# solstice
Supporting contracts and tools for https://github.com/filecoin-project/FIPs/discussions/1249

## Deployment
[docs/DEPLOYMENT.md](docs/DEPLOYMENT.md): the live proxy addresses, the two deploy scripts (everything, or implementations only) and how to run them locally or through the [Deploy Contract workflow](.github/workflows/deploy-contract.yml), and bringing up a new network.

## Upgrades
[docs/UPGRADE.md](docs/UPGRADE.md): the runbook for replacing the implementation behind the live proxies, step by step through the [Upgrade workflow](.github/workflows/upgrade.yml), built on these tools, in the order they are used:

* [`tools/storage_layout.py`](tools/storage_layout.py) with [`test/layout/StorageLayoutProbe.sol`](test/layout/StorageLayoutProbe.sol) and [`test/StorageSlots.t.sol`](test/StorageSlots.t.sol): CI gate for ERC-7201 namespaced storage; fails non-append-only changes and pins slot constants.
* Version bumps in [`version.json`](version.json) with notes in [`CHANGELOG.md`](CHANGELOG.md); the [Releaser workflow](.github/workflows/releaser.yml) tags and pre-releases them.
* [`tools/upgrade.py`](tools/upgrade.py), run with `uv run`: every upgrade operation as one command; drives the forge scripts below and uses [safe-eth-py](https://github.com/safe-global/safe-eth-py) for the [Safe](https://safe.filecoin.io) proposals.
* [`script/Rehearse.s.sol`](script/Rehearse.s.sol): full upgrade of both contracts in a local fork (impersonated owners, hold, execute).
* [Deploy Contract workflow](.github/workflows/deploy-contract.yml) (see [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md)).
* [`script/Verify.s.sol`](script/Verify.s.sol): read-only check that the live proxies and implementations match the checked-out source and [`deployments.json`](deployments.json); with candidate addresses given, checks those before they are proposed. [`script/UpgradeBase.sol`](script/UpgradeBase.sol) holds what the two scripts share.

## Workflows
[`tools/lint_workflows.py`](tools/lint_workflows.py), run with `uv run --locked tools/lint_workflows.py`: lints `.github/workflows` with [actionlint](https://github.com/rhysd/actionlint), which also runs shellcheck on every `run:` script. The [Linter workflow](.github/workflows/lint.yml) runs the same command on every PR.
