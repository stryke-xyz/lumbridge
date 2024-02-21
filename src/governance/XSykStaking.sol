// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.23;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IXStrykeToken} from "../interfaces/IXStrykeToken.sol";
import {IXSykStaking} from "../interfaces/IXSykStaking.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title XSyk Staking Contract
/// @notice Enables staking of a specific token and distribution of rewards over a fixed duration.
/// @dev This contract manages the staking of tokens and calculation and distribution of rewards based on staked amounts.
contract XSykStaking is IXSykStaking, AccessManaged {
    using SafeERC20 for IERC20;

    /// @notice Token that users stake in this contract.
    IERC20 public immutable stakingToken;

    /// @notice Token distributed as rewards to stakers.
    IERC20 public immutable rewardsToken;

    /// @notice xSYK Token
    IXStrykeToken public immutable xSyk;

    /// @notice xSYK reward conversion percentage.
    uint256 public xSykRewardPercentage;

    /// @notice Duration over which the rewards are distributed.
    uint256 public duration;

    /// @notice Time when the reward distribution finishes.
    uint256 public finishAt;

    /// @notice Last time rewards were updated or reward distribution finished, whichever is earlier.
    uint256 public updatedAt;

    /// @notice Rate at which rewards are distributed per second.
    uint256 public rewardRate;

    /// @notice Accumulated reward per token staked, scaled by 1e18.
    uint256 public rewardPerTokenStored;

    /// @notice Total amount of the staking token staked in the contract.
    uint256 public totalSupply;

    /// @notice Tracks which addresses are authorized as bridge adapters.
    mapping(address => bool) public bridgeAdapters;

    /// @notice Stores the rewardPerToken value at which each user's rewards were last calculated.
    mapping(address => uint256) public userRewardPerTokenPaid;

    /// @notice Stores the rewards that are yet to be claimed by each user.
    mapping(address => uint256) public rewards;

    /// @notice Amount of the staking token staked by each user.
    mapping(address => uint256) public balanceOf;

    /// @notice Initializes the staking and rewards tokens, along with the initial authority for access management.
    /// @param _stakingToken Address of the staking token.
    /// @param _rewardToken Address of the rewards token.
    /// @param _initialAuthority Address with initial administrative authority.
    constructor(address _stakingToken, address _rewardToken, address _xSyk, address _initialAuthority)
        AccessManaged(_initialAuthority)
    {
        stakingToken = IERC20(_stakingToken);
        rewardsToken = IERC20(_rewardToken);
        xSyk = IXStrykeToken(_xSyk);
    }

    /// @dev Updates reward calculation for a user before executing function logic.
    /// @param _account Address of the user for whom rewards are updated.
    modifier updateReward(address _account) {
        rewardPerTokenStored = rewardPerToken();
        updatedAt = lastTimeRewardApplicable();

        if (_account != address(0)) {
            rewards[_account] = earned(_account);
            userRewardPerTokenPaid[_account] = rewardPerTokenStored;
        }

        _;
    }

    /// @notice Updates the authorization status of a bridge adapter.
    /// @dev Restricted to contract administrators.
    /// @param _bridgeAdapter Address of the bridge adapter.
    /// @param _add True to authorize, false to revoke authorization.
    function updateBridgeAdapter(address _bridgeAdapter, bool _add) external restricted {
        bridgeAdapters[_bridgeAdapter] = _add;

        emit BridgeAdapterUpdated(_bridgeAdapter, _add);
    }

    /// @notice Updates xSYK reward conversion percentage.
    /// @dev Restricted to contract administrators.
    /// @param _xSykRewardPercentage The percentage of SYK rewards to be sent in xSYK
    function updateXSykRewardPercentage(uint256 _xSykRewardPercentage) external restricted {
        xSykRewardPercentage = _xSykRewardPercentage;

        emit XSykRewardPercentageUpdated(_xSykRewardPercentage);
    }

    /// @notice Calculates the last time rewards are applicable.
    function lastTimeRewardApplicable() public view returns (uint256) {
        return _min(finishAt, block.timestamp);
    }

    /// @notice Calculates the accumulated amount of reward per token staked.
    function rewardPerToken() public view returns (uint256) {
        if (totalSupply == 0) {
            return rewardPerTokenStored;
        }

        return rewardPerTokenStored + (rewardRate * (lastTimeRewardApplicable() - updatedAt) * 1e18) / totalSupply;
    }

    /// @notice Allows a user or a bridge adapter to stake tokens on behalf of a user.
    /// @param _amount Amount of tokens to stake.
    /// @param _account Address of the user on whose behalf tokens are staked.
    function stake(uint256 _amount, address _account) external updateReward(_account) {
        if (_amount < 0) revert AmountCannotBeZero();

        if (!bridgeAdapters[msg.sender]) {
            if (_account != msg.sender) revert AccountMustBeSender();
            stakingToken.safeTransferFrom(_account, address(this), _amount);
        }

        balanceOf[_account] += _amount;
        totalSupply += _amount;

        emit Staked(_account, _amount);
    }

    /// @notice Unstakes staked tokens for a user.
    /// @param _amount Amount of tokens to withdraw.
    /// @param _account Address of the user withdrawing tokens.
    function unstake(uint256 _amount, address _account) public updateReward(_account) {
        if (_amount < 0) revert AmountCannotBeZero();

        if (!bridgeAdapters[msg.sender]) {
            if (_account != msg.sender) revert AccountMustBeSender();
            stakingToken.safeTransfer(_account, _amount);
        }

        balanceOf[_account] -= _amount;
        totalSupply -= _amount;

        emit Unstaked(_account, _amount);
    }

    /// @notice Calculates the total rewards earned by a user.
    /// @param _account Address of the user.
    /// @return The total rewards earned.
    function earned(address _account) public view returns (uint256) {
        return
            ((balanceOf[_account] * (rewardPerToken() - userRewardPerTokenPaid[_account])) / 1e18) + rewards[_account];
    }

    /// @notice Claims earned rewards for a user.
    /// @param _account Address of the user claiming rewards.
    /// @return reward The amount of rewards claimed.
    function claim(address _account) public updateReward(_account) returns (uint256 reward) {
        if (!bridgeAdapters[msg.sender]) {
            if (_account != msg.sender) revert AccountMustBeSender();
        }

        reward = rewards[_account];
        if (reward > 0) {
            rewards[_account] = 0;
            if (!bridgeAdapters[msg.sender]) {
                uint256 xSykReward = (reward * xSykRewardPercentage) / 100;
                if (xSykReward > 0) {
                    rewardsToken.approve(address(xSyk), xSykReward);
                    xSyk.convert(xSykReward, _account);
                }
                rewardsToken.safeTransfer(_account, reward - xSykReward);
            } else {
                // The transfer needs to happen to msg.sender since the reward is transferred to the bridge adapter which is bridged back for the account
                rewardsToken.safeTransfer(msg.sender, reward);
            }
        }

        emit Claimed(_account, reward);
    }

    /// @notice Withdraws staked tokens and claims rewards for a user.
    /// @param _account Address of the user exiting the staking contract.
    /// @return balance The staked token balance returned.
    /// @return reward The rewards claimed.
    function exit(address _account) external updateReward(_account) returns (uint256 balance, uint256 reward) {
        balance = balanceOf[_account];
        unstake(balanceOf[_account], _account);
        reward = claim(_account);
    }

    /// @notice Sets the duration over which rewards are distributed.
    /// @dev Restricted to contract administrators.
    /// @param _duration The new rewards duration.
    function setRewardsDuration(uint256 _duration) external restricted {
        if (finishAt >= block.timestamp) revert RewardsDurationActive();
        duration = _duration;

        emit RewardsDurationSet(_duration);
    }

    /// @notice Notifies the contract of the amount of rewards to be distributed over the set duration.
    /// @dev Restricted to contract administrators.
    /// @param _amount The amount of rewards to distribute.
    function notifyRewardAmount(uint256 _amount) external restricted updateReward(address(0)) {
        if (block.timestamp >= finishAt) {
            rewardRate = _amount / duration;
        } else {
            uint256 remainingRewards = (finishAt - block.timestamp) * rewardRate;
            rewardRate = (_amount + remainingRewards) / duration;
        }

        if (rewardRate < 0) revert RewardRateCannotBeZero();
        if (rewardRate * duration > rewardsToken.balanceOf(address(this))) revert NotEnoughRewardBalance();

        finishAt = block.timestamp + duration;
        updatedAt = block.timestamp;

        emit Notified(_amount, finishAt);
    }

    function _min(uint256 x, uint256 y) private pure returns (uint256) {
        return x <= y ? x : y;
    }
}
