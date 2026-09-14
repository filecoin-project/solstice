// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {ServiceRewardsActor} from "../../src/ServiceRewardsActor.sol";
import {Epoch} from "../../src/lib/Epoch.sol";

/// @dev Halmos symbolic-verification harness: inherits ServiceRewardsActor and exposes the internal
///      quarter-window predicates (_inPostingWindow/_inVerificationWindow/_afterBinding) through public
///      wrappers. The wrappers forward to the implementation — no window logic is copied.
///      Constructor parameters match the production config in test/SRATestBase.sol (Q=1000/P=300/V=400/
///      ACTIVATION=100000); the check contract inherits this harness and runs this constructor, so the
///      immutable window constants hold those values during verification.
contract QuarterWindowHarness is ServiceRewardsActor {
    constructor(address owner1, address owner2, uint64 sraUpgradeHold)
        ServiceRewardsActor(
            owner1,
            owner2,
            Epoch.wrap(1000), // epochsPerQuarter
            Epoch.wrap(300), // postPeriod
            Epoch.wrap(400), // verificationWindow
            Epoch.wrap(100_000), // activationEpoch
            Epoch.wrap(sraUpgradeHold)
        )
    {}

    /// @dev posting window [E, E+POST).
    function inPostingWindow(uint64 q) external view returns (bool) {
        return _inPostingWindow(q);
    }

    /// @dev verification window [E+POST, E+POST+VERIFY).
    function inVerificationWindow(uint64 q) external view returns (bool) {
        return _inVerificationWindow(q);
    }

    /// @dev post-binding: now >= E+POST+VERIFY.
    function afterBinding(uint64 q) external view returns (bool) {
        return _afterBinding(q);
    }
}
