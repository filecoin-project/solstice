// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DeployScript} from "../../script/Deploy.s.sol";
import {ServiceRewardsActor} from "../../src/ServiceRewardsActor.sol";
import {Epoch} from "../../src/lib/Epoch.sol";
import {UnanimousProxied} from "../../src/lib/UnanimousProxied.sol";

contract DeployEpochParserHarness is DeployScript {
    function parseEpoch(string calldata json) external pure returns (uint64) {
        return Epoch.unwrap(_readEpoch(json, ".config", "epoch"));
    }
}

/// Retained deployment-input reproducers for appendlog Entries 020-022.
/// Run:
/// forge test --contracts review/reproducers --match-contract DeploymentHardeningReproducer -vv
contract DeploymentHardeningReproducer is Test {
    function test_ZeroOwnerConfigurationMustBeRejected() public {
        ServiceRewardsActor implementation = new ServiceRewardsActor(
            address(0),
            makeAddr("reachable-owner"),
            Epoch.wrap(1000),
            Epoch.wrap(10),
            Epoch.wrap(20),
            Epoch.wrap(100),
            Epoch.wrap(30)
        );

        vm.expectRevert();
        new ERC1967Proxy(address(implementation), abi.encodeCall(UnanimousProxied.initialize, ()));
    }

    function test_OutOfRangeEpochMustNotSilentlyTruncate() public {
        DeployEpochParserHarness harness = new DeployEpochParserHarness();
        string memory json = '{"config":{"epoch":18446744073709551616}}';

        vm.expectRevert();
        harness.parseEpoch(json);
    }

    function test_RerunMustNotDeployDifferentCanonicalProxies() public {
        vm.chainId(314);
        DeployScript script = new DeployScript();
        (address firstSra, address firstSwa) = script.run();
        (address secondSra, address secondSwa) = script.run();

        assertEq(secondSra, firstSra, "rerun deployed a different SRA proxy");
        assertEq(secondSwa, firstSwa, "rerun deployed a different SWA proxy");
    }
}
