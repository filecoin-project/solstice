# Solstice independent review appendlog

Review target: `26d4441e10003c272a98900ff0bbee68bcbea9a8`

This file is append-only. Candidate findings remain recorded after refutation; later entries supersede status without deleting history. Executable reproducers are retained under `test/reproducers/` once created.

## Entry 000 — Review opened

- Status: process record
- Evidence baseline: `REVIEWER_GUIDE.md`
- External revisions: pending independent pinning
- Findings: none yet

## Entry 001 — External baselines pinned

- Status: process record
- Accepted FIP-0118: `filecoin-project/FIPs@9fbc58118435bcbbcbdc75959576f8bde0a908ae`
- Pending clarification PR #1286: open at `7897ef0c1ea5cc95fb5ebf83b11c51a2eb4c3a9a`
- Native actor PR #1782: open at `faa3a01657bdd2c2dccd6e3c2c5b0d8e9d72489b`
- Solidity/FVM dependency: `fvm-solidity@ea1fe65367d7539236be111916a6e2781bcf7a1b`
- OpenZeppelin dependency: `openzeppelin-contracts@cab19933c33c2ad1d4c7a84864a3601dddfd16f3`

## Entry 002 — Candidate: SRA commits local state while ignoring `ReplaceAddress` failure

- Status: candidate; reproducer pending
- Locations: `src/ServiceRewardsActor.sol:351-375`, `src/ServiceRewardsActor.sol:389-400`
- Invariant: `RemoveOrchestrator` must immediately remove the recipient from the f02 service map; `ReplaceWallet` must immediately redirect its future share. Solidity and f02 state must change atomically.
- Observation: both methods call `FVMRewards.tryReplaceAddress(...)` and discard every non-zero native exit code. They then commit SRA state and emit a success event.
- Preconditions: unanimous SRA governance executes either method while f02 rejects or cannot execute `ReplaceAddress`.
- Suspected impact: f02 may continue paying a removed wallet, or may keep paying an old wallet after SRA records a replacement. Later `SubmitShares` can repair the map, but removal can remain ineffective for most of a quarter and replacement behavior contradicts the emitted state.
- Narrow remediation under review: distinguish the documented absent-row no-op from real native failures. If pinned f02 already treats an absent old address as success, use the reverting `FVMRewards.replaceAddress` wrapper.

## Entry 003 — Candidate: removed orchestrator volume may remain in gate aggregate

- Status: candidate reported by wide-scope review; independent reproducer pending
- Locations: `src/ServiceRewardsActor.sol:313`, `src/ServiceRewardsActor.sol:351-375`, `src/ServiceRewardsActor.sol:548-553`
- Invariant: an orchestrator removed before the relevant quarter closes must be excluded from both the submitted share map and `AggregatedFPV`.
- Hypothesis: `removeOrchestrator` removes the id from `admittedIds` without deducting its already-posted mirror from `totalUsd[q]`; `_collectSlot` then excludes the row while `aggregatedFilecoinPayVolume` returns the stale counter.
- Open check: `_pendingSharesQuarter` may prevent the hypothesized posting-window removal. The candidate remains logged until the exact epoch sequence is executed.

## Entry 004 — Specification conflict: admission effective quarter

- Status: unresolved specification question, not classified as a defect
- Location: `src/ServiceRewardsActor.sol:328-342`
- Accepted FIP-0118 at `9fbc5811...` states an admission applies from the next quarter boundary.
- Pending clarification `7897ef0c...` states an admission applies immediately and permits posting for the current quarter.
- Implementation marks the identity admitted immediately. Classification requires maintainers to choose the authoritative semantics; tests cannot resolve a normative conflict.

## Entry 005 — Candidate deployment blocker: mainnet activation epoch is zero

- Status: candidate; deployment-path reproducer pending
- Locations: `deployments.json:2-13`, `script/Deploy.s.sol:45-85`
- Observation: the mainnet config sets `activationEpoch` to `0`; the deploy script consumes it without rejecting placeholders.
- Suspected impact: a production deployment would anchor quarter arithmetic to genesis, immediately expose historical quarters as bound, and permit catch-up gate checks against empty historical aggregates instead of starting at the Solstice activation.
- Open check: whether deployment operations replace this field out of band. The checked-in script/config combination is unsafe as written.

## Entry 006 — Entry 002 reproduced

