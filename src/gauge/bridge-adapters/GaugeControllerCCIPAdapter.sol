// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {OwnerIsCreator} from "@chainlink/contracts-ccip/src/v0.8/shared/access/OwnerIsCreator.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IGaugeController, VoteParams, PullParams} from "../../interfaces/IGaugeController.sol";
import {IXSykStakingLzAdapter} from "../../interfaces/IXSykStakingLzAdapter.sol";

/// @title GaugeController CCIP Adapter
/// @notice Facilitates cross-chain interactions for voting and pulling rewards using Chainlink CCIP
contract GaugeControllerCCIPAdapter is CCIPReceiver, OwnerIsCreator {
    using SafeERC20 for IERC20;

    // Custom errors
    error NotEnoughBalance(uint256 currentBalance, uint256 calculatedFees);
    error InvalidReceiverAddress();
    error DestinationChainNotAllowlisted(uint64 destinationChainSelector);
    error GaugeControllerCCIPAdapter_NotEnoughPowerAvailable();
    error NothingToWithdraw();
    error FailedToWithdrawEth(address sender, address beneficiary, uint256 amount);
    error InvalidMessageSource(address sender);
    error InvalidTokenTransfer();
    error InsufficientFeeProvided();

    // Constants
    uint256 public constant EPOCH_LENGTH = 7 days;
    uint16 public constant VOTE_TYPE = 0;
    uint16 public constant PULL_TYPE = 1;
    uint256 public constant DEFAULT_GAS_LIMIT = 400_000;
    uint256 public constant TOKEN_TRANSFER_GAS_LIMIT = 200_000;

    // State variables
    IGaugeController public immutable gaugeController;
    IERC20 public immutable xSyk;
    IERC20 public immutable sykToken; // Added SYK token reference
    IERC20 public immutable linkToken;
    IXSykStakingLzAdapter public immutable xSykStakingLzAdapter;
    uint256 public immutable genesis;

    // Mappings
    mapping(uint64 => bool) public allowlistedDestinationChains;

    // Events
    event Voted(VoteParams voteParams, bytes32 messageId);
    event RewardPulled(PullParams pullParams, bytes32 messageId, uint256 rewardAmount);
    event MessageReceived(bytes message, bytes32 messageId, uint64 sourceChainSelector);
    event TokensTransferred(address token, address recipient, uint256 amount, bytes32 messageId);

    struct TokenTransferParams {
        address token;
        address recipient;
        uint256 amount;
        uint64 destinationChainSelector;
    }

    /// @notice Constructor
    constructor(
        address _router,
        address _link,
        address _gaugeController,
        address _xSyk,
        address _syk,
        address _xSykStakingLzAdapter,
        uint256 _genesis
    ) CCIPReceiver(_router) {
        linkToken = IERC20(_link);
        gaugeController = IGaugeController(_gaugeController);
        xSyk = IERC20(_xSyk);
        sykToken = IERC20(_syk);
        xSykStakingLzAdapter = IXSykStakingLzAdapter(_xSykStakingLzAdapter);
        genesis = _genesis;
    }

    /// @notice Calculates the current epoch
    function epoch() public view returns (uint256) {
        return (block.timestamp - genesis) / EPOCH_LENGTH;
    }

    /// @notice Submit a vote via CCIP
    function vote(
        uint256 _power,
        bytes32 _gaugeId,
        address _receiver,
        uint64 _destinationChainSelector,
        bool _payInLink
    )
        external
        payable
        validateReceiver(_receiver)
        onlyAllowlistedDestinationChain(_destinationChainSelector)
        returns (bytes32)
    {
        VoteParams memory voteParams = _buildVoteParams(_power, _gaugeId);
        bytes memory messageData = abi.encode(VOTE_TYPE, abi.encode(voteParams), bytes(""));

        Client.EVM2AnyMessage memory evm2AnyMessage =
            _buildMessage(_receiver, messageData, new Client.EVMTokenAmount[](0), _payInLink);

        bytes32 messageId = _sendMessage(_destinationChainSelector, evm2AnyMessage, _payInLink);

        emit Voted(voteParams, messageId);
        return messageId;
    }

    /// @notice Pull rewards via CCIP
    function pull(
        address _gaugeAddress,
        uint256 _epochNumber,
        address _receiver,
        uint64 _destinationChainSelector,
        bool _payInLink
    )
        external
        payable
        validateReceiver(_receiver)
        onlyAllowlistedDestinationChain(_destinationChainSelector)
        returns (bytes32)
    {
        PullParams memory pullParams = _buildPullParams(_gaugeAddress, _epochNumber);

        bytes memory messageData =
            abi.encode(PULL_TYPE, abi.encode(pullParams), abi.encode(_receiver, _destinationChainSelector));

        Client.EVM2AnyMessage memory evm2AnyMessage =
            _buildMessage(_receiver, messageData, new Client.EVMTokenAmount[](0), _payInLink);

        bytes32 messageId = _sendMessage(_destinationChainSelector, evm2AnyMessage, _payInLink);

        emit RewardPulled(pullParams, messageId, 0);
        return messageId;
    }

    /// @notice Handle incoming CCIP messages
    function _ccipReceive(Client.Any2EVMMessage memory any2EvmMessage) internal override {
        (uint16 msgType, bytes memory params, bytes memory returnData) =
            abi.decode(any2EvmMessage.data, (uint16, bytes, bytes));

        if (msgType == VOTE_TYPE) {
            VoteParams memory voteParams = abi.decode(params, (VoteParams));
            gaugeController.vote(voteParams);
        } else if (msgType == PULL_TYPE) {
            PullParams memory pullParams = abi.decode(params, (PullParams));
            (address receiver, uint64 returnChainSelector) = abi.decode(returnData, (address, uint64));

            // Pull rewards
            uint256 reward = gaugeController.pull(pullParams);

            // Transfer rewards back to source chain
            if (reward > 0) {
                _handleRewardTransfer(
                    TokenTransferParams({
                        token: address(sykToken),
                        recipient: receiver,
                        amount: reward,
                        destinationChainSelector: returnChainSelector
                    })
                );
            }
        }

        emit MessageReceived(any2EvmMessage.data, any2EvmMessage.messageId, any2EvmMessage.sourceChainSelector);
    }

    /// @notice Handle token transfers
    function _handleRewardTransfer(TokenTransferParams memory params) internal {
        require(params.amount > 0, "Zero amount");
        require(params.recipient != address(0), "Invalid recipient");

        // Prepare token transfer message
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: params.token, amount: params.amount});

        // Build message for token transfer
        Client.EVM2AnyMessage memory evm2AnyMessage = _buildMessage(
            params.recipient,
            abi.encode("REWARD_TRANSFER"),
            tokenAmounts,
            false // Use native token for fees
        );

        // Approve tokens for transfer
        IERC20(params.token).approve(address(getRouter()), params.amount);

        // Send tokens
        bytes32 messageId = IRouterClient(getRouter()).ccipSend(params.destinationChainSelector, evm2AnyMessage);

        emit TokensTransferred(params.token, params.recipient, params.amount, messageId);
    }

    /// @notice Build CCIP message
    function _buildMessage(
        address _receiver,
        bytes memory _messageData,
        Client.EVMTokenAmount[] memory _tokenAmounts,
        bool _payInLink
    ) internal view returns (Client.EVM2AnyMessage memory) {
        return Client.EVM2AnyMessage({
            receiver: abi.encode(_receiver),
            data: _messageData,
            tokenAmounts: _tokenAmounts,
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV2({gasLimit: DEFAULT_GAS_LIMIT, allowOutOfOrderExecution: true})
            ),
            feeToken: _payInLink ? address(linkToken) : address(0)
        });
    }

    /// @notice Send CCIP message
    function _sendMessage(uint64 _destinationChainSelector, Client.EVM2AnyMessage memory _message, bool _payInLink)
        internal
        returns (bytes32)
    {
        IRouterClient router = IRouterClient(getRouter());
        uint256 fees = router.getFee(_destinationChainSelector, _message);

        if (_payInLink) {
            if (fees > linkToken.balanceOf(address(this))) {
                revert NotEnoughBalance(linkToken.balanceOf(address(this)), fees);
            }
            linkToken.approve(address(router), fees);
            return router.ccipSend(_destinationChainSelector, _message);
        } else {
            if (fees > address(this).balance) {
                revert NotEnoughBalance(address(this).balance, fees);
            }
            return router.ccipSend{value: fees}(_destinationChainSelector, _message);
        }
    }

    /// @notice Build vote parameters
    function _buildVoteParams(uint256 _power, bytes32 _gaugeId) private view returns (VoteParams memory) {
        uint256 totalPower = xSyk.balanceOf(msg.sender) + xSykStakingLzAdapter.balanceOf(msg.sender);

        if (totalPower < _power) {
            revert GaugeControllerCCIPAdapter_NotEnoughPowerAvailable();
        }

        return VoteParams({
            power: _power,
            totalPower: totalPower,
            epoch: epoch(),
            accountId: keccak256(abi.encode(block.chainid, msg.sender)),
            gaugeId: _gaugeId
        });
    }

    /// @notice Build pull parameters
    function _buildPullParams(address _gaugeAddress, uint256 _epoch) private view returns (PullParams memory) {
        return PullParams({
            epoch: _epoch,
            gaugeId: keccak256(abi.encode(block.chainid, _gaugeAddress)),
            gaugeAddress: _gaugeAddress
        });
    }

    // Admin functions
    function allowlistDestinationChain(uint64 _chainSelector, bool _allowed) external onlyOwner {
        allowlistedDestinationChains[_chainSelector] = _allowed;
    }

    // Modifiers
    modifier validateReceiver(address _receiver) {
        if (_receiver == address(0)) revert InvalidReceiverAddress();
        _;
    }

    modifier onlyAllowlistedDestinationChain(uint64 _destinationChainSelector) {
        if (!allowlistedDestinationChains[_destinationChainSelector]) {
            revert DestinationChainNotAllowlisted(_destinationChainSelector);
        }
        _;
    }

    // Withdrawal functions
    function withdraw(address _beneficiary) public onlyOwner {
        uint256 amount = address(this).balance;
        if (amount == 0) revert NothingToWithdraw();
        (bool sent,) = _beneficiary.call{value: amount}("");
        if (!sent) revert FailedToWithdrawEth(msg.sender, _beneficiary, amount);
    }

    function withdrawToken(address _beneficiary, address _token) public onlyOwner {
        uint256 amount = IERC20(_token).balanceOf(address(this));
        if (amount == 0) revert NothingToWithdraw();
        IERC20(_token).safeTransfer(_beneficiary, amount);
    }

    // Quote functions
    function quoteVote(
        uint256 _power,
        bytes32 _gaugeId,
        address _receiver,
        uint64 _destinationChainSelector,
        bool _payInLink
    ) external view returns (uint256) {
        VoteParams memory voteParams = _buildVoteParams(_power, _gaugeId);
        bytes memory messageData = abi.encode(VOTE_TYPE, abi.encode(voteParams), bytes(""));

        Client.EVM2AnyMessage memory evm2AnyMessage =
            _buildMessage(_receiver, messageData, new Client.EVMTokenAmount[](0), _payInLink);

        return IRouterClient(this.getRouter()).getFee(_destinationChainSelector, evm2AnyMessage);
    }

    function quotePull(
        address _gaugeAddress,
        uint256 _epochNumber,
        address _receiver,
        uint64 _destinationChainSelector,
        bool _payInLink
    ) external view returns (uint256) {
        PullParams memory pullParams = _buildPullParams(_gaugeAddress, _epochNumber);

        bytes memory messageData =
            abi.encode(PULL_TYPE, abi.encode(pullParams), abi.encode(_receiver, _destinationChainSelector));

        Client.EVM2AnyMessage memory evm2AnyMessage =
            _buildMessage(_receiver, messageData, new Client.EVMTokenAmount[](0), _payInLink);

        return IRouterClient(this.getRouter()).getFee(_destinationChainSelector, evm2AnyMessage);
    }

    // Receive and fallback functions to accept native currency
    receive() external payable {}
    fallback() external payable {}
}
