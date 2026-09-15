// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {SRATestBase} from "../../test/SRATestBase.sol";
import {FixedU18} from "../../src/lib/FixedU18.sol";
import {SERVICE_ID, Share} from "../../src/lib/FVMRewardTypes.sol";

/// Retained evidence for the external-spec quarter origin reviewed in appendlog Entries 016 and 035.
/// The repository uses zero-based internal q, but accepted and pending FIP timelines have no report at activation.
/// Run:
/// forge test --contracts review/reproducers --match-contract QuarterZeroAdmissionReproducer -vvv
contract QuarterZeroAdmissionReproducer is SRATestBase {
    function test_ExternalOneBasedQuarterModelWouldRejectQuarterZero() public {
        address orchestrator = makeAddr("quarter-zero-orchestrator");
        _admit(orchestrator, orchestrator);
        vm.roll(_quarterStart(0));

        vm.prank(orchestrator);
        vm.expectRevert();
        sra.postVolume(0, FixedU18.wrap(1e18));
    }

    function test_QuarterZeroMustNotOverwriteMigrationShareMap() public {
        address orchestrator = makeAddr("quarter-zero-map-orchestrator");
        _admit(orchestrator, orchestrator);
        vm.roll(_quarterStart(0));
        vm.prank(orchestrator);
        sra.postVolume(0, FixedU18.wrap(1e18));

        vm.roll(_bindingStart(0));
        sra.submitShares(0);

        Share[] memory shares = rewardActor().getShares(SERVICE_ID);
        assertEq(shares.length, 1);
        assertEq(shares[0].wallet, address(sra), "q0 overwrote the migration-installed initial map");
    }
}
