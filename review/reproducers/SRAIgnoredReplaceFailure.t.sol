// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {CALL_ACTOR_BY_ID} from "fvm-solidity/FVMPrecompiles.sol";

import {SRATestBase} from "../../test/SRATestBase.sol";
import {FVMRewards} from "../../src/lib/FVMRewards.sol";
import {FixedU18} from "../../src/lib/FixedU18.sol";
import {SERVICE_ID, Share} from "../../src/lib/FVMRewardTypes.sol";

/// Minimal production-code reproducer for review appendlog Entry 002.
/// Run:
/// forge test --contracts review/reproducers --match-contract SRAIgnoredReplaceFailureReproducer -vvv
contract SRAIgnoredReplaceFailureReproducer is SRATestBase {
    function test_ReplaceWalletMustRevertWhenNativeReplaceFails() public {
        address orch = makeAddr("repro-orchestrator");
        address oldWallet = _wallet("repro-old-wallet");
        address newWallet = _wallet("repro-new-wallet");
        _admit(orch, oldWallet);

        vm.roll(_quarterStart(0));
        _postAs(orch, 0, 100e18);
        vm.roll(_bindingStart(0));
        sra.submitShares(0);

        Share[] memory beforeMap = rewardActor().getShares(SERVICE_ID);
        assertEq(beforeMap.length, 1);
        assertEq(beforeMap[0].wallet, oldWallet);
        assertEq(FixedU18.unwrap(beforeMap[0].share), 1e18);

        // Simulate CALL_ACTOR_BY_ID becoming unavailable. The library reports exit code -1.
        // SRA must not commit the wallet change unless f02 commits ReplaceAddress atomically.
        vm.etch(CALL_ACTOR_BY_ID, hex"");

        vm.prank(owner1);
        sra.replaceWallet(orch, newWallet);

        vm.expectRevert(abi.encodeWithSelector(FVMRewards.ReplaceAddressFailed.selector, int256(-1)));
        vm.prank(owner2);
        sra.replaceWallet(orch, newWallet);
    }
}
