// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

// A/B dual-mirror tagged-slot model — acceptance tests
//
// These tests define the tagged-slot semantics through the *existing external interface*
// (submitShares / removeOrchestrator / replaceWallet / postVolume / correctVolume / fpvOf —
// signatures unchanged). The tag mechanism is internal (each slot owns its quarter tag, stored as
// quarter + 1 with 0 = never written; no rolling mirror), so the externally visible governance
// contract is unchanged: RemoveOrchestrator keeps its spec §3.2 PendingShares guard — a lagging
// removal reverts until the ended quarter's map is submitted — and ReplaceWallet stays strictly
// prospective (no guard, spec §3.2). The slot-tag encoding cases read the quarter namespace
// straight from storage (vm.load, as in SRAInvariant/SRARegistry): the tags have no public
// getter and their q+1 encoding is what the erasure ordering rests on.
//
// Time model (test base): E(Q)=100000+Q*1000; posting (E,E+300]; verification
//   (E+300,E+700]; post-binding > E+700. Governance methods execute immediately
//   (unanimousNoHold, spec §4.2). Shares are WAD-scaled (1e18 == 100%).

import {SRATestBase} from "./SRATestBase.sol";
import {FixedU18} from "../src/lib/FixedU18.sol";
import {SERVICE_ID, Share} from "../src/lib/FVMRewardTypes.sol";
import {ServiceRewardsActor} from "../src/ServiceRewardsActor.sol";

/// @dev ERC-7201 Quarter namespace slot (src/lib/SraStorage.sol) — read directly to pin the slot
///      tag encoding (q + 1, 0 = never written): the tags are internal with no public getter, and
///      their encoding is what the erasure ordering (vacant slot first) rests on.
bytes32 constant QUARTER_SLOT = 0x347e624280399e1e720d839edbd7cd00c80c69bf34cd8ee59e27f691732af300;

