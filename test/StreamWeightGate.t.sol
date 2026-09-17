// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {USR_ILLEGAL_ARGUMENT} from "fvm-solidity/FVMErrors.sol";

import {SWATestBase} from "./SWATestBase.sol";
import {StreamWeightActor} from "../src/StreamWeightActor.sol";
import {ServiceRewardsActor} from "../src/ServiceRewardsActor.sol";
import {IServiceRewardsActor} from "../src/interfaces/IServiceRewardsActor.sol";
import {SERVICE_ID, WeightRecord, WeightRecordUpdate} from "../src/lib/FVMRewardTypes.sol";
import {Epoch} from "../src/lib/Epoch.sol";
import {FixedU18} from "../src/lib/FixedU18.sol";
import {FVMRewards} from "../src/lib/FVMRewards.sol";
import {GateParamsLibrary, GateParams, VolumeTarget} from "../src/lib/GateParams.sol";
import {UnanimousGovernance} from "../src/lib/UnanimousGovernance.sol";
import {OwnersLibrary} from "../src/lib/Owners.sol";
import {MAINNET_TIMELOCK, MockState} from "./mocks/FVMRewardActor.sol";

/// @dev ERC-7201 storage slot of GateParamsInfo (src/lib/GateParams.sol: Solstice.GateParams).
///     GateParamsInfo layout: {uint64 lastCheckedQuarter; GateParams params;}, where params is
///     {VolumeTarget target; uint64 steps;} and VolumeTarget is {FixedU18 base; FixedU18 stepRatio;}
///     — so lastCheckedQuarter lives at the slot, target.base at slot+1, stepRatio at slot+2,
///     and steps at slot+3 (each FixedU18 is a full 32-byte word; steps is a uint64 in the low bits).
bytes32 constant GATE_PARAMS_SLOT = 0xf9abab00248d945495524c8caf6be2b837274c1becd1964fb3775f62fd6e4600;

