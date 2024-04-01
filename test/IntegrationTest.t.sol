// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.23;

import {Test, console} from "forge-std/Test.sol";

import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import {MessagingFee} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {StrykeTokenRoot} from "../src/token/StrykeTokenRoot.sol";
import {StrykeTokenChild} from "../src/token/StrykeTokenChild.sol";
import {SykBridgeController} from "../src/token/SykBridgeController.sol";
import {EndpointV2Mock} from "./mocks/layerzero/EndpointV2Mock.sol";
import {SykLzAdapter} from "../src/token/bridge-adapters/SykLzAdapter.sol";
import {XStrykeToken} from "../src/governance/XStrykeToken.sol";
import {GaugeController} from "../src/gauge/GaugeController.sol";
import {GaugeInfo} from "../src/interfaces/IGaugeController.sol";
import {GaugeType1} from "../src/gauge/GaugeType1.sol";
import {XSykStaking} from "../src/governance/XSykStaking.sol";
import {XSykStakingLzAdapter} from "../src/governance/bridge-adapters/XSykStakingLzAdapter.sol";
import {VoteParams} from "../src/interfaces/IGaugeController.sol";
import {GaugeControllerLzAdapter} from "../src/gauge/bridge-adapters/GaugeControllerLzAdapter.sol";
import {ISykLzAdapter, SendParams} from "../src/interfaces/ISykLzAdapter.sol";

