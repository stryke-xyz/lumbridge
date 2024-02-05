// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.23;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20PausableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import {AccessManagedUpgradeable} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import {ERC20PermitUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {IStrykeTokenBase} from "../interfaces/IStrykeTokenBase.sol";

/// @title The SYK Token Base
/// @author witherblock
/// @dev Contains the base token logic from openzeppelin libraries
abstract contract StrykeTokenBase is
    Initializable,
    ERC20Upgradeable,
    ERC20PausableUpgradeable,
    AccessManagedUpgradeable,
    ERC20PermitUpgradeable,
    UUPSUpgradeable,
    IStrykeTokenBase
{
    /// @inheritdoc	IStrykeTokenBase
    function mint(address _to, uint256 _amount) public restricted {
        _mint(_to, _amount);
    }

    /// @inheritdoc	IStrykeTokenBase
    function burn(address _account, uint256 _amount) public restricted {
        _burn(_account, _amount);
    }

    /// @notice Function to pause the contract
    /// @dev Can only be called by admin
    function pause() public restricted {
        _pause();
    }

    /// @notice Function to pause the contract
    /// @dev Can only be called by admin
    function unpause() public restricted {
        _unpause();
    }

    function _authorizeUpgrade(address newImplementation) internal override restricted {}

    // The following functions are overrides required by Solidity.

    function _update(address from, address to, uint256 value)
        internal
        override(ERC20Upgradeable, ERC20PausableUpgradeable)
    {
        super._update(from, to, value);
    }
}