- Status: demonstrated defect against production `ServiceRewardsActor` code and the local f02 call boundary
- Reproducer: `review/reproducers/SRAIgnoredReplaceFailure.t.sol`
- Command: `forge test --contracts review/reproducers --match-contract SRAIgnoredReplaceFailureReproducer -vvv`
- Observed result: the expected `FVMRewards.ReplaceAddressFailed(-1)` revert did not occur. The second governance call emitted `OrchestratorWalletReplaced` after `CALL_ACTOR_BY_ID` returned no data and `FVMRewards.tryReplaceAddress` reported `-1`.
- Native actor comparison: pinned f02 `Actor::replace_address` and `Ledger::replace_address` return an actor error when the stream, writer, old recipient, new recipient, or table-capacity checks fail. An absent old row is not a successful no-op.
- Recovery: a later nonzero `SubmitShares` can rewrite the map; repeated zero-volume quarters leave the stale map in place. Removal clears `activeIdOf`, so the same removal cannot be retried.

## Entry 007 — Entry 003 refuted

- Status: refuted timing hypothesis; retained per append-only policy
- Evidence: during the reporting cycle for q, `_quarterOf(currentEpoch()) == q`. After submitting q-1, `nextQuarter == q`, while `_pendingSharesQuarter` requires `nextQuarter == q + 1`; therefore removal is blocked throughout q's posting and verification windows. It becomes possible only after `submitShares(q)` advances the line.
- Conclusion: no admitted poster can be removed while q remains unbound, so `totalUsd[q]` does not retain a removed poster through the hypothesized path. No reproducer was created because the precondition is unreachable through production calls.

## Entry 008 — Specification conflict: reporting-window endpoints

- Status: unresolved specification question, not classified as a defect
- Locations: `src/ServiceRewardsActor.sol:138-156`
- Accepted FIP-0118 uses posting `(E, E + POST]` and verification `(E + POST, E + POST + VERIFY]`.
- Pending clarification `7897ef0c...` changes both to half-open intervals `[Start, Start + duration)`, matching the implementation.
- Impact of baseline choice: calls at the exact start/end epochs change acceptance. Maintainer resolution is required before deployment.

## Entry 009 — Derived review invariants

- Status: process record
- Governance: only current owners approve; unanimity is evaluated against the current set; no stale approval may transfer to a replacement owner; held operations execute only after the final approval plus the configured hold; exact calldata identifies a task.
- SRA timing: quarter/window arithmetic has one unambiguous endpoint convention; only the currently open posting/verification quarter mutates; bound totals are final; only the latest bound quarter can update shares.
- SRA accounting: every mirror mutation changes its quarter aggregate by the same delta; submitted positive shares are unique, nonzero, and sum exactly to `1e18`; registry state and f02 recipient state change atomically.
- Registry: orchestrator IDs never alias; admitted identities and payout actor IDs are unique where required; bindings have one admitted owner; every transition emits enough data for deterministic off-chain attribution.
- Gate: checked quarters advance strictly by one; each quarter can cause at most one step; a rejected native step rolls back both counters; thresholds and w2 derive from the same authoritative step count.
- Native boundary: every method number, actor ID, tuple field, width, address form, and exit outcome matches pinned f02; non-success never commits dependent Solidity state.
- Deployment: proxy initialization is atomic; implementations are locked; owners, holds, timings, activation, cross-contract addresses, and chain config are non-placeholder and mutually consistent before broadcast.

## Entry 010 — Entry 005 reproduced

- Status: demonstrated deployment defect
- Reproducer: `review/reproducers/DeploymentActivationEpoch.t.sol`
- Command: `forge test --contracts review/reproducers --match-contract DeploymentActivationEpochReproducer -vvv`
- Observed result: `DeployScript.run()` on chain ID 314 read `.314.activationEpoch == 0`, deployed both proxies successfully, and `ServiceRewardsActor.quarterStart(0)` returned `0`; the assertion that reporting must not anchor to genesis failed.
- Remediation: populate the coordinated activation epoch before broadcast and make `DeployScript` reject zero/unset activation for live-network entries. Treat the existing zero output address fields separately; they are deployment outputs, while activation is an input.

## Entry 011 — Candidate: `RegisterStream` advertises epochs f02 cannot deserialize

