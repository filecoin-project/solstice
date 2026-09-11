// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

// Overflow DoS regression (V3): a huge FilecoinPayVolume USD total would overflow _computeShares
// and wedge quarterly settlement — the FilecoinPayVolume inputs had no business-domain
// upper-bound validation. The fix is the MAX_FILECOIN_PAY_VOLUME_USD bound enforced at
// postVolume/correctVolume: a total beyond it is rejected at the entry, and a normal total lets
// submitShares settle (system stays operational).

import {SERVICE_ID, Share} from "../src/lib/FVMRewardTypes.sol";
import {SRATestBase} from "./SRATestBase.sol";
import {FixedU18} from "../src/lib/FixedU18.sol";

contract SRAOverflowDoS is SRATestBase {
    uint256 private constant EXTREME = type(uint256).max; // V3: poison USD total

    // ------------------------------------------------------------------------
    // V3 — huge USD total → _computeShares overflow → quarterly settlement stuck
    // ------------------------------------------------------------------------

    /// V3 regression (operational): a huge USD total must not wedge submitShares;
    /// the quarter must still settle.
    function test_V3_HugeUsd_SystemStaysOperational() public {
        address attacker = makeAddr("v3-attacker");
        address victim = makeAddr("v3-victim");
        _admit(attacker, attacker);
        _admit(victim, victim);

        vm.roll(_quarterStart(0) + 1);
        vm.prank(attacker);
        try sra.postVolume(0, FixedU18.wrap(EXTREME)) {} catch {}

        vm.prank(victim);
        sra.postVolume(0, FixedU18.wrap(100e18));

        vm.roll(_bindingStart(0) + 1);
        sra.submitShares(0); // must not overflow

        Share[] memory shares = rewardActor().getShares(SERVICE_ID);
        assertEq(_sumShares(shares), 1e18);
    }

    /// V3 regression (reject-at-post): the huge total must be rejected by postVolume
    /// (expected fix: business-domain upper bound MAX_FILECOIN_PAY_VOLUME_USD on the single USD total).
    function test_V3_HugeUsd_RejectedByPostVolume() public {
        address attacker = makeAddr("v3-reject");
        _admit(attacker, attacker);

        vm.roll(_quarterStart(0) + 1);
        vm.prank(attacker);
        vm.expectRevert();
        sra.postVolume(0, FixedU18.wrap(EXTREME));
    }

    // ------------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------------

    function _sumShares(Share[] memory shares) internal pure returns (uint256 sum) {
        for (uint256 i = 0; i < shares.length; i++) {
            sum += FixedU18.unwrap(shares[i].share);
        }
    }
}
