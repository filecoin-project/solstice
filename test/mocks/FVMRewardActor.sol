// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {USR_FORBIDDEN, USR_ILLEGAL_ARGUMENT, USR_NOT_FOUND, USR_UNHANDLED_MESSAGE} from "fvm-solidity/FVMErrors.sol";

import {
    SET_WEIGHT_RECORDS,
    SET_SHARES,
    GET_STATE,
    REGISTER_STREAM,
    REMOVE_STREAM,
    SET_DISTRIBUTION,
    CANCEL_PENDING,
    COMPUTE_WEIGHT,
    SWA_TIMELOCK
} from "./FVMRewardMethod.sol";

/// @dev Weights, and per-orchestrator shares, are WAD-scaled: 1e18 == 1.0 == 100%.
int256 constant WAD = 1e18;

/// @dev Mock-only caps; FIP-0118 requires MAX_STREAMS/MAX_RECIPIENTS limits exist but does
/// not fix their values, so these are placeholders sized for testing, not consensus values.
uint256 constant MAX_STREAMS = 8;
uint256 constant MAX_RECIPIENTS = 32;

/// @dev Same value as WAD, typed uint256: shares (always non-negative) are stored unsigned,
/// so comparing their sum against this avoids a signed-to-unsigned cast of WAD.
uint256 constant SHARE_TOTAL = 1e18;

/// @notice FIP-0118 section 2.4: the bundle of scheduler parameters for one stream's weight.
/// @dev vStart/slope/floor/cap are WAD-scaled Rationals; slope may be negative (w1's ramp).
struct WeightRecord {
    int256 vStart;
    int256 slope;
    uint64 tStart;
    int256 floor;
    int256 cap;
}

/// @notice A stream's Distribution: IMPLICIT (consensus stream only, f02-resolved recipient)
/// or EXPLICIT (a wallet-to-share map maintained by the stream's designated writer).
enum DistributionKind {
    IMPLICIT,
    EXPLICIT
}

/// @notice One entry in an EXPLICIT stream's wallet-to-share map.
struct Share {
    address wallet;
    uint256 share;
}

/// @notice FIP-0118 section 2.4: `Stream = { id, WeightRecord, Distribution }`. `id` is the
/// mapping key rather than a field here; `shares` is the EXPLICIT distribution's
/// wallet-to-share map (unused when `kind == IMPLICIT`).
struct Stream {
    bool exists;
    WeightRecord weightRecord;
    DistributionKind kind;
    address writer;
    Share[] shares;
}

enum PendingKind {
    NONE,
    REGISTER,
    SET_WEIGHT,
    SET_DISTRIBUTION,
    REMOVE
}

/// @dev A queued SWA write, held until `effectiveEpoch` per SWA_TIMELOCK. Only one pending
/// write per stream id at a time -- a second SWA write for the same id simply replaces it,
/// matching CancelPending's premise that there is a single queued write to discard.
struct Pending {
    PendingKind kind;
    uint64 effectiveEpoch;
    WeightRecord weightRecord;
    DistributionKind distributionKind;
    address writer;
}

