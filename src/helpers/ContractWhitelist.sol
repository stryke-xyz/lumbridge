//SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.23;

/// @title ContractWhitelist
/// @author witherblock
/// @notice A helper contract that lets you add a list of whitelisted contracts that should be able to interact with restricited functions
abstract contract ContractWhitelist {
    /// @dev contract => whitelisted or not
    mapping(address => bool) public whitelistedContracts;

    /*==== ERRORS ====*/

    /// @dev Error indicating that the address provided is not a contract address.
    error ContractWhitelist_AddressNotContract();

    /// @dev Error indicating that the contract is already whitelisted.
    error ContractWhitelist_AlreadyWhitelisted();

    /// @dev Error indicating that the contract is not whitelisted.
    error ContractWhitelist_NotWhitelisted();

    /*==== SETTERS ====*/

    /// @dev add to the contract whitelist
    /// @param _contract the address of the contract to add to the contract whitelist
    /// @param _add boolean for adding or removing
    function updateContractWhitelist(address _contract, bool _add) public virtual {
        if (!isContract(_contract)) revert ContractWhitelist_AddressNotContract();
        if (whitelistedContracts[_contract]) revert ContractWhitelist_AlreadyWhitelisted();

        whitelistedContracts[_contract] = _add;

        emit ContractWhitelistUpdated(_contract, _add);
    }

    // modifier is eligible sender modifier
    function _isEligibleSender() internal view {
        // the below condition checks whether the caller is a contract or not
        if (msg.sender != tx.origin) {
            if (!whitelistedContracts[msg.sender]) revert ContractWhitelist_NotWhitelisted();
        }
    }

    /*==== VIEWS ====*/

    /// @dev checks for contract or EOA addresses
    /// @param addr the address to check
    /// @return bool whether the passed address is a contract address
    function isContract(address addr) public view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(addr)
        }
        return size > 0;
    }

    /*==== EVENTS ====*/

    /// @notice Emitted when the contract whitelist is updated
    /// @param _contract Address of the contract
    /// @param _add boolean for adding or removing
    event ContractWhitelistUpdated(address indexed _contract, bool _add);
}
