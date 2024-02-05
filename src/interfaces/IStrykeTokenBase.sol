// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.23;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface IStrykeTokenBase is IERC20Metadata {
    /// @notice Mints tokens for authorized parties
    /// @dev Can only be called by admin
    /// @param _to address to mint tokens to
    /// @param _amount amount of tokens to mint
    function mint(address _to, uint256 _amount) external;

    /// @notice Burns tokens for authorized parties
    /// @dev Can only be called by admin
    /// @param _account address to burn tokens from
    /// @param _amount amount of tokens to burn
    function burn(address _account, uint256 _amount) external;
}
