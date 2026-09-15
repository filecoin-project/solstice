# First-deployment code review

Reviewed the working tree based on commit `88f70fe1e64e9e2e3b6609e4a673205a1cf0228f` on 2026-09-15. Production code was not changed. Solidity files under `test/review/` are minimal reproducers: a passing test demonstrates current behavior, not a fix.

## Executive conclusion

No critical issue, direct permissionless theft path, or arbitrary-caller privilege escalation was found.

The review found two release-blocking correctness failures:

1. SRA wallet replacement can report success while f02 rejects the payout-map update, leaving the old wallet earning.
2. SWA gate retuning can desynchronize its authoritative step counter from f02's service weight, allowing one later gate to skip several intended 5-point levels.

Both require governance action and are therefore not standalone external exploits. Their impact is still material because the contracts claim that successful governance operations atomically update reward allocation.

Additional findings are specification mismatches or governance/configuration footguns. Severity below weights attacker reachability and realistic preconditions, not only worst-case impact.

| ID | Severity | Finding | Attacker model |
|---|---|---|---|
| R-01 | Medium | Wallet replacement ignores f02 rejection and diverges payout state | Reachable state plus ordinary governance replacement |
| W-01 | Medium | Gate-step retune is not synchronized with f02 weight | Unanimous SWA governance action |
| R-02 | Medium | New admission can contribute to an already-ended quarter | Unanimous SRA governance admission plus admitted orchestrator |
| W-02 | Low | Same-epoch transaction ordering changes retuned gate result | Matured unanimous retune plus transaction ordering |
| G-01 | Low | Recycled owner bits inherit stale approvals | 159 unanimously approved rotations after a parked approval |
| G-02 | Low | Zero-address owner rotation permanently bricks unanimity | Unanimous governance mistake |
| R-03 | Low | Self-service cancellation bypasses governed binding transfer semantics | Cooperation by current holder, then another admitted orchestrator |
| R-04 | Low | Wallet replacement omits specified wallet liveness proof | Unanimous governance mistake; no added authorization bypass |
| D-01 | Low | Checked-in activation epoch is zero | Operator deploys unresolved placeholder configuration |
| D-02 | Informational | Deployment epoch JSON silently truncates to uint64 | Malformed operator-controlled configuration |

## Contract findings

### R-01 — Medium: wallet replacement can succeed while f02 keeps paying the old wallet

**Locations:** `src/ServiceRewardsActor.sol:389-400`; `src/lib/FVMRewards.sol:473-486`.

`replaceWallet` commits `orchestrators[id].wallet = newWallet`, calls `FVMRewards.tryReplaceAddress`, ignores every returned exit code, and emits success. The comment treats an absent f02 row as an intentional no-op, but the native method has other valid-state failure modes.

A reachable example is f02's payable-row bound. Start with 64 old payable recipients and 64 current recipients, the permitted union of 128. After current-period accrual, replacing one current recipient introduces a 129th union member during the fold, so f02 rejects the call. SRA nevertheless records and announces the new wallet. Future rewards continue accruing to the old wallet; a compromised wallet rotation therefore appears successful without stopping payment. Later `SetShares` operations may also remain blocked until claims reduce the union.

The reproducer constructs the full state and asserts that SRA returns success while f02's map still contains the old recipient:

```sh
forge test --match-path test/review/RewardsReplaceCapacity.t.sol -vv
```

**Recommendation:** use the reverting `replaceAddress` path unless the return code is the exact, deliberately accepted absent-row case. If absent-row success is required, classify that response explicitly and revert for every other exit. Keep SRA registry mutation, native actor mutation, and event emission atomic.

`removeOrchestrator` also ignores `tryReplaceAddress` at `ServiceRewardsActor.sol:374`, but this review did not prove the same capacity rejection for burn replacement because burning removes rather than adds a union member. Audit and explicitly classify its possible exits; do not infer the demonstrated replacement failure applies identically.

