// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {SRATestBase} from "../../test/SRATestBase.sol";
import {Binding} from "../../src/lib/SraTypes.sol";

/// Minimal production-state reproducer for review appendlog Entry 013.
/// Run:
/// forge test --contracts review/reproducers --match-contract ZeroOrchestratorHiddenBindingReproducer -vvv
contract ZeroOrchestratorHiddenBindingReproducer is SRATestBase {
    function test_UnboundSentinelMustNotHideOccupiedBinding() public {
        address liveOrchestrator = makeAddr("live-orchestrator");
        _admit(liveOrchestrator, liveOrchestrator);
        _admit(address(0), makeAddr("zero-identity-wallet"));

        Binding[] memory pairs = new Binding[](1);
        pairs[0] = Binding({payer: makeAddr("payer"), operator: makeAddr("operator")});
        _registerPairsAs(liveOrchestrator, pairs);

        vm.prank(owner1);
        sra.reassignBinding(pairs[0].payer, pairs[0].operator, address(0), false);
        vm.prank(owner2);
        sra.reassignBinding(pairs[0].payer, pairs[0].operator, address(0), false);

        assertEq(sra.bindingOf(pairs[0].payer, pairs[0].operator), address(0), "view reports unbound sentinel");

        // A pair reported as unbound must be available for registration. Production state instead
        // retains the zero orchestrator's live ID and reverts AlreadyBound.
        _registerPairsAs(liveOrchestrator, pairs);
    }
}
