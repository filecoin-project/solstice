// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

contract CallProxy {
    address immutable RECIPIENT;

    constructor(address recipient) payable {
        RECIPIENT = recipient;
    }

    fallback() external payable {
        address recipient = RECIPIENT;
        assembly ("memory-safe") {
            calldatacopy(0, 0, calldatasize())
            let success := call(gas(), recipient, callvalue(), 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(success) {
                revert(0, returndatasize())
            }
            return(0, returndatasize())
        }
    }
}
