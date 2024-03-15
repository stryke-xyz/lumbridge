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

import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Test, console} from "forge-std/Test.sol";

/// @title XSykStakingLzAdapter Contract
/// @notice This contract facilitates staking, unstaking, claiming rewards, and exiting for xSYK tokens through LayerZero messaging.
contract XSykStakingLzAdapter is IXSykStakingLzAdapter, OApp, OAppOptionsType3 {
    using SafeERC20 for IERC20;
    using OptionsBuilder for bytes;

    /*==== STATE VARIABLES ====*/

    /// @notice XSykStaking contract
    IXSykStaking public immutable xSykStaking;

    /// @notice xSYK contract
    IERC20 public immutable xSyk;

    /// @notice SYK Bridge Adapter contract
    ISykLzAdapter public immutable sykLzAdapter;

    /// @notice xSYK reward conversion percentage.
    uint256 public xSykRewardPercentage;

    /// @notice Destination LayerZero endpoint ID of the chain where the XSykStaking contract is deployed
    uint32 public immutable dstEid;

    /// @notice Stake type in uint8
    uint16 public constant STAKE_TYPE = 1;

    /// @notice Unstake type in uint8
    uint16 public constant UNSTAKE_TYPE = 2;

    /// @notice Claim type in uint8
    uint16 public constant CLAIM_TYPE = 3;

    /// @notice Exit type in uint8
    uint16 public constant EXIT_TYPE = 4;

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

    /*==== RESTRICTED FUNCTIONS ====*/

    /// @notice Updates xSYK reward conversion percentage.
    /// @dev Restricted to contract administrators.
    /// @param _xSykRewardPercentage The percentage of SYK rewards to be sent in xSYK
    function updateXSykRewardPercentage(uint256 _xSykRewardPercentage) external onlyOwner {
        xSykRewardPercentage = _xSykRewardPercentage;

        emit XSykRewardPercentageUpdated(_xSykRewardPercentage);
    }

    /*==== PUBLIC FUNCTIONS ====*/

    function quote(uint16 _msgType, uint256 _amount, bytes calldata _options)
        external
        view
        returns (MessagingFee memory msgFee)
    {
        // Craft the message
        bytes memory message = abi.encode(_msgType, _amount, block.chainid, msg.sender);

        // Calculates the LayerZero fee for the send() operation.
        return _quote(dstEid, message, _options, false);
    }

    /// @inheritdoc IXSykStakingLzAdapter
    function stake(uint256 _amount, bytes calldata _options)
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

        bytes memory payload = abi.encode(STAKE_TYPE, _amount, block.chainid, msg.sender);

        msgReceipt = _lzSend(
            dstEid, // Destination chain's endpoint ID.
            payload, // Encoded message payload being sent.
            combineOptions(dstEid, STAKE_TYPE, _options), // Message execution options (e.g., gas to use on destination).
            MessagingFee(msg.value, 0), // Fee struct containing native gas and ZRO token.
            payable(msg.sender) // The refund address in case the send call reverts.
        );

        emit Staked(msg.sender, _amount, msgReceipt);
    }

    /// @inheritdoc IXSykStakingLzAdapter
    function unstake(uint256 _amount, bytes calldata _options)
        external
        payable
        returns (MessagingReceipt memory msgReceipt)
    {
        _unstake(msg.sender, _amount);

        bytes memory payload = abi.encode(UNSTAKE_TYPE, _amount, block.chainid, msg.sender);

        msgReceipt = _lzSend(
            dstEid, // Destination chain's endpoint ID.
            payload, // Encoded message payload being sent.
            combineOptions(dstEid, UNSTAKE_TYPE, _options), // Message execution options (e.g., gas to use on destination).
            MessagingFee(msg.value, 0), // Fee struct containing native gas and ZRO token.
            payable(msg.sender) // The refund address in case the send call reverts.
        );

        emit Unstaked(msg.sender, _amount, msgReceipt);
    }

    /// @inheritdoc IXSykStakingLzAdapter
    function claim(bytes calldata _options) external payable returns (MessagingReceipt memory msgReceipt) {
        bytes memory payload = abi.encode(CLAIM_TYPE, 0, block.chainid, msg.sender);

        msgReceipt = _lzSend(
            dstEid, // Destination chain's endpoint ID.
            payload, // Encoded message payload being sent.
            combineOptions(dstEid, CLAIM_TYPE, _options), // Message execution options (e.g., gas to use on destination).
            MessagingFee(msg.value, 0), // Fee struct containing native gas and ZRO token.
            payable(msg.sender) // The refund address in case the send call reverts.
        );

        emit Claimed(msg.sender, msgReceipt);
    }

    /// @inheritdoc IXSykStakingLzAdapter
    function exit(bytes calldata _options) external payable returns (MessagingReceipt memory msgReceipt) {
        uint256 accountBalance = balanceOf[msg.sender];

        _unstake(msg.sender, balanceOf[msg.sender]);

        bytes memory payload = abi.encode(EXIT_TYPE, 0, block.chainid, msg.sender);

        msgReceipt = _lzSend(
            dstEid, // Destination chain's endpoint ID.
            payload, // Encoded message payload being sent.
            combineOptions(dstEid, EXIT_TYPE, _options), // Message execution options (e.g., gas to use on destination).
            MessagingFee(msg.value, 0), // Fee struct containing native gas and ZRO token.
            payable(msg.sender) // The refund address in case the send call reverts.
        );

        emit Exited(msg.sender, accountBalance, msgReceipt);
    }

    /*==== INTERNAL FUNCTIONS ====*/

    function _lzReceive(Origin calldata _origin, bytes32 _guid, bytes calldata _message, address, bytes calldata)
        internal
        override
    {
        (uint16 MSG_TYPE, uint256 _amount, uint256 _chainId, address _account) =
            abi.decode(_message, (uint16, uint256, uint256, address));
        if (MSG_TYPE == 1) {
            xSykStaking.stake(_amount, _chainId, _account);
        } else if (MSG_TYPE == 2) {
            xSykStaking.unstake(_amount, _chainId, _account);
        } else if (MSG_TYPE == 3) {
            uint256 reward = xSykStaking.claim(_chainId, _account);
            uint256 xSykReward = (reward * xSykRewardPercentage) / 100;
            _sendSyk(_origin.srcEid, reward, xSykReward, _account);
        } else if (MSG_TYPE == 4) {
            (, uint256 reward) = xSykStaking.exit(_chainId, _account);
            uint256 xSykReward = (reward * xSykRewardPercentage) / 100;
            _sendSyk(_origin.srcEid, reward, xSykReward, _account);
        }

        emit MessageReceived(MSG_TYPE, _amount, _account, _guid, _origin.srcEid);
    }

    function _unstake(address _account, uint256 _amount) private {
        uint256 balance = balanceOf[_account];

        if (balance < _amount) {
            revert XSykStakingLzAdapter_InsufficientBalance();
        }

        xSyk.safeTransfer(_account, _amount);

        balanceOf[_account] -= _amount;
    }

    function _sendSyk(uint32 _dstEid, uint256 _amount, uint256 _xSykAmount, address _to) private {
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);

        SendParams memory sendParams =
            SendParams({dstEid: _dstEid, to: _to, amount: _amount, options: options, xSykAmount: _xSykAmount});

        MessagingFee memory msgFee = sykLzAdapter.quoteSend(sendParams, false);

        // The msg.value should include any the fees to bridge back the SYK, incase the msg.value is not enough, this contract can store funds in order to prevent any failures
        sykLzAdapter.send{value: msgFee.nativeFee}(sendParams, msgFee, address(this));
    }

    // be able to receive ether
    receive() external payable virtual {}

    fallback() external payable {}
}
