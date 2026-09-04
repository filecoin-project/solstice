// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {Bootstrap} from "erc8167/interfaces/Bootstrap.sol";
import {Migration, SetDelegateOperation} from "erc8167/lib/Migration.sol";
import {Script} from "forge-std/Script.sol";
import {IDeployer} from "ReservedAddress/interfaces/IDeployer.sol";

import {ServiceRewardsActor} from "../src/ServiceRewardsActor.sol";
import {IServiceRewardsActor} from "../src/interfaces/IServiceRewardsActor.sol";
import {StreamWeightActor} from "../src/StreamWeightActor.sol";
import {Epoch} from "../src/lib/Epoch.sol";
import {InitializableGateParams} from "../src/lib/GateParams.sol";
import {InitializableOwners} from "../src/lib/InitializableOwners.sol";
import {Migratable} from "../src/lib/Migratable.sol";

contract DeployScript is Script {
    using Migration for SetDelegateOperation[];

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

    function createSraMigration(
        address,
        /*streamWeightActor*/
        address,
        /*sraOwners*/
        address,
        /*implementationMethod*/
        address /*migrateMethod*/
    )
        internal
        returns (address migration)
    {
        // TODO
        SetDelegateOperation[] memory operations = new SetDelegateOperation[](0);
        return operations.createMigration();
    }

    function createSwaMigration(
        address,
        /*serviceRewardsActor*/
        address,
        /*swaOwners*/
        address,
        /*implementationMethod*/
        address,
        /*migrateMethod*/
        address /*initializeGateParamsMethod*/
    )
        internal
        returns (address migration)
    {
        // TODO
        SetDelegateOperation[] memory operations = new SetDelegateOperation[](0);
        return operations.createMigration();
    }

    function run(
        Epoch epochsToHold,
        Epoch epochsPerQuarter,
        Epoch postPeriod,
        Epoch verificationWindow,
        Epoch activationEpoch,
        uint256 minLot,
        uint256 priceBand
    ) public {
        vm.deal(ROOT_DEPLOYER, 0.2 ether);

        vm.startBroadcast();

        vm.broadcastRawTransaction(getDeployRootTx());

        ROOT.reserve(SRA);
        ROOT.reserve(SWA);

        ROOT.reveal(SRA, SRA_SALT);
        ROOT.reveal(SWA, SWA_SALT);

        {
            address proxyDeployer = create(
                bytes.concat(
                    UNIVERSAL_CONSTRUCTOR, vm.getCode("lib/erc8167/out/Proxy.constructor.evm/Proxy.constructor.json")
                )
            );

            ROOT.deploy(SRA, proxyDeployer);
            ROOT.deploy(SWA, proxyDeployer);
        }

        {
            bytes32 proxyCodeHash = keccak256(vm.getDeployedCode("lib/erc8167/out/Proxy.evm/Proxy.json"));
            require(SRA.codehash == proxyCodeHash);
            require(SWA.codehash == proxyCodeHash);
        }

        {
            address bootstrapMigrateMethod =
                create(vm.getCode("lib/erc8167/out/Migrate.constructor.evm/Migrate.constructor.evm"));
            ROOT.call(
                SRA,
                abi.encodeWithSelector(
                    Bootstrap.configure.selector, Migratable.migrate.selector, bootstrapMigrateMethod
                )
            );
            ROOT.call(
                SWA,
                abi.encodeWithSelector(
                    Bootstrap.configure.selector, Migratable.migrate.selector, bootstrapMigrateMethod
                )
            );
        }

        // deploy facets
        address implementationMethod = create(vm.getCode("lib/erc8167/out/Implementation.evm/Implementation.json"));
        address sraOwners = address(new InitializableOwners(SRA_OWNER1, SRA_OWNER2));
        address swaOwners = address(new InitializableOwners(SWA_OWNER1, SWA_OWNER2));
        address streamWeightActor =
            address(new StreamWeightActor(IServiceRewardsActor(SRA), epochsPerQuarter, epochsToHold));
        address serviceRewardsActor = address(
            new ServiceRewardsActor(
                epochsPerQuarter, postPeriod, verificationWindow, epochsToHold, activationEpoch, minLot, priceBand
            )
        );
        address migrateMethod = address(new Migratable(epochsToHold)); // overwrites bootstrapping migrate method
        address initializeGateParamsMethod = address(new InitializableGateParams());

        // TODO deploy migration
        address sraMigration = createSraMigration(streamWeightActor, sraOwners, implementationMethod, migrateMethod);
        address swaMigration = createSwaMigration(
            serviceRewardsActor, swaOwners, implementationMethod, migrateMethod, initializeGateParamsMethod
        );

        // run migration
        Migratable(SRA).migrate(sraMigration);
        Migratable(SWA).migrate(swaMigration);

        InitializableOwners(SRA).initializeOwners();
        InitializableOwners(SWA).initializeOwners();
        InitializableGateParams(SWA).initializeGateParams();
        vm.stopBroadcast();
    }
}
