// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {REWARD_ACTOR_ID, REWARD_ACTOR_ADDRESS, BURN_ACTOR_ID, BURN_ADDRESS} from "fvm-solidity/FVMActors.sol";
import {CALL_ACTOR_BY_ID} from "fvm-solidity/FVMPrecompiles.sol";
import {NO_FLAGS} from "fvm-solidity/FVMFlags.sol";
import {USR_FORBIDDEN, USR_ILLEGAL_ARGUMENT, USR_NOT_FOUND, USR_UNHANDLED_MESSAGE} from "fvm-solidity/FVMErrors.sol";
import {FVMPay} from "fvm-solidity/FVMPay.sol";
import {FVMMiner} from "fvm-solidity/FVMMiner.sol";

import {MockRewardTest} from "./MockRewardTest.sol";
import {
    WeightRecord,
    DistributionKind,
    Share,
    LedgerRow,
    PendingOp,
    StreamView,
    TombstoneView,
    PendingView,
    WAD,
    MAX_STREAMS,
    MAX_RECIPIENTS,
    SHARE_TOTAL
} from "./FVMRewardActor.sol";
import {
    SET_WEIGHT_RECORDS,
    STEP_WEIGHT_RECORDS,
    SET_SHARES,
    GET_STATE,
    REGISTER_STREAM,
    REMOVE_STREAM,
    SET_DISTRIBUTION,
    CANCEL_PENDING,
    CLAIM,
    SWA_TIMELOCK
} from "./FVMRewardMethod.sol";

/// @dev A distinct external caller, so tests can check authorization by identity rather than
/// by happenstance of who the test contract is.
contract RewardCaller {
    function call(uint64 method, bytes memory params) external returns (uint32 exitCode, bytes memory data) {
        bytes memory callData = abi.encode(method, uint256(0), NO_FLAGS, uint64(0), params, REWARD_ACTOR_ID);
        (bool success, bytes memory ret) = CALL_ACTOR_BY_ID.delegatecall(callData);
        require(success, "RewardCaller: precompile call failed");
        (exitCode,, data) = abi.decode(ret, (uint32, uint64, bytes));
    }
}

