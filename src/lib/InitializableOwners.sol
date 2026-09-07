// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {SelfUninstalling} from "erc8167/lib/SelfUninstalling.sol";
import {OwnersLibrary} from "./Owners.sol";
import {UnanimousGovernance} from "./UnanimousGovernance.sol";

contract InitializableOwners is UnanimousGovernance, SelfUninstalling {
    using OwnersLibrary for address;

    address private immutable OWNER1;
    address private immutable OWNER2;

    constructor(address owner1, address owner2) {
        OWNER1 = owner1;
        OWNER2 = owner2;
    }

    function initializeOwners() external selfUninstalling {
        OWNER1.addOwner();
        OWNER2.addOwner();
    }
}
