// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import {Epoch} from "./Epoch.sol";
import {UnanimousGovernance} from "./UnanimousGovernance.sol";
import {OwnersLibrary} from "./Owners.sol";

contract UnanimousProxied is Initializable, UnanimousGovernance, UUPSUpgradeable {
    using OwnersLibrary for address;

    address private immutable INITIAL_OWNER1;
    address private immutable INITIAL_OWNER2;
    Epoch internal immutable HOLD;

    event OwnerReplaced(address indexed prevOwner, address indexed newOwner);

    constructor(address owner1, address owner2, Epoch hold) {
        _disableInitializers();
        INITIAL_OWNER1 = owner1;
        INITIAL_OWNER2 = owner2;
        HOLD = hold;
    }

    function initialize() public virtual initializer {
        INITIAL_OWNER1.addOwner();
        INITIAL_OWNER2.addOwner();
    }

    /// @notice Replaces one of the two owners.
    /// @param prevOwner Owner being removed.
    /// @param newOwner Owner being added.
    function replaceOwner(address prevOwner, address newOwner) external unanimousNoHold(keccak256(msg.data)) {
        prevOwner.removeOwner();
        newOwner.addOwner();
        emit OwnerReplaced(prevOwner, newOwner);
    }

    error NonzeroCallValue();

    /// @dev Solidity doesn't let you override a payable method as nonpayable.
    ///      This is a modifier so that it can be applied before `unanimous`
    modifier nonpayablePayable() {
        require(msg.value == 0, NonzeroCallValue());
        _;
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        nonpayablePayable
        unanimous(keccak256(msg.data), HOLD)
    {}

    /// @notice An owner cancels a pending unanimous task before it executes.
    /// @param taskId The pending task's identifier, usually keccak256(msg.data) of its submission.
    function veto(bytes32 taskId) external {
        _veto(taskId);
    }
}