// For the demonstration of all functionality we will assume the root chain to be Arbitrum and a child chain BSC
contract IntegrationTest is Test {
    using OptionsBuilder for bytes;

    GaugeController public gaugeController;

    StrykeTokenRoot public sykRoot;
    StrykeTokenChild public sykBsc;

    SykBridgeController public bridgeControllerRoot;
    SykBridgeController public bridgeControllerBsc;

    XStrykeToken public xSykRoot;
    XStrykeToken public xSykBsc;

    GaugeControllerLzAdapter public gaugeControllerLzAdapterRoot;
    GaugeControllerLzAdapter public gaugeControllerLzAdapterBsc;

    EndpointV2Mock public rootEndpoint;
    EndpointV2Mock public bscEndpoint;

    SykLzAdapter public sykLzAdapterRoot;
    SykLzAdapter public sykLzAdapterBsc;

    XSykStaking public xSykStaking;
    XSykStakingLzAdapter public xSykStakingLzAdapterRoot;
    XSykStakingLzAdapter public xSykStakingLzAdapterBsc;

    AccessManager public accessManagerRoot;
    AccessManager public accessManagerBsc;

    Account public john;
    Account public doe;

    function setUp() public {
        vm.chainId(42161);
        john = makeAccount("john");
        deal(john.addr, 100 ether);

        doe = makeAccount("doe");
        deal(doe.addr, 100 ether);

        StrykeTokenRoot sykImplementation = new StrykeTokenRoot();
        StrykeTokenChild sykChildImplementation = new StrykeTokenChild();
        XStrykeToken xSykImplementation = new XStrykeToken();
        GaugeController gaugeControllerImplementation = new GaugeController();

        accessManagerRoot = new AccessManager(address(this));
        accessManagerBsc = new AccessManager(address(this));

        rootEndpoint = new EndpointV2Mock(30110);
        bscEndpoint = new EndpointV2Mock(30102);

        sykRoot = StrykeTokenRoot(
            address(
                new ERC1967Proxy(
                    address(sykImplementation),
                    abi.encodeWithSelector(StrykeTokenRoot.initialize.selector, address(accessManagerRoot))
                )
            )
        );

        sykBsc = StrykeTokenChild(
            address(
                new ERC1967Proxy(
                    address(sykChildImplementation),
                    abi.encodeWithSelector(StrykeTokenChild.initialize.selector, address(accessManagerBsc))
                )
            )
        );

        bridgeControllerRoot = new SykBridgeController(address(sykRoot), address(accessManagerRoot));
        bridgeControllerBsc = new SykBridgeController(address(sykBsc), address(accessManagerBsc));

        xSykRoot = XStrykeToken(
            address(
                new ERC1967Proxy(
                    address(xSykImplementation),
                    abi.encodeWithSelector(
                        XStrykeToken.initialize.selector, address(sykRoot), address(accessManagerRoot)
                    )
                )
            )
        );

        xSykBsc = XStrykeToken(
            address(
                new ERC1967Proxy(
                    address(xSykImplementation),
                    abi.encodeWithSelector(XStrykeToken.initialize.selector, address(sykBsc), address(accessManagerBsc))
                )
            )
        );

        xSykStaking =
            new XSykStaking(address(xSykRoot), address(sykRoot), address(xSykRoot), address(accessManagerRoot));
        xSykRoot.updateWhitelist(address(xSykStaking), true);

        sykRoot.setInflationPerYear(1_000_000 ether);

        // Move 7 days ahead in time to allow 1 week of inflation to process
        skip(7 days);

        gaugeController = GaugeController(
            address(
                new ERC1967Proxy(
                    address(gaugeControllerImplementation),
                    abi.encodeWithSelector(
                        GaugeController.initialize.selector,
                        address(sykRoot),
                        address(xSykRoot),
                        address(xSykStaking),
                        address(accessManagerRoot)
                    )
                )
            )
        );

        gaugeController.setGenesis(block.timestamp);

        uint64 MINTER_BURNER_SYK = 1;

        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = bytes4(keccak256("mint(address,uint256)"));
        selectors[1] = bytes4(keccak256("burn(address,uint256)"));

        // Set role for bridge controller root
        accessManagerRoot.grantRole(MINTER_BURNER_SYK, address(bridgeControllerRoot), 0);
        accessManagerRoot.grantRole(MINTER_BURNER_SYK, address(this), 0);
        accessManagerRoot.setTargetFunctionRole(address(sykRoot), selectors, MINTER_BURNER_SYK);

        // Set role for gauge controller
        uint64 STRYKER = 2;
        bytes4[] memory strykeSelectors = new bytes4[](1);
        strykeSelectors[0] = bytes4(keccak256("stryke(uint256)"));
        accessManagerRoot.grantRole(STRYKER, address(gaugeController), 0);
        accessManagerRoot.setTargetFunctionRole(address(sykRoot), strykeSelectors, STRYKER);

        // Set role for bridge controller bsc
        accessManagerBsc.grantRole(MINTER_BURNER_SYK, address(bridgeControllerBsc), 0);
        accessManagerBsc.grantRole(MINTER_BURNER_SYK, address(this), 0);
        accessManagerBsc.setTargetFunctionRole(address(sykBsc), selectors, MINTER_BURNER_SYK);

        sykLzAdapterRoot = new SykLzAdapter(
            address(rootEndpoint), address(this), address(bridgeControllerRoot), address(sykRoot), address(xSykRoot)
        );
        sykLzAdapterBsc = new SykLzAdapter(
            address(bscEndpoint), address(this), address(bridgeControllerBsc), address(sykBsc), address(xSykBsc)
        );

        rootEndpoint.setDestLzEndpoint(address(sykLzAdapterBsc), address(bscEndpoint));

        bscEndpoint.setDestLzEndpoint(address(sykLzAdapterRoot), address(rootEndpoint));

        xSykStakingLzAdapterRoot = new XSykStakingLzAdapter(
            address(rootEndpoint),
            address(this),
            address(xSykStaking),
            address(xSykRoot),
            address(sykLzAdapterRoot),
            30110
        );
        xSykStakingLzAdapterBsc = new XSykStakingLzAdapter(
            address(bscEndpoint), address(this), address(0), address(xSykBsc), address(sykLzAdapterBsc), 30110
        );

        gaugeControllerLzAdapterRoot = new GaugeControllerLzAdapter(
            address(rootEndpoint),
            address(this),
            address(gaugeController),
            address(xSykRoot),
            address(sykLzAdapterRoot),
            address(0),
            30110,
            gaugeController.genesis()
        );

        gaugeControllerLzAdapterBsc = new GaugeControllerLzAdapter(
            address(bscEndpoint),
            address(this),
            address(gaugeController),
            address(xSykBsc),
            address(0),
            address(xSykStakingLzAdapterBsc),
            30110,
            gaugeController.genesis()
        );

        gaugeController.updateBridgeAdapter(address(gaugeControllerLzAdapterRoot), true);

        rootEndpoint.setDestLzEndpoint(address(gaugeControllerLzAdapterBsc), address(bscEndpoint));
        bscEndpoint.setDestLzEndpoint(address(gaugeControllerLzAdapterRoot), address(rootEndpoint));

        gaugeControllerLzAdapterRoot.setPeer(30102, addressToBytes32(address(gaugeControllerLzAdapterBsc)));
        gaugeControllerLzAdapterBsc.setPeer(30110, addressToBytes32(address(gaugeControllerLzAdapterRoot)));

        bridgeControllerRoot.setLimits(address(sykLzAdapterRoot), 10000 ether, 10000 ether);
        bridgeControllerBsc.setLimits(address(sykLzAdapterBsc), 10000 ether, 10000 ether);

        // Set peers for both the adapters
        sykLzAdapterRoot.setPeer(30102, addressToBytes32(address(sykLzAdapterBsc)));
        sykLzAdapterBsc.setPeer(30110, addressToBytes32(address(sykLzAdapterRoot)));

        xSykBsc.updateWhitelist(address(xSykStakingLzAdapterBsc), true);

        xSykStaking.updateBridgeAdapter(address(xSykStakingLzAdapterRoot), true);

        rootEndpoint.setDestLzEndpoint(address(xSykStakingLzAdapterBsc), address(bscEndpoint));
        bscEndpoint.setDestLzEndpoint(address(xSykStakingLzAdapterRoot), address(rootEndpoint));

        xSykStakingLzAdapterRoot.setPeer(30102, addressToBytes32(address(xSykStakingLzAdapterBsc)));
        xSykStakingLzAdapterBsc.setPeer(30110, addressToBytes32(address(xSykStakingLzAdapterRoot)));
    }

    function test_bridgeToAndFromBsc() public {
        // Mint SYK to john and bridge to bsc
        sykRoot.mint(john.addr, 1 ether);
        assertEq(sykRoot.balanceOf(john.addr), 1 ether);

        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);

        // Check revert block start

        SendParams memory sendParams =
            SendParams({dstEid: 30102, to: john.addr, amount: 1 ether, options: options, xSykAmount: 1.1 ether});

        MessagingFee memory msgFee = sykLzAdapterRoot.quoteSend(sendParams, false);

        vm.expectRevert(ISykLzAdapter.SykLzAdapter_InvalidAmount.selector);
        vm.prank(john.addr);
        sykLzAdapterRoot.send{value: msgFee.nativeFee}(sendParams, msgFee, john.addr);

        // Check revert block end

        sendParams = SendParams({dstEid: 30102, to: john.addr, amount: 1 ether, options: options, xSykAmount: 0});

        msgFee = sykLzAdapterRoot.quoteSend(sendParams, false);

        vm.prank(john.addr);
        sykLzAdapterRoot.send{value: msgFee.nativeFee}(sendParams, msgFee, john.addr);
        assertEq(sykRoot.balanceOf(john.addr), 0);
        assertEq(sykBsc.balanceOf(john.addr), 1 ether);

        // Check with xSYK amount block start
        xSykBsc.updateContractWhitelist(address(sykLzAdapterBsc), true);
        sykRoot.mint(john.addr, 1 ether);
        assertEq(sykRoot.balanceOf(john.addr), 1 ether);

        sendParams =
            SendParams({dstEid: 30102, to: john.addr, amount: 1 ether, options: options, xSykAmount: 0.5 ether});

        msgFee = sykLzAdapterRoot.quoteSend(sendParams, false);

        vm.prank(john.addr);
        sykLzAdapterRoot.send{value: msgFee.nativeFee}(sendParams, msgFee, john.addr);
        assertEq(sykRoot.balanceOf(john.addr), 0 ether);
        assertEq(sykBsc.balanceOf(john.addr), 1.5 ether);
        assertEq(xSykBsc.balanceOf(john.addr), 0.5 ether);
        // Check with xSYK amount block end

        SendParams memory sendParams2 =
            SendParams({dstEid: 30110, to: john.addr, amount: 1.5 ether, options: options, xSykAmount: 0});

        MessagingFee memory msgFee2 = sykLzAdapterBsc.quoteSend(sendParams2, false);

        vm.prank(john.addr);
        sykLzAdapterBsc.send{value: msgFee2.nativeFee}(sendParams2, msgFee2, john.addr);
        assertEq(sykRoot.balanceOf(john.addr), 1.5 ether);
        assertEq(sykBsc.balanceOf(john.addr), 0);
    }

    function test_voteAndPullNative() public {
        gaugeController.setTotalRewardPerEpoch(1000 ether);

        GaugeType1 gaugeImplementation = new GaugeType1();

        GaugeType1 gaugeA = GaugeType1(
            address(
                new ERC1967Proxy(
                    address(gaugeImplementation),
                    abi.encodeWithSelector(
                        GaugeType1.initialize.selector, address(this), address(gaugeController), address(sykRoot)
                    )
                )
            )
        );

        GaugeType1 gaugeB = GaugeType1(
            address(
                new ERC1967Proxy(
                    address(gaugeImplementation),
                    abi.encodeWithSelector(
                        GaugeType1.initialize.selector, address(this), address(gaugeController), address(sykRoot)
                    )
                )
            )
        );

        GaugeInfo memory gaugeAInfo =
            GaugeInfo({gaugeType: 1, chainId: 42161, baseReward: 300 ether, gaugeAddress: address(gaugeA)});

        GaugeInfo memory gaugeBInfo =
            GaugeInfo({gaugeType: 1, chainId: 42161, baseReward: 300 ether, gaugeAddress: address(gaugeB)});

        bytes32 gaugeAId = gaugeController.addGauge(gaugeAInfo);
        bytes32 gaugeBId = gaugeController.addGauge(gaugeBInfo);

        // Mint SYK to john and doe on arbitrum
        sykRoot.mint(john.addr, 1 ether);
        sykRoot.mint(doe.addr, 2 ether);

        vm.startPrank(john.addr, john.addr);
        sykRoot.approve(address(xSykRoot), 1 ether);
        xSykRoot.convert(1 ether, john.addr);
        gaugeController.vote(
            VoteParams({
                power: 1 ether,
                totalPower: 1 ether,
                epoch: 0,
                gaugeId: gaugeAId,
                accountId: keccak256(abi.encode(42161, john.addr))
            })
        );
        vm.stopPrank();

        vm.startPrank(doe.addr, doe.addr);
        sykRoot.approve(address(xSykRoot), 2 ether);
        xSykRoot.convert(2 ether, doe.addr);
        gaugeController.vote(
            VoteParams({
                power: 2 ether,
                totalPower: 2 ether,
                epoch: 0,
                gaugeId: gaugeBId,
                accountId: keccak256(abi.encode(42161, doe.addr))
            })
        );
        vm.stopPrank();

        skip(7 days);
        gaugeController.finalizeEpoch(0);
        gaugeA.pull(0);
        assertEq(sykRoot.balanceOf(address(this)), 433333333333333333333);
        gaugeB.pull(0);
        assertEq(sykRoot.balanceOf(address(this)), 433333333333333333333 + 566666666666666666666);
    }

    function test_voteAndPullCrossChain() public {
        gaugeController.setTotalRewardPerEpoch(1000 ether);

        GaugeType1 gaugeImplementation = new GaugeType1();

        GaugeType1 gaugeA = GaugeType1(
            address(
                new ERC1967Proxy(
                    address(gaugeImplementation),
                    abi.encodeWithSelector(
                        GaugeType1.initialize.selector, address(this), address(gaugeController), address(sykRoot)
                    )
                )
            )
        );

        GaugeType1 gaugeB = GaugeType1(
            address(
                new ERC1967Proxy(
                    address(gaugeImplementation),
                    abi.encodeWithSelector(GaugeType1.initialize.selector, address(this), address(0), address(sykBsc))
                )
            )
        );

        GaugeInfo memory gaugeAInfo =
            GaugeInfo({gaugeType: 1, chainId: 42161, baseReward: 300 ether, gaugeAddress: address(gaugeA)});

        GaugeInfo memory gaugeBInfo =
            GaugeInfo({gaugeType: 1, chainId: 56, baseReward: 300 ether, gaugeAddress: address(gaugeB)});

        bytes32 gaugeAId = gaugeController.addGauge(gaugeAInfo);
        bytes32 gaugeBId = gaugeController.addGauge(gaugeBInfo);

        // Mint SYK to john on arbitrum and doe on bsc
        sykRoot.mint(john.addr, 1 ether);
        sykBsc.mint(doe.addr, 2 ether);

        // Vote for john
        vm.startPrank(john.addr, john.addr);
        sykRoot.approve(address(xSykRoot), 1 ether);
        xSykRoot.convert(1 ether, john.addr);
        gaugeController.vote(
            VoteParams({
                power: 1 ether,
                totalPower: 1 ether,
                epoch: gaugeController.epoch(),
                gaugeId: gaugeAId,
                accountId: keccak256(abi.encode(42161, john.addr))
            })
        );
        vm.stopPrank();

        // Vote for joe
        vm.startPrank(doe.addr, doe.addr);
        sykBsc.approve(address(xSykBsc), 2 ether);
        xSykBsc.convert(2 ether, doe.addr);
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);
        MessagingFee memory _fee = gaugeControllerLzAdapterBsc.quoteVote(2 ether, gaugeBId, options, false);
        gaugeControllerLzAdapterBsc.vote{value: _fee.nativeFee}(2 ether, gaugeBId, _fee, options);
        vm.stopPrank();

        skip(7 days);
        gaugeController.finalizeEpoch(0);

        gaugeA.pull(0);

        assertEq(sykRoot.balanceOf(address(this)), 433333333333333333333);

        vm.chainId(56);

        uint256 reward = gaugeController.computeRewards(gaugeBId, 0);

        SendParams memory sendParams =
            SendParams({dstEid: 30102, to: address(gaugeB), amount: reward, options: options, xSykAmount: 0});

        MessagingFee memory msgFee = sykLzAdapterRoot.quoteSend(sendParams, false);

        options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(10000000, uint128(msgFee.nativeFee));

        _fee = gaugeControllerLzAdapterBsc.quotePull(
            address(gaugeB), 0, OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0), options, false
        );

        gaugeControllerLzAdapterBsc.pull{value: _fee.nativeFee}(
            address(gaugeB), 0, _fee, OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0), options
        );

        gaugeB.pull();

        assertEq(sykBsc.balanceOf(address(this)), 566666666666666666666);
    }

    function test_stakingCrossChain() public {
        xSykStaking.setRewardsDuration(7 days);
        // Send 30% of rewards in xSYK
        xSykStaking.updateXSykRewardPercentage(50);
        xSykRoot.updateContractWhitelist(address(xSykStaking), true);

        uint256 amount = 700 ether;

        sykRoot.mint(address(xSykStaking), amount);
        xSykStaking.notifyRewardAmount(amount);

        // Mint SYK to john on arbitrum and doe on bsc
        sykRoot.mint(john.addr, 1 ether);
        sykBsc.mint(doe.addr, 1 ether);

        // John stakes from Arbitrum
        vm.startPrank(john.addr, john.addr);
        sykRoot.approve(address(xSykRoot), 1 ether);
        xSykRoot.convert(1 ether, john.addr);
        xSykRoot.approve(address(xSykStaking), 1 ether);
        xSykStaking.stake(1 ether, 42161, john.addr);
        bytes32 johnId = keccak256(abi.encode(42161, john.addr));
        assertEq(xSykStaking.balanceOf(johnId), 1 ether);
        vm.stopPrank();

        // Doe stakes from BSC
        vm.startPrank(doe.addr, doe.addr);
        vm.chainId(56);
        sykBsc.approve(address(xSykBsc), 1 ether);
        xSykBsc.convert(1 ether, doe.addr);
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);
        xSykBsc.approve(address(xSykStakingLzAdapterBsc), 1 ether);
        MessagingFee memory _fee = xSykStakingLzAdapterBsc.quote(
            xSykStakingLzAdapterBsc.STAKE_TYPE(), 30110, 1 ether, bytes(""), options, false
        );
        xSykStakingLzAdapterBsc.stake{value: _fee.nativeFee}(1 ether, _fee, options);
        bytes32 doeId = keccak256(abi.encode(56, doe.addr));
        assertEq(xSykStaking.balanceOf(doeId), 1 ether);
        vm.stopPrank();

        // Skip until end of staking period
        skip(7 days);

        // John unstakes and gets reward from arbitrum
        vm.startPrank(john.addr, john.addr);
        vm.chainId(42161);
        xSykStaking.unstake(1 ether, 42161, john.addr);
        assertEq(xSykRoot.balanceOf(john.addr), 1 ether);
        assertEq(xSykStaking.balanceOf(keccak256(abi.encode(42161, john.addr))), 0);
        xSykStaking.claim(42161, john.addr);
        assertEq(sykRoot.balanceOf(john.addr), 174999999999999938400);
        assertEq(xSykRoot.balanceOf(john.addr), 175999999999999938400);
        vm.stopPrank();

        xSykBsc.updateContractWhitelist(address(sykLzAdapterBsc), true);

        // Doe unstakes and gets reward from BSC
        vm.startPrank(doe.addr, doe.addr);
        vm.chainId(56);
        _fee = xSykStakingLzAdapterRoot.quote(
            xSykStakingLzAdapterRoot.FINALIZE_UNSTAKE_TYPE(),
            30102,
            1 ether,
            bytes(""),
            OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0),
            false
        );
        options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, uint128(_fee.nativeFee));
        _fee = xSykStakingLzAdapterBsc.quote(
            xSykStakingLzAdapterBsc.UNSTAKE_TYPE(),
            30110,
            1 ether,
            OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0),
            options,
            false
        );
        xSykStakingLzAdapterBsc.unstake{value: _fee.nativeFee}(
            1 ether, _fee, OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0), options
        );
        assertEq(xSykBsc.balanceOf(doe.addr), 1 ether);
        assertEq(xSykStaking.balanceOf(keccak256(abi.encode(56, doe.addr))), 0);

        uint256 reward = xSykStaking.earned(keccak256(abi.encode(56, doe.addr)));

        SendParams memory sendParams =
            SendParams({dstEid: 30102, to: address(doe.addr), amount: reward, options: options, xSykAmount: reward / 2});

        MessagingFee memory msgFee = sykLzAdapterRoot.quoteSend(sendParams, false);
        options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(10000000, uint128(msgFee.nativeFee));
        _fee = xSykStakingLzAdapterBsc.quote(
            xSykStakingLzAdapterBsc.CLAIM_TYPE(),
            30110,
            0,
            OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0),
            options,
            false
        );
        xSykStakingLzAdapterBsc.claim{value: _fee.nativeFee}(
            _fee, OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0), options
        );
        assertEq(sykBsc.balanceOf(doe.addr), 174999999999999938400);
        assertEq(xSykBsc.balanceOf(doe.addr), 175999999999999938400);

        vm.stopPrank();
    }

    function test_stakingUsingExit() public {
        xSykStaking.setRewardsDuration(7 days);

        uint256 amount = 700 ether;

        sykRoot.mint(address(xSykStaking), amount);
        xSykStaking.notifyRewardAmount(amount);

        // Mint SYK to john on arbitrum and doe on bsc
        sykRoot.mint(john.addr, 1 ether);
        sykBsc.mint(doe.addr, 1 ether);

        // John stakes from Arbitrum
        vm.startPrank(john.addr, john.addr);
        vm.chainId(42161);
        sykRoot.approve(address(xSykRoot), 1 ether);
        xSykRoot.convert(1 ether, john.addr);
        xSykRoot.approve(address(xSykStaking), 1 ether);
        xSykStaking.stake(1 ether, 42161, john.addr);
        assertEq(xSykStaking.balanceOf(keccak256(abi.encode(42161, john.addr))), 1 ether);
        vm.stopPrank();

        // Skip until end of staking period
        skip(7 days);

        // John exits from arbitrum
        vm.startPrank(john.addr, john.addr);
        vm.chainId(42161);
        xSykStaking.exit(42161, john.addr);
        bytes32 johnId = keccak256(abi.encode(42161, doe.addr));
        assertEq(xSykRoot.balanceOf(john.addr), 1 ether);
        assertEq(xSykStaking.balanceOf(johnId), 0);
        assertEq(sykRoot.balanceOf(john.addr), 699999999999999753600);
        vm.stopPrank();
    }

    function test_voteUsingStakingBalance() public {
        gaugeController.setTotalRewardPerEpoch(1000 ether);

        GaugeType1 gaugeImplementation = new GaugeType1();

        GaugeType1 gaugeA = GaugeType1(
            address(
                new ERC1967Proxy(
                    address(gaugeImplementation),
                    abi.encodeWithSelector(
                        GaugeType1.initialize.selector, address(this), address(gaugeController), address(sykRoot)
                    )
                )
            )
        );

        GaugeType1 gaugeB = GaugeType1(
            address(
                new ERC1967Proxy(
                    address(gaugeImplementation),
                    abi.encodeWithSelector(GaugeType1.initialize.selector, address(this), address(0), address(sykBsc))
                )
            )
        );

        GaugeInfo memory gaugeAInfo =
            GaugeInfo({gaugeType: 1, chainId: 42161, baseReward: 300 ether, gaugeAddress: address(gaugeA)});

        GaugeInfo memory gaugeBInfo =
            GaugeInfo({gaugeType: 1, chainId: 56, baseReward: 300 ether, gaugeAddress: address(gaugeB)});

        bytes32 gaugeAId = gaugeController.addGauge(gaugeAInfo);
        bytes32 gaugeBId = gaugeController.addGauge(gaugeBInfo);

        // Mint SYK to john on arbitrum and doe on bsc
        sykRoot.mint(john.addr, 1 ether);
        sykBsc.mint(doe.addr, 2 ether);

        // Vote for john
        vm.startPrank(john.addr, john.addr);
        sykRoot.approve(address(xSykRoot), 1 ether);
        xSykRoot.convert(1 ether, john.addr);
        xSykRoot.approve(address(xSykStaking), 1 ether);
        xSykStaking.stake(1 ether, 42161, john.addr);
        gaugeController.vote(
            VoteParams({
                power: 1 ether,
                totalPower: 1 ether,
                epoch: 0,
                gaugeId: gaugeAId,
                accountId: keccak256(abi.encode(42161, john.addr))
            })
        );
        vm.stopPrank();

        // Vote for joe
        vm.startPrank(doe.addr, doe.addr);
        sykBsc.approve(address(xSykBsc), 2 ether);
        xSykBsc.convert(2 ether, doe.addr);

        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);
        xSykBsc.approve(address(xSykStakingLzAdapterBsc), 2 ether);
        MessagingFee memory _fee = xSykStakingLzAdapterBsc.quote(
            xSykStakingLzAdapterBsc.STAKE_TYPE(), 30110, 2 ether, bytes(""), options, false
        );
        xSykStakingLzAdapterBsc.stake{value: _fee.nativeFee}(2 ether, _fee, options);

        _fee = gaugeControllerLzAdapterBsc.quoteVote(2 ether, gaugeBId, options, false);
        gaugeControllerLzAdapterBsc.vote{value: _fee.nativeFee}(2 ether, gaugeBId, _fee, options);
        vm.stopPrank();

        skip(7 days);
        gaugeController.finalizeEpoch(0);

        gaugeA.pull(0);

        assertEq(sykRoot.balanceOf(address(this)), 433333333333333333333);

        vm.chainId(56);

        uint256 reward = gaugeController.computeRewards(gaugeBId, 0);

        SendParams memory sendParams =
            SendParams({dstEid: 30102, to: address(gaugeB), amount: reward, options: options, xSykAmount: 0});

        MessagingFee memory msgFee = sykLzAdapterRoot.quoteSend(sendParams, false);

        options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(10000000, uint128(msgFee.nativeFee));
        _fee = gaugeControllerLzAdapterBsc.quotePull(
            address(gaugeB), 0, OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0), options, false
        );
        gaugeControllerLzAdapterBsc.pull{value: _fee.nativeFee}(
            address(gaugeB), 0, _fee, OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0), options
        );

        gaugeB.pull();

        assertEq(sykBsc.balanceOf(address(this)), 566666666666666666666);
    }

    function addressToBytes32(address _addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }

    // be able to receive ether
    receive() external payable virtual {}

    fallback() external payable {}
}
