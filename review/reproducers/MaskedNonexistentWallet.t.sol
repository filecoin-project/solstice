// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {SRATestBase} from "../../test/SRATestBase.sol";

/// Production SRA validation reproducer for appendlog Entry 025.
/// The mocked RESOLVE_ADDRESS behavior matches FVM's ID-address short circuit: it returns the
/// numeric ID without proving actor-state existence.
/// Run:
/// forge test --contracts review/reproducers --match-contract MaskedNonexistentWalletReproducer -vvv
contract MaskedNonexistentWalletReproducer is SRATestBase {
    function test_ResolvableButNonexistentMaskedWalletMustBeRejected() public {
        address orchestrator = makeAddr("orchestrator");
        address nonexistentWallet = _maskedWallet(9_999_999_999);
        assertEq(nonexistentWallet.codehash, bytes32(0), "fixture unexpectedly has actor code");

        vm.prank(owner1);
        sra.addOrchestrator(orchestrator, nonexistentWallet);
        vm.prank(owner2);
        vm.expectRevert();
        sra.addOrchestrator(orchestrator, nonexistentWallet);
    }
}