- Status: demonstrated interface-domain mismatch; executable reproducer pending
- Locations: `src/StreamWeightActor.sol:41-64`, `src/lib/FVMRewards.sol:311-337`
- Native evidence: pinned f02 `RegisterStreamParams.activation_epoch` is `ChainEpoch` (`i64`) at `builtin-actors@faa3a016.../actors/reward/src/types.rs:45-50`.
- Observation: both Solidity entrypoints accept `uint64`, and FVMRewards encodes the full domain as unsigned CBOR. Values in `[2^63, 2^64-1]` are valid Solidity inputs but fail native tuple deserialization before actor logic.
- Reachability/impact: unanimous SWA governance only; clean atomic failure; immediate retry with an in-range activation. No attacker-controlled state loss.
- Narrow remediation: locally restrict activation to nonnegative `int64` range and encode it consistently with the native `ChainEpoch` domain.

## Entry 012 — Entry 011 reproduced

- Status: demonstrated interface-domain mismatch against the production encoder and pinned native type
- Reproducer: `review/reproducers/RegisterStreamEpochDomain.t.sol`
- Command: `forge test --contracts review/reproducers --match-contract RegisterStreamEpochDomainReproducer -vvv`
- Observed result: the expected local `ValueOutOfRange(2^63)` rejection did not occur. The production encoder emitted `1b8000000000000000` as the fourth `RegisterStream` tuple field and returned success from the permissive recorder.
- Native outcome: pinned Rust deserializes the field into `ChainEpoch`/`i64`; the same CBOR value is out of domain and returns `USR_SERIALIZATION` before dispatch.

## Entry 013 — Candidate: zero orchestrator creates a hidden live binding

- Status: credible low-severity correctness issue; reproducer pending
- Locations: `src/ServiceRewardsActor.sol:328-356`, `src/ServiceRewardsActor.sol:441-474`, `src/ServiceRewardsActor.sol:514-520`
- Observation: governance may admit `address(0)` as an orchestrator. Once admitted, governance may reassign a pair to that live ID. `bindingOf` then returns `address(0)`, indistinguishable from its documented unbound sentinel, while the internal binding remains occupied and `registerPairs` rejects it as `AlreadyBound`.
- Reachability/impact: requires unanimous governance action; zero can never call `postVolume` or self-register/cancel pairs. The pair is hidden from the view API and unavailable until governance repairs it.
- Narrow remediation: reject a zero orchestrator identity on admission. Existing tests currently lock the unsafe behavior as accepted.

## Entry 014 — Spec conflict: wallet replacement authorization and binding cancellation

- Status: unresolved baseline question
- Accepted baseline: FIP-0118 commit `9fbc581...` requires the replacement wallet to co-sign `ReplaceWallet` and does not expose `CancelBinding`.
- Clarification baseline: open PR #1286 head `7897ef0...` removes the replacement-wallet co-signature and adds orchestrator `CancelBinding`, matching this repository.
- Deployment decision required: name the governing specification before treating the repository's behavior as intended.

## Entry 015 — Entry 013 reproduced

- Status: demonstrated low-severity correctness issue
- Reproducer: `review/reproducers/ZeroOrchestratorHiddenBinding.t.sol`
- Command: `forge test --contracts review/reproducers --match-contract ZeroOrchestratorHiddenBindingReproducer -vvv`
- Observed transition: admit zero identity; register a pair to a normal orchestrator; unanimous `reassignBinding(..., address(0), false)` succeeds; `bindingOf` returns its zero/unbound sentinel; re-registration by a live orchestrator reverts `AlreadyBound(pairId)`.
- Recovery: unanimous governance can reassign the pair away from zero. The zero identity itself cannot post, register, or cancel because it cannot be `msg.sender`.

## Entry 016 — Candidate: external quarter numbering treats `q == 0` as nonexistent

- Status: not an implementation defect under this repository's explicit baseline; external specification decision remains unresolved
- Candidate basis: accepted FIP-0118 and clarification PR #1286 describe deployment quarters as one-based. Under that reading, accepting `postVolume(0)` could update the migration share map before the intended first reporting cycle.
- Contrary repository evidence: `REVIEWER_GUIDE.md:102` expressly defines contract quarter `q` as a zero-based reporting interval anchored at activation; production comments and the standard test suite consistently exercise q0. This can be a deliberate internal zero-based representation of external Q1.
- Retained reproducer: `review/reproducers/QuarterZeroAdmission.t.sol`
- Command: `forge test --contracts review/reproducers --match-contract QuarterZeroAdmissionReproducer -vvv`
- Observed result: an external-one-based expectation fails because `postVolume(0, 1e18)` succeeds at `ACTIVATION_EPOCH`.
- Decision required: publish the mapping between contract q0 and specification Q1, including which measurement interval its FPV summarizes. Do not change code solely from external numbering until that mapping is fixed.

