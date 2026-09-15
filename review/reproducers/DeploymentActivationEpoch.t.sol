// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {Test} from "forge-std/Test.sol";

import {DeployScript} from "../../script/Deploy.s.sol";
import {ServiceRewardsActor} from "../../src/ServiceRewardsActor.sol";
import {Epoch} from "../../src/lib/Epoch.sol";

/// Minimal production deployment-path reproducer for review appendlog Entry 005.
/// Run:
/// forge test --contracts review/reproducers --match-contract DeploymentActivationEpochReproducer -vvv
contract DeploymentActivationEpochReproducer is Test {
    function test_MainnetConfigMustNotAnchorQuarterZeroToGenesis() public {
        vm.chainId(314);
        DeployScript deployer = new DeployScript();
        (address sra,) = deployer.run();

        uint64 quarterZeroStart = Epoch.unwrap(ServiceRewardsActor(sra).quarterStart(0));
        assertGt(quarterZeroStart, 0, "checked-in mainnet deployment config anchors reporting to genesis");
    }
}