/// @notice StreamWeightActor quarterly-gate tests: `setGateParams` (the only system-wide governance
///         method retaining a HOLD-epoch timelock after the W2 change) and its `quarterlyGateCheck`
///         counterpart. Covers the timelock's effective boundary (== vs < HOLD epochs), the
///         permissionless execution path, and the gate state machine (quarter advance, threshold
///         comparison, StepsComplete terminal state, not-yet-bound quarter).
contract StreamWeightGateTest is SWATestBase {
    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _gateParams(uint256 base, uint256 stepRatio, uint64 steps)
        internal
        pure
        returns (GateParams memory params)
    {
        params.target = VolumeTarget({base: FixedU18.wrap(base), stepRatio: FixedU18.wrap(stepRatio)});
        params.steps = steps;
    }

    function _sraMock() internal returns (IServiceRewardsActor sra) {
        sra = IServiceRewardsActor(makeAddr("sra")); // the actor's SRA handle (same label setUp passed the constructor)
    }

    function _mockFpv(IServiceRewardsActor sra, uint64 quarter, uint256 value) internal {
        vm.mockCall(
            address(sra),
            abi.encodeWithSelector(IServiceRewardsActor.aggregatedFilecoinPayVolume.selector, quarter),
            abi.encode(FixedU18.wrap(value))
        );
    }

    function _mockQuarterStart(IServiceRewardsActor sra, uint64 quarter, uint64 end) internal {
        vm.mockCall(
            address(sra),
            abi.encodeWithSelector(IServiceRewardsActor.quarterStart.selector, quarter),
            abi.encode(Epoch.wrap(end))
        );
    }

    /// @dev Both owners submit the same params: unanimous approval reached, execution deferred by HOLD.
    function _submitGateParams(GateParams memory params) internal {
        vm.prank(owner1);
        actor.setGateParams(params);
        vm.prank(owner2);
        actor.setGateParams(params);
    }

    /// @dev Reads the ERC-7201 GateParamsInfo slot the SWA's own GateParamsLibrary writes.
    function _storedGateParamsAt(address target)
        internal
        view
        returns (uint256 base, uint256 stepRatio, uint64 steps, uint64 lastCheckedQuarter)
    {
        base = uint256(vm.load(target, bytes32(uint256(GATE_PARAMS_SLOT) + 1)));
        stepRatio = uint256(vm.load(target, bytes32(uint256(GATE_PARAMS_SLOT) + 2)));
        steps = uint64(uint256(vm.load(target, bytes32(uint256(GATE_PARAMS_SLOT) + 3))));
        lastCheckedQuarter = uint64(uint256(vm.load(target, GATE_PARAMS_SLOT)));
    }

    function _storedGateParams()
        internal
        view
        returns (uint256 base, uint256 stepRatio, uint64 steps, uint64 lastCheckedQuarter)
    {
        return _storedGateParamsAt(address(actor));
    }

    // -------------------------------------------------------------------------
    // setGateParams — access control and the HOLD-epoch timelock (W2 core semantics)
    // -------------------------------------------------------------------------

    function test_SetGateParams_NotOwner_Reverts() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OwnersLibrary.NotOwner.selector, stranger));
        actor.setGateParams(_gateParams(4000 ether, 2.7 ether, 0));
    }

    function test_SetGateParams_EmitsSubmittedAndApproved() public {
        GateParams memory params = _gateParams(4000 ether, 2.7 ether, 1);
        bytes32 taskId = keccak256(abi.encodePacked(StreamWeightActor.setGateParams.selector, abi.encode(params)));

        vm.expectEmit(true, true, true, true);
        emit UnanimousGovernance.Submitted(taskId);
        vm.prank(owner1);
        actor.setGateParams(params);

        vm.expectEmit(true, true, true, true);
        emit UnanimousGovernance.Approved(taskId, owner2);
        vm.prank(owner2);
        actor.setGateParams(params);
    }

    /// @dev The W2 timelock contract: after unanimous approval the old params stay effective through
    ///      the whole HOLD window (submission writes nothing), permissionless completion is blocked
    ///      one epoch before the hold elapses, and the new params land exactly at epoch == HOLD.
    function test_SetGateParams_OwnerSubmit_ParamsDeferred_UntilTimelock() public {
        GateParams memory params = _gateParams(4000 ether, 2.7 ether, 1);
        _submitGateParams(params);
        uint64 modified = uint64(vm.getBlockNumber()); // second vote's epoch — the hold starts counting here

        // Old (init) params still effective: 3500 ether / 2.7 / 0 steps, untouched by the submission.
        (uint256 base, uint256 stepRatio, uint64 steps,) = _storedGateParams();
        assertEq(base, 3500 ether);
        assertEq(stepRatio, 2.7 ether);
        assertEq(steps, 0);

        // < HOLD: permissionless execution still gated.
        vm.roll(modified + Epoch.unwrap(MAINNET_TIMELOCK) - 1);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(
            abi.encodeWithSelector(
                UnanimousGovernance.HoldUntil.selector, Epoch.wrap(modified + Epoch.unwrap(MAINNET_TIMELOCK))
            )
        );
        actor.setGateParams(params);

        // == HOLD (exact boundary): execution becomes permissionless and the new params land.
        vm.roll(modified + Epoch.unwrap(MAINNET_TIMELOCK));
        vm.prank(makeAddr("stranger"));
        actor.setGateParams(params);

        (base, stepRatio, steps,) = _storedGateParams();
        assertEq(base, 4000 ether);
        assertEq(stepRatio, 2.7 ether);
        assertEq(steps, 1);
    }

    /// @dev An approval not yet unanimous keeps the task in owner-only territory: a stranger cannot
    ///      trigger completion because the permissionless branch requires a full approval set.
    function test_SetGateParams_SingleOwnerVote_StrangerCannotComplete() public {
        GateParams memory params = _gateParams(4000 ether, 2.7 ether, 0);
        vm.prank(owner1);
        actor.setGateParams(params); // only one vote

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(abi.encodeWithSelector(OwnersLibrary.NotOwner.selector, makeAddr("stranger")));
        actor.setGateParams(params);
    }

    /// @dev steps is bounded above by the gate count (8 = (W2_CAP - W2_BASE) / W2_STEP): a steps
    /// value past it would wedge quarterlyGateCheck at StepsComplete, so setGateParams rejects it
    /// at execution. The write lands nothing -- params keep their init values.
    function test_SetGateParams_StepsAboveGateCount_RevertsAndWritesNothing() public {
        GateParams memory params = _gateParams(4000 ether, 2.7 ether, 9); // 9 > 8 gate steps
        _submitGateParams(params); // both owners approve: the submission defers to the hold
        vm.roll(vm.getBlockNumber() + Epoch.unwrap(MAINNET_TIMELOCK));

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(StreamWeightActor.StepsOutOfRange.selector);
        actor.setGateParams(params); // permissionless completion hits the bound

        (uint256 base, uint256 stepRatio, uint64 steps,) = _storedGateParams();
        assertEq(base, 3500 ether, "params untouched");
        assertEq(stepRatio, 2.7 ether);
        assertEq(steps, 0);
    }

    /// @dev steps == the gate count is legal (the upper bound, not the rejection edge): the
    /// schedule stops at W2_CAP and the params land unchanged after the hold.
    function test_SetGateParams_StepsAtGateCount_LandsAfterTimelock() public {
        GateParams memory params = _gateParams(4000 ether, 2.7 ether, 8);
        _submitGateParams(params);
        vm.roll(vm.getBlockNumber() + Epoch.unwrap(MAINNET_TIMELOCK));
        vm.prank(makeAddr("stranger"));
        actor.setGateParams(params);

        (uint256 base,, uint64 steps,) = _storedGateParams();
        assertEq(base, 4000 ether);
        assertEq(steps, 8);
    }

    /// @dev A second, distinct proposal cannot start while an earlier one is still outstanding.
    function test_SetGateParams_SecondDistinctProposal_Reverts() public {
        GateParams memory a = _gateParams(4000 ether, 2.7 ether, 1);
        GateParams memory b = _gateParams(4500 ether, 2.7 ether, 2);
        vm.prank(owner1);
        actor.setGateParams(a);

        bytes32 taskIdA = keccak256(abi.encodePacked(StreamWeightActor.setGateParams.selector, abi.encode(a)));

        vm.prank(owner1);
        vm.expectRevert(abi.encodeWithSelector(GateParamsLibrary.PendingGateParams.selector, taskIdA));
        actor.setGateParams(b);
    }

    /// @dev Vetoing the tracked task clears it, so a distinct proposal can then start and complete.
    function test_SetGateParams_SecondDistinctProposal_AllowedAfterVeto() public {
        GateParams memory a = _gateParams(4000 ether, 2.7 ether, 1);
        GateParams memory b = _gateParams(4500 ether, 2.7 ether, 2);
        vm.prank(owner1);
        actor.setGateParams(a);

        bytes32 taskIdA = keccak256(abi.encodePacked(StreamWeightActor.setGateParams.selector, abi.encode(a)));
        vm.prank(owner1);
        actor.veto(taskIdA);

        _submitGateParams(b);
        vm.roll(vm.getBlockNumber() + Epoch.unwrap(MAINNET_TIMELOCK));
        actor.setGateParams(b);

        (uint256 base,, uint64 steps,) = _storedGateParams();
        assertEq(base, 4500 ether);
        assertEq(steps, 2);
    }

    // -------------------------------------------------------------------------
    // veto -- a held gate update is cancellable by either multisig before its hold elapses.
    // -------------------------------------------------------------------------

    /// @dev One owner's vote leaves the task pending inside its HOLD window; the other owner
    /// vetoes it, wiping the task so no permissionless completion can land the params.
    function test_Veto_HeldGateParams_Owner2CancelsPending() public {
        GateParams memory params = _gateParams(4000 ether, 2.7 ether, 1);
        vm.prank(owner1);
        actor.setGateParams(params); // one vote: approvals = {owner1}, deferred by the hold

        bytes32 taskId = keccak256(abi.encodePacked(StreamWeightActor.setGateParams.selector, abi.encode(params)));

        vm.expectEmit(true, true, true, true);
        emit UnanimousGovernance.Rejected(taskId, owner2);
        vm.prank(owner2);
        actor.veto(taskId);

        // The task is gone: after the hold would have elapsed, the same calldata starts a fresh
        // approval round instead of completing, and a stranger is not an owner.
        vm.roll(vm.getBlockNumber() + Epoch.unwrap(MAINNET_TIMELOCK));
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(abi.encodeWithSelector(OwnersLibrary.NotOwner.selector, makeAddr("stranger")));
        actor.setGateParams(params);

        (uint256 base,, uint64 steps,) = _storedGateParams();
        assertEq(base, 3500 ether, "vetoed params never land");
        assertEq(steps, 0);
    }

    function test_Veto_NonOwner_RevertsNotOwner() public {
        GateParams memory params = _gateParams(4000 ether, 2.7 ether, 1);
        vm.prank(owner1);
        actor.setGateParams(params);

        bytes32 taskId = keccak256(abi.encodePacked(StreamWeightActor.setGateParams.selector, abi.encode(params)));
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OwnersLibrary.NotOwner.selector, stranger));
        actor.veto(taskId);
    }

    /// @dev The veto clears approvals as well as the task: re-submitting the same calldata emits a
    /// fresh Submitted (not AlreadyApproved), a new approval round runs, and the params apply.
    function test_Veto_AfterCancel_ResubmitRestartsAndApplies() public {
        GateParams memory params = _gateParams(4000 ether, 2.7 ether, 1);
        vm.prank(owner1);
        actor.setGateParams(params);

        bytes32 taskId = keccak256(abi.encodePacked(StreamWeightActor.setGateParams.selector, abi.encode(params)));
        vm.prank(owner2);
        actor.veto(taskId);

        // owner1's earlier approval was wiped: the same calldata restarts at Submitted.
        vm.expectEmit(true, true, true, true);
        emit UnanimousGovernance.Submitted(taskId);
        vm.prank(owner1);
        actor.setGateParams(params);

        vm.prank(owner2);
        actor.setGateParams(params); // fresh second approval
        vm.roll(vm.getBlockNumber() + Epoch.unwrap(MAINNET_TIMELOCK));
        vm.prank(makeAddr("stranger"));
        actor.setGateParams(params); // permissionless completion

        (uint256 base,, uint64 steps,) = _storedGateParams();
        assertEq(base, 4000 ether, "re-approved params apply after the hold");
        assertEq(steps, 1);
    }

    /// @dev A task whose params are out of range can never complete: execution reverts
    ///      StepsOutOfRange and the unanimous state rolls back with it, leaving the task stuck.
    ///      An owner vetoes the stuck task, and a fresh submission of legal params recovers the
    ///      gate update end to end.
    function test_SetGateParams_OutOfRangeTask_VetoRecoveryAppliesLegalParams() public {
        GateParams memory bad = _gateParams(4000 ether, 2.7 ether, 9); // 9 > 8 gate steps
        bytes32 badTaskId = keccak256(abi.encodePacked(StreamWeightActor.setGateParams.selector, abi.encode(bad)));
        _submitGateParams(bad);
        vm.roll(vm.getBlockNumber() + Epoch.unwrap(MAINNET_TIMELOCK));

        // Permissionless completion reverts at the bound; the task survives the failed execution
        // (whole-tx rollback) and stays pending -- a second attempt reverts identically.
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(StreamWeightActor.StepsOutOfRange.selector);
        actor.setGateParams(bad);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(StreamWeightActor.StepsOutOfRange.selector);
        actor.setGateParams(bad);

        (uint256 base,, uint64 steps,) = _storedGateParams();
        assertEq(base, 3500 ether, "stuck task never lands its params");
        assertEq(steps, 0);

        // Owner veto clears the stuck task.
        vm.expectEmit(true, true, true, true);
        emit UnanimousGovernance.Rejected(badTaskId, owner1);
        vm.prank(owner1);
        actor.veto(badTaskId);

        // A fresh submission of legal params completes normally after the hold.
        GateParams memory good = _gateParams(4000 ether, 2.7 ether, 1);
        _submitGateParams(good);
        vm.roll(vm.getBlockNumber() + Epoch.unwrap(MAINNET_TIMELOCK));
        vm.prank(makeAddr("stranger"));
        actor.setGateParams(good);

        (base,, steps,) = _storedGateParams();
        assertEq(base, 4000 ether, "legal params apply after veto recovery");
        assertEq(steps, 1);
    }

    // -------------------------------------------------------------------------
    // quarterlyGateCheck — gate state machine
    // -------------------------------------------------------------------------

    /// @dev fpv == threshold (3500 * 2.7^0): the boundary equality clears the gate, steps the
    ///      SERVICE_ID schedule once, and advances the checked quarter.
    function test_QuarterlyGateCheck_ThresholdCleared_StepsAndLandsWeight() public {
        _registerAndActivate(SERVICE_ID);
        IServiceRewardsActor sra = _sraMock();
        _mockFpv(sra, 2, 3500 ether);
        _mockQuarterStart(sra, 2, 1000);

        actor.quarterlyGateCheck(); // permissionless

        (uint256 base, uint256 stepRatio, uint64 steps, uint64 lastChecked) = _storedGateParams();
        assertEq(base, 3500 ether);
        assertEq(stepRatio, 2.7 ether);
        assertEq(steps, 1, "threshold cleared -> one step taken");
        assertEq(lastChecked, 2, "quarter advances past the init lastCheckedQuarter=1");

        // The step is queued to f02 as an uncancellable STEP_WEIGHT write and lands once the
        // mock's own timelock elapses: floor/vStart/cap = (0+3) * STEP, tStart = quarterStart(2).
        vm.roll(vm.getBlockNumber() + Epoch.unwrap(MAINNET_TIMELOCK));
        rewardActor().mockSettle();
        (uint256 b, uint256 r, uint64 s,) = _storedGateParams();
        assertEq(b, 3500 ether);
        assertEq(r, 2.7 ether);
        assertEq(s, 1);
    }

    /// @dev fpv < threshold: no step, but the quarter still advances (each quarter is checked once).
    function test_QuarterlyGateCheck_BelowThreshold_NoStep_QuarterAdvances() public {
        IServiceRewardsActor sra = _sraMock();
        _mockFpv(sra, 2, 3499 ether);

        actor.quarterlyGateCheck();

        (,, uint64 steps, uint64 lastChecked) = _storedGateParams();
        assertEq(steps, 0, "below threshold -> no step");
        assertEq(lastChecked, 2);
    }

    /// @dev Successive checks advance one quarter each, independent of the threshold outcome.
    function test_QuarterlyGateCheck_QuarterAdvancesMonotonically() public {
        _registerAndActivate(SERVICE_ID);
        IServiceRewardsActor sra = _sraMock();
        _mockFpv(sra, 2, 3499 ether); // below
        _mockFpv(sra, 3, 3500 ether); // cleared (threshold for steps=0 is still 3500)
        _mockQuarterStart(sra, 3, 2000);

        actor.quarterlyGateCheck();
        actor.quarterlyGateCheck();

        (,, uint64 steps, uint64 lastChecked) = _storedGateParams();
        assertEq(lastChecked, 3);
        assertEq(steps, 1);
    }

    /// @dev Terminal state: with all 8 steps taken the gate is complete and rejects further checks.
    ///      The steps are driven to 8 through the governance path, re-exercising the setGateParams
    ///      timelock execution from the earlier tests.
    function test_QuarterlyGateCheck_StepsComplete_Reverts() public {
        GateParams memory done = _gateParams(3500 ether, 2.7 ether, 8);
        _submitGateParams(done);
        vm.roll(vm.getBlockNumber() + Epoch.unwrap(MAINNET_TIMELOCK));
        actor.setGateParams(done);

        (,, uint64 steps,) = _storedGateParams();
        assertEq(steps, 8);

        vm.expectRevert(StreamWeightActor.StepsComplete.selector);
        actor.quarterlyGateCheck();
    }

    /// @dev A quarter whose FilecoinPayVolume is not yet bound reverts through the SRA — the SWA
    ///      does not mask the NotBound guard (call too early), only the zero-volume case returns 0.
    function test_QuarterlyGateCheck_QuarterNotBound_Reverts() public {
        IServiceRewardsActor sra = _sraMock();
        uint64 q = 2;
        vm.mockCallRevert(
            address(sra),
            abi.encodeCall(IServiceRewardsActor.aggregatedFilecoinPayVolume, (q)),
            abi.encodeWithSelector(ServiceRewardsActor.NotBound.selector, q)
        );

        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.NotBound.selector, q));
        actor.quarterlyGateCheck();
    }

    /// @dev Each check reports its quarter and outcome: passed=true carries the post-check step
    /// count, so tooling can pinpoint when a gate step was taken (event shape pending #37).
    function test_QuarterlyGateCheck_Passed_EmitsResult() public {
        _registerAndActivate(SERVICE_ID);
        IServiceRewardsActor sra = _sraMock();
        _mockFpv(sra, 2, 3500 ether); // == threshold: clears
        _mockQuarterStart(sra, 2, 1000);

        vm.expectEmit(true, true, true, true);
        emit StreamWeightActor.QuarterlyGateCheckResult(2, true, 1);
        actor.quarterlyGateCheck();
    }

    /// @dev A below-threshold check still emits its outcome: passed=false and the unchanged step
    /// count, so an observer can tell a checked-and-failed quarter from an unchecked one.
    function test_QuarterlyGateCheck_BelowThreshold_EmitsResult() public {
        IServiceRewardsActor sra = _sraMock();
        _mockFpv(sra, 2, 3499 ether); // < threshold: no step

        vm.expectEmit(true, true, true, true);
        emit StreamWeightActor.QuarterlyGateCheckResult(2, false, 0);
        actor.quarterlyGateCheck();
    }

    /// @dev Every gate-clearing check writes w2 exactly on the 5pp grid: the landed record equals
    /// W2_BASE + steps*W2_STEP = (steps+3)*STEP (W2_BASE is three 5pp steps up from zero), and a
    /// sweep of all eight positions stays on the grid through the cap boundary.
    function test_QuarterlyGateCheck_StepWeight_LandsOnGridEveryStep() public {
        _registerAndActivate(SERVICE_ID);
        IServiceRewardsActor sra = _sraMock();

        for (uint64 steps = 0; steps < 8; steps++) {
            uint64 quarter = 2 + steps;
            _mockFpv(sra, quarter, 1e30); // clears every threshold up to ratio^7 * base
            _mockQuarterStart(sra, quarter, 1000 * (steps + 1));

            actor.quarterlyGateCheck();
            (,, uint64 s, uint64 lastChecked) = _storedGateParams();
            assertEq(s, steps + 1, "step taken");
            assertEq(lastChecked, quarter, "quarter advanced");

            // Settle the queued write so the next check's STEP_WEIGHT slot is free, then assert
            // the landed record is on the grid.
            vm.roll(vm.getBlockNumber() + Epoch.unwrap(MAINNET_TIMELOCK));
            rewardActor().mockSettle();

            MockState memory st = rewardActor().mockState();
            assertEq(st.streams.length, 1, "SERVICE_ID live");
            int256 expected = (int256(uint256(steps)) + 3) * 5e16; // (steps + 3) * STEP
            assertEq(st.streams[0].weightRecord.vStart, expected, "vStart on the grid");
            assertEq(st.streams[0].weightRecord.floor, expected, "floor on the grid");
            assertEq(st.streams[0].weightRecord.cap, expected, "cap on the grid");
            assertEq(st.streams[0].weightRecord.slope, 0, "flat schedule");
            assertEq(
                uint256(Epoch.unwrap(st.streams[0].weightRecord.tStart)),
                1000 * (steps + 1),
                "tStart is the checked quarter's end"
            );
        }
    }

    /// @dev If f02's queue-time validation rejects the gate write, the whole check reverts: steps
    /// and lastCheckedQuarter do not advance, and once the blocking write settles the same quarter
    /// retries through. The rejection is the real pending-slot collision, not a mock switch: a
    /// STEP_WEIGHT batch already occupies the schedule-wide slot, and gate writes are
    /// uncancellable, so only settling frees it for the retry.
    function test_QuarterlyGateCheck_F02RejectsStepWrite_WholeCallRollsBack() public {
        _registerAndActivate(SERVICE_ID);
        IServiceRewardsActor sra = _sraMock();
        _mockFpv(sra, 2, 3500 ether);
        _mockQuarterStart(sra, 2, 1000);

        // A STEP_WEIGHT batch still inside its timelock holds the schedule-wide slot, so the gate's
        // own write is rejected at queue time (pending write exists) rather than admitted.
        WeightRecord memory pendingStep =
            WeightRecord({vStart: 0.15e18, slope: 0, tStart: Epoch.wrap(1000), floor: 0.15e18, cap: 0.15e18});
        assertEq(rewardActor().mockQueueStepWeight(_singleWeightRecord(SERVICE_ID, pendingStep)), 0, "slot occupied");

        vm.expectRevert(
            abi.encodeWithSelector(FVMRewards.StepWeightRecordsFailed.selector, int256(uint256(USR_ILLEGAL_ARGUMENT)))
        );
        actor.quarterlyGateCheck();

        // Atomic rollback: neither the step counter nor the checked quarter advanced.
        (,, uint64 steps, uint64 lastChecked) = _storedGateParams();
        assertEq(steps, 0, "step counter rolled back");
        assertEq(lastChecked, 1, "checked quarter rolled back");

        // Once the blocking write settles the slot is free and the same quarter check goes through.
        vm.roll(vm.getBlockNumber() + Epoch.unwrap(MAINNET_TIMELOCK));
        rewardActor().mockSettle();
        actor.quarterlyGateCheck();
        (,, steps, lastChecked) = _storedGateParams();
        assertEq(steps, 1, "retry takes the step");
        assertEq(lastChecked, 2, "retry advances the quarter");
    }

    function test_QuarterlyGateCheck_PendingSetWeightRecords_BlocksInterleavedCheck() public {
        _registerAndActivate(SERVICE_ID);

        WeightRecord memory fifty = WeightRecord({
            vStart: 0.5e18, slope: 0, tStart: Epoch.wrap(uint64(vm.getBlockNumber())), floor: 0.5e18, cap: 0.5e18
        });
        WeightRecordUpdate[] memory updates = _singleWeightRecord(SERVICE_ID, fifty);
        vm.prank(owner1);
        actor.setWeightRecords(updates);
        vm.prank(owner2);
        actor.setWeightRecords(updates);

        GateParams memory terminal = _gateParams(3500 ether, 2.7 ether, 8);
        _submitGateParams(terminal);

        Epoch until = Epoch.wrap(uint64(vm.getBlockNumber()) + Epoch.unwrap(MAINNET_TIMELOCK));
        vm.roll(vm.getBlockNumber() + Epoch.unwrap(MAINNET_TIMELOCK) - 1);

        IServiceRewardsActor sra = _sraMock();
        _mockFpv(sra, 2, 3500 ether);
        _mockQuarterStart(sra, 2, 1000);

        vm.expectRevert(abi.encodeWithSelector(GateParamsLibrary.PendingWeightWrite.selector, until));
        actor.quarterlyGateCheck();

        vm.roll(vm.getBlockNumber() + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                GateParamsLibrary.PendingGateParams.selector,
                keccak256(abi.encodePacked(StreamWeightActor.setGateParams.selector, abi.encode(terminal)))
            )
        );
        actor.quarterlyGateCheck();

        actor.setGateParams(terminal);
        (,, uint64 steps,) = _storedGateParams();
        assertEq(steps, 8, "paired steps land, not an interleaved step");

        vm.roll(vm.getBlockNumber() + 1);
        vm.expectRevert(StreamWeightActor.StepsComplete.selector);
        actor.quarterlyGateCheck();

        rewardActor().mockSettle();
        MockState memory state = rewardActor().mockState();
        assertEq(state.streams[0].weightRecord.vStart, 0.5e18, "interleaved gate did not overwrite the paired retune");
    }

    /// @dev A unanimous, still-held setGateParams blocks quarterlyGateCheck.
    function test_QuarterlyGateCheck_UnanimousSetGateParams_Reverts() public {
        GateParams memory params = _gateParams(4000 ether, 2.7 ether, 1);
        _submitGateParams(params);
        bytes32 taskId = keccak256(abi.encodePacked(StreamWeightActor.setGateParams.selector, abi.encode(params)));

        IServiceRewardsActor sra = _sraMock();
        _mockFpv(sra, 2, 3499 ether);

        vm.expectRevert(abi.encodeWithSelector(GateParamsLibrary.PendingGateParams.selector, taskId));
        actor.quarterlyGateCheck();
    }

    /// @dev A single-owner (non-unanimous) setGateParams proposal does not block quarterlyGateCheck.
    function test_QuarterlyGateCheck_SingleOwnerSetGateParams_NotBlocked() public {
        GateParams memory params = _gateParams(4000 ether, 2.7 ether, 1);
        vm.prank(owner1);
        actor.setGateParams(params);

        IServiceRewardsActor sra = _sraMock();
        _mockFpv(sra, 2, 3499 ether);
        actor.quarterlyGateCheck();

        (,, uint64 steps, uint64 lastChecked) = _storedGateParams();
        assertEq(steps, 0);
        assertEq(lastChecked, 2);
    }

    /// @dev setWeightRecords lands (both owners) while setGateParams has only one approval.
    function test_QuarterlyGateCheck_PendingWeightWrite_NeededWhenGateParamsNotYetUnanimous() public {
        _registerAndActivate(SERVICE_ID);

        WeightRecord memory fifty = WeightRecord({
            vStart: 0.5e18, slope: 0, tStart: Epoch.wrap(uint64(vm.getBlockNumber())), floor: 0.5e18, cap: 0.5e18
        });
        WeightRecordUpdate[] memory updates = _singleWeightRecord(SERVICE_ID, fifty);
        vm.prank(owner1);
        actor.setWeightRecords(updates);
        vm.prank(owner2);
        actor.setWeightRecords(updates);

        GateParams memory terminal = _gateParams(3500 ether, 2.7 ether, 8);
        vm.prank(owner1);
        actor.setGateParams(terminal); // only one approval: NOT unanimous, guard 2 would not fire

        IServiceRewardsActor sra = _sraMock();
        _mockFpv(sra, 2, 3500 ether);
        _mockQuarterStart(sra, 2, 1000);

        // Still well inside f02's hold window for the 50% write.
        vm.expectRevert(
            abi.encodeWithSelector(
                GateParamsLibrary.PendingWeightWrite.selector,
                Epoch.wrap(uint64(vm.getBlockNumber()) + Epoch.unwrap(MAINNET_TIMELOCK))
            )
        );
        actor.quarterlyGateCheck();
    }

    /// @dev Reproducer: if the matching setGateParams receives its second approval only after the
    ///      SetWeightRecords hold elapses, the time-based weight blocker has expired while the
    ///      non-unanimous params task does not block. A gate check can then queue an old-counter
    ///      step that later overwrites the retune, leaving f02's weight inconsistent with `steps`.
    function test_QuarterlyGateCheck_DelayedSecondGateParamsApproval_DoesNotOverwriteRetune() public {
        _registerAndActivate(SERVICE_ID);

        WeightRecord memory fifty = WeightRecord({
            vStart: 0.5e18, slope: 0, tStart: Epoch.wrap(uint64(vm.getBlockNumber())), floor: 0.5e18, cap: 0.5e18
        });
        WeightRecordUpdate[] memory updates = _singleWeightRecord(SERVICE_ID, fifty);
        vm.prank(owner1);
        actor.setWeightRecords(updates);
        vm.prank(owner2);
        actor.setWeightRecords(updates);

        GateParams memory terminal = _gateParams(3500 ether, 2.7 ether, 8);
        vm.prank(owner1);
        actor.setGateParams(terminal);

        // The weight retune reaches its effective epoch before setGateParams becomes unanimous.
        // The current guards allow this check, which settles 50% and queues an old-counter 15%.
        vm.roll(vm.getBlockNumber() + Epoch.unwrap(MAINNET_TIMELOCK));
        IServiceRewardsActor sra = _sraMock();
        _mockFpv(sra, 2, 3500 ether);
        _mockQuarterStart(sra, 2, 1000);
        actor.quarterlyGateCheck();

        // The delayed second approval starts the params hold at the same epoch as the 15% write.
        vm.prank(owner2);
        actor.setGateParams(terminal);
        vm.roll(vm.getBlockNumber() + Epoch.unwrap(MAINNET_TIMELOCK));
        actor.setGateParams(terminal);
        rewardActor().mockSettle();

        (,, uint64 steps,) = _storedGateParams();
        MockState memory state = rewardActor().mockState();
        assertEq(steps, 8, "matching gate params landed");
        assertEq(state.streams[0].weightRecord.vStart, 0.5e18, "interleaved gate overwrote the 50% retune");
    }

    /// @dev Once the pending setGateParams completes, quarterlyGateCheck reads the fresh steps.
    function test_QuarterlyGateCheck_UnblocksAfterSetGateParamsCompletes() public {
        GateParams memory params = _gateParams(4000 ether, 2.7 ether, 1);
        _submitGateParams(params);
        vm.roll(vm.getBlockNumber() + Epoch.unwrap(MAINNET_TIMELOCK));
        actor.setGateParams(params);

        IServiceRewardsActor sra = _sraMock();
        _mockFpv(sra, 2, 3499 ether);
        actor.quarterlyGateCheck();

        (,, uint64 steps, uint64 lastChecked) = _storedGateParams();
        assertEq(steps, 1);
        assertEq(lastChecked, 2);
    }
}
