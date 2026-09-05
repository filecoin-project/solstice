// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {Epoch} from "./Epoch.sol";
import {UnanimousGovernance} from "./UnanimousGovernance.sol";

contract Migratable is UnanimousGovernance {
    Epoch private immutable HOLD;

    constructor(Epoch hold) {
        HOLD = hold;
    }

    function migrate(address migration) external unanimous(keccak256(msg.data), HOLD) {
        assembly ("memory-safe") {
            if delegatecall(gas(), migration, 0, 0, 0, 0) {
                returndatacopy(0, 0, returndatasize())
                return(0, returndatasize())
            }
            returndatacopy(0, 0, returndatasize())
            revert(0, returndatasize())
        }
    }
}
