// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {Test} from "forge-std/Test.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Epoch} from "../src/lib/Epoch.sol";
import {OwnersLibrary} from "../src/lib/Owners.sol";
import {UnanimousGovernance} from "../src/lib/UnanimousGovernance.sol";
import {UnanimousProxied} from "../src/lib/UnanimousProxied.sol";

contract UnanimousProxiedTest is Test {
    address owner1;
    address owner2;
    UnanimousProxied proxy;
    Epoch hold;

    function setUp() public {
        owner1 = makeAddr("owner1");
        owner2 = makeAddr("owner2");
        hold = Epoch.wrap(90);
        address implementation = address(new UnanimousProxied(owner1, owner2, hold));
        proxy = UnanimousProxied(
            address(new ERC1967Proxy(implementation, abi.encodeCall(UnanimousProxied.initialize, ())))
        );
    }

    function test_vetoRevertsNoTask() public {
        bytes32 taskId;

        vm.prank(owner1);
        vm.expectRevert(abi.encodeWithSelector(UnanimousGovernance.TaskNotFound.selector, taskId));
        proxy.veto(taskId);
    }

    function test_upgrade() public {
        address owner3 = makeAddr("owner3");
        address owner4 = makeAddr("owner3");
        address implementation = address(new UnanimousProxied(owner3, owner4, hold));

        vm.prank(owner3);
        vm.expectRevert(abi.encodeWithSelector(OwnersLibrary.NotOwner.selector, owner3));
        proxy.upgradeToAndCall(implementation, abi.encodeCall(UnanimousProxied.initialize, ()));

        vm.prank(owner1);
        proxy.upgradeToAndCall(implementation, abi.encodeCall(UnanimousProxied.initialize, ()));
        vm.prank(owner2);
        proxy.upgradeToAndCall(implementation, abi.encodeCall(UnanimousProxied.initialize, ()));

        vm.roll(vm.getBlockNumber() + Epoch.unwrap(hold));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        proxy.upgradeToAndCall(implementation, abi.encodeCall(UnanimousProxied.initialize, ()));

        bytes32 taskId = keccak256(
            abi.encodeCall(proxy.upgradeToAndCall, (implementation, abi.encodeCall(UnanimousProxied.initialize, ())))
        );

        vm.prank(owner3);
        vm.expectRevert(abi.encodeWithSelector(OwnersLibrary.NotOwner.selector, owner3));
        proxy.veto(taskId);

        vm.prank(owner1);
        vm.expectEmit(address(proxy));
        emit UnanimousGovernance.Rejected(taskId, owner1);
        proxy.veto(taskId);
    }
}
