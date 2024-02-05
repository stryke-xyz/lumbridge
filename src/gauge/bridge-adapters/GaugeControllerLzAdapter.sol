// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {OAppReceiver, Origin} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OAppReceiver.sol";
import {OAppCore, Ownable} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OAppCore.sol";

import {OApp, Origin, MessagingFee} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OApp.sol";
import {IGaugeController, VoteParams, PullParams} from "../../interfaces/IGaugeController.sol";
import {Test, console} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import {SykLzAdapter, SendParams} from "../../token/bridge-adapters/SykLzAdapter.sol";

contract GaugeControllerLzAdapter is OApp {
    using OptionsBuilder for bytes;

    address public immutable gaugeController;

    address public immutable xSyk;

    address public immutable syk;

    address public immutable sykLzAdapter;

    address public immutable xSykStakingLzAdapter;

    uint32 public immutable dstEid;

    error NotEnoughPowerAvailable();

    constructor(
        address _endpoint,
        address _owner,
        address _gaugeController,
        address _xSyk,
        address _syk,
        address _sykLzAdapter,
        address _xSykStakingLzAdapter,
        uint32 _dstEid
    ) OApp(_endpoint, _owner) Ownable(_owner) {
        gaugeController = _gaugeController;
        xSyk = _xSyk;
        syk = _syk;
        sykLzAdapter = _sykLzAdapter;
        dstEid = _dstEid;
        xSykStakingLzAdapter = _xSykStakingLzAdapter;
    }

    function vote(uint256 _power, bytes32 _gaugeId, bytes calldata _options) external payable {
        uint256 totalPower = IERC20Metadata(xSyk).balanceOf(msg.sender);
        totalPower += IERC20Metadata(xSykStakingLzAdapter).balanceOf(msg.sender);

        if (totalPower < _power) {
            revert NotEnoughPowerAvailable();
        }

        VoteParams memory voteParams = VoteParams({
            power: _power,
            totalPower: totalPower,
            accountId: keccak256(abi.encode(block.chainid, msg.sender)),
            gaugeId: _gaugeId
        });

        bytes memory payload = abi.encode(abi.encode(voteParams), bytes(""));

        _lzSend(
            dstEid, // Destination chain's endpoint ID.
            payload, // Encoded message payload being sent.
            _options, // Message execution options (e.g., gas to use on destination).
            MessagingFee(msg.value, 0), // Fee struct containing native gas and ZRO token.
            payable(msg.sender) // The refund address in case the send call reverts.
        );
    }

    function pull(address _gaugeAddress, uint256 _epoch, bytes calldata _options) external payable {
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
    }

    function _lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) internal override {
        (bytes memory voteParams, bytes memory pullParams) = abi.decode(_message, (bytes, bytes));

        if (voteParams.length > 0) {
            IGaugeController(gaugeController).vote(abi.decode(voteParams, (VoteParams)));
        } else if (pullParams.length > 0) {
            PullParams memory pullParamsDecoded = abi.decode(pullParams, (PullParams));

            uint256 reward = IGaugeController(gaugeController).pull(pullParamsDecoded);

            bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);

            SendParams memory sendParams = SendParams({
                dstEid: _origin.srcEid,
                to: pullParamsDecoded.gaugeAddress,
                amount: reward,
                options: options,
                xSykAmount: 0
            });

            MessagingFee memory msgFee = SykLzAdapter(sykLzAdapter).quoteSend(sendParams, false);

            // The msg.value should include any the fees to bridge back the SYK, incase the msg.value is not enough, this contract can store funds in order to prevent any failures
            SykLzAdapter(sykLzAdapter).send{value: msgFee.nativeFee}(sendParams, msgFee, address(this));
        }
    }

    function addressToBytes32(address _addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }

    // be able to receive ether
    receive() external payable virtual {}

    fallback() external payable {}
}
