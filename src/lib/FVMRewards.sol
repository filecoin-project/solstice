// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {CALL_ACTOR_BY_ID} from "fvm-solidity/FVMPrecompiles.sol";
import {REWARD_ACTOR_ID} from "fvm-solidity/FVMActors.sol";
import {NO_FLAGS} from "fvm-solidity/FVMFlags.sol";
import {CBOR_CODEC} from "fvm-solidity/FVMCodec.sol";
import {EXIT_SUCCESS} from "fvm-solidity/FVMErrors.sol";

import {
    REGISTER_STREAM,
    REMOVE_STREAM,
    SET_WEIGHT_RECORDS,
    STEP_WEIGHT_RECORDS,
    SET_DISTRIBUTION,
    CANCEL_PENDING,
    SET_SHARES,
    CLAIM
} from "./FVMRewardMethod.sol";
import {WeightRecord, WeightRecordUpdate, Share, PendingOp} from "./FVMRewardTypes.sol";

/// @notice Calls the f02 (Reward actor) methods specified by FIP-0118, for the Stream Weight
/// Actor (solstice#3) and Service Rewards Actor (solstice#4).
/// @dev Every param blob is a DAG-CBOR array of positional fields matching f02's own parameter
/// tuples, which are pinned by the vectors in builtin-actors
/// `actors/reward/tests/types_test.rs`. The Solidity mirror of those vectors is
/// `test/mocks/FVMRewardWire.t.sol`; change an encoding here and that table must move with it.
/// @dev DAG-CBOR admits only definite-length arrays and shortest-form integers, so every array
/// header carries its count and every integer is written in the narrowest form that holds it.
library FVMRewards {
    error RegisterStreamFailed(int256 exitCode);
    error RemoveStreamFailed(int256 exitCode);
    error SetWeightRecordsFailed(int256 exitCode);
    error StepWeightRecordsFailed(int256 exitCode);
    error SetDistributionFailed(int256 exitCode);
    error CancelPendingFailed(int256 exitCode);
    error SetSharesFailed(int256 exitCode);
    error ClaimFailed(int256 exitCode);

    /// @dev A field does not fit the width f02 declares for it, so encoding it would silently
    /// truncate. Solidity checks arithmetic overflow but not narrowing casts, so this is checked.
    error ValueOutOfRange(int256 value);
    /// @dev An implicit stream (null distribution) carries no share map.
    error ImplicitStreamWithShares();

    /// @dev Sentinel for the unexpected case where the syscall reverts or returns fewer than 32
    /// bytes. Kept at -1 to match `fvm-solidity`'s behavior.
    int256 internal constant EXIT_PRECOMPILE_FAILED = -1;

    uint256 private constant ENVELOPE_HEAD = 0xe0;

    // Upper bounds on encoded size, in bytes. Each `_begin` call below sums these to reserve the
    // memory its params need, and every term maps one-to-one onto a `_write*` call beneath it, so
    // a bound can be checked by reading down the function. Under-counting would write past the
    // reservation rather than revert, which is why these are deliberately loose and traceable
    // rather than tight and clever; `_invoke` also asserts the reservation held.

    /// @dev Any CBOR head, whatever its major type: the tag byte plus eight argument bytes. Array
    /// and byte-string headers are counted at this width too, since the library does not bound the
    /// array lengths a caller may hand it.
    uint256 private constant MAX_HEAD_BYTES = 9;
    uint256 private constant NULL_BYTES = 1;
    /// @dev A one-byte head plus f410's 22 payload bytes. An f0 address is at most 12.
    uint256 private constant MAX_ADDRESS_BYTES = 23;
    /// @dev A weight record: its own head plus five integers.
    uint256 private constant MAX_RECORD_BYTES = 6 * MAX_HEAD_BYTES;
    /// @dev One `[recipient, share]` row.
    uint256 private constant MAX_SHARE_BYTES = MAX_HEAD_BYTES + MAX_ADDRESS_BYTES + MAX_HEAD_BYTES;
    /// @dev One `[id, record]` row.
    uint256 private constant MAX_UPDATE_BYTES = MAX_HEAD_BYTES + MAX_HEAD_BYTES + MAX_RECORD_BYTES;

    // -------------------------------------------------------------------------
    // Width guards
    // -------------------------------------------------------------------------

    function _u64(int256 v) private pure returns (uint256) {
        if (v < 0 || v > int256(uint256(type(uint64).max))) revert ValueOutOfRange(v);
        return uint256(v);
    }

    function _i64(int256 v) private pure returns (int256) {
        if (v < type(int64).min || v > type(int64).max) revert ValueOutOfRange(v);
        return v;
    }

    // -------------------------------------------------------------------------
    // CBOR primitives. One implementation each: these are written into memory this library
    // reserved, so callers pass and receive a raw cursor rather than a `bytes memory`.
    // -------------------------------------------------------------------------

    /// @dev Writes a major-type header with `value` in shortest form, returning the new cursor.
    function _writeHead(uint256 p, uint256 major, uint256 value) private pure returns (uint256) {
        uint256 base = major << 5;
        assembly ("memory-safe") {
            switch lt(value, 24)
            case 1 {
                mstore8(p, or(base, value))
                p := add(p, 1)
            }
            default {
                switch lt(value, 0x100)
                case 1 {
                    mstore8(p, or(base, 24))
                    mstore8(add(p, 1), value)
                    p := add(p, 2)
                }
                default {
                    switch lt(value, 0x10000)
                    case 1 {
                        mstore8(p, or(base, 25))
                        mstore(add(p, 1), shl(240, value))
                        p := add(p, 3)
                    }
                    default {
                        switch lt(value, 0x100000000)
                        case 1 {
                            mstore8(p, or(base, 26))
                            mstore(add(p, 1), shl(224, value))
                            p := add(p, 5)
                        }
                        default {
                            mstore8(p, or(base, 27))
                            mstore(add(p, 1), shl(192, value))
                            p := add(p, 9)
                        }
                    }
                }
            }
        }
        return p;
    }

    function _writeUint(uint256 p, uint256 v) private pure returns (uint256) {
        return _writeHead(p, 0, v);
    }

    function _writeInt(uint256 p, int256 v) private pure returns (uint256) {
        _i64(v);
        // CBOR encodes a negative n as major type 1 carrying -1-n.
        if (v < 0) return _writeHead(p, 1, uint256(-1 - v));
        return _writeHead(p, 0, uint256(v));
    }

    function _writeArrayHeader(uint256 p, uint256 count) private pure returns (uint256) {
        return _writeHead(p, 4, count);
    }

    function _writeNull(uint256 p) private pure returns (uint256) {
        assembly ("memory-safe") {
            mstore8(p, 0xf6)
        }
        return p + 1;
    }

    /// @dev A Filecoin address as a CBOR byte string, in one of the two forms a contract can hold.
    ///
    /// A masked ID address (`0xff` then eleven zero bytes then a big-endian actor id) is the EVM
    /// spelling of any Filecoin-native actor, and encodes as protocol 0: a zero byte followed by
    /// the id as an unsigned LEB128 varint. Everything else is an EVM-native actor and encodes as
    /// an f410 delegated address: `0x04`, `0x0a`, then the twenty address bytes.
    ///
    /// Emitting f410 for a masked ID would name a delegated address nobody created, so it resolves
    /// nowhere and f02 rejects the call. f099, the burn actor, is reachable only through the first
    /// form.
    function _writeAddress(uint256 p, address a) private pure returns (uint256) {
        uint256 v = uint256(uint160(a));
        if ((v >> 64) == (uint256(0xff) << 88)) return _writeIdAddress(p, v);

        assembly ("memory-safe") {
            // bytes(22): 0x56, then the protocol-4 EAM prefix, then the address.
            mstore(p, or(shl(232, 0x56040a), shl(72, v)))
            p := add(p, 23)
        }
        return p;
    }

    /// @dev The shift-and-mask runs in Solidity rather than assembly: inline assembly reads the
    /// raw stack slot, where a narrow type's upper bits are not guaranteed clean, and here those
    /// bits are the rest of the masked-ID address.
    function _writeIdAddress(uint256 p, uint256 id) private pure returns (uint256) {
        id &= type(uint64).max;

        // Payload is the protocol byte plus the varint; the header is inline for any id, since a
        // u64 varint reaches ten bytes at most.
        uint256 varintLen = 1;
        for (uint256 rest = id >> 7; rest != 0; rest >>= 7) {
            varintLen++;
        }

        p = _writeHead(p, 2, varintLen + 1);
        assembly ("memory-safe") {
            mstore8(p, 0)
        }
        p += 1;
        while (id > 0x7f) {
            assembly ("memory-safe") {
                mstore8(p, or(and(id, 0x7f), 0x80))
            }
            p += 1;
            id >>= 7;
        }
        assembly ("memory-safe") {
            mstore8(p, id)
        }
        return p + 1;
    }

    /// @dev `[v_start, slope, t_start, floor, cap]`. f02 declares v_start, floor and cap as u64
    /// and slope and t_start as i64; the struct is signed throughout so a caller can hand f02 a
    /// record it will reject, but a value outside the declared width cannot be encoded at all.
    function _writeRecord(uint256 p, WeightRecord memory r) private pure returns (uint256) {
        p = _writeArrayHeader(p, 5);
        p = _writeUint(p, _u64(r.vStart));
        p = _writeInt(p, r.slope);
        p = _writeInt(p, int256(uint256(r.tStart)));
        p = _writeUint(p, _u64(r.floor));
        p = _writeUint(p, _u64(r.cap));
        return p;
    }

    /// @dev `[[recipient, share], ...]`.
    function _writeShares(uint256 p, Share[] memory shares) private pure returns (uint256) {
        p = _writeArrayHeader(p, shares.length);
        for (uint256 i = 0; i < shares.length; i++) {
            p = _writeArrayHeader(p, 2);
            p = _writeAddress(p, shares[i].wallet);
            if (shares[i].share > type(uint64).max) revert ValueOutOfRange(int256(shares[i].share));
            p = _writeUint(p, shares[i].share);
        }
        return p;
    }

    // -------------------------------------------------------------------------
    // Call envelope: the six-field tuple CALL_ACTOR_BY_ID expects, laid out by hand.
    // -------------------------------------------------------------------------

    /// @dev Reserves `paramsBound` bytes of params space and writes the fixed head, returning the
    /// envelope base and the cursor the params start at.
    function _begin(uint64 method, uint256 paramsBound) private pure returns (uint256 base, uint256 p) {
        assembly ("memory-safe") {
            base := mload(0x40)
            // Own the whole envelope before writing, so nothing here depends on scratch memory
            // surviving an allocation.
            mstore(0x40, add(base, and(add(add(ENVELOPE_HEAD, paramsBound), 31), not(31))))
            mstore(base, method)
            mstore(add(base, 0x20), 0) // value: no method accepts one
            mstore(add(base, 0x40), NO_FLAGS)
            mstore(add(base, 0x60), CBOR_CODEC)
            mstore(add(base, 0x80), 0xc0) // offset of the params bytes within the tuple
            mstore(add(base, 0xa0), REWARD_ACTOR_ID)
            p := add(base, ENVELOPE_HEAD)
        }
    }

    /// @dev Completes the envelope and invokes the precompile, returning f02's exit code.
    function _invoke(uint256 base, uint256 p) private returns (int256 exitCode) {
        assembly ("memory-safe") {
            // The reservation `_begin` made ends at the free memory pointer, since nothing between
            // then and now allocates. Writing past it would corrupt the next allocation silently,
            // so an under-counted bound fails here instead.
            if gt(p, mload(0x40)) { revert(0, 0) }
            mstore(add(base, 0xc0), sub(p, add(base, ENVELOPE_HEAD))) // params length
            exitCode := EXIT_PRECOMPILE_FAILED
            let ok := delegatecall(gas(), CALL_ACTOR_BY_ID, base, sub(p, base), 0, 0x20)
            if and(ok, gt(returndatasize(), 0x1f)) { exitCode := mload(0) }
        }
    }

    // -------------------------------------------------------------------------
    // SetWeightRecords / StepWeightRecords -- SWA only
    // -------------------------------------------------------------------------

    /// @notice Queues a discretionary weight-schedule write, without reverting on actor error.
    function trySetWeightRecords(WeightRecordUpdate[] memory updates) internal returns (int256 exitCode) {
        return _tryWeightRecords(SET_WEIGHT_RECORDS, updates);
    }

    /// @notice Queues a gate-originated weight-schedule write, without reverting on actor error.
    /// @dev Encodes identically to SetWeightRecords and differs only in dispatch, but the two are
    /// separate calls because f02 treats them differently: a StepWeightRecords write cannot be
    /// cancelled, so the discretionary path cannot revoke what the governance gate produced.
    function tryStepWeightRecords(WeightRecordUpdate[] memory updates) internal returns (int256 exitCode) {
        return _tryWeightRecords(STEP_WEIGHT_RECORDS, updates);
    }

    /// @dev Params CBOR: `[[[id, record], ...]]` -- one array of pairs, inside the single-field
    /// tuple wrapper f02's parameter struct produces.
    function _tryWeightRecords(uint64 method, WeightRecordUpdate[] memory updates) private returns (int256 exitCode) {
        // [[[id, record], ...]]
        (uint256 base, uint256 p) = _begin(method, MAX_HEAD_BYTES + MAX_HEAD_BYTES + updates.length * MAX_UPDATE_BYTES);
        p = _writeArrayHeader(p, 1);
        p = _writeArrayHeader(p, updates.length);
        for (uint256 i = 0; i < updates.length; i++) {
            p = _writeArrayHeader(p, 2);
            p = _writeUint(p, updates[i].id);
            p = _writeRecord(p, updates[i].record);
        }
        return _invoke(base, p);
    }

    /// @notice Queues a discretionary weight-schedule write, reverting on actor error.
    function setWeightRecords(WeightRecordUpdate[] memory updates) internal {
        int256 exitCode = trySetWeightRecords(updates);
        require(exitCode == EXIT_SUCCESS, SetWeightRecordsFailed(exitCode));
    }

    /// @notice Queues a gate-originated weight-schedule write, reverting on actor error.
    function stepWeightRecords(WeightRecordUpdate[] memory updates) internal {
        int256 exitCode = tryStepWeightRecords(updates);
        require(exitCode == EXIT_SUCCESS, StepWeightRecordsFailed(exitCode));
    }

    // -------------------------------------------------------------------------
    // RegisterStream -- SWA only
    // -------------------------------------------------------------------------

    /// @notice Queues a new stream, without reverting on actor error.
    /// @param writer The explicit stream's designated share writer; `address(0)` registers an
    /// implicit stream, whose recipient f02 resolves from protocol state.
    /// @param shares The explicit stream's initial share map; must be empty when implicit.
    /// @dev Params CBOR: `[id, record, distribution|null, activationEpoch]`, where distribution is
    /// `[writer, shares]`. A stream's kind is not a wire field: it is exactly whether the
    /// distribution is present.
    function tryRegisterStream(
        uint64 id,
        WeightRecord memory record,
        address writer,
        Share[] memory shares,
        uint64 activationEpoch
    ) internal returns (int256 exitCode) {
        if (writer == address(0) && shares.length != 0) revert ImplicitStreamWithShares();

        // [id, record, [writer, [[recipient, share], ...]] | null, activationEpoch]
        (uint256 base, uint256 p) = _begin(
            REGISTER_STREAM,
            MAX_HEAD_BYTES + MAX_HEAD_BYTES + MAX_RECORD_BYTES + MAX_HEAD_BYTES + MAX_ADDRESS_BYTES + MAX_HEAD_BYTES
                + shares.length * MAX_SHARE_BYTES + MAX_HEAD_BYTES
        );
        p = _writeArrayHeader(p, 4);
        p = _writeUint(p, id);
        p = _writeRecord(p, record);
        if (writer == address(0)) {
            p = _writeNull(p);
        } else {
            p = _writeArrayHeader(p, 2);
            p = _writeAddress(p, writer);
            p = _writeShares(p, shares);
        }
        p = _writeUint(p, activationEpoch);
        return _invoke(base, p);
    }

    /// @notice Queues a new stream, reverting on actor error.
    function registerStream(
        uint64 id,
        WeightRecord memory record,
        address writer,
        Share[] memory shares,
        uint64 activationEpoch
    ) internal {
        int256 exitCode = tryRegisterStream(id, record, writer, shares, activationEpoch);
        require(exitCode == EXIT_SUCCESS, RegisterStreamFailed(exitCode));
    }

    // -------------------------------------------------------------------------
    // RemoveStream -- SWA only
    // -------------------------------------------------------------------------

    /// @notice Queues a stream removal, without reverting on actor error.
    /// @dev Params CBOR: `[id]`. A single-field parameter tuple is still an array.
    function tryRemoveStream(uint64 id) internal returns (int256 exitCode) {
        // [id]
        (uint256 base, uint256 p) = _begin(REMOVE_STREAM, MAX_HEAD_BYTES + MAX_HEAD_BYTES);
        p = _writeArrayHeader(p, 1);
        p = _writeUint(p, id);
        return _invoke(base, p);
    }

    /// @notice Queues a stream removal, reverting on actor error.
    function removeStream(uint64 id) internal {
        int256 exitCode = tryRemoveStream(id);
        require(exitCode == EXIT_SUCCESS, RemoveStreamFailed(exitCode));
    }

    // -------------------------------------------------------------------------
    // SetDistribution -- SWA only
    // -------------------------------------------------------------------------

    /// @notice Queues a change of an explicit stream's designated writer, without reverting.
    /// @dev Params CBOR: `[id, writer]`. Only the writer changes; a stream's kind is fixed at
    /// registration.
    function trySetDistribution(uint64 id, address writer) internal returns (int256 exitCode) {
        // [id, writer]
        (uint256 base, uint256 p) = _begin(SET_DISTRIBUTION, MAX_HEAD_BYTES + MAX_HEAD_BYTES + MAX_ADDRESS_BYTES);
        p = _writeArrayHeader(p, 2);
        p = _writeUint(p, id);
        p = _writeAddress(p, writer);
        return _invoke(base, p);
    }

    /// @notice Queues a change of an explicit stream's designated writer, reverting on error.
    function setDistribution(uint64 id, address writer) internal {
        int256 exitCode = trySetDistribution(id, writer);
        require(exitCode == EXIT_SUCCESS, SetDistributionFailed(exitCode));
    }

    // -------------------------------------------------------------------------
    // CancelPending -- SWA only
    // -------------------------------------------------------------------------

    /// @notice Cancels a queued write, without reverting on actor error.
    /// @dev Params CBOR: `[id|null, op]`. The two weight operations occupy one schedule-wide slot
    /// each and carry no id, so they are addressed with a null; every other operation is per
    /// stream and carries its id.
    function tryCancelPendingWeight(PendingOp op) internal returns (int256 exitCode) {
        // [null, op]
        (uint256 base, uint256 p) = _begin(CANCEL_PENDING, MAX_HEAD_BYTES + NULL_BYTES + MAX_HEAD_BYTES);
        p = _writeArrayHeader(p, 2);
        p = _writeNull(p);
        p = _writeUint(p, uint256(op));
        return _invoke(base, p);
    }

    /// @notice Cancels a queued per-stream write, without reverting on actor error.
    function tryCancelPending(uint64 id, PendingOp op) internal returns (int256 exitCode) {
        // [id, op]
        (uint256 base, uint256 p) = _begin(CANCEL_PENDING, MAX_HEAD_BYTES + MAX_HEAD_BYTES + MAX_HEAD_BYTES);
        p = _writeArrayHeader(p, 2);
        p = _writeUint(p, id);
        p = _writeUint(p, uint256(op));
        return _invoke(base, p);
    }

    /// @notice Cancels a queued schedule-wide weight write, reverting on actor error.
    function cancelPendingWeight(PendingOp op) internal {
        int256 exitCode = tryCancelPendingWeight(op);
        require(exitCode == EXIT_SUCCESS, CancelPendingFailed(exitCode));
    }

    /// @notice Cancels a queued per-stream write, reverting on actor error.
    function cancelPending(uint64 id, PendingOp op) internal {
        int256 exitCode = tryCancelPending(id, op);
        require(exitCode == EXIT_SUCCESS, CancelPendingFailed(exitCode));
    }

    // -------------------------------------------------------------------------
    // SetShares -- the stream's designated writer only
    // -------------------------------------------------------------------------

    /// @notice Installs an explicit stream's share map, without reverting on actor error.
    /// @dev Params CBOR: `[id, [[recipient, share], ...]]`.
    function trySetShares(uint64 id, Share[] memory shares) internal returns (int256 exitCode) {
        // [id, [[recipient, share], ...]]
        (uint256 base, uint256 p) =
            _begin(SET_SHARES, MAX_HEAD_BYTES + MAX_HEAD_BYTES + MAX_HEAD_BYTES + shares.length * MAX_SHARE_BYTES);
        p = _writeArrayHeader(p, 2);
        p = _writeUint(p, id);
        p = _writeShares(p, shares);
        return _invoke(base, p);
    }

    /// @notice Installs an explicit stream's share map, reverting on actor error.
    function setShares(uint64 id, Share[] memory shares) internal {
        int256 exitCode = trySetShares(id, shares);
        require(exitCode == EXIT_SUCCESS, SetSharesFailed(exitCode));
    }

    // -------------------------------------------------------------------------
    // Claim -- permissionless
    // -------------------------------------------------------------------------

    /// @notice Claims for a batch of wallets, without reverting on actor error.
    /// @dev Params CBOR: `[id, [wallet, ...]]`. Return CBOR: `[[amount, ...]]`, one positional
    /// entry per wallet, each a Filecoin BigInt byte string. An unknown wallet is not an error; it
    /// returns zero in its position.
    function tryClaim(uint64 id, address[] memory wallets)
        internal
        returns (int256 exitCode, uint256[] memory amounts)
    {
        // [id, [wallet, ...]]
        (uint256 base, uint256 p) =
            _begin(CLAIM, MAX_HEAD_BYTES + MAX_HEAD_BYTES + MAX_HEAD_BYTES + wallets.length * MAX_ADDRESS_BYTES);
        p = _writeArrayHeader(p, 2);
        p = _writeUint(p, id);
        p = _writeArrayHeader(p, wallets.length);
        for (uint256 i = 0; i < wallets.length; i++) {
            p = _writeAddress(p, wallets[i]);
        }

        exitCode = _invoke(base, p);
        amounts = exitCode == EXIT_SUCCESS ? _decodeAmounts() : new uint256[](0);
    }

    /// @notice Claims for a batch of wallets, reverting on actor error.
    function claim(uint64 id, address[] memory wallets) internal returns (uint256[] memory amounts) {
        int256 exitCode;
        (exitCode, amounts) = tryClaim(id, wallets);
        require(exitCode == EXIT_SUCCESS, ClaimFailed(exitCode));
    }

    /// @dev Reads `[[amount, ...]]` out of returndata. Layout is exitCode, codec, bytes offset,
    /// bytes length, then the CBOR payload at 0x80.
    function _decodeAmounts() private pure returns (uint256[] memory amounts) {
        uint256 payloadLen;
        assembly ("memory-safe") {
            payloadLen := 0
            if gt(returndatasize(), 0x80) { payloadLen := sub(returndatasize(), 0x80) }
        }
        if (payloadLen == 0) return new uint256[](0);

        uint256 scratch;
        assembly ("memory-safe") {
            scratch := mload(0x40)
            mstore(0x40, add(scratch, and(add(payloadLen, 31), not(31))))
            returndatacopy(scratch, 0x80, payloadLen)
        }

        // ClaimReturn is a single-field tuple: the amounts array is wrapped in a 1-element array.
        (, uint256 cur) = _readHead(scratch);
        uint256 count;
        (count, cur) = _readHead(cur);
        amounts = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            uint256 len;
            (len, cur) = _readHead(cur);
            amounts[i] = _readBigInt(cur, len);
            cur += len;
        }
    }

    /// @dev Reads a CBOR head, returning its argument and the cursor past it. The major type is
    /// not returned: every head this decoder meets is positionally determined.
    function _readHead(uint256 p) private pure returns (uint256 value, uint256 next) {
        assembly ("memory-safe") {
            let info := and(byte(0, mload(p)), 0x1f)
            switch lt(info, 24)
            case 1 {
                value := info
                next := add(p, 1)
            }
            default {
                switch info
                case 24 {
                    value := byte(0, mload(add(p, 1)))
                    next := add(p, 2)
                }
                case 25 {
                    value := shr(240, mload(add(p, 1)))
                    next := add(p, 3)
                }
                case 26 {
                    value := shr(224, mload(add(p, 1)))
                    next := add(p, 5)
                }
                default {
                    value := shr(192, mload(add(p, 1)))
                    next := add(p, 9)
                }
            }
        }
    }

    /// @dev A Filecoin BigInt: an empty byte string is zero, otherwise a sign byte followed by a
    /// big-endian magnitude. An entitlement is never negative and never exceeds a uint256.
    function _readBigInt(uint256 p, uint256 len) private pure returns (uint256 value) {
        if (len == 0) return 0;
        assembly ("memory-safe") {
            let signByte := byte(0, mload(p))
            let magLen := sub(len, 1)
            if or(signByte, gt(magLen, 32)) { revert(0, 0) }
            if magLen { value := shr(shl(3, sub(32, magLen)), mload(add(p, 1))) }
        }
    }
}