### W-01 — Medium: gate counter retunes are not synchronized with f02 weight

**Locations:** `src/StreamWeightActor.sol:118-149`; accepted FIP-0118 §3.1.1, “The counter is the authority.”

`setGateParams` permits governance to replace `steps` independently after the SWA hold. It neither writes the matching f02 service weight nor shares an effective epoch with such a write. `quarterlyGateCheck` later derives the new service weight solely from the stored counter:

```solidity
int256 next = (int256(uint256(loaded.steps)) + 3) * STEP;
```

Starting with f02 at 10%, governance can set `steps = 7`; one passing quarter then queues 50%, skipping 15% through 45%. Setting `steps = 8` makes `StepsComplete` block the gate entirely even if f02 is still at 10%. Lowering the counter can repeat levels.

```sh
forge test --match-path test/review/StreamRetuneReview.t.sol \
  --match-test test_IndependentCounterRetuneSkipsServiceWeightLevels -vv
```

**Recommendation:** make a step-counter change and its corresponding f02 record one indivisible governance operation with the same effective epoch. Alternatively, remove independent `steps` mutation from `setGateParams` and provide a purpose-built synchronized retune method.

### R-02 — Medium: a new admission can post for an already-ended quarter

**Locations:** `src/ServiceRewardsActor.sol:293-304,328-342,468-489`; accepted FIP-0118 §3.2 `AddOrchestrator`.

`addOrchestrator` records only an immediate `admitted` boolean. `postVolume` and `correctVolume` check that live boolean, not an admission-effective quarter. Governance can admit an orchestrator during Q's post/verification interval, after measurement quarter Q has ended, and the orchestrator can immediately post or be backfilled for Q. Its value enters both `AggregatedFPV(Q)` and `SubmitShares(Q)`. The accepted FIP instead says an orchestrator admitted in Q first posts for Q+1.

```sh
forge test --match-path test/review/RewardsAdmissionLifecycle.t.sol \
  --match-test test_NewAdmissionCanPostForAlreadyEndedQuarter -vv
```

**Recommendation:** store the admission-effective quarter and enforce it in both posting and correction. Apply the same temporal model when deciding whether bindings contribute.

### W-02 — Low: same-epoch ordering changes a retuned gate result

**Location:** `src/StreamWeightActor.sol:118-149`; accepted FIP-0118 §3.1.1 `SetGateParams` timing.

The contract stores `lastCheckedQuarter` but not the epoch of the last successful check. When a held retune matures at epoch E, both orderings can succeed:

- gate check then retune: Q is tested against old parameters;
- retune then gate check: the same Q is tested against new parameters.

With Q volume between the two thresholds, transaction ordering changes whether the service weight steps. The specification requires a retune's effective epoch to be strictly later than the last gate-check epoch.

```sh
forge test --match-path test/review/StreamRetuneReview.t.sol \
  --match-test test_SameEpochRetuneOrderingChangesGateOutcome -vv
```

**Recommendation:** store the last successful gate-check epoch and reject retune application unless its effective epoch is strictly later. This does not replace W-01's synchronized weight/counter requirement.

### G-01 — Low: recycled owner bits inherit stale approvals

**Locations:** `src/lib/Owners.sol:52-79,87-103`; `src/lib/UnanimousGovernance.sol:83-103`; `src/lib/UnanimousProxied.sol:35-38`.

Pending tasks store approvals as a 160-bit owner mask. Owner removal does not invalidate pending tasks, and `addOwner` eventually reuses freed bits. A stale approval is then attributed to the new owner occupying that bit.

Minimal sequence: owner A approves task T; A and B replace A with C; B and C unanimously execute 158 C-to-C replacements, advancing the allocator around all 160 positions until C receives A's freed bit; B then approves T and it executes although C never approved T. This breaks identity-based unanimity, but the 159 unanimously authorized rotation operations make it an impractical external exploit.

