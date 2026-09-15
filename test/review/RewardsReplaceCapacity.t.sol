// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {SRATestBase} from "../SRATestBase.sol";
import {Epoch} from "../../src/lib/Epoch.sol";
import {FixedU18} from "../../src/lib/FixedU18.sol";
import {FVMRewards} from "../../src/lib/FVMRewards.sol";
import {SERVICE_ID, Share, WeightRecord, WeightRecordUpdate} from "../../src/lib/FVMRewardTypes.sol";

contract RewardsReplaceCapacityReview is SRATestBase {
    function test_ReplaceWalletCommitsWhenF02RejectsPayableCapacity() public {
        Share[] memory oldMap = _map(1_000);
        Share[] memory currentMap = _map(2_000);
        address orch = makeAddr("capacity-orch");
        address newWallet = _wallet("capacity-new-wallet");
        _admit(orch, currentMap[0].wallet);

        // Temporarily make this harness the designated writer so it can construct a reachable
        // full payable union, then restore the SRA before exercising replaceWallet.
        rewardActor().mockSwaTimelockEpochs(0);
        FVMRewards.setDistribution(SERVICE_ID, address(this));
        rewardActor().mockAwardBlockReward(0); // settle the zero-delay writer change

        FVMRewards.setShares(SERVICE_ID, oldMap);
        _setServiceWeightToOne();
        rewardActor().mockAwardBlockReward(64 ether);
        FVMRewards.setShares(SERVICE_ID, currentMap); // 64 old payable + 64 live = the 128-row limit

        FVMRewards.setDistribution(SERVICE_ID, address(sra));
        rewardActor().mockAwardBlockReward(0); // restore the real writer without adding accrual
        rewardActor().mockAwardBlockReward(64 ether);

        vm.prank(owner1);
        sra.replaceWallet(orch, newWallet);
        vm.prank(owner2);
        sra.replaceWallet(orch, newWallet); // SRA succeeds although f02 rejects the 129-row union

        Share[] memory actual = rewardActor().getShares(SERVICE_ID);
        assertTrue(_contains(actual, currentMap[0].wallet), "stale f02 recipient remains");
        assertFalse(_contains(actual, newWallet), "new SRA wallet never reached f02");
    }

    function _map(uint160 base) private returns (Share[] memory shares) {
        shares = new Share[](64);
        for (uint256 i = 0; i < shares.length; i++) {
            address wallet = address(base + uint160(i));
            _ensureResolvable(wallet);
            shares[i] = Share({wallet: wallet, share: FixedU18.wrap(1e18 / 64)});
        }
    }

    function _setServiceWeightToOne() private {
        WeightRecordUpdate[] memory updates = new WeightRecordUpdate[](1);
        updates[0] = WeightRecordUpdate({
            id: SERVICE_ID,
            record: WeightRecord({
                vStart: 1e18, slope: 0, tStart: Epoch.wrap(uint64(block.number)), floor: 1e18, cap: 1e18
            })
        });
        FVMRewards.setWeightRecords(updates);
        rewardActor().mockAwardBlockReward(0); // settle the zero-delay weight change
    }

    function _contains(Share[] memory shares, address wallet) private pure returns (bool) {
        for (uint256 i = 0; i < shares.length; i++) {
            if (shares[i].wallet == wallet) return true;
        }
        return false;
    }
}
