// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

// SRA cancelBinding tests — orchestrator-self release of a single binding.

import {SRATestBase} from "./SRATestBase.sol";
import {ServiceRewardsActor} from "../src/ServiceRewardsActor.sol";
import {Binding} from "../src/lib/SraTypes.sol";

contract SRACancelBindingTest is SRATestBase {
    /// pairId = keccak256(abi.encode(payer, operator)) — mirrors the contract's _pairId helper
    /// (the assembly version is byte-identical to abi.encode; asserted in the PairNotBound checks).
    function _pairId(address payer, address operator) internal pure returns (bytes32) {
        return keccak256(abi.encode(payer, operator));
    }

    /// orchestrator-self release: a direct call by the bound orchestrator itself (no governance votes).
    function _cancelBindingAs(address caller, address payer, address operator) internal {
        vm.prank(caller);
        sra.cancelBinding(payer, operator);
    }

    /// every rejection path reverts the combined guard error PairNotBound(pairId).
    function _expectPairNotBound(address payer, address operator) internal {
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.PairNotBound.selector, _pairId(payer, operator)));
    }

    // ------------------------------------------------------------------------
    // Happy path (caller = the bound orchestrator itself)
    // ------------------------------------------------------------------------

    /// a live binding is released by its own orchestrator: after the self-cancel, bindingOf
    /// returns address(0) (unclaimed).
    function test_CancelBinding_Success_UnbindsPair() public {
        address orch = makeAddr("orch");
        _admit(orch, orch);

        address payer = makeAddr("payer");
        address operator = makeAddr("operator");
        Binding[] memory pairs = new Binding[](1);
        pairs[0] = _pair(payer, operator);
        _registerPairsAs(orch, pairs);
        assertEq(sra.bindingOf(payer, operator), orch);

        _cancelBindingAs(orch, payer, operator);

        assertEq(sra.bindingOf(payer, operator), address(0));
    }

    /// released pairs return to unclaimed: another admitted orchestrator can claim the same pair
    /// (consistent with registerPairs's removed-as-unclaimed semantics, spec §4.2).
    function test_CancelBinding_PairReclaimable_ByOtherOrch() public {
        address orchA = makeAddr("orchA");
        address orchB = makeAddr("orchB");
        _admit(orchA, orchA);
        _admit(orchB, orchB);

        address payer = makeAddr("payer");
        address operator = makeAddr("operator");
        Binding[] memory pairs = new Binding[](1);
        pairs[0] = _pair(payer, operator);
        _registerPairsAs(orchA, pairs);

        _cancelBindingAs(orchA, payer, operator);
        assertEq(sra.bindingOf(payer, operator), address(0));

        _registerPairsAs(orchB, pairs); // claimable after release
        assertEq(sra.bindingOf(payer, operator), orchB);
    }

    /// the release emits BindingCanceled(payer, operator, admitIdentity) at the self-cancel call
    /// (here admitIdentity == orch == wallet; the distinct-wallet case is covered below).
    function test_CancelBinding_EmitsBindingCanceled() public {
        address orch = makeAddr("orch");
        _admit(orch, orch);

        address payer = makeAddr("payer");
        address operator = makeAddr("operator");
        Binding[] memory pairs = new Binding[](1);
        pairs[0] = _pair(payer, operator);
        _registerPairsAs(orch, pairs);

        vm.expectEmit(true, true, true, false, address(sra));
        emit ServiceRewardsActor.BindingCanceled(payer, operator, orch);
        _cancelBindingAs(orch, payer, operator);
    }

    /// third event arg is the *admit-time orchestrator identity*, not the distinct payout wallet.
    function test_CancelBinding_EmitsIdentity_WhenWalletDiffersFromOrch() public {
        address orch = makeAddr("orch");
        address distinctWallet = makeAddr("distinct-wallet");
        _admit(orch, distinctWallet);

        address payer = makeAddr("payer");
        address operator = makeAddr("operator");
        Binding[] memory pairs = new Binding[](1);
        pairs[0] = _pair(payer, operator);
        _registerPairsAs(orch, pairs);

        vm.expectEmit(true, true, true, false, address(sra));
        emit ServiceRewardsActor.BindingCanceled(payer, operator, orch);
        _cancelBindingAs(orch, payer, operator);
    }

    /// the identity does not move with the payout wallet (spec §3.2): after replaceWallet, cancel
    /// still emits the *admit-time* orchestrator, and the orchestrator's own address still authorizes it.
    function test_CancelBinding_EmitsAdmitIdentity_AfterReplaceWallet() public {
        address orch = makeAddr("orch");
        address origWallet = makeAddr("orig-wallet");
        address newWallet = _wallet("new-wallet");
        _admit(orch, origWallet);

        address payer = makeAddr("payer");
        address operator = makeAddr("operator");
        Binding[] memory pairs = new Binding[](1);
        pairs[0] = _pair(payer, operator);
        _registerPairsAs(orch, pairs);

        // governance wallet swap: identity and binding stay put, only the wallet field re-points
        vm.prank(owner1);
        sra.replaceWallet(orch, newWallet);
        vm.prank(owner2);
        sra.replaceWallet(orch, newWallet); // second approval executes immediately

        vm.expectEmit(true, true, true, false, address(sra));
        emit ServiceRewardsActor.BindingCanceled(payer, operator, orch); // admit-time identity, not newWallet
        _cancelBindingAs(orch, payer, operator);
    }

    // ------------------------------------------------------------------------
    // Release semantics (forward-effective)
    // ------------------------------------------------------------------------

    /// forward-effective: after release the same orchestrator may re-register the pair — the release
    /// only dropped the binding record, admission is untouched.
    function test_CancelBinding_SelfReclaim_AfterRelease() public {
        address orch = makeAddr("orch");
        _admit(orch, orch);

        address payer = makeAddr("payer");
        address operator = makeAddr("operator");
        Binding[] memory pairs = new Binding[](1);
        pairs[0] = _pair(payer, operator);
        _registerPairsAs(orch, pairs);
        _cancelBindingAs(orch, payer, operator);
        assertEq(sra.bindingOf(payer, operator), address(0));

        _registerPairsAs(orch, pairs); // self re-claim after release
        assertEq(sra.bindingOf(payer, operator), orch);
        assertTrue(sra.isAdmitted(orch), "release must not affect the releasing orchestrator's admission");
    }

    // ------------------------------------------------------------------------
    // Failure paths (single combined guard: PairNotBound)
    // ------------------------------------------------------------------------

    /// the governance owners — old callers — now revert: the call lands in the body (no modifier),
    /// the owner is not the bound identity, so PairNotBound fires and the binding stays untouched.
    function test_CancelBinding_GovernanceOwner_Reverts() public {
        address orch = makeAddr("orch");
        _admit(orch, orch);

        address payer = makeAddr("payer");
        address operator = makeAddr("operator");
        Binding[] memory pairs = new Binding[](1);
        pairs[0] = _pair(payer, operator);
        _registerPairsAs(orch, pairs);

        _expectPairNotBound(payer, operator);
        vm.prank(owner1);
        sra.cancelBinding(payer, operator);

        assertEq(sra.bindingOf(payer, operator), orch); // owner call had no effect
    }

    /// only the bound orchestrator may cancel: another admitted orchestrator on someone else's pair
    /// reverts PairNotBound — dropping a pair it does not hold stays on the reassignBinding path.
    function test_CancelBinding_OtherOrch_Reverts() public {
        address orchA = makeAddr("orchA");
        address orchB = makeAddr("orchB");
        _admit(orchA, orchA);
        _admit(orchB, orchB);

        address payer = makeAddr("payer");
        address operator = makeAddr("operator");
        Binding[] memory pairs = new Binding[](1);
        pairs[0] = _pair(payer, operator);
        _registerPairsAs(orchA, pairs);

        _expectPairNotBound(payer, operator);
        _cancelBindingAs(orchB, payer, operator);

        assertEq(sra.bindingOf(payer, operator), orchA); // other-orch call had no effect
    }

    /// the distinct payout wallet is not the identity: activeIdOf maps the orchestrator, not the wallet.
    function test_CancelBinding_WalletNotBinder_Reverts() public {
        address orch = makeAddr("orch");
        address distinctWallet = makeAddr("distinct-wallet");
        _admit(orch, distinctWallet);

        address payer = makeAddr("payer");
        address operator = makeAddr("operator");
        Binding[] memory pairs = new Binding[](1);
        pairs[0] = _pair(payer, operator);
        _registerPairsAs(orch, pairs);

        _expectPairNotBound(payer, operator);
        _cancelBindingAs(distinctWallet, payer, operator);

        assertEq(sra.bindingOf(payer, operator), orch); // wallet call had no effect
    }

    /// canceling a pair that was never bound reverts PairNotBound(pairId) at the guard (boundId == 0).
    function test_CancelBinding_NotBound_Reverts() public {
        address orch = makeAddr("orch");
        _admit(orch, orch);

        address payer = makeAddr("payer");
        address operator = makeAddr("operator");

        _expectPairNotBound(payer, operator);
        _cancelBindingAs(orch, payer, operator);
    }

    /// the 0==0 trap: a never-admitted caller on a never-bound pair reads both sides 0 — pure
    /// equality would pass and emit BindingCanceled with a zero orchestrator; boundId != 0 reverts.
    function test_CancelBinding_StrangerNeverBound_Reverts() public {
        address stranger = makeAddr("stranger"); // never admitted (activeIdOf == 0)

        address payer = makeAddr("payer");
        address operator = makeAddr("operator");
        assertEq(sra.bindingOf(payer, operator), address(0)); // never bound (bindings == 0)

        _expectPairNotBound(payer, operator);
        _cancelBindingAs(stranger, payer, operator);

        assertEq(sra.bindingOf(payer, operator), address(0)); // no state change, no phantom binding
    }

    /// cancel is not idempotent: a second cancel after release is a no-op and reverts PairNotBound.
    function test_CancelBinding_DoubleCancel_Reverts() public {
        address orch = makeAddr("orch");
        _admit(orch, orch);

        address payer = makeAddr("payer");
        address operator = makeAddr("operator");
        Binding[] memory pairs = new Binding[](1);
        pairs[0] = _pair(payer, operator);
        _registerPairsAs(orch, pairs);
        _cancelBindingAs(orch, payer, operator);

        _expectPairNotBound(payer, operator);
        _cancelBindingAs(orch, payer, operator);
    }

    /// a removed orchestrator's binding is already unclaimed-equivalent: its id is no longer admitted,
    /// so canceling reverts PairNotBound and the pair stays claimable.
    function test_CancelBinding_RemovedOrch_Reverts() public {
        address orchA = makeAddr("orchA");
        address orchB = makeAddr("orchB");
        _admit(orchA, orchA);
        _admit(orchB, orchB);

        address payer = makeAddr("payer");
        address operator = makeAddr("operator");
        Binding[] memory pairs = new Binding[](1);
        pairs[0] = _pair(payer, operator);
        _registerPairsAs(orchA, pairs);
        _crankQuarter0(); // lift the §3.2 remove guard (q0 bound + submitted)
        _remove(orchA); // binding stays in storage but reads as unclaimed (spec §4.2)

        _expectPairNotBound(payer, operator);
        _cancelBindingAs(orchA, payer, operator);

        // the pair stays claimable by another orchestrator (registerPairs sees it as unclaimed)
        _registerPairsAs(orchB, pairs);
        assertEq(sra.bindingOf(payer, operator), orchB);
    }
}
