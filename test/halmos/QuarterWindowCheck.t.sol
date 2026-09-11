// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {Test} from "forge-std/Test.sol";
import {Epoch} from "../../src/lib/Epoch.sol";
import {QuarterWindowHarness} from "./QuarterWindowHarness.sol";

/// @dev Halmos symbolic verification of the quarter state-machine window determination.
///      The constructor runs (no --no-test-constructor), so the immutable window constants hold the
///      harness config (Q=1000/P=300/V=400/ACTIVATION=100000) and vm.roll pins currentEpoch()
///      (= block.number) to a concrete epoch.
contract QuarterWindowCheck is QuarterWindowHarness, Test {
    // forge-lint: disable-start(mixed-case-function) — halmos runs only check_-prefixed property functions (tool convention)
    /// @dev owner params arbitrary (halmos executes with --no-test-constructor, skipping the constructor; the compiler layer still needs explicit args).
    constructor() QuarterWindowHarness(address(0xCAFE), address(0xBEEF)) {}

    /// @dev owner params arbitrary; the window parameters come from the harness config.
    constructor() QuarterWindowHarness(address(0xCAFE), address(0xBEEF), 20160) {}

    // ------------------------------------------------------------------------
    // T2: posting window [E, E+POST), E = quarterStart(q) — E is the left edge, included
    // ------------------------------------------------------------------------

    /// @dev T2a: quarterStart(q) opens quarter q's posting window: rolling to quarterStart(q) puts the
    ///      state machine inside the posting window.
    function check_T2a_PostingLeftEdge_Included(uint64 q) public {
        vm.assume(q <= 3);
        vm.roll(Epoch.unwrap(_quarterStart(q)));
        assert(this.inPostingWindow(q));
    }

    // ------------------------------------------------------------------------
    // T3: constant quarter-progression interval (arithmetic correctness + cross-quarter continuity)
    // ------------------------------------------------------------------------

    /// @dev T3: any consecutive quarter interval is constant: quarterStart(q+1) - quarterStart(q) == quarterStart(1) - quarterStart(0).
    ///      I.e. quarter progression is equidistant — the gap is always EPOCHS_PER_QUARTER, so no quarter
    ///      boundary overlaps the next or leaves a hole between them.
    function check_T3_QuarterProgression(uint64 q) public view {
        vm.assume(q <= 3);
        uint256 gap = Epoch.unwrap(_quarterStart(q + 1)) - Epoch.unwrap(_quarterStart(q));
        uint256 gap0 = Epoch.unwrap(_quarterStart(1)) - Epoch.unwrap(_quarterStart(0));
        assert(gap == gap0);
    }

    // forge-lint: disable-end(mixed-case-function)
}
