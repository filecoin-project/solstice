// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {Bootstrap} from "erc8167/interfaces/Bootstrap.sol";
import {IERC8167} from "erc8167/interfaces/IERC8167.sol";
import {Implementation} from "erc8167/interfaces/Implementation.sol";
import {Test} from "forge-std/Test.sol";
import {Epoch} from "../src/lib/Epoch.sol";
import {InitializableOwners} from "../src/lib/InitializableOwners.sol";
import {Migratable} from "../src/lib/Migratable.sol";
import {UnanimousGovernance} from "../src/lib/UnanimousGovernance.sol";

contract MigrationTest is Test {
    uint256 private constant HOLD = 5;
    Epoch private constant HOLD_EPOCHS = Epoch.wrap(5);
    Migratable proxy;

    address owner1;
    address owner2;

    function deployProxy() internal returns (address proxyAddress) {
        proxyAddress = deployCode("lib/erc8167/out/Proxy.constructor.evm/Proxy.constructor.json");
    }

    function setUp() public {
        owner1 = makeAddr("owner1");
        owner2 = makeAddr("owner2");
        address proxyAddress = deployProxy();

        address implementationMethod = makeAddr("implementation");
        vm.etch(implementationMethod, vm.getDeployedCode("lib/erc8167/out/Implementation.evm/Implementation.json"));
        Bootstrap(proxyAddress).configure(Implementation.implementation.selector, implementationMethod);

        Bootstrap(proxyAddress).configure(InitializableOwners.initializeOwners.selector, address(new InitializableOwners(owner1, owner2)));
        InitializableOwners(proxyAddress).initializeOwners();
        Bootstrap(proxyAddress).configure(Migratable.migrate.selector, address(new Migratable(HOLD_EPOCHS)));
        proxy = Migratable(proxyAddress);
    }

    function getBootstrapImplementation() internal view returns (address) {
        return IERC8167(address(proxy)).implementation(Bootstrap.configure.selector);
    }

    function testMigrate() public {
        // create a simple migration that uninstalls Bootstrap.configure
        address migration = makeAddr("migration");
        bytes memory migrationCode = hex"5f7f9e5badb7e9e4be042cb44f289e6b2cacbaa8f93a016a25bbfbda16d82de4943555";
        vm.etch(migration, migrationCode);

        address before = getBootstrapImplementation();
        assertNotEq(before, address(0));

        vm.prank(owner1);
        proxy.migrate(migration);
        vm.prank(owner2);
        proxy.migrate(migration);

        // migration is on-hold and not yet executed
        assertEq(getBootstrapImplementation(), before);

        vm.roll(vm.getBlockNumber() + HOLD - 1);

        vm.expectRevert(abi.encodeWithSelector(UnanimousGovernance.HoldUntil.selector, vm.getBlockNumber() + 1));
        proxy.migrate(migration);

        vm.roll(vm.getBlockNumber() + 1);

        // now permissionless
        proxy.migrate(migration);

        // Bootstrap.configure was uninstalled
        assertEq(getBootstrapImplementation(), address(0));

        vm.expectRevert(abi.encodeWithSelector(UnanimousGovernance.NotOwner.selector, address(this)));
        proxy.migrate(migration);
    }
}
