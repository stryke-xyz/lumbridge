// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.23;

/// @dev Bridge struct defining the minter and burner params of a bridge
struct Bridge {
    BridgeParameters minterParams;
    BridgeParameters burnerParams;
}

/// @dev BridgeParameters struct defining the parameters for minting and burning
struct BridgeParameters {
    uint256 timestamp;
    uint256 ratePerSecond;
    uint256 maxLimit;
    uint256 currentLimit;
}

interface ISykBridgeController {
    /// @notice Emitted when the duration changes
    /// @param duration duration after which the limits are fully replenished for bridges
    event DurationUpdated(uint256 duration);

    /// @notice Emitted when a bridge's limit changes
    /// @param mintingLimit minting limit of the bridge
    /// @param burningLimit burning limit of the bridge
    /// @param bridge address of the bridge
    event BridgeLimitsSet(uint256 mintingLimit, uint256 burningLimit, address bridge);

    /// @notice Reverts with this error when a bridge has met its limits or have no limits sets
    error SykBridgeController_NotHighEnoughLimits();

    /// @notice Mints tokens for a user
    /// @dev Can only be called by a bridge
    /// @param _user The address of the user who needs tokens minted
    /// @param _amount The amount of tokens being minted
    function mint(address _user, uint256 _amount) external;

    /// @notice Burns tokens for a user
    /// @dev Can only be called by a bridge
    /// @param _user The address of the user who needs tokens burned
    /// @param _amount The amount of tokens being burned
    function burn(address _user, uint256 _amount) external;

    /// @notice Returns the max limit of a bridge
    /// @param _bridge the bridge we are viewing the limits of
    /// @return _limit The limit the bridge has
    function mintingMaxLimitOf(address _bridge) external view returns (uint256 _limit);

    /// @notice Returns the max limit of a bridge
    /// @param _bridge the bridge we are viewing the limits of
    /// @return _limit The limit the bridge has
    function burningMaxLimitOf(address _bridge) external view returns (uint256 _limit);

    /// @notice Returns the current minting limit of a bridge
    /// @param _bridge the bridge we are viewing the limits of
    /// @return _limit The limit the bridge has
    function mintingCurrentLimitOf(address _bridge) external view returns (uint256 _limit);

    /// @notice Returns the current burning limit of a bridge
    /// @param _bridge the bridge we are viewing the limits of
    /// @return _limit The limit the bridge has
    function burningCurrentLimitOf(address _bridge) external view returns (uint256 _limit);
}
