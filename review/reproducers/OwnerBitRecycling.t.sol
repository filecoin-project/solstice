// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {SRATestBase} from "../../test/SRATestBase.sol";

/// Minimal production-governance reproducer for review appendlog Entry 018.
/// Run:
/// forge test --contracts review/reproducers --match-contract OwnerBitRecyclingReproducer -vvv
contract OwnerBitRecyclingReproducer is SRATestBase {
    function test_RecycledBitMustNotApproveForReplacementOwner() public {
        address candidate = makeAddr("candidate");
        _ensureResolvable(candidate);

        // Original owner1 leaves one approval on an immediate governance task.
        vm.prank(owner1);
        sra.addOrchestrator(candidate, candidate);
        assertFalse(sra.isAdmitted(candidate));

        // Initialization consumed bits 0 and 1. Rotating the first owner 159 times allocates
        // bits 2..159 and then recycles bit 0 into an unrelated current owner.
        address rotatingOwner = owner1;
        for (uint256 i = 0; i < 159; i++) {
            address replacement = address(uint160(0x1000 + i));
            vm.prank(rotatingOwner);
            sra.replaceOwner(rotatingOwner, replacement);
            vm.prank(owner2);
            sra.replaceOwner(rotatingOwner, replacement);
            rotatingOwner = replacement;
        }

        // Only owner2 approves as a current owner. The recycled bit makes the task appear unanimous,
        // so the body executes without any approval from rotatingOwner.
        vm.prank(owner2);
        sra.addOrchestrator(candidate, candidate);

        assertFalse(sra.isAdmitted(candidate), "replacement owner never approved this task");
    }
}
