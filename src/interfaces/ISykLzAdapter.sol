// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import {Origin, MessagingFee, MessagingReceipt} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OApp.sol";

/// @dev Struct representing token parameters for the send() operation.
struct SendParams {
    uint32 dstEid; // Destination endpoint ID.
    address to; // Recipient address.
    uint256 amount; // Amount to send.
    uint256 xSykAmount; // Amount to receive in xSYK.
    bytes options; // Options supplied by the caller to be used in the LayerZero message.
}

interface ISykLzAdapter {
    /// @notice Reverts with this error if the amount of SYK is lesser than the amount of xSYK passed
    error SykLzAdapter_InvalidAmount();

    /// @notice Emitted on send()
    /// @param msgReceipt LayerZero Message Receipt.
    /// @param dstEid Destination Endpoint ID.
    /// @param fromAddress Address of the sender on the src chain.
    /// @param amount Amount of tokens sent.
    event SykSent(MessagingReceipt msgReceipt, uint32 indexed dstEid, address indexed fromAddress, uint256 amount);

    /// @notice Emitted on lzReceive()
    /// @param guid GUID of the Bridge message.
    /// @param srcEid Source Endpoint ID.
    /// @param toAddress Address of the recipient on the dst chain.
    /// @param amount Amount of tokens received.
    event SykReceived(bytes32 guid, uint32 srcEid, address toAddress, uint256 amount);

    /// @notice Provides a quote for the send() operation.
    /// @param _sendParams The parameters for the send() operation.
    /// @param _payInLzToken Flag indicating whether the caller is paying in the LZ token.
    /// @return msgFee The calculated LayerZero messaging fee from the send() operation.
    ///
    /// @dev MessagingFee: LayerZero msg fee
    ///  - nativeFee: The native fee.
    ///  - lzTokenFee: The lzToken fee.
    function quoteSend(SendParams calldata _sendParams, bool _payInLzToken)
        external
        view
        returns (MessagingFee memory msgFee);

    /// @dev Executes the send operation.
    /// @param _sendParams The parameters for the send operation.
    /// @param _fee The calculated fee for the send() operation.
    ///      - nativeFee: The native fee.
    ///      - lzTokenFee: The lzToken fee.
    /// @param _refundAddress The address to receive any excess funds.
    /// @return msgReceipt The receipt for the send operation.
    ///
    /// @dev MessagingReceipt: LayerZero msg receipt
    ///  - guid: The unique identifier for the sent message.
    ///  - nonce: The nonce of the sent message.
    ///  - fee: The LayerZero fee incurred for the message.
    function send(SendParams calldata _sendParams, MessagingFee calldata _fee, address _refundAddress)
        external
        payable
        returns (MessagingReceipt memory msgReceipt);
}
