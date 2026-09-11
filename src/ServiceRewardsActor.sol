// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

// Service Rewards Actor (SRA) — Service-stream share computation contract
//
// Responsibilities:
// - the orchestrator registry
// - stablecoin/Filecoin Pay allowlists
// - quarterly FilecoinPayVolume state
// - compute service-stream shares and write them to f02 (SetShares)
// - export AggregatedFilecoinPayVolume(Q) for the SWA
//
// The SRA never receives or holds value.
//
// Storage: 2 ERC-7201 namespaces (Registry/Quarter),
//       reusing Solstice.Owners (dual Safe) and Solstice.PendingTasks (governance queue).
//       The allowlists are event-only (AdmittedListsUpdated is the authoritative snapshot).

import {Epoch, currentEpoch} from "./lib/Epoch.sol";
import {FixedU18, ONE, ZERO} from "./lib/FixedU18.sol";
import {FVMRewards} from "./lib/FVMRewards.sol";
import {SERVICE_ID, Share} from "./lib/FVMRewardTypes.sol";
import {BURN_ADDRESS} from "fvm-solidity/FVMActors.sol";
import {FVMActor} from "fvm-solidity/FVMActor.sol";
import {OwnersLibrary} from "./lib/Owners.sol";
import {UnanimousGovernance} from "./lib/UnanimousGovernance.sol";
// Top-level SRA types (Binding / FilecoinPayVolume) and the ERC-7201 storage layout live in
// separate library files (SraTypes.sol / SraStorage.sol) — extracted to simplify
// the #5 proxy refactor; test files import the types from SraTypes.sol.
import {Binding, FilecoinPayVolume} from "./lib/SraTypes.sol";
import {SraStorage} from "./lib/SraStorage.sol";