```sh
forge test --match-path test/review/GovernanceReview.t.sol \
  --match-test test_staleApprovalExecutesAfterOwnerBitIsReused -vv
```

**Recommendation:** bind every pending task to an owner-set generation and invalidate it when membership changes. Do not allow approval bits to retain meaning across rotations.

### G-02 — Low: zero-address owner rotation permanently bricks unanimity

**Locations:** `src/lib/Owners.sol:52-80`; `src/lib/UnanimousProxied.sol:20-29,35-38`.

Initial owners and replacement owners are not checked for zero. If both owners approve replacing one owner with `address(0)`, the bitmap continues to require zero's approval, but no ordinary EVM call can originate from zero. Upgrades, governance actions, and rotating zero back out are permanently blocked. The remaining real owner can still veto existing tasks; veto does not recover the owner set.

```sh
forge test --match-path test/review/GovernanceReview.t.sol \
  --match-test test_zeroOwnerRotationPermanentlyLocksUnanimousActions -vv
```

**Recommendation:** reject zero in the constructor/initializer path and in `addOwner`/`replaceOwner`. The existing test that explicitly accepts zero should be removed rather than updated to preserve unsafe behavior.

### R-03 — Low: self-service binding cancellation bypasses governed transfer semantics

**Locations:** `src/ServiceRewardsActor.sol:252-288`; accepted FIP-0118 §3.2 binding lifecycle.

`cancelBinding` lets the current orchestrator delete a live binding. Any other admitted orchestrator can then claim it through `registerPairs`, with no Registry governance `ReassignBinding` decision and no `inherit` scope recorded. The accepted FIP describes live transfer through governed reassignment and release through orchestrator removal; it does not define this unilateral live-release path.

```sh
forge test --match-path test/review/RewardsBindingLifecycle.t.sol -vv
```

This is not a unilateral theft: the existing holder must first release the pair. The risk is bypass of the dispute/audit lifecycle and a race among admitted orchestrators after release.

**Recommendation:** remove `cancelBinding` unless self-service release is deliberately added to the normative lifecycle. If retained, specify attribution timing and a deterministic claimant/approval rule rather than making the released pair first-come-first-served.

### R-04 — Low: wallet replacement omits the specified wallet liveness proof

**Location:** `src/ServiceRewardsActor.sol:389-400`; accepted FIP-0118 §3.2 `ReplaceWallet(old,new,extradata)`.

The ABI accepts only `(oldOrch,newWallet)`. It cannot carry or verify the old-wallet signature used for an ordinary rotation or the new-wallet liveness signature used for lost-key recovery. Both Registry owners can select an existing actor address without proof anyone controls its key.

```sh
forge test --match-path test/review/RewardsAdmissionLifecycle.t.sol \
  --match-test test_RegistryOwnersCanReplaceWalletWithoutOrchestratorSignature -vv
```

The FIP explicitly makes this signature a liveness/request-evidence check, not additional authorization. Therefore this omission does not create a new theft capability beyond malicious unanimous Registry governance, which the FIP already acknowledges can redirect rewards.

**Recommendation:** add the specified payload and validate the old- or new-wallet proof according to rotation mode. Domain-separate the signature by chain ID, SRA proxy, orchestrator, old wallet, new wallet, nonce, and mode.

## Deployment notes, not exploits

### D-01 — Low: checked-in activation epoch is zero

**Locations:** `deployments.json:10,23`; `script/Deploy.s.sol:41-56,70-79`; `src/ServiceRewardsActor.sol:132-156`.

Both checked-in network entries pass `activationEpoch = 0` into immutable SRA timing. If deployed as-is at a later height, quarter windows remain anchored to genesis. The documented script succeeds; zero is not treated as an unresolved placeholder. At controlled mainnet chain ID and height 6,000,000, a fresh deployment already considers gate quarter Q2 bound and cannot submit Q0 as the latest quarter.

