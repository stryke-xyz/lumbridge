// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.23;

import {StrykeTokenBase} from "./StrykeTokenBase.sol";

import {IStrykeTokenRoot} from "../interfaces/IStrykeTokenRoot.sol";
import {IStrykeTokenBase} from "../interfaces/IStrykeTokenBase.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title The SYK Token Root
/// @author witherblock
/// @notice The token contract deployed on Arbitrum
/// @dev Contains logic for inflation management
contract StrykeTokenRoot is StrykeTokenBase, IStrykeTokenRoot {
    /// @inheritdoc	IStrykeTokenRoot
    uint256 public inflationPerYear;

    /// @inheritdoc	IStrykeTokenRoot
    uint256 public emissionRatePerSecond;

    /// @inheritdoc	IStrykeTokenRoot
    uint256 public maxSupply;

    /// @dev The amount of tokens minted using the stryke() fn
    uint256 public totalStryked;

    /// @dev The amount of tokens minted using adminMint() fn
    uint256 public totalMinted;

    /// @dev Last time inflation was updated
    uint256 public lastInflationUpdated;

    /// @notice A constant representing 1 year in seconds
    uint256 public constant ONE_YEAR = 365 days;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Function to initialize the proxy
    /// @param initialAuthority address of the access manager contract
    function initialize(address initialAuthority) public initializer {
        __ERC20_init("StrykeToken", "SYK");
        __ERC20Pausable_init();
        __AccessManaged_init(initialAuthority);
        __ERC20Permit_init("StrykeToken");
        __UUPSUpgradeable_init();
        maxSupply = 100_000_000 ether; // 100 million tokens
    }

    /// @inheritdoc	IStrykeTokenRoot
    function stryke(uint256 _amount) external restricted {
        if (totalStryked + _amount > ((block.timestamp - lastInflationUpdated)) * emissionRatePerSecond) {
            revert StrykeTokenRoot_InflationExceeding();
        }

        if (totalStryked + totalMinted + _amount > maxSupply) {
            revert StrykeTokenRoot_MaxSupplyReached();
        }

        totalStryked += _amount;

        _mint(msg.sender, _amount);
    }

    /// @inheritdoc	IStrykeTokenRoot
    function setInflationPerYear(uint256 _inflationPerYear) external restricted {
        inflationPerYear = _inflationPerYear;
        emissionRatePerSecond = _inflationPerYear / ONE_YEAR;
        lastInflationUpdated = block.timestamp;

        emit InflationPerYearSet(_inflationPerYear, emissionRatePerSecond);
    }

    /// @inheritdoc	IStrykeTokenRoot
    function adminMint(address _to, uint256 _amount) external restricted {
        if (totalStryked + totalMinted + _amount > maxSupply) {
            revert StrykeTokenRoot_MaxSupplyReached();
        }

        totalMinted += _amount;

        super.mint(_to, _amount);
    }
}
