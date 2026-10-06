// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {console} from "forge-std/console.sol";

import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import {ServiceRewardsActor} from "../src/ServiceRewardsActor.sol";
import {Epoch} from "../src/lib/Epoch.sol";
import {OwnersLibrary} from "../src/lib/Owners.sol";
import {UnanimousGovernance} from "../src/lib/UnanimousGovernance.sol";
import {UpgradeBase} from "./UpgradeBase.sol";

/// @notice Rehearses the SRA and SWA upgrade in a local fork of the target network. Sends nothing.
/// @dev Usage:
///
///        forge script script/Rehearse.s.sol --rpc-url $ETH_RPC_URL
///
///      Both implementations are built from the checked-out source inside the fork (the rehearsal runs before any
///      implementation is deployed). For each contract, both owner Safes are impersonated to submit and approve,
///      early execution is shown to revert with HoldUntil, the hold is rolled past, and the upgrade executes; the
///      proxy's implementation slot is then required to point at the new implementation.
///
///      After both upgrades, checks against the live state that unit tests (fresh deployments, synthetic state) cannot
///      make: on each proxy a non-owner cannot submit while both owners can still submit and approve a task (a
///      rollback to the previous implementation, left pending in the fork), since an upgrade that broke owner
///      recognition could never be upgraded or rolled back again; and the SRA's Orchestrator registry is unchanged.
///      It also prints the SRA's activation epoch before and after, for the reviewer to compare with the network
///      upgrade date, and requires it to match `deployments.json`.
contract RehearseScript is UpgradeBase {
    /// @dev SRA registry readings that an upgrade must not change.
    struct SraSnapshot {
        uint64 orchestratorCount;
        uint64 admittedCount;
        bool initialOrchestratorAdmitted;
        uint64 activationEpoch;
    }

    function run() public returns (address sra, address swa) {
        string memory key = _configKey();
        string memory json = vm.readFile(CONFIG_PATH);
        Config memory config = _loadConfig(json, key);
        sra = _readAddress(json, key, "sra");
        swa = _readAddress(json, key, "swa");
        _rehearseAndCheck(config, sra, swa);

        console.log("");
        console.log("REHEARSAL COMPLETE");
    }

    function _rehearseAndCheck(Config memory config, address sra, address swa) internal {
        address oldSraImpl = _implementationOf(sra);
        address oldSwaImpl = _implementationOf(swa);
        SraSnapshot memory before = _sraSnapshot(sra, config);

        _rehearse("SRA", sra, config.sraOwner1, config.sraOwner2, config.hold, _buildImplementation(true, config, sra));
        _rehearse("SWA", swa, config.swaOwner1, config.swaOwner2, config.hold, _buildImplementation(false, config, sra));

        console.log("");
        _checkSraSchedule(sra, config, before);
        _checkSraRegistry(sra, config, before);
        _checkGovernance("SRA", sra, config.sraOwner1, config.sraOwner2, oldSraImpl);
        _checkGovernance("SWA", swa, config.swaOwner1, config.swaOwner2, oldSwaImpl);
    }

    function _rehearse(string memory name, address proxy, address owner1, address owner2, Epoch hold, address impl)
        internal
    {
        console.log(string.concat("[", name, "] built implementation in the fork"), impl);
        bytes memory upgradeCall = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (impl, ""));
        console.log(string.concat("[", name, "] governance task id"), vm.toString(keccak256(upgradeCall)));

        vm.prank(owner1);
        _call(proxy, upgradeCall, string.concat("[", name, "] owner 1 submit"));
        vm.prank(owner2);
        _call(proxy, upgradeCall, string.concat("[", name, "] owner 2 approve"));

        (bool ok, bytes memory ret) = proxy.call(upgradeCall);
        require(
            !ok && bytes4(ret) == UnanimousGovernance.HoldUntil.selector,
            string.concat(name, ": early execution did not revert with HoldUntil")
        );
        console.log(string.concat("[", name, "] early execution reverted with HoldUntil, as required"));

        vm.roll(block.number + Epoch.unwrap(hold));
        _call(proxy, upgradeCall, string.concat("[", name, "] execute after hold"));
        require(_implementationOf(proxy) == impl, string.concat(name, ": implementation slot did not change"));
        console.log(string.concat("[", name, "] implementation slot now"), impl);
    }

    function _sraSnapshot(address sra, Config memory config) internal view returns (SraSnapshot memory) {
        ServiceRewardsActor actor = ServiceRewardsActor(sra);
        return SraSnapshot({
            orchestratorCount: actor.orchestratorCount(),
            admittedCount: actor.admittedCount(),
            initialOrchestratorAdmitted: actor.isAdmitted(config.initialOrchestrator),
            activationEpoch: Epoch.unwrap(actor.quarterStart(0))
        });
    }

    function _checkSraSchedule(address sra, Config memory config, SraSnapshot memory before) internal view {
        ServiceRewardsActor actor = ServiceRewardsActor(sra);
        uint64 start0 = Epoch.unwrap(actor.quarterStart(0));
        require(start0 == Epoch.unwrap(config.activationEpoch), "SRA: quarterStart(0) is not activationEpoch");
        require(
            Epoch.unwrap(actor.quarterStart(1)) - start0 == Epoch.unwrap(config.epochsPerQuarter),
            "SRA: quarter length is not epochsPerQuarter"
        );
        console.log("[SRA] activation epoch (quarterStart(0)) before upgrade", before.activationEpoch);
        console.log("[SRA] activation epoch (quarterStart(0)) after upgrade ", start0);
    }

    function _checkSraRegistry(address sra, Config memory config, SraSnapshot memory before) internal view {
        SraSnapshot memory afterUpgrade = _sraSnapshot(sra, config);
        require(afterUpgrade.orchestratorCount == before.orchestratorCount, "SRA: orchestratorCount changed");
        require(afterUpgrade.admittedCount == before.admittedCount, "SRA: admittedCount changed");
        require(
            afterUpgrade.initialOrchestratorAdmitted == before.initialOrchestratorAdmitted,
            "SRA: initial Orchestrator admission changed"
        );
        console.log("[SRA] registry unchanged: orchestratorCount", before.orchestratorCount);
        console.log("[SRA] registry unchanged: admittedCount", before.admittedCount);
    }

    function _checkGovernance(string memory name, address proxy, address owner1, address owner2, address oldImpl)
        internal
    {
        bytes memory rollbackCall = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (oldImpl, ""));
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        (bool ok, bytes memory ret) = proxy.call(rollbackCall);
        require(
            !ok && bytes4(ret) == OwnersLibrary.NotOwner.selector,
            string.concat(name, ": non-owner submit did not revert with NotOwner")
        );
        console.log(string.concat("[", name, "] non-owner submit reverted with NotOwner, as required"));
        vm.prank(owner1);
        _call(proxy, rollbackCall, string.concat("[", name, "] owner 1 can still submit"));
        vm.prank(owner2);
        _call(proxy, rollbackCall, string.concat("[", name, "] owner 2 can still approve"));
    }

    function _call(address target, bytes memory callData, string memory label) internal {
        (bool ok, bytes memory ret) = target.call(callData);
        require(ok, string.concat(label, " failed: ", vm.toString(ret)));
        console.log(string.concat(label, ": ok"));
    }
}
