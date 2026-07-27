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
    WAD,
    MAX_STREAMS,
    MAX_RECIPIENTS,
    SHARE_TOTAL
} from "./FVMRewardActor.sol";
import {
    SET_WEIGHT_RECORDS,
    SET_SHARES,
    GET_STATE,
    REGISTER_STREAM,
    REMOVE_STREAM,
    SET_DISTRIBUTION,
    CANCEL_PENDING,
    COMPUTE_WEIGHT,
    SWA_TIMELOCK
} from "./FVMRewardMethod.sol";

/// @dev A distinct external caller, so a test can give SWA / stream-writer authorization to
/// an address other than the test contract itself and check that authorization is enforced
/// by identity, not by happenstance of who the test contract is.
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

    function _warpPastTimelockAndSettle() internal {
        vm.roll(block.number + SWA_TIMELOCK);
        _call(GET_STATE, ""); // any dispatched call settles pending writes
    }

    function _getState()
        internal
        returns (
            uint64[] memory ids,
            WeightRecord[] memory records,
            DistributionKind[] memory kinds,
            address[] memory writers,
            int256[] memory weights
        )
    {
        (uint32 exitCode, bytes memory data) = _call(GET_STATE, "");
        assertEq(exitCode, 0);
        (ids, records, kinds, writers, weights) =
            abi.decode(data, (uint64[], WeightRecord[], DistributionKind[], address[], int256[]));
    }

    // -------------------------------------------------------------------------
    // SWA_TIMELOCK
    // -------------------------------------------------------------------------

    // FIP-0118 section 2.4/4: the objection window is 7 days; epochs are 30s.
    function test_SwaTimelock_IsSevenDaysOfEpochs() public pure {
        assertEq(SWA_TIMELOCK, 7 * 24 * 60 * 60 / 30);
    }

    // -------------------------------------------------------------------------
    // ComputeWeight -- clamp(v_start + slope * (e - t_start), floor, cap)
    // -------------------------------------------------------------------------

    function _computeWeight(WeightRecord memory record, uint64 epoch) internal returns (int256) {
        (uint32 exitCode, bytes memory data) = _call(COMPUTE_WEIGHT, abi.encode(record, epoch));
        assertEq(exitCode, 0);
        return abi.decode(data, (int256));
    }

    function test_ComputeWeight_AtTStart_ReturnsVStart() public {
        WeightRecord memory r = _record(0.95e18, -100, 1000, 0.5e18, 0.95e18);
        assertEq(_computeWeight(r, 1000), 0.95e18);
    }

    function test_ComputeWeight_MidRamp_IsLinear() public {
        WeightRecord memory r = _record(0.95e18, -100, 1000, 0.5e18, 0.95e18);
        // 500 epochs after t_start: 0.95e18 - 100*500 = 0.95e18 - 50000
        assertEq(_computeWeight(r, 1500), 0.95e18 - 50_000);
    }

    function test_ComputeWeight_PastFloor_ClampsToFloor() public {
        WeightRecord memory r = _record(0.95e18, -1e17, 1000, 0.5e18, 0.95e18);
        // 10 epochs after t_start at slope -1e17/epoch is already far past the 0.5e18 floor.
        assertEq(_computeWeight(r, 1010), 0.5e18);
    }

    function test_ComputeWeight_BeforeTStart_ClampsToCap() public {
        // e < t_start with a negative slope means (e - t_start) < 0, so raw > v_start = cap.
        WeightRecord memory r = _record(0.95e18, -100, 1000, 0.5e18, 0.95e18);
        assertEq(_computeWeight(r, 0), 0.95e18);
    }

    function test_ComputeWeight_ZeroSlope_IsConstant() public {
        WeightRecord memory r = _constantRecord(0.3e18);
        assertEq(_computeWeight(r, 0), 0.3e18);
        assertEq(_computeWeight(r, 1_000_000), 0.3e18);
    }

    // -------------------------------------------------------------------------
    // GetState
    // -------------------------------------------------------------------------

    function test_GetState_Empty_ReturnsNoStreams() public {
        (uint64[] memory ids,,,,) = _getState();
        assertEq(ids.length, 0);
    }

    function test_GetState_ReflectsRegisteredStream_WithMatchingWeight() public {
        WeightRecord memory r = _constantRecord(0.4e18);
        assertEq(_registerStream(SERVICE_ID, r, DistributionKind.EXPLICIT, address(writerCaller)), 0);
        _warpPastTimelockAndSettle();

        (
            uint64[] memory ids,
            WeightRecord[] memory records,
            DistributionKind[] memory kinds,
            address[] memory writers,
            int256[] memory weights
        ) = _getState();
        assertEq(ids.length, 1);
        assertEq(ids[0], SERVICE_ID);
        assertEq(records[0].vStart, r.vStart);
        assertEq(uint8(kinds[0]), uint8(DistributionKind.EXPLICIT));
        assertEq(writers[0], address(writerCaller));
        assertEq(weights[0], _computeWeight(r, uint64(block.number)));
    }

    // -------------------------------------------------------------------------
    // RegisterStream
    // -------------------------------------------------------------------------

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
        (uint64[] memory ids,,,,) = _getState();
        assertEq(ids.length, 0, "stream must not be live before its activation epoch");

        _warpPastTimelockAndSettle();
        (uint64[] memory idsAfter,,,,) = _getState();
        assertEq(idsAfter.length, 1);
        assertEq(idsAfter[0], SERVICE_ID);
    }

    // -------------------------------------------------------------------------
    // SetWeightRecords
    // -------------------------------------------------------------------------

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

        (, WeightRecord[] memory recordsBefore,,,) = _getState();
        assertEq(recordsBefore[0].vStart, 0.1e18, "must not apply before the timelock elapses");

        _warpPastTimelockAndSettle();
        (, WeightRecord[] memory recordsAfter,,,) = _getState();
        assertEq(recordsAfter[0].vStart, 0.7e18);
    }

    // -------------------------------------------------------------------------
    // SetShares
    // -------------------------------------------------------------------------

    function _shares(address wallet, uint256 amount) internal pure returns (Share[] memory arr) {
        arr = new Share[](1);
        arr[0] = Share({wallet: wallet, share: amount});
    }

    function _setSharesParams(uint64 id, Share[] memory shares_) internal pure returns (bytes memory) {
        return abi.encode(id, shares_);
    }

    function _registerExplicit(uint64 id, address writer) internal {
        assertEq(_registerStream(id, _constantRecord(0.1e18), DistributionKind.EXPLICIT, writer), 0);
        _warpPastTimelockAndSettle();
    }

    function test_SetShares_NotWriter_Forbidden() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        (uint32 exitCode,) =
            randomCaller.call(SET_SHARES, _setSharesParams(SERVICE_ID, _shares(address(0xBEEF), SHARE_TOTAL)));
        assertEq(exitCode, USR_FORBIDDEN);
    }

    function test_SetShares_NonexistentStream_NotFound() public {
        (uint32 exitCode,) =
            writerCaller.call(SET_SHARES, _setSharesParams(SERVICE_ID, _shares(address(0xBEEF), SHARE_TOTAL)));
        assertEq(exitCode, USR_NOT_FOUND);
    }

    function test_SetShares_ImplicitStream_IllegalArgument() public {
        assertEq(_registerStream(CONSENSUS_ID, _constantRecord(0.1e18), DistributionKind.IMPLICIT, address(0)), 0);
        _warpPastTimelockAndSettle();
        (uint32 exitCode,) =
            randomCaller.call(SET_SHARES, _setSharesParams(CONSENSUS_ID, _shares(address(0xBEEF), SHARE_TOTAL)));
        assertEq(exitCode, USR_ILLEGAL_ARGUMENT);
    }

    function test_SetShares_DoesNotSumToOne_IllegalArgument() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        (uint32 under,) =
            writerCaller.call(SET_SHARES, _setSharesParams(SERVICE_ID, _shares(address(0xBEEF), SHARE_TOTAL - 1)));
        assertEq(under, USR_ILLEGAL_ARGUMENT);
        (uint32 over,) =
            writerCaller.call(SET_SHARES, _setSharesParams(SERVICE_ID, _shares(address(0xBEEF), SHARE_TOTAL + 1)));
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
        Share[] memory shares_ = _shares(address(0xBEEF), SHARE_TOTAL);
        (uint32 exitCode,) = writerCaller.call(SET_SHARES, _setSharesParams(SERVICE_ID, shares_));
        assertEq(exitCode, 0);

        // No vm.roll here: SetShares is the writer's own write, not queued under SWA_TIMELOCK.
        Share[] memory got = rewardActor().getShares(SERVICE_ID);
        assertEq(got.length, 1);
        assertEq(got[0].wallet, address(0xBEEF));
        assertEq(got[0].share, SHARE_TOTAL);
    }

    // -------------------------------------------------------------------------
    // RemoveStream
    // -------------------------------------------------------------------------

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
            writerCaller.call(SET_SHARES, _setSharesParams(SERVICE_ID, _shares(address(0xBEEF), SHARE_TOTAL)));
        assertEq(setExit, 0);

        (uint32 removeExit,) = swaCaller.call(REMOVE_STREAM, abi.encode(SERVICE_ID));
        assertEq(removeExit, 0);

        (uint64[] memory idsBefore,,,,) = _getState();
        assertEq(idsBefore.length, 1, "must still be live before the timelock elapses");

        _warpPastTimelockAndSettle();
        (uint64[] memory idsAfter,,,,) = _getState();
        assertEq(idsAfter.length, 0);
        assertEq(rewardActor().getShares(SERVICE_ID).length, 0);
    }

    // -------------------------------------------------------------------------
    // SetDistribution
    // -------------------------------------------------------------------------

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

    // FIP-0118 2.4 item 9: "The stream's current wallet-to-share map remains in force until
    // the new writer overwrites it via SetShares, so payments continue across the transition."
    function test_SetDistribution_OldWriterStaysAuthorizedUntilTimelockElapses() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        (uint32 initialSet,) =
            writerCaller.call(SET_SHARES, _setSharesParams(SERVICE_ID, _shares(address(0xBEEF), SHARE_TOTAL)));
        assertEq(initialSet, 0);

        (uint32 distExit,) = swaCaller.call(
            SET_DISTRIBUTION, abi.encode(SERVICE_ID, DistributionKind.EXPLICIT, address(otherWriterCaller))
        );
        assertEq(distExit, 0);

        // Before the timelock elapses: old writer still authorized, new writer is not, and
        // the existing map (from initialSet) is untouched.
        (uint32 oldWriterExit,) =
            writerCaller.call(SET_SHARES, _setSharesParams(SERVICE_ID, _shares(address(0xCAFE), SHARE_TOTAL)));
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

    // -------------------------------------------------------------------------
    // CancelPending
    // -------------------------------------------------------------------------

    function test_CancelPending_NotSwa_Forbidden() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        (uint32 setExit,) = swaCaller.call(SET_WEIGHT_RECORDS, _setWeightParams(SERVICE_ID, _constantRecord(0.9e18)));
        assertEq(setExit, 0);
        (uint32 exitCode,) = randomCaller.call(CANCEL_PENDING, abi.encode(SERVICE_ID));
        assertEq(exitCode, USR_FORBIDDEN);
    }

    function test_CancelPending_NoPending_NotFound() public {
        (uint32 exitCode,) = swaCaller.call(CANCEL_PENDING, abi.encode(SERVICE_ID));
        assertEq(exitCode, USR_NOT_FOUND);
    }

    function test_CancelPending_DiscardsQueuedSetWeightRecords() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        (uint32 setExit,) = swaCaller.call(SET_WEIGHT_RECORDS, _setWeightParams(SERVICE_ID, _constantRecord(0.9e18)));
        assertEq(setExit, 0);

        (uint32 cancelExit,) = swaCaller.call(CANCEL_PENDING, abi.encode(SERVICE_ID));
        assertEq(cancelExit, 0);

        _warpPastTimelockAndSettle();
        (, WeightRecord[] memory records,,,) = _getState();
        assertEq(records[0].vStart, 0.1e18, "cancelled write must never apply");
    }

    function test_CancelPending_DiscardsQueuedRegisterStream() public {
        assertEq(_registerStream(SERVICE_ID, _constantRecord(0.1e18), DistributionKind.IMPLICIT, address(0)), 0);
        (uint32 cancelExit,) = swaCaller.call(CANCEL_PENDING, abi.encode(SERVICE_ID));
        assertEq(cancelExit, 0);

        _warpPastTimelockAndSettle();
        (uint64[] memory ids,,,,) = _getState();
        assertEq(ids.length, 0, "cancelled registration must never take effect");
    }

    function test_CancelPending_DiscardsQueuedRemoveStream() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        (uint32 removeExit,) = swaCaller.call(REMOVE_STREAM, abi.encode(SERVICE_ID));
        assertEq(removeExit, 0);

        (uint32 cancelExit,) = swaCaller.call(CANCEL_PENDING, abi.encode(SERVICE_ID));
        assertEq(cancelExit, 0);

        _warpPastTimelockAndSettle();
        (uint64[] memory ids,,,,) = _getState();
        assertEq(ids.length, 1, "cancelled removal must never take effect");
    }

    // -------------------------------------------------------------------------
    // Fidelity: native-actor fallback and precompile guard
    // -------------------------------------------------------------------------

    // The real reward actor is a native actor: direct EVM CALL (InvokeContract) fails with
    // USR_UNHANDLED_MESSAGE rather than succeeding like an account actor would.
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

    // Exercises _handleBurn's `address(this).balance` debit through the new dispatcher --
    // the specific behavior a `call`-based (rather than `delegatecall`-based) forward to the
    // underlying FVMCallActorById would have broken.
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
