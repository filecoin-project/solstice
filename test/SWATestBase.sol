// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {MockRewardTest} from "./mocks/MockRewardTest.sol";
import {WAD, MAINNET_TIMELOCK} from "./mocks/FVMRewardActor.sol";
import {StreamWeightActor} from "../src/StreamWeightActor.sol";
import {IServiceRewardsActor} from "../src/interfaces/IServiceRewardsActor.sol";
import {Share, WeightRecord, WeightRecordUpdate} from "../src/lib/FVMRewardTypes.sol";
import {Epoch} from "../src/lib/Epoch.sol";
import {FixedU18} from "../src/lib/FixedU18.sol";
import {UnanimousProxy} from "../src/lib/UnanimousProxy.sol";

/// @notice Common SWA test base: deploys the StreamWeightActor (behind its ERC1967 proxy) with a
///         mainnet-hold SRA mock, and provides the registration/record-building helpers shared by
///         StreamWeightActor.t.sol and StreamWeightGate.t.sol. Carries no test_ functions of its
///         own, so a suite extending it does not inherit and rerun another suite's tests.
contract SWATestBase is MockRewardTest {
    StreamWeightActor actor;
    address owner1;
    address owner2;

    uint64 constant STREAM_ID = 1;
    address constant WRITER = address(0xBEEF);

    function setUp() public virtual override {
        super.setUp();
        owner1 = makeAddr("owner1");
        owner2 = makeAddr("owner2");

        address sra = makeAddr("sra");

        address swaImpl = address(new StreamWeightActor(owner1, owner2, MAINNET_TIMELOCK, IServiceRewardsActor(sra)));
        address proxy = address(new ERC1967Proxy(swaImpl, abi.encodeCall(UnanimousProxy.initialize, ())));
        actor = StreamWeightActor(proxy);
        rewardActor().mockSwa(address(actor));
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _record(int256 w) internal pure returns (WeightRecord memory) {
        return WeightRecord({vStart: w, slope: 0, tStart: Epoch.wrap(0), floor: 0, cap: WAD});
    }

    function _activation() internal view returns (uint64) {
        return uint64(vm.getBlockNumber()) + Epoch.unwrap(MAINNET_TIMELOCK);
    }

    function _shares() internal pure returns (Share[] memory shares) {
        shares = new Share[](1);
        shares[0] = Share({wallet: WRITER, share: FixedU18.wrap(uint256(WAD))});
    }

    function _singleWeightRecord(uint64 id, WeightRecord memory record)
        internal
        pure
        returns (WeightRecordUpdate[] memory updates)
    {
        updates = new WeightRecordUpdate[](1);
        updates[0] = WeightRecordUpdate({id: id, record: record});
    }

    /// @dev Registers STREAM_ID (EXPLICIT, WRITER) through both owners, then rolls past the
    /// timelock so the next dispatched call settles it into existence.
    function _registerAndActivate(uint64 id) internal {
        vm.prank(owner1);
        actor.registerStream(id, _record(0.1e18), WRITER, _shares(), _activation());
        vm.prank(owner2);
        actor.registerStream(id, _record(0.1e18), WRITER, _shares(), _activation());
        vm.roll(vm.getBlockNumber() + Epoch.unwrap(MAINNET_TIMELOCK));
    }
}
