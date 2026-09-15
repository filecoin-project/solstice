// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {MockRewardWireTest} from "../../test/mocks/MockRewardWireTest.sol";
import {Epoch} from "../../src/lib/Epoch.sol";
import {FVMRewards} from "../../src/lib/FVMRewards.sol";
import {WeightRecord} from "../../src/lib/FVMRewardTypes.sol";

contract RegisterStreamEpochCaller {
    function register(uint64 activationEpoch) external returns (int256) {
        WeightRecord memory record = WeightRecord({vStart: 0, slope: 0, tStart: Epoch.wrap(0), floor: 0, cap: 0});
        return FVMRewards.tryRegisterStream(77, record, activationEpoch);
    }
}

/// Minimal production encoder reproducer for review appendlog Entry 011.
/// Run:
/// forge test --contracts review/reproducers --match-contract RegisterStreamEpochDomainReproducer -vvv
contract RegisterStreamEpochDomainReproducer is MockRewardWireTest {
    function test_ActivationEpochOutsideNativeI64MustFailLocally() public {
        RegisterStreamEpochCaller caller = new RegisterStreamEpochCaller();
        uint64 firstUnencodableNativeEpoch = uint64(1) << 63;

        vm.expectRevert(
            abi.encodeWithSelector(FVMRewards.ValueOutOfRange.selector, int256(uint256(firstUnencodableNativeEpoch)))
        );
        caller.register(firstUnencodableNativeEpoch);
    }
}
