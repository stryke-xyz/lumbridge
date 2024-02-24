// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {OApp, Origin, MessagingFee, MessagingReceipt} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OApp.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISykLzAdapter, SendParams} from "../../interfaces/ISykLzAdapter.sol";
import {IGaugeController, VoteParams, PullParams} from "../../interfaces/IGaugeController.sol";
import {IXSykStakingLzAdapter} from "../../interfaces/IXSykStakingLzAdapter.sol";

import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";

/// @title GaugeController LayerZero Adapter
/// @notice Facilitates cross-chain interactions for voting and pulling rewards associated with gauge mechanisms.
/// @dev Extends `OApp` for LayerZero messaging, enabling cross-chain gauge operations.
contract GaugeControllerLzAdapter is OApp {
    using OptionsBuilder for bytes;

    /// @notice Reference to the GaugeController contract.
    IGaugeController public immutable gaugeController;

    /// @notice Token used for staking and voting in the gauge system.
    IERC20 public immutable xSyk;

    /// @notice Reference to the SykLzAdapter for cross-chain token transfers.
    ISykLzAdapter public immutable sykLzAdapter;

    /// @notice Address of the LayerZero adapter for the xSyk staking contract.
    IXSykStakingLzAdapter public immutable xSykStakingLzAdapter;

    /// @notice Destination endpoint ID for cross-chain messages.
    uint32 public immutable dstEid;

    /// @notice Emitted when a vote is cast via LayerZero.
    /// @param voteParams The parameters of the vote cast.
    /// @param msgReceipt The LayerZero messaging receipt.
    event Voted(VoteParams voteParams, MessagingReceipt msgReceipt);

    /// @notice Emitted when rewards are pulled via LayerZero.
    /// @param pullParams The parameters of the pull request.
    /// @param msgReceipt The LayerZero messaging receipt.
    event RewardPulled(PullParams pullParams, MessagingReceipt msgReceipt);

    /// @dev Emitted when this contract receives a message via LayerZero.
    /// @param message Message payload.
    /// @param guid Identifier for the LayerZero message.
    /// @param srcEid Source Endpoint ID.
    event MessageReceived(bytes message, bytes32 guid, uint32 srcEid);

    /// @dev Thrown when a user attempts to vote with more power than available.
    error GaugeControllerLzAdapter_NotEnoughPowerAvailable();

    /// @dev Constructor.
    /// @param _endpoint Address of the LayerZero endpoint contract.
    /// @param _owner Address to be set as the owner of the contract.
    /// @param _gaugeController Address of the GaugeController contract.
    /// @param _xSyk Address of the xSyk token contract.
    /// @param _sykLzAdapter Address of the SykLzAdapter contract.
    /// @param _xSykStakingLzAdapter Address of the xSyk Staking LayerZero adapter.
    /// @param _dstEid Destination endpoint ID for cross-chain messaging.
    constructor(
        address _endpoint,
        address _owner,
        address _gaugeController,
        address _xSyk,
        address _sykLzAdapter,
        address _xSykStakingLzAdapter,
        uint32 _dstEid
    ) OApp(_endpoint, _owner) Ownable(_owner) {
        gaugeController = IGaugeController(_gaugeController);
        xSyk = IERC20(_xSyk);
        sykLzAdapter = ISykLzAdapter(_sykLzAdapter);
        xSykStakingLzAdapter = IXSykStakingLzAdapter(_xSykStakingLzAdapter);
        dstEid = _dstEid;
    }

    /// @notice Casts a vote for a gauge across chains using LayerZero.
    /// @param _power The amount of power to vote with.
    /// @param _gaugeId The ID of the gauge to vote for.
    /// @param _options LayerZero message options for customizing message delivery.
    /// @return msgReceipt The receipt for the LayerZero message.
    function vote(uint256 _power, bytes32 _gaugeId, bytes calldata _options)
        external
        payable
        returns (MessagingReceipt memory msgReceipt)
    {
        // Check xSYK balance of the user
        uint256 totalPower = xSyk.balanceOf(msg.sender);
        // Check the xSYK staked balance of the user on staking adapter
        totalPower += xSykStakingLzAdapter.balanceOf(msg.sender);

        if (totalPower < _power) {
            revert GaugeControllerLzAdapter_NotEnoughPowerAvailable();
        }

        VoteParams memory voteParams = VoteParams({
            power: _power,
            totalPower: totalPower,
            accountId: keccak256(abi.encode(block.chainid, msg.sender)),
            gaugeId: _gaugeId
        });

        bytes memory payload = abi.encode(abi.encode(voteParams), bytes(""));

        msgReceipt = _lzSend(
            dstEid, // Destination chain's endpoint ID.
            payload, // Encoded message payload being sent.
            _options, // Message execution options (e.g., gas to use on destination).
            MessagingFee(msg.value, 0), // Fee struct containing native gas and ZRO token.
            payable(msg.sender) // The refund address in case the send call reverts.
        );

        emit Voted(voteParams, msgReceipt);
    }

    /// @notice Pulls rewards for a gauge across chains using LayerZero.
    /// @param _gaugeAddress The address of the gauge to pull rewards from.
    /// @param _epoch The epoch for which to pull rewards.
    /// @param _options LayerZero message options for customizing message delivery.
    /// @return msgReceipt The receipt for the LayerZero message.
    function pull(address _gaugeAddress, uint256 _epoch, bytes calldata _options)
        external
        payable
        returns (MessagingReceipt memory msgReceipt)
    {
        bytes32 gaugeId = keccak256(abi.encode(block.chainid, _gaugeAddress));

        PullParams memory pullParams = PullParams({epoch: _epoch, gaugeId: gaugeId, gaugeAddress: _gaugeAddress});

        bytes memory payload = abi.encode(bytes(""), pullParams);

        _lzSend(
            dstEid, // Destination chain's endpoint ID.
            payload, // Encoded message payload being sent.
            _options, // Message execution options (e.g., gas to use on destination).
            MessagingFee(msg.value, 0), // Fee struct containing native gas and ZRO token.
            payable(msg.sender) // The refund address in case the send call reverts.
        );

        emit RewardPulled(pullParams, msgReceipt);
    }

    function _lzReceive(Origin calldata _origin, bytes32 _guid, bytes calldata _message, address, bytes calldata)
        internal
        override
    {
        (bytes memory voteParams, bytes memory pullParams) = abi.decode(_message, (bytes, bytes));

        if (voteParams.length > 0) {
            gaugeController.vote(abi.decode(voteParams, (VoteParams)));
        } else if (pullParams.length > 0) {
            PullParams memory pullParamsDecoded = abi.decode(pullParams, (PullParams));

            uint256 reward = gaugeController.pull(pullParamsDecoded);

            bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);

            SendParams memory sendParams = SendParams({
                dstEid: _origin.srcEid,
                to: pullParamsDecoded.gaugeAddress,
                amount: reward,
                options: options,
                xSykAmount: 0
            });

            MessagingFee memory msgFee = sykLzAdapter.quoteSend(sendParams, false);

            // The msg.value should include any the fees to bridge back the SYK, incase the msg.value is not enough, this contract can store funds in order to prevent any failures
            sykLzAdapter.send{value: msgFee.nativeFee}(sendParams, msgFee, address(this));
        }

        emit MessageReceived(_message, _guid, _origin.srcEid);
    }

    // be able to receive ether
    receive() external payable virtual {}

    fallback() external payable {}
}