## Entry 017 — Deployment blocker: native migration parameters are not evidenced here

- Status: unresolved deployment integration prerequisite
- Required native state: f02 must contain the exact deployed SWA in ID form as `swa_actor`, the intended f02 hold, the deployed SRA as service-stream writer, and the intended initial service wallet/share row.
- Repository evidence: `Deploy.s.sol` deploys only the two FEVM proxies; `deployments.json` contains no initial orchestrator/wallet or native migration outputs; f02 has no read method for `swa_actor` or its hold. `README.md` documents broadcast only.
- Risk: a correct Solidity deployment can be unusable or authorize the wrong contracts if the network migration and broadcast artifacts disagree. SRA local registry bootstrap must also correspond operationally to the migration's initial service row.
- Pre-deployment requirement: preserve an activation artifact binding chain ID, target epoch, SRA/SWA proxy and ID addresses, f02 writer/SWA/hold, and initial wallet; verify it against migration inputs or a post-upgrade state inspection tool.

## Entry 018 — Candidate: owner-bit recycling revives stale approvals

- Status: credible governance correctness issue; reproducer pending
- Locations: `src/lib/Owners.sol:52-79,86-104`, `src/lib/UnanimousProxied.sol:32-39`, `src/lib/UnanimousGovernance.sol:33-76,82-113`
- Observation: pending approvals are stored as owner-bit masks. `OwnersLibrary.removeOwner` explicitly warns that a removed bit can later be recycled and requires callers to veto stale tasks first, but `replaceOwner` removes/adds without invalidating any pending task. After the 160-bit cursor wraps, a new owner inherits an earlier owner's approvals.
- Reachability/impact: with the normal two-owner set, at least 159 unanimously approved owner rotations are required to recycle the first bit. Thereafter the other owner alone can execute an immediate pending task that the current replacement owner never approved. Timelocked tasks can similarly become unanimous and later execute.
- Narrow remediation: owner rotation must invalidate pending approvals globally, or approval identity/generation must prevent bit reuse from authenticating a different owner. Enumerating all pending task IDs is not currently possible, so a governance generation/epoch is the simpler clean design.

## Entry 019 — Entry 018 reproduced

- Status: demonstrated low-frequency governance defect
- Reproducer: `review/reproducers/OwnerBitRecycling.t.sol`
- Command: `forge test --contracts review/reproducers --match-contract OwnerBitRecyclingReproducer -vv`
- Observed result: owner1 approved an admission once, 159 valid unanimous owner rotations recycled owner1's bit into a new current owner, and owner2's sole current-owner vote admitted the candidate. The final assertion failed because the replacement owner never approved that task.
- Cost/reachability: the trace consumed about 10.1 million test gas across 318 rotation approvals. This is not a practical external attack; it is a latent authorization failure under long-lived governance churn.

## Entry 020 — Candidate deployment hardening: zero owner initializes a permanently unavailable approval

- Status: credible configuration hazard; shipped configurations currently use four nonzero addresses
- Locations: `src/lib/UnanimousProxied.sol:20-30`, `src/lib/Owners.sol:30-80`, `script/Deploy.s.sol:45-85`
- Observation: neither deployment nor owner insertion rejects `address(0)`. A proxy initialized with one zero owner has a two-bit unanimous owner set, but no real transaction can originate from the zero address; governance and upgrades are permanently blocked.
- Narrow remediation: constructor/deployment validation must reject zero owners. Equal owners already fail atomically during proxy initialization through `AlreadyOwner`.

## Entry 021 — Candidate deployment hardening: JSON epochs silently truncate to `uint64`

- Status: credible configuration hazard; no current value exceeds the range
- Location: `script/Deploy.s.sol:41-43`
- Observation: `json.readUint` returns `uint256`; explicit conversion to `uint64` truncates rather than reverts. A mistyped epoch at or above `2^64` can silently deploy with a different activation, hold, or window.
- Narrow remediation: read to `uint256`, require `<= type(uint64).max`, then convert.

## Entry 022 — Candidate deployment hardening: broadcast rerun overwrites canonical proxy outputs

- Status: credible operational hazard
- Locations: `script/Deploy.s.sol:64-91`, `deployments.json`
- Observation: `run()` always deploys fresh implementations and proxies, even when `.sra` or `.swa` already contains a nonzero address, then overwrites both fields in broadcast context.
- Impact: an accidental rerun can replace the addresses operators treat as canonical while migration-only f02 authorization remains bound to the original proxy.
- Narrow remediation: reject nonzero output fields by default; require an explicit, separately named redeployment path for replacement.

