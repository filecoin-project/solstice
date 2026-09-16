// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ServiceRewardsActor} from "../src/ServiceRewardsActor.sol";
import {StreamWeightActor} from "../src/StreamWeightActor.sol";
import {Epoch} from "../src/lib/Epoch.sol";
import {UnanimousProxied} from "../src/lib/UnanimousProxied.sol";

contract DeployScript is Script {
    using stdJson for string;

    string internal constant CONFIG_PATH = "deployments.json";

    /// @dev Per-chainId deploy parameters, keyed by decimal chainId (FIP-0118 §3.2 for mainnet, 314).
    struct Config {
        address swaOwner1;
        address swaOwner2;
        address sraOwner1;
        address sraOwner2;
        address initialOrchestrator;
        address initialOrchestratorWallet;
        Epoch epochsPerQuarter;
        Epoch postPeriod;
        Epoch verificationWindow;
        Epoch activationEpoch;
        Epoch hold;
    }

    function initializeProxy(address implementation) internal returns (address proxy) {
        proxy = address(new ERC1967Proxy(implementation, abi.encodeCall(UnanimousProxied.initialize, ())));
    }

    function _readAddress(string memory json, string memory key, string memory field) internal pure returns (address) {
        return json.readAddress(string.concat(key, ".", field));
    }

    error BadEpoch(uint256 epoch);

    function _readEpoch(string memory json, string memory key, string memory field) internal pure returns (Epoch) {
        uint256 value = json.readUint(string.concat(key, ".", field));
        require(value <= type(uint64).max, BadEpoch(value));
        return Epoch.wrap(uint64(value));
    }

    function _loadConfig(string memory json, string memory key) internal pure returns (Config memory config) {
        config = Config({
            swaOwner1: _readAddress(json, key, "swaOwner1"),
            swaOwner2: _readAddress(json, key, "swaOwner2"),
            sraOwner1: _readAddress(json, key, "sraOwner1"),
            sraOwner2: _readAddress(json, key, "sraOwner2"),
            initialOrchestrator: _readAddress(json, key, "initialOrchestrator"),
            initialOrchestratorWallet: _readAddress(json, key, "initialOrchestratorWallet"),
            epochsPerQuarter: _readEpoch(json, key, "epochsPerQuarter"),
            postPeriod: _readEpoch(json, key, "postPeriod"),
            verificationWindow: _readEpoch(json, key, "verificationWindow"),
            activationEpoch: _readEpoch(json, key, "activationEpoch"),
            hold: _readEpoch(json, key, "hold")
        });
    }

    function _writeDeployedAddresses(string memory key, address sra, address swa) internal {
        vm.writeJson(vm.toString(sra), CONFIG_PATH, string.concat(key, ".sra"));
        vm.writeJson(vm.toString(swa), CONFIG_PATH, string.concat(key, ".swa"));
    }

    function run() public returns (address sra, address swa) {
        string memory key = string.concat(".", vm.toString(block.chainid));
        Config memory config = _loadConfig(vm.readFile(CONFIG_PATH), key);

        vm.startBroadcast();

        address sraImplementation = address(
            new ServiceRewardsActor(
                config.sraOwner1,
                config.sraOwner2,
                config.initialOrchestrator,
                config.initialOrchestratorWallet,
                config.epochsPerQuarter,
                config.postPeriod,
                config.verificationWindow,
                config.activationEpoch,
                config.hold
            )
        );
        sra = initializeProxy(sraImplementation);

        address swaImplementation =
            address(new StreamWeightActor(config.swaOwner1, config.swaOwner2, config.hold, ServiceRewardsActor(sra)));
        swa = initializeProxy(swaImplementation);

        vm.stopBroadcast();

        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            _writeDeployedAddresses(key, sra, swa);
        }
    }
}
