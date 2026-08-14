// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {IServiceRewardsActor} from "./interfaces/IServiceRewardsActor.sol";
import {Epoch, currentEpoch} from "./lib/Epoch.sol";
import {FixedU18} from "./lib/FixedU18.sol";
import {GateParams, GateParamsLibrary} from "./lib/GateParams.sol";
import {FVMRewards} from "./lib/FVMRewards.sol";
import {PendingOp, Share, WeightRecord, WeightRecordUpdate} from "./lib/FVMRewardTypes.sol";
import {OwnersLibrary} from "./lib/Owners.sol";
import {UnanimousGovernance} from "./lib/UnanimousGovernance.sol";
import {IsASafe} from "./lib/IsASafe.sol";

uint64 constant CONSENSUS_ID = 1;
uint64 constant SERVICE_ID = 1;

int256 constant INITIAL = 5e16; // 5%
int256 constant STEP = 5e16; // 5%

// TODO get QUARTER and HOLD from SRA
Epoch constant QUARTER = Epoch.wrap(262980); // epochs per 365.25/4 days
Epoch constant HOLD = Epoch.wrap(2 * 60 * 24 * 7); // epochs per 7 days

contract StreamWeightActor is UnanimousGovernance {
    using IsASafe for address;
    using OwnersLibrary for address;

    IServiceRewardsActor immutable SRA;

    constructor(address owner1, address owner2, IServiceRewardsActor sra) {
        owner1.isProbablyASafe();
        owner2.isProbablyASafe();

        owner1.addOwner();
        owner2.addOwner();

        SRA = sra;
    }

    function registerStream(uint64 id, WeightRecord calldata record, uint64 activationEpoch)
        external
        unanimousNoHold(keccak256(msg.data))
    {
        // hold enforced in f02
        FVMRewards.registerStream(id, record, activationEpoch);
    }

    function registerStream(
        uint64 id,
        WeightRecord calldata record,
        address writer,
        Share[] calldata shares,
        uint64 activationEpoch
    ) external unanimousNoHold(keccak256(msg.data)) {
        // hold enforced in f02
        FVMRewards.registerStream(id, record, writer, shares, activationEpoch);
    }

    function removeStream(uint64 id) external unanimousNoHold(keccak256(msg.data)) {
        // hold enforced in f02
        FVMRewards.removeStream(id);
    }

    function setWeightRecords(WeightRecordUpdate[] calldata updates) external unanimousNoHold(keccak256(msg.data)) {
        // hold enforced in f02
        FVMRewards.setWeightRecords(updates);
    }

    function setDistribution(uint64 id, address writer) external unanimousNoHold(keccak256(msg.data)) {
        // hold enforced in f02
        FVMRewards.setDistribution(id, writer);
    }

    function cancelPending(uint64 id, PendingOp op) external {
        // any owner can immediately cancel any pending operation
        require(msg.sender.isOwner());
        FVMRewards.cancelPending(id, op);
    }

    function cancelPendingWeight(PendingOp op) external {
        // any owner can immediately cancel any pending operation
        require(msg.sender.isOwner());
        FVMRewards.cancelPendingWeight(op);
    }

    function replaceOwner(address prevOwner, address newOwner) external unanimousNoHold(keccak256(msg.data)) {
        newOwner.isProbablyASafe();
        prevOwner.removeOwner();
        newOwner.addOwner();
    }

    // TODO relocate these
    Epoch nextQuarter;

    error WaitUntil(Epoch then);
    error StepsComplete();

    function quarterlyGateCheck() external {
        Epoch nextQuarterLoaded = nextQuarter;
        require(nextQuarterLoaded <= currentEpoch(), WaitUntil(nextQuarterLoaded));

        GateParamsLibrary.GateParamsInfo storage gateParamsInfo = GateParamsLibrary.getGateParamsSlot();
        GateParams memory loaded = gateParamsInfo.params;
        require(loaded.steps < 9, StepsComplete());

        int256 nextCap = (int256(uint256(loaded.steps)) + 2) * STEP; // FIXME this is wrong
        // TODO aggregatedFPV takes an incrementing quarter index, not an epoch; nextQuarterLoaded is wrong here
        FixedU18 fpv = SRA.aggregatedFPV(Epoch.unwrap(nextQuarterLoaded));

        WeightRecordUpdate[] memory updates = new WeightRecordUpdate[](1);
        updates[0].id = SERVICE_ID;
        updates[0].record.floor = INITIAL;
        updates[0].record.tStart = nextQuarter;
        updates[0].record.vStart = nextCap;

        if (fpv > loaded.nextThreshold()) {
            updates[0].record.cap = nextCap;
            updates[0].record.slope =
                (updates[0].record.cap - updates[0].record.vStart) / int256(uint256(Epoch.unwrap(QUARTER)));

            loaded.steps++;
            gateParamsInfo.params = loaded;
        } else {
            updates[0].record.cap = nextCap;
            updates[0].record.slope = 0;
        }

        FVMRewards.stepWeightRecords(updates);
        nextQuarter = nextQuarterLoaded + QUARTER;
    }

    function setGateParams(GateParams calldata params) external unanimous(keccak256(msg.data), HOLD) {
        GateParamsLibrary.getGateParamsSlot().params = params;
    }
}
