# Solstice pre-deployment review

## Decision

**Deployment readiness: not approved at target revision `26d4441e10003c272a98900ff0bbee68bcbea9a8`.**

The implementation findings below require triage or fixes before sign-off. Deployment configuration and ceremony items are tracked separately as a readiness checklist; they are not presented as code vulnerabilities.

No production fix was applied. Intentionally failing pre-fix reproducers are retained in `review/reproducers/`. The chronological, append-only investigation record is `review/APPENDLOG.md`.

## Pinned scope

| Component | Revision |
|---|---|
| Solstice target | `26d4441e10003c272a98900ff0bbee68bcbea9a8` |
| Accepted FIP-0118 | `filecoin-project/FIPs@9fbc58118435bcbbcbdc75959576f8bde0a908ae` |
| Open clarification PR #1286 | `7897ef0c1ea5cc95fb5ebf83b11c51a2eb4c3a9a` |
| Native actor PR #1782 head reviewed as integration pin | `faa3a01657bdd2c2dccd6e3c2c5b0d8e9d72489b` |
| `fvm-solidity` | `ea1fe65367d7539236be111916a6e2781bcf7a1b` |
| OpenZeppelin Contracts | `cab19933c33c2ad1d4c7a84864a3601dddfd16f3` |
| Forge standard library | `bf647bd6046f2f7da30d0c2bf435e5c76a780c1b` |

Reviewed surfaces: SRA lifecycle, share arithmetic, registry, SWA gate and native administration, governance/UUPS, CBOR/native wire compatibility, deployment configuration, CI, storage namespaces, and the behavioral f02 mock.

## Confirmed implementation findings

### F-01 — SRA commits success while f02 rejects recipient replacement

**Severity: high. Confidence: high.**

Tracking: https://github.com/filecoin-project/solstice/issues/55

Locations: `src/ServiceRewardsActor.sol:351-375,389-400`; `src/lib/FVMRewards.sol:473-486`.

`removeOrchestrator` and `replaceWallet` mutate SRA state, call `FVMRewards.tryReplaceAddress`, discard every exit code, and emit success. Pinned f02 can reject for the wrong writer, missing old recipient, absent new actor, recipient collision, or payable-row capacity. Its transaction correctly rolls back, but the Solidity transaction commits.

State transition and impact:

1. Both SRA owners authorize removal or wallet replacement.
2. SRA clears admission or stores the new wallet.
3. f02 rejects and retains the old live recipient.
4. SRA emits a success event.
5. The old or removed wallet can continue accruing and claiming service rewards. A zero-volume quarter performs no `SetShares`, so divergence can persist. Removal also clears `activeIdOf`, preventing a retry of the same transition.

The fault-injection reproducer returned no data from `CALL_ACTOR_BY_ID`; the second approval still emitted `OrchestratorWalletReplaced`. The repository's native behavioral tests independently demonstrate real `ReplaceAddress` rejection paths, including a payable union over 128.

Required action: track whether a row is known to exist; skip only a locally proven no-row/same-resolved-ID no-op; otherwise use the checked `FVMRewards.replaceAddress` path and let failure roll back local state and events.

Reproducer: `review/reproducers/SRAIgnoredReplaceFailure.t.sol`.

### F-02 — One-based quarter initialization is incomplete

**Classification: deployment correctness TODO; no deeper mechanism flaw once Q starts at 1. Confidence: high.**

Tracking: https://github.com/filecoin-project/solstice/issues/52

Locations: `src/ServiceRewardsActor.sol:130-185,291-315,496-558`; `src/lib/SraStorage.sol:27-31`.

Yes: if the contract's valid quarter domain starts at Q=1, the reported q0 behavior goes away. With the existing formula, `_quarterStart(1) = activation + L`, which is the first legitimate reporting window. During `[activation, activation + L)`, `_quarterOf` may remain the internal zero sentinel without creating a reportable quarter.

The required cutover is:

1. Initialize proxy storage `nextQuarter = 1`.
2. Reject Q=0 through `_quarterStart` (therefore post, correct, submit, aggregate, and `quarterStart(0)` all reject).
3. Keep `_pendingSharesQuarter` using internal `nowQ == 0` before the first quarter ends: `nextQuarter == nowQ + 1` then correctly means no submission is pending.

