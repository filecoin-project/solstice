// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {StreamWeightActor} from "../../src/StreamWeightActor.sol";
import {IServiceRewardsActor} from "../../src/interfaces/IServiceRewardsActor.sol";
import {Epoch} from "../../src/lib/Epoch.sol";
import {FixedU18} from "../../src/lib/FixedU18.sol";
import {GateParams, VolumeTarget} from "../../src/lib/GateParams.sol";
import {UnanimousProxied} from "../../src/lib/UnanimousProxied.sol";

bytes32 constant HOLD_WRAP_GATE_SLOT = 0xf9abab00248d945495524c8caf6be2b837274c1becd1964fb3775f62fd6e4600;

/// Production held-governance reproducer for appendlog Entry 033.
/// Run:
/// forge test --contracts review/reproducers --match-contract HoldDeadlineWrapReproducer -vv
contract HoldDeadlineWrapReproducer is Test {
    function test_PositiveHoldMustNotMatureBeforeItsFinalApproval() public {
        vm.roll(100);
        address owner1 = makeAddr("owner1");
        address owner2 = makeAddr("owner2");
        StreamWeightActor implementation =
            new StreamWeightActor(owner1, owner2, Epoch.wrap(type(uint64).max), IServiceRewardsActor(makeAddr("sra")));
        StreamWeightActor actor = StreamWeightActor(
            address(new ERC1967Proxy(address(implementation), abi.encodeCall(UnanimousProxied.initialize, ())))
        );

        GateParams memory params = GateParams({
            target: VolumeTarget({base: FixedU18.wrap(4000 ether), stepRatio: FixedU18.wrap(2.7 ether)}), steps: 0
        });
        vm.prank(owner1);
        actor.setGateParams(params);
        vm.prank(owner2);
        actor.setGateParams(params);

        actor.setGateParams(params); // arbitrary public finalizer, no epoch advance

        uint256 storedBase = uint256(vm.load(address(actor), bytes32(uint256(HOLD_WRAP_GATE_SLOT) + 1)));
        assertEq(storedBase, 3500 ether, "wrapped deadline bypassed the configured positive hold");
    }
}
