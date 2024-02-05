// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.23;

import {StrykeTokenBase} from "./StrykeTokenBase.sol";

/// @title The SYK Token Child
/// @author witherblock
/// @notice The token contract deployed on any chain but Arbitrum
/// @dev Contains logic for inflation management
contract StrykeTokenChild is StrykeTokenBase {
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
    }
}
