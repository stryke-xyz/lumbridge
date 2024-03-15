// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.23;

import {StrykeTokenBase} from "./StrykeTokenBase.sol";

import {IStrykeTokenRoot} from "../interfaces/IStrykeTokenRoot.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title The SYK Token Root
/// @author witherblock
/// @notice The token contract deployed on Arbitrum
/// @dev Contains logic for inflation management
contract StrykeTokenRoot is StrykeTokenBase, IStrykeTokenRoot {
    /// @inheritdoc	IStrykeTokenRoot
    uint256 public genesis;

    /// @inheritdoc	IStrykeTokenRoot
    uint256 public inflationPerYear;

    /// @inheritdoc	IStrykeTokenRoot
    uint256 public emissionRatePerSecond;

    /// @inheritdoc	IStrykeTokenRoot
    uint256 public maxSupply;

    uint256 public totalMinted;

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
        genesis = block.timestamp;
    }

    /// @inheritdoc	IStrykeTokenRoot
    function availableSupply() public view returns (uint256) {
        return Math.min(totalMinted + ((block.timestamp - genesis)) * emissionRatePerSecond, maxSupply);
    }

    /// @inheritdoc	IStrykeTokenRoot
    function stryke(uint256 _amount) external restricted {
        if (totalMinted + _amount > availableSupply()) {
            revert StrykeTokenRoot_InflationExceeding();
        }
        _mint(msg.sender, _amount);
    }

    /// @inheritdoc	IStrykeTokenRoot
    function setInflationPerYear(uint256 _inflationPerYear) external restricted {
        inflationPerYear = _inflationPerYear;
        emissionRatePerSecond = _inflationPerYear / ONE_YEAR;

        emit InflationPerYearSet(_inflationPerYear, emissionRatePerSecond);
    }

    function _update(address from, address to, uint256 value) internal override(StrykeTokenBase) {
        if (from == address(0)) {
            totalMinted += value;
        }

        super._update(from, to, value);
    }
}
