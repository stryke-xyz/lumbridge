// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {OAppReceiver, Origin} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OAppReceiver.sol";
import {OAppCore, Ownable} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OAppCore.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {OApp, Origin, MessagingFee} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OApp.sol";
import {IGaugeController, VoteParams, PullParams} from "../../interfaces/IGaugeController.sol";
import {Test, console} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import {SykLzAdapter, SendParams} from "../../token/bridge-adapters/SykLzAdapter.sol";
import {XSykStaking} from "../XSykStaking.sol";

contract XSykStakingLzAdapter is OApp {
    using SafeERC20 for IERC20;
    using OptionsBuilder for bytes;

    address public immutable xSykStaking;

    address public immutable xSyk;

    address public immutable syk;

    address public immutable sykLzAdapter;

    uint32 public immutable dstEid;

    /// @notice xSYK reward conversion percentage.
    uint256 public xSykRewardPercentage;

    uint8 public constant STAKE_TYPE = 1;
    uint8 public constant UNSTAKE_TYPE = 2;
    uint8 public constant CLAIM_TYPE = 3;
    uint8 public constant EXIT_TYPE = 4;

    mapping(address => uint256) public balanceOf;

    /// @notice Emitted when the xSYK reward conversion percentage is updated.
    /// @param xSykRewardPercentage The percentage of SYK rewards to be sent in xSYK
    event XSykRewardPercentageUpdated(uint256 xSykRewardPercentage);

    error InsufficientBalance();

    error NoStakedAmountFound();

    constructor(
        address _endpoint,
        address _owner,
        address _xSykStaking,
        address _xSyk,
        address _syk,
        address _sykLzAdapter,
        uint32 _dstEid
    ) OApp(_endpoint, _owner) Ownable(_owner) {
        xSykStaking = _xSykStaking;
        xSyk = _xSyk;
        syk = _syk;
        sykLzAdapter = _sykLzAdapter;
        dstEid = _dstEid;
    }

    /// @notice Updates xSYK reward conversion percentage.
    /// @dev Restricted to contract administrators.
    /// @param _xSykRewardPercentage The percentage of SYK rewards to be sent in xSYK
    function updateXSykRewardPercentage(uint256 _xSykRewardPercentage) external onlyOwner {
        xSykRewardPercentage = _xSykRewardPercentage;

        emit XSykRewardPercentageUpdated(_xSykRewardPercentage);
    }

    function stake(uint256 _amount, bytes calldata _options) external payable {
        uint256 balance = IERC20Metadata(xSyk).balanceOf(msg.sender);

        if (balance < _amount) {
            revert InsufficientBalance();
        }

        IERC20(xSyk).safeTransferFrom(msg.sender, address(this), _amount);

        balanceOf[msg.sender] += _amount;

        bytes memory payload = abi.encode(STAKE_TYPE, _amount, msg.sender);

        // TODO: CHECK RETRY MECHANISM
        _lzSend(
            dstEid, // Destination chain's endpoint ID.
            payload, // Encoded message payload being sent.
            _options, // Message execution options (e.g., gas to use on destination).
            MessagingFee(msg.value, 0), // Fee struct containing native gas and ZRO token.
            payable(msg.sender) // The refund address in case the send call reverts.
        );
    }

    function unstake(uint256 _amount, bytes calldata _options) external payable {
        _unstake(msg.sender, _amount);

        bytes memory payload = abi.encode(UNSTAKE_TYPE, _amount, msg.sender);

        _lzSend(
            dstEid, // Destination chain's endpoint ID.
            payload, // Encoded message payload being sent.
            _options, // Message execution options (e.g., gas to use on destination).
            MessagingFee(msg.value, 0), // Fee struct containing native gas and ZRO token.
            payable(msg.sender) // The refund address in case the send call reverts.
        );
    }

    function claim(bytes calldata _options) external payable {
        bytes memory payload = abi.encode(CLAIM_TYPE, 0, msg.sender);

        _lzSend(
            dstEid, // Destination chain's endpoint ID.
            payload, // Encoded message payload being sent.
            _options, // Message execution options (e.g., gas to use on destination).
            MessagingFee(msg.value, 0), // Fee struct containing native gas and ZRO token.
            payable(msg.sender) // The refund address in case the send call reverts.
        );
    }

    function exit(bytes calldata _options) external payable {
        _unstake(msg.sender, balanceOf[msg.sender]);

        bytes memory payload = abi.encode(EXIT_TYPE, 0, msg.sender);

        _lzSend(
            dstEid, // Destination chain's endpoint ID.
            payload, // Encoded message payload being sent.
            _options, // Message execution options (e.g., gas to use on destination).
            MessagingFee(msg.value, 0), // Fee struct containing native gas and ZRO token.
            payable(msg.sender) // The refund address in case the send call reverts.
        );
    }

    function _lzReceive(Origin calldata _origin, bytes32 _guid, bytes calldata _message, address, bytes calldata)
        internal
        override
    {
        (uint8 MSG_TYPE, uint256 _amount, address _account) = abi.decode(_message, (uint8, uint256, address));
        if (MSG_TYPE == 1) {
            XSykStaking(xSykStaking).stake(_amount, _account);
        } else if (MSG_TYPE == 2) {
            XSykStaking(xSykStaking).unstake(_amount, _account);
        } else if (MSG_TYPE == 3) {
            uint256 reward = XSykStaking(xSykStaking).claim(_account);
            uint256 xSykReward = (reward * xSykRewardPercentage) / 100;
            _sendSyk(_origin.srcEid, reward, xSykReward, _account);
        } else if (MSG_TYPE == 4) {
            (, uint256 reward) = XSykStaking(xSykStaking).exit(_account);
            uint256 xSykReward = (reward * xSykRewardPercentage) / 100;
            _sendSyk(_origin.srcEid, reward, xSykReward, _account);
        }
    }

    function _unstake(address _account, uint256 _amount) private {
        uint256 balance = balanceOf[_account];

        if (balance < _amount) {
            revert InsufficientBalance();
        }

        IERC20(xSyk).safeTransfer(_account, _amount);

        balanceOf[_account] -= _amount;
    }

    function _sendSyk(uint32 _dstEid, uint256 _amount, uint256 _xSykAmount, address _to) private {
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);

        SendParams memory sendParams =
            SendParams({dstEid: _dstEid, to: _to, amount: _amount, options: options, xSykAmount: _xSykAmount});

        MessagingFee memory msgFee = SykLzAdapter(sykLzAdapter).quoteSend(sendParams, false);

        // The msg.value should include any the fees to bridge back the SYK, incase the msg.value is not enough, this contract can store funds in order to prevent any failures
        SykLzAdapter(sykLzAdapter).send{value: msgFee.nativeFee}(sendParams, msgFee, address(this));
    }

    function addressToBytes32(address _addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }

    function bytes32ToAddress(bytes32 _bytes) internal pure returns (address) {
        return address(uint160(uint256(_bytes)));
    }

    // be able to receive ether
    receive() external payable virtual {}

    fallback() external payable {}
}