## Entry 023 — Entries 020-022 reproduced

- Status: demonstrated deployment-path hazards
- Reproducer: `review/reproducers/DeploymentHardening.t.sol`
- Command: `forge test --contracts review/reproducers --match-contract DeploymentHardeningReproducer -vv`
- Zero owner: proxy initialization succeeded instead of reverting.
- Epoch truncation: parsing `18446744073709551616` (`2^64`) succeeded and returned the truncated value instead of reverting.
- Rerun: two `DeployScript.run()` calls for chain ID 314 deployed different SRA/SWA proxy pairs; the idempotency assertion failed on SRA first.
- Scope: the checked-in owner and duration values do not currently trigger the first two hazards. The rerun guard becomes directly relevant as soon as output addresses are populated.

## Entry 024 — Appendlog path correction

- Status: process record
- Entry 000 stated that retained reproducers would live under `test/reproducers/`. To keep intentionally failing evidence out of the normal `test/` root, all reproducers are instead retained under `review/reproducers/`.

## Entry 025 — Candidate: masked ID resolution is mistaken for actor existence

- Status: demonstrated cross-boundary validation defect; executable reproducer pending
- Locations: `src/ServiceRewardsActor.sol:714-724`, `lib/fvm-solidity/src/FVMActor.sol:64-101`
- Observation: wallet admission calls only `FVMActor.getActorId`. For a masked address, that converts directly to f0 and asks `RESOLVE_ADDRESS`. The FVM runtime returns an ID address's numeric ID without checking whether actor state exists.
- Native evidence: pinned f02 separately calls `get_actor_code_cid` after resolution and returns `USR_NOT_FOUND` when the recipient actor is absent (`builtin-actors@faa3a016.../actors/reward/src/lib.rs`, `resolve_existing`).
- Impact: admission/replacement can accept an unallocated masked ID. A later positive `SubmitShares` then reverts at f02 and leaves the submission line blocked; if that ID is allocated to an attacker before submission, the attacker-controlled actor becomes the payout recipient.
- Narrow remediation: after resolution, check actual actor existence (for example an available actor-code/existence primitive; on FEVM evaluate exact `codehash` semantics for native/account actors) before committing the wallet.

## Entry 026 — Candidate: permissionless upgrade completion injects unapproved caller and value

- Status: credible conditional upgrade hazard; reproducer pending
- Locations: `src/lib/UnanimousProxied.sol:41`, `src/lib/UnanimousGovernance.sol:42-48`, OpenZeppelin `UUPSUpgradeable.upgradeToAndCall` and `ERC1967Utils.upgradeToAndCall`
- Observation: owners commit only `msg.data`. After the hold, any address may submit the exact calldata with arbitrary `msg.value`; OpenZeppelin delegatecalls the approved migration payload while preserving that finalizer as `msg.sender` and its value.
- Impact: a future reinitializer that derives roles/configuration from `msg.sender` or `msg.value` can grant control to a front-running public finalizer despite exact implementation/payload approval.
- Narrow remediation: make held upgrades empty-data only and run migration through a separately committed canonical-context operation, or explicitly commit/enforce executor and value. At minimum reject nonzero value.

## Entry 027 — Entry 025 reproduced

- Status: demonstrated validation defect
- Reproducer: `review/reproducers/MaskedNonexistentWallet.t.sol`
- Command: `forge test --contracts review/reproducers --match-contract MaskedNonexistentWalletReproducer -vv`
- Observed result: a masked address with zero `codehash` was configured to receive the FVM-correct numeric-ID resolution response; the second governance approval admitted it instead of reverting.
- Pinned native comparison: `builtin-actors@faa3a016...` uses `resolve_existing`, which requires both `resolve_address` and `get_actor_code_cid`; the same absent recipient is rejected later by f02.

## Entry 028 — Entry 026 reproduced

- Status: demonstrated conditional upgrade-context defect
- Reproducer: `review/reproducers/UpgradeFinalizerContext.t.sol`
- Command: `forge test --contracts review/reproducers --match-contract UpgradeFinalizerContextReproducer -vv`
- Observed caller: after both owner approvals and the hold, the migration delegatecall stored the arbitrary public finalizer `0xFd21...3e0e`, not a canonical proxy context.
- Observed value: the same exact approved calldata finalized with `1 ether`; the migration stored the uncommitted `msg.value`.
- Reachability bound: owners must first approve the exact implementation and migration bytes. The defect is exploitable only when those bytes consume caller or value, but standard initializer patterns commonly consume `msg.sender`.