```sh
forge test --match-path test/review/DeploymentReview.t.sol \
  --match-test test_CheckedInMainnetConfigStartsQuartersAtGenesis -vv
```

This is operator-controlled configuration, not an exploit. Resolve and verify the exact migration activation epoch before deployment, and fail closed on an unset production value.

### D-02 — Informational: JSON epoch fields silently truncate

**Location:** `script/Deploy.s.sol:41-42`.

`uint64(json.readUint(...))` silently truncates. `2^64` becomes zero and `2^64+1` becomes one; some truncated activation/hold values remain constructor-valid.

```sh
forge test --match-path test/review/DeploymentReview.t.sol \
  --match-test test_ConfigEpochOverflowSilentlyTruncates -vv
```

Reject values above `type(uint64).max` before conversion. This input is operator-controlled.

## Reviewed areas with no finding

- UUPS authorization was traced through OpenZeppelin. Preliminary governance approvals execute `assembly stop()`, terminating the whole proxy delegatecall before `_upgradeToAndCallUUPS`; a held, fully approved completion returns normally and performs the upgrade. The early-success behavior is unusual but not an authorization bypass.
- Default gate state matches the accepted schedule: `lastCheckedQuarter = 1`, so the first check consumes Q2; the default target and ratio are exact fixed-point values.
- FVM method numbers, `PendingOp` order, and CBOR tuple shapes were compared with builtin-actors PR #1782 head `faa3a01657bdd2c2dccd6e3c2c5b0d8e9d72489b`. That revision includes `ReplaceAddress`; no unsupported-method finding is claimed.
- Share largest-remainder arithmetic, quarter A/B mirror storage, wallet actor-ID deduplication, and the principal register/remove/reassign paths have substantial unit, fuzz, differential, invariant, and symbolic coverage. No additional defect was demonstrated in those areas.

## Deployment gates and residual risks

These are release checks, not findings:

- `.github/workflows/dry-deploy.yml:26-28` runs with a calibration chain ID but no RPC URL. It is a local EVM run, not a calibration fork or exact FEVM/native-actor integration. Exercise deployment, approvals, `SetShares`, `ReplaceAddress`, gate stepping, and claims against the exact target bundle and migration state.
- `DeployScript.run()` deploys implementations and proxies; it does not seat the initial orchestrator or install f02's SWA actor ID/SRA writer. Verify the combined migration procedure, proxy actor IDs, initial recipient, timing values, and f02 hold.
- Independently authenticate all four configured governance addresses and their multisig thresholds/modules.
- Effective Foundry configuration selects `evm_version = osaka`; `foundry.toml` does not pin it. Verify and pin the FEVM-compatible target.
- `forge build --sizes` reports SRA runtime 23,215 bytes, 1,361 bytes below EIP-170; SWA is 15,119 bytes. The command exits nonzero only because the test mock `FVMRewardActor` is 31,168 bytes. Monitor SRA headroom while fixing findings.
- The README broadcast command uses `--skip-simulation`. Use it only after an exact-configuration, exact-bundle rehearsal.

## Verification and sources

- Final `forge test`: 439 passed, 0 failed, 0 skipped across 30 suites, including all ten review reproducer tests.
- `forge script script/Deploy.s.sol --chain-id 314159` succeeded locally and explicitly reported that an RPC URL is required for on-chain simulation.
- `forge build --sizes` produced the sizes above; it returned nonzero for the oversized test-only mock.
- [Accepted FIP-0118](https://github.com/filecoin-project/FIPs/blob/master/FIPS/fip-0118.md), especially §§2.2, 3.1.1, 3.2, and 4.
- [builtin-actors PR #1782](https://github.com/filecoin-project/builtin-actors/pull/1782), integration reference at review-time head `faa3a01657bdd2c2dccd6e3c2c5b0d8e9d72489b`. The PR was open at review time and is not proof of the deployed network bundle.
