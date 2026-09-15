// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {Test} from "forge-std/Test.sol";
import {DeployScript} from "../../script/Deploy.s.sol";
import {ServiceRewardsActor} from "../../src/ServiceRewardsActor.sol";
import {StreamWeightActor} from "../../src/StreamWeightActor.sol";
import {Epoch} from "../../src/lib/Epoch.sol";
import {FixedU18} from "../../src/lib/FixedU18.sol";

contract DeploymentConfigReader is DeployScript {
    function readEpoch(string memory json) external pure returns (uint64) {
        return Epoch.unwrap(_readEpoch(json, ".314", "activationEpoch"));
    }
}

/// @notice Review evidence: passing tests demonstrate unsafe current behavior, not a fix.
contract DeploymentReviewTest is Test {
    function test_CheckedInMainnetConfigStartsQuartersAtGenesis() public {
        vm.chainId(314);
        // Synthetic future activation/deployment epoch; no live-chain assumptions required.
        vm.roll(6_000_000);
        (address sraAddress, address swaAddress) = new DeployScript().run();
        ServiceRewardsActor sra = ServiceRewardsActor(sraAddress);
        assertEq(Epoch.unwrap(sra.quarterStart(0)), 0);
        assertEq(Epoch.unwrap(sra.quarterStart(1)), 259_200);
        // Even the first gate quarter (Q2) is already bound on this fresh deployment.
        assertEq(FixedU18.unwrap(sra.aggregatedFilecoinPayVolume(2)), 0);
        // A permissionless caller can consume the newly initialized first gate immediately.
        StreamWeightActor(swaAddress).quarterlyGateCheck();
        // Q0 cannot be submitted even immediately after fresh deployment.
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.NotLatestQuarter.selector, uint64(0)));
        sra.submitShares(0);
    }

    function test_ConfigEpochOverflowSilentlyTruncates() public {
        DeploymentConfigReader reader = new DeploymentConfigReader();
        assertEq(reader.readEpoch('{"314":{"activationEpoch":18446744073709551616}}'), 0);
        assertEq(reader.readEpoch('{"314":{"activationEpoch":18446744073709551617}}'), 1);
    }
}
