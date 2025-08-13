// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {CCIPLocalSimulatorFork, Register} from "@chainlink/local/src/ccip/CCIPLocalSimulatorFork.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {GaugeControllerCCIPAdapter} from "../src/gauge/bridge-adapters/GaugeControllerCCIPAdapter.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {MockGaugeController} from "./mocks/MockGaugeController.sol";

contract GaugeControllerAdapterTest is Test {
    CCIPLocalSimulatorFork public ccipLocalSimulatorFork;
    uint256 public sourceFork;
    uint256 public destinationFork;
    address public user;
    IRouterClient public sourceRouter;
    uint64 public destinationChainSelector;

    // Our contracts
    GaugeControllerCCIPAdapter public sourceAdapter;
    GaugeControllerCCIPAdapter public destinationAdapter;
    MockToken public xSykToken;
    MockToken public linkToken;
    MockGaugeController public gaugeControllerSrc;
    MockGaugeController public gaugeControllerDst;

    // Test constants
    uint256 constant INITIAL_BALANCE = 1000 ether;
    uint256 constant VOTING_POWER = 100 ether;
    bytes32 constant TEST_GAUGE_ID = bytes32(uint256(1));
    uint256 constant REWARD_AMOUNT = 100 ether;
    uint256 constant EPOCH_1 = 0;
    uint256 constant EPOCH_2 = 1;

    function setUp() public {
        string memory DESTINATION_RPC_URL = vm.envString("ETHEREUM_SEPOLIA_RPC_URL");
        string memory SOURCE_RPC_URL = vm.envString("ARBITRUM_SEPOLIA_RPC_URL");

        destinationFork = vm.createSelectFork(DESTINATION_RPC_URL);
        sourceFork = vm.createFork(SOURCE_RPC_URL);

        user = makeAddr("user");

        // Set up CCIP simulator
        ccipLocalSimulatorFork = new CCIPLocalSimulatorFork();
        vm.makePersistent(address(ccipLocalSimulatorFork));

        // Get destination network details
        Register.NetworkDetails memory destinationNetworkDetails =
            ccipLocalSimulatorFork.getNetworkDetails(block.chainid);
        destinationChainSelector = destinationNetworkDetails.chainSelector;

        // Switch to source chain and get network details
        vm.selectFork(sourceFork);
        Register.NetworkDetails memory sourceNetworkDetails = ccipLocalSimulatorFork.getNetworkDetails(block.chainid);
        sourceRouter = IRouterClient(sourceNetworkDetails.routerAddress);

        // Deploy mock tokens and contracts
        xSykToken = new MockToken(address(this));
        linkToken = new MockToken(address(this));
        gaugeControllerSrc = new MockGaugeController(EPOCH_1);

        // Deploy adapters on both chains
        sourceAdapter = new GaugeControllerCCIPAdapter(
            address(sourceRouter),
            address(linkToken),
            address(gaugeControllerSrc),
            address(xSykToken),
            address(xSykToken),
            address(xSykToken),
            block.timestamp
        );

        vm.selectFork(destinationFork);

        gaugeControllerDst = new MockGaugeController(EPOCH_1);
        destinationAdapter = new GaugeControllerCCIPAdapter(
            destinationNetworkDetails.routerAddress,
            destinationNetworkDetails.linkAddress,
            address(gaugeControllerDst),
            address(xSykToken),
            address(xSykToken),
            address(xSykToken),
            block.timestamp
        );

        // Setup allowlists
        vm.selectFork(sourceFork);
        sourceAdapter.allowlistDestinationChain(destinationChainSelector, true);

        vm.selectFork(destinationFork);
        gaugeControllerDst.setReward(TEST_GAUGE_ID, EPOCH_1, REWARD_AMOUNT);

        // Give user some tokens and ETH
        vm.selectFork(sourceFork);
        deal(user, 5 ether);
        xSykToken.mint(user, INITIAL_BALANCE);
    }

    function test_vote() public {
        vm.selectFork(sourceFork);
        linkToken.mint(user, INITIAL_BALANCE);
        ccipLocalSimulatorFork.requestLinkFromFaucet(user, INITIAL_BALANCE);

        vm.startPrank(user);
        linkToken.approve(address(sourceAdapter), type(uint256).max);

        uint256 fees = sourceAdapter.quoteVote(
            VOTING_POWER, TEST_GAUGE_ID, address(destinationAdapter), destinationChainSelector, false
        );

        bytes32 messageId = sourceAdapter.vote{value: fees}(
            VOTING_POWER, TEST_GAUGE_ID, address(destinationAdapter), destinationChainSelector, false
        );

        vm.stopPrank();

        assertNotEq(messageId, bytes32(0));
        ccipLocalSimulatorFork.switchChainAndRouteMessage(destinationFork);

        uint256 vote = gaugeControllerDst.getVotes(TEST_GAUGE_ID, EPOCH_1);
        assertEq(vote, VOTING_POWER);
    }
}
