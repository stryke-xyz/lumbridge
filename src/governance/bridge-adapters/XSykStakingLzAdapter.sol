// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {OApp, Origin, MessagingFee, MessagingReceipt} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OApp.sol";
import {OAppOptionsType3} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp//libs/OAppOptionsType3.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IXSykStakingLzAdapter} from "../../interfaces/IXSykStakingLzAdapter.sol";
import {IGaugeController, VoteParams, PullParams} from "../../interfaces/IGaugeController.sol";
import {ISykLzAdapter, SendParams} from "../../interfaces/ISykLzAdapter.sol";
import {IXSykStaking} from "../../interfaces/IXSykStaking.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title XSykStakingLzAdapter Contract
/// @notice This contract facilitates staking, unstaking, claiming rewards, and exiting for xSYK tokens through LayerZero messaging.
contract XSykStakingLzAdapter is IXSykStakingLzAdapter, OApp, OAppOptionsType3 {
    using SafeERC20 for IERC20;

    /*==== STATE VARIABLES ====*/

    /// @notice XSykStaking contract
    IXSykStaking public immutable xSykStaking;

    /// @notice xSYK contract
    IERC20 public immutable xSyk;

    /// @notice SYK Bridge Adapter contract
    ISykLzAdapter public immutable sykLzAdapter;

    /// @notice Destination LayerZero endpoint ID of the chain where the XSykStaking contract is deployed
    uint32 public immutable dstEid;

    /// @notice Stake type in uint16
    uint16 public constant STAKE_TYPE = 0;

    /// @notice Unstake type in uint16
    uint16 public constant UNSTAKE_TYPE = 1;

    /// @notice Claim type in uint16
    uint16 public constant CLAIM_TYPE = 2;

    /// @notice Finalize Unstake type in uint16
    uint16 public constant FINALIZE_UNSTAKE_TYPE = 3;

    /// @notice account => balance
    mapping(address => uint256) public balanceOf;

    /// @notice Constructor
    /// @param _endpoint Address of the LayerZero endpoint for this chain.
    /// @param _owner Address of the contract owner.
    /// @param _xSykStaking Address of the XSykStaking contract.
    /// @param _xSyk Address of the xSYK token contract.
    /// @param _sykLzAdapter Address of the SykLzAdapter for cross-chain communication.
    /// @param _dstEid Destination LayerZero endpoint ID of the chain where the XSykStaking contract is deployed
    constructor(
        address _endpoint,
        address _owner,
        address _xSykStaking,
        address _xSyk,
        address _sykLzAdapter,
        uint32 _dstEid
    ) OApp(_endpoint, _owner) Ownable(_owner) {
        xSykStaking = IXSykStaking(_xSykStaking);
        xSyk = IERC20(_xSyk);
        sykLzAdapter = ISykLzAdapter(_sykLzAdapter);
        dstEid = _dstEid;
    }

    /*==== OWNER FUNCTIONS ====*/

    /// @notice Recovers the native tokens of the chain from this contract if any
    function recoverNative() external onlyOwner {
        payable(msg.sender).transfer(address(this).balance);
    }

    /// @notice Finalizes the unstake for an account in case of any message dropping
    /// @param _account Address of the account
    /// @param _amount Amount to unstake
    function finalizeUnstake(address _account, uint256 _amount) external onlyOwner {
        _finalizeUnstake(_account, _amount);
    }

    /*==== PUBLIC FUNCTIONS ====*/

    /// @notice This function calculates the messaging fee required for sending a message via LayerZero.
    /// @param _msgType The message type identifier as a `uint16`.
    /// @param _dstEid The destination endpoint identifier as a `uint32`.
    /// @param _amount The amount of tokens or the value related to the message, specified as `uint256`.
    /// @param _abaOptions Options for any message that involves a ping back to the origin chain. ABA Message Pattern.
    /// @param _options Additional options for the message as a byte array.
    /// @param _payInLzToken A boolean indicating whether the LayerZero token (LZ) should be used for the payment of the messaging fee.
    /// @return msgFee A struct containing the details of the calculated messaging fee.
    function quote(
        uint16 _msgType,
        uint32 _dstEid,
        uint256 _amount,
        bytes memory _abaOptions,
        bytes memory _options,
        bool _payInLzToken
    ) public view returns (MessagingFee memory msgFee) {
        // Craft the message
        bytes memory message = abi.encode(_msgType, _amount, block.chainid, msg.sender, _abaOptions);

        // Calculates the LayerZero fee for the send() operation.
        return _quote(_dstEid, message, _options, _payInLzToken);
    }

    /// @inheritdoc IXSykStakingLzAdapter
    function stake(uint256 _amount, MessagingFee calldata _fee, bytes calldata _options)
        external
        payable
        returns (MessagingReceipt memory msgReceipt)
    {
        uint256 balance = xSyk.balanceOf(msg.sender);

        if (balance < _amount) {
            revert XSykStakingLzAdapter_InsufficientBalance();
        }

        xSyk.safeTransferFrom(msg.sender, address(this), _amount);

        balanceOf[msg.sender] += _amount;

        bytes memory payload = abi.encode(STAKE_TYPE, _amount, block.chainid, msg.sender, bytes(""));

        msgReceipt = _lzSend(
            dstEid, // Destination chain's endpoint ID.
            payload, // Encoded message payload being sent.
            combineOptions(dstEid, STAKE_TYPE, _options), // Message execution options (e.g., gas to use on destination).
            _fee, // Fee struct containing native gas and ZRO token.
            payable(msg.sender) // The refund address in case the send call reverts.
        );

        emit Staked(msg.sender, _amount, msgReceipt);
    }

    /// @inheritdoc IXSykStakingLzAdapter
    function unstake(
        uint256 _amount,
        MessagingFee calldata _fee,
        bytes calldata _finalizeUnstakeOptions,
        bytes calldata _options
    ) external payable returns (MessagingReceipt memory msgReceipt) {
        uint256 balance = balanceOf[msg.sender];

        if (balance < _amount) {
            revert XSykStakingLzAdapter_InsufficientBalance();
        }

        bytes memory payload = abi.encode(UNSTAKE_TYPE, _amount, block.chainid, msg.sender, _finalizeUnstakeOptions);

        msgReceipt = _lzSend(
            dstEid, // Destination chain's endpoint ID.
            payload, // Encoded message payload being sent.
            combineOptions(dstEid, UNSTAKE_TYPE, _options), // Message execution options (e.g., gas to use on destination).
            _fee, // Fee struct containing native gas and ZRO token.
            payable(msg.sender) // The refund address in case the send call reverts.
        );

        emit Unstaked(msg.sender, _amount, msgReceipt);
    }

    /// @inheritdoc IXSykStakingLzAdapter
    function claim(MessagingFee calldata _fee, bytes calldata _sendSykOptions, bytes calldata _options)
        external
        payable
        returns (MessagingReceipt memory msgReceipt)
    {
        bytes memory payload = abi.encode(CLAIM_TYPE, 0, block.chainid, msg.sender, _sendSykOptions);

        msgReceipt = _lzSend(
            dstEid, // Destination chain's endpoint ID.
            payload, // Encoded message payload being sent.
            combineOptions(dstEid, CLAIM_TYPE, _options), // Message execution options (e.g., gas to use on destination).
            _fee, // Fee struct containing native gas and ZRO token.
            payable(msg.sender) // The refund address in case the send call reverts.
        );

        emit Claimed(msg.sender, msgReceipt);
    }

    /*==== INTERNAL FUNCTIONS ====*/

    function _lzReceive(Origin calldata _origin, bytes32 _guid, bytes calldata _message, address, bytes calldata)
        internal
        override
    {
        (uint16 MSG_TYPE, uint256 _amount, uint256 _chainId, address _account, bytes memory _abaOptions) =
            abi.decode(_message, (uint16, uint256, uint256, address, bytes));

        if (MSG_TYPE == 0) {
            xSykStaking.stake(_amount, _chainId, _account);
        } else if (MSG_TYPE == 1) {
            // ABA Message Pattern
            xSykStaking.unstake(_amount, _chainId, _account);

            _sendFinalizeUnstake(_origin.srcEid, _amount, _chainId, _account, _abaOptions);
        } else if (MSG_TYPE == 2) {
            uint256 reward = xSykStaking.claim(_chainId, _account);
            uint256 xSykReward = (reward * xSykStaking.xSykRewardPercentage()) / 100;
            _sendSyk(_origin.srcEid, reward, xSykReward, _account, _abaOptions);
        } else if (MSG_TYPE == 3) {
            _finalizeUnstake(_account, _amount);
        }

        emit MessageReceived(MSG_TYPE, _amount, _account, _guid);
    }

    function _finalizeUnstake(address _account, uint256 _amount) private {
        uint256 balance = balanceOf[_account];

        if (balance < _amount) {
            revert XSykStakingLzAdapter_InsufficientBalance();
        }

        xSyk.safeTransfer(_account, _amount);

        balanceOf[_account] -= _amount;
    }

    function _sendSyk(uint32 _dstEid, uint256 _amount, uint256 _xSykAmount, address _to, bytes memory _options)
        private
    {
        SendParams memory sendParams =
            SendParams({dstEid: _dstEid, to: _to, amount: _amount, options: _options, xSykAmount: _xSykAmount});

        MessagingFee memory msgFee = sykLzAdapter.quoteSend(sendParams, false);

        // The msg.value should include any the fees to bridge back the SYK, incase the msg.value is not enough, this contract can store funds in order to prevent any failures
        sykLzAdapter.send{value: msgFee.nativeFee}(sendParams, msgFee, address(this));
    }

    function _sendFinalizeUnstake(
        uint32 _dstEid,
        uint256 _amount,
        uint256 _chainId,
        address _account,
        bytes memory _options
    ) private {
        _lzSend(
            _dstEid, // Destination chain's endpoint ID.
            abi.encode(FINALIZE_UNSTAKE_TYPE, _amount, _chainId, _account, bytes("")), // Encoded message payload being sent.
            _options, // Message execution options (e.g., gas to use on destination).
            quote(FINALIZE_UNSTAKE_TYPE, _dstEid, _amount, bytes(""), _options, false), // Fee struct containing native gas and ZRO token.
            address(this) // The refund address in case the send call reverts.
        );
    }

    // be able to receive native token
    receive() external payable virtual {}

    fallback() external payable {}
}
