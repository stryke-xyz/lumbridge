// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {MessagingReceipt, MessagingFee} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OApp.sol";

interface IXSykStakingLzAdapter {
    /*==== EVENTS ====*/

    /// @notice Emitted when the xSYK reward conversion percentage is updated.
    /// @param xSykRewardPercentage The percentage of SYK rewards to be sent in xSYK
    event XSykRewardPercentageUpdated(uint256 xSykRewardPercentage);

    /// @dev Emitted when tokens are staked in the contract.
    /// @notice This event is fired whenever a user stakes tokens, indicating the amount staked.
    /// @param account The address of the account that staked tokens.
    /// @param amount The amount of tokens that were staked by the account.
    /// @param msgReceipt The receipt of the LZ message
    event Staked(address indexed account, uint256 amount, MessagingReceipt msgReceipt);

    /// @dev Emitted when staked tokens are withdrawn (unstaked) from the contract.
    /// @notice This event is fired whenever a user unstakes tokens, indicating the amount unstaked.
    /// @param account The address of the account that unstaked tokens.
    /// @param amount The amount of tokens that were unstaked by the account.
    /// @param msgReceipt The receipt of the LZ message
    event Unstaked(address indexed account, uint256 amount, MessagingReceipt msgReceipt);

    /// @dev Emitted when rewards are claimed by a staker.
    /// @notice This event is fired whenever a user claims their staking rewards, indicating the amount claimed.
    /// @param account The address of the account that claimed rewards.
    /// @param msgReceipt The receipt of the LZ message
    event Claimed(address indexed account, MessagingReceipt msgReceipt);

    /// @dev Emitted when an account is exiting the staking pool.
    /// @param account The address of the account that is exiting.
    /// @param amount The amount of balance that was withdrawn.
    /// @param msgReceipt The receipt of the LZ message
    event Exited(address indexed account, uint256 amount, MessagingReceipt msgReceipt);

    /// @dev Emitted when this contract receives a message via LayerZero.
    /// @param messageType Message type (stake, unstake, claim, exit).
    /// @param amount Amount to stake or unstake, 0 for claim and exit.
    /// @param account Address of the account.
    /// @param guid Identifier for the LayerZero message.
    /// @param srcEid Source Endpoint ID.
    event MessageReceived(uint16 messageType, uint256 amount, address account, bytes32 guid, uint32 srcEid);

    /*==== ERRORS ====*/

    /// @dev Indicates an operation was attempted with an insufficient token balance.
    error XSykStakingLzAdapter_InsufficientBalance();

    /// @dev Indicates an attempt to perform an operation without a corresponding staked amount.
    error XSykStakingLzAdapter_NoStakedAmountFound();

    /*==== PUBLIC FUNCTIONS ====*/

    /// @notice Returns the staked balance of the account.
    /// @param _account Address of the account.
    /// @return balance Balance of the account.
    function balanceOf(address _account) external view returns (uint256 balance);

    /// @notice Allows users to stake xSYK tokens and triggers a cross-chain message to the destination chain.
    /// @param _amount The amount of xSYK tokens to stake.
    /// @param _fee The calculated fee for the send() operation.
    ///      - nativeFee: The native fee.
    ///      - lzTokenFee: The lzToken fee.
    /// @param _options LayerZero message options for cross-chain communication.
    /// @return msgReceipt The receipt of the LayerZero message.
    function stake(uint256 _amount, MessagingFee calldata _fee, bytes calldata _options)
        external
        payable
        returns (MessagingReceipt memory msgReceipt);

    /// @notice Allows users to unstake xSYK tokens and triggers a cross-chain message to the destination chain.
    /// @param _amount The amount of xSYK tokens to unstake.
    /// @param _fee The calculated fee for the send() operation.
    ///      - nativeFee: The native fee.
    ///      - lzTokenFee: The lzToken fee.
    /// @param _options LayerZero message options for cross-chain communication.
    /// @return msgReceipt The receipt of the LayerZero message.
    function unstake(uint256 _amount, MessagingFee calldata _fee, bytes calldata _options)
        external
        payable
        returns (MessagingReceipt memory msgReceipt);

    /// @notice Allows users to claim their rewards, triggering a cross-chain message to handle the reward distribution.
    /// @param _fee The calculated fee for the send() operation.
    ///      - nativeFee: The native fee.
    ///      - lzTokenFee: The lzToken fee.
    /// @param _options LayerZero message options for cross-chain communication.
    /// @return msgReceipt The receipt of the LayerZero message.
    function claim(MessagingFee calldata _fee, bytes calldata _options)
        external
        payable
        returns (MessagingReceipt memory msgReceipt);

    /// @notice Allows users to exit the staking pool, unstaking their tokens and claiming any rewards in a single transaction.
    /// @param _fee The calculated fee for the send() operation.
    ///      - nativeFee: The native fee.
    ///      - lzTokenFee: The lzToken fee.
    /// @param _options LayerZero message options for cross-chain communication.
    /// @return msgReceipt The receipt of the LayerZero message.
    function exit(MessagingFee calldata _fee, bytes calldata _options)
        external
        payable
        returns (MessagingReceipt memory msgReceipt);
}