## Entry 029 — Candidate: gate retune can race a check and desynchronize local steps from f02 weight

- Status: demonstrated design violation; executable reproducer pending
- Locations: `src/StreamWeightActor.sol:118-149`, `src/lib/GateParams.sol:25-29`
- Pinned specification: accepted FIP-0118 requires a discretionary w2 record and matching `steps` adjustment to take effect at the same epoch, with the parameter write effective later than the last check.
- Observation: `setGateParams` stores only local params after a Solidity hold; the matching `setWeightRecords` is a separate native queue. At their shared maturity epoch, a permissionless check can execute first under old steps, while its f02 call settles the new record and queues an old-counter step. Completing `setGateParams` afterward leaves the native queued step free to overwrite the matched weight one hold later.
- Impact example: paired w2=50%/steps=8 matures; a q2 pass queues 15% from old steps=0; local steps then becomes terminal 8; native 15% later applies while further gates revert `StepsComplete`.
- Narrow remediation: commit a single pending transition with an explicit effective epoch and matching record, prevent checks from interleaving its activation, and enforce effective epoch later than the recorded last-check epoch.

## Entry 030 — Candidate: consecutive late gate passes require one native hold each

- Status: demonstrated SRA/SWA/f02 liveness mismatch; executable reproducer pending
- Locations: `src/StreamWeightActor.sol:118-140`, pinned f02 `streams/queue.rs:91-110,470-474,563-568`
- Pinned specification: accepted FIP-0118 says after a late check, the next bound quarter becomes callable immediately and says gate-write rejection on this schedule occurs only after a discretionary w1 change.
- Observation: every passing check queues the same uncancellable schedule-wide `StepWeightRecords` key; pinned f02 allows only one pending write per key. A second consecutive passing stale quarter reverts until the first step's full native hold expires.
- Impact: an eight-pass historical backlog can serialize across roughly eight seven-day holds instead of self-healing immediately; reward residual continues burning meanwhile. Calls roll back safely and remain retryable.
- Narrow remediation: allow ordered pending gate steps or coalesce already-bound decisions into a safe absolute target; otherwise amend the protocol liveness claim.

## Entry 031 — Candidate: unchecked gate exponentiation can wrap a target to zero

- Status: credible governance-parameter arithmetic defect; executable reproducer pending
- Locations: `src/StreamWeightActor.sol:147-149`, `src/lib/GateParams.sol:40-42`, `src/lib/FixedU18.sol:70-75,105-118`
- Observation: `setGateParams` bounds only `steps`. Assembly multiplication/exponentiation wraps modulo 2^256. With raw ratio `2^128` and steps=2, squaring wraps exactly to zero; the computed threshold becomes zero and a zero-volume quarter passes.
- Reachability: unanimous governance must approve unsupported parameters, so defaults are unaffected. Once mature, the false pass and uncancellable native step are permissionless.
- Narrow remediation: validate the full remaining target sequence at parameter installation using checked full-precision fixed-point arithmetic and the ratified retune rounding rule.

## Entry 032 — Entries 029-031 reproduced

- Status: three demonstrated gate defects
- Reproducer: `review/reproducers/GateStateMachine.t.sol`
- Command: `forge test --contracts review/reproducers --match-contract GateStateMachineReproducer -vv`
- Retune race: after paired 50%/steps=8 maturity, an interleaved q2 check queued 15%; one hold later native w2 was `0.15e18` while local steps remained terminal at 8.
- Late-pass serialization: q2 passed, then an immediately invoked passing q3 reverted `StepWeightRecordsFailed(16)` because the native Step key remained occupied.
- Arithmetic: ratio raw `2^128`, steps=2 produced a wrapped zero threshold; zero FPV passed and advanced stored steps from 2 to 3.
- Native fidelity: this repository's behavioral f02 mock enforces the same one-key admission and settlement order as pinned `builtin-actors@faa3a016...`; the arithmetic and local retune ordering occur entirely in production Solidity.

## Entry 033 — Candidate: wrapped hold deadline can mature before approval

