// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Epoch} from "../../src/lib/Epoch.sol";
import {UnanimousProxied} from "../../src/lib/UnanimousProxied.sol";

contract UpgradeContextProbe is UnanimousProxied {
    address public observedCaller;
    uint256 public observedValue;

    constructor(address owner1, address owner2, Epoch hold) UnanimousProxied(owner1, owner2, hold) {}

    function captureUpgradeContext() external payable {
        observedCaller = msg.sender;
        observedValue = msg.value;
    }
}

/// Production UUPS/governance reproducer for appendlog Entry 026.
/// Run:
/// forge test --contracts review/reproducers --match-contract UpgradeFinalizerContextReproducer -vv
contract UpgradeFinalizerContextReproducer is Test {
    address internal owner1;
    address internal owner2;
    address internal finalizer;
    Epoch internal hold;
    UnanimousProxied internal proxy;
    UpgradeContextProbe internal nextImplementation;

    function setUp() public {
        owner1 = makeAddr("owner1");
        owner2 = makeAddr("owner2");
        finalizer = makeAddr("public-finalizer");
        hold = Epoch.wrap(90);

        UnanimousProxied initialImplementation = new UnanimousProxied(owner1, owner2, hold);
        proxy = UnanimousProxied(
            address(new ERC1967Proxy(address(initialImplementation), abi.encodeCall(UnanimousProxied.initialize, ())))
        );
        nextImplementation = new UpgradeContextProbe(makeAddr("unused-1"), makeAddr("unused-2"), hold);
    }

    function _approveAndFinalize(uint256 value) internal returns (UpgradeContextProbe upgraded) {
        bytes memory migration = abi.encodeCall(UpgradeContextProbe.captureUpgradeContext, ());
        vm.prank(owner1);
        proxy.upgradeToAndCall(address(nextImplementation), migration);
        vm.prank(owner2);
        proxy.upgradeToAndCall(address(nextImplementation), migration);

        vm.roll(block.number + Epoch.unwrap(hold));
        vm.deal(finalizer, value);
        vm.prank(finalizer);
        proxy.upgradeToAndCall{value: value}(address(nextImplementation), migration);
        upgraded = UpgradeContextProbe(payable(address(proxy)));
    }

    function test_MigrationMustNotObserveUnapprovedPublicFinalizer() public {
        UpgradeContextProbe upgraded = _approveAndFinalize(0);
        assertEq(upgraded.observedCaller(), address(proxy), "migration observed the public finalizer");
    }

    function test_MigrationMustNotObserveUncommittedValue() public {
        UpgradeContextProbe upgraded = _approveAndFinalize(1 ether);
        assertEq(upgraded.observedValue(), 0, "migration observed uncommitted msg.value");
    }
}
