// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {OApp, Origin, MessagingFee, MessagingReceipt} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OApp.sol";
import {OAppOptionsType3} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp//libs/OAppOptionsType3.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISykLzAdapter, SendParams} from "../../interfaces/ISykLzAdapter.sol";
import {IGaugeController, VoteParams, PullParams} from "../../interfaces/IGaugeController.sol";
import {IXSykStakingLzAdapter} from "../../interfaces/IXSykStakingLzAdapter.sol";

/// @title GaugeController LayerZero Adapter
/// @notice Facilitates cross-chain interactions for voting and pulling rewards associated with gauge mechanisms.
/// @dev Extends `OApp` for LayerZero messaging, enabling cross-chain gauge operations.
contract GaugeControllerLzAdapter is OApp, OAppOptionsType3 {
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

    /// @notice The timestamp of the first epoch's start. To be set to the same value inside of the GaugeController
    uint256 public immutable genesis;

    /// @notice Length of an epoch in seconds.
    uint256 public constant EPOCH_LENGTH = 7 days;

    /// @notice Vote type in uint16
    uint16 public constant VOTE_TYPE = 0;

    /// @notice Pull type in uint16
    uint16 public constant PULL_TYPE = 1;

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
        uint32 _dstEid,
        uint256 _genesis
    ) OApp(_endpoint, _owner) Ownable(_owner) {
        gaugeController = IGaugeController(_gaugeController);
        xSyk = IERC20(_xSyk);
        sykLzAdapter = ISykLzAdapter(_sykLzAdapter);
        xSykStakingLzAdapter = IXSykStakingLzAdapter(_xSykStakingLzAdapter);
        dstEid = _dstEid;
        // To be set to the same value inside of the GaugeController
        genesis = _genesis;
    }

    /// @notice Recovers the native tokens of the chain from this contract if any
    function recoverNative() external onlyOwner {
        payable(msg.sender).transfer(address(this).balance);
    }

    /// @notice Calculates the current epoch based on the genesis time and epoch length.
    /// @return _epoch current epoch number.
    function epoch() public view returns (uint256 _epoch) {
        _epoch = (block.timestamp - genesis) / EPOCH_LENGTH;
    }

    /// @notice This function estimates the messaging fee for sending a vote via LayerZero by encoding the vote parameters and calculating the fee based on the encoded message.
    /// @param _power The voting power to be used in the vote, expressed as `uint256`.
    /// @param _gaugeId The unique identifier for the gauge on which the vote is being cast, as a `bytes32`.
    /// @param _options Additional options for the voting message as a byte array in calldata.
    /// @param _payInLzToken A boolean flag indicating whether the payment for the messaging fee should be made using the LayerZero token (LZ).
    /// @return msgFee A struct containing the details of the calculated messaging fee for the vote operation.
    function quoteVote(uint256 _power, bytes32 _gaugeId, bytes calldata _options, bool _payInLzToken)
        external
        view
        returns (MessagingFee memory msgFee)
    {
        VoteParams memory voteParams = _buildVoteParams(_power, _gaugeId);

        // Craft the message
        bytes memory message = abi.encode(VOTE_TYPE, abi.encode(voteParams), bytes(""));

        // Calculates the LayerZero fee for the send() operation.
        return _quote(dstEid, message, combineOptions(dstEid, VOTE_TYPE, _options), _payInLzToken);
    }

    /// @notice Estimates the messaging fee for executing a pull operation via LayerZero by encoding the operation's parameters and then calculating the fee based on the encoded message.
    /// @param _gaugeAddress The address of the gauge from which the pull operation is being initiated, as an `address`.
    /// @param _epoch The epoch for which the pull operation is being executed, expressed as a `uint256`.
    /// @param _sendSykOptions LayerZero message options for sending back SYK to the src chain.
    /// @param _options Additional options for the pull operation as a byte array in calldata.
    /// @param _payInLzToken A boolean flag indicating whether the LayerZero token (LZ) should be used for the payment of the messaging fee.
    /// @return msgFee A struct containing the calculated messaging fee for the pull operation.
    function quotePull(
        address _gaugeAddress,
        uint256 _epoch,
        bytes calldata _sendSykOptions,
        bytes calldata _options,
        bool _payInLzToken
    ) external view returns (MessagingFee memory msgFee) {
        PullParams memory pullParams = _buildPullParams(_gaugeAddress, _epoch);

        // Craft the message
        bytes memory message = abi.encode(PULL_TYPE, abi.encode(pullParams), _sendSykOptions);

        // Calculates the LayerZero fee for the send() operation.
        return _quote(dstEid, message, combineOptions(dstEid, PULL_TYPE, _options), _payInLzToken);
    }

    /// @notice Casts a vote for a gauge across chains using LayerZero.
    /// @param _power The amount of power to vote with.
    /// @param _gaugeId The ID of the gauge to vote for.
    /// @param _fee The calculated fee for the send() operation.
    ///      - nativeFee: The native fee.
    ///      - lzTokenFee: The lzToken fee.
    /// @param _options LayerZero message options for customizing message delivery.
    /// @return msgReceipt The receipt for the LayerZero message.
    function vote(uint256 _power, bytes32 _gaugeId, MessagingFee calldata _fee, bytes calldata _options)
        external
        payable
        returns (MessagingReceipt memory msgReceipt)
    {
        VoteParams memory voteParams = _buildVoteParams(_power, _gaugeId);

        bytes memory payload = abi.encode(VOTE_TYPE, abi.encode(voteParams), bytes(""));

        msgReceipt = _lzSend(
            dstEid, // Destination chain's endpoint ID.
            payload, // Encoded message payload being sent.
            combineOptions(dstEid, VOTE_TYPE, _options), // Message execution options (e.g., gas to use on destination).
            _fee, // Fee struct containing native gas and ZRO token.
            payable(msg.sender) // The refund address in case the send call reverts.
        );

        emit Voted(voteParams, msgReceipt);
    }

    /// @notice Pulls rewards for a gauge across chains using LayerZero.
    /// @param _gaugeAddress The address of the gauge to pull rewards from.
    /// @param _epoch The epoch for which to pull rewards.
    /// @param _fee The calculated fee for the send() operation.
    ///      - nativeFee: The native fee.
    ///      - lzTokenFee: The lzToken fee.
    /// @param _sendSykOptions LayerZero message options for sending back SYK to the src chain.
    /// @param _options LayerZero message options for customizing message delivery.
    /// @return msgReceipt The receipt for the LayerZero message.
    function pull(
        address _gaugeAddress,
        uint256 _epoch,
        MessagingFee calldata _fee,
        bytes calldata _sendSykOptions,
        bytes calldata _options
    ) external payable returns (MessagingReceipt memory msgReceipt) {
        PullParams memory pullParams = _buildPullParams(_gaugeAddress, _epoch);

        bytes memory payload = abi.encode(PULL_TYPE, abi.encode(pullParams), _sendSykOptions);

        _lzSend(
            dstEid, // Destination chain's endpoint ID.
            payload, // Encoded message payload being sent.
            combineOptions(dstEid, PULL_TYPE, _options), // Message execution options (e.g., gas to use on destination).
            _fee,
            payable(msg.sender) // The refund address in case the send call reverts.
        );

        emit RewardPulled(pullParams, msgReceipt);
    }

    function _lzReceive(Origin calldata _origin, bytes32 _guid, bytes calldata _message, address, bytes calldata)
        internal
        override
    {
        (uint16 MSG_TYPE, bytes memory params, bytes memory sendSykOptions) =
            abi.decode(_message, (uint16, bytes, bytes));

        if (MSG_TYPE == VOTE_TYPE) {
            gaugeController.vote(abi.decode(params, (VoteParams)));
        } else if (MSG_TYPE == PULL_TYPE) {
            PullParams memory pullParamsDecoded = abi.decode(params, (PullParams));

            uint256 reward = gaugeController.pull(pullParamsDecoded);

            SendParams memory sendParams = SendParams({
                dstEid: _origin.srcEid,
                to: pullParamsDecoded.gaugeAddress,
                amount: reward,
                options: sendSykOptions,
                xSykAmount: 0
            });

            MessagingFee memory msgFee = sykLzAdapter.quoteSend(sendParams, false);

            // The msg.value should include any the fees to bridge back the SYK, incase the msg.value is not enough, this contract can store funds in order to prevent any failures
            sykLzAdapter.send{value: msgFee.nativeFee}(sendParams, msgFee, address(this));
        }

        emit MessageReceived(_message, _guid, _origin.srcEid);
    }

    function _buildVoteParams(uint256 _power, bytes32 _gaugeId) private view returns (VoteParams memory voteParams) {
        // Check xSYK balance of the user
        uint256 totalPower = xSyk.balanceOf(msg.sender);
        // Check the xSYK staked balance of the user on staking adapter
        totalPower += xSykStakingLzAdapter.balanceOf(msg.sender);

        if (totalPower < _power) {
            revert GaugeControllerLzAdapter_NotEnoughPowerAvailable();
        }

        voteParams = VoteParams({
            power: _power,
            totalPower: totalPower,
            epoch: epoch(),
            accountId: keccak256(abi.encode(block.chainid, msg.sender)),
            gaugeId: _gaugeId
        });
    }

    function _buildPullParams(address _gaugeAddress, uint256 _epoch)
        private
        view
        returns (PullParams memory pullParams)
    {
        bytes32 gaugeId = keccak256(abi.encode(block.chainid, _gaugeAddress));

        pullParams = PullParams({epoch: _epoch, gaugeId: gaugeId, gaugeAddress: _gaugeAddress});
    }

    // be able to receive native tokens
    receive() external payable virtual {}

    fallback() external payable {}
}
