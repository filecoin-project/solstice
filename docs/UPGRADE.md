# Upgrading SRA and SWA

How a merged code change becomes the live implementation behind the ServiceRewardsActor (SRA) and StreamWeightActor (SWA) proxies on calibration and mainnet. The two proxies are permanent: their addresses are `sra` and `swa` in [`deployments.json`](../deployments.json) and are hardwired into Lotus ([lotus#13809](https://github.com/filecoin-project/lotus/pull/13809)). An upgrade replaces the implementation behind each proxy; it never moves a proxy. See [DEPLOYMENT.md](./DEPLOYMENT.md) only if you are bringing up a new network.

## How an upgrade works

| Piece | Where | What it does |
|---|---|---|
| Proxies | Two OpenZeppelin [`ERC1967Proxy`](../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol) contracts; addresses `sra` and `swa` in [`deployments.json`](../deployments.json) | Hold all state and delegate every call to their implementation. No admin; only the implementation's own logic can change which implementation a proxy points at. |
| Implementations | [`ServiceRewardsActor`](../src/ServiceRewardsActor.sol) and [`StreamWeightActor`](../src/StreamWeightActor.sol), one deployment each per version; the live one is whatever each proxy's ERC-1967 slot points at, recorded in the [release](https://github.com/filecoin-project/solstice/releases) for the version | Inherit [`UnanimousProxied`](../src/lib/UnanimousProxied.sol), whose `_authorizeUpgrade` is gated by the `unanimous` modifier in [`UnanimousGovernance`](../src/lib/UnanimousGovernance.sol). SRA and SWA are always upgraded together. |
| Version | [`version.json`](../version.json) and [`CHANGELOG.md`](../CHANGELOG.md) | One version covers both contracts. Bumping it on `main` makes the [Releaser workflow](https://github.com/filecoin-project/solstice/actions/workflows/releaser.yml) tag the commit and open a pre-release with the changelog section. |
| Owners | Two [Safe](https://safe.filecoin.io) multisigs per contract: `sraOwner1`, `sraOwner2`, `swaOwner1`, `swaOwner2` in [`deployments.json`](../deployments.json) | The only parties that can approve an upgrade. |
| Hold | `hold` in [`deployments.json`](../deployments.json), fixed at deployment as an immutable and the same for every task | Epochs that must pass after the second owner's approval before a task can execute. |
| Operations key (`DEPLOYER_PRIVATE_KEY`) | Secret on the [`calibnet`](https://github.com/filecoin-project/solstice/settings/environments/22478295461/edit) and [`mainnet`](https://github.com/filecoin-project/solstice/settings/environments/22478417501/edit) [environments](https://github.com/filecoin-project/solstice/settings/environments) | Deploys implementations, queues proposals on the owner Safes, executes, pays gas. One-time setup: an owner of each of the four Safes registers its address as a [proposer](https://help.safe.global/articles/1671337645-proposers) in the Safe app. It's a plain key with no power over the contracts; it's not an owner key. |

The upgrade call is [`upgradeToAndCall(newImplementation, data)`](../lib/openzeppelin-contracts/contracts/proxy/utils/UUPSUpgradeable.sol) on the proxy. Its task id is `keccak256(calldata)`, so both owners must send byte-identical calldata with zero value.

| Step | Who | Effect |
|---|---|---|
| Submit | Whichever owner Safe executes first | `Submitted` and `Approved` events. Nothing changes yet. |
| Approve | The other owner Safe | Second `Approved`. The hold starts at this block. |
| Hold | Anyone | Execution reverts with `HoldUntil(epoch)` until the hold elapses. Either owner can `veto(taskId)`. |
| Execute | Anyone | The proxy's implementation slot changes, `data` (if any) runs, the task is deleted. |

## Steps

Calibration first, then mainnet, from the same tag. Steps 2 to 7 are dispatches of the [Upgrade workflow](https://github.com/filecoin-project/solstice/actions/workflows/upgrade.yml) or the [Deploy Contract workflow](https://github.com/filecoin-project/solstice/actions/workflows/deploy-contract.yml), always with the version tag as the ref. The ref matters for the steps that build or verify code (rehearse, deploy, propose, verify); `status` and `execute` only read and send calldata, so they can be dispatched from the newest tag, which matters for a rollback whose own tag carries older tooling. Each workflow run is a thin wrapper around [`tools/upgrade.py`](../tools/upgrade.py), which can also be run locally with the same arguments. Each GitHub Action run's summary is the record; link it from the [tracking issue](#0-open-a-tracking-issue).

### 0. Open a tracking issue

Use the [upgrade issue template](https://github.com/filecoin-project/solstice/issues/new?template=upgrade.md). Progress and decisions go in issue comments; the durable record (implementation addresses, transaction hashes) accumulates in the GitHub release automatically.

Every SRA or SWA code upgrade needs an accepted [FIP](https://github.com/filecoin-project/FIPs) first: [FIP-0118 section 4.2](https://github.com/filecoin-project/FIPs/blob/master/FIPS/fip-0118.md#42-governance-tiers-and-powers) lists "upgrade the SWA's code" among the SWA writes that each require a FIP, and "upgrade the SRA's code" as the one registry change that does, and the [section 4.4](https://github.com/filecoin-project/FIPs/blob/master/FIPS/fip-0118.md#44-the-fip--governance-repository-boundary) table gives the process for SWA or SRA code as "FIP, both multisigs, on-chain hold; no network upgrade". The owner Safes approve on the strength of that FIP. Link it in the issue before step 1.

### 1. Merge

The PR carries the code change, the next version in [`version.json`](../version.json), and its notes under that version's heading in [`CHANGELOG.md`](../CHANGELOG.md). CI does the safety checks: the [Storage Layout workflow](https://github.com/filecoin-project/solstice/actions/workflows/storage-layout.yml) fails any change to the namespaced structs that is not append-only, using the compiler's layout of [`StorageLayoutProbe`](../test/layout/StorageLayoutProbe.sol) via [`tools/storage_layout.py`](../tools/storage_layout.py); [`StorageSlots.t.sol`](../test/StorageSlots.t.sol) pins every slot constant to its ERC-7201 derivation; and [`UnanimousProxied.t.sol`](../test/UnanimousProxied.t.sol) covers the governance paths. If the layout check fails, the change needs a storage migration, which this runbook does not cover; stop and design that first. On merge, the [Releaser workflow](https://github.com/filecoin-project/solstice/actions/workflows/releaser.yml) tags the commit and creates the GitHub pre-release. Link the PR and the GitHub pre-release from the issue.

### 2. Rehearse

Dispatch [Upgrade](https://github.com/filecoin-project/solstice/actions/workflows/upgrade.yml) with operation `rehearse`, the network, ref the tag. It runs [`script/Rehearse.s.sol`](../script/Rehearse.s.sol): one local fork in which both implementations are built from source, and for each contract both owner Safes are impersonated to submit and approve, early execution is shown to revert, the hold is rolled past, and the upgrade executes. The summary ends with `REHEARSAL COMPLETE` or the failing step. Nothing is sent. Rehearse on each network before its step 3, since the two networks have different holds and parameters.

### 3. Deploy the implementations

> [!NOTE]
> This step [requires approval](#what-are-the-responsibilities-of-a-deployment-reviewer).

Dispatch [Deploy Contract](https://github.com/filecoin-project/solstice/actions/workflows/deploy-contract.yml) with target "Implementations only", dry run off, ref the tag. It deploys both implementations from the tag and verifies their source on Sourcify. Both contracts are upgraded every time, even if only one changed: shared code (governance, epoch and gate libraries) means either bytecode can change when the other does, and the verifier rebuilds both from the tag. Take the SRA and SWA implementation addresses from the run summary; every later step needs both.

### 4. Propose to the owners

> [!NOTE]
> This step [requires approval](#what-are-the-responsibilities-of-a-deployment-reviewer).

Dispatch [Upgrade](https://github.com/filecoin-project/solstice/actions/workflows/upgrade.yml) with operation `propose`, the network, and both implementation addresses. The run:
1. makes the same checks as [`check-setup`](#how-do-i-check-that-everything-is-set-up-correctly) and stops before posting anything if an owner Safe in [`deployments.json`](../deployments.json) is not an owner on its proxy or does not have the operations key as a proposer; if other transactions are queued ahead on a Safe, it says so, since that Safe's owners must execute or reject them before the upgrade. 
2. runs the full verifier ([`script/Verify.s.sol`](../script/Verify.s.sol)) with the new addresses as candidates: it rebuilds both implementations from the tag and compares the runtime code against the candidates instead of the live implementations, refuses a candidate equal to the current implementation, and still checks the live proxies' code, owners and seeded state. 
3. queues the upgrade transaction on all four owner Safes through the [Filecoin Safe Transaction Service](https://transaction.safe.filecoin.io/). 

Rerunning `propose` is idempotent; it skips Safes where the transaction is already queued and Safes that have already executed it.

The proposer then needs to manually tell each owner group (e.g., over Slack) that their Safe has a transaction queued, and each owner group confirms and executes it in the [Safe app](https://safe.filecoin.io). (See the Submit and Approve rows in ["How an upgrade works"](#how-an-upgrade-works) for what the first and second executions do.)

> [!NOTE]
> If there is an issue with [Safe's proposer functionality](https://help.safe.global/articles/1671337645-proposers), the same run summary prints each proxy address and calldata; the owners can enter those in the Safe app's transaction builder instead. It is the same transaction.

### 5. Track the hold

Dispatch [Upgrade](https://github.com/filecoin-project/solstice/actions/workflows/upgrade.yml) with operation `status` and both implementation addresses. The summary shows, for SRA and SWA, how many owners have approved and the epoch the hold ends. There is no need to poll: run it once after each owner group reports that it has executed, to confirm the approval landed and (after the second) to read the epoch the hold ends, and once more before step 6. If something is wrong, either owner cancels with the veto calldata printed in the same summary. `status` reports whatever task the given addresses name, so running it with the previous implementation addresses shows a prepared rollback.

### 6. Execute

> [!NOTE]
> This step [requires approval](#what-are-the-responsibilities-of-a-deployment-reviewer).

After the holds, dispatch [Upgrade](https://github.com/filecoin-project/solstice/actions/workflows/upgrade.yml) with operation `execute` and both implementation addresses. Anyone may execute, but running it through the workflow keeps the record in one place. The two holds end at different epochs because each contract has its own owner Safes; the run sends nothing until both are executable, and fails if either transaction reverts or a proxy's implementation slot does not change. If it stops after the first contract for any reason, rerun it: a contract whose proxy already points at the new implementation is skipped, so only the remaining one is sent.

### 7. Verify

Dispatch [Upgrade](https://github.com/filecoin-project/solstice/actions/workflows/upgrade.yml) with operation `verify`. It runs [`script/Verify.s.sol`](../script/Verify.s.sol), which rebuilds both implementations and both proxies from the tag and checks them against the live contracts, ending with `ALL CHECKS PASSED` or the failed check. On success the run appends the live implementation addresses and epoch to the release (every run appends, so a rerun or a rollback's re-verification shows as its own line); on mainnet it also promotes the pre-release to the final release. [`deployments.json`](../deployments.json) does not change: the two proxy addresses are all it records for the live contracts, and the chain is the source of truth for the implementation behind each.

### 8. Repeat for mainnet

Repeat steps 2 to 7 on mainnet.

## Rollback

- Before execution, rollback is a veto: either owner sends the veto calldata printed by `status`, and the task is gone. Nothing has changed on chain, so this is always safe.
- After execution, rollback is a new upgrade back to the previous implementations, subject to the full hold. It is safe when the new version only appended storage (which is all the [layout gate](#1-merge) in [`tools/storage_layout.py`](../tools/storage_layout.py) allows), because the previous code simply ignores the new fields. It is not safe if the new version ran a reinitializer or migration that reinterpreted existing storage; that case needs its own design before it is attempted. The [tracking issue](#0-open-a-tracking-issue) template asks for the previous implementation addresses up front so the rollback proposal can be built from them. One caveat: the verifier checks the live owner set against [`deployments.json`](../deployments.json) at the dispatched ref, so after an owner rotation (`replaceOwner`) a tag cut before it fails that check. To roll back to such a tag, cut a patch tag that carries the old `src` with the current `deployments.json`, or have the owners use the Safe transaction builder as in the note under [step 4](#4-propose-to-the-owners).
- Optional, for a change risky enough to want a fast rollback: once the upgrade has executed (step 6), dispatch `propose` with the previous implementation addresses and ref the previous version's tag. This only works after execution: the code check rebuilds from the checked-out ref, and the verifier refuses a candidate equal to the implementation a proxy already points at, since such a proposal would be a no-op that still consumes a hold and, in practice, means someone pasted the live address instead of the new one. Have the first owner execute it at once and the second owner execute it at the start of the monitoring window you want; the rollback becomes executable one hold after that second execution. From then until an owner vetoes it, anyone can execute it, so the final step is that veto; the [issue template](../.github/ISSUE_TEMPLATE/upgrade.md) has a checkbox for it, and `status` with the previous addresses shows the rollback task.

## FAQ

### How do I check that everything is set up correctly?

Dispatch the [Upgrade](https://github.com/filecoin-project/solstice/actions/workflows/upgrade.yml) workflow with operation `check-setup` on each network from `main` or a `v*` tag since the environments accept no other ref. It sends nothing. It prints the key's public address and balance, which is the only way to confirm the secret holds the intended key, since GitHub never shows a secret. For each owner Safe in [`deployments.json`](../deployments.json), it also prints whether that Safe is an owner on the proxy, whether the operations key is its proposer, and what is queued at or above its nonce. It fails if an owner in [`deployments.json`](../deployments.json) is not an owner on its proxy.

> [!NOTE]
> This check [requires approval](#what-are-the-responsibilities-of-a-deployment-reviewer) since it accesses the operations key. (Given this is a read-only operation, it would be ideal if a reviewer wasn't required, but given we don't expect this workflow to be called much, additional environments with different approval settings were not configured.)

### What are the responsibilities of a deployment reviewer?

These workflows access the "operations key" (stored as `DEPLOYER_PRIVATE_KEY` secret on GitHub) on Calibration and Mainnet through a [GitHub environment](https://github.com/filecoin-project/solstice/settings/environments):
* [Deploy the implementations](#3-deploy-the-implementations)
* [Propose](#4-propose-to-the-owners)
* [Execute](#6-execute)
* [Check setup](#how-do-i-check-that-everything-is-set-up-correctly)

They require a second person approval. By default, GitHub shows dispatch inputs nowhere on a run, so our workflow run's title carries them, and we have a `pregate` job that finishes before the approval request which puts them in the run summary with its checks. This includes whether:
1. the ref is `main` or a `v*` tag
2. its commit is on `main`
3. any implementation addresses given have code on chain.

If a check fails, that job fails and no approval is requested. So the approver's job is not those checks but what a machine cannot know: open the run summary and confirm that the network, operation and tag are the ones in the [tracking issue](#0-open-a-tracking-issue), and that the implementation addresses are the ones in the [deploy step](#3-deploy-the-implementations)'s run summary.

### What if GitHub is down during an upgrade?

The [Upgrade workflow](https://github.com/filecoin-project/solstice/actions/workflows/upgrade.yml) is a thin wrapper around [`tools/upgrade.py`](../tools/upgrade.py), so every operation can be run from a checkout of the version tag instead. It needs [Foundry](https://getfoundry.sh) and [uv](https://docs.astral.sh/uv/) (the versions CI uses are in [`.github/actions/setup/action.yml`](../.github/actions/setup/action.yml)), the submodules, and an RPC for the network:

```sh
TAG=v1.2.3 # <-- set to proper version
git checkout "$TAG" && git submodule update --init --recursive
export ETH_RPC_URL=https://api.calibration.node.glif.io/rpc/v1   # mainnet: https://api.node.glif.io/rpc/v1
uv run --locked tools/upgrade.py status --sra 0x... --swa 0x...
```

- `rehearse`, `status` and `verify` need no key.
- `verify --record-release "$TAG"` also needs the `gh` CLI, so leave it off and record the result by hand.
- `propose`, `execute` and `check-setup` need `DEPLOYER_PRIVATE_KEY` set.
- `propose`, `execute` and deploying the implementations change on-chain state. In GitHub, the [environment](https://github.com/filecoin-project/solstice/settings/environments) makes a second person approve them; a local run has no such gate, so have a second person check each invocation.

### Working around not having the GitHub secret for `DEPLOYER_PRIVATE_KEY`

These operations are affected by not having the GitHub secret:

- [Deploying the implementations](#3-deploy-the-implementations) is not part of [`tools/upgrade.py`](../tools/upgrade.py), and any funded key works: run [`DeployImplementation.s.sol`](../script/DeployImplementation.s.sol) directly with forge as shown in [DEPLOYMENT.md](./DEPLOYMENT.md#two-ways-to-run-them).
- `propose` only works with a key registered as a proposer on all four owner Safes, and refuses before posting anything otherwise. Without one, run `status` with both implementation addresses instead (it needs no key): it prints each proxy address and the calldata, which the owners enter in the Safe app's transaction builder (see the note under [step 4](#4-propose-to-the-owners)).
- `execute`: anyone may execute once the holds have passed, so `DEPLOYER_PRIVATE_KEY=0x<any funded key> uv run --locked tools/upgrade.py execute --sra 0x... --swa 0x...` works.

### How do I rotate the operations key stored in `DEPLOYER_PRIVATE_KEY`?

1. Fund the new key on both networks.
2. Replace the `DEPLOYER_PRIVATE_KEY` secret on the [`calibnet`](https://github.com/filecoin-project/solstice/settings/environments/22478295461/edit) and [`mainnet`](https://github.com/filecoin-project/solstice/settings/environments/22478417501/edit) environments.
3. Have an owner of each of the four owner Safes, on each network, add the new address as a [proposer](https://help.safe.global/articles/1671337645-proposers) in the Safe app and remove the old one.
4. [Check the setup](#how-do-i-check-that-everything-is-set-up-correctly) on each network: it should print the new address.

### Why doesn't this runbook live in the governance repo?

Upgrades are expected to be driven by engineers at the request of the community, through the FIP process and the [governance repo](https://github.com/filecoin-project/solstice-governance). The governance repo says what should change and why, and this runbook says how an engineer carries it out. Keeping the runbook next to the contracts, the scripts and the workflows it names means a change to any of them is reviewed together with the runbook that depends on it, so the two cannot drift apart.

## Related

- [#26](https://github.com/filecoin-project/solstice/issues/26): the issue that asked for this process.
- [#84](https://github.com/filecoin-project/solstice/pull/84): the PR that added it, including the one-time setup (environments, operations key, proposer registration on the owner Safes) and what is deliberately out of scope.