Without those guards, the current code does allow q0 submission and map replacement, as retained in `review/reproducers/QuarterZeroAdmission.t.sol`. This is already tracked exactly by issue #52, whose requested fix is `nextQuarter = 1` plus rejection of Q=0 in the reporting methods.

### F-03 — Gate retune/check ordering desynchronizes `steps` from native w2

**Severity: low for the current deployment; potentially material only during a future FIP-governed retune. Confidence: high.**

Locations: `src/StreamWeightActor.sol:118-149`; `src/lib/GateParams.sol:25-29`.

FIP-0118 requires a discretionary w2 record and matching `steps` retune to take effect at the same epoch, later than the last gate check. The code has no effective epoch or last-check epoch for local params and no atomic relationship to the native record.

The reproducer queued a paired w2=50%/steps=8 transition. At maturity, a permissionless q2 check ran first under steps=0. Its native call settled 50% and queued a 15% gate step. The local retune then completed at steps=8. One hold later, f02 applied 15% while the local counter remained terminal, so further checks revert `StepsComplete`.

Current/default impact is zero: the initial gate parameters and native bootstrap record do not use `setGateParams`. The bad state requires governance to schedule a later paired weight/counter retune. If triggered, service weight can be lower than the terminal counter claims, increasing burn until dual governance completes a corrective record/counter sequence after the applicable holds; it does not redirect rewards to an attacker.

Required action: represent the pair as one committed transition with one effective epoch, block gate checks while a due retune is unresolved, and enforce effective epoch greater than the stored last-check epoch.

Reproducer: `review/reproducers/GateStateMachine.t.sol`.

### F-04 — Consecutive late gate passes serialize across native holds

**Severity: low economic-liveness issue. Confidence: high.**

Locations: `src/StreamWeightActor.sol:118-140`; pinned f02 `actors/reward/src/streams/queue.rs` (`WriteKey::ScheduleWide`, occupied-key check).

Accepted FIP-0118 says the next bound quarter becomes callable immediately after a late check. In pinned f02, every passing check occupies the single uncancellable schedule-wide `StepWeightRecords` key. An immediate passing check for the next stale quarter therefore reverts until the prior step's full native hold expires.

The reproducer passed q2, then q3 reverted `StepWeightRecordsFailed(16)`. State rolls back safely and retry remains possible, but an eight-pass backlog can require roughly eight seven-day holds while the service weight remains low and residual burns.

No quarter is skipped and no incorrect recipient is paid: the second call reverts atomically and is retryable. Impact is delayed service-weight escalation and additional residual burn, only when checks have already lagged by multiple quarters and consecutive stale quarters pass.

Required action: allow ordered pending gate steps or safely coalesce bound historical decisions into an absolute target; otherwise amend the FIP's late-crank liveness guarantee.

Reproducer: `review/reproducers/GateStateMachine.t.sol`.

### F-05 — Masked ID resolution does not prove payout actor existence

**Severity: low governance-input validation issue. Confidence: high.**

Locations: `src/ServiceRewardsActor.sol:714-724`; `lib/fvm-solidity/src/FVMActor.sol:64-101`.

SRA treats `FVMActor.getActorId` as proof that a payout actor exists. FVM address resolution returns the numeric ID for any ID-protocol address, including an unallocated one. Pinned f02 performs an additional `get_actor_code_cid` check and rejects an absent recipient.

The reproducer admitted a masked address with zero `codehash` after the resolver returned its numeric ID. A later positive `SubmitShares` can then fail and block the submission/removal line. If the revealed ID is allocated to an attacker before submission, rewards can instead be installed to the attacker's actor.

This requires both owners to approve a masked `0xff…` ID address for an actor that does not exist. Ordinary unregistered f410 wallets are already rejected. The normal outcome is a blocked positive `SubmitShares` until governance replaces the wallet and retries; the future-ID capture scenario additionally requires the chosen ID to be allocated to another party before submission.

Required action: verify actual actor existence after resolution using a Filecoin-correct actor-code/existence primitive; apply the same check to admission and replacement.

Reproducer: `review/reproducers/MaskedNonexistentWallet.t.sol`.

### F-06 — Upgrade approvals do not constrain `msg.value`

