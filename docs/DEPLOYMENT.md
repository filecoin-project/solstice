# Deployment

The SRA and SWA proxies were deployed once for nv29 and are not expected to be deployed again on calibration or mainnet. A code change is an [upgrade](./UPGRADE.md) of the implementation behind each proxy, and moving a proxy would itself be a network upgrade. This page records where the live proxy addresses come from, how the two deploy scripts are run, and how to bring up a new network.

Vocabulary: a **proxy** is the permanent contract that holds state and whose address everyone uses (`sra` and `swa` in [`deployments.json`](../deployments.json)); an **implementation** is the code a proxy currently delegates to, replaced by upgrades and recorded in the [release](https://github.com/filecoin-project/solstice/releases) for each version.

The live proxy addresses are hardwired into Lotus by [lotus#13809](https://github.com/filecoin-project/lotus/pull/13809). The verification record for that deployment, with explorer links for the proxies and the v1 implementations, is in [#84](https://github.com/filecoin-project/solstice/pull/84).

## The two deploy scripts

Both extend [`DeploymentScript`](../script/DeploymentScript.sol), which loads the chain's entry in [`deployments.json`](../deployments.json) (owners, orchestrator, epoch parameters, `hold`) by chain id.

| Script | Deploys | Touches [`deployments.json`](../deployments.json) | Used for |
|---|---|---|---|
| [`DeployAll.s.sol`](../script/DeployAll.s.sol) | Both implementations, each behind a new proxy, initialized | Writes the new proxy addresses (in a broadcast) | A new network, or a throwaway pair for testing |
| [`DeployImplementation.s.sol`](../script/DeployImplementation.s.sol) | Both implementations only; the SWA one binds to the SRA proxy already recorded | No; the chain is the record once an upgrade is live | Step 3 of an [upgrade](./UPGRADE.md#3-deploy-the-implementations) |

Both verify source on Sourcify when run with `--verify`, and both are dry-run by the [Dry Deployment workflow](../.github/workflows/dry-deploy.yml) on every pull request.

## Two ways to run them

**Through the Deploy Contract workflow** for anything on calibration or mainnet. It runs either script from GitHub Actions with the operations key, inside the network's [environment](https://github.com/filecoin-project/solstice/settings/environments), so a required reviewer approves every live run, the source is verified on Sourcify, and the commit, actor and addresses are recorded in the run summary. It never runs on push or pull request; dispatch it from the Actions tab or with the GitHub CLI, with `--ref` selecting the branch or tag to deploy:

```sh
# Dry run (the default): simulates against the network without sending transactions
gh workflow run deploy-contract.yml --ref main -f network=Calibnet -f target="Implementations only"
# Live
gh workflow run deploy-contract.yml --ref main -f network=Calibnet -f target="Implementations only" -f dry_run=false
```

`target` is `Implementations only` or `Full deployment (implementations and proxies)`. The summary of a full deployment shows the new proxy addresses as a [`deployments.json`](../deployments.json) diff.

**Directly with forge** when you want contracts for local testing, or do not want the workflow. Any funded key works; it pays gas and has no power over the contracts afterwards.

```sh
# Signing key: a keystore account (cast wallet list) ...
export ETH_KEYSTORE_ACCOUNT=<account name>
# ... or, for a throwaway key, pass --private-key 0x... to forge script instead.

# Calibration
export ETH_RPC_URL=https://api.calibration.node.glif.io/rpc/v1
# Mainnet
export ETH_RPC_URL=https://api.node.glif.io/rpc/v1

# Everything: both implementations behind new proxies; records the proxies in deployments.json
forge script script/DeployAll.s.sol --broadcast --verify --rpc-url $ETH_RPC_URL --skip-simulation
# Implementations only, bound to the proxies in deployments.json
forge script script/DeployImplementation.s.sol --broadcast --verify --rpc-url $ETH_RPC_URL --skip-simulation
```

`--skip-simulation` is required on Filecoin: forge's local re-simulation cannot model FEVM gas. For a local chain, fork the network with `anvil --fork-url <rpc>`, point `ETH_RPC_URL` at it and sign with one of anvil's funded keys; the fork keeps the chain id, so the same [`deployments.json`](../deployments.json) entry applies. Drop `--verify` there, and `git checkout deployments.json` afterwards if you ran [`DeployAll.s.sol`](../script/DeployAll.s.sol).

## Deploying on a new network

A new network gets new proxies and new implementations. Every step is a PR or a workflow dispatch.

1. **Config PR.** Add an entry for the chain id to [`deployments.json`](../deployments.json) with the owners, orchestrator, epoch parameters and `hold`, and with `sra` and `swa` present and set to the zero address. Add the network to the `network` choice in [`deploy-contract.yml`](../.github/workflows/deploy-contract.yml) and [`upgrade.yml`](../.github/workflows/upgrade.yml), and to the RPC map in [`deploy-contract.yml`](../.github/workflows/deploy-contract.yml) and [`.github/actions/setup/action.yml`](../.github/actions/setup/action.yml). Merge it.
2. **Environment.** Create a GitHub [environment](https://github.com/filecoin-project/solstice/settings/environments) named after the network with the secret `DEPLOYER_PRIVATE_KEY` (the same key as the other networks, whose address is the [GitHub Actions variable `DEPLOYER_ADDRESS`](https://github.com/filecoin-project/solstice/settings/variables/actions/DEPLOYER_ADDRESS)), required reviewers, and the branch and tag policy of the existing ones.
3. **Dry run, then deploy.** Dispatch the [Deploy Contract workflow](https://github.com/filecoin-project/solstice/actions/workflows/deploy-contract.yml) twice from `main` with target `Full deployment (implementations and proxies)`, first as a dry run, then live. The live run's summary shows the new proxy addresses as a [`deployments.json`](../deployments.json) diff.
4. **Addresses PR.** Open a PR that applies that diff, so `sra` and `swa` for the network are the live proxy addresses. Merge it.
5. **Verify.** Dispatch the [Upgrade workflow](https://github.com/filecoin-project/solstice/actions/workflows/upgrade.yml) with operation `verify` against `main`, or run [`tools/upgrade.py verify`](../tools/upgrade.py) locally. It ends with `ALL CHECKS PASSED` or names the failed check.
