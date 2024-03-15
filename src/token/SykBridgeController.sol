// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.23;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";

import {IStrykeTokenBase} from "../interfaces/IStrykeTokenBase.sol";

import {ISykBridgeController, Bridge, BridgeParameters} from "../interfaces/ISykBridgeController.sol";

/// @title The SYK Bridge Controller
/// @author witherblock
/// @notice The bridge controller is responsible for minting/burning the token on different chains.
/// It is called by Bridge Adapters to teleport tokens across different chains.
/// Inspired by the XERC20 standard (https://www.xerc20.com/)
contract SykBridgeController is ISykBridgeController, AccessManaged {
    /// @notice The token address of SYK
    IStrykeTokenBase public immutable token;

    /// @notice The duration it takes for the limits to fully replenish for a bridge
    uint256 public duration = 1 days;

    /// @notice Maps bridge address to bridge configurations
    mapping(address => Bridge) public bridges;

    /// @dev Constructor
    /// @param _token SYK address
    /// @param _initialAuthority Address of AccessManager contract deployed on the chain
    constructor(address _token, address _initialAuthority) AccessManaged(_initialAuthority) {
        token = IStrykeTokenBase(_token);
    }

    /// @notice Updates the limits of any bridge
    /// @dev Can only be called by the owner
    /// @param _mintingLimit The updated minting limit we are setting to the bridge
    /// @param _burningLimit The updated burning limit we are setting to the bridge
    /// @param _bridge The address of the bridge we are setting the limits too
    function setLimits(address _bridge, uint256 _mintingLimit, uint256 _burningLimit) external restricted {
        _changeMinterLimit(_bridge, _mintingLimit);
        _changeBurnerLimit(_bridge, _burningLimit);
        emit BridgeLimitsSet(_mintingLimit, _burningLimit, _bridge);
    }

    /// @notice Function to change the duration when the limits for a bridge replenish
    /// @dev Can only be called by admin
    /// @param _duration The duration
    function setDuration(uint256 _duration, address[] calldata _bridges) public restricted {
        duration = _duration;

        uint256 i;
        uint256 bridgesLength = _bridges.length;
        for (; i < bridgesLength;) {
            Bridge storage bridge = bridges[_bridges[i]];
            bridge.minterParams.ratePerSecond = bridge.minterParams.maxLimit / _duration;
            bridge.burnerParams.ratePerSecond = bridge.burnerParams.maxLimit / _duration;
            unchecked {
                ++i;
            }
        }

        emit DurationUpdated(_duration);
    }

    /// @inheritdoc	ISykBridgeController
    function mint(address _user, uint256 _amount) external {
        _mintWithCaller(msg.sender, _user, _amount);
    }

    /// @inheritdoc	ISykBridgeController
    function burn(address _user, uint256 _amount) external {
        _burnWithCaller(msg.sender, _user, _amount);
    }

    /// @inheritdoc	ISykBridgeController
    function mintingMaxLimitOf(address _bridge) external view returns (uint256 _limit) {
        _limit = bridges[_bridge].minterParams.maxLimit;
    }

    /// @inheritdoc	ISykBridgeController
    function burningMaxLimitOf(address _bridge) external view returns (uint256 _limit) {
        _limit = bridges[_bridge].burnerParams.maxLimit;
    }

    /// @inheritdoc	ISykBridgeController
    function mintingCurrentLimitOf(address _bridge) public view returns (uint256 _limit) {
        _limit = _getCurrentLimit(
            bridges[_bridge].minterParams.currentLimit,
            bridges[_bridge].minterParams.maxLimit,
            bridges[_bridge].minterParams.timestamp,
            bridges[_bridge].minterParams.ratePerSecond
        );
    }

    /// @inheritdoc	ISykBridgeController
    function burningCurrentLimitOf(address _bridge) public view returns (uint256 _limit) {
        _limit = _getCurrentLimit(
            bridges[_bridge].burnerParams.currentLimit,
            bridges[_bridge].burnerParams.maxLimit,
            bridges[_bridge].burnerParams.timestamp,
            bridges[_bridge].burnerParams.ratePerSecond
        );
    }

    /// @notice Uses the minting limit of any bridge
    /// @param _bridge The address of the bridge who is being changed
    /// @param _change The change in the limit
    function _useMinterLimits(address _bridge, uint256 _change) internal {
        uint256 _currentLimit = mintingCurrentLimitOf(_bridge);
        bridges[_bridge].minterParams.timestamp = block.timestamp;
        bridges[_bridge].minterParams.currentLimit = _currentLimit - _change;
    }

    /// @notice Uses the burning limit of any bridge
    /// @param _bridge The address of the bridge who is being changed
    /// @param _change The change in the limit
    function _useBurnerLimits(address _bridge, uint256 _change) internal {
        uint256 _currentLimit = burningCurrentLimitOf(_bridge);
        bridges[_bridge].burnerParams.timestamp = block.timestamp;
        bridges[_bridge].burnerParams.currentLimit = _currentLimit - _change;
    }

    /// @notice Updates the mintng limit of any bridge
    /// @dev Can only be called by the owner
    /// @param _bridge The address of the bridge we are setting the limit too
    /// @param _limit The updated limit we are setting to the bridge
    function _changeMinterLimit(address _bridge, uint256 _limit) internal {
        uint256 _oldLimit = bridges[_bridge].minterParams.maxLimit;
        uint256 _currentLimit = mintingCurrentLimitOf(_bridge);
        bridges[_bridge].minterParams.maxLimit = _limit;

        bridges[_bridge].minterParams.currentLimit = _calculateNewCurrentLimit(_limit, _oldLimit, _currentLimit);

        bridges[_bridge].minterParams.ratePerSecond = _limit / duration;
        bridges[_bridge].minterParams.timestamp = block.timestamp;
    }

    /// @notice Updates the burning limit of any bridge
    /// @dev Can only be called by the owner
    /// @param _bridge The address of the bridge we are setting the limit too
    /// @param _limit The updated limit we are setting to the bridge
    function _changeBurnerLimit(address _bridge, uint256 _limit) internal {
        uint256 _oldLimit = bridges[_bridge].burnerParams.maxLimit;
        uint256 _currentLimit = burningCurrentLimitOf(_bridge);
        bridges[_bridge].burnerParams.maxLimit = _limit;

        bridges[_bridge].burnerParams.currentLimit = _calculateNewCurrentLimit(_limit, _oldLimit, _currentLimit);

        bridges[_bridge].burnerParams.ratePerSecond = _limit / duration;
        bridges[_bridge].burnerParams.timestamp = block.timestamp;
    }

    /// @notice Updates the current limit
    /// @param _limit The new limit
    /// @param _oldLimit The old limit
    /// @param _currentLimit The current limit
    function _calculateNewCurrentLimit(uint256 _limit, uint256 _oldLimit, uint256 _currentLimit)
        internal
        pure
        returns (uint256 _newCurrentLimit)
    {
        uint256 _difference;

        if (_oldLimit > _limit) {
            _difference = _oldLimit - _limit;
            _newCurrentLimit = _currentLimit > _difference ? _currentLimit - _difference : 0;
        } else {
            _difference = _limit - _oldLimit;
            _newCurrentLimit = _currentLimit + _difference;
        }
    }

    /// @notice Gets the current limit
    /// @param _currentLimit The current limit
    /// @param _maxLimit The max limit
    /// @param _timestamp The timestamp of the last update
    /// @param _ratePerSecond The rate per second
    function _getCurrentLimit(uint256 _currentLimit, uint256 _maxLimit, uint256 _timestamp, uint256 _ratePerSecond)
        internal
        view
        returns (uint256 _limit)
    {
        _limit = _currentLimit;
        if (_limit == _maxLimit) {
            return _limit;
        } else if (_timestamp + duration <= block.timestamp) {
            _limit = _maxLimit;
        } else if (_timestamp + duration > block.timestamp) {
            uint256 _timePassed = block.timestamp - _timestamp;
            uint256 _calculatedLimit = _limit + (_timePassed * _ratePerSecond);
            _limit = _calculatedLimit > _maxLimit ? _maxLimit : _calculatedLimit;
        }
    }

    /// @notice Internal function for burning tokens
    /// @param _caller The caller address
    /// @param _user The user address
    /// @param _amount The amount to burn
    function _burnWithCaller(address _caller, address _user, uint256 _amount) internal {
        uint256 _currentLimit = burningCurrentLimitOf(_caller);
        if (_currentLimit < _amount) revert SykBridgeController_NotHighEnoughLimits();
        _useBurnerLimits(_caller, _amount);
        IStrykeTokenBase(token).burn(_user, _amount);
    }

    /// @notice Internal function for minting tokens
    /// @param _caller The caller address
    /// @param _user The user address
    /// @param _amount The amount to mint
    function _mintWithCaller(address _caller, address _user, uint256 _amount) internal {
        uint256 _currentLimit = mintingCurrentLimitOf(_caller);
        if (_currentLimit < _amount) revert SykBridgeController_NotHighEnoughLimits();
        _useMinterLimits(_caller, _amount);
        IStrykeTokenBase(token).mint(_user, _amount);
    }
}
