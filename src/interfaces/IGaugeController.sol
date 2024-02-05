// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.23;

/// @dev Struct to hold information about each gauge.
struct GaugeInfo {
    uint8 gaugeType;
    uint256 chainId;
    uint256 baseReward;
    address gaugeAddress;
}

/// @dev Struct for the parameters to pass to vote().
struct VoteParams {
    uint256 power;
    uint256 totalPower;
    bytes32 gaugeId; // keccak256(abi.encode(chainId, gauge address))
    bytes32 accountId; // keccak256(abi.encode(chainId, account address))
}

/// @dev Struct for the parameters to pass to pull().
struct PullParams {
    uint256 epoch;
    bytes32 gaugeId;
    address gaugeAddress;
}

interface IGaugeController {
    /// @dev Error thrown when trying to pull rewards for a gauge in the current epoch.
    error CannotPullDuringActiveEpoch();

    /// @dev Error thrown when the total reward available is insufficient to cover the base rewards.
    error NotEnoughRewardAvailable();

    /// @dev Error thrown when an account does not have enough power to vote as requested.
    error NotEnoughPowerAvailable();

    /// @dev Error thrown when an address not recognized as a bridge adapter attempts a restricted action.
    error BridgeAdapterNotFound();

    /// @dev Error thrown when an invalid gauge address is provided.
    error InvalidGauge();

    /// @dev Error thrown when an action is attempted on a gauge that does not exist.
    error GaugeNotFound();

    /// @dev Error thrown when the msg.sender for pull() is not a gauge or a approved bridge adapter.
    error NotGauge();

    /// @dev Error thrown when a gauge tries to pull rewards for an epoch which already had its rewards pulled.
    error RewardAlreadyPulled();

    /// @notice Emitted when a vote is cast.
    /// @param voteParams The parameters for the vote.
    event Vote(VoteParams voteParams);

    /// @notice Emitted when a gauge pulls its reward for the epoch.
    /// @param pullParams The parameters for the pull.
    /// @param reward Amount of reward.
    event RewardPulled(PullParams pullParams, uint256 reward);

    /// @notice Emitted when a bridge adapter's status is updated.
    /// @param bridgeAdapter The address of the bridge adapter.
    /// @param add True if the adapter is added, false if removed.
    event BridgeAdapterUpdated(address bridgeAdapter, bool add);

    /// @notice Emitted when the total rewards per epoch is changed
    /// @param totalRewardsPerEpoch uint256 amount for total reward per epoch
    event SetTotalRewardsPerEpoch(uint256 totalRewardsPerEpoch);

    /// @notice Emitted when a new gauge is added
    /// @param gaugeInfo The GaugeInfo struct
    event GaugeAdded(GaugeInfo gaugeInfo);

    /// @notice Emitted when a gauge is removed
    /// @param gaugeInfo The GaugeInfo struct
    event GaugeRemoved(GaugeInfo gaugeInfo);

    /// @notice Calculates the current epoch based on the genesis time and epoch length.
    /// @return _epoch current epoch number.
    function epoch() external view returns (uint256 _epoch);

    /// @notice Computes the rewards for a gauge based on votes in a given epoch.
    /// @param _id The unique identifier of the gauge.
    /// @param _epoch The epoch for which to compute rewards.
    /// @return reward The amount of reward computed.
    function computeRewards(bytes32 _id, uint256 _epoch) external view returns (uint256 reward);

    /// @notice Allows an account to vote on a gauge with its voting power.
    /// @param _voteParams Parameters including the gauge ID, power to allocate, and total power.
    function vote(VoteParams calldata _voteParams) external;

    /// @notice Pulls computed rewards for a gauge for a given epoch.
    /// @param _pullParams Parameters including the gauge ID and the epoch.
    /// @return reward The amount of reward pulled.
    function pull(PullParams calldata _pullParams) external returns (uint256 reward);
}