contract FVMRewardActorTest is MockRewardTest {
    using FVMPay for uint64;

    RewardCaller swaCaller;
    RewardCaller writerCaller;
    RewardCaller otherWriterCaller;
    RewardCaller randomCaller;

    uint64 constant SERVICE_ID = 1;
    uint64 constant CONSENSUS_ID = 2;

    address constant RECIPIENT_A = address(0xBEEF);
    address constant RECIPIENT_B = address(0xCAFE);

    function setUp() public override {
        super.setUp();
        swaCaller = new RewardCaller();
        writerCaller = new RewardCaller();
        otherWriterCaller = new RewardCaller();
        randomCaller = new RewardCaller();
        rewardActor().mockSwa(address(swaCaller));
    }

    // -------------------------------------------------------------------------
    // Call helpers
    // -------------------------------------------------------------------------

    function _call(uint64 method, bytes memory params) internal returns (uint32 exitCode, bytes memory data) {
        bytes memory callData = abi.encode(method, uint256(0), NO_FLAGS, uint64(0), params, REWARD_ACTOR_ID);
        (bool success, bytes memory ret) = CALL_ACTOR_BY_ID.delegatecall(callData);
        assertTrue(success, "precompile call failed");
        (exitCode,, data) = abi.decode(ret, (uint32, uint64, bytes));
    }

    function _record(int256 vStart, int256 slope, uint64 tStart, int256 floor, int256 cap)
        internal
        pure
        returns (WeightRecord memory)
    {
        return WeightRecord({vStart: vStart, slope: slope, tStart: tStart, floor: floor, cap: cap});
    }

    /// @dev A record whose weight is the constant `w` at every epoch.
    function _constantRecord(int256 w) internal pure returns (WeightRecord memory) {
        return _record(w, 0, 0, 0, WAD);
    }

    function _registerParams(uint64 id, WeightRecord memory record, DistributionKind kind, address writer)
        internal
        view
        returns (bytes memory)
    {
        return abi.encode(id, record, kind, writer, uint64(block.number) + SWA_TIMELOCK);
    }

    function _registerStream(uint64 id, WeightRecord memory record, DistributionKind kind, address writer)
        internal
        returns (uint32)
    {
        (uint32 exitCode,) = swaCaller.call(REGISTER_STREAM, _registerParams(id, record, kind, writer));
        return exitCode;
    }

    function _registerExplicit(uint64 id, address writer) internal {
        assertEq(_registerStream(id, _constantRecord(0.1e18), DistributionKind.EXPLICIT, writer), 0);
        _warpPastTimelockAndSettle();
    }

    function _warpPastTimelockAndSettle() internal {
        vm.roll(block.number + SWA_TIMELOCK);
        _call(GET_STATE, ""); // any dispatched call settles pending writes
    }

    /// @dev Bundled as a struct so call sites don't juggle an 8-way tuple.
    struct GetStateResult {
        uint256 totalMintedReward;
        uint256 totalBurnMinted;
        uint256 totalServiceMinted;
        uint64 nextTransitionEpoch;
        uint64 swaTimelockEpochs;
        StreamView[] streams;
        TombstoneView[] tombstones;
        PendingView[] pendingWrites;
    }

    function _getState() internal returns (GetStateResult memory r) {
        (uint32 exitCode, bytes memory data) = _call(GET_STATE, "");
        assertEq(exitCode, 0);
        // Not `abi.decode(data, (GetStateResult))`: that single-struct-type decode sugar
        // silently mis-decodes this array-of-structs-with-nested-arrays depth on solc 0.8.36
        // without via-ir. The tuple-typed decode below is correct, but must land in fresh
        // locals -- assigning straight into named returns hits `stack too deep`.
        (
            uint256 totalMintedReward,
            uint256 totalBurnMinted,
            uint256 totalServiceMinted,
            uint64 nextTransitionEpoch,
            uint64 swaTimelockEpochs,
            StreamView[] memory streams,
            TombstoneView[] memory tombstones,
            PendingView[] memory pendingWrites
        ) = abi.decode(data, (uint256, uint256, uint256, uint64, uint64, StreamView[], TombstoneView[], PendingView[]));
        r = GetStateResult({
            totalMintedReward: totalMintedReward,
            totalBurnMinted: totalBurnMinted,
            totalServiceMinted: totalServiceMinted,
            nextTransitionEpoch: nextTransitionEpoch,
            swaTimelockEpochs: swaTimelockEpochs,
            streams: streams,
            tombstones: tombstones,
            pendingWrites: pendingWrites
        });
    }

    function _streams() internal returns (StreamView[] memory) {
        return _getState().streams;
    }

    function _shares(address wallet, uint256 amount) internal pure returns (Share[] memory arr) {
        arr = new Share[](1);
        arr[0] = Share({wallet: wallet, share: amount});
    }

    function _setSharesParams(uint64 id, Share[] memory shares_) internal pure returns (bytes memory) {
        return abi.encode(id, shares_);
    }

    function _wallets(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _claimParams(uint64 id, address[] memory wallets_) internal pure returns (bytes memory) {
        return abi.encode(id, wallets_);
    }

    function _claim(uint64 id, address[] memory wallets_) internal returns (uint32 exitCode, uint256[] memory amounts) {
        bytes memory data;
        (exitCode, data) = _call(CLAIM, _claimParams(id, wallets_));
        if (exitCode == 0) amounts = abi.decode(data, (uint256[]));
    }

    function _payableRow(LedgerRow[] memory rows, address wallet) internal pure returns (uint256) {
        for (uint256 i = 0; i < rows.length; i++) {
            if (rows[i].wallet == wallet) return rows[i].amount;
        }
        return 0;
    }

    // The objection window is 7 days; epochs are 30s.
    function test_SwaTimelock_IsSevenDaysOfEpochs() public pure {
        assertEq(SWA_TIMELOCK, 7 * 24 * 60 * 60 / 30);
    }

    function test_SwaTimelockEpochs_DefaultsToConstant() public view {
        assertEq(rewardActor().swaTimelockEpochs(), SWA_TIMELOCK);
    }

    function test_MockSwaTimelockEpochs_Overrides() public {
        rewardActor().mockSwaTimelockEpochs(10);

        // _registerParams hardcodes SWA_TIMELOCK, not the override, so build params directly.
        bytes memory params = abi.encode(
            SERVICE_ID, _constantRecord(0.1e18), DistributionKind.IMPLICIT, address(0), uint64(block.number) + 10
        );
        (uint32 exitCode,) = swaCaller.call(REGISTER_STREAM, params);
        assertEq(exitCode, 0);

        vm.roll(block.number + 10);
        assertEq(_streams().length, 1, "must settle after the overridden (short) hold");
    }

    // -------------------------------------------------------------------------
    // ClampWeight -- clamp(v_start + slope * (e - t_start), floor, cap). Not a dispatched
    // method; exposed directly.
    // -------------------------------------------------------------------------

    function _clampWeight(WeightRecord memory record, uint64 epoch) internal pure returns (int256) {
        return rewardActor().clampWeight(record, epoch);
    }

    function test_ClampWeight_AtTStart_ReturnsVStart() public pure {
        WeightRecord memory r = _record(0.95e18, -100, 1000, 0.5e18, 0.95e18);
        assertEq(_clampWeight(r, 1000), 0.95e18);
    }

    function test_ClampWeight_MidRamp_IsLinear() public pure {
        WeightRecord memory r = _record(0.95e18, -100, 1000, 0.5e18, 0.95e18);
        // 500 epochs after t_start: 0.95e18 - 100*500 = 0.95e18 - 50000
        assertEq(_clampWeight(r, 1500), 0.95e18 - 50_000);
    }

    function test_ClampWeight_PastFloor_ClampsToFloor() public pure {
        WeightRecord memory r = _record(0.95e18, -1e17, 1000, 0.5e18, 0.95e18);
        // 10 epochs after t_start at slope -1e17/epoch is already far past the 0.5e18 floor.
        assertEq(_clampWeight(r, 1010), 0.5e18);
    }

    function test_ClampWeight_BeforeTStart_ClampsToCap() public pure {
        // e < t_start with a negative slope means (e - t_start) < 0, so raw > v_start = cap.
        WeightRecord memory r = _record(0.95e18, -100, 1000, 0.5e18, 0.95e18);
        assertEq(_clampWeight(r, 0), 0.95e18);
    }

    function test_ClampWeight_ZeroSlope_IsConstant() public pure {
        WeightRecord memory r = _constantRecord(0.3e18);
        assertEq(_clampWeight(r, 0), 0.3e18);
        assertEq(_clampWeight(r, 1_000_000), 0.3e18);
    }

    function test_GetState_Empty_ReturnsNoStreams() public {
        assertEq(_streams().length, 0);
    }

    function test_GetState_ReflectsRegisteredStream_WithMatchingWeight() public {
        WeightRecord memory r = _constantRecord(0.4e18);
        assertEq(_registerStream(SERVICE_ID, r, DistributionKind.EXPLICIT, address(writerCaller)), 0);
        _warpPastTimelockAndSettle();

        StreamView[] memory streams = _streams();
        assertEq(streams.length, 1);
        assertEq(streams[0].id, SERVICE_ID);
        assertEq(streams[0].weightRecord.vStart, r.vStart);
        assertEq(uint8(streams[0].kind), uint8(DistributionKind.EXPLICIT));
        assertEq(streams[0].writer, address(writerCaller));
        assertEq(streams[0].weight, _clampWeight(r, uint64(block.number)));
        assertEq(streams[0].accrued, 0);
    }

    function test_RegisterStream_NotSwa_Forbidden() public {
        (uint32 exitCode,) = randomCaller.call(
            REGISTER_STREAM, _registerParams(SERVICE_ID, _constantRecord(0.1e18), DistributionKind.IMPLICIT, address(0))
        );
        assertEq(exitCode, USR_FORBIDDEN);
    }

    function test_RegisterStream_ActivationTooSoon_IllegalArgument() public {
        bytes memory params = abi.encode(
            SERVICE_ID,
            _constantRecord(0.1e18),
            DistributionKind.IMPLICIT,
            address(0),
            uint64(block.number) + SWA_TIMELOCK - 1
        );
        (uint32 exitCode,) = swaCaller.call(REGISTER_STREAM, params);
        assertEq(exitCode, USR_ILLEGAL_ARGUMENT);
    }

    function test_RegisterStream_FloorAboveCap_IllegalArgument() public {
        WeightRecord memory r = _record(0.1e18, 0, 0, 0.6e18, 0.5e18);
        assertEq(_registerStream(SERVICE_ID, r, DistributionKind.IMPLICIT, address(0)), USR_ILLEGAL_ARGUMENT);
    }

    function test_RegisterStream_CapAboveOne_IllegalArgument() public {
        WeightRecord memory r = _record(0.1e18, 0, 0, 0, WAD + 1);
        assertEq(_registerStream(SERVICE_ID, r, DistributionKind.IMPLICIT, address(0)), USR_ILLEGAL_ARGUMENT);
    }

    function test_RegisterStream_FloorBelowZero_IllegalArgument() public {
        WeightRecord memory r = _record(0.1e18, 0, 0, -1, WAD);
        assertEq(_registerStream(SERVICE_ID, r, DistributionKind.IMPLICIT, address(0)), USR_ILLEGAL_ARGUMENT);
    }

    function test_RegisterStream_ImplicitWithWriter_IllegalArgument() public {
        assertEq(
            _registerStream(SERVICE_ID, _constantRecord(0.1e18), DistributionKind.IMPLICIT, address(writerCaller)),
            USR_ILLEGAL_ARGUMENT
        );
    }

    function test_RegisterStream_ExplicitWithoutWriter_IllegalArgument() public {
        assertEq(
            _registerStream(SERVICE_ID, _constantRecord(0.1e18), DistributionKind.EXPLICIT, address(0)),
            USR_ILLEGAL_ARGUMENT
        );
    }

    function test_RegisterStream_DuplicateId_IllegalArgument() public {
        assertEq(_registerStream(SERVICE_ID, _constantRecord(0.1e18), DistributionKind.IMPLICIT, address(0)), 0);
        assertEq(
            _registerStream(SERVICE_ID, _constantRecord(0.1e18), DistributionKind.IMPLICIT, address(0)),
            USR_ILLEGAL_ARGUMENT
        );
    }

    function test_RegisterStream_AtMaxStreams_IllegalArgument() public {
        for (uint64 i = 0; i < MAX_STREAMS; i++) {
            assertEq(_registerStream(i, _constantRecord(0), DistributionKind.IMPLICIT, address(0)), 0);
        }
        uint64 oneMoreId = uint64(MAX_STREAMS);
        assertEq(
            _registerStream(oneMoreId, _constantRecord(0), DistributionKind.IMPLICIT, address(0)), USR_ILLEGAL_ARGUMENT
        );
    }

    function test_RegisterStream_SumWouldExceedOne_IllegalArgument() public {
        assertEq(_registerStream(SERVICE_ID, _constantRecord(0.6e18), DistributionKind.IMPLICIT, address(0)), 0);
        _warpPastTimelockAndSettle();
        assertEq(
            _registerStream(CONSENSUS_ID, _constantRecord(0.5e18), DistributionKind.IMPLICIT, address(0)),
            USR_ILLEGAL_ARGUMENT
        );
    }

    function test_RegisterStream_PendingUntilActivation() public {
        assertEq(_registerStream(SERVICE_ID, _constantRecord(0.1e18), DistributionKind.IMPLICIT, address(0)), 0);
        assertEq(_streams().length, 0, "stream must not be live before its activation epoch");

        _warpPastTimelockAndSettle();
        StreamView[] memory streams = _streams();
        assertEq(streams.length, 1);
        assertEq(streams[0].id, SERVICE_ID);
    }

    function test_RegisterStream_TombstonedId_IllegalArgument() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        (uint32 setSharesExit,) =
            writerCaller.call(SET_SHARES, _setSharesParams(SERVICE_ID, _shares(RECIPIENT_A, SHARE_TOTAL)));
        assertEq(setSharesExit, 0);
        vm.deal(address(rewardActor()), 1 ether);
        rewardActor().mockAwardBlockReward(1 ether); // 0.1 ether accrues, never claimed

        (uint32 removeExit,) = swaCaller.call(REMOVE_STREAM, abi.encode(SERVICE_ID));
        assertEq(removeExit, 0);
        _warpPastTimelockAndSettle();

        assertEq(_getState().tombstones.length, 1, "sanity: the outstanding payable produced a tombstone");

        // f02 rejects any id collision it can see, including an undrained tombstone.
        assertEq(
            _registerStream(SERVICE_ID, _constantRecord(0.1e18), DistributionKind.IMPLICIT, address(0)),
            USR_ILLEGAL_ARGUMENT
        );

        // Once the tombstone drains, the id is free again (f02 doesn't remember past that).
        _claim(SERVICE_ID, _wallets(RECIPIENT_A));
        assertEq(_registerStream(SERVICE_ID, _constantRecord(0.1e18), DistributionKind.IMPLICIT, address(0)), 0);
    }

    function _setWeightParams(uint64 id, WeightRecord memory record) internal pure returns (bytes memory) {
        uint64[] memory ids = new uint64[](1);
        ids[0] = id;
        WeightRecord[] memory records = new WeightRecord[](1);
        records[0] = record;
        return abi.encode(ids, records);
    }

    function test_SetWeightRecords_NotSwa_Forbidden() public {
        (uint32 exitCode,) =
            randomCaller.call(SET_WEIGHT_RECORDS, _setWeightParams(SERVICE_ID, _constantRecord(0.1e18)));
        assertEq(exitCode, USR_FORBIDDEN);
    }

    function test_SetWeightRecords_NonexistentStream_NotFound() public {
        (uint32 exitCode,) = swaCaller.call(SET_WEIGHT_RECORDS, _setWeightParams(SERVICE_ID, _constantRecord(0.1e18)));
        assertEq(exitCode, USR_NOT_FOUND);
    }

    function test_SetWeightRecords_MismatchedArrayLengths_IllegalArgument() public {
        uint64[] memory ids = new uint64[](2);
        WeightRecord[] memory records = new WeightRecord[](1);
        (uint32 exitCode,) = swaCaller.call(SET_WEIGHT_RECORDS, abi.encode(ids, records));
        assertEq(exitCode, USR_ILLEGAL_ARGUMENT);
    }

    function test_SetWeightRecords_InsaneRecord_IllegalArgument() public {
        assertEq(_registerStream(SERVICE_ID, _constantRecord(0.1e18), DistributionKind.IMPLICIT, address(0)), 0);
        _warpPastTimelockAndSettle();
        WeightRecord memory bad = _record(0, 0, 0, 0.9e18, 0.1e18); // floor > cap
        (uint32 exitCode,) = swaCaller.call(SET_WEIGHT_RECORDS, _setWeightParams(SERVICE_ID, bad));
        assertEq(exitCode, USR_ILLEGAL_ARGUMENT);
    }

    function test_SetWeightRecords_SumWouldExceedOne_IllegalArgument() public {
        assertEq(_registerStream(SERVICE_ID, _constantRecord(0.3e18), DistributionKind.IMPLICIT, address(0)), 0);
        assertEq(_registerStream(CONSENSUS_ID, _constantRecord(0.3e18), DistributionKind.IMPLICIT, address(0)), 0);
        _warpPastTimelockAndSettle();

        (uint32 exitCode,) = swaCaller.call(SET_WEIGHT_RECORDS, _setWeightParams(SERVICE_ID, _constantRecord(0.8e18)));
        assertEq(exitCode, USR_ILLEGAL_ARGUMENT);
    }

    function test_SetWeightRecords_QueuedUntilTimelockElapses() public {
        assertEq(_registerStream(SERVICE_ID, _constantRecord(0.1e18), DistributionKind.IMPLICIT, address(0)), 0);
        _warpPastTimelockAndSettle();

        (uint32 setExit,) = swaCaller.call(SET_WEIGHT_RECORDS, _setWeightParams(SERVICE_ID, _constantRecord(0.7e18)));
        assertEq(setExit, 0);

        StreamView[] memory before = _streams();
        assertEq(before[0].weightRecord.vStart, 0.1e18, "must not apply before the timelock elapses");

        _warpPastTimelockAndSettle();
        StreamView[] memory afterSettle = _streams();
        assertEq(afterSettle[0].weightRecord.vStart, 0.7e18);
    }

    // -------------------------------------------------------------------------
    // StepWeightRecords -- queued under its own (id, STEP_WEIGHT) slot, coexists with SetWeightRecords.
    // -------------------------------------------------------------------------

    function test_StepWeightRecords_NotSwa_Forbidden() public {
        (uint32 exitCode,) =
            randomCaller.call(STEP_WEIGHT_RECORDS, _setWeightParams(SERVICE_ID, _constantRecord(0.1e18)));
        assertEq(exitCode, USR_FORBIDDEN);
    }

    function test_StepWeightRecords_QueuedUntilTimelockElapses() public {
        assertEq(_registerStream(SERVICE_ID, _constantRecord(0.1e18), DistributionKind.IMPLICIT, address(0)), 0);
        _warpPastTimelockAndSettle();

        (uint32 setExit,) = swaCaller.call(STEP_WEIGHT_RECORDS, _setWeightParams(SERVICE_ID, _constantRecord(0.15e18)));
        assertEq(setExit, 0);
        assertEq(_streams()[0].weightRecord.vStart, 0.1e18, "must not apply before the timelock elapses");

        _warpPastTimelockAndSettle();
        assertEq(_streams()[0].weightRecord.vStart, 0.15e18);
    }

    function test_StepWeightRecords_And_SetWeightRecords_AreIndependentSlots() public {
        assertEq(_registerStream(SERVICE_ID, _constantRecord(0.1e18), DistributionKind.IMPLICIT, address(0)), 0);
        _warpPastTimelockAndSettle();

        // Both queue successfully: distinct (id, op) slots.
        (uint32 stepExit,) = swaCaller.call(STEP_WEIGHT_RECORDS, _setWeightParams(SERVICE_ID, _constantRecord(0.15e18)));
        assertEq(stepExit, 0);
        (uint32 setExit,) = swaCaller.call(SET_WEIGHT_RECORDS, _setWeightParams(SERVICE_ID, _constantRecord(0.2e18)));
        assertEq(setExit, 0);

        assertEq(_getState().pendingWrites.length, 2);
    }

    function test_StepWeightRecords_OccupiedSlot_IllegalArgument() public {
        assertEq(_registerStream(SERVICE_ID, _constantRecord(0.1e18), DistributionKind.IMPLICIT, address(0)), 0);
        _warpPastTimelockAndSettle();

        (uint32 firstExit,) =
            swaCaller.call(STEP_WEIGHT_RECORDS, _setWeightParams(SERVICE_ID, _constantRecord(0.15e18)));
        assertEq(firstExit, 0);
        (uint32 secondExit,) =
            swaCaller.call(STEP_WEIGHT_RECORDS, _setWeightParams(SERVICE_ID, _constantRecord(0.2e18)));
        assertEq(secondExit, USR_ILLEGAL_ARGUMENT, "revising a pending write is cancel + requeue, not a second queue");
    }

    function test_SetShares_NotWriter_Forbidden() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        (uint32 exitCode,) =
            randomCaller.call(SET_SHARES, _setSharesParams(SERVICE_ID, _shares(RECIPIENT_A, SHARE_TOTAL)));
        assertEq(exitCode, USR_FORBIDDEN);
    }

    function test_SetShares_NonexistentStream_NotFound() public {
        (uint32 exitCode,) =
            writerCaller.call(SET_SHARES, _setSharesParams(SERVICE_ID, _shares(RECIPIENT_A, SHARE_TOTAL)));
        assertEq(exitCode, USR_NOT_FOUND);
    }

    function test_SetShares_ImplicitStream_IllegalArgument() public {
        assertEq(_registerStream(CONSENSUS_ID, _constantRecord(0.1e18), DistributionKind.IMPLICIT, address(0)), 0);
        _warpPastTimelockAndSettle();
        (uint32 exitCode,) =
            randomCaller.call(SET_SHARES, _setSharesParams(CONSENSUS_ID, _shares(RECIPIENT_A, SHARE_TOTAL)));
        assertEq(exitCode, USR_ILLEGAL_ARGUMENT);
    }

    function test_SetShares_DoesNotSumToOne_IllegalArgument() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        (uint32 under,) =
            writerCaller.call(SET_SHARES, _setSharesParams(SERVICE_ID, _shares(RECIPIENT_A, SHARE_TOTAL - 1)));
        assertEq(under, USR_ILLEGAL_ARGUMENT);
        (uint32 over,) =
            writerCaller.call(SET_SHARES, _setSharesParams(SERVICE_ID, _shares(RECIPIENT_A, SHARE_TOTAL + 1)));
        assertEq(over, USR_ILLEGAL_ARGUMENT);
    }

    function test_SetShares_TooManyRecipients_IllegalArgument() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        uint256 n = MAX_RECIPIENTS + 1;
        Share[] memory shares_ = new Share[](n);
        for (uint256 i = 0; i < n; i++) {
            shares_[i] = Share({wallet: address(uint160(i + 1)), share: SHARE_TOTAL / n});
        }
        (uint32 exitCode,) = writerCaller.call(SET_SHARES, _setSharesParams(SERVICE_ID, shares_));
        assertEq(exitCode, USR_ILLEGAL_ARGUMENT);
    }

    function test_SetShares_Valid_AppliesImmediately_NoTimelock() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        Share[] memory shares_ = _shares(RECIPIENT_A, SHARE_TOTAL);
        (uint32 exitCode,) = writerCaller.call(SET_SHARES, _setSharesParams(SERVICE_ID, shares_));
        assertEq(exitCode, 0);

        // No vm.roll here: SetShares is the writer's own write, not queued under the timelock.
        Share[] memory got = rewardActor().getShares(SERVICE_ID);
        assertEq(got.length, 1);
        assertEq(got[0].wallet, RECIPIENT_A);
        assertEq(got[0].share, SHARE_TOTAL);
    }

    function test_SetShares_FoldsAccruedIntoPayable_AndBurnsResidue() public {
        _registerExplicit(SERVICE_ID, address(writerCaller)); // weight 0.1e18
        (uint32 firstSetExit,) =
            writerCaller.call(SET_SHARES, _setSharesParams(SERVICE_ID, _shares(RECIPIENT_A, SHARE_TOTAL)));
        assertEq(firstSetExit, 0);

        vm.deal(address(rewardActor()), 1 ether);
        rewardActor().mockAwardBlockReward(1 ether); // service accrues 0.1 ether

        uint256 burnBefore = BURN_ADDRESS.balance;
        (uint32 exitCode,) =
            writerCaller.call(SET_SHARES, _setSharesParams(SERVICE_ID, _shares(RECIPIENT_B, SHARE_TOTAL)));
        assertEq(exitCode, 0);

        // Sole recipient held 100%, so folding leaves no rounding residue.
        LedgerRow[] memory payableRows = rewardActor().getPayable(SERVICE_ID);
        assertEq(_payableRow(payableRows, RECIPIENT_A), 0.1 ether);
        assertEq(BURN_ADDRESS.balance, burnBefore, "an exact 100% share leaves no rounding dust to burn");
        assertEq(_streams()[0].accrued, 0, "accrual resets after the fold");

        // New map installed for the next period.
        Share[] memory got = rewardActor().getShares(SERVICE_ID);
        assertEq(got[0].wallet, RECIPIENT_B);
    }

    function test_RemoveStream_NotSwa_Forbidden() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        (uint32 exitCode,) = randomCaller.call(REMOVE_STREAM, abi.encode(SERVICE_ID));
        assertEq(exitCode, USR_FORBIDDEN);
    }

    function test_RemoveStream_Nonexistent_NotFound() public {
        (uint32 exitCode,) = swaCaller.call(REMOVE_STREAM, abi.encode(SERVICE_ID));
        assertEq(exitCode, USR_NOT_FOUND);
    }

    function test_RemoveStream_QueuedThenRemoved_AndSharesCleared() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        (uint32 setExit,) =
            writerCaller.call(SET_SHARES, _setSharesParams(SERVICE_ID, _shares(RECIPIENT_A, SHARE_TOTAL)));
        assertEq(setExit, 0);

        (uint32 removeExit,) = swaCaller.call(REMOVE_STREAM, abi.encode(SERVICE_ID));
        assertEq(removeExit, 0);
        assertEq(_streams().length, 1, "must still be live before the timelock elapses");

        _warpPastTimelockAndSettle();
        assertEq(_streams().length, 0);
        assertEq(rewardActor().getShares(SERVICE_ID).length, 0);
    }

    function test_RemoveStream_NoOutstandingPayable_NoTombstoneCreated() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        (uint32 removeExit,) = swaCaller.call(REMOVE_STREAM, abi.encode(SERVICE_ID));
        assertEq(removeExit, 0);
        _warpPastTimelockAndSettle();

        assertEq(_getState().tombstones.length, 0, "nothing was ever owed, so nothing needs to stay addressable");
    }

    function test_RemoveStream_OutstandingPayable_MovesToTombstone_ClaimableAfterRemoval() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        (uint32 setSharesExit,) =
            writerCaller.call(SET_SHARES, _setSharesParams(SERVICE_ID, _shares(RECIPIENT_A, SHARE_TOTAL)));
        assertEq(setSharesExit, 0);

        vm.deal(address(rewardActor()), 1 ether);
        rewardActor().mockAwardBlockReward(1 ether); // 0.1 ether accrues, never claimed

        (uint32 removeExit,) = swaCaller.call(REMOVE_STREAM, abi.encode(SERVICE_ID));
        assertEq(removeExit, 0);
        _warpPastTimelockAndSettle();

        assertEq(_streams().length, 0);
        TombstoneView[] memory tombstones = _getState().tombstones;
        assertEq(tombstones.length, 1);
        assertEq(tombstones[0].id, SERVICE_ID);
        assertEq(_payableRow(tombstones[0].payableRows, RECIPIENT_A), 0.1 ether);

        (uint32 claimExit, uint256[] memory amounts) = _claim(SERVICE_ID, _wallets(RECIPIENT_A));
        assertEq(claimExit, 0);
        assertEq(amounts[0], 0.1 ether);
        assertEq(RECIPIENT_A.balance, 0.1 ether);

        // Fully claimed: the tombstone drains and deletes.
        assertEq(_getState().tombstones.length, 0);
    }

    function test_SetDistribution_NotSwa_Forbidden() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        (uint32 exitCode,) = randomCaller.call(
            SET_DISTRIBUTION, abi.encode(SERVICE_ID, DistributionKind.EXPLICIT, address(otherWriterCaller))
        );
        assertEq(exitCode, USR_FORBIDDEN);
    }

    function test_SetDistribution_ToImplicit_IllegalArgument() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        (uint32 exitCode,) =
            swaCaller.call(SET_DISTRIBUTION, abi.encode(SERVICE_ID, DistributionKind.IMPLICIT, address(0)));
        assertEq(exitCode, USR_ILLEGAL_ARGUMENT);
    }

    function test_SetDistribution_ZeroWriter_IllegalArgument() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        (uint32 exitCode,) =
            swaCaller.call(SET_DISTRIBUTION, abi.encode(SERVICE_ID, DistributionKind.EXPLICIT, address(0)));
        assertEq(exitCode, USR_ILLEGAL_ARGUMENT);
    }

    // The stream's current wallet-to-share map remains in force until the new writer
    // overwrites it via SetShares, so payments continue across the transition.
    function test_SetDistribution_OldWriterStaysAuthorizedUntilTimelockElapses() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        (uint32 initialSet,) =
            writerCaller.call(SET_SHARES, _setSharesParams(SERVICE_ID, _shares(RECIPIENT_A, SHARE_TOTAL)));
        assertEq(initialSet, 0);

        (uint32 distExit,) = swaCaller.call(
            SET_DISTRIBUTION, abi.encode(SERVICE_ID, DistributionKind.EXPLICIT, address(otherWriterCaller))
        );
        assertEq(distExit, 0);

        // Before the timelock elapses: old writer still authorized, new writer is not.
        (uint32 oldWriterExit,) =
            writerCaller.call(SET_SHARES, _setSharesParams(SERVICE_ID, _shares(RECIPIENT_B, SHARE_TOTAL)));
        assertEq(oldWriterExit, 0);
        (uint32 newWriterExitTooEarly,) =
            otherWriterCaller.call(SET_SHARES, _setSharesParams(SERVICE_ID, _shares(address(0xF00D), SHARE_TOTAL)));
        assertEq(newWriterExitTooEarly, USR_FORBIDDEN);

        _warpPastTimelockAndSettle();

        // After the timelock elapses: roles have swapped.
        (uint32 oldWriterExitTooLate,) =
            writerCaller.call(SET_SHARES, _setSharesParams(SERVICE_ID, _shares(address(0xF00D), SHARE_TOTAL)));
        assertEq(oldWriterExitTooLate, USR_FORBIDDEN);
        (uint32 newWriterExit,) =
            otherWriterCaller.call(SET_SHARES, _setSharesParams(SERVICE_ID, _shares(address(0xF00D), SHARE_TOTAL)));
        assertEq(newWriterExit, 0);
        assertEq(rewardActor().getShares(SERVICE_ID)[0].wallet, address(0xF00D));
    }

    function test_SetDistribution_ApplyFoldsAccruedIntoPayable() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        (uint32 setSharesExit,) =
            writerCaller.call(SET_SHARES, _setSharesParams(SERVICE_ID, _shares(RECIPIENT_A, SHARE_TOTAL)));
        assertEq(setSharesExit, 0);

        vm.deal(address(rewardActor()), 1 ether);
        rewardActor().mockAwardBlockReward(1 ether); // 0.1 ether accrues under RECIPIENT_A

        (uint32 distExit,) = swaCaller.call(
            SET_DISTRIBUTION, abi.encode(SERVICE_ID, DistributionKind.EXPLICIT, address(otherWriterCaller))
        );
        assertEq(distExit, 0);
        _warpPastTimelockAndSettle();

        assertEq(_payableRow(rewardActor().getPayable(SERVICE_ID), RECIPIENT_A), 0.1 ether);
        assertEq(_streams()[0].accrued, 0);
        // The share map itself is untouched by the writer change.
        assertEq(rewardActor().getShares(SERVICE_ID)[0].wallet, RECIPIENT_A);
    }

    function test_CancelPending_NotSwa_Forbidden() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        (uint32 setExit,) = swaCaller.call(SET_WEIGHT_RECORDS, _setWeightParams(SERVICE_ID, _constantRecord(0.9e18)));
        assertEq(setExit, 0);
        (uint32 exitCode,) = randomCaller.call(CANCEL_PENDING, abi.encode(SERVICE_ID, PendingOp.SET_WEIGHT));
        assertEq(exitCode, USR_FORBIDDEN);
    }

    // Cancelling a slot with nothing queued must succeed as a no-op, not error.
    function test_CancelPending_EmptySlot_BenignNoOp() public {
        (uint32 exitCode,) = swaCaller.call(CANCEL_PENDING, abi.encode(SERVICE_ID, PendingOp.SET_WEIGHT));
        assertEq(exitCode, 0);
    }

    function test_CancelPending_DiscardsQueuedSetWeightRecords() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        (uint32 setExit,) = swaCaller.call(SET_WEIGHT_RECORDS, _setWeightParams(SERVICE_ID, _constantRecord(0.9e18)));
        assertEq(setExit, 0);

        (uint32 cancelExit,) = swaCaller.call(CANCEL_PENDING, abi.encode(SERVICE_ID, PendingOp.SET_WEIGHT));
        assertEq(cancelExit, 0);

        _warpPastTimelockAndSettle();
        assertEq(_streams()[0].weightRecord.vStart, 0.1e18, "cancelled write must never apply");
    }

    function test_CancelPending_DiscardsQueuedRegisterStream() public {
        assertEq(_registerStream(SERVICE_ID, _constantRecord(0.1e18), DistributionKind.IMPLICIT, address(0)), 0);
        (uint32 cancelExit,) = swaCaller.call(CANCEL_PENDING, abi.encode(SERVICE_ID, PendingOp.REGISTER));
        assertEq(cancelExit, 0);

        _warpPastTimelockAndSettle();
        assertEq(_streams().length, 0, "cancelled registration must never take effect");
    }

    function test_CancelPending_DiscardsQueuedRemoveStream() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        (uint32 removeExit,) = swaCaller.call(REMOVE_STREAM, abi.encode(SERVICE_ID));
        assertEq(removeExit, 0);

        (uint32 cancelExit,) = swaCaller.call(CANCEL_PENDING, abi.encode(SERVICE_ID, PendingOp.REMOVE));
        assertEq(cancelExit, 0);

        _warpPastTimelockAndSettle();
        assertEq(_streams().length, 1, "cancelled removal must never take effect");
    }

    // "No cancel path" is SWA-side discipline; f02 itself treats every op uniformly.
    function test_CancelPending_StepWeightRecords_IsCancellableLikeAnyOtherOp() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        (uint32 stepExit,) = swaCaller.call(STEP_WEIGHT_RECORDS, _setWeightParams(SERVICE_ID, _constantRecord(0.9e18)));
        assertEq(stepExit, 0);

        (uint32 cancelExit,) = swaCaller.call(CANCEL_PENDING, abi.encode(SERVICE_ID, PendingOp.STEP_WEIGHT));
        assertEq(cancelExit, 0);

        _warpPastTimelockAndSettle();
        assertEq(_streams()[0].weightRecord.vStart, 0.1e18);
    }

    function test_CancelPending_OnlyCancelsMatchingOp() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        (uint32 setExit,) = swaCaller.call(SET_WEIGHT_RECORDS, _setWeightParams(SERVICE_ID, _constantRecord(0.5e18)));
        assertEq(setExit, 0);
        (uint32 stepExit,) = swaCaller.call(STEP_WEIGHT_RECORDS, _setWeightParams(SERVICE_ID, _constantRecord(0.6e18)));
        assertEq(stepExit, 0);

        (uint32 cancelExit,) = swaCaller.call(CANCEL_PENDING, abi.encode(SERVICE_ID, PendingOp.SET_WEIGHT));
        assertEq(cancelExit, 0);

        _warpPastTimelockAndSettle();
        // SET_WEIGHT was cancelled; STEP_WEIGHT still applied.
        assertEq(_streams()[0].weightRecord.vStart, 0.6e18);
    }

    function test_Claim_NonexistentStream_NotFound() public {
        (uint32 exitCode,) = _claim(SERVICE_ID, _wallets(RECIPIENT_A));
        assertEq(exitCode, USR_NOT_FOUND);
    }

    function test_Claim_ImplicitStream_IllegalArgument() public {
        assertEq(_registerStream(CONSENSUS_ID, _constantRecord(0.1e18), DistributionKind.IMPLICIT, address(0)), 0);
        _warpPastTimelockAndSettle();
        (uint32 exitCode,) = _claim(CONSENSUS_ID, _wallets(RECIPIENT_A));
        assertEq(exitCode, USR_ILLEGAL_ARGUMENT);
    }

    function test_Claim_UnknownWallet_ReturnsZero_NoRevert() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        (uint32 setSharesExit,) =
            writerCaller.call(SET_SHARES, _setSharesParams(SERVICE_ID, _shares(RECIPIENT_A, SHARE_TOTAL)));
        assertEq(setSharesExit, 0);

        (uint32 exitCode, uint256[] memory amounts) = _claim(SERVICE_ID, _wallets(RECIPIENT_B));
        assertEq(exitCode, 0, "an all-zero batch is a benign no-op success");
        assertEq(amounts[0], 0);
    }

    function test_Claim_PaysLiveAccrual() public {
        _registerExplicit(SERVICE_ID, address(writerCaller)); // weight 0.1e18
        (uint32 setSharesExit,) =
            writerCaller.call(SET_SHARES, _setSharesParams(SERVICE_ID, _shares(RECIPIENT_A, SHARE_TOTAL)));
        assertEq(setSharesExit, 0);

        vm.deal(address(rewardActor()), 1 ether);
        rewardActor().mockAwardBlockReward(1 ether); // service accrues 0.1 ether

        (uint32 exitCode, uint256[] memory amounts) = _claim(SERVICE_ID, _wallets(RECIPIENT_A));
        assertEq(exitCode, 0);
        assertEq(amounts[0], 0.1 ether);
        assertEq(RECIPIENT_A.balance, 0.1 ether);
        assertEq(_streams()[0].accrued, 0.1 ether, "accrued is a period gross total, unaffected by claims");

        // A second claim in the same period pays nothing further: claimed_period tracks it.
        (, uint256[] memory secondAmounts) = _claim(SERVICE_ID, _wallets(RECIPIENT_A));
        assertEq(secondAmounts[0], 0);
        assertEq(RECIPIENT_A.balance, 0.1 ether);
    }

    function test_Claim_PaysPayablePlusLive() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        (uint32 firstSetExit,) =
            writerCaller.call(SET_SHARES, _setSharesParams(SERVICE_ID, _shares(RECIPIENT_A, SHARE_TOTAL)));
        assertEq(firstSetExit, 0);

        vm.deal(address(rewardActor()), 2 ether);
        rewardActor().mockAwardBlockReward(1 ether); // 0.1 ether accrues, never claimed

        // Fold the period (via a new SetShares) so the 0.1 ether moves into payable.
        (uint32 secondSetExit,) =
            writerCaller.call(SET_SHARES, _setSharesParams(SERVICE_ID, _shares(RECIPIENT_A, SHARE_TOTAL)));
        assertEq(secondSetExit, 0);
        assertEq(_payableRow(rewardActor().getPayable(SERVICE_ID), RECIPIENT_A), 0.1 ether);

        rewardActor().mockAwardBlockReward(1 ether); // another 0.1 ether accrues, live this period

        (uint32 exitCode, uint256[] memory amounts) = _claim(SERVICE_ID, _wallets(RECIPIENT_A));
        assertEq(exitCode, 0);
        assertEq(amounts[0], 0.2 ether, "payable (closed period) plus live (current period)");
        assertEq(RECIPIENT_A.balance, 0.2 ether);
        assertEq(rewardActor().getPayable(SERVICE_ID).length, 0, "claimed payable row drops");
    }

    function test_AwardBlockReward_SplitsAcrossMinerAndService_ConservationHolds() public {
        assertEq(_registerStream(CONSENSUS_ID, _constantRecord(0.85e18), DistributionKind.IMPLICIT, address(0)), 0);
        assertEq(
            _registerStream(SERVICE_ID, _constantRecord(0.1e18), DistributionKind.EXPLICIT, address(writerCaller)), 0
        );
        _warpPastTimelockAndSettle();

        vm.deal(address(rewardActor()), 1 ether);
        (uint256 minerPortion, uint256 servicePortion, uint256 burnAmount) = rewardActor().mockAwardBlockReward(1 ether);

        assertEq(minerPortion, 0.85 ether);
        assertEq(servicePortion, 0.1 ether);
        assertEq(burnAmount, 0.05 ether);
        assertEq(minerPortion + servicePortion + burnAmount, 1 ether, "conservation: BR = miner + service + burn");

        assertEq(rewardActor().totalMintedReward(), 1 ether);
        assertEq(rewardActor().totalBurnMinted(), 0.05 ether);
        assertEq(rewardActor().totalServiceMinted(), 0.1 ether);
        // M = T - B - S is derived, never stored.
        assertEq(
            rewardActor().totalMintedReward() - rewardActor().totalBurnMinted() - rewardActor().totalServiceMinted(),
            minerPortion
        );
        assertEq(BURN_ADDRESS.balance, 0.05 ether);
    }

    function test_AwardBlockReward_NoStreams_AllBurn() public {
        vm.deal(address(rewardActor()), 1 ether);
        (uint256 minerPortion, uint256 servicePortion, uint256 burnAmount) = rewardActor().mockAwardBlockReward(1 ether);
        assertEq(minerPortion, 0);
        assertEq(servicePortion, 0);
        assertEq(burnAmount, 1 ether);
        assertEq(BURN_ADDRESS.balance, 1 ether);
    }

    // -------------------------------------------------------------------------
    // Fidelity: native-actor fallback and precompile guard
    // -------------------------------------------------------------------------

    // A native actor: direct EVM CALL fails with USR_UNHANDLED_MESSAGE, not like an account actor.
    function test_DirectEvmCall_ReturnsUnhandledMessage() public {
        (bool ok, bytes memory ret) = REWARD_ACTOR_ADDRESS.call("");
        assertTrue(ok);
        (uint32 exitCode,,) = abi.decode(ret, (uint32, uint64, bytes));
        assertEq(exitCode, USR_UNHANDLED_MESSAGE);
    }

    // The real precompile requires delegatecall; a direct call/staticcall must fail.
    function test_DirectCallToPrecompile_Reverts() public {
        (bool ok,) = CALL_ACTOR_BY_ID.call("");
        assertFalse(ok);
    }

    // -------------------------------------------------------------------------
    // Regression: FVMCallActorByIdWithReward must not break existing actor mocks
    // -------------------------------------------------------------------------

    // Exercises _handleBurn's balance debit through the new dispatcher -- would break if the
    // forward to FVMCallActorById used `call` instead of `delegatecall`.
    function test_Regression_Burn_StillDebitsCallerBalance() public {
        uint256 before = address(this).balance;
        assertEq(BURN_ADDRESS.balance, 0);
        BURN_ACTOR_ID.pay(10 ether);
        assertEq(BURN_ADDRESS.balance, 10 ether);
        assertEq(address(this).balance, before - 10 ether);
    }

    // Exercises the storage power actor branch (_handlePower) through the new dispatcher.
    function test_Regression_MinerPower_StillWorks() public {
        mockMiner(555);
        assertTrue(FVMMiner.isMiner(555));
        assertFalse(FVMMiner.isMiner(556));
    }
}