- Status: credible generic configuration defect; checked-in holds are safe; reproducer pending
- Locations: `src/lib/Epoch.sol:23-27`, `src/lib/UnanimousGovernance.sol:42-45`, `src/lib/UnanimousProxied.sol:20-25`
- Observation: `Epoch.add` uses raw assembly addition into `uint64`. If `modified + hold > type(uint64).max`, the deadline wraps into the past and a fully approved held gate change or upgrade becomes immediately permissionless.
- Reachability: requires an extreme trusted hold misconfiguration or a chain epoch near the uint64 horizon; no present deployment value triggers it.
- Narrow remediation: compute the deadline in `uint256`, require it fits `uint64`, and preferably store the validated deadline when unanimity is reached.

## Entry 034 — Entry 033 reproduced

- Status: demonstrated generic timelock arithmetic defect; inactive under current configuration
- Reproducer: `review/reproducers/HoldDeadlineWrap.t.sol`
- Command: `forge test --contracts review/reproducers --match-contract HoldDeadlineWrapReproducer -vv`
- Observed result: at epoch 100 with hold `type(uint64).max`, both owners approved a 4000e18 gate base and an arbitrary caller completed it in the same epoch; stored base changed from 3500e18 to 4000e18 without any positive delay.

## Entry 035 — Entry 016 reclassified: q0 is a phantom reporting cycle

- Status: demonstrated medium-impact lifecycle defect; supersedes Entry 016's provisional classification
- Pinned timeline: accepted FIP-0118 defines external Quarter 1 as the first quarter ending at `ACTIVATION_EPOCH + EPOCHS_PER_QUARTER`; clarification PR #1286 makes `Start(1) = activation` and begins posting FPV(Q) at `Start(Q+1)`. Neither has an FPV report at activation.
- Resolution of contrary evidence: `REVIEWER_GUIDE.md` describes the repository's internal q as zero-based, but that indexing cannot create an extra report before external Quarter 1 ends. Internal q0 would need to correspond to external Q1's report at `activation + L`, not a new cycle at activation.
- Reproducer: `review/reproducers/QuarterZeroAdmission.t.sol`
- Command: `forge test --contracts review/reproducers --match-contract QuarterZeroAdmissionReproducer -vv`
- Observed results: `postVolume(0)` succeeded at activation, and after posting+verification `submitShares(0)` replaced the migration-installed one-recipient map with the q0 poster's wallet.
- Native behavior: f02 is quarter-agnostic and accepts the valid `SetShares`; it cannot reject or repair the phantom cycle.
- Narrow remediation: reserve q0 as invalid or remap internal indices so the first report opens only when Quarter 1 ends; initialize submission/pending state consistently and reject pre-first-quarter post/correct/submit/aggregate calls.

## Entry 036 — Specification conflict: mainnet quarter length

- Status: unresolved deployment baseline question
- Accepted FIP-0118 commit `9fbc581...` lists `EPOCHS_PER_QUARTER = 259200`; open clarification PR #1286 head `7897ef0...` and `deployments.json` use `262974`.
- Impact: the immutable SRA calendar drifts by 3774 epochs per quarter depending on the chosen revision. Ratify and pin one value before deployment.

## Entry 037 — Specification question: local per-orchestrator FPV cap

- Status: unresolved domain constraint
- Location: `src/ServiceRewardsActor.sol:46-48,300-304,472-474`
- Observation: the contract rejects an orchestrator's quarterly FPV above raw `1e30` (one trillion 18-decimal USD) to bound fixed-point arithmetic. No equivalent cap was found in accepted FIP-0118 or clarification PR #1286.
- Decision required: ratify the cap as protocol policy or use full-precision arithmetic with a separately defined aggregate bound.

## Entry 038 — Final verification record

- Status: review evidence corpus and unaffected standard suite verified
- Complete reproducer command: `forge test --contracts review/reproducers --summary`
- Reproducer result: compiler succeeded; 17 expected pre-fix assertions failed across 11 retained reproducer contracts. Imported standard suites also produced 429 passes and no unrelated failures.
- Standard CI-profile command: `FOUNDRY_PROFILE=ci forge test --summary`
- Standard result: 429 passed, 0 failed, 0 skipped; invariant campaign used 256 runs and 128000 calls per invariant.
- Formatting: `forge fmt --check` passed.
- Lint: `forge lint --deny notes --quiet` passed.
- Static diagnostics: Solidity LSP diagnostics previously returned no issues for `src/**/*.sol`.

## Entry 039 — Review report issued

