// SPDX-License-Identifier: MIT

pragma solidity ^0.6.8;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/SafeCast.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@animoca/ethereum-contracts-erc20_base/contracts/token/ERC20/IERC20.sol";
import "@animoca/ethereum-contracts-assets_inventory/contracts/token/ERC721/IERC721.sol";
import "@animoca/ethereum-contracts-assets_inventory/contracts/token/ERC1155/IERC1155.sol";
import "@animoca/ethereum-contracts-assets_inventory/contracts/token/ERC1155/ERC1155TokenReceiver.sol";

abstract contract NftStaking is ERC1155TokenReceiver, Ownable {

    using SafeMath for uint256;
    using SafeCast for uint256;

    uint40 internal constant _DIVS_PRECISION = 10 ** 10; // used to preserve significant figures in floating point calculations

    event RewardScheduleSet(
        uint256 startPeriod,
        uint256 endPeriod,
        uint256 rewardPerCycle
    );

    event NftStaked(
        address staker,
        uint256 tokenId,
        uint256 cycle
    );

    event NftUnstaked(
        address staker,
        uint256 tokenId,
        uint256 cycle
    );

    event RewardsClaimed(
        address staker,
        uint256 snapshotStartIndex,
        uint256 snapshotEndIndex,
        uint256 amount
    );

    event SnapshotUpdated(
        uint256 index,
        uint256 startCycle,
        uint256 endCycle,
        uint256 totalStake
    );

    // used to track the history of changes in the total stake by
    // ranges of cycles. The range cannot extend over several periods.
    // optimised for usage in storage
    struct Snapshot {
        uint16 period; // the period in which the snapshot is contained
        uint16 startCycle; // MUST be inside the period
        uint16 endCycle; // MUST be inside the period
        uint64 totalStake;
    }

    // used to track a staker's state.
    // optimised for usage in storage
    struct StakerState {
        uint64 stake; // sum of the weights of the tokens staked by this staker
        uint16 nextClaimablePeriod;
        uint128 nextClaimableSnapshotIndex;
    }

    // used to track an NFTs staking state.
    // optimised for usage in storage
    struct TokenInfo {
        address owner;
        uint64 weight;
        uint16 depositCycle;
    }

    // used as a container to hold result values from calculating claimable rewards.
    // to be used in memory only, not optimised for storage
    struct CalculateRewardsResult {
        uint256 claimableRewards;
        uint256 startSnapshotIndex;
        uint256 endSnapshotIndex;
        uint16 computedPeriods;
    }

    uint256 public startTimestamp = 0; // starting timestamp of the staking schedule, in seconds since epoch
    uint256 public rewardPool = 0; // reward pool amount to be distributed over the entire schedule

    bool public disabled = false;

    address public immutable whitelistedNftContract; // ERC1155-compliant NFT contract from which staking is accepted.
    address public immutable rewardsToken; // ERC20-compliant contract used as staking rewards

    uint32 public immutable cycleLengthInSeconds;
    uint16 public immutable periodLengthInCycles;
    uint16 public immutable freezeLengthInCycles; // duration for which a newly staked NFT is locked before it can be unstaked

    mapping(address /* staker */ => StakerState) public stakerStates;
    mapping(uint256 /* tokenId */ => TokenInfo) public tokenInfos;
    mapping(uint256 /* period */ => uint256 /* rewards per-cycle */) public rewardSchedule;

    Snapshot[] public snapshots; // history of total stake by ranges of cycles within a single period

    // This modifier MUST be applied on any function which modifies a staker's stake
    // For optimisation purpose, rewards are calculated with the assumption that the
    // current staker's stake is up to date and didn't change since the last claim
    modifier rewardsClaimed(address sender) {
        require(_getClaimablePeriods(sender, periodLengthInCycles) == 0, "NftStaking: Rewards are not claimed");
        _;
    }

    modifier hasStarted() {
        require(startTimestamp != 0, "NftStaking: Staking has not started yet");
        _;
    }

    modifier isEnabled() {
        require(!disabled, "NftStaking: Staking operations are disabled");
        _;
    }

    /**
     * Constructor.
     * @dev Reverts if the period length value is zero.
     * @dev Reverts if the cycle length value is zero.
     * @param cycleLengthInSeconds_ Length of a cycle, in seconds.
     * @param periodLengthInCycles_ Length of a period, in cycles.
     * @param freezeLengthInCycles_ Initial number of cycles during which a newly staked NFT is locked for before it can be unstaked.
     * @param whitelistedNftContract_ ERC1155-based contract to be whitelisted for performing transfer operations of NFTs for staking/unstaking.
     * @param rewardsToken_ ERC20-based token used as staking rewards.
     */
    constructor(
        uint32 cycleLengthInSeconds_,
        uint16 periodLengthInCycles_,
        uint16 freezeLengthInCycles_,
        address whitelistedNftContract_,
        address rewardsToken_
    ) internal {
        require(cycleLengthInSeconds_ >= 1 minutes, "NftStaking: Cycles must be at least one minute");
        require(periodLengthInCycles_ >= 2, "NftStaking: Periods must be at least 2 cycles long");

        cycleLengthInSeconds = cycleLengthInSeconds_;
        periodLengthInCycles = periodLengthInCycles_;
        freezeLengthInCycles = freezeLengthInCycles_;
        whitelistedNftContract = whitelistedNftContract_;
        rewardsToken = rewardsToken_;
    }


/////////////////////////////////// Admin Public Functions ////////////////////////////////////////

    /**
     * Set the rewards for a range of periods.
     * @dev Reverts if the start or end periods are zero.
     * @dev Reverts if the end period is before the start period.
     * @dev Emits the RewardSet event when the function is called successfully.
     * @param startPeriod The starting period (inclusive).
     * @param endPeriod The ending period (inclusive).
     * @param rewardPerCycle The reward for each cycle within range.
     */
    function setRewardsForPeriods(
        uint16 startPeriod,
        uint16 endPeriod,
        uint256 rewardPerCycle
    ) public onlyOwner {
        require(startPeriod != 0 && startPeriod <= endPeriod, "NftStaking: Wrong period range");

        for (uint16 period = startPeriod; period <= endPeriod; ++period) {
            rewardSchedule[period] = rewardPerCycle;
        }

        uint256 reward = rewardPerCycle;
        reward = reward.mul(periodLengthInCycles);
        reward = reward.mul(endPeriod - startPeriod + 1);

        rewardPool = rewardPool.add(reward);

        emit RewardScheduleSet(startPeriod, endPeriod, rewardPerCycle);
    }

    /**
     * Transfers necessary reward balance to the contract from the reward token contract,
     * and begins running the staking schedule.
     */
    function start() public onlyOwner {
        require(
            IERC20(rewardsToken).transferFrom(msg.sender, address(this), rewardPool),
            "NftStaking: Failed to transfer the total reward"
        );

        startTimestamp = now;
    }

    /**
     * Withdraws a specified amount of rewards tokens from the contract.
     * @param amount The amount to withdraw.
     */
    function withdrawRewardsPool(uint256 amount) public onlyOwner {
        require(
            IERC20(rewardsToken).transfer(msg.sender, amount),
            "NftStaking: Failed to withdraw from the rewards pool"
        );
    }

    /**
     * Permanently disables all staking and claiming functionality of the contract.
     */
    function disable() public onlyOwner {
        disabled = true;
    }


////////////////////////////////////// ERC1155TokenReceiver ///////////////////////////////////////

    function onERC1155Received(
        address /*operator*/,
        address from,
        uint256 id,
        uint256 /*value*/,
        bytes calldata /*data*/
    )
    external
    virtual
    override
    returns (bytes4)
    {
        _stakeNft(id, from);
        return _ERC1155_RECEIVED;
    }

    function onERC1155BatchReceived(
        address /*operator*/,
        address from,
        uint256[] calldata ids,
        uint256[] calldata /*values*/,
        bytes calldata /*data*/
    )
    external
    virtual
    override
    returns (bytes4)
    {
        for (uint256 i = 0; i < ids.length; ++i) {
            _stakeNft(ids[i], from);
        }
        return _ERC1155_BATCH_RECEIVED;
    }


//////////////////////////////////// Staking Public Functions /////////////////////////////////////

    /**
     * Unstakes a deposited NFT from the contract.
     * @dev Reverts if the caller is not the original owner of the NFT.
     * @dev While the contract is enabled, reverts if there are outstanding rewards to be claimed.
     * @dev While the contract is enabled, reverts if NFT is being unstaked before the staking freeze duration has elapsed.
     * @dev While the contract is enabled, creates any missing snapshots, up-to the current cycle.
     * @dev Emits the NftUnstaked event when the function is called successfully.
     * @dev May emit the SnapshotUpdated event if any snapshots are created or modified to ensure that snapshots exist, up-to the current cycle.
     * @param tokenId The token identifier, referencing the NFT being unstaked.
     */
    function unstakeNft(uint256 tokenId) external virtual {
        TokenInfo memory tokenInfo = tokenInfos[tokenId];

        require(tokenInfo.owner == msg.sender, "NftStaking: Incorrect token owner or token already unstaked");

        uint16 currentCycle = _getCycle(now);

        // by-pass operations if the contract is disabled, to avoid unnecessary calculations and
        // reduce the gas requirements for the caller
        if (!disabled) {
            uint16 periodLengthInCycles_ = periodLengthInCycles;

            require(_getClaimablePeriods (msg.sender, periodLengthInCycles_) == 0, "NftStaking: Rewards are not claimed");
            require(currentCycle - tokenInfo.depositCycle >= freezeLengthInCycles, "NftStaking: Token is still frozen");

            ensureSnapshots(0);

            uint256 snapshotIndex = snapshots.length - 1;
            Snapshot memory snapshot = snapshots[snapshotIndex];

            // decrease the latest snapshot's stake
            _updateSnapshotStake(
                snapshot,
                snapshotIndex,
                snapshot.totalStake - tokenInfo.weight,
                currentCycle);

            // clear the token owner to ensure that it cannot be unstaked again
            // without being re-staked
            tokenInfos[tokenId].owner = address(0);

            // decrease the staker's stake
            StakerState memory stakerState = stakerStates[msg.sender];
            stakerState.stake -= tokenInfo.weight;

            // nothing is currently staked by the staker
            if (stakerState.stake == 0) {
                // clear the next claimable period and next claimable snapshot
                // index
                stakerState.nextClaimableSnapshotIndex = 0;
                stakerState.nextClaimablePeriod = 0;
            }

            stakerStates[msg.sender] = stakerState;
        }

        try IERC1155(whitelistedNftContract).safeTransferFrom(address(this), msg.sender, tokenId, 1, "") {
        } catch Error(string memory /*reason*/) {
            // This is executed in case evert was called inside
            // getData and a reason string was provided.

            // attempting a non-safe transferFrom() of the token in the case
            // that the failure was caused by a ethereum client wallet
            // implementation that does not support safeTransferFrom()
            IERC721(whitelistedNftContract).transferFrom(address(this), msg.sender, tokenId);
        } catch (bytes memory /*lowLevelData*/) {
            // This is executed in case revert() was used or there was
            // a failing assertion, division by zero, etc. inside getData.

            // attempting a non-safe transferFrom() of the token in the case
            // that the failure was caused by a ethereum client wallet
            // implementation that does not support safeTransferFrom()
            IERC721(whitelistedNftContract).transferFrom(address(this), msg.sender, tokenId);
        }

        emit NftUnstaked(msg.sender, tokenId, currentCycle);
    }

    /**
     * Estimates the claimable rewards for the specified number of periods.
     * @param maxPeriods The maximum number of claimable periods to calculate for.
     * @return claimableRewards The total claimable rewards.
     * @return claimablePeriods The actual number of claimable periods calculated for.
     */
    function estimateRewards(uint16 maxPeriods) external view isEnabled hasStarted returns (
        uint256 claimableRewards,
        uint16 claimablePeriods
    ) {
        // estimating for 0 periods
        if (maxPeriods == 0) {
            return (0, 0);
        }

        // calculate the claimable rewards
        CalculateRewardsResult memory result =
            _calculateRewards(msg.sender, maxPeriods, true);

        claimableRewards = result.claimableRewards;
        claimablePeriods = result.computedPeriods;
    }

    /**
     * Claims the rewards for the specified number of periods.
     * @dev Creates any missing snapshots, up-to the current cycle.
     * @dev Emits the RewardsClaimed event when the function is called successfully.
     * @dev May emit the SnapshotUpdated event if any snapshots are created or modified to ensure that snapshots exist, up-to the current cycle.
     * @param maxPeriods The maximum number of periods to claim for.
     */
    function claimRewards(uint16 maxPeriods) external isEnabled hasStarted {
        // claiming for 0 periods
        if (maxPeriods == 0) {
            return;
        }

        // ensure that snapshots exist up-to the current cycle/period
        ensureSnapshots(0);

        // calculate the claimable rewards
        CalculateRewardsResult memory result =
            _calculateRewards(msg.sender, maxPeriods, false);

        // no periods were actually processed when calculating the rewards to
        // claim (i.e. no net changes were made to the current state since
        // before _calculateRewards() was called)
        if (result.computedPeriods == 0) {
            return;
        }

        // update the staker's next claimable period and next claimable snapshot
        // index, for each call of this function. this should be done even when
        // no rewards to claim were found, to save from reprocessing fruitless
        // periods in subsequent calls
        StakerState memory stakerState = stakerStates[msg.sender];
        stakerState.nextClaimableSnapshotIndex = (result.endSnapshotIndex + 1).toUint128();
        stakerState.nextClaimablePeriod += result.computedPeriods;
        stakerStates[msg.sender] = stakerState;

        // no rewards to claim were found across the processed periods
        if (result.claimableRewards == 0) {
            return;
        }

        require(
            IERC20(rewardsToken).transfer(msg.sender, result.claimableRewards),
            "NftStaking: Failed to transfer claimed rewards");

        emit RewardsClaimed(
            msg.sender,
            result.startSnapshotIndex,
            result.endSnapshotIndex,
            result.claimableRewards);
    }

    /**
     * Retrieves the first claimable period (index-1 based) and number of claimable periods.
     * @return nextClaimablePeriod The first claimable period (index-1 based).
     * @return claimablePeriods The number of claimable periods.
     */
    function getClaimablePeriods() external view returns (
        uint16 nextClaimablePeriod,
        uint16 claimablePeriods
    ) {
        StakerState memory stakerState = stakerStates[msg.sender];

        if (stakerState.stake == 0) {
            return (0, 0);
        }

        return (
            stakerState.nextClaimablePeriod,
            _getClaimablePeriods (msg.sender, periodLengthInCycles)
        );
    }


//////////////////////////////////// Utility Public Functions /////////////////////////////////////

    /**
     * Retrieves the current cycle (index-1 based).
     * @return The current cycle (index-1 based).
     */
    function getCurrentCycle() external view returns (uint16) {
        // index is 1 based
        return _getCycle(now);
    }

    /**
     * Retrieves the current period (index-1 based).
     * @return The current period (index-1 based).
     */
    function getCurrentPeriod() external view returns (uint16) {
        return _getCurrentPeriod(periodLengthInCycles);
    }

    /**
     * Retrieves the last snapshot index, if any.
     * @return The last snapshot index, or throws if there are no snapshots.
     */
    function lastSnapshotIndex() external view returns (uint256) {
        uint256 length = snapshots.length;
        require(length > 0, "NftStaking: no snapshots yet");
        return length - 1;
    }

    /**
     * Ensures that the snapshot history is up-to-date to the current cycle.
     * @dev If the latest snapshot is related to a past period, it creates a snapshot for each missing period and one for the current period (if needed).
     * @dev Updates the latest snapshot to end on current cycle if not already.
     * @dev May emit the SnapshotUpdated event if any snapshots are created or modified to ensure that snapshots exist, up-to the current cycle.
     * @param maxSnapshotsToAdd the limit of snapshots to create. No limit will be applied if it equals zero.
     */
    function ensureSnapshots(uint256 maxSnapshotsToAdd) public {
        uint16 periodLengthInCycles_ = periodLengthInCycles;
        uint16 currentCycle = _getCycle(now);
        uint16 currentPeriod = _getPeriod(currentCycle, periodLengthInCycles_);
        uint256 totalSnapshots = snapshots.length;

        // no snapshots currently exist
        if (totalSnapshots == 0) {
            // create the initial snapshot, starting at the current cycle
            _addNewSnapshot(currentPeriod, currentCycle, currentCycle, 0);
            return;
        }

        uint256 snapshotIndex = totalSnapshots - 1;

        // get the latest snapshot
        Snapshot memory snapshot = snapshots[snapshotIndex];

        // latest snapshot ends on the current cycle
        if (snapshot.endCycle == currentCycle) {
            // nothing to do
            return;
        }

        // determine the assignment based on whether or not the latest snapshot
        // is in the current period
        uint16 snapshotPeriodEndCycle =
            snapshot.period == currentPeriod ?
                currentCycle :
                SafeMath.mul(snapshot.period, periodLengthInCycles_).toUint16();

        // extend the latest snapshot to cover all of the missing cycles for its
        // period
        snapshots[snapshotIndex].endCycle = snapshotPeriodEndCycle;
        snapshot.endCycle = snapshotPeriodEndCycle;

        emit SnapshotUpdated(
                snapshotIndex,
                snapshot.startCycle,
                snapshot.endCycle,
                snapshot.totalStake);

        // latest snapshot was for the current period
        if (snapshot.period == currentPeriod) {
            // we are done
            return;
        }

        // latest snapshot is in an earlier period

        uint16 previousPeriod = currentPeriod - 1;
        bool hasAddNewSnapshotLimit = maxSnapshotsToAdd != 0;

        // while there are unaccounted-for periods...
        while (snapshot.period < previousPeriod) {
            // maximum snapshots to add has been reached
            if (hasAddNewSnapshotLimit && (--maxSnapshotsToAdd == 0)) {
                // break out of loop to add the last snapshot for the current period
                break;
            }

            // create an interstitial snapshot that spans the unaccounted-for
            // period, initialized with the staked weight of the previous
            // snapshot
            (snapshot, snapshotIndex) = _addNewSnapshot(
                snapshot.period + 1,
                snapshot.endCycle + 1,
                snapshot.endCycle + periodLengthInCycles_,
                snapshot.totalStake);
        }

        // create the new latest snapshot for the current period and cycle,
        // initialized with the staked weight from the previous snapshot
        _addNewSnapshot(
            snapshot.period + 1,
            snapshot.endCycle + 1,
            currentCycle,
            snapshot.totalStake);
    }


/////////////////////////////////// Staking Internal Functions ////////////////////////////////////

    /**
     * Stakes the NFT received by the contract, referenced by its specified token identifier and owner.
     * @dev Reverts if the caller is not the whitelisted NFT contract.
     * @dev Creates any missing snapshots, up-to the current cycle.
     * @dev May emit the SnapshotUpdated event if any snapshots are created or modified to ensure that snapshots exist, up-to the current cycle.
     * @dev Emits the NftStaked event when the function is called successfully.
     * @param tokenId Identifier of the staked NFT.
     * @param tokenOwner Owner of the staked NFT.
     */
    function _stakeNft(
        uint256 tokenId,
        address tokenOwner
    ) internal isEnabled hasStarted rewardsClaimed(tokenOwner) {
        require(whitelistedNftContract == msg.sender, "NftStaking: Caller is not the whitelisted NFT contract");

        uint64 weight = _validateAndGetWeight(tokenId);

        ensureSnapshots(0);

        uint16 currentCycle = _getCycle(now);
        uint256 snapshotIndex = snapshots.length - 1;
        Snapshot memory snapshot = snapshots[snapshotIndex];

        // increase the latest snapshot's stake
        _updateSnapshotStake(
            snapshot,
            snapshotIndex,
            SafeMath.add(snapshot.totalStake, weight).toUint64(),
            currentCycle);

        // set the staked token's info
        TokenInfo memory tokenInfo;
        tokenInfo.depositCycle = currentCycle;
        tokenInfo.owner = tokenOwner;
        tokenInfo.weight = weight;
        tokenInfos[tokenId] = tokenInfo;

        StakerState memory stakerState = stakerStates[tokenOwner];

        if (stakerState.stake == 0) {
            // nothing is currently staked by the staker so reset/initialize
            // the next claimable period and next claimable snapshot index to
            // the current cycle for claimable period tracking
            stakerState.nextClaimableSnapshotIndex = snapshotIndex.toUint128();
            stakerState.nextClaimablePeriod = snapshot.period;
        }

        // increase the staker's stake
        stakerState.stake = SafeMath.add(stakerState.stake, weight).toUint64();
        stakerStates[tokenOwner] = stakerState;

        emit NftStaked(tokenOwner, tokenId, currentCycle);
    }

    /**
     * Calculates the amount of rewards over the available claimable periods
     * @dev Processes until the specified maximum number of periods to claim is reached, or the last processable period is reached (the current period for a claim estimate, or the last snapshot period for an actual claim), whichever occurs first.
     * @param staker The staker for whom the rewards will be calculated.
     * @param periodsToClaim Maximum number of periods, over which to calculate the claimable rewards.
     * @param estimate Flags whether or not the calculation is for a reward claim estimate, or for an actual claim.
     * @return CalculateRewardsResult result containing the amount of claimable rewards, the starting and ending snapshot indices over which the calculation was performed, and the number of actual periods processed in the calculation.
     */
    function _calculateRewards(
        address staker,
        uint16 periodsToClaim,
        bool estimate
    ) internal view returns (CalculateRewardsResult memory)
    {
        CalculateRewardsResult memory result;

        // calculating for 0 periods
        if (periodsToClaim == 0) {
            return result;
        }

        uint256 totalSnapshots = snapshots.length;

        // no snapshots to calculate with
        if (totalSnapshots == 0) {
            return result;
        }

        StakerState memory stakerState = stakerStates[staker];

        // nothing staked to calculate with
        if (stakerState.stake == 0) {
            return result;
        }

        uint16 periodLengthInCycles_ = periodLengthInCycles;
        uint16 periodToClaim = stakerState.nextClaimablePeriod;
        uint16 currentPeriod = _getCurrentPeriod(periodLengthInCycles_);
        uint256 lastSnapshotIndex_ = totalSnapshots - 1;
        uint16 lastSnapshotPeriod = snapshots[lastSnapshotIndex_].period;

        // the current period has been reached (claim estimate), or the last
        // snapshot period has been reached (actual claim)
        if ((estimate && (periodToClaim  == currentPeriod)) ||
            (!estimate && (periodToClaim == lastSnapshotPeriod))) {
            return result;
        }

        uint256 rewardPerCycle = rewardSchedule[periodToClaim];
        uint16 periodToClaimEndCycle = SafeMath.mul(periodToClaim, periodLengthInCycles_).toUint16();

        uint256 snapshotIndex = uint256(stakerState.nextClaimableSnapshotIndex);
        Snapshot memory snapshot = snapshots[snapshotIndex];

        // for a claim estimate, the last snapshot period is not the current
        // period and does not align with the end of its period
        if (estimate &&
            (snapshotIndex == lastSnapshotIndex_) &&
            (snapshot.period != currentPeriod) &&
            (snapshot.endCycle != periodToClaimEndCycle)) {
            // extend the last snapshot cycle range to align with the end of its
            // period
            snapshot.endCycle = periodToClaimEndCycle;
        }

        result.startSnapshotIndex = snapshotIndex;

        // iterate over snapshots one by one until either the specified maximum
        // number of periods to claim is reached, or the last processable
        // period is reached (the current period for a claim estimate, or the
        // last snapshot period for an actual claim), whichever occurs first.
        // this loop assumes that (1) there is at least one snapshot within each
        // period, (2) snapshots are aligned back-to-back, (3) each period is
        // spanned by snapshots (i.e. no cycle gaps), (4) snapshots do not span
        // across multiple periods (i.e. bound within a single period), and (5)
        // that it will be executed for at least 1 iteration
        while (true) {
            // there are rewards to calculate in this loop iteration
            if ((snapshot.totalStake != 0) && (rewardPerCycle != 0)) {
                // calculate the staker's snapshot rewards
                uint256 rewardsToClaim = snapshot.endCycle - snapshot.startCycle + 1;
                rewardsToClaim *= stakerState.stake;
                rewardsToClaim *= _DIVS_PRECISION;
                rewardsToClaim = rewardsToClaim.mul(rewardPerCycle);
                rewardsToClaim /= snapshot.totalStake;
                rewardsToClaim /= _DIVS_PRECISION;

                // update the total rewards to claim
                result.claimableRewards = result.claimableRewards.add(rewardsToClaim);
            }

            // snapshot is the last one in the period to claim
            if (snapshot.endCycle == periodToClaimEndCycle) {
                ++periodToClaim;
                ++result.computedPeriods;

                // the specified maximum number of periods to claim is reached,
                // or the last processable period is reached (the current period
                // for a claim estimate, or the last snapshot period for an
                // actual claim)
                if ((periodsToClaim == result.computedPeriods) ||
                    (estimate && (periodToClaim  == currentPeriod)) ||
                    (!estimate && (periodToClaim == lastSnapshotPeriod))) {
                    break;
                }

                // advance the period state for the next loop iteration
                rewardPerCycle = rewardSchedule[periodToClaim];
                periodToClaimEndCycle = SafeMath.add(periodToClaimEndCycle, periodLengthInCycles_).toUint16();
            }

            // still have individual snapshots to process. once there are no
            // more, in the case of a claim estimate, assume the same snapshot
            // properties (excluding cycle range bounds) as the last snapshot,
            // for any subsequent periods to claim that do not have any
            // snapshots
            if (snapshotIndex < lastSnapshotIndex_) {
                // advance the snapshot for the next loop iteration
                ++snapshotIndex;
                snapshot = snapshots[snapshotIndex];
            }

            // for a claim estimate, the last snapshot has been reached
            if (estimate && (snapshotIndex == lastSnapshotIndex_)) {
                if (periodToClaim == lastSnapshotPeriod) {
                    // process the last snapshot

                    // extend the last snapshot cycle range to align with
                    // the end of its period, as necessary
                    if (snapshot.endCycle != periodToClaimEndCycle) {
                        snapshot.endCycle = periodToClaimEndCycle;
                    }
                } else {
                    // process a 'pseudo-' snapshot for this period, which
                    // does not have any snapshots by re-using the last snapshot

                    // re-position the last snapshot cycle range for the period
                    // to claim
                    snapshot.startCycle = snapshot.endCycle + 1;
                    snapshot.endCycle = periodToClaimEndCycle;
                }
            }
        }

        result.endSnapshotIndex = snapshotIndex;

        return result;
    }

    /**
     * Retrieves the number of claimable periods for the specified staker.
     * @param sender The staker whose number of claimable periods will be retrieved.
     * @param periodLengthInCycles_ Length of a period, in cycles.
     * @return The number of claimable periods for the specified staker.
     */
    function _getClaimablePeriods (address sender, uint16 periodLengthInCycles_) internal view returns (uint16) {
        StakerState memory stakerState = stakerStates[sender];

        if (stakerState.stake == 0) {
            return 0;
        }

        return _getCurrentPeriod(periodLengthInCycles_) - stakerState.nextClaimablePeriod;
    }


/////////////////////////////////// Utility Internal Functions ////////////////////////////////////

    /**
     * Retrieves the cycle (index-1 based) at the specified timestamp.
     * @dev Reverts if the specified timestamp is earlier than the beginning of the staking schedule
     * @param timestamp The timestamp for which the cycle is derived from.
     * @return The cycle (index-1 based) at the specified timestamp.
     */
    function _getCycle(uint256 timestamp) internal view returns (uint16) {
        require(timestamp >= startTimestamp, "NftStaking: Cycle timestamp preceeds the contract start timestamp");
        return (((timestamp - startTimestamp) / uint256(cycleLengthInSeconds)) + 1).toUint16();
    }

    /**
     * Retrieves the period (index-1 based) for the specified cycle and period length.
     * @dev reverts if the specified cycle is zero.
     * @param cycle The cycle within the period to retrieve.
     * @param periodLengthInCycles_ Length of a period, in cycles.
     * @return The period (index-1 based) for the specified cycle and period length.
     */
    function _getPeriod(uint16 cycle, uint16 periodLengthInCycles_) internal pure returns (uint16) {
        require(cycle != 0, "NftStaking: Period cycle cannot be zero");
        return (cycle - 1) / periodLengthInCycles_ + 1;
    }

    /**
     * Retrieves the current period (index-1 based).
     * @param periodLengthInCycles_ Length of a period, in cycles.
     * @return The current period (index-1 based).
     */
    function _getCurrentPeriod(uint16 periodLengthInCycles_) internal view returns (uint16) {
        return _getPeriod(_getCycle(now), periodLengthInCycles_);
    }

    /**
     * Adds a new snapshot to the snapshot history list.
     * @dev Emits the SnapshotUpdated event when the function is called.
     * @param cycleStart Starting cycle for the new snapshot.
     * @param cycleEnd Ending cycle for the new snapshot.
     * @param stake Initial stake for the new snapshot.
     * @return The newly created snapshot.
     * @return The index of the newly created snapshot.
     */
    function _addNewSnapshot(
        uint16 period,
        uint16 cycleStart,
        uint16 cycleEnd,
        uint64 stake
    ) internal returns (Snapshot storage, uint256)
    {
        Snapshot memory snapshot;
        snapshot.period = period;
        snapshot.startCycle = cycleStart;
        snapshot.endCycle = cycleEnd;
        snapshot.totalStake = stake;

        snapshots.push(snapshot);

        uint256 snapshotIndex = snapshots.length - 1;

        emit SnapshotUpdated(
            snapshotIndex,
            snapshot.startCycle,
            snapshot.endCycle,
            snapshot.totalStake);

        return (snapshots[snapshotIndex], snapshotIndex);
    }

    /**
     * Updates the snapshot stake at the current cycle.
     * @dev It will update the latest snapshot if it starts at the current cycle, otherwise will adjust the snapshots range end back by one cycle (the previous cycle) and create a new snapshot for the current cycle with the stake update.
     * @dev Emits the SnapshotUpdated event when the function is called.
     * @param snapshot The snapshot whose stake is being updated.
     * @param snapshotIndex The index of the snapshot being updated.
     * @param stake The stake to update the latest snapshot with.
     * @param currentCycle The current staking cycle.
     */
    function _updateSnapshotStake(
        Snapshot memory snapshot,
        uint256 snapshotIndex,
        uint64 stake,
        uint16 currentCycle
    ) internal
    {
        if (snapshot.startCycle == currentCycle) {
            // if the snapshot starts at the current cycle, update its stake
            // since this is the only time we can update an existing snapshot
            snapshots[snapshotIndex].totalStake = stake;

            emit SnapshotUpdated(
                snapshotIndex,
                snapshot.startCycle,
                snapshot.endCycle,
                stake);

        } else {
            // make the current snapshot end at previous cycle, since the stake
            // for a new snapshot at the current cycle will be updated
            --snapshots[snapshotIndex].endCycle;

            // Note: no need to emit the SnapshotUpdated event, from adjusting
            // the snapshot range, since the purpose of the event is to report
            // changes in stake weight

            // add a new snapshot starting at the current cycle with stake
            // update
            _addNewSnapshot(snapshot.period, currentCycle, currentCycle, stake);
        }
    }


///////////////////////////////////////// Internal Hooks //////////////////////////////////////////

    /**
     * Abstract function which validates whether or not the supplied NFT identifier is accepted for staking
     * and retrieves its associated weight.
     * @dev MUST throw if the token is invalid.
     * @param nftId uint256 NFT identifier used to determine if the token is valid for staking.
     * @return uint32 the weight of the NFT.
     */
    function _validateAndGetWeight(uint256 nftId) internal virtual view returns (uint64);

}
