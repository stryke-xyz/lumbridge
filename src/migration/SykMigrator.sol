// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.23;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStrykeTokenBase} from "../interfaces/IStrykeTokenBase.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Migrator
/// @author witherblock
/// @notice Handles the migration of DPX and rDPX tokens to SYK tokens according to specified conversion rates within a defined period. Only Available on Arbitrum.
/// @dev Inherits from AccessManaged for access control.
contract SykMigrator is AccessManaged {
    using SafeERC20 for IERC20;

    /// @notice Address of the DPX token contract.
    address public immutable dpx;

    /// @notice Address of the rDPX token contract.
    address public immutable rdpx;

    /// @notice Address of the SYK token contract.
    address public immutable syk;

    /// @notice Timestamp marking the end of the migration period.
    uint256 public migrationPeriodEnd;

    /// @notice Conversion rate for DPX to SYK migration, in 1e4 precision.
    uint256 public dpxConversionRate = 100 * 1e4;

    /// @notice Conversion rate for rDPX to SYK migration, in 1e4 precision.
    uint256 public rdpxConversionRate = 133333;

    /// @dev Indicates an operation with an invalid token address.
    error SykMigrator_InvalidToken();

    /// @dev Indicates an attempt to migrate after the migration period has ended.
    error SykMigrator_MigrationPeriodOver();

    /// @dev Indicates an attempt to extend the migration period before the migration period has ended.
    error SykMigrator_MigrationPeriodNotOver();

    /// @dev Emitted when the migrate() function is called
    /// @param sender msg.sender of the tx
    /// @param token Address of the token being migrated (DPX or rDPX)
    /// @param amount Amount of the token being migrated
    event Migrated(address sender, address token, uint256 amount);

    /// @dev Emitted when the extendMigrationPeriod() function is called
    /// @param newMigrationPeriodEnd The new migration period end
    /// @param extendBy The seconds extended by from the block.timestamp of this event
    event MigrationPeriodExtended(uint256 newMigrationPeriodEnd, uint256 extendBy);

    /// @dev Emitted when the recoverERC20() function is called
    /// @param tokens The ERC20 tokens recovered
    /// @param sender msg.sender
    event ERC20Recovered(address[] tokens, address sender);

    /// @notice Initializes contract with token addresses and sets the migration period.
    /// @param _dpx Address of the DPX token contract.
    /// @param _rdpx Address of the rDPX token contract.
    /// @param _syk Address of the SYK token contract.
    /// @param _initialAuthority Address of the AccessManager contract on Arbitrum
    constructor(address _dpx, address _rdpx, address _syk, address _initialAuthority)
        AccessManaged(_initialAuthority)
    {
        dpx = _dpx;
        rdpx = _rdpx;
        syk = _syk;
        migrationPeriodEnd = block.timestamp + 548 days; // Sets the migration period to one and a half years.
    }

    /// @notice Migrates tokens by transferring them to this contract and minting SYK tokens to the sender's account based on the conversion rate.
    /// @dev Reverts if the migration period is over or if an unsupported token is provided.
    /// @param _token Address of the token to migrate (DPX or rDPX).
    /// @param _amount Amount of tokens to migrate.
    function migrate(address _token, uint256 _amount) external {
        if (migrationPeriodEnd < block.timestamp) revert SykMigrator_MigrationPeriodOver();

        IERC20 token;
        uint256 conversionRate;

        if (_token == dpx) {
            token = IERC20(dpx);
            conversionRate = dpxConversionRate;
        } else if (_token == rdpx) {
            token = IERC20(rdpx);
            conversionRate = rdpxConversionRate;
        } else {
            revert SykMigrator_InvalidToken();
        }

        token.safeTransferFrom(msg.sender, address(this), _amount);
        IStrykeTokenBase(syk).mint(msg.sender, (conversionRate * _amount) / 1e4);

        emit Migrated(msg.sender, _token, _amount);
    }

    /// @notice Extends the migration period if over
    /// @dev Only accessible by users with the appropriate role (restricted access).
    /// @param _extendBy Extension time from block.timestamp in seconds
    function extendMigrationPeriod(uint256 _extendBy) external restricted {
        if (migrationPeriodEnd > block.timestamp) revert SykMigrator_MigrationPeriodNotOver();

        migrationPeriodEnd = block.timestamp + _extendBy;

        emit MigrationPeriodExtended(migrationPeriodEnd, _extendBy);
    }

    /// @notice Allows the recovery of ERC20 tokens sent to this contract.
    /// @dev Only accessible by users with the appropriate role (restricted access).
    /// @param _tokens Array of token addresses to recover.
    function recoverERC20(address[] memory _tokens) external restricted {
        uint256 tokensLength = _tokens.length;
        for (uint256 i; i < tokensLength;) {
            address token = _tokens[i];
            IERC20(token).safeTransfer(msg.sender, IERC20(token).balanceOf(address(this)));
            unchecked {
                ++i;
            }
        }

        emit ERC20Recovered(_tokens, msg.sender);
    }
}