contract ServiceRewardsActor is UnanimousGovernance {
    using OwnersLibrary for address;

    /// @dev Total share (f02 encoding constraint: Σ shares must be exactly == 1e18).
    FixedU18 private constant SHARE_TOTAL = ONE;

    uint256 private constant BASIS_POINTS = 10_000;

    /// @dev Admitted orchestrator cap, matching f02 MAX_RECIPIENTS.
    uint256 private constant MAX_ORCHESTRATORS = 64;
    uint256 private constant MAX_PAIRS = 64;
    uint256 private constant MAX_ALLOWLIST = 64;

    /// @notice quarterly orchestrator volume is limited to 1 trillion
    /// @dev protects against overflow in _computeShares
    FixedU18 private constant MAX_FILECOIN_PAY_VOLUME_USD = FixedU18.wrap(1e30);

    Epoch public immutable EPOCHS_PER_QUARTER;
    Epoch private immutable POST_PERIOD;
    Epoch private immutable VERIFICATION_WINDOW;
    Epoch private immutable ACTIVATION_EPOCH;

    /// @notice Upgrade-hold duration in epochs, fixed at deployment (spec 95eb9e0 §4.2: the
    ///         SRA's upgrade hold is SRA state, not a governance parameter).
    Epoch public immutable SRA_UPGRADE_HOLD;

    event OrchestratorAdmitted(address indexed orch, address wallet);
    event OrchestratorRemoved(address indexed orch);
    event OrchestratorWalletReplaced(address indexed oldOrch, address indexed newWallet);
    event BindingDeclared(address indexed payer, address indexed operator, address indexed orchestrator);
    event BindingReassigned(
        address indexed payer, address indexed operator, address indexed orchestrator, bool inherit
    );
    event BindingCanceled(address indexed payer, address indexed operator, address indexed orchestrator);
    event OwnersReplaced(address indexed prevOwner, address indexed newOwner);
    event AdmittedListsUpdated(address[] stablecoins, address[] filecoinPayContracts);
    event PricingParamsUpdated(
        uint256 minLotFloor,
        uint256 minLotAlphaNum,
        uint256 minLotAlphaDen,
        uint256 priceBand,
        uint256 registrationCutoff
    );
    event VolumePosted(uint64 indexed q, address indexed orchestrator, FixedU18 volume);
    event VolumeCorrected(uint64 indexed q, address indexed orchestrator, FixedU18 volume);
    event SharesSubmitted(uint64 indexed q, uint256 recipientCount, FixedU18 totalUsd);

    error NotAdmitted(address orch);
    error AlreadyAdmitted(address orch);
    error AtCapacity();
    error AlreadyBound(bytes32 pairId);
    error PairNotBound(bytes32 pairId);
    error NotInPostingWindow(uint64 q);
    error NotInVerificationWindow(uint64 q);
    error NotBound(uint64 q);
    error AlreadyPosted(uint64 q);
    error PendingShares(uint64 q); // FIP-0118 §3.2: RemoveOrchestrator reverts while an ended quarter awaits its share map
    error AlreadySubmitted(uint64 q);
    error NotLatestQuarter(uint64 q); // FIP-0118 §4.2: an older quarter's shares can never overwrite a newer quarter's
    error TooManyPairs(); // registerPairs batch exceeds MAX_PAIRS
    error ZeroWallet(address wallet); // the zero address is never a valid payout wallet
    error UnresolvedWallet(address wallet); // wallet does not resolve to an existing actor (FIP §2.4.4)
    error DuplicateWallet(address wallet); // another admitted row resolves to the same actor id (byte-equal or cross-spelling)
    error InvalidParameter();

    /// @param owner1,owner2 the two governance owners
    /// @param epochsPerQuarter quarter length (epochs)
    /// @param postPeriod posting window (epochs)
    /// @param verificationWindow verification window (epochs)
    /// @param activationEpoch end epoch of quarter 0 (window start)
    /// @param minLot,priceBand initial FIL pricing parameters (governable; authoritative for the off-chain indexer, FIPs#1275)
    constructor(
        address owner1,
        address owner2,
        Epoch epochsPerQuarter,
        Epoch postPeriod,
        Epoch verificationWindow,
        Epoch activationEpoch,
        Epoch upgradeHold
    ) {
        owner1.addOwner();
        owner2.addOwner();

        require(
            Epoch.unwrap(epochsPerQuarter) > 0 && Epoch.unwrap(postPeriod) > 0 && Epoch.unwrap(verificationWindow) > 0
                && uint256(Epoch.unwrap(postPeriod)) + uint256(Epoch.unwrap(verificationWindow))
                    < uint256(Epoch.unwrap(epochsPerQuarter)),
            InvalidParameter()
        );

        EPOCHS_PER_QUARTER = epochsPerQuarter;
        POST_PERIOD = postPeriod;
        VERIFICATION_WINDOW = verificationWindow;
        ACTIVATION_EPOCH = activationEpoch;
        SRA_UPGRADE_HOLD = upgradeHold;

        // id allocator starts at 1: 0 is the unregistered sentinel (activeIdOf[addr] == 0)
        SraStorage.registry().nextId = 1;
    }

    // ------------------------------------------------------------------------
    // Window and quarter utilities
    // ------------------------------------------------------------------------

    /// @dev Quarter anchor E = FIP-0118 Start(q+1), where quarter q's cycle opens; reverts with
    ///      InvalidParameter on uint64 overflow.
    function _quarterStart(uint64 q) internal view returns (Epoch) {
        uint256 start = uint256(Epoch.unwrap(ACTIVATION_EPOCH)) + uint256(q) * uint256(Epoch.unwrap(EPOCHS_PER_QUARTER));
        require(start <= type(uint64).max, InvalidParameter());
        return Epoch.wrap(uint64(start));
    }

    /// @dev posting window [E, E+POST).
    function _inPostingWindow(uint64 q) internal view returns (bool) {
        Epoch nowE = currentEpoch();
        Epoch e = _quarterStart(q);
        return nowE >= e && nowE < e + POST_PERIOD;
    }

    /// @dev verification window [E+POST, E+POST+VERIFY).
    function _inVerificationWindow(uint64 q) internal view returns (bool) {
        Epoch nowE = currentEpoch();
        Epoch postEnd = _quarterStart(q) + POST_PERIOD;
        return nowE >= postEnd && nowE < postEnd + VERIFICATION_WINDOW;
    }

    /// @dev post-binding: now >= E+POST+VERIFY.
    function _afterBinding(uint64 q) internal view returns (bool) {
        Epoch nowE = currentEpoch();
        Epoch verifyEnd = _quarterStart(q) + POST_PERIOD + VERIFICATION_WINDOW;
        return nowE >= verifyEnd;
    }

    /// @dev Quarter containing `nowE`, derived from the clock alone:
    ///      E(q) = ACTIVATION_EPOCH + q * EPOCHS_PER_QUARTER, so the time quarter is a pure
    ///      function of the epoch. Unlike the slot tags (which advance only on writes), this never
    ///      lags: a gap quarter with no volume is still a *time* quarter. Pre-activation epochs
    ///      (possible in test environments; the contract itself starts at ACTIVATION_EPOCH)
    ///      saturate to quarter 0, matching the initial submission line (nextQuarter = 0).
    function _quarterOf(Epoch nowE) internal view returns (uint64) {
        if (nowE < ACTIVATION_EPOCH) return 0;
        unchecked {
            // Safe: subtraction is guarded by the early return above (nowE >= ACTIVATION_EPOCH);
            // division cannot divide by zero because the constructor requires epochsPerQuarter > 0.
            uint256 offset = uint256(Epoch.unwrap(nowE)) - uint256(Epoch.unwrap(ACTIVATION_EPOCH));
            return uint64(offset / uint256(Epoch.unwrap(EPOCHS_PER_QUARTER)));
        }
    }

    /// @dev Time-correct the mirror cache before a write: if the active quarter lags the time
    ///      quarter (a gap quarter with no writes), advance in one step — gap quarters carry no
    ///      data, so prevFpv becomes 0 (one-step jump semantics, keeping the prevFpv == activeQ-1
    ///      invariant). Idempotent when already current. Keeps the slot semantics (fpv/prevFpv
    ///      ownership) aligned with the clock so no time judgment ever reads a stale cache.
    function _syncMirror(SraStorage.SraStorageQuarter storage qt) internal {
        uint64 nowQ = _quarterOf(currentEpoch());
        if (qt.activeQuarter < nowQ) _advanceMirror(qt, nowQ);
    }

    /// @dev Mirror advance: the first write of a new quarter (postVolume or correctVolume
    ///      with q != activeQ) backs the previous active-quarter contributions up into the previous-
    ///      quarter mirror — exclusion-fixed (frozenAtPostEnd ? 0 : fpv), because the freeze state
    ///      of the previous quarter's E+POST is no longer derivable once the quarter has advanced —
    ///      and clears the active slots for the new quarter. When q skips quarters (q > activeQ + 1,
    ///      a gap quarter with no volume — necessarily unwritten, postVolume rejects zero), the
    ///      mirror jumps in one step: quarter q-1 is a gap with no data, so prevFpv is zero; the
    ///      previous active-quarter data is superseded (that quarter has no legal submission path
    ///      once the gap quarter has bound — NotLatestQuarter). O(n) per write regardless of gap size.
    function _advanceMirror(SraStorage.SraStorageQuarter storage qt, uint64 q) internal {
        SraStorage.SraStorageRegistry storage r = SraStorage.registry();
        for (uint256 i = 0; i < r.admittedIds.length; i++) {
            _setMirror(r.orchestrators[r.admittedIds[i]], slot, ZERO);
        }
        qt.activeQuarter = q;
    }

    // ------------------------------------------------------------------------
    // Orchestrator operations (called by self, no governance)
    // ------------------------------------------------------------------------

    /// @notice An admitted, non-frozen orchestrator declares binding pairs; reverts if the pair is already bound to another (uniqueness).
    /// @dev C1: parameter uses a named struct Binding[] (inline tuple-array params are illegal in Solidity).
    function registerPairs(Binding[] calldata pairs) external {
        require(pairs.length <= MAX_PAIRS, TooManyPairs()); // batch bound
        // single storage pointer — avoids hashing the orchestrators mapping twice
        SraStorage.SraStorageRegistry storage r = SraStorage.registry();
        uint64 id = r.activeIdOf[msg.sender];
        SraStorage.OrchestratorInfo storage o = r.orchestrators[id];
        require(id != 0 && o.admitted, NotAdmitted(msg.sender));

        for (uint256 i = 0; i < pairs.length; i++) {
            bytes32 pairId = _pairId(pairs[i].payer, pairs[i].operator);
            uint64 boundId = r.bindings[pairId];
            // Uniqueness: if bound and the bound id is still admitted -> reject; if the bound id was
            // Removed (admitted=false) -> treated as unclaimed, claimable (spec §4.2). ids are never
            // reused, so a removed id stays resolvable — no alias chain required.
            if (boundId != 0 && r.orchestrators[boundId].admitted) {
                revert AlreadyBound(pairId);
            }
            r.bindings[pairId] = id;
            emit BindingDeclared(pairs[i].payer, pairs[i].operator, msg.sender);
        }
    }

    /// @notice An admitted orchestrator releases a pair bound to it — self-service, not governance: the pair
    ///         returns to unclaimed and claimable again (spec §4.2).
    /// @dev The boundId != 0 term is load-bearing: without it an unadmitted caller on a never-bound pair
    ///      would pass the caller check (0 == 0) and emit BindingCanceled with a zero orchestrator.
    function cancelBinding(address payer, address operator) external {
        SraStorage.SraStorageRegistry storage r = SraStorage.registry();
        bytes32 pairId = _pairId(payer, operator);
        uint64 boundId = r.bindings[pairId];
        require(
            boundId != 0 && r.orchestrators[boundId].admitted && r.activeIdOf[msg.sender] == boundId,
            PairNotBound(pairId)
        );
        address orchestrator = r.orchestrators[boundId].orchestrator;
        delete r.bindings[pairId];
        emit BindingCanceled(payer, operator, orchestrator);
    }

    /// @notice During posting, at most one posting per quarter; the value is a single USD total
    ///         (FilecoinPayVolume_i(Q): stablecoin face USD + off-chain-converted FIL volume, FIP-0118 FIPs#1275).
    function postVolume(uint64 q, FixedU18 fpv) external {
        // single storage pointer — avoids hashing the orchestrators mapping twice
        SraStorage.SraStorageRegistry storage r = SraStorage.registry();
        uint64 id = r.activeIdOf[msg.sender];
        SraStorage.OrchestratorInfo storage o = r.orchestrators[id];
        require(id != 0 && o.admitted, NotAdmitted(msg.sender));
        require(_inPostingWindow(q), NotInPostingWindow(q));

        // The single USD total is the only on-chain input that feeds _computeShares;
        // bound it at the entry so the share arithmetic cannot overflow (see MAX_FILECOIN_PAY_VOLUME_USD).
        // Reject zero: a zero total is equivalent to not posting (both excluded from the
        // aggregate), so `usd == 0` unambiguously means "not posted".
        require(fpv > ZERO && fpv <= MAX_FILECOIN_PAY_VOLUME_USD, InvalidParameter());

        SraStorage.SraStorageQuarter storage qt = SraStorage.quarter();

        // Slot target: the quarter's own tagged slot (reused across posters/corrections), or a
        // fresh slot built by erasing the most sacrificable one (smallest tag — _slotForWrite).
        uint8 slot = _slotForWrite(q);
        require(_mirrorOf(o, slot) == ZERO, AlreadyPosted(q));
        _setMirror(o, slot, fpv);
        qt.totalUsd[q] = qt.totalUsd[q] + fpv;

        emit VolumePosted(q, msg.sender, fpv);
    }

    // ------------------------------------------------------------------------
    // Governance operations (dual Safe, unanimous path; no-hold on signature-finalized methods)
    // ------------------------------------------------------------------------

    /// @notice Admits an orchestrator with its payout wallet; rejects when admitted total >= 64.
    /// @dev The payout wallet must be non-zero and resolve to an existing actor's id, and its
    ///      resolved id must not duplicate any other admitted row's (FIP §2.4.4).
    /// @dev Re-admit of a previously removed/replaced address allocates a fresh id — a fresh identity with no
    ///      bindings, FilecoinPayVolume, or history. Because ids are never reused and the address mapping (activeIdOf)
    ///      is cleared on remove/replace, there is no residual alias-chain or state to clean up.
    function addOrchestrator(address orch, address wallet) external unanimousNoHold(keccak256(msg.data)) {
        SraStorage.SraStorageRegistry storage r = SraStorage.registry();
        require(r.activeIdOf[orch] == 0, AlreadyAdmitted(orch));
        require(r.admittedIds.length < MAX_ORCHESTRATORS, AtCapacity());
        _assertWalletAdmissible(wallet, 0); // zero → resolve → resolved-id uniqueness
        uint64 id = r.nextId;
        r.nextId = id + 1;
        SraStorage.OrchestratorInfo storage o = r.orchestrators[id];
        o.orchestrator = orch;
        o.wallet = wallet;
        o.admitted = true;
        o.admittedIndex = uint64(r.admittedIds.length);
        r.activeIdOf[orch] = id;
        r.admittedIds.push(id);
        emit OrchestratorAdmitted(orch, wallet);
    }

    /// @notice Permanent removal; releases all bindings (pairs return to unclaimed) (spec §4.2).
    /// @dev Timing guard (spec §3.2): RemoveOrchestrator reverts while an ended quarter awaits
    ///      its share map — from the end of a quarter until that quarter's SubmitShares has run.
    ///      Governance clears the pending quarter by cranking SubmitShares first, then removes in a
    ///      later message (spec keeps the flows separate: SubmitShares is the only moment survivors
    ///      gain from a removal, FIP-0118 §3.2).
    function removeOrchestrator(address orch) external unanimousNoHold(keccak256(msg.data)) {
        SraStorage.SraStorageRegistry storage r = SraStorage.registry();
        uint64 id = r.activeIdOf[orch];
        SraStorage.OrchestratorInfo storage o = r.orchestrators[id];
        require(id != 0 && o.admitted, NotAdmitted(orch));
        (bool hasPending, uint64 pendingQ) = _pendingSharesQuarter();
        if (hasPending) revert PendingShares(pendingQ);
        // No aggregate deduction: the guard makes any removal post-binding (nextQuarter == nowQ + 1
        // implies the active quarter was already submitted), so the aggregate is a binding snapshot;
        // the orchestrator's exclusion from later quarters follows from it leaving the admitted list.
        o.admitted = false;
        r.activeIdOf[orch] = 0;
        uint64 idx = o.admittedIndex;
        uint64 lastId = r.admittedIds[r.admittedIds.length - 1];
        _swapRemove(r.admittedIds, idx);
        // swap double-write: the moved id's index must follow it, or the admittedIndex invariant (I6) breaks
        if (id != lastId) r.orchestrators[lastId].admittedIndex = idx;
        // dead pointer: the removed id leaves the list, its index no longer addresses a live slot
        delete o.admittedIndex;
        // Immediate f099 repoint: the removed id's f02 row moves to BURN_ADDRESS from the moment the
        // removal binds — its slice burns, survivors' rows stay untouched until the next SubmitShares.
        // o.wallet is unchanged, so it still names the row's address. A no-op when the id has no f02
        // row (never submitted, or floored to zero).
        FVMRewards.tryReplaceAddress(SERVICE_ID, o.wallet, BURN_ADDRESS);
        emit OrchestratorRemoved(orch);
    }

    /// @notice Swaps the payout wallet (spec §3.2): the Orchestrator identity does not move — bindings,
    ///         accrued volumes, and contribution slots stay with the same orchestrator.
    /// @dev O(1) wallet re-point: only the id's wallet field changes. bindings and quarterly mirror
    ///      state both key on the id, so they keep resolving to the same orchestrator (the identity
    ///      never moves), and historical quarter FilecoinPayVolume remains aggregated. Strictly
    ///      prospective (spec §3.2): the swap is not gated on the submission line — an ended quarter
    ///      awaiting its share map keeps the old wallet for the already-bound map; the new wallet
    ///      pays from the next submission onward.
    /// @dev The new payout wallet must be non-zero, resolve to an existing actor's id, and its
    ///      resolved id must not duplicate any other admitted row's (the row being replaced is
    ///      exempt — re-spelling its own actor is a single row; FIP §2.4.4).
    function replaceWallet(address oldOrch, address newWallet) external unanimousNoHold(keccak256(msg.data)) {
        SraStorage.SraStorageRegistry storage r = SraStorage.registry();
        uint64 id = r.activeIdOf[oldOrch];
        require(id != 0 && r.orchestrators[id].admitted, NotAdmitted(oldOrch));
        _assertWalletAdmissible(newWallet, id); // zero → resolve → resolved-id uniqueness; own row exempt
        address oldWallet = r.orchestrators[id].wallet;
        r.orchestrators[id].wallet = newWallet;
        // Immediate f02 wallet repoint: the id's row share stays (prospective — identity and accrued
        // do not move), only the row's wallet changes. A no-op when the id has no row, or when
        // newWallet resolves to oldWallet (f02 rejects an unchanged/duplicate address).
        FVMRewards.tryReplaceAddress(SERVICE_ID, oldWallet, newWallet);
        emit OrchestratorWalletReplaced(oldOrch, newWallet);
    }

    /// @notice Disputed pair reassignment; volume is credited to the new orchestrator from the change epoch onward (spec §4.2).
    /// @dev inherit is carried in the event so every off-chain verifier applies the same application scope
    ///      (inherit = false for a client-orchestrator change, inherit = true for a wrongful-claim adjudication);
    ///      the contract records the binding, not the scope — the application epoch is off-chain semantics.
    function reassignBinding(address payer, address operator, address orch, bool inherit)
        external
        unanimousNoHold(keccak256(msg.data))
    {
        uint64 id = _requireAdmittedId(orch);
        SraStorage.registry().bindings[_pairId(payer, operator)] = id;
        emit BindingReassigned(payer, operator, orch, inherit);
    }

    /// @notice Batch form of reassignBinding: each item reuses the single path's validation and
    ///         event (per-item _requireAdmittedId, per-item BindingReassigned); atomicity comes
    ///         from revert — any invalid item rolls the whole batch back.
    function reassignBindings(Reassignment[] calldata rs) external unanimousNoHold(keccak256(msg.data)) {
        require(rs.length <= MAX_PAIRS, TooManyPairs());
        SraStorage.SraStorageRegistry storage r = SraStorage.registry();
        for (uint256 i = 0; i < rs.length; i++) {
            uint64 id = _requireAdmittedId(rs[i].orch);
            r.bindings[_pairId(rs[i].payer, rs[i].operator)] = id;
            emit BindingReassigned(rs[i].payer, rs[i].operator, rs[i].orch, rs[i].inherit);
        }
    }

    /// @notice Owner rotation, effective immediately (unanimousNoHold path,
    ///         aligned with upstream SWA's replaceOwner).
    function replaceOwner(address prevOwner, address newOwner) external unanimousNoHold(keccak256(msg.data)) {
        prevOwner.removeOwner();
        newOwner.addOwner();
        emit OwnersReplaced(prevOwner, newOwner);
    }

    /// @notice Updates the stablecoin + Filecoin Pay allowlists (exclusive update, spec §4.2).
    /// @dev Event-only: the allowlists are not stored on-chain; AdmittedListsUpdated carries the
    ///      full arrays (snapshot semantics) and is the sole authoritative record. Each call's
    ///      array parameters replace the entire allowlist (exclusive update). Array parameters
    ///      require normalization (only same-order calldata yields an identical taskId).
    function setAdmittedLists(address[] calldata stablecoins, address[] calldata filecoinPayContracts)
        external
        unanimousNoHold(keccak256(msg.data))
    {
        require(stablecoins.length <= MAX_ALLOWLIST && filecoinPayContracts.length <= MAX_ALLOWLIST, InvalidParameter());
        emit AdmittedListsUpdated(stablecoins, filecoinPayContracts);
    }

    /// @notice Updates the FIL pricing parameters MIN_LOT/PRICE_BAND.
    ///         FIPs#1275: authoritative for the off-chain indexer's conversion, not an on-chain computation.
    function setPricingParams(uint256 minLot, uint256 priceBand)
        external
        unanimous(keccak256(msg.data), SRA_CANCEL_HOLD)
    {
        require(priceBand <= BASIS_POINTS, InvalidParameter());
        SraStorage.SraStorageParams storage p = SraStorage.params();
        p.minLot = minLot;
        p.priceBand = priceBand;
        emit PricingParamsUpdated(minLot, priceBand);
    }

    /// @notice Either Safe calls _veto alone to discard a queued change (spec §4.2, _veto).
    function cancelPending(bytes32 taskId) external {
        _veto(taskId);
    }

    // ------------------------------------------------------------------------
    // correctVolume (dual Safe + effective immediately within the window, unanimousNoHold path)
    // ------------------------------------------------------------------------

    /// @notice Only within the verification window, dual-Safe joint; replaces the posted value with the recomputed figure,
    ///         or supplies the recomputed figure for an unposted orchestrator; effective immediately — the verification
    ///         window itself is the hold (spec §4.2), allows bidirectional correction. Value is a single USD total (FIP-0118 FIPs#1275).
    /// @dev The unanimousNoHold modifier handles dual-Safe owner validation; the function body validates the verification window.
    function correctVolume(address orch, uint64 q, FixedU18 value) external unanimousNoHold(keccak256(msg.data)) {
        require(_inVerificationWindow(q), NotInVerificationWindow(q));
        uint64 id = _requireAdmittedId(orch);

        // Same business-domain bound as postVolume (governance path into the same FilecoinPayVolume storage).
        require(value <= MAX_FILECOIN_PAY_VOLUME_USD, InvalidParameter());

        SraStorage.OrchestratorInfo storage o = SraStorage.registry().orchestrators[id];
        SraStorage.SraStorageQuarter storage qt = SraStorage.quarter();

        // Time-correct the mirror cache first (gap quarters advance on the clock, not on
        // writes): the window checks bound q to the current time quarter, and _syncMirror
        // advances activeQ to it — correctVolume can be the first writer of a quarter
        // (supplying recomputed figures for a quarter nobody posted); the sync's advance backs
        // the previous quarter's data up into prevFpv.
        _syncMirror(qt);

        // Read the old value *after* the advance: on an advance the previous
        // quarter's fpv has already been backed up into prevFpv and fpv cleared, so oldUsd = 0
        // and the counter receives the full value; without an advance oldUsd is the current
        // quarter's value and the counter is adjusted by (value - oldUsd).
        FixedU18 oldUsd = o.fpv;
        o.fpv = value; // FixedU18 — 18-decimal USD; value==0 clears (equivalent to not posted)

        // E+POST has passed (verification window): frozenAtPostEnd is final — a frozen-at-E+POST
        // orchestrator never enters the aggregate (its value is recorded, not counted).
        if (!o.frozenAtPostEnd) {
            qt.totalUsd[q] = qt.totalUsd[q] + value - oldUsd;
        }

        emit VolumeCorrected(q, orch, value);
    }

    // ------------------------------------------------------------------------
    // Mechanism operations (permissionless)
    // ------------------------------------------------------------------------

    /// @notice Permissionless after binding; SplitRule over the bound USD values → f02.SetShares(2, map) (spec §4.2).
    ///         Reverts when this quarter's map has already been submitted (FIP-0118 §4.2); an all-zero quarter is a
    ///         benign no-op: SplitRule is not evaluated and the existing share map stands (FIPs#1275).
    function submitShares(uint64 q) external {
        require(_afterBinding(q), NotBound(q));
        // FIP-0118 §4.2: SubmitShares operates on the **latest** quarter whose volumes are bound, so an
        // older quarter's shares can never overwrite a newer quarter's. Because _afterBinding is monotonic
        // in q, q is the latest bound quarter iff q + 1 is not yet bound. (At q = uint64.max the first
        // require's _quarterStart range guard already reverts, so q + 1 cannot overflow here.)
        require(!_afterBinding(q + 1), NotLatestQuarter(q));

        SraStorage.SraStorageRegistry storage r = SraStorage.registry();
        SraStorage.SraStorageQuarter storage qt = SraStorage.quarter();
        require(q + 1 != qt.nextQuarter, AlreadySubmitted(q));

        // Slot selection by quarter tag: the slot tagged q+1 holds this quarter's
        // input; a bound quarter with no tagged slot (gap — posting/verification elapsed with no
        // write) has no data and submits as an all-zero no-op: it still counts as submitted, the
        // existing map stands.
        (bool hit, uint8 slot) = _slotQuarterOf(q);
        if (!hit) {
            qt.nextQuarter = q + 1;
            return;
        }
        Share[] memory shares = new Share[](r.admittedIds.length);
        // Sum over the collected entries (the current admitted ids) — self-consistent with the
        // collection. The quarter counter (totalUsd) is a binding snapshot that can outlive a
        // lag-window remove, so it must not drive the largest-remainder split
        // (an oversized total underflowed the bump loop). aggregatedFilecoinPayVolume keeps the counter (O(1)).
        (uint256 count, FixedU18 total) = _collectSlot(slot, shares);

        // FIP-0118: an all-zero quarter is a benign no-op — no SplitRule, no SetShares, existing map stands.
        // It still counts as submitted (the quarter cannot be resubmitted).
        if (total == ZERO) {
            qt.nextQuarter = q + 1;
            return;
        }

        _computeShares(shares, count, total);
        _submitMap(qt, q, shares, count, total);
    }

    // ------------------------------------------------------------------------
    // Read-only (for SWA and external audit)
    // ------------------------------------------------------------------------

    // forge-lint: disable-next-item(mixed-case-function) — FIP-0118 spec method name (selector-affecting)
    /// @notice Returns the post-binding USD aggregate (FIP-0118 §4.2): Σ of each non-excluded posted orchestrator's
    ///         bound USD value. Pure view — the FIL→USD conversion happens off-chain (FIPs#1275), so there is no
    ///         on-chain finalize to trigger. O(1) quarter counter lookup for every quarter (the SWA's hot path).
    /// @dev Reverts NotBound(q) before binding — distinguishes "quarter not yet bound" (call too early; the SWA
    ///      does not need to re-enforce the check) from "quarter with zero declared volume" (legitimately returns 0).
    function aggregatedFilecoinPayVolume(uint64 q) external view returns (FixedU18 usd) {
        require(_afterBinding(q), NotBound(q));
        // Quarter counter array — O(1) for every quarter. Values are fixed once the mirror
        // advances (spec determinism: the registry is constant within a quarter, so the
        // aggregate cannot drift with later remove/replace).
        return SraStorage.quarter().totalUsd[q];
    }

    /// @dev Quarter anchor epoch for quarter q (Epoch-typed; exposed per the IServiceRewardsActor interface the SWA consumes).
    function quarterStart(uint64 q) external view returns (Epoch) {
        return _quarterStart(q);
    }

    function isAdmitted(address orch) external view returns (bool) {
        SraStorage.SraStorageRegistry storage r = SraStorage.registry();
        uint64 id = r.activeIdOf[orch];
        return id != 0 && r.orchestrators[id].admitted;
    }

    function admittedCount() external view returns (uint64) {
        return uint64(SraStorage.registry().admittedIds.length); // MAX_ORCHESTRATORS bound keeps this < 2^64
    }

    function bindingOf(address payer, address operator) external view returns (address) {
        SraStorage.SraStorageRegistry storage r = SraStorage.registry();
        uint64 id = r.bindings[_pairId(payer, operator)];
        if (id == 0 || !r.orchestrators[id].admitted) return address(0);
        return r.orchestrators[id].orchestrator;
    }

    function fpvOf(uint64 q, address orch) external view returns (FilecoinPayVolume memory) {
        SraStorage.SraStorageRegistry storage r = SraStorage.registry();
        uint64 id = r.activeIdOf[orch];
        SraStorage.OrchestratorInfo storage o = r.orchestrators[id];
        // Tag match: read the slot tagged q+1 (quarter q's own slot). A quarter with no live slot
        // (never written, or its slot erased by a newer write) reads 0 — the aggregate (totalUsd)
        // is the only historical read.
        SraStorage.SraStorageQuarter storage qt = SraStorage.quarter();
        if (_tagMatches(qt.mirrorAQuarter, q)) return FilecoinPayVolume({usd: o.mirrorA});
        if (_tagMatches(qt.mirrorBQuarter, q)) return FilecoinPayVolume({usd: o.mirrorB});
        return FilecoinPayVolume({usd: ZERO});
    }

    function orchestratorCount() external view returns (uint64) {
        return uint64(SraStorage.registry().admittedIds.length);
    }

    // ------------------------------------------------------------------------
    // Internal logic
    // ------------------------------------------------------------------------

    /// @dev Collects the full quarterly input of mirror slot `slot` over the *current* admitted ids
    ///      (the same set submitShares would collect) into `shares`. Returns the collected count and
    ///      the Σ USD; the wallet field carries each id's current effective wallet, so a prior
    ///      replaceWallet already re-points it.
    function _collectSlot(uint8 slot, Share[] memory shares) internal view returns (uint256 count, FixedU18 total) {
        SraStorage.SraStorageRegistry storage r = SraStorage.registry();
        for (uint256 i = 0; i < r.admittedIds.length; i++) {
            uint64 id = r.admittedIds[i];
            SraStorage.OrchestratorInfo storage o = r.orchestrators[id];
            FixedU18 usd = _mirrorOf(o, slot);
            if (usd == ZERO) continue;
            shares[count] = Share({wallet: o.wallet, share: usd});
            total = total + usd;
            count++;
        }
    }

    /// @dev Submits a computed share map (submitShares' tail): trims zero-share rows
    ///      (largest-remainder can floor a tiny usd to 0 when the residue top-up round count is
    ///      smaller than the active count; real f02 SetShares rejects share==0 entries, as does the
    ///      mock), advances the submission line (CEI: before the external call) and pushes to f02.
    function _submitMap(
        SraStorage.SraStorageQuarter storage qt,
        uint64 q,
        Share[] memory shares,
        uint256 count,
        FixedU18 total
    ) internal {
        uint256 kept = 0;
        for (uint256 i = 0; i < count; i++) {
            if (shares[i].share > ZERO) {
                shares[kept] = shares[i];
                kept++;
            }
        }
        if (kept < shares.length) {
            assembly ("memory-safe") {
                mstore(shares, kept)
            }
        }

        qt.nextQuarter = q + 1; // CEI: mark before the external call
        FVMRewards.setShares(SERVICE_ID, shares);
        emit SharesSubmitted(q, shares.length, total); // totalUsd as FixedU18 (18-decimal USD)
    }

    /// @dev SplitRule share computation: floor + largest-remainder (remainder descending, first residue entries +1).
    ///      Writes the share field of each entry in place; the wallet field is filled by the caller.
    function _computeShares(Share[] memory shares, uint256 n, FixedU18 total) internal pure {
        uint256[] memory remainders = new uint256[](n);
        FixedU18 residue = SHARE_TOTAL;
        for (uint256 i = 0; i < n; i++) {
            FixedU18 usd = shares[i].share;
            shares[i].share = usd / total;
            remainders[i] = FixedU18.unwrap(usd % total);
            residue = residue - shares[i].share;
        }
        // Largest-remainder top-up
        uint256[] memory order = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            order[i] = i;
        }
        _mergeSortByRemainder(order, remainders);
        for (uint256 r = 0; r < FixedU18.unwrap(residue); r++) {
            shares[order[r]].share = shares[order[r]].share + FixedU18.wrap(1);
        }
    }

    /// @dev Stable merge sort of order[] by (remainder desc, index asc) — O(n log n).
    ///      Stability is required: equal remainders must top up in input order (lowest index
    ///      first) to match the per-round pick. Merge is the minimal stable O(n log n) sort;
    ///      insertion/selection stay O(n²) and would re-introduce the quadratic behavior.
    function _mergeSortByRemainder(uint256[] memory order, uint256[] memory remainders) private pure {
        uint256 n = order.length;
        if (n < 2) return;
        uint256[] memory buf = new uint256[](n);
        _mergeSortByRemainderRec(order, remainders, buf, 0, n);
    }

    function _mergeSortByRemainderRec(
        uint256[] memory order,
        uint256[] memory remainders,
        uint256[] memory buf,
        uint256 lo,
        uint256 hi
    ) private pure {
        if (hi - lo < 2) return;
        uint256 mid = (lo + hi) / 2;
        _mergeSortByRemainderRec(order, remainders, buf, lo, mid);
        _mergeSortByRemainderRec(order, remainders, buf, mid, hi);
        uint256 i = lo;
        uint256 j = mid;
        uint256 k = lo;
        while (i < mid && j < hi) {
            if (_remainderBefore(order[i], order[j], remainders)) {
                buf[k++] = order[i++];
            } else {
                buf[k++] = order[j++];
            }
        }
        while (i < mid) buf[k++] = order[i++];
        while (j < hi) buf[k++] = order[j++];
        for (k = lo; k < hi; k++) {
            order[k] = buf[k];
        }
    }

    /// @dev True when a must sort before b: strictly larger remainder, or equal remainder with a smaller index.
    function _remainderBefore(uint256 a, uint256 b, uint256[] memory remainders) private pure returns (bool) {
        if (remainders[a] != remainders[b]) return remainders[a] > remainders[b];
        return a < b;
    }

    /// @dev Wallet-admission gate shared by addOrchestrator / replaceWallet:
    ///      zero is rejected before any resolve — address(0)'s f410 resolution is registry-dependent
    ///      (fresh devnet misses it, mainnet resolves it to a resident actor), so the local byte
    ///      check must win in both worlds; the wallet must then resolve to an existing actor
    ///      (FIP §2.4.4); the resolved id must not duplicate any other admitted row's. The dedup key
    ///      is the resolved id, not the wallet bytes — one actor has two wire spellings (f410
    ///      delegated vs masked 0xff…) that differ in bytes but resolve to one id. selfId excludes
    ///      the row being replaced (its own re-spelling is a single row); addOrchestrator passes 0.
    function _assertWalletAdmissible(address wallet, uint64 selfId) internal view {
        require(wallet != address(0), ZeroWallet(wallet));
        uint64 wid = _resolveWallet(wallet);
        SraStorage.SraStorageRegistry storage r = SraStorage.registry();
        for (uint256 i = 0; i < r.admittedIds.length; i++) {
            uint64 otherId = r.admittedIds[i];
            if (otherId == selfId) continue;
            // admitted rows resolved at admission; a row that no longer resolves is a data fault the
            // admission must surface (revert names the stale wallet), not silently compare as unequal
            if (_resolveWallet(r.orchestrators[otherId].wallet) == wid) revert DuplicateWallet(wallet);
        }
    }

    /// @dev Resolves a payout wallet to its actor id; reverts UnresolvedWallet when the address maps
    ///      to no existing actor (FIP §2.4.4: every payout wallet must exist on-chain before the SRA
    ///      names it). The resolved id is the dedup key — both spellings of an actor land on it.
    function _resolveWallet(address wallet) internal view returns (uint64 id) {
        (bool exists, uint64 resolved) = FVMActor.tryGetActorId(wallet);
        if (!exists) revert UnresolvedWallet(wallet);
        return resolved;
    }

    /// @dev Resolves the current admitted id for an address; reverts NotAdmitted when unregistered/removed.
    function _requireAdmittedId(address orch) internal view returns (uint64 id) {
        SraStorage.SraStorageRegistry storage r = SraStorage.registry();
        id = r.activeIdOf[orch];
        require(id != 0 && r.orchestrators[id].admitted, NotAdmitted(orch));
    }

    function _pairId(address payer, address operator) internal pure returns (bytes32 result) {
        // Scratch-memory assembly: both addresses fit in the 64-byte scratch space,
        // identical result to keccak256(abi.encode(payer, operator)) without the memory allocation.
        assembly {
            mstore(0, payer)
            mstore(32, operator)
            result := keccak256(0, 64)
        }
    }

    function _swapRemove(uint64[] storage list, uint64 idx) internal {
        uint64 lastId = list[list.length - 1];
        if (idx != list.length - 1) list[idx] = lastId;
        list.pop();
    }
}
