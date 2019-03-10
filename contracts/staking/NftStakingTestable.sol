// SPDX-License-Identifier: MIT

pragma solidity ^0.6.8;

import "./NftStaking.sol";

abstract contract NftStakingTestable is NftStaking {

    constructor(
        uint256 cycleLength_,
        uint256 payoutPeriodLength_,
        uint256 freezeDurationAfterStake_,
        address whitelistedNftContract_,
        address dividendToken_
    ) NftStaking(
        cycleLength_,
        payoutPeriodLength_,
        freezeDurationAfterStake_,
        whitelistedNftContract_,
        dividendToken_
    ) public {}

    function getLatestSnapshot()
    public
    view
    returns(
        uint32 startCycle,
        uint32 endCycle,
        uint64 stakedWeight
    )
    {
        DividendsSnapshot memory snapshot;

        if (dividendsSnapshots.length != 0) {
            snapshot = dividendsSnapshots[dividendsSnapshots.length - 1];
        }

        return (
            snapshot.startCycle,
            snapshot.endCycle,
            snapshot.stakedWeight
        );
    }

    function dividendsSnapshot(uint32 targetCycle)
    public
    view
    returns(
        uint32 startCycle,
        uint32 endCycle,
        uint64 stakedWeight,
        uint256 snapshotIndex
    )
    {
        DividendsSnapshot memory snapshot;
        (snapshot, snapshotIndex) = _findDividendsSnapshot(targetCycle);
        return (
            snapshot.startCycle,
            snapshot.endCycle,
            snapshot.stakedWeight,
            snapshotIndex
        );
    }

    function totalSnapshots() public view returns(uint256) {
        return dividendsSnapshots.length;
    }

    function getOrCreateSnapshot() public returns(
        uint256 period,
        uint32 startCycle,
        uint32 endCycle,
        uint64 stakedWeight
    ) {
        _updateSnapshots(0);
        uint256 snapshotIndex = dividendsSnapshots.length - 1;
        DividendsSnapshot memory snapshot = dividendsSnapshots[snapshotIndex];

        period = snapshot.period;
        startCycle = snapshot.startCycle;
        endCycle = snapshot.endCycle;
        stakedWeight = snapshot.stakedWeight;
    }

    function currentPayoutPeriod() public view returns(uint256) {
        StakerState memory state = stakerStates[msg.sender];
        if (state.stakedWeight == 0) {
            return 0;
        }

        return _getPeriod(state.nextUnclaimedPeriodStartCycle, periodLengthInCycles);
    }
}
