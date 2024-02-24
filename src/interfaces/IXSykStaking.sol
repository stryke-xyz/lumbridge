// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.23;

interface IXSykStaking {
    /// @notice Emitted when a bridge adapter is added or removed.
    /// @param bridgeAdapter Address of the bridge adapter.
    /// @param add Indicates whether the bridge adapter was added (true) or removed (false).
    event BridgeAdapterUpdated(address bridgeAdapter, bool add);

    /// @notice Emitted when the xSYK reward conversion percentage is updated.
    /// @param xSykRewardPercentage The percentage of SYK rewards to be sent in xSYK
    event XSykRewardPercentageUpdated(uint256 xSykRewardPercentage);

    /// @dev Emitted when tokens are staked in the contract.
    /// @notice This event is fired whenever a user stakes tokens, indicating the amount staked.
    /// @param account The address of the account that staked tokens.
    /// @param amount The amount of tokens that were staked by the account.
    event Staked(address indexed account, uint256 amount);

    /// @dev Emitted when staked tokens are withdrawn (unstaked) from the contract.
    /// @notice This event is fired whenever a user unstakes tokens, indicating the amount unstaked.
    /// @param account The address of the account that unstaked tokens.
    /// @param amount The amount of tokens that were unstaked by the account.
    event Unstaked(address indexed account, uint256 amount);

    /// @dev Emitted when rewards are claimed by a staker.
    /// @notice This event is fired whenever a user claims their staking rewards, indicating the amount claimed.
    /// @param account The address of the account that claimed rewards.
    /// @param amount The amount of rewards that were claimed by the account.
    event Claimed(address indexed account, uint256 amount);

    /// @dev Emitted when a new reward amount is notified to the contract.
    /// @notice This event signals the notification of a new reward amount and the time when the rewards distribution will finish.
    /// @param amount The amount of rewards that will be distributed.
    /// @param finishAt The timestamp when the reward distribution is scheduled to finish.
    event Notified(uint256 amount, uint256 finishAt);

    /// @dev Emitted when the rewards distribution duration is set or updated.
    /// @notice This event is fired whenever the duration for rewards distribution is set or changed, indicating the new duration period.
    /// @param duration The new duration (in seconds) over which rewards will be distributed.
    event RewardsDurationSet(uint256 duration);

    /// @dev Error thrown when an operation that requires a non-zero amount is attempted with a zero value.
    /// @notice Indicates that the operation cannot proceed because the amount specified is zero.
    error XSykStaking_AmountZero();

    /// @dev Error thrown when an operation requires the caller to be the same as a specified account, but it is not.
    /// @notice Indicates that the caller of the function must be the same as the account specified for the operation.
    error XSykStaking_AccountNotSender();

    /// @dev Error thrown when an attempt is made to set or change the rewards duration while a previous rewards duration is still active.
    /// @notice Indicates that the rewards duration cannot be modified while the current rewards period has not yet concluded.
    error XSykStaking_RewardsDurationActive();

    /// @dev Error thrown when an operation that requires a non-zero reward rate is attempted with a zero value.
    /// @notice Indicates that the reward rate for distributing rewards cannot be zero.
    error XSykStaking_RewardRateZero();

    /// @dev Error thrown when there are not enough rewards in the contract to cover a distribution or operation.
    /// @notice Indicates that the operation cannot proceed because the contract does not hold enough rewards to fulfill the request.
    error XSykStaking_NotEnoughRewardBalance();

    /// @notice Returns the saked balance of an account
    /// @param _account address of the account
    function balanceOf(address _account) external returns (uint256);

    /// @notice Allows a user or a bridge adapter to stake tokens on behalf of a user.
    /// @param _amount Amount of tokens to stake.
    /// @param _account Address of the user on whose behalf tokens are staked.
    function stake(uint256 _amount, address _account) external;

    /// @notice Unstakes staked tokens for a user.
    /// @param _amount Amount of tokens to withdraw.
    /// @param _account Address of the user withdrawing tokens.
    function unstake(uint256 _amount, address _account) external;

    /// @notice Calculates the total rewards earned by a user.
    /// @param _account Address of the user.
    /// @return The total rewards earned.
    function earned(address _account) external view returns (uint256);

    /// @notice Claims earned rewards for a user.
    /// @param _account Address of the user claiming rewards.
    /// @return reward The amount of rewards claimed.
    function claim(address _account) external returns (uint256 reward);

    /// @notice Withdraws staked tokens and claims rewards for a user.
    /// @param _account Address of the user exiting the staking contract.
    /// @return balance The staked token balance returned.
    /// @return reward The rewards claimed.
    function exit(address _account) external returns (uint256 balance, uint256 reward);
}
