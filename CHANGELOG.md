# Changelog

Each version is one tag and one GitHub release covering both SRA and SWA. The release is created automatically as a pre-release when `version.json` changes on `main` (see `.github/workflows/releaser.yml`) and is promoted to a release when the mainnet upgrade is verified. Put the notes for the next version under its heading before merging the bump.

## v1.0.2

- Mainnet only: moves the SRA activation epoch (`activationEpoch` in `deployments.json`, the `ACTIVATION_EPOCH` immutable and `quarterStart(0)`) from 6450120 (2026-10-12 13:00 UTC) to 6470280 (2026-10-19 13:00 UTC), the first epoch after the nv29 upgrade height 6470279 in [lotus#13874](https://github.com/filecoin-project/lotus/pull/13874), per the [upgrade timing discussion](https://filecoinproject.slack.com/archives/C05P37R9KQD/p1790910918413659). No other change: the calibration build is identical to v1.0.1, and the mainnet SWA build is identical to v1.0.0.

## v1.0.1

- No behavior change. A process test of the upgrade runbook on calibration only ([#85](https://github.com/filecoin-project/solstice/issues/85)); mainnet stays on v1.0.0, so this release stays a pre-release. On calibration the new implementations differ from the live v1.0.0 ones only in the owner Safe addresses built into them, all four of which were replaced on 2026-10-01 and 2026-10-02 ([#88](https://github.com/filecoin-project/solstice/pull/88), [#91](https://github.com/filecoin-project/solstice/pull/91)).

## v1.0.0

- Initial nv29 deployment of ServiceRewardsActor and StreamWeightActor behind ERC-1967 proxies on calibration and mainnet ([#83](https://github.com/filecoin-project/solstice/pull/83)).
