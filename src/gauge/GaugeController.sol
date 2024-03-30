// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.23;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";

import {IStrykeTokenRoot} from "../interfaces/IStrykeTokenRoot.sol";
import {IGaugeController, VoteParams, PullParams, GaugeInfo} from "../interfaces/IGaugeController.sol";
import {IXSykStaking} from "../interfaces/IXSykStaking.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Gauge Controller for Reward Distribution
/// @notice Manages gauges for different chains, handles voting power allocation, and rewards distribution.
/// @dev This contract allows bridge adapters and users to vote on gauges and pull rewards based on their voting power.
contract GaugeController is IGaugeController, AccessManaged {
    using SafeERC20 for IStrykeTokenRoot;

    /// @notice The current total reward distributed across all gauges.
    uint256 public totalRewardPerEpoch;

    /// @notice The current portion of the total reward that is allocated based on voting.
    uint256 public totalVoteableRewardPerEpoch;

    /// @notice The current sum of base rewards for all gauges.
    uint256 public totalBaseRewardPerEpoch;

    /// @notice The total reward distributed per epoch across all gauges.
    mapping(uint256 => uint256) public totalReward;

    /// @notice The portion of the total reward per epoch that is allocated based on voting.
    mapping(uint256 => uint256) public totalVoteableReward;

    /// @notice The sum of base rewards for all gauges per epoch.
    mapping(uint256 => uint256) public totalBaseReward;

    /// @notice Epoch no => whether finalized or not.
    mapping(uint256 => bool) public epochFinalized;

    /// @notice Length of an epoch in seconds.
    uint256 public constant EPOCH_LENGTH = 7 days;

    /// @notice The timestamp of the first epoch's start.
    uint256 public genesis;

    /// @notice Address of the xSYK Staking contract.
    address public xSykStaking;

    /// @notice Address of the xSyk token.
    address public xSyk;

    /// @notice Address of the Syk token.
    address public syk;

    /// @notice Tracks the voting power allocated to each gauge per epoch.
    mapping(uint256 => mapping(bytes32 => uint256)) public gaugePowersPerEpoch;

    /// @notice Tracks the voting power used by each account per epoch.
    mapping(uint256 => mapping(bytes32 => uint256)) public accountPowerUsedPerEpoch;

    /// @notice Total voting power used per epoch.
    mapping(uint256 => uint256) public totalPowerUsedPerEpoch;

    /// @notice Tracks whether rewards have been pulled for a gauge in a specific epoch.
    mapping(uint256 => mapping(bytes32 => bool)) gaugeRewardPulledPerEpoch;

    /// @notice Stores information for each gauge identified by a bytes32 ID.
    mapping(bytes32 => GaugeInfo) public gauges;

    /// @notice Tracks which addresses are authorized as bridge adapters.
    mapping(address => bool) public bridgeAdapters;

    /// @notice Initializes the contract with SYK, xSyk token addresses, and the initial authority.
    /// @param _syk Address of the Syk token.
    /// @param _xSyk Address of the xSyk token.
    /// @param _initialAuthority Address of the initial authority for access management.
    constructor(address _syk, address _xSyk, address _xSykStaking, address _initialAuthority)
        AccessManaged(_initialAuthority)
    {
        syk = _syk;
        xSyk = _xSyk;
        xSykStaking = _xSykStaking;
    }

    /// @notice Sets the genesis time for the first epoch. Can only be set once.
    /// @dev Restricted to contract administrators.
    /// @param _genesis Timestamp for the start of the first epoch.
    function setGenesis(uint256 _genesis) external restricted {
        require(genesis == 0, "genesis cannot be reset");

        genesis = _genesis;
    }

    /// @notice Updates the xSYK staking contract address.
    /// @dev Restricted to contract administrators.
    /// @param _xSykStaking Address of the new xSYK staking contract.
    function updateXSykStaking(address _xSykStaking) external restricted {
        xSykStaking = _xSykStaking;
    }

    /// @notice Updates the total reward distributed per epoch.
    /// @dev Restricted to contract administrators.
    /// @param _totalRewardPerEpoch New total reward amount per epoch.
    function setTotalRewardPerEpoch(uint256 _totalRewardPerEpoch) external restricted {
        totalRewardPerEpoch = _totalRewardPerEpoch;
    }

    /// @notice Adds or removes a bridge adapter's authorization.
    /// @dev Restricted to contract administrators.
    /// @param _bridgeAdapter Address of the bridge adapter.
    /// @param _add True to authorize, false to revoke authorization.
    function updateBridgeAdapter(address _bridgeAdapter, bool _add) external restricted {
        bridgeAdapters[_bridgeAdapter] = _add;

        emit BridgeAdapterUpdated(_bridgeAdapter, _add);
    }

    /// @notice Adds a new gauge to the system.
    /// @dev Restricted to contract administrators.
    /// @param _gaugeInfo Information about the new gauge.
    /// @return id The unique identifier for the new gauge.
    function addGauge(GaugeInfo memory _gaugeInfo) external restricted returns (bytes32 id) {
        if (_gaugeInfo.gaugeAddress == address(0)) {
            revert GaugeController_InvalidGauge();
        }

        id = keccak256(abi.encode(_gaugeInfo.chainId, _gaugeInfo.gaugeAddress));

        gauges[id] = _gaugeInfo;

        totalBaseRewardPerEpoch += _gaugeInfo.baseReward;

        if (totalRewardPerEpoch < totalBaseRewardPerEpoch) revert GaugeController_NotEnoughRewardAvailable();

        totalVoteableRewardPerEpoch = totalRewardPerEpoch - totalBaseRewardPerEpoch;

        emit GaugeAdded(_gaugeInfo);
    }

    /// @notice Removes a gauge from the system.
    /// @dev Restricted to contract administrators.
    /// @param _gaugeId The unique identifier of the gauge to be removed.
    function removeGauge(bytes32 _gaugeId) external restricted {
        emit GaugeRemoved(gauges[_gaugeId]);

        uint256 _epoch = epoch();

        totalBaseRewardPerEpoch -= gauges[_gaugeId].baseReward;

        totalVoteableRewardPerEpoch = totalRewardPerEpoch - totalBaseRewardPerEpoch;

        totalPowerUsedPerEpoch[_epoch] -= gaugePowersPerEpoch[_epoch][_gaugeId];

        gaugePowersPerEpoch[_epoch][_gaugeId] = 0;

        gauges[_gaugeId] = GaugeInfo({gaugeType: 0, chainId: 0, baseReward: 0, gaugeAddress: address(0)});
    }

    /// @notice Finalizes an epoch.
    /// @dev Restricted to contract administrators.
    /// @param _epoch Epoch number.
    function finalizeEpoch(uint256 _epoch) external restricted {
        if (_epoch == 0) {
            totalBaseReward[_epoch] = totalBaseRewardPerEpoch;
            totalVoteableReward[_epoch] = totalVoteableRewardPerEpoch;
            totalReward[_epoch] = totalRewardPerEpoch;
        }

        epochFinalized[_epoch] = true;

        totalBaseReward[_epoch + 1] = totalBaseRewardPerEpoch;
        totalVoteableReward[_epoch + 1] = totalVoteableRewardPerEpoch;
        totalReward[_epoch + 1] = totalRewardPerEpoch;
    }

    /// @inheritdoc	IGaugeController
    function epoch() public view returns (uint256 _epoch) {
        _epoch = (block.timestamp - genesis) / EPOCH_LENGTH;
    }

    /// @inheritdoc	IGaugeController
    function computeRewards(bytes32 _id, uint256 _epoch) public view returns (uint256 reward) {
        // Compute the rewards from the voteable rewards
        if (totalPowerUsedPerEpoch[_epoch] != 0) {
            reward = totalVoteableReward[_epoch] * gaugePowersPerEpoch[_epoch][_id] / totalPowerUsedPerEpoch[_epoch];
        }

        // Add base reward
        reward += gauges[_id].baseReward;
    }

    /// @inheritdoc	IGaugeController
    function vote(VoteParams calldata _voteParams) external {
        if (_voteParams.epoch != 0) {
            if (!epochFinalized[_voteParams.epoch - 1]) {
                revert GaugeController_EpochNotFinalized();
            }
        }

        uint256 _epoch = epoch();

        if (_voteParams.epoch != _epoch) {
            revert GaugeController_IncorrectEpoch();
        }

        if (gauges[_voteParams.gaugeId].gaugeAddress == address(0)) {
            revert GaugeController_GaugeNotFound();
        }

        uint256 totalPower;
        bytes32 accountId;

        if (bridgeAdapters[msg.sender]) {
            totalPower = _voteParams.totalPower;
            accountId = _voteParams.accountId;
        } else {
            totalPower += IStrykeTokenRoot(xSyk).balanceOf(msg.sender);
            accountId = keccak256(abi.encode(block.chainid, msg.sender));
            totalPower += IXSykStaking(xSykStaking).balanceOf(accountId);
        }

        uint256 usedPower = accountPowerUsedPerEpoch[_epoch][accountId];

        if ((totalPower - usedPower) < _voteParams.power) {
            revert GaugeController_NotEnoughPowerAvailable();
        }

        accountPowerUsedPerEpoch[_epoch][accountId] = usedPower + _voteParams.power;

        gaugePowersPerEpoch[_epoch][_voteParams.gaugeId] += _voteParams.power;

        totalPowerUsedPerEpoch[_epoch] += _voteParams.power;

        emit Voted(_voteParams);
    }

    /// @inheritdoc	IGaugeController
    function pull(PullParams calldata _pullParams) external returns (uint256 reward) {
        if (!epochFinalized[_pullParams.epoch]) revert GaugeController_EpochNotFinalized();

        if (_pullParams.epoch >= epoch()) {
            revert GaugeController_EpochActive();
        }

        if (gaugeRewardPulledPerEpoch[_pullParams.epoch][_pullParams.gaugeId]) {
            revert GaugeController_RewardAlreadyPulled();
        }

        GaugeInfo memory gauge = gauges[_pullParams.gaugeId];

        if ((gauge.gaugeAddress != msg.sender) && (!bridgeAdapters[msg.sender])) revert GaugeController_NotGauge();

        gaugeRewardPulledPerEpoch[_pullParams.epoch][_pullParams.gaugeId] = true;

        reward = computeRewards(_pullParams.gaugeId, _pullParams.epoch);

        IStrykeTokenRoot(syk).stryke(reward);

        IStrykeTokenRoot(syk).safeTransfer(msg.sender, reward);

        emit RewardPulled(_pullParams, reward);
    }
}
