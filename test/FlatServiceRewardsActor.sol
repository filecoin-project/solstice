// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {ServiceRewardsActor} from "../src/ServiceRewardsActor.sol";
import {Epoch} from "../src/lib/Epoch.sol";
import {OwnersLibrary} from "../src/lib/Owners.sol";

/// @notice Flat (non-proxy) ServiceRewardsActor for tests: seeds the two owners in the
/// constructor instead of leaving them to a proxy `initializeOwners`/`migrate` step.
/// @dev Behaviour is identical to the production actor; only owner bootstrapping differs.
contract FlatServiceRewardsActor is ServiceRewardsActor {
    using OwnersLibrary for address;

    constructor(
        address owner1,
        address owner2,
        Epoch epochsPerQuarter,
        Epoch postPeriod,
        Epoch verificationWindow,
        Epoch cancelHold,
        Epoch activationEpoch,
        uint256 minLot,
        uint256 priceBand
    )
        ServiceRewardsActor(
            epochsPerQuarter, postPeriod, verificationWindow, cancelHold, activationEpoch, minLot, priceBand
        )
    {
        owner1.addOwner();
        owner2.addOwner();
    }
}
