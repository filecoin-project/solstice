// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

// FRC-0042 method numbers (first 4 bytes of blake2b-512("1|" + MethodName), rejection-sampled
// above 1<<24) for the f02 (Reward actor) stream-splitting methods; defined here so
// solstice's contracts and this mock agree on the same numbers.
uint64 constant SET_WEIGHT_RECORDS = 3362570548;
uint64 constant STEP_WEIGHT_RECORDS = 3951753085;
uint64 constant SET_SHARES = 2414422607;
uint64 constant GET_STATE = 1397113977;
uint64 constant REGISTER_STREAM = 386660827;
uint64 constant REMOVE_STREAM = 1623858416;
uint64 constant SET_DISTRIBUTION = 3872725033;
uint64 constant CANCEL_PENDING = 187585191;
uint64 constant CLAIM = 4045527845;

/// @dev The activation timelock SWA writes to f02 are queued under: the mainnet default,
/// 7 days in epochs (30s/epoch). Also exposed as mutable state (`swaTimelockEpochs`) since
/// it's migration-set per network.
uint64 constant SWA_TIMELOCK = 20160;
