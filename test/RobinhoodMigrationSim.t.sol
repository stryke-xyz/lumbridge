// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import {Test, console2 as console} from "forge-std/Test.sol";

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import {
    IMessageLibManager,
    SetConfigParam
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";
import {UlnConfig} from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/UlnBase.sol";

import {StrykeTokenChild} from "../src/token/StrykeTokenChild.sol";
import {XStrykeToken} from "../src/governance/XStrykeToken.sol";
import {SykBridgeController} from "../src/token/SykBridgeController.sol";
import {ISykBridgeController} from "../src/interfaces/ISykBridgeController.sol";
import {SykLzAdapter} from "../src/token/bridge-adapters/SykLzAdapter.sol";
import {SendParams, MessagingFee} from "../src/interfaces/ISykLzAdapter.sol";

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface ICamelotV2Router {
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);
}

interface IAerodromeRouter {
    function removeLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);
}

/// @notice Fork simulations for the FRESH (non-CREATE3) SYK launch on Robinhood + liquidity
///         migration executed WITHOUT the original deployer EOA:
///         - new addresses on Robinhood, deployed by any fresh key
///         - Arbitrum bridging split into 10M/day chunks (no admin key to raise limits)
/// Run: forge test --match-contract RobinhoodMigrationSim -vv
contract RobinhoodMigrationSim is Test {
    using OptionsBuilder for bytes;

    // RPCs
    string constant RH_RPC = "https://rpc.mainnet.chain.robinhood.com"; // cloudflare rate-limits bursts; fork is pinned so the local cache absorbs re-runs
    string constant ARB_RPC = "https://arb1.arbitrum.io/rpc";
    string constant BASE_RPC = "https://base-rpc.publicnode.com";

    // Existing (Arbitrum/Base) contracts
    address constant SYK = 0xACC51FFDeF63fB0c014c882267C3A17261A5eD50;
    address constant ADAPTER_OWNER = 0xC4290eA730a461075141e6d5DF1e980E72F1BD1B; // owner + LZ delegate of Arb/Base adapters
    address constant SAFE = 0x2fa6F21eCfE274f594F470c376f5BDd061E08a37;

    // Arbitrum
    address constant ARB_ADAPTER = 0x8022418FBE0e8668a9BaCa3b87F933Cc52225c8e;
    address constant ARB_CONTROLLER = 0x33A46fbcAd7bbC05e38817d972111793bD1AF487;
    address constant CAMELOT_PAIR = 0xe83b6714f7b8d94187d8457592CE6FCf82453cf4;
    address constant CAMELOT_ROUTER = 0xc873fEcbd354f5A56E00E710B90EF4201db2448d;
    address constant WETH_ARB = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant ARB_SEND_ULN = 0x975bcD720be66659e3EB3C0e4F1866a3020E493A;
    address constant ARB_RECEIVE_ULN = 0x7B9E184e07a6EE1aC23eAe0fe8D6Be2f663f05e6;
    address constant ARB_DVN_LZ = 0x2f55C492897526677C5B68fb199ea31E2c126416;
    address constant ARB_DVN_NETHERMIND = 0xa7b5189bcA84Cd304D8553977c7C614329750d99;

    // Base
    address constant BASE_ADAPTER = 0x954EC795Bc449Cdc765a4aD4958dA23FC7Cff47c;
    address constant AERO_POOL = 0x198e98719Fc79197f6436e3570b102ff9C83337f;
    address constant AERO_ROUTER = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;
    address constant WETH_BASE = 0x4200000000000000000000000000000000000006;
    address constant BASE_SEND_ULN = 0xB5320B0B3a13cC860893E2Bd79FCd7e13484Dda2;
    address constant BASE_RECEIVE_ULN = 0xc70AB6f32772f59fBfc23889Caf4Ba3376C84bAf;
    address constant BASE_DVN_LZ = 0x9e059a54699a285714207b43B055483E78FAac25;
    address constant BASE_DVN_NETHERMIND = 0xcd37CA043f8479064e10635020c65FfC005d36f6;

    // Robinhood LayerZero
    address constant RH_LZ_ENDPOINT = 0x6F475642a6e85809B1c36Fa62763669b1b48DD5B;
    address constant RH_SEND_ULN = 0xC39161c743D0307EB9BCc9FEF03eeb9Dc4802de7;
    address constant RH_RECEIVE_ULN = 0xe1844c5D63a9543023008D332Bd3d2e6f1FE1043;
    address constant RH_DVN_LZ = 0xd01ae6905d48315f7bE10C7330aeCF8360Ef5b12;
    address constant RH_DVN_NETHERMIND = 0x0Ffe02DF012299A370D5dd69298A5826EAcaFdF8;

    uint32 constant EID_ARBITRUM = 30110;
    uint32 constant EID_BASE = 30184;
    uint32 constant EID_ROBINHOOD = 30416;
    uint64 constant BRIDGE_CONTROLLER_ROLE = 4;
    uint32 constant CONFIG_TYPE_ULN = 2;

    function _ulnParams(uint32 eid, uint64 confirmations, address dvnA, address dvnB)
        internal
        pure
        returns (SetConfigParam[] memory params)
    {
        address[] memory required = new address[](2);
        (required[0], required[1]) = dvnA < dvnB ? (dvnA, dvnB) : (dvnB, dvnA);
        UlnConfig memory cfg = UlnConfig({
            confirmations: confirmations,
            requiredDVNCount: 2,
            optionalDVNCount: 0,
            optionalDVNThreshold: 0,
            requiredDVNs: required,
            optionalDVNs: new address[](0)
        });
        params = new SetConfigParam[](1);
        params[0] = SetConfigParam(eid, CONFIG_TYPE_ULN, abi.encode(cfg));
    }

    /// @dev Fresh launch on Robinhood by a brand-new EOA (no original deployer, no CREATE3).
    function test_1_RobinhoodFreshDeployAndWiring() public {
        vm.selectFork(vm.createFork(RH_RPC, 51_272_700));
        assertEq(block.chainid, 4663, "not robinhood chain");

        address freshDeployer = makeAddr("freshDeployer");
        vm.deal(freshDeployer, 10 ether);
        vm.startPrank(freshDeployer);

        // mirrors script/DeployRobinhoodFresh.s.sol
        AccessManager am = new AccessManager(freshDeployer);
        StrykeTokenChild sykImpl = new StrykeTokenChild();
        address syk = address(
            new ERC1967Proxy(
                address(sykImpl), abi.encodeWithSelector(StrykeTokenChild.initialize.selector, address(am))
            )
        );
        XStrykeToken xSykImpl = new XStrykeToken();
        address xsyk = address(
            new ERC1967Proxy(
                address(xSykImpl), abi.encodeWithSelector(XStrykeToken.initialize.selector, syk, address(am))
            )
        );
        SykBridgeController controller = new SykBridgeController(syk, address(am));
        SykLzAdapter adapter = new SykLzAdapter(RH_LZ_ENDPOINT, freshDeployer, address(controller), syk, xsyk);

        am.grantRole(BRIDGE_CONTROLLER_ROLE, address(controller), 0);
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = 0x40c10f19;
        selectors[1] = 0x9dc29fac;
        am.setTargetFunctionRole(syk, selectors, BRIDGE_CONTROLLER_ROLE);
        controller.setLimits(address(adapter), 10_000_000 ether, 10_000_000 ether);
        XStrykeToken(xsyk).updateContractWhitelist(address(adapter), true);
        XStrykeToken(xsyk).updateExcessReceiver(SAFE);

        adapter.setPeer(EID_ARBITRUM, bytes32(uint256(uint160(ARB_ADAPTER))));
        adapter.setPeer(EID_BASE, bytes32(uint256(uint160(BASE_ADAPTER))));
        IMessageLibManager ep = IMessageLibManager(RH_LZ_ENDPOINT);
        ep.setConfig(address(adapter), RH_SEND_ULN, _ulnParams(EID_ARBITRUM, 5, RH_DVN_LZ, RH_DVN_NETHERMIND));
        ep.setConfig(address(adapter), RH_SEND_ULN, _ulnParams(EID_BASE, 5, RH_DVN_LZ, RH_DVN_NETHERMIND));
        ep.setConfig(address(adapter), RH_RECEIVE_ULN, _ulnParams(EID_ARBITRUM, 20, RH_DVN_LZ, RH_DVN_NETHERMIND));
        ep.setConfig(address(adapter), RH_RECEIVE_ULN, _ulnParams(EID_BASE, 20, RH_DVN_LZ, RH_DVN_NETHERMIND));

        am.grantRole(am.ADMIN_ROLE(), SAFE, 0);
        vm.stopPrank();

        console.log("fresh SYK:", syk);
        console.log("fresh adapter:", address(adapter));

        // validate mint/burn plumbing exactly as lzReceive would trigger it
        vm.prank(address(adapter));
        controller.mint(address(0xBEEF), 123 ether);
        assertEq(IERC20Min(syk).balanceOf(address(0xBEEF)), 123 ether, "mint plumbing broken");
        vm.prank(address(adapter));
        controller.burn(address(0xBEEF), 123 ether);
        assertEq(IERC20Min(syk).balanceOf(address(0xBEEF)), 0, "burn plumbing broken");

        // Safe co-admin sanity
        (bool isAdmin,) = am.hasRole(am.ADMIN_ROLE(), SAFE);
        assertTrue(isAdmin, "safe not admin");

        // outbound quote RH -> Arbitrum via live default executor + our DVN config
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0);
        MessagingFee memory fee = adapter.quoteSend(SendParams(EID_ARBITRUM, SAFE, 1 ether, 0, options), false);
        console.log("RH -> ARB quoteSend nativeFee (wei):", fee.nativeFee);
        assertGt(fee.nativeFee, 0);
    }

    /// @dev Safe on Arbitrum: pull Camelot liquidity, then bridge ~34M SYK in 10M/day chunks
    ///      (no admin key available to raise the burn limit).
    function test_2_ArbitrumSafeMigration_ChunkedSends() public {
        vm.selectFork(vm.createFork(ARB_RPC));

        uint256 lp = IERC20Min(CAMELOT_PAIR).balanceOf(SAFE);
        assertGt(lp, 0, "no LP");

        // --- Safe tx 1: approve LP ---
        vm.prank(SAFE);
        IERC20Min(CAMELOT_PAIR).approve(CAMELOT_ROUTER, lp);

        // --- Safe tx 2: remove liquidity ---
        vm.prank(SAFE);
        (uint256 outSyk, uint256 outWeth) = ICamelotV2Router(CAMELOT_ROUTER)
            .removeLiquidity(SYK, WETH_ARB, lp, 4_600_000 ether, 18.5 ether, SAFE, block.timestamp + 7 days);
        console.log("Camelot removed SYK:", outSyk / 1e18);
        console.log("Camelot removed WETH (wei):", outWeth);

        // --- Adapter owner (0xC429...) txs: peer + DVN config for the new RH adapter ---
        address rhAdapterNew = makeAddr("rhAdapterNew"); // placeholder for the freshly deployed adapter
        vm.startPrank(ADAPTER_OWNER);
        SykLzAdapter(ARB_ADAPTER).setPeer(EID_ROBINHOOD, bytes32(uint256(uint160(rhAdapterNew))));
        IMessageLibManager(0x1a44076050125825900e736c501f859c50fE728c)
            .setConfig(ARB_ADAPTER, ARB_SEND_ULN, _ulnParams(EID_ROBINHOOD, 20, ARB_DVN_LZ, ARB_DVN_NETHERMIND));
        IMessageLibManager(0x1a44076050125825900e736c501f859c50fE728c)
            .setConfig(ARB_ADAPTER, ARB_RECEIVE_ULN, _ulnParams(EID_ROBINHOOD, 5, ARB_DVN_LZ, ARB_DVN_NETHERMIND));
        vm.stopPrank();

        uint256 total = IERC20Min(SYK).balanceOf(SAFE);
        console.log("Total SYK to bridge:", total / 1e18);

        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0);
        vm.deal(SAFE, 1 ether);

        // --- Safe tx 3: chunk #1 (10M, within the daily burn limit) ---
        SendParams memory sp = SendParams(EID_ROBINHOOD, SAFE, 10_000_000 ether, 0, options);
        MessagingFee memory fee = SykLzAdapter(ARB_ADAPTER).quoteSend(sp, false);
        console.log("ARB -> RH quoteSend nativeFee (wei):", fee.nativeFee);
        vm.prank(SAFE);
        SykLzAdapter(ARB_ADAPTER).send{value: fee.nativeFee}(sp, fee, SAFE);
        assertEq(IERC20Min(SYK).balanceOf(SAFE), total - 10_000_000 ether, "chunk1 not burned");

        // immediate second 10M chunk must revert: daily limit exhausted
        vm.prank(SAFE);
        vm.expectRevert(ISykBridgeController.SykBridgeController_NotHighEnoughLimits.selector);
        SykLzAdapter(ARB_ADAPTER).send{value: fee.nativeFee}(sp, fee, SAFE);

        // --- next day: chunk #2 succeeds after limit replenishes ---
        vm.warp(block.timestamp + 1 days);
        fee = SykLzAdapter(ARB_ADAPTER).quoteSend(sp, false);
        vm.prank(SAFE);
        SykLzAdapter(ARB_ADAPTER).send{value: fee.nativeFee}(sp, fee, SAFE);
        assertEq(IERC20Min(SYK).balanceOf(SAFE), total - 20_000_000 ether, "chunk2 not burned");

        console.log("Remaining after 2 chunks:", IERC20Min(SYK).balanceOf(SAFE) / 1e18);
        console.log("=> repeat daily: chunk #3 = 10M, chunk #4 = remainder");
    }

    /// @dev Safe on Base: pull Aerodrome liquidity and bridge all SYK in one send (< 10M limit).
    function test_3_BaseSafeMigration() public {
        vm.selectFork(vm.createFork(BASE_RPC));

        uint256 lp = IERC20Min(AERO_POOL).balanceOf(SAFE);
        assertGt(lp, 0, "no LP");

        vm.prank(SAFE);
        IERC20Min(AERO_POOL).approve(AERO_ROUTER, lp);

        vm.prank(SAFE);
        (uint256 outWeth, uint256 outSyk) = IAerodromeRouter(AERO_ROUTER)
            .removeLiquidity(WETH_BASE, SYK, false, lp, 18.5 ether, 4_550_000 ether, SAFE, block.timestamp + 7 days);
        console.log("Aerodrome removed WETH (wei):", outWeth);
        console.log("Aerodrome removed SYK:", outSyk / 1e18);

        address rhAdapterNew = makeAddr("rhAdapterNew");
        vm.startPrank(ADAPTER_OWNER);
        SykLzAdapter(BASE_ADAPTER).setPeer(EID_ROBINHOOD, bytes32(uint256(uint160(rhAdapterNew))));
        IMessageLibManager(0x1a44076050125825900e736c501f859c50fE728c)
            .setConfig(BASE_ADAPTER, BASE_SEND_ULN, _ulnParams(EID_ROBINHOOD, 20, BASE_DVN_LZ, BASE_DVN_NETHERMIND));
        IMessageLibManager(0x1a44076050125825900e736c501f859c50fE728c)
            .setConfig(BASE_ADAPTER, BASE_RECEIVE_ULN, _ulnParams(EID_ROBINHOOD, 5, BASE_DVN_LZ, BASE_DVN_NETHERMIND));
        vm.stopPrank();

        uint256 total = IERC20Min(SYK).balanceOf(SAFE);
        console.log("Total SYK to bridge from Base:", total / 1e18);
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0);
        SendParams memory sp = SendParams(EID_ROBINHOOD, SAFE, total, 0, options);

        MessagingFee memory fee = SykLzAdapter(BASE_ADAPTER).quoteSend(sp, false);
        console.log("BASE -> RH quoteSend nativeFee (wei):", fee.nativeFee);
        vm.deal(SAFE, fee.nativeFee + 0.01 ether);
        vm.prank(SAFE);
        SykLzAdapter(BASE_ADAPTER).send{value: fee.nativeFee}(sp, fee, SAFE);
        assertEq(IERC20Min(SYK).balanceOf(SAFE), 0, "SYK not fully burned/bridged");
        console.log("Bridged (burned) all SYK from Safe on Base");
    }
}
