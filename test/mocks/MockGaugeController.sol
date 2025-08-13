// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IGaugeController, VoteParams, PullParams} from "../../src/interfaces/IGaugeController.sol";

contract MockGaugeController is IGaugeController {
    mapping(bytes32 => mapping(uint256 => uint256)) public votes; // gaugeId => epoch => amount
    mapping(bytes32 => mapping(uint256 => uint256)) public rewards; // gaugeId => epoch => amount
    mapping(address => uint256) public lastVoteEpoch;
    uint256 public currentEpoch;

    event VoteCast(address voter, bytes32 gaugeId, uint256 power, uint256 epoch);
    event RewardPulled(bytes32 gaugeId, uint256 epoch, uint256 amount);

    constructor(uint256 _startEpoch) {
        currentEpoch = _startEpoch;
    }

    function vote(VoteParams memory params) external override {
        require(params.power > 0, "Invalid power");
        require(params.totalPower >= params.power, "Power exceeds total");

        votes[params.gaugeId][params.epoch] += params.power;
        lastVoteEpoch[msg.sender] = params.epoch;

        emit VoteCast(msg.sender, params.gaugeId, params.power, params.epoch);
    }

    function pull(PullParams memory params) external override returns (uint256) {
        uint256 reward = rewards[params.gaugeId][params.epoch];
        require(reward > 0, "No rewards");

        // Reset rewards after pulling
        rewards[params.gaugeId][params.epoch] = 0;

        emit RewardPulled(params.gaugeId, params.epoch, reward);
        return reward;
    }

    function epoch() external view override returns (uint256) {
        return currentEpoch;
    }

    function computeRewards(bytes32 _id, uint256 _epoch) external view override returns (uint256) {
        return rewards[_id][_epoch];
    }

    // Helper functions for testing
    function setReward(bytes32 _gaugeId, uint256 _epoch, uint256 _amount) external {
        rewards[_gaugeId][_epoch] = _amount;
    }

    function setEpoch(uint256 _epoch) external {
        currentEpoch = _epoch;
    }

    function getVotes(bytes32 _gaugeId, uint256 _epoch) external view returns (uint256) {
        return votes[_gaugeId][_epoch];
    }
}