**Severity: advisory for the current code; relevant only to a future payable migration. Confidence: high.**

Locations: `src/lib/UnanimousProxied.sol:41`; `src/lib/UnanimousGovernance.sol:33-76`; OpenZeppelin UUPS/ERC1967 delegatecall path.

The governed task ID is `keccak256(msg.data)`, while `upgradeToAndCall` is payable. After both owners approve the implementation and migration calldata, any arbitrary public caller can finalize by repeating that exact calldata with any `msg.value`; OpenZeppelin's migration delegatecall receives both that arbitrary caller as `msg.sender` and the caller-chosen value.

The arbitrary finalizer identity is intentional and is not independently the finding. The issue is that value is likewise arbitrary but, unlike caller identity, is not an inherent requirement of public finalization. Current code has no payable V2 migration, so there is no present impact. A future migration that consumes or branches on `msg.value` could receive an owner-unapproved amount, misconfigure value-derived state, or lock unexpected FIL.

Value-bearing approvals are also awkward to commit safely: value sent with each non-executing approval remains on the proxy, so simply adding value to the task hash would make both owner approvals and finalization fund the proxy separately.

Required action: require `msg.value == 0` for the governed UUPS upgrade path. If a migration needs funding, use a separate explicit funding operation rather than payable approval/finalization calls.

Reproducer: `review/reproducers/UpgradeFinalizerContext.t.sol`, specifically `test_MigrationMustNotObserveUncommittedValue`. The caller-observation test only documents the intended public-finalizer context.

## Lower-severity confirmed findings

| ID | Finding | Reachability / impact | Reproducer |
|---|---|---|---|
| F-07 | Pending owner-bit approvals transfer after bit reuse | Requires 159 valid unanimous rotations in the normal two-owner setup. Owner2 then executed an immediate task without the replacement owner's approval. Namespace tasks by governance/code generation. | `OwnerBitRecycling.t.sol` |
| F-08 | Zero orchestrator creates a hidden live binding | Requires unanimous admission and reassignment to zero. `bindingOf` reports the unbound sentinel while registration reverts `AlreadyBound`; governance can repair. Reject zero identities. | `ZeroOrchestratorHiddenBinding.t.sol` |
| F-09 | Gate target arithmetic wraps | Requires unanimous unsupported retune. Ratio raw `2^128`, steps=2 wrapped the threshold to zero and let zero FPV advance a gate. Validate with checked full-precision math. | `GateStateMachine.t.sol` |
| F-10 | Hold deadline wraps | Current holds are safe. With hold `uint64.max` at epoch 100, a positive hold matured in the approval epoch. Use checked `uint256` deadline arithmetic. | `HoldDeadlineWrap.t.sol` |
| F-11 | Solidity RegisterStream epoch domain exceeds native `ChainEpoch` | SWA governance only; atomic failure and easy retry. Solidity accepts uint64 values at or above `2^63`, while pinned Rust deserializes `ChainEpoch` as i64. Reject outside int64 range locally. | `RegisterStreamEpochDomain.t.sol` |

## Specification decisions required before deployment

The implementation intentionally follows parts of an open clarification rather than the accepted FIP. A deployment cannot be reviewed against two incompatible normative baselines.

1. **Window endpoints:** accepted `(E,E+POST]` / `(postEnd,verifyEnd]`; PR #1286 and code use half-open intervals.
2. **Admission timing:** accepted next-quarter effect; PR #1286 and code make admission immediate.
3. **Wallet replacement and cancellation:** accepted text requires replacement-wallet co-signature and lacks `CancelBinding`; PR #1286/code remove the co-signature and add cancellation.
4. **Mainnet quarter length:** accepted `259200`; PR #1286/config `262974`.
5. **FPV cap:** code imposes per-orchestrator raw `1e30`; neither pinned specification revision states that policy.

Required action: merge/ratify the intended specification, pin its commit in the activation manifest, and update code/tests/comments to one convention before re-review.

## Deployment readiness checklist (not audit findings)

### D-01 — Executable deployment manifest anchors reporting to genesis

**Priority: complete before broadcast.** `deployments.json:10` and `:23` set both networks' activation epoch to zero. `script/Deploy.s.sol:45-85` reads and embeds the value without rejecting a placeholder. The actual deployment-path reproducer deployed the mainnet configuration and observed `quarterStart(0) == 0`.

