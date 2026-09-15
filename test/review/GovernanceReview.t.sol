// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Epoch} from "../../src/lib/Epoch.sol";
import {OwnersLibrary} from "../../src/lib/Owners.sol";
import {UnanimousGovernance} from "../../src/lib/UnanimousGovernance.sol";
import {UnanimousProxied} from "../../src/lib/UnanimousProxied.sol";

contract GovernanceReviewHarness is UnanimousProxied {
    uint256 public value;

    constructor(address owner1, address owner2) UnanimousProxied(owner1, owner2, Epoch.wrap(0)) {}

    function setValue(uint256 next) external unanimousNoHold(keccak256(msg.data)) {
        value = next;
    }

    function isOwner(address account) external view returns (bool) {
        return OwnersLibrary.isOwner(account);
    }
}

contract GovernanceReviewTest is Test {
    address internal ownerA = makeAddr("ownerA");
    address internal ownerB = makeAddr("ownerB");
    address internal ownerC = makeAddr("ownerC");
    GovernanceReviewHarness internal governance;

    function setUp() public {
        vm.roll(1);
        address implementation = address(new GovernanceReviewHarness(ownerA, ownerB));
        governance = GovernanceReviewHarness(
            address(new ERC1967Proxy(implementation, abi.encodeCall(UnanimousProxied.initialize, ())))
        );
    }

    function test_staleApprovalExecutesAfterOwnerBitIsReused() public {
        // ownerA (allocation bit 0) is the only owner to approve this task.
        vm.prank(ownerA);
        governance.setValue(7);
        assertEq(governance.value(), 0);

        // Replace ownerA. ownerC starts at bit 2 because bits 0 and 1 were allocated initially.
        vm.prank(ownerA);
        governance.replaceOwner(ownerA, ownerC);
        vm.prank(ownerB);
        governance.replaceOwner(ownerA, ownerC);

        // Replacing ownerC with itself advances its allocation through bits 3..159 and then
        // wraps to the now-free bit 0. None of these calls approves setValue(7) as ownerC.
        for (uint256 i = 0; i < 158; ++i) {
            vm.prank(ownerB);
            governance.replaceOwner(ownerC, ownerC);
            vm.prank(ownerC);
            governance.replaceOwner(ownerC, ownerC);
        }

        // ownerA's stale bit-0 approval is now attributed to ownerC. ownerB's sole approval
        // reaches the current bitmap and executes without ownerC ever approving this task.
        vm.prank(ownerB);
        governance.setValue(7);
        assertEq(governance.value(), 7);
    }

    function test_zeroOwnerRotationPermanentlyLocksUnanimousActions() public {
        vm.prank(ownerA);
        governance.replaceOwner(ownerA, address(0));
        vm.prank(ownerB);
        governance.replaceOwner(ownerA, address(0));

        assertFalse(governance.isOwner(ownerA));
        assertTrue(governance.isOwner(ownerB));
        assertTrue(governance.isOwner(address(0)));

        // The only callable owner can submit but can never supply address(0)'s approval.
        vm.prank(ownerB);
        governance.setValue(9);
        assertEq(governance.value(), 0);

        vm.expectRevert(UnanimousGovernance.AlreadyApproved.selector);
        vm.prank(ownerB);
        governance.setValue(9);

        // Recovery itself is unanimous, so ownerB also cannot rotate address(0) back out.
        vm.prank(ownerB);
        governance.replaceOwner(address(0), ownerA);
        vm.expectRevert(UnanimousGovernance.AlreadyApproved.selector);
        vm.prank(ownerB);
        governance.replaceOwner(address(0), ownerA);
    }
}

