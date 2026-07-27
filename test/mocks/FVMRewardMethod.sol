// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

// FRC-0042 method numbers (first 4 bytes of blake2b-512("1|" + MethodName), rejection-sampled
// above 1<<24) for the new f02 (Reward actor) methods proposed by draft FIP-0118
// (https://github.com/filecoin-project/FIPs/pull/1270) and tracked in
// https://github.com/filecoin-project/builtin-actors/issues/1764. Not yet implemented in
// builtin-actors; defined here so solstice's contracts and this mock agree on the same
// method numbers ahead of the real actor shipping them.
uint64 constant SET_WEIGHT_RECORDS = 3362570548;
uint64 constant SET_SHARES = 2414422607;
uint64 constant GET_STATE = 1397113977;
uint64 constant REGISTER_STREAM = 386660827;
uint64 constant REMOVE_STREAM = 1623858416;
uint64 constant SET_DISTRIBUTION = 3872725033;
uint64 constant CANCEL_PENDING = 187585191;
uint64 constant COMPUTE_WEIGHT = 2393050123;

/// @dev FIP-0118 section 2.4: the activation timelock the SWA's writes to f02 are queued
/// under, equal to the Section 4 objection window (7 days), in epochs (30s/epoch).
uint64 constant SWA_TIMELOCK = 20160;
