// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.23;

import {IStrykeTokenBase} from "./IStrykeTokenBase.sol";

interface IStrykeTokenRoot is IStrykeTokenBase {
    /// @notice Emitted on changes to inflation per year
    /// @param inflationPerYear the inflation per year
    /// @param emissionRatePerSecond the emission rate per second
    event SetInflationPerYear(
        uint256 inflationPerYear,
        uint256 emissionRatePerSecond
    );

    /// @notice Reverts with this error if more tokens are trying to be emitted than the allowed emissions
    error InflationExceeding();

    /// @notice Returns the timestamp of the deployment of this contract
    function genesis() external view returns (uint256);

    /// @notice Returns the amount of tokens that can be emitted per year
    function inflationPerYear() external view returns (uint256);

    /// @notice Returns the token emission per second based on the inflation per year
    function emissionRatePerSecond() external view returns (uint256);

    /// @notice Returns the max supply of the token
    function maxSupply() external view returns (uint256);

    function availableSupply() external view returns (uint256);

    /// @notice Function for token emission
    /// @dev Ensures no more tokens than the allowed inflation can be minted. Can only be called by authorized addresses.
    /// @param _amount amount of tokens to mint
    function stryke(uint256 _amount) external;

    /// @notice Function to set token inflation per year
    /// @dev Can only be called by admin
    /// @param _inflationPerYear the inflation per year to set
    function setInflationPerYear(uint256 _inflationPerYear) external;
}
