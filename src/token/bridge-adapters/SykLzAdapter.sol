// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {OApp} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OApp.sol";
import {OAppOptionsType3} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp//libs/OAppOptionsType3.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISykBridgeController} from "../../interfaces/ISykBridgeController.sol";
import {IXStrykeToken} from "../../interfaces/IXStrykeToken.sol";
import {ISykLzAdapter, SendParams, Origin, MessagingFee, MessagingReceipt} from "../../interfaces/ISykLzAdapter.sol";

/// @title The SYK LayerZero Adapter (uses LayerZero V2)
/// @author witherblock
/// @notice The Bridge Adapter that uses LayerZero to bridge tokens to different chains
/// @dev Is permissioned by the Bridge Controller to mint and burn
contract SykLzAdapter is ISykLzAdapter, OApp, OAppOptionsType3 {
    /// @dev The SYK Bridge Controller
    ISykBridgeController public immutable sykBridgeController;

    IERC20 public immutable syk;

    /// @dev xSYK token address
    IXStrykeToken public immutable xSyk;

    uint16 public constant SEND_TYPE = 0;

    /// @dev Constructor
    /// @param _endpoint LayerZero Endpoint address
    /// @param _owner Owner address for the adapter
    /// @param _sykBridgeController Address for the SYK Bridge Controller
    /// @param _xSyk Address of xSYK token
    constructor(address _endpoint, address _owner, address _sykBridgeController, address _syk, address _xSyk)
        OApp(_endpoint, _owner)
        Ownable(_owner)
    {
        sykBridgeController = ISykBridgeController(_sykBridgeController);
        syk = IERC20(_syk);
        xSyk = IXStrykeToken(_xSyk);
    }

    /// @inheritdoc ISykLzAdapter
    function quoteSend(SendParams calldata _sendParams, bool _payInLzToken)
        external
        view
        returns (MessagingFee memory msgFee)
    {
        // Craft the message
        bytes memory message = abi.encode(_sendParams.to, _sendParams.amount, _sendParams.xSykAmount);

        // Calculates the LayerZero fee for the send() operation.
        return _quote(
            _sendParams.dstEid,
            message,
            combineOptions(_sendParams.dstEid, SEND_TYPE, _sendParams.options),
            _payInLzToken
        );
    }

    /// @inheritdoc ISykLzAdapter
    function send(SendParams calldata _sendParams, MessagingFee calldata _fee, address _refundAddress)
        external
        payable
        returns (MessagingReceipt memory msgReceipt)
    {
        if (_sendParams.amount < _sendParams.xSykAmount) revert SykLzAdapter_InvalidAmount();

        // Burns SYK via the BridgeController
        _debit(_sendParams.amount);

        // Craft the message
        bytes memory message = abi.encode(_sendParams.to, _sendParams.amount, _sendParams.xSykAmount);

        // Sends the message to the LayerZero endpoint and returns the LayerZero msg receipt.
        msgReceipt = _lzSend(
            _sendParams.dstEid,
            message,
            combineOptions(_sendParams.dstEid, SEND_TYPE, _sendParams.options),
            _fee,
            _refundAddress
        );

        emit SykSent(msgReceipt, _sendParams.dstEid, _sendParams.to, _sendParams.amount);
    }

    /// @dev Internal function to handle the receive on the LayerZero endpoint.
    /// @param _origin The origin information.
    ///  - srcEid: The source chain endpoint ID.
    ///  - sender: The sender address from the src chain.
    ///  - nonce: The nonce of the LayerZero message.
    /// @param _guid The unique identifier for the received LayerZero message.
    /// @param _message The encoded message.
    /// @dev _executor The address of the executor.
    /// @dev _extraData Additional data.
    function _lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address, /*_executor*/ // @dev unused in the default implementation.
        bytes calldata /*_extraData*/ // @dev unused in the default implementation.
    ) internal virtual override {
        // Decode the message
        (address to, uint256 amount, uint256 xSykAmount) = abi.decode(_message, (address, uint256, uint256));

        uint256 sykAmount = amount - xSykAmount;

        // Mints the SYK amount to the 'to' address
        _credit(to, sykAmount);

        if (xSykAmount > 0) {
            _credit(address(this), xSykAmount);
            syk.approve(address(xSyk), xSykAmount);
            xSyk.convert(xSykAmount, to);
        }

        emit SykReceived(_guid, _origin.srcEid, to, amount);
    }

    /// @dev Internal function to perform a debit operation.
    /// @param _amount The amount to send.
    function _debit(uint256 _amount) internal {
        sykBridgeController.burn(msg.sender, _amount);
    }

    /// @dev Internal function to perform a credit operation.
    /// @param _to The address to credit.
    /// @param _amount The amount to credit.
    function _credit(address _to, uint256 _amount) internal {
        sykBridgeController.mint(_to, _amount);
    }
}