/// @notice Mock for the Filecoin Reward actor (f02) covering the stream-splitting methods
///         proposed by draft FIP-0118 (https://github.com/filecoin-project/FIPs/pull/1270,
///         tracked in https://github.com/filecoin-project/builtin-actors/issues/1764):
///         SetWeightRecords, SetShares, GetState, RegisterStream, RemoveStream,
///         SetDistribution, CancelPending, and ComputeWeight.
/// @dev These mocks live in solstice, not fvm-solidity, because they mock methods that don't
///      exist in builtin-actors yet and will only ever be called by solstice's own contracts
///      (the future Stream Weights Actor and Service Rewards Actor).
/// @dev Etch this at REWARD_ACTOR_ADDRESS via MockRewardTest, which also re-etches
///      CALL_ACTOR_BY_ID with FVMCallActorByIdWithReward so that
///      CALL_ACTOR_BY_ID(actorId=REWARD_ACTOR_ID) reaches handle_filecoin_method below.
/// @dev Params/returns use plain abi.encode/abi.decode rather than CBOR: the real wire format
///      doesn't exist yet since builtin-actors hasn't implemented these methods, so there is
///      nothing to match. Revisit the encoding once the real actor ships.
contract FVMRewardActor {
    /// @notice The address authorized to call the SWA-only methods (SetWeightRecords,
    /// RegisterStream, RemoveStream, SetDistribution, CancelPending).
    address public swa;

    mapping(uint64 streamId => Stream) internal _streams;
    uint64[] internal _streamIds;

    mapping(uint64 streamId => Pending) internal _pending;
    uint64[] internal _pendingIds;

    /// @notice Test helper: set the address authorized to call SWA-only methods.
    function mockSwa(address swa_) external {
        swa = swa_;
    }

    /// @notice Test helper: read back an EXPLICIT stream's wallet-to-share map directly,
    /// without going through the CALL_ACTOR_BY_ID/CBOR-shaped GetState round trip.
    function getShares(uint64 streamId) external view returns (Share[] memory) {
        return _streams[streamId].shares;
    }

    /// @notice Fallback for unknown ABI selectors, matching the real reward actor's behavior
    /// for direct EVM CALL (InvokeContract): it's a native actor, so this returns
    /// USR_UNHANDLED_MESSAGE rather than reverting.
    fallback() external {
        bytes memory response = abi.encode(uint32(USR_UNHANDLED_MESSAGE), uint64(0), bytes(""));
        assembly ("memory-safe") {
            return(add(response, 0x20), mload(response))
        }
    }

    /// @dev Receives calls routed from FVMCallActorByIdWithReward's REWARD_ACTOR_ID branch.
    /// Returns (exitCode, codec, data); never reverts for actor-level errors, matching real
    /// FVM behavior where CALL_ACTOR_BY_ID returns success=true with a non-zero exit code.
    // forge-lint: disable-next-line(mixed-case-function)
    function handle_filecoin_method(uint64 method, uint64, bytes calldata params)
        external
        returns (uint32, uint64, bytes memory)
    {
        _settle();
        if (method == SET_WEIGHT_RECORDS) return _setWeightRecords(params);
        if (method == SET_SHARES) return _setShares(params);
        if (method == GET_STATE) return _getState();
        if (method == REGISTER_STREAM) return _registerStream(params);
        if (method == REMOVE_STREAM) return _removeStream(params);
        if (method == SET_DISTRIBUTION) return _setDistribution(params);
        if (method == CANCEL_PENDING) return _cancelPending(params);
        if (method == COMPUTE_WEIGHT) return _computeWeight(params);
        return (USR_UNHANDLED_MESSAGE, 0, "");
    }

    // -------------------------------------------------------------------------
    // SetWeightRecords(ids, records) -- SWA only, queued under SWA_TIMELOCK
    // -------------------------------------------------------------------------

    function _setWeightRecords(bytes calldata params) internal returns (uint32, uint64, bytes memory) {
        if (msg.sender != swa) return (USR_FORBIDDEN, 0, "");
        (uint64[] memory ids, WeightRecord[] memory records) = abi.decode(params, (uint64[], WeightRecord[]));
        if (ids.length != records.length) return (USR_ILLEGAL_ARGUMENT, 0, "");

        uint64 effectiveEpoch = uint64(block.number) + SWA_TIMELOCK;
        for (uint256 i = 0; i < ids.length; i++) {
            if (!_streams[ids[i]].exists) return (USR_NOT_FOUND, 0, "");
            if (!_sane(records[i])) return (USR_ILLEGAL_ARGUMENT, 0, "");
        }
        // Guardrail (FIP-0118 2.4): sum of all *other* streams' current weight, plus the
        // newly proposed weights, must not exceed 1 at the activation epoch.
        int256 sum = _sumWeightsExcluding(ids, effectiveEpoch);
        for (uint256 i = 0; i < records.length; i++) {
            sum += _clampWeight(records[i], effectiveEpoch);
        }
        if (sum > WAD) return (USR_ILLEGAL_ARGUMENT, 0, "");

        for (uint256 i = 0; i < ids.length; i++) {
            _queue(
                ids[i],
                Pending({
                    kind: PendingKind.SET_WEIGHT,
                    effectiveEpoch: effectiveEpoch,
                    weightRecord: records[i],
                    distributionKind: DistributionKind.IMPLICIT,
                    writer: address(0)
                })
            );
        }
        return (0, 0, "");
    }

    // -------------------------------------------------------------------------
    // SetShares(id, shares) -- the stream's designated writer only, applied immediately
    // -------------------------------------------------------------------------

    function _setShares(bytes calldata params) internal returns (uint32, uint64, bytes memory) {
        (uint64 id, Share[] memory shares) = abi.decode(params, (uint64, Share[]));
        Stream storage s = _streams[id];
        if (!s.exists) return (USR_NOT_FOUND, 0, "");
        if (s.kind != DistributionKind.EXPLICIT) return (USR_ILLEGAL_ARGUMENT, 0, "");
        if (msg.sender != s.writer) return (USR_FORBIDDEN, 0, "");
        if (shares.length > MAX_RECIPIENTS) return (USR_ILLEGAL_ARGUMENT, 0, "");

        uint256 total;
        for (uint256 i = 0; i < shares.length; i++) {
            total += shares[i].share;
        }
        if (total != SHARE_TOTAL) return (USR_ILLEGAL_ARGUMENT, 0, "");

        delete s.shares;
        for (uint256 i = 0; i < shares.length; i++) {
            s.shares.push(shares[i]);
        }
        return (0, 0, "");
    }

    // -------------------------------------------------------------------------
    // GetState() -- read-only
    // -------------------------------------------------------------------------

    function _getState() internal view returns (uint32, uint64, bytes memory) {
        uint256 n = _streamIds.length;
        uint64[] memory ids = new uint64[](n);
        WeightRecord[] memory records = new WeightRecord[](n);
        DistributionKind[] memory kinds = new DistributionKind[](n);
        address[] memory writers = new address[](n);
        int256[] memory weights = new int256[](n);

        uint64 nowEpoch = uint64(block.number);
        for (uint256 i = 0; i < n; i++) {
            uint64 id = _streamIds[i];
            Stream storage s = _streams[id];
            ids[i] = id;
            records[i] = s.weightRecord;
            kinds[i] = s.kind;
            writers[i] = s.writer;
            weights[i] = _clampWeight(s.weightRecord, nowEpoch);
        }
        return (0, 0, abi.encode(ids, records, kinds, writers, weights));
    }

    // -------------------------------------------------------------------------
    // RegisterStream(id, weightRecord, kind, writer, activationEpoch) -- SWA only
    // -------------------------------------------------------------------------

    function _registerStream(bytes calldata params) internal returns (uint32, uint64, bytes memory) {
        if (msg.sender != swa) return (USR_FORBIDDEN, 0, "");
        (uint64 id, WeightRecord memory record, DistributionKind kind, address writer, uint64 activationEpoch) =
            abi.decode(params, (uint64, WeightRecord, DistributionKind, address, uint64));

        if (_streams[id].exists || _pending[id].kind == PendingKind.REGISTER) {
            return (USR_ILLEGAL_ARGUMENT, 0, "");
        }
        // Count queued-but-not-yet-settled registrations too: otherwise a burst of
        // RegisterStream calls within one SWA_TIMELOCK window could blow past the cap, since
        // none of them would be in _streamIds yet.
        if (_streamIds.length + _pendingRegistrationCount() >= MAX_STREAMS) {
            return (USR_ILLEGAL_ARGUMENT, 0, "");
        }
        if (!_sane(record)) return (USR_ILLEGAL_ARGUMENT, 0, "");
        // IMPLICIT is consensus-only and carries no writer; EXPLICIT always needs one.
        if (kind == DistributionKind.IMPLICIT ? writer != address(0) : writer == address(0)) {
            return (USR_ILLEGAL_ARGUMENT, 0, "");
        }
        if (activationEpoch < uint64(block.number) + SWA_TIMELOCK) return (USR_ILLEGAL_ARGUMENT, 0, "");

        int256 sum = _sumWeightsExcluding(new uint64[](0), activationEpoch) + _clampWeight(record, activationEpoch);
        if (sum > WAD) return (USR_ILLEGAL_ARGUMENT, 0, "");

        _queue(
            id,
            Pending({
                kind: PendingKind.REGISTER,
                effectiveEpoch: activationEpoch,
                weightRecord: record,
                distributionKind: kind,
                writer: writer
            })
        );
        return (0, 0, "");
    }

    // -------------------------------------------------------------------------
    // RemoveStream(id) -- SWA only, queued under SWA_TIMELOCK
    // -------------------------------------------------------------------------

    function _removeStream(bytes calldata params) internal returns (uint32, uint64, bytes memory) {
        if (msg.sender != swa) return (USR_FORBIDDEN, 0, "");
        uint64 id = abi.decode(params, (uint64));
        if (!_streams[id].exists) return (USR_NOT_FOUND, 0, "");

        _queue(
            id,
            Pending({
                kind: PendingKind.REMOVE,
                effectiveEpoch: uint64(block.number) + SWA_TIMELOCK,
                weightRecord: WeightRecord({vStart: 0, slope: 0, tStart: 0, floor: 0, cap: 0}),
                distributionKind: DistributionKind.IMPLICIT,
                writer: address(0)
            })
        );
        return (0, 0, "");
    }

    // -------------------------------------------------------------------------
    // SetDistribution(id, kind, writer) -- SWA only, queued under SWA_TIMELOCK
    // -------------------------------------------------------------------------

    function _setDistribution(bytes calldata params) internal returns (uint32, uint64, bytes memory) {
        if (msg.sender != swa) return (USR_FORBIDDEN, 0, "");
        (uint64 id, DistributionKind kind, address writer) = abi.decode(params, (uint64, DistributionKind, address));
        if (!_streams[id].exists) return (USR_NOT_FOUND, 0, "");
        // "Converting a stream to IMPLICIT is not permitted (IMPLICIT is consensus-only)."
        if (kind == DistributionKind.IMPLICIT || writer == address(0)) return (USR_ILLEGAL_ARGUMENT, 0, "");

        _queue(
            id,
            Pending({
                kind: PendingKind.SET_DISTRIBUTION,
                effectiveEpoch: uint64(block.number) + SWA_TIMELOCK,
                weightRecord: WeightRecord({vStart: 0, slope: 0, tStart: 0, floor: 0, cap: 0}),
                distributionKind: kind,
                writer: writer
            })
        );
        return (0, 0, "");
    }

    // -------------------------------------------------------------------------
    // CancelPending(id) -- SWA only
    // -------------------------------------------------------------------------

    function _cancelPending(bytes calldata params) internal returns (uint32, uint64, bytes memory) {
        if (msg.sender != swa) return (USR_FORBIDDEN, 0, "");
        uint64 id = abi.decode(params, (uint64));
        if (_pending[id].kind == PendingKind.NONE) return (USR_NOT_FOUND, 0, "");

        delete _pending[id];
        _removePendingId(id);
        return (0, 0, "");
    }

    // -------------------------------------------------------------------------
    // ComputeWeight(record, epoch) -- pure
    // -------------------------------------------------------------------------

    function _computeWeight(bytes calldata params) internal pure returns (uint32, uint64, bytes memory) {
        (WeightRecord memory record, uint64 epoch) = abi.decode(params, (WeightRecord, uint64));
        return (0, 0, abi.encode(_clampWeight(record, epoch)));
    }

    // -------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------

    /// @dev FIP-0118 2.4: `clamp(v_start + slope * (e - t_start), floor, cap)`.
    function _clampWeight(WeightRecord memory w, uint64 e) internal pure returns (int256 weight) {
        int256 raw = w.vStart + w.slope * (int256(uint256(e)) - int256(uint256(w.tStart)));
        weight = raw < w.floor ? w.floor : (raw > w.cap ? w.cap : raw);
    }

    /// @dev Per-record sanity required at write time: 0 <= floor <= cap <= 1.
    function _sane(WeightRecord memory w) internal pure returns (bool) {
        return w.floor >= 0 && w.floor <= w.cap && w.cap <= WAD;
    }

    /// @dev Sum of every *registered* stream's weight at `atEpoch`, excluding `excludeIds`.
    /// Streams with a not-yet-settled pending write still count at their currently stored
    /// (pre-write) record -- the invariant check is against what is live today, matching
    /// f02's "validates ... at the activation epoch" rule for the write being proposed now.
    function _sumWeightsExcluding(uint64[] memory excludeIds, uint64 atEpoch) internal view returns (int256 sum) {
        for (uint256 i = 0; i < _streamIds.length; i++) {
            uint64 id = _streamIds[i];
            bool excluded = false;
            for (uint256 j = 0; j < excludeIds.length; j++) {
                if (excludeIds[j] == id) {
                    excluded = true;
                    break;
                }
            }
            if (!excluded) sum += _clampWeight(_streams[id].weightRecord, atEpoch);
        }
    }

    function _pendingRegistrationCount() internal view returns (uint256 count) {
        for (uint256 i = 0; i < _pendingIds.length; i++) {
            if (_pending[_pendingIds[i]].kind == PendingKind.REGISTER) count++;
        }
    }

    function _queue(uint64 id, Pending memory p) internal {
        if (_pending[id].kind == PendingKind.NONE) _pendingIds.push(id);
        _pending[id] = p;
    }

    function _removePendingId(uint64 id) internal {
        for (uint256 i = 0; i < _pendingIds.length; i++) {
            if (_pendingIds[i] == id) {
                _pendingIds[i] = _pendingIds[_pendingIds.length - 1];
                _pendingIds.pop();
                return;
            }
        }
    }

    /// @dev Applies every queued write whose effectiveEpoch has arrived. Called at the top
    /// of every dispatched method so stored state is always current before it's read or
    /// validated against.
    function _settle() internal {
        uint64 nowEpoch = uint64(block.number);
        for (uint256 i = 0; i < _pendingIds.length;) {
            uint64 id = _pendingIds[i];
            Pending storage p = _pending[id];
            if (nowEpoch >= p.effectiveEpoch) {
                _apply(id, p);
                delete _pending[id];
                _pendingIds[i] = _pendingIds[_pendingIds.length - 1];
                _pendingIds.pop();
                continue;
            }
            i++;
        }
    }

    function _apply(uint64 id, Pending storage p) internal {
        if (p.kind == PendingKind.REGISTER) {
            Stream storage s = _streams[id];
            s.exists = true;
            s.weightRecord = p.weightRecord;
            s.kind = p.distributionKind;
            s.writer = p.writer;
            _streamIds.push(id);
        } else if (p.kind == PendingKind.SET_WEIGHT) {
            _streams[id].weightRecord = p.weightRecord;
        } else if (p.kind == PendingKind.SET_DISTRIBUTION) {
            _streams[id].kind = p.distributionKind;
            _streams[id].writer = p.writer;
        } else if (p.kind == PendingKind.REMOVE) {
            delete _streams[id];
            for (uint256 j = 0; j < _streamIds.length; j++) {
                if (_streamIds[j] == id) {
                    _streamIds[j] = _streamIds[_streamIds.length - 1];
                    _streamIds.pop();
                    break;
                }
            }
        }
    }
}
