# First-deployment code review

Reviewed the working tree based on commit `88f70fe1e64e9e2e3b6609e4a673205a1cf0228f` on 2026-09-15. Production code was not changed. Solidity files under `test/review/` are minimal reproducers: a passing test demonstrates current behavior, not a fix. Findings were reevaluated against [FIPs PR #1286](https://github.com/filecoin-project/FIPs/pull/1286) at head `7897ef0c1ea5cc95fb5ebf83b11c51a2eb4c3a9a`.

## Executive conclusion

No critical/high issue, direct permissionless theft path, or arbitrary-caller privilege escalation was found.

One medium integration/correctness finding remains: SRA wallet replacement can report success while f02 rejects the payout-map update, leaving the old wallet earning. PR #1286 adds payment-channel recipients as another concrete rejection case.

W-01, R-02, W-02, R-03, and R-04 are withdrawn because PR #1286 explicitly defines the observed behavior or assigns synchronization to governance sequencing. The remaining findings are governance/configuration footguns.

| ID | Severity | Finding | Attacker model |
|---|---|---|---|
| R-01 | Medium | Wallet replacement ignores f02 rejection and diverges payout state | Reachable state plus ordinary governance replacement |
| W-01 | Withdrawn | Gate-step/weight synchronization is a governance sequencing requirement | PR #1286 clarification |
| R-02 | Withdrawn | Admission applies immediately, including the current posting period | PR #1286 clarification |
| W-02 | Withdrawn | Same-epoch transaction order determines the active gate parameters | PR #1286 clarification |
| G-01 | Low | Recycled owner bits inherit stale approvals | 159 unanimously approved rotations after a parked approval |
| G-02 | Low | Zero-address owner rotation permanently bricks unanimity | Unanimous governance mistake |
| R-03 | Withdrawn | `CancelBinding` is an intended cooperative self-service exit | PR #1286 clarification |
| R-04 | Withdrawn | `ReplaceWallet` intentionally omits `extradata` | PR #1286 clarification |
| D-01 | Low | Checked-in production timing is unresolved/stale | Operator deploys checked-in configuration unchanged |
| D-02 | Informational | Deployment epoch JSON silently truncates to uint64 | Malformed operator-controlled configuration |

## Contract findings

### R-01 — Medium: wallet replacement can succeed while f02 keeps paying the old wallet

**Locations:** `src/ServiceRewardsActor.sol:389-400`; `src/lib/FVMRewards.sol:473-486`.

`replaceWallet` commits `orchestrators[id].wallet = newWallet`, calls `FVMRewards.tryReplaceAddress`, ignores every returned exit code, and emits success. The comment treats an absent f02 row as an intentional no-op, but the native method has other valid-state failure modes.

A reachable example is f02's payable-row bound. Start with 64 old payable recipients and 64 current recipients, the permitted union of 128. After current-period accrual, replacing one current recipient introduces a 129th union member during the fold, so f02 rejects the call. SRA nevertheless records and announces the new wallet. Future rewards continue accruing to the old wallet; a compromised wallet rotation therefore appears successful without stopping payment. Later `SetShares` operations may also remain blocked until claims reduce the union.

PR #1286 adds another concrete rejection case: f02 rejects payment-channel recipients because `Collect` deletes the actor. SRA's `_assertWalletAdmissible` checks only nonzero address, actor-ID resolution, and uniqueness, so it can accept a payment channel, commit the replacement, ignore f02's rejection, and emit success.

The reproducer constructs the full state and asserts that SRA returns success while f02's map still contains the old recipient:

```sh
forge test --match-path test/review/RewardsReplaceCapacity.t.sol -vv
```

**Recommendation:** make SRA mutation conditional on native success. The current f02 illegal-argument exit does not distinguish an absent old row from capacity, invalid-recipient-type, duplicate, and other failures, so allowlisting that code is unsafe. Make absent-row replacement a native success, provide a distinct absent-row result, or track when the row cannot exist and skip only that call. Also reject payment-channel wallets locally if actor-type inspection is available.

`removeOrchestrator` also ignores `tryReplaceAddress` at `ServiceRewardsActor.sol:374`, but this review did not prove the same capacity rejection for burn replacement because burning removes rather than adds a union member. Audit and explicitly classify its possible exits; do not infer the demonstrated replacement failure applies identically.

### W-01 — Withdrawn: gate counter retunes are not synchronized with f02 weight

PR #1286 requires a discretionary f02 w2 write and matching `steps` update to be part of the same published governance action and sequenced so no `QuarterlyGateCheck` applies between their effective epochs. It does not require contract-level atomicity. The demonstrated independent `steps = 7` retune violates that governance procedure rather than the clarified contract specification.

This remains a deployment/runbook obligation because the contract does not enforce the sequencing rule, but it is withdrawn as a code finding.

### R-02 — Withdrawn: a new admission can post for an already-ended quarter

PR #1286 explicitly makes `AddOrchestrator` immediate and states that an orchestrator admitted during Q's posting period may post `FPV_i(Q)` and enter that quarter's submitted map. The implementation matches that clarified behavior.

### W-02 — Withdrawn: same-epoch ordering changes a retuned gate result

PR #1286 removes the strict-later-epoch requirement. Transaction execution order intentionally determines whether a gate observes the old or new parameters. The remaining sequencing requirement is the paired w2/`steps` rule described under W-01.

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

### R-03 — Withdrawn: self-service binding cancellation bypasses governed transfer semantics

PR #1286 explicitly defines `CancelBinding` as a cooperative self-service exit by the current orchestrator. Release follows execution order, another admitted orchestrator may claim the unbound pair, and contested transfers still use governed `ReassignBinding`. The implementation matches that lifecycle.

### R-04 — Withdrawn: wallet replacement omits the specified wallet liveness proof

PR #1286 deliberately changes `ReplaceWallet(old,new,extradata)` to `ReplaceWallet(old,new)` and removes the wallet co-signature. The public governance request and Section 4.3 remedy are the specified protections. The contract ABI matches.

## Deployment notes, not exploits

### D-01 — Low: checked-in production timing is unresolved/stale

**Locations:** `deployments.json:7-11,20-24`; `script/Deploy.s.sol:41-56,70-79`; `src/ServiceRewardsActor.sol:132-156`.

Both checked-in network entries pass `activationEpoch = 0` into immutable SRA timing. If deployed as-is at a later height, quarter windows remain anchored to genesis. Mainnet also uses `epochsPerQuarter = 259200`, while PR #1286 specifies `262974`. The deployment script accepts and permanently embeds both values.

```sh
forge test --match-path test/review/DeploymentReview.t.sol \
  --match-test test_CheckedInMainnetConfigStartsQuartersAtGenesis -vv
```

This is operator-controlled configuration, not an exploit. Resolve the exact migration activation epoch, update mainnet quarter length to `262974`, and fail closed on unset or network-inconsistent production values. Calibration's compressed quarter length is a separate network parameter.

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
- FVM method numbers, `PendingOp` order, and CBOR tuple shapes were compared with builtin-actors PR #1782 head `faa3a01657bdd2c2dccd6e3c2c5b0d8e9d72489b`. That revision includes `ReplaceAddress` and payment-channel recipient rejection; no unsupported-method finding is claimed.
- Share largest-remainder arithmetic, quarter A/B mirror storage, wallet actor-ID deduplication, and the principal register/remove/reassign paths have substantial unit, fuzz, differential, invariant, and symbolic coverage. No additional defect was demonstrated in those areas.

## Deployment gates and residual risks

These are release checks, not findings:

- `.github/workflows/dry-deploy.yml:26-28` runs with a calibration chain ID but no RPC URL. It is a local EVM run, not a calibration fork or exact FEVM/native-actor integration. Exercise deployment, approvals, `SetShares`, `ReplaceAddress` rejection cases, gate stepping, and claims against the exact target bundle and migration state.
- `DeployScript.run()` deploys implementations and proxies; it does not seat the initial orchestrator or install f02's SWA actor ID/SRA writer. Verify the combined migration procedure, proxy actor IDs, initial recipient, timing values, and f02 hold.
- Independently authenticate all four configured governance addresses and their multisig thresholds/modules.
- Effective Foundry configuration selects `evm_version = osaka`; `foundry.toml` does not pin it. Verify and pin the FEVM-compatible target.
- `forge build --sizes` reports SRA runtime 23,215 bytes, 1,361 bytes below EIP-170; SWA is 15,119 bytes. The command exits nonzero only because the test mock `FVMRewardActor` is 31,168 bytes. Monitor SRA headroom while fixing findings.
- The README broadcast command uses `--skip-simulation`. Use it only after an exact-configuration, exact-bundle rehearsal.

## Verification and sources

- Final post-reevaluation `forge test`: 434 passed, 0 failed, 0 skipped across 27 suites, including all five retained review reproducer tests. Final `forge fmt --check` passed.
- `forge script script/Deploy.s.sol --chain-id 314159` succeeded locally and explicitly reported that an RPC URL is required for on-chain simulation.
- `forge build --sizes` produced the sizes above; it returned nonzero for the oversized test-only mock.
- [Accepted FIP-0118](https://github.com/filecoin-project/FIPs/blob/master/FIPS/fip-0118.md), especially §§2.2, 3.1.1, 3.2, and 4.
- [FIPs PR #1286](https://github.com/filecoin-project/FIPs/pull/1286), evaluated at head `7897ef0c1ea5cc95fb5ebf83b11c51a2eb4c3a9a`.
- [builtin-actors PR #1782](https://github.com/filecoin-project/builtin-actors/pull/1782), integration reference at review-time head `faa3a01657bdd2c2dccd6e3c2c5b0d8e9d72489b`. The PR was open at review time and is not proof of the deployed network bundle.
