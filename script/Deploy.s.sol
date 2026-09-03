// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {Bootstrap} from "erc8167/interfaces/Bootstrap.sol";
import {Implementation} from "erc8167/interfaces/Implementation.sol";
import {Script} from "forge-std/Script.sol";
import {IDeployer} from "ReservedAddress/interfaces/IDeployer.sol";

import {Epoch} from "../src/lib/Epoch.sol";
import {InitializableOwners} from "../src/lib/InitializableOwners.sol";
import {Migratable} from "../src/lib/Migratable.sol";

contract DeployScript is Script {
    address constant ROOT_DEPLOYER = 0x3ef96E9f82CaFE4a05183b59e7671E39B6b26347;
    IDeployer constant ROOT = IDeployer(0x000000000000c57CF0A1f923d44527e703F1ad70);
    address constant SRA = 0x888808e3e6888E8988E8178864cA861d8882e88A;
    address constant SWA = 0x88802aa46868868584802848988888C882888BE3;

    bytes32 constant SRA_SALT = 0xeda7621f46ea790599a2898fad7fa8cf5bfd6713aa5eb107927590511004cfc0;
    bytes32 constant SWA_SALT = 0xeda7621e46ea7987763f89877b74a9cf5bfd6713aa5eb107927590511004cfc0;

    bytes constant UNIVERSAL_CONSTRUCTOR = hex"600b380380600b3d393df3";

    address constant SRA_OWNER1 = 0x8B7F1c94c396C2051D97AFF974187A5640136759;
    address constant SRA_OWNER2 = 0xFb1B58925947E52B3f75BAc3D9fB5325cfb36371;
    address constant SWA_OWNER1 = 0x591FfA9476A038114000166523486948D3a63E57;
    address constant SWA_OWNER2 = 0x024a3c8CCA435db64D2dfa0f903E4823A5eBdf63;

    function getDeployRootTx() internal view returns (bytes memory rawTx) {
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory json = vm.readFile("lib/ReservedAddress/deploy.json");
        rawTx = vm.parseJsonBytes(json, ".params[0]");
    }

    function create(bytes memory initcode) internal returns (address account) {
        assembly ("memory-safe") {
            account := create(0, add(32, initcode), mload(initcode))
        }
        require(account.code.length != 0);
    }

    function run(Epoch hold) public {
        vm.deal(ROOT_DEPLOYER, 0.2 ether);

        vm.startBroadcast();

        vm.broadcastRawTransaction(getDeployRootTx());

        ROOT.reserve(SRA);
        ROOT.reserve(SWA);

        ROOT.reveal(SRA, SRA_SALT);
        ROOT.reveal(SWA, SWA_SALT);

        address proxyDeployer = create(bytes.concat(
            UNIVERSAL_CONSTRUCTOR,
            vm.getCode("lib/erc8167/out/Proxy.constructor.evm/Proxy.constructor.json")
        ));

        ROOT.deploy(SRA, proxyDeployer);
        ROOT.deploy(SWA, proxyDeployer);

        bytes32 proxyCodeHash = keccak256(vm.getDeployedCode("lib/erc8167/out/Proxy.evm/Proxy.json"));
        require(SRA.codehash == proxyCodeHash);
        require(SWA.codehash == proxyCodeHash);

        address implementationMethod = create(vm.getCode("lib/erc8167/out/Implementation.evm/Implementation.json"));
        ROOT.call(SRA, abi.encodeWithSelector(Bootstrap.configure.selector, Implementation.implementation.selector, implementationMethod));
        ROOT.call(SWA, abi.encodeWithSelector(Bootstrap.configure.selector, Implementation.implementation.selector, implementationMethod));
        require(Implementation(SRA).implementation(Implementation.implementation.selector) == implementationMethod);
        require(Implementation(SWA).implementation(Implementation.implementation.selector) == implementationMethod);

        InitializableOwners sraOwners = new InitializableOwners(SRA_OWNER1, SRA_OWNER2);
        InitializableOwners swaOwners = new InitializableOwners(SWA_OWNER1, SWA_OWNER2);
        ROOT.call(SRA, abi.encodeWithSelector(Bootstrap.configure.selector, InitializableOwners.initializeOwners.selector, sraOwners));
        ROOT.call(SWA, abi.encodeWithSelector(Bootstrap.configure.selector, InitializableOwners.initializeOwners.selector, swaOwners));

        InitializableOwners(SRA).initializeOwners();
        InitializableOwners(SWA).initializeOwners();

        Migratable migratableImpl = new Migratable(hold);
        ROOT.call(SRA, abi.encodeWithSelector(Bootstrap.configure.selector, Migratable.migrate.selector, migratableImpl));
        ROOT.call(SWA, abi.encodeWithSelector(Bootstrap.configure.selector, Migratable.migrate.selector, migratableImpl));

        // TODO deploy migration

        vm.stopBroadcast();

        // TODO run migration as owners
    }
}
