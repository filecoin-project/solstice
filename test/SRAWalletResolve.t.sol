// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

// Case tags used below:
//   [A] FIP silent-zone hardening — a zero payout wallet is a governance mistake
//   [B] FIP §2.4.4 — every payout wallet must resolve to an existing actor's ID before the SRA names it
//   [C] FIP §2.4.4 — the duplicate check is keyed by the *resolved* actor ID (a wallet has two wire
//       spellings — f410 delegated vs masked 0xff… — that differ in bytes but resolve to one id)
//   [D] regression — events keep the raw wire spelling; existing wire vectors stay untouched

import {ServiceRewardsActor} from "../src/ServiceRewardsActor.sol";
import {BURN_ADDRESS} from "fvm-solidity/FVMActors.sol";
import {SRATestBase} from "./SRATestBase.sol";

contract SRAWalletResolveTest is SRATestBase {
    bytes4 private constant ZERO_WALLET_ERROR = bytes4(keccak256("ZeroWallet(address)"));
    bytes4 private constant UNRESOLVED_WALLET_ERROR = bytes4(keccak256("UnresolvedWallet(address)"));

    // ------------------------------------------------------------------------
    // [A] zero payout wallet
    // ------------------------------------------------------------------------

    /// [A] addOrchestrator with the zero wallet is rejected before any resolve: address(0) is not
    /// masked, so its f410 resolve outcome would otherwise depend on the registry state (fresh
    /// devnet: unresolved; a registered 0x0 simulates mainnet/calibnet, where f410(0x0) hosts an
    /// actor). The zero check must win in both worlds.
    function test_AddOrchestrator_ZeroWallet_Reverts() public {
        address orch = _wallet("a1-orch");
        vm.prank(owner1);
        sra.addOrchestrator(orch, address(0)); // vote 1 (approve)
        vm.expectRevert(abi.encodeWithSelector(ZERO_WALLET_ERROR, address(0)));
        vm.prank(owner2);
        sra.addOrchestrator(orch, address(0)); // vote 2 executes the body -> ZeroWallet
        assertFalse(sra.isAdmitted(orch));
    }

    /// [A] address(0) is registered to resolve (as it does on mainnet/calibnet), yet the zero
    /// require fires before the resolve would pass — the admission is locally rejected, never
    /// admitted with a fund-locking row.
    function test_AddOrchestrator_ZeroWallet_RegisteredZero_StillReverts() public {
        _registerResolve(address(0), 424_242); // simulate mainnet: f410(0x0) has a resident actor
        address orch = _wallet("a1b-orch");
        vm.prank(owner1);
        sra.addOrchestrator(orch, address(0));
        vm.expectRevert(abi.encodeWithSelector(ZERO_WALLET_ERROR, address(0)));
        vm.prank(owner2);
        sra.addOrchestrator(orch, address(0));
        assertFalse(sra.isAdmitted(orch));
    }

    /// [A] replaceWallet to the zero wallet is rejected by the same local check.
    function test_ReplaceWallet_ZeroWallet_Reverts() public {
        address oldOrch = _wallet("a2-orch");
        _admit(oldOrch, _wallet("a2-wallet"));
        vm.prank(owner1);
        sra.replaceWallet(oldOrch, address(0));
        vm.expectRevert(abi.encodeWithSelector(ZERO_WALLET_ERROR, address(0)));
        vm.prank(owner2);
        sra.replaceWallet(oldOrch, address(0)); // vote 2 executes the body -> ZeroWallet
    }

    // ------------------------------------------------------------------------
    // [B] resolve requirement
    // ------------------------------------------------------------------------

    /// [B] a wallet that resolves to no actor is rejected on admit. The address is deliberately not
    /// registered with the mock (explicit unresolvable — distinct from the base's default-registered
    /// wallets, so the revert is the feature's, not a forgotten registration).
    function test_AddOrchestrator_UnresolvableWallet_Reverts() public {
        address orch = _wallet("b4a-orch");
        address ghost = makeAddr("b4a-ghost"); // never registered -> resolve returns exists=false
        vm.prank(owner1);
        sra.addOrchestrator(orch, ghost);
        vm.expectRevert(abi.encodeWithSelector(UNRESOLVED_WALLET_ERROR, ghost));
        vm.prank(owner2);
        sra.addOrchestrator(orch, ghost); // vote 2 executes the body -> UnresolvedWallet
        assertFalse(sra.isAdmitted(orch));
    }

    /// [B] same for replaceWallet.
    function test_ReplaceWallet_UnresolvableWallet_Reverts() public {
        address oldOrch = _wallet("b4b-orch");
        _admit(oldOrch, _wallet("b4b-wallet"));
        address ghost = makeAddr("b4b-ghost"); // never registered
        vm.prank(owner1);
        sra.replaceWallet(oldOrch, ghost);
        vm.expectRevert(abi.encodeWithSelector(UNRESOLVED_WALLET_ERROR, ghost));
        vm.prank(owner2);
        sra.replaceWallet(oldOrch, ghost); // vote 2 executes the body -> UnresolvedWallet
    }

    /// [B] a registered (resolvable) wallet is admitted — the base semantic the whole suite relies
    /// on (regression over the base's auto-registration in _admit).
    function test_Admit_ResolvableWallet_Succeeds() public {
        address orch = _wallet("b5-orch");
        address wallet = _wallet("b5-wallet");
        _admit(orch, wallet);
        assertTrue(sra.isAdmitted(orch));
    }

    /// [B] the burn address (masked f099) stays admissible: f099 resolves to the always-existing
    /// actor 99 (pre-registered by the mock constructor), and burn-only payout rows are legitimate
    /// (FIP §2.4.4 strips f099 rows from storage). The zero require does not touch it (bytes non-zero).
    function test_Admit_BurnAddressWallet_Succeeds() public {
        address orch = _wallet("b6-orch");
        _admit(orch, BURN_ADDRESS);
        assertTrue(sra.isAdmitted(orch));
    }

    /// [B] a masked wallet for a non-system actor id resolves (its f0 key is registered) and is
    /// admitted — masked spellings are not blanket-rejected.
    function test_Admit_MaskedLargeIdWallet_Succeeds() public {
        address orch = _wallet("b7-orch");
        address maskedW = _maskedWallet(5000); // non-system id, explicitly registered
        _admit(orch, maskedW);
        assertTrue(sra.isAdmitted(orch));
    }

    // ------------------------------------------------------------------------
    // [C] resolved-ID distinctness
    // ------------------------------------------------------------------------
    // Actor 42 spelled two ways: the EOA address pinned to 42 (mock f410 key) and the masked
    // 0xff…2a spelling (mock f0(42) key). The bytes differ; the resolved actor id is 42 either way.

    /// [C] A holds the f410 spelling of actor 42; admitting B with the masked spelling creates a
    /// second row resolving to 42 -> rejected.
    function test_AddOrchestrator_DuplicateResolvedId_EOAThenMasked_Reverts() public {
        address eoaE = makeAddr("c8-eoaE");
        _registerResolve(eoaE, 42); // f410(eoaE) -> 42
        address masked42 = _maskedWallet(42); // 0xff…2a -> f0(42) -> 42
        address a = _wallet("c8-a");
        address b = _wallet("c8-b");
        _admit(a, eoaE);

        vm.prank(owner1);
        sra.addOrchestrator(b, masked42);
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.DuplicateWallet.selector, masked42));
        vm.prank(owner2);
        sra.addOrchestrator(b, masked42); // vote 2 executes the body -> DuplicateWallet
        assertFalse(sra.isAdmitted(b));
    }

    /// [C] reverse order: A holds the masked spelling, B attempts the f410 spelling -> same reject.
    function test_AddOrchestrator_DuplicateResolvedId_MaskedThenEOA_Reverts() public {
        address masked42 = _maskedWallet(42);
        address eoaE = makeAddr("c9-eoaE");
        _registerResolve(eoaE, 42);
        address a = _wallet("c9-a");
        address b = _wallet("c9-b");
        _admit(a, masked42);

        vm.prank(owner1);
        sra.addOrchestrator(b, eoaE);
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.DuplicateWallet.selector, eoaE));
        vm.prank(owner2);
        sra.addOrchestrator(b, eoaE); // vote 2 executes the body -> DuplicateWallet
        assertFalse(sra.isAdmitted(b));
    }

    /// [C] two identical masked wallets (same bytes AND same resolved id) still reject — the
    /// byte-keyed path survives under the resolved-ID check.
    function test_AddOrchestrator_DuplicateMasked_SameSpelling_Reverts() public {
        address masked42 = _maskedWallet(42);
        address a = _wallet("c10-a");
        address b = _wallet("c10-b");
        _admit(a, masked42);

        vm.prank(owner1);
        sra.addOrchestrator(b, masked42);
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.DuplicateWallet.selector, masked42));
        vm.prank(owner2);
        sra.addOrchestrator(b, masked42); // vote 2 executes the body -> DuplicateWallet
        assertFalse(sra.isAdmitted(b));
    }

    /// [C] replaceWallet to the other spelling of an admitted actor's wallet is rejected: A holds
    /// the f410 spelling of 42; governance swaps B onto masked(42) -> second row for actor 42.
    function test_ReplaceWallet_DuplicateResolvedId_CrossSpelling_Reverts() public {
        address eoaE = makeAddr("c11-eoaE");
        _registerResolve(eoaE, 42);
        address masked42 = _maskedWallet(42);
        address a = _wallet("c11-a");
        address b = _wallet("c11-b");
        _admit(a, eoaE);
        _admit(b, _wallet("c11-bw"));

        vm.prank(owner1);
        sra.replaceWallet(b, masked42);
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.DuplicateWallet.selector, masked42));
        vm.prank(owner2);
        sra.replaceWallet(b, masked42); // vote 2 executes the body -> DuplicateWallet
    }

    /// [C] re-spelling the SAME actor's wallet on its own orchestrator stays allowed: B holds the
    /// f410 spelling of 42 and swaps to the masked spelling — the scan excludes the id being
    /// replaced (otherId != id), so no second row for actor 42 is created.
    function test_ReplaceWallet_SelfSpellingSwap_Succeeds() public {
        address eoaE = makeAddr("c11s-eoaE");
        _registerResolve(eoaE, 42);
        address masked42 = _maskedWallet(42);
        address b = _wallet("c11s-b");
        _admit(b, eoaE);

        vm.prank(owner1);
        sra.replaceWallet(b, masked42);
        vm.prank(owner2);
        sra.replaceWallet(b, masked42); // second vote executes -> no duplicate row

        assertTrue(sra.isAdmitted(b));
    }

    /// [C] a removed orchestrator frees its resolved id for reuse under the OTHER spelling: A held
    /// the f410 spelling of 42 and is removed; a fresh orchestrator admits the masked spelling.
    function test_Admit_RemovedResolvedId_OtherSpelling_Reusable() public {
        address eoaE = makeAddr("c13-eoaE");
        _registerResolve(eoaE, 42);
        address masked42 = _maskedWallet(42);
        address a = _wallet("c13-a");
        address c = _wallet("c13-c");
        _admit(a, eoaE);

        _crankQuarter0(); // lift the §3.2 remove guard (q0 bound + submitted)
        _remove(a);

        _admit(c, masked42); // id 42 freed by the removal -> the masked spelling is admitted
        assertTrue(sra.isAdmitted(c));
    }

    // ------------------------------------------------------------------------
    // [D] events keep the raw wire wallet spelling (storage and events carry the governance-submitted
    //     20 bytes; the resolved id is derived, never stored or emitted)
    // ------------------------------------------------------------------------

    /// [D] OrchestratorAdmitted emits the masked wallet exactly as governance submitted it — the
    /// event must not re-emit some canonicalized spelling of the resolved actor.
    function test_Admit_MaskedWallet_EventCarriesRawSpelling() public {
        address maskedW = _maskedWallet(777);
        address orch = _wallet("d15-orch");
        vm.prank(owner1);
        sra.addOrchestrator(orch, maskedW); // vote 1 (approve)
        vm.expectEmit(true, false, false, true, address(sra));
        emit ServiceRewardsActor.OrchestratorAdmitted(orch, maskedW);
        vm.prank(owner2);
        sra.addOrchestrator(orch, maskedW); // vote 2 executes, emitting the raw spelling
    }

    /// [D] OrchestratorWalletReplaced emits the raw newWallet spelling on a masked swap.
    function test_ReplaceWallet_MaskedWallet_EventCarriesRawSpelling() public {
        address maskedW = _maskedWallet(778);
        address orch = _wallet("d15b-orch");
        _admit(orch, _wallet("d15b-wallet"));
        vm.prank(owner1);
        sra.replaceWallet(orch, maskedW);
        vm.expectEmit(true, true, false, true, address(sra));
        emit ServiceRewardsActor.OrchestratorWalletReplaced(orch, maskedW);
        vm.prank(owner2);
        sra.replaceWallet(orch, maskedW); // vote 2 executes, emitting the raw spelling
    }
}
