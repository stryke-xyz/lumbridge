// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.23;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title StakedSYK
/// @notice Successor to xSYK/XSykStaking: stake SYK directly, earn multiple reward tokens
///         (SYK, tokenized stocks, ...), withdraw via a configurable cooldown (hard-capped
///         at 7 days). Pending (cooling-down) stake earns nothing.
contract StakedSYK is AccessManaged, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*==== STRUCTS ====*/

    struct RewardData {
        uint256 duration;
        uint256 finishAt;
        uint256 updatedAt;
        uint256 rewardRate;
        uint256 rewardPerTokenStored;
    }

    struct UnstakeRequest {
        uint128 amount;
        uint64 unlockAt;
    }

    /*==== STATE ====*/

    uint256 public constant MAX_COOLDOWN = 7 days;
    uint256 public constant MAX_REWARD_TOKENS = 10;

    IERC20 public immutable syk;

    /// @notice Current cooldown applied to new unstake requests.
    uint256 public cooldown;

    /// @notice Actively staked (reward-earning) total.
    uint256 public totalSupply;

    /// @notice Total currently cooling down (not earning).
    uint256 public totalPendingUnstake;

    mapping(address => uint256) public balanceOf;
    mapping(address => UnstakeRequest[]) private _unstakeRequests;

    address[] public rewardTokens;
    mapping(address => RewardData) public rewardData;
    /// @dev token => user => value
    mapping(address => mapping(address => uint256)) public userRewardPerTokenPaid;
    mapping(address => mapping(address => uint256)) public rewards;

    /*==== EVENTS ====*/

    event Staked(address indexed account, uint256 amount);
    event UnstakeInitiated(address indexed account, uint256 amount, uint256 unlockAt, uint256 index);
    event UnstakeCancelled(address indexed account, uint256 amount, uint256 index);
    event Withdrawn(address indexed account, uint256 amount);
    event RewardPaid(address indexed account, address indexed token, uint256 amount);
    event RewardAdded(address indexed token, uint256 duration);
    event RewardsDurationSet(address indexed token, uint256 duration);
    event RewardNotified(address indexed token, uint256 amount, uint256 finishAt);
    event CooldownSet(uint256 cooldown);
    event Recovered(address indexed token, uint256 amount);

    /*==== ERRORS ====*/

    error StakedSYK_AmountZero();
    error StakedSYK_CooldownTooLong();
    error StakedSYK_RewardTokenExists();
    error StakedSYK_RewardTokenUnknown();
    error StakedSYK_TooManyRewardTokens();
    error StakedSYK_DurationZero();
    error StakedSYK_RewardPeriodActive();
    error StakedSYK_RewardRateZero();
    error StakedSYK_InvalidIndex();
    error StakedSYK_TokenNotRecoverable();

    /*==== CONSTRUCTOR ====*/

    constructor(address _syk, uint256 _cooldown, address _initialAuthority) AccessManaged(_initialAuthority) {
        syk = IERC20(_syk);
        _setCooldown(_cooldown);
    }

    /*==== MODIFIERS ====*/

    modifier updateReward(address _account) {
        uint256 len = rewardTokens.length;
        for (uint256 i; i < len; ++i) {
            address token = rewardTokens[i];
            RewardData storage r = rewardData[token];
            r.rewardPerTokenStored = rewardPerToken(token);
            r.updatedAt = lastTimeRewardApplicable(token);
            if (_account != address(0)) {
                rewards[token][_account] = earned(token, _account);
                userRewardPerTokenPaid[token][_account] = r.rewardPerTokenStored;
            }
        }
        _;
    }

    /*==== VIEWS ====*/

    function rewardTokensLength() external view returns (uint256) {
        return rewardTokens.length;
    }

    function getRewardTokens() external view returns (address[] memory) {
        return rewardTokens;
    }

    function lastTimeRewardApplicable(address _token) public view returns (uint256) {
        uint256 finishAt = rewardData[_token].finishAt;
        return block.timestamp < finishAt ? block.timestamp : finishAt;
    }

    function rewardPerToken(address _token) public view returns (uint256) {
        RewardData storage r = rewardData[_token];
        if (totalSupply == 0) {
            return r.rewardPerTokenStored;
        }
        return
            r.rewardPerTokenStored + (r.rewardRate * (lastTimeRewardApplicable(_token) - r.updatedAt) * 1e18)
                / totalSupply;
    }

    function earned(address _token, address _account) public view returns (uint256) {
        return (balanceOf[_account] * (rewardPerToken(_token) - userRewardPerTokenPaid[_token][_account])) / 1e18
            + rewards[_token][_account];
    }

    function unstakeRequests(address _account) external view returns (UnstakeRequest[] memory) {
        return _unstakeRequests[_account];
    }

    /// @notice Amount withdrawable right now (matured cooldowns).
    function withdrawable(address _account) public view returns (uint256 amount) {
        UnstakeRequest[] storage reqs = _unstakeRequests[_account];
        uint256 len = reqs.length;
        for (uint256 i; i < len; ++i) {
            if (reqs[i].unlockAt <= block.timestamp) amount += reqs[i].amount;
        }
    }

    /*==== USER FUNCTIONS ====*/

    function stake(uint256 _amount) external nonReentrant updateReward(msg.sender) {
        if (_amount == 0) revert StakedSYK_AmountZero();

        syk.safeTransferFrom(msg.sender, address(this), _amount);
        balanceOf[msg.sender] += _amount;
        totalSupply += _amount;

        emit Staked(msg.sender, _amount);
    }

    /// @notice Starts the cooldown for `_amount`; it stops earning immediately.
    function initiateUnstake(uint256 _amount) public nonReentrant updateReward(msg.sender) {
        if (_amount == 0) revert StakedSYK_AmountZero();

        balanceOf[msg.sender] -= _amount;
        totalSupply -= _amount;
        totalPendingUnstake += _amount;

        uint256 unlockAt = block.timestamp + cooldown;
        _unstakeRequests[msg.sender].push(UnstakeRequest(uint128(_amount), uint64(unlockAt)));

        emit UnstakeInitiated(msg.sender, _amount, unlockAt, _unstakeRequests[msg.sender].length - 1);
    }

    /// @notice Re-stakes a pending unstake request.
    function cancelUnstake(uint256 _index) external nonReentrant updateReward(msg.sender) {
        UnstakeRequest[] storage reqs = _unstakeRequests[msg.sender];
        if (_index >= reqs.length) revert StakedSYK_InvalidIndex();

        uint256 amount = reqs[_index].amount;
        reqs[_index] = reqs[reqs.length - 1];
        reqs.pop();

        totalPendingUnstake -= amount;
        balanceOf[msg.sender] += amount;
        totalSupply += amount;

        emit UnstakeCancelled(msg.sender, amount, _index);
    }

    /// @notice Withdraws all matured unstake requests.
    function withdraw() public nonReentrant returns (uint256 amount) {
        UnstakeRequest[] storage reqs = _unstakeRequests[msg.sender];
        uint256 i;
        while (i < reqs.length) {
            if (reqs[i].unlockAt <= block.timestamp) {
                amount += reqs[i].amount;
                reqs[i] = reqs[reqs.length - 1];
                reqs.pop();
            } else {
                ++i;
            }
        }

        if (amount > 0) {
            totalPendingUnstake -= amount;
            syk.safeTransfer(msg.sender, amount);
            emit Withdrawn(msg.sender, amount);
        }
    }

    /// @notice Claims all accrued rewards across every reward token.
    function claim() public nonReentrant updateReward(msg.sender) {
        uint256 len = rewardTokens.length;
        for (uint256 i; i < len; ++i) {
            address token = rewardTokens[i];
            uint256 reward = rewards[token][msg.sender];
            if (reward > 0) {
                rewards[token][msg.sender] = 0;
                IERC20(token).safeTransfer(msg.sender, reward);
                emit RewardPaid(msg.sender, token, reward);
            }
        }
    }

    /// @notice Claims rewards and starts the cooldown for the full staked balance.
    function exit() external {
        uint256 balance = balanceOf[msg.sender];
        if (balance > 0) initiateUnstake(balance);
        claim();
    }

    /*==== RESTRICTED FUNCTIONS ====*/

    function addReward(address _token, uint256 _duration) external restricted {
        if (_duration == 0) revert StakedSYK_DurationZero();
        if (rewardData[_token].duration != 0) revert StakedSYK_RewardTokenExists();
        if (rewardTokens.length >= MAX_REWARD_TOKENS) revert StakedSYK_TooManyRewardTokens();

        rewardTokens.push(_token);
        rewardData[_token].duration = _duration;

        emit RewardAdded(_token, _duration);
    }

    function setRewardsDuration(address _token, uint256 _duration) external restricted {
        if (_duration == 0) revert StakedSYK_DurationZero();
        RewardData storage r = rewardData[_token];
        if (r.duration == 0) revert StakedSYK_RewardTokenUnknown();
        if (r.finishAt > block.timestamp) revert StakedSYK_RewardPeriodActive();

        r.duration = _duration;

        emit RewardsDurationSet(_token, _duration);
    }

    /// @notice Pulls `_amount` of `_token` from the caller and streams it over the token's duration.
    ///         Leftover from an active period rolls over.
    function notifyRewardAmount(address _token, uint256 _amount) external restricted updateReward(address(0)) {
        RewardData storage r = rewardData[_token];
        if (r.duration == 0) revert StakedSYK_RewardTokenUnknown();

        uint256 balanceBefore = IERC20(_token).balanceOf(address(this));
        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
        uint256 received = IERC20(_token).balanceOf(address(this)) - balanceBefore;

        if (block.timestamp >= r.finishAt) {
            r.rewardRate = received / r.duration;
        } else {
            uint256 remaining = (r.finishAt - block.timestamp) * r.rewardRate;
            r.rewardRate = (received + remaining) / r.duration;
        }

        if (r.rewardRate == 0) revert StakedSYK_RewardRateZero();

        r.finishAt = block.timestamp + r.duration;
        r.updatedAt = block.timestamp;

        emit RewardNotified(_token, received, r.finishAt);
    }

    function setCooldown(uint256 _cooldown) external restricted {
        _setCooldown(_cooldown);
    }

    /// @notice Recovers stray tokens. Staking and reward tokens are not recoverable.
    function recoverERC20(address _token, uint256 _amount) external restricted {
        if (_token == address(syk) || rewardData[_token].duration != 0) revert StakedSYK_TokenNotRecoverable();

        IERC20(_token).safeTransfer(msg.sender, _amount);

        emit Recovered(_token, _amount);
    }

    /*==== INTERNAL ====*/

    function _setCooldown(uint256 _cooldown) internal {
        if (_cooldown > MAX_COOLDOWN) revert StakedSYK_CooldownTooLong();
        cooldown = _cooldown;
        emit CooldownSet(_cooldown);
    }
}
