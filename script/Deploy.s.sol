// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {Script} from "forge-std/Script.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/erc1967/ERC1967Proxy.sol";

import {ServiceRewardsActor} from "../src/ServiceRewardsActor.sol";
import {StreamWeightActor} from "../src/StreamWeightActor.sol";
import {Epoch} from "../src/lib/Epoch.sol";
import {UnanimousProxy} from "../src/lib/UnanimousProxy.sol";

contract DeployScript is Script {
    function initializeProxy(address implementation) internal returns (address proxy) {
        proxy = address(new ERC1967Proxy(implementation, abi.encodeCall(UnanimousProxy.initialize, ())));
    }

    function run(
        address swaOwner1,
        address swaOwner2,
        address sraOwner1,
        address sraOwner2,
        Epoch epochsPerQuarter,
        Epoch postPeriod,
        Epoch verificationWindow,
        Epoch activationEpoch,
        Epoch hold
    ) public returns (address sra, address swa) {
        address sraImplementation = address(
            new ServiceRewardsActor(
                sraOwner1, sraOwner2, epochsPerQuarter, postPeriod, verificationWindow, activationEpoch, hold
            )
        );

        sra = initializeProxy(sraImplementation);

        address swaImplementation = address(new StreamWeightActor(swaOwner1, swaOwner2, hold, ServiceRewardsActor(sra)));

        swa = initializeProxy(swaImplementation);
    }
}