Impact: every SRA quarter/window calculation is anchored to genesis; historical quarters appear bound; permissionless gate catch-up can run against an unintended calendar. The immutable calendar cannot be safely corrected after activation without coordinated state migration.

Required action: populate the ratified future activation epoch and make the script reject zero/unset live-network activation before `startBroadcast`.

Reproducer: `review/reproducers/DeploymentActivationEpoch.t.sol`.

### D-02 — No proof that migration-only f02 state matches the proxies

**Priority: complete before activation.** `Deploy.s.sol` performs only FEVM creation and initialization. The native actor stores `swa_actor` and the native hold through migration-only state and has no exported getter/setter for them. The service stream writer and initial wallet/share map must likewise match SRA bootstrap. `README.md` calls the current broadcast command “Deploy all,” and `.github/workflows/dry-deploy.yml` proves only that constructors run for a chain ID.

Required action: produce an append-only activation manifest binding chain ID, target epoch, source/compiler/dependency pins, proxy and implementation addresses/code hashes, resolved actor IDs, f02 `swa_actor`, native hold, service writer, and initial service wallet. Verify it against the actual migration input/state and execute end-to-end SWA and SRA writes on a pinned actor devnet.

### D-03 — Deployment script accepts destructive or silently altered inputs

| Issue | Reachability and impact | Evidence |
|---|---|---|
| Zero owner accepted | Current owner fields are nonzero, but one future zero field initializes a real unreachable owner bit and permanently deadlocks all unanimous writes and upgrades. | `DeploymentHardening.t.sol` |
| Epoch narrowing truncates | `_readEpoch` converts unrestricted JSON `uint256` to `uint64`; `2^64` became zero instead of reverting. | `DeploymentHardening.t.sol` |
| Rerun replaces outputs | Two `DeployScript.run()` calls created different proxy pairs. A broadcast rerun overwrites the only canonical address fields while f02 remains pinned to the first SWA. | `DeploymentHardening.t.sol` |

Required action: validate nonzero/distinct owners and exact epoch ranges; reject nonzero existing output addresses unless using an explicit redeployment procedure; journal generations instead of overwriting them.

## Refuted candidates and negative findings

- Removing an orchestrator cannot leave that same quarter's poster volume in the aggregate through the hypothesized path: `_pendingSharesQuarter` blocks removal until that current reporting cycle is submitted. Appendlog Entries 003 and 007 preserve the candidate and refutation.
- Removed IDs do not reactivate bindings on re-admission: IDs are monotonic and never reused.
- Failed checked `SetShares` and gate native writes roll back Solidity latches atomically.
- Default gate thresholds, share totals, largest-remainder work, and the 64-orchestrator arithmetic bound do not overflow under current constants.
- Proxy initialization is atomic and implementation initializers are disabled; duplicate initial owners fail closed.
- ERC-7201 namespaces reviewed are distinct; persistent actor state uses namespaced storage and actor-specific values are immutable.

## Verification

- `FOUNDRY_PROFILE=ci forge test --summary`: **429 passed, 0 failed, 0 skipped**. Each SRA invariant ran 256 campaigns and 128000 calls.
- `forge test --contracts review/reproducers --summary`: compilation succeeded; **17 expected pre-fix failures** across 11 retained reproducer contracts. Imported standard suites produced 429 passes.
- `forge fmt --check`: passed.
- `forge lint --deny notes --quiet`: passed.
- Solidity LSP diagnostics for `src/**/*.sol`: no diagnostics.

The reproducer failures are the evidence: each asserts the required safe behavior and currently fails. They are outside Foundry's configured `test/` root, so the normal suite remains green.

## Primary references

- Accepted FIP-0118: https://github.com/filecoin-project/FIPs/blob/9fbc58118435bcbbcbdc75959576f8bde0a908ae/FIPS/fip-0118.md
- Clarification PR head: https://github.com/filecoin-project/FIPs/commit/7897ef0c1ea5cc95fb5ebf83b11c51a2eb4c3a9a
- Native actor review pin: https://github.com/filecoin-project/builtin-actors/tree/faa3a01657bdd2c2dccd6e3c2c5b0d8e9d72489b