contract SRAAbMirrorTest is SRATestBase {
    /// Spec §3.2 guard: a lagging remove (latest bound quarter q0 has a live mirror, submission
    /// line behind — time already into q1) reverts PendingShares(1). Governance cranks the pending
    /// quarters — submitShares(0) then, after q1 binds, submitShares(1) — and the same unanimous
    /// task then completes. Mirror input: q0 [a:100, b:100] → 0.5e18 each.
    function test_Remove_Lagging_RevertsPendingShares() public {
        address a = makeAddr("a");
        address b = makeAddr("b");
        _admit(a, a);
        _admit(b, b);

        vm.roll(_quarterStart(0) + 1);
        _postAs(a, 0, _fpv(100e18));
        _postAs(b, 0, _fpv(100e18));

        // q=1: a posts again — q0's tagged slot survives, q0 stays the latest bound (map pending).
        vm.roll(_quarterStart(1) + 1);
        _postAs(a, 1, _fpv(50e18));

        // vote 2 executes the body: ended q1 awaits its share map -> guard reverts.
        vm.prank(owner1);
        sra.removeOrchestrator(b); // vote 1 (approve)
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.PendingShares.selector, 1));
        vm.prank(owner2);
        sra.removeOrchestrator(b); // vote 2: revert (task stays pending)

        // crank the pending quarters: q0 submits while still admitted, then q1 binds and submits.
        sra.submitShares(0);
        Share[] memory shares = rewardActor().getShares(SERVICE_ID);
        assertEq(shares.length, 2, "q0 map holds both contributors");
        assertEq(_shareOf(shares, a), 0.5e18, "a's q0 share is 100/200");
        assertEq(_shareOf(shares, b), 0.5e18, "b's q0 share is 100/200");
        vm.roll(_bindingStart(1) + 1); // q1 binds
        sra.submitShares(1);

        // the persisted task completes on the next second vote: remove succeeds; the q1 map is
        // [a] only (b posted nothing in q1), so b has no live slice to burn — the push is a no-op.
        vm.prank(owner2);
        sra.removeOrchestrator(b);
        assertEq(sra.isAdmitted(b), false, "b removed after the pending quarters are cleared");
        shares = rewardActor().getShares(SERVICE_ID);
        assertEq(shares.length, 1, "q1 map holds a only");
        assertEq(shares[0].wallet, a);
        assertEq(FixedU18.unwrap(shares[0].share), 1e18, "a's q1 map is the full 1e18");
        assertEq(rewardActor().strippedBurnOf(SERVICE_ID), 0, "no live slice to burn (q0 slice already paid out)");
    }

    /// Spec §3.2 guard with multi-quarter lag: the submission line was never cranked; q2 is the
    /// latest bound quarter. A removal at this point reverts PendingShares(2) (the ended quarter
    /// awaits its map); governance submits q2 (the only submittable quarter — q0/q1 are superseded,
    /// NotLatestQuarter), which advances the line to nowQ+1, then removes. The removed id's q2
    /// slice (b wrote q2) burns from the submitted snapshot. Writing q2 erased the q0 slot
    /// (oldest), so the cranked q2 map is built from q2's tag only [a:30, b:70].
    function test_Remove_MultiQuarterLag_RevertsThenCranks() public {
        address a = makeAddr("a");
        address b = makeAddr("b");
        _admit(a, a);
        _admit(b, b);

        vm.roll(_quarterStart(0) + 1);
        _postAs(a, 0, _fpv(100e18)); // A slot carries q0 (tag 1)
        vm.roll(_quarterStart(1) + 1);
        _postAs(b, 1, _fpv(100e18)); // B slot carries q1 (tag 2)
        vm.roll(_quarterStart(2) + 1);
        _postAs(a, 2, _fpv(30e18)); // third write erases the q0 slot (oldest)
        _postAs(b, 2, _fpv(70e18));

        vm.roll(_bindingStart(2) + 1); // q2 binds; no quarter ever submitted (line = 0)

        // lagging remove reverts: ended q2 awaits its share map.
        vm.prank(owner1);
        sra.removeOrchestrator(b);
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.PendingShares.selector, 2));
        vm.prank(owner2);
        sra.removeOrchestrator(b); // vote 2: revert (task stays pending)

        // crank q2 (latest bound, has a tag) — the line advances to 3 == nowQ + 1, guard lifts.
        sra.submitShares(2);

        // the persisted task completes on the next second vote; b's snapshot slice (0.7) burns.
        vm.prank(owner2);
        sra.removeOrchestrator(b);
        assertEq(sra.isAdmitted(b), false, "b removed after the pending quarter is cleared");
        Share[] memory shares = rewardActor().getShares(SERVICE_ID);
        assertEq(shares.length, 1, "q2 map: only a stored (b's row burned)");
        assertEq(shares[0].wallet, a);
        assertEq(FixedU18.unwrap(shares[0].share), 0.3e18, "a's q2 share is 30/100");
        assertEq(rewardActor().strippedBurnOf(SERVICE_ID), 0.7e18, "b's q2 slice burned");
    }

    /// No lag: the submission line already passed the latest bound quarter, so the guard is clear —
    /// removal runs the plain path: de-admit + immediate f099 push on the submitted snapshot.
    /// Kept as a regression anchor for the no-pending remove behavior.
    function test_Remove_NoLag_PerturbationBranch() public {
        address a = makeAddr("a");
        address b = makeAddr("b");
        _admit(a, a);
        _admit(b, b);

        vm.roll(_quarterStart(0) + 1);
        _postAs(a, 0, _fpv(100e18));
        _postAs(b, 0, _fpv(100e18));
        vm.roll(_bindingStart(0) + 1);
        sra.submitShares(0); // map [a:0.5, b:0.5], line = 1

        _remove(b); // guard clear → plain remove + immediate f099 push
        assertEq(sra.isAdmitted(b), false);
        Share[] memory shares = rewardActor().getShares(SERVICE_ID);
        assertEq(shares.length, 1, "perturbation push repoints b to BURN, stored map keeps a");
        assertEq(shares[0].wallet, a);
        assertEq(FixedU18.unwrap(shares[0].share), 0.5e18, "survivor share untouched");
        assertEq(rewardActor().strippedBurnOf(SERVICE_ID), 0.5e18, "b's slice burned, sum kept");
        assertEq(FixedU18.unwrap(sra.aggregatedFilecoinPayVolume(0)), 200e18, "bound aggregate is a binding snapshot");
    }

    /// After removal the orchestrator never enters future quarter maps; its already-bound
    /// slice stays burned (immediate f099 push) and the next submission reflects only survivors.
    function test_Remove_FutureQuarterMap_ExcludesRemoved() public {
        address a = makeAddr("a");
        address b = makeAddr("b");
        _admit(a, a);
        _admit(b, b);

        vm.roll(_quarterStart(0) + 1);
        _postAs(a, 0, _fpv(100e18));
        _postAs(b, 0, _fpv(100e18));
        vm.roll(_bindingStart(0) + 1);
        sra.submitShares(0); // line = 1
        _remove(b); // perturbation: b's q0 slice → BURN (0.5e18), a stays 0.5e18

        vm.roll(_quarterStart(1) + 1);
        _postAs(a, 1, _fpv(100e18)); // q1: only a writes
        vm.roll(_bindingStart(1) + 1);
        sra.submitShares(1);
        Share[] memory shares = rewardActor().getShares(SERVICE_ID);
        assertEq(shares.length, 1, "q1 map holds only a");
        assertEq(shares[0].wallet, a);
        assertEq(FixedU18.unwrap(shares[0].share), 1e18, "a receives the full q1 map");
        assertEq(rewardActor().strippedBurnOf(SERVICE_ID), 0, "q1 map has no BURN row (b not admitted)");
    }

    /// spec §3.2 ReplaceWallet is strictly prospective — no PendingShares guard (unlike remove):
    /// the swap executes even while the latest bound quarter awaits its share map. It updates the
    /// id's wallet field and re-points the current snapshot only; the submission line does not move,
    /// so the unsubmitted q0 is paid through the *new* wallet when submitShares(0) later runs
    /// (collection reads the live wallet). replace does not change the admitted set.
    function test_ReplaceWallet_Lagging_Prospective() public {
        address a = makeAddr("a");
        address b = makeAddr("b");
        address b2 = _wallet("b2");
        _admit(a, a);
        _admit(b, b);

        vm.roll(_quarterStart(0) + 1);
        _postAs(a, 0, _fpv(100e18));
        _postAs(b, 0, _fpv(100e18));

        vm.roll(_quarterStart(1) + 1);
        _postAs(a, 1, _fpv(50e18)); // q0 latest bound, unsubmitted, mirror live

        vm.prank(owner1);
        sra.replaceWallet(b, b2);
        vm.prank(owner2);
        sra.replaceWallet(b, b2); // vote 2 executes the body: no guard on replace

        assertEq(sra.isAdmitted(b), true, "replace keeps the identity admitted");
        assertEq(FixedU18.unwrap(sra.fpvOf(0, b).usd), 100e18, "live mirror value unchanged by replace");

        // the line did not advance: q0 is still submittable, and pays the replaced wallet (b2).
        sra.submitShares(0);
        Share[] memory shares = rewardActor().getShares(SERVICE_ID);
        assertEq(shares.length, 2, "q0 map rows: a + b2 (no BURN - replace repoints the wallet)");
        assertEq(_shareOf(shares, a), 0.5e18, "a's q0 share unchanged");
        assertEq(_shareOf(shares, b2), 0.5e18, "b's q0 share paid to the new wallet");
        assertEq(_shareOf(shares, b), 0, "old wallet no longer a payee");
    }

    /// Replace changes only the wallet field — prospective: the current snapshot row is re-pointed
    /// immediately, and a later submitShares of a fresh quarter collects through the *live* wallet
    /// (already replaced).
    function test_ReplaceWallet_NoLag_KeepsSnapshotWalletSwap() public {
        address a = makeAddr("a");
        address b = makeAddr("b");
        address b2 = _wallet("b2");
        _admit(a, a);
        _admit(b, b);

        vm.roll(_quarterStart(0) + 1);
        _postAs(a, 0, _fpv(100e18));
        _postAs(b, 0, _fpv(100e18));
        vm.roll(_bindingStart(0) + 1);
        sra.submitShares(0); // map [a:0.5, b:0.5], line = 1

        vm.prank(owner1);
        sra.replaceWallet(b, b2); // snapshot wallet-swap push (prospective)
        vm.prank(owner2);
        sra.replaceWallet(b, b2);
        Share[] memory shares = rewardActor().getShares(SERVICE_ID);
        assertEq(_shareOf(shares, b2), 0.5e18, "snapshot row re-pointed to the new wallet");
        assertEq(_shareOf(shares, b), 0, "old wallet no longer a payee");
        assertEq(sra.isAdmitted(b), true, "identity still admitted");

        // future submission collects through the live wallet (b2)
        vm.roll(_quarterStart(1) + 1);
        _postAs(b, 1, _fpv(100e18)); // b (identity) posts q1
        vm.roll(_bindingStart(1) + 1);
        sra.submitShares(1);
        shares = rewardActor().getShares(SERVICE_ID);
        assertEq(_shareOf(shares, b2), 1e18, "q1 map pays the replaced wallet");
        assertEq(_shareOf(shares, b), 0, "old wallet absent from the q1 map");
    }

    /// Writing the same quarter twice (post then correctVolume) must not create a new slot — the
    /// existing tagged slot is hit; a correctVolume on an unposted orchestrator joins it.
    /// Single-quarter lag — the submit reads the quarter's own tagged slot.
    function test_SubmitShares_Lagging_TagMatch() public {
        address a = makeAddr("a");
        address b = makeAddr("b");
        _admit(a, a);
        _admit(b, b);

        vm.roll(_quarterStart(0) + 1);
        _postAs(a, 0, _fpv(100e18));
        _postAs(b, 0, _fpv(200e18));

        // q=1: b corrected (a does not write) — q0's slot keeps both, q1's slot gets b only
        vm.roll(_postEnd(1) + 1);
        _correctVolume(b, 1, _fpv(300e18));

        // q0 is the latest bound quarter (q1 not bound yet): lagging submit matches the q0 tag
        sra.submitShares(0);
        Share[] memory shares = rewardActor().getShares(SERVICE_ID);
        assertEq(shares.length, 2, "both q0 contributors submitted");
        assertEq(_shareOf(shares, a) + _shareOf(shares, b), 1e18, "sum==1e18");
        assertGt(_shareOf(shares, b), _shareOf(shares, a), "b (200) out-slices a (100)");

        // q1 binds; submit matches the q1 tag (b only)
        vm.roll(_bindingStart(1) + 1);
        sra.submitShares(1);
        shares = rewardActor().getShares(SERVICE_ID);
        assertEq(shares.length, 1, "q1 map = b only");
        assertEq(shares[0].wallet, b);
        assertEq(FixedU18.unwrap(shares[0].share), 1e18);
    }

    /// Entry gates are unchanged — an already-submitted quarter, a non-latest quarter and
    /// an unbound quarter keep reverting.
    function test_SubmitShares_EntryGates_Unchanged() public {
        address a = makeAddr("a");
        _admit(a, a);

        vm.roll(_quarterStart(0) + 1);
        _postAs(a, 0, _fpv(100e18));
        vm.roll(_bindingStart(0) + 1);
        sra.submitShares(0);
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.AlreadySubmitted.selector, 0));
        sra.submitShares(0);

        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.NotBound.selector, 2));
        sra.submitShares(2); // far future, never bound
    }

    /// A gap quarter (no writes) submits as an all-zero no-op — the line advances, the map
    /// stands; the erased old quarter's input is not resubmittable but never blocks the line.
    function test_GapQuarter_NoWrite_NoOpAdvancesLine() public {
        address a = makeAddr("a");
        address b = makeAddr("b");
        _admit(a, a);
        _admit(b, b);

        vm.roll(_quarterStart(0) + 1);
        _postAs(a, 0, _fpv(100e18));
        vm.roll(_bindingStart(0) + 1);
        sra.submitShares(0); // map [a:1e18], line = 1

        vm.roll(_quarterStart(2) + 1);
        _postAs(b, 2, _fpv(50e18)); // q2 write erases q0's slot (oldest); q1 was a gap

        // q1 binds with no contribution: submitShares(1) must be an all-zero no-op.
        vm.roll(_bindingStart(1) + 1);
        sra.submitShares(1);
        Share[] memory shares = rewardActor().getShares(SERVICE_ID);
        assertEq(shares.length, 1, "gap no-op leaves the map untouched");
        assertEq(shares[0].wallet, a);

        // q2 (latest bound, has a mirror) submits normally.
        vm.roll(_bindingStart(2) + 1);
        sra.submitShares(2);
        shares = rewardActor().getShares(SERVICE_ID);
        assertEq(shares.length, 1, "q2 map = b");
        assertEq(shares[0].wallet, b);
        assertEq(FixedU18.unwrap(shares[0].share), 1e18);
    }

    /// fpvOf reads by quarter tag — the value of the quarter's own slot, 0 for a quarter
    /// with no slot (never written, or its slot erased by a newer third write).
    function test_FpvOf_QuarterTagMatch() public {
        address a = makeAddr("a");
        address b = makeAddr("b");
        _admit(a, a);
        _admit(b, b);

        vm.roll(_quarterStart(0) + 1);
        _postAs(a, 0, _fpv(100e18));
        vm.roll(_quarterStart(1) + 1);
        _postAs(b, 1, _fpv(50e18));
        assertEq(FixedU18.unwrap(sra.fpvOf(0, a).usd), 100e18, "q0 slot holds a's value");
        assertEq(FixedU18.unwrap(sra.fpvOf(1, b).usd), 50e18, "q1 slot holds b's value");

        // third write erases the oldest slot (q0) — q0 reads 0, q1/q2 keep their tagged values
        vm.roll(_quarterStart(2) + 1);
        _postAs(a, 2, _fpv(30e18));
        assertEq(FixedU18.unwrap(sra.fpvOf(0, a).usd), 0, "erased slot reads 0");
        assertEq(FixedU18.unwrap(sra.fpvOf(1, b).usd), 50e18, "surviving slot keeps its tag");
        assertEq(FixedU18.unwrap(sra.fpvOf(2, a).usd), 30e18, "new slot holds the q2 write");
        assertEq(FixedU18.unwrap(sra.fpvOf(2, b).usd), 0, "unposted orchestrator reads 0 within the tag");
    }

    /// @dev share of a wallet in the map (0 if absent).
    function _shareOf(Share[] memory shares, address wallet) internal pure returns (uint256) {
        for (uint256 i = 0; i < shares.length; i++) {
            if (shares[i].wallet == wallet) return FixedU18.unwrap(shares[i].share);
        }
        return 0;
    }

    /// @dev Reads the slot tag straight from the Quarter namespace: SraStorageQuarter packs
    ///      nextQuarter (low 64b) | mirrorAQuarter | mirrorBQuarter into the first 32B word.
    function _slotTag(uint8 slot) internal view returns (uint64 tag) {
        uint256 word = uint256(vm.load(address(sra), QUARTER_SLOT));
        return uint64(word >> (64 * (slot + 1)));
    }

    /// Tag encoding: a slot stores quarter + 1 — empty (never written) = 0, a q0 write tags its
    /// slot 1, a q1 write lands in the second slot and tags it 2. The q+1 encoding gives the
    /// never-written slot the smallest tag, so a pure-tag erasure (no content scan) always picks
    /// the vacant slot before any written quarter's slot.
    function test_SlotTag_EncodesQuarterPlusOne() public {
        address a = makeAddr("a");
        _admit(a, a);

        assertEq(_slotTag(0), 0, "slot A starts never-written (tag 0)");
        assertEq(_slotTag(1), 0, "slot B starts never-written (tag 0)");

        vm.roll(_quarterStart(0) + 1);
        _postAs(a, 0, _fpv(100e18)); // q0 write: tag = q + 1 = 1
        assertEq(_slotTag(0), 1, "q0 write tags slot A with q+1 = 1");
        assertEq(FixedU18.unwrap(sra.fpvOf(0, a).usd), 100e18, "q0 readable from its tagged slot");

        vm.roll(_quarterStart(1) + 1);
        _postAs(a, 1, _fpv(50e18)); // q1 write: vacant slot B gets tag 2
        assertEq(_slotTag(1), 2, "q1 write tags slot B with q+1 = 2");
        assertEq(_slotTag(0), 1, "q0's slot keeps its tag across the q1 write");
        assertEq(FixedU18.unwrap(sra.fpvOf(1, a).usd), 50e18, "q1 readable from its tagged slot");
    }

    /// Governance-lag slot survival (the collision the q+1 encoding removes): q0's data was
    /// written (its slot tagged 1) but submitShares(0) never ran — governance lagging. Time
    /// advances into q1 and a fresh q1 write must erase the *vacant* slot (tag 0 sorts below any
    /// written quarter's), never the q0 data slot; a later submitShares(0) then collects the q0
    /// input normally instead of an all-zero no-op.
    function test_GovernanceLag_Q1Write_KeepsQ0DataSlot() public {
        address a = makeAddr("a");
        address b = makeAddr("b");
        _admit(a, a);
        _admit(b, b);

        vm.roll(_quarterStart(0) + 1);
        _postAs(a, 0, _fpv(100e18));
        _postAs(b, 0, _fpv(200e18)); // q0: both write the q0-tagged slot
        assertEq(_slotTag(0), 1, "q0 slot tagged 1");

        // q0 never submitted (governance lag); q1: a writes a fresh quarter.
        vm.roll(_quarterStart(1) + 1); // q0 long bound (verify end E0+700); q1 in its posting window
        _postAs(a, 1, _fpv(50e18));
        assertEq(_slotTag(0), 1, "q0 data slot survives the q1 write (vacant slot erased instead)");
        assertEq(_slotTag(1), 2, "q1 write took the vacant slot B");
        assertEq(FixedU18.unwrap(sra.fpvOf(0, a).usd), 100e18, "q0's a value still readable");
        assertEq(FixedU18.unwrap(sra.fpvOf(0, b).usd), 200e18, "q0's b value still readable");

        // q0 is the latest bound quarter (q1 not bound yet): submitShares(0) collects the spared
        // q0 input — the share map is [a:100/300, b:200/300], not an all-zero no-op.
        sra.submitShares(0);
        Share[] memory shares = rewardActor().getShares(SERVICE_ID);
        assertEq(shares.length, 2, "q0 map holds both contributors (not a no-op)");
        assertEq(_shareOf(shares, a) + _shareOf(shares, b), 1e18, "shares sum to 1e18");
        assertGt(_shareOf(shares, b), _shareOf(shares, a), "b (200) out-slices a (100)");
    }
}
