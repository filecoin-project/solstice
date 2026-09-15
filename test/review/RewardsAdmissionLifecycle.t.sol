// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {SRATestBase} from "../SRATestBase.sol";
import {FixedU18} from "../../src/lib/FixedU18.sol";
import {SERVICE_ID, Share} from "../../src/lib/FVMRewardTypes.sol";

contract RewardsAdmissionLifecycleReview is SRATestBase {
    function test_NewAdmissionCanPostForAlreadyEndedQuarter() public {
        address orch = makeAddr("late-admission-orch");
        address wallet = _wallet("late-admission-wallet");

        vm.roll(_quarterStart(0) + 1);
        _admit(orch, wallet);
        _postAs(orch, 0, 100e18);

        vm.roll(_bindingStart(0));
        sra.submitShares(0);

        Share[] memory shares = rewardActor().getShares(SERVICE_ID);
        assertEq(shares.length, 1);
        assertEq(shares[0].wallet, wallet);
        assertEq(FixedU18.unwrap(shares[0].share), 1e18);
    }

    function test_RegistryOwnersCanReplaceWalletWithoutOrchestratorSignature() public {
        address orch = makeAddr("unsigned-replace-orch");
        address oldWallet = _wallet("unsigned-replace-old");
        address newWallet = _wallet("unsigned-replace-new");
        _admit(orch, oldWallet);

        vm.roll(_quarterStart(0) + 1);
        _postAs(orch, 0, 100e18);
        vm.roll(_bindingStart(0));
        sra.submitShares(0);

        vm.prank(owner1);
        sra.replaceWallet(orch, newWallet);
        vm.prank(owner2);
        sra.replaceWallet(orch, newWallet);

        Share[] memory shares = rewardActor().getShares(SERVICE_ID);
        assertEq(shares.length, 1);
        assertEq(shares[0].wallet, newWallet);
        assertEq(FixedU18.unwrap(shares[0].share), 1e18);
    }
}
