// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {StreamWeightActor} from "../src/StreamWeightActor.sol";
import {IServiceRewardsActor} from "../src/interfaces/IServiceRewardsActor.sol";
import {Epoch} from "../src/lib/Epoch.sol";
import {OwnersLibrary} from "../src/lib/Owners.sol";

/// @notice Flat (non-proxy) StreamWeightActor for tests: seeds the two owners in the
/// constructor instead of leaving them to a proxy `initializeOwners`/`migrate` step.
/// @dev Behaviour is identical to the production actor; only owner bootstrapping differs.
contract FlatStreamWeightActor is StreamWeightActor {
    using OwnersLibrary for address;

    constructor(address owner1, address owner2, IServiceRewardsActor sra, Epoch quarter, Epoch hold)
        StreamWeightActor(sra, quarter, hold)
    {
        owner1.addOwner();
        owner2.addOwner();
    }
}
