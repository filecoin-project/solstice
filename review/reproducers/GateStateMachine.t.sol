// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {SWATestBase} from "../../test/SWATestBase.sol";
import {IServiceRewardsActor} from "../../src/interfaces/IServiceRewardsActor.sol";
import {SERVICE_ID, WeightRecord, WeightRecordUpdate} from "../../src/lib/FVMRewardTypes.sol";
import {Epoch} from "../../src/lib/Epoch.sol";
import {FixedU18} from "../../src/lib/FixedU18.sol";
import {GateParams, VolumeTarget} from "../../src/lib/GateParams.sol";
import {MAINNET_TIMELOCK, MockState} from "../../test/mocks/FVMRewardActor.sol";

bytes32 constant REVIEW_GATE_PARAMS_SLOT = 0xf9abab00248d945495524c8caf6be2b837274c1becd1964fb3775f62fd6e4600;

/// Production SWA plus the repository's behavioral f02 mock. Retains reproducers for appendlog
/// Entries 029-031.
/// Run:
/// forge test --contracts review/reproducers --match-contract GateStateMachineReproducer -vv
contract GateStateMachineReproducer is SWATestBase {
    function _sra() internal returns (IServiceRewardsActor) {
        return IServiceRewardsActor(makeAddr("sra"));
    }

    function _mockQuarter(IServiceRewardsActor sra, uint64 q, uint256 fpv, uint64 start) internal {
        vm.mockCall(
            address(sra),
            abi.encodeWithSelector(IServiceRewardsActor.aggregatedFilecoinPayVolume.selector, q),
            abi.encode(FixedU18.wrap(fpv))
        );
        vm.mockCall(
            address(sra),
            abi.encodeWithSelector(IServiceRewardsActor.quarterStart.selector, q),
            abi.encode(Epoch.wrap(start))
        );
    }

    function _params(uint256 base, uint256 ratio, uint64 steps) internal pure returns (GateParams memory p) {
        p.target = VolumeTarget({base: FixedU18.wrap(base), stepRatio: FixedU18.wrap(ratio)});
        p.steps = steps;
    }

    function _approveGateParams(GateParams memory p) internal {
        vm.prank(owner1);
        actor.setGateParams(p);
        vm.prank(owner2);
        actor.setGateParams(p);
    }

    function _steps() internal view returns (uint64) {
        return uint64(uint256(vm.load(address(actor), bytes32(uint256(REVIEW_GATE_PARAMS_SLOT) + 3))));
    }

    function test_PairedRetuneMustNotBeOverwrittenByInterleavedGateCheck() public {
        _registerAndActivate(SERVICE_ID);

        WeightRecord memory fifty = WeightRecord({
            vStart: 0.5e18, slope: 0, tStart: Epoch.wrap(uint64(block.number)), floor: 0.5e18, cap: 0.5e18
        });
        WeightRecordUpdate[] memory updates = _singleWeightRecord(SERVICE_ID, fifty);
        vm.prank(owner1);
        actor.setWeightRecords(updates);
        vm.prank(owner2);
        actor.setWeightRecords(updates);

        GateParams memory terminal = _params(3500 ether, 2.7 ether, 8);
        _approveGateParams(terminal);
        vm.roll(block.number + Epoch.unwrap(MAINNET_TIMELOCK));

        IServiceRewardsActor sra = _sra();
        _mockQuarter(sra, 2, 3500 ether, 1000);
        actor.quarterlyGateCheck(); // reads steps=0; f02 first settles 50%, then queues 15%
        actor.setGateParams(terminal); // permissionless completion in the same epoch

        vm.roll(block.number + Epoch.unwrap(MAINNET_TIMELOCK));
        rewardActor().mockSettle();
        MockState memory state = rewardActor().mockState();

        assertEq(state.streams[0].weightRecord.vStart, 0.5e18, "interleaved gate overwrote paired 50% retune");
        assertEq(_steps(), 8, "local counter is terminal");
    }

    function test_ConsecutiveLatePassingQuartersMustBeImmediatelyCallable() public {
        _registerAndActivate(SERVICE_ID);
        IServiceRewardsActor sra = _sra();
        _mockQuarter(sra, 2, 3500 ether, 1000);
        _mockQuarter(sra, 3, 9450 ether, 2000);

        actor.quarterlyGateCheck();
        actor.quarterlyGateCheck(); // pinned f02 rejects: StepWeightRecords key is still occupied
    }

    function test_OverflowingTargetMustNotLetZeroVolumePass() public {
        _registerAndActivate(SERVICE_ID);
        GateParams memory overflowing = _params(3500 ether, uint256(1) << 128, 2);
        _approveGateParams(overflowing);
        vm.roll(block.number + Epoch.unwrap(MAINNET_TIMELOCK));
        actor.setGateParams(overflowing);

        IServiceRewardsActor sra = _sra();
        _mockQuarter(sra, 2, 0, 1000);
        actor.quarterlyGateCheck();

        assertEq(_steps(), 2, "wrapped zero threshold admitted an unearned gate step");
    }
}
