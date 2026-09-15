// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {SWATestBase} from "../SWATestBase.sol";
import {MAINNET_TIMELOCK} from "../mocks/FVMRewardActor.sol";
import {IServiceRewardsActor} from "../../src/interfaces/IServiceRewardsActor.sol";
import {StreamWeightActor} from "../../src/StreamWeightActor.sol";
import {SERVICE_ID} from "../../src/lib/FVMRewardTypes.sol";
import {GateParams, VolumeTarget} from "../../src/lib/GateParams.sol";
import {Epoch} from "../../src/lib/Epoch.sol";
import {FixedU18} from "../../src/lib/FixedU18.sol";

/// @notice Passing tests reproduce missing retune coordination, with the existing f02 mock.
contract StreamRetuneReviewTest is SWATestBase {
    function _params(uint256 base, uint64 steps) internal pure returns (GateParams memory) {
        return GateParams(VolumeTarget(FixedU18.wrap(base), FixedU18.wrap(2.7e18)), steps);
    }

    function _approve(GateParams memory params) internal {
        vm.prank(owner1);
        actor.setGateParams(params);
        vm.prank(owner2);
        actor.setGateParams(params);
    }

    function _bindQuarterTwo(uint256 volume) internal {
        address sra = makeAddr("sra");
        vm.mockCall(
            sra, abi.encodeCall(IServiceRewardsActor.aggregatedFilecoinPayVolume, (uint64(2))), abi.encode(volume)
        );
        vm.mockCall(sra, abi.encodeCall(IServiceRewardsActor.quarterStart, (uint64(2))), abi.encode(uint64(1000)));
    }

    function test_IndependentCounterRetuneSkipsServiceWeightLevels() public {
        _registerAndActivate(SERVICE_ID);
        rewardActor().mockAwardBlockReward(0);
        GateParams memory params = _params(3500e18, 7);
        _approve(params);
        vm.roll(block.number + Epoch.unwrap(MAINNET_TIMELOCK));
        actor.setGateParams(params);
        (, uint256 beforePortion,) = rewardActor().mockAwardBlockReward(100e18);
        assertEq(beforePortion, 10e18);

        _bindQuarterTwo(1_000_000_000e18);
        actor.quarterlyGateCheck();
        vm.roll(block.number + Epoch.unwrap(MAINNET_TIMELOCK));
        (, uint256 afterPortion,) = rewardActor().mockAwardBlockReward(100e18);
        assertEq(afterPortion, 50e18); // One passing quarter moves 10% directly to 50%.
        vm.expectRevert(StreamWeightActor.StepsComplete.selector);
        actor.quarterlyGateCheck();
    }

    function test_SameEpochRetuneOrderingChangesGateOutcome() public {
        _registerAndActivate(SERVICE_ID);
        rewardActor().mockAwardBlockReward(0);
        _bindQuarterTwo(4000e18); // Passes the old 3500 threshold, fails the new 5000 threshold.
        GateParams memory params = _params(5000e18, 0);
        _approve(params);
        vm.roll(block.number + Epoch.unwrap(MAINNET_TIMELOCK));
        uint256 snapshot = vm.snapshotState();

        // Both calls succeed in the same epoch even though the retune follows a gate check.
        actor.quarterlyGateCheck();
        actor.setGateParams(params);
        vm.roll(block.number + Epoch.unwrap(MAINNET_TIMELOCK));
        (, uint256 gateFirstPortion,) = rewardActor().mockAwardBlockReward(100e18);
        assertEq(gateFirstPortion, 15e18);

        assertTrue(vm.revertToState(snapshot));
        actor.setGateParams(params);
        actor.quarterlyGateCheck();
        vm.roll(block.number + Epoch.unwrap(MAINNET_TIMELOCK));
        (, uint256 retuneFirstPortion,) = rewardActor().mockAwardBlockReward(100e18);
        assertEq(retuneFirstPortion, 10e18);
    }
}