- Status: final process record
- Report: `review/REPORT.md`
- Deployment decision: NO-GO at target revision until deployment blockers and confirmed implementation findings are resolved and the normative FIP revision is pinned.
- Evidence retained: 11 reproducer contracts under `review/reproducers/`; no finding reproducer was deleted after refutation or reclassification.

## Entry 040 — Maintainer impact triage and issue cross-reference

- Status: report presentation updated; prior entries retained
- Deployment D-series: reclassified as a lower-prominence readiness checklist rather than audit vulnerabilities.
- F-01: confirmed already tracked by issue #55, “SRA::replaceWallet should handle errors from f02.”
- F-02: issue #53 is related deployment work but does not currently report the phantom q0 cycle. It tracks seating the initial Orchestrator and emitting `OrchestratorAdmitted`; F-02 separately shows `postVolume(0)` and `submitShares(0)` overwriting that migration map before Quarter 1 ends.
- F-03 impact: none under initial/default parameters; latent in a future FIP-governed paired w2/steps retune. If triggered, native weight can be too low until held governance repair, increasing burn without attacker payout.
- F-04 impact: atomic, retryable economic liveness only—late consecutive passing quarters serialize across holds, delaying escalation and increasing residual burn; no skipped quarter or wrong recipient.
- F-05 impact: requires both owners to approve a nonexistent masked-ID wallet. Normal effect is blocked positive share submission until wallet repair; ordinary unresolved f410 wallets are already rejected.
- F-06 impact: advisory for current code. It becomes dangerous only if a future unanimously approved migration payload derives privilege/configuration from finalizer `msg.sender` or uncommitted `msg.value`.

## Entry 041 — F-02 resolved to one-based quarter initialization TODO

- Status: reclassified; supersedes Entry 040's separation from issue #53
- Decision: valid external quarters start at Q=1. Under that domain there is no conceptual phantom-quarter mechanism; the observed q0 path exists because the implementation does not yet enforce the domain.
- Required implementation details: initialize proxy `nextQuarter = 1`; reject Q=0 through `_quarterStart` so every report/write/bound view rejects it; retain internal `_quarterOf == 0` during `[activation, activation + L)` as a sentinel.
- Timing check: with the existing formula, `_quarterStart(1) = activation + L`. Before then, `nextQuarter == 1 == nowQ + 1`, so `_pendingSharesQuarter` correctly reports no pending submission. At `activation + L`, internal `nowQ` becomes 1 and Q1 becomes pending until submission.
- Tracking: fold these acceptance criteria into issue #53 alongside initial-orchestrator seating and its admission event.
- Reproducer retained: `review/reproducers/QuarterZeroAdmission.t.sol` continues to show the missing Q=0 rejection before the fix.

## Entry 042 — F-02 issue reference corrected

- Status: tracking correction; supersedes Entries 040-041 only as to issue number
- F-02 is already tracked exactly by issue #52, “SRA: quarter 0 is treated as a real quarter, the FIP starts at quarter 1.”
- Issue #52 requests `nextQuarter = 1` and rejection of Q=0 in `postVolume`, `correctVolume`, and `submitShares`, matching this review's resolution.
- Issue #53 remains the separate initial-Orchestrator seating and admission-event task.

## Entry 043 — F-06 narrowed to uncommitted upgrade value

- Status: finding wording corrected; caller-context portion refuted as independently problematic
- The permissionless finalizer's `msg.sender` is intentional. Owners approve exact implementation and migration calldata knowing completion is public.
- The surviving issue is `msg.value`: task identity hashes only calldata, so the public finalizer can choose the value observed by a nonempty `upgradeToAndCall` migration delegatecall.
- Current impact: none without a future payable/value-sensitive migration. Potential impact is owner-unapproved value-derived state or unexpected FIL locked in the proxy.
- Remediation: require zero value on governed UUPS upgrades and fund migrations through a separate explicit operation. Merely hashing value is insufficient because value attached to each non-executing owner approval remains on the proxy.
- Retained reproducer: `UpgradeFinalizerContext.t.sol`; its value test demonstrates the surviving issue, while its caller test is retained as evidence of the now-classified intentional public-finalizer behavior.

## Entry 044 — F-06 arbitrary caller context clarified

- Status: wording clarification
- The report now states explicitly that any arbitrary public caller may finalize and is observed as migration `msg.sender`.
- That arbitrary caller identity remains intentional rather than an independent finding; F-06 remains narrowly about the caller also selecting uncommitted `msg.value`.
