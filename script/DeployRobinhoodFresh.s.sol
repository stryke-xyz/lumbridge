// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import {Script} from "forge-std/Script.sol";
import {console2 as console} from "forge-std/console2.sol";

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {
    IMessageLibManager,
    SetConfigParam
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";
import {UlnConfig} from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/UlnBase.sol";

import {StrykeTokenChild} from "../src/token/StrykeTokenChild.sol";
import {XStrykeToken} from "../src/governance/XStrykeToken.sol";
import {SykBridgeController} from "../src/token/SykBridgeController.sol";
import {SykLzAdapter} from "../src/token/bridge-adapters/SykLzAdapter.sol";

/// @notice Step-by-step SYK launch on Robinhood Chain (chain id 4663) from any EOA.
///         No CREATE3 — addresses differ from Arbitrum/Base (canonical addresses are
///         unreachable without the original 0xf885... deployer key anyway).
///         Run each step separately, record the printed address, feed it to the next step:
///
///   export PRIVATE_KEY=<deployer pk>   # e.g. 0xC4290... key
///   export RPC=https://rpc.mainnet.chain.robinhood.com
///   S=script/DeployRobinhoodFresh.s.sol
///   V=(--verify --verifier sourcify)   # zsh array (a plain string won't word-split); blockscout side: script/verify-robinhood.sh
///
///   1. forge script $S --rpc-url $RPC --broadcast $V --sig "step1_deployAccessManager()"
///   2. forge script $S --rpc-url $RPC --broadcast $V --sig "step2_deploySyk(address)" <AM>
///   3. forge script $S --rpc-url $RPC --broadcast $V --sig "step3_deployXSyk(address,address)" <SYK> <AM>
///   4. forge script $S --rpc-url $RPC --broadcast $V --sig "step4_deployBridgeController(address,address)" <SYK> <AM>
///   5. forge script $S --rpc-url $RPC --broadcast $V --sig "step5_deployLzAdapter(address,address,address)" <CONTROLLER> <SYK> <XSYK>
///   6. forge script $S --rpc-url $RPC --broadcast --sig "step6_wireRoles(address,address,address)" <AM> <SYK> <CONTROLLER>
///   7. forge script $S --rpc-url $RPC --broadcast --sig "step7_setLimits(address,address)" <CONTROLLER> <ADAPTER>
///   8. forge script $S --rpc-url $RPC --broadcast --sig "step8_wireXSyk(address,address)" <XSYK> <ADAPTER>
///   9. forge script $S --rpc-url $RPC --broadcast --sig "step9_setPeers(address)" <ADAPTER>
///  10. forge script $S --rpc-url $RPC --broadcast --sig "step10_setDvnConfigs(address)" <ADAPTER>
///  11. forge script $S --rpc-url $RPC --broadcast --sig "step11_grantSafeAdmin(address)" <AM>
///  12. forge script $S --rpc-url $RPC --sig "verifyAll(address,address,address,address,address)" <AM> <SYK> <XSYK> <CONTROLLER> <ADAPTER>
///
///         Steps 6-11 are idempotent — safe to re-run if a tx fails halfway.
contract DeployRobinhoodFresh is Script {
    // --- LayerZero on Robinhood (EID 30416) ---
    address constant LZ_ENDPOINT = 0x6F475642a6e85809B1c36Fa62763669b1b48DD5B;
    address constant SEND_ULN = 0xC39161c743D0307EB9BCc9FEF03eeb9Dc4802de7;
    address constant RECEIVE_ULN = 0xe1844c5D63a9543023008D332Bd3d2e6f1FE1043;
    address constant DVN_NETHERMIND = 0x0Ffe02DF012299A370D5dd69298A5826EAcaFdF8;
    address constant DVN_LZ_LABS = 0xd01ae6905d48315f7bE10C7330aeCF8360Ef5b12;

    // --- existing adapters to peer with ---
    address constant ARB_ADAPTER = 0x8022418FBE0e8668a9BaCa3b87F933Cc52225c8e;
    address constant BASE_ADAPTER = 0x954EC795Bc449Cdc765a4aD4958dA23FC7Cff47c;
    uint32 constant EID_ARBITRUM = 30110;
    uint32 constant EID_BASE = 30184;

    // treasury Safe (already replayed on Robinhood at the same address)
    address constant TREASURY_SAFE = 0x2fa6F21eCfE274f594F470c376f5BDd061E08a37;

    uint64 constant BRIDGE_CONTROLLER_ROLE = 4;
    uint256 constant DAILY_LIMIT = 10_000_000 ether;

    modifier broadcast() {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        _;
        vm.stopBroadcast();
    }

    function _deployer() internal view returns (address) {
        return vm.addr(vm.envUint("PRIVATE_KEY"));
    }

    // ---------------------------------------------------------------- deploys

    /// 1 tx — deployer becomes initial admin
    function step1_deployAccessManager() public broadcast {
        AccessManager am = new AccessManager(_deployer());
        console.log("AccessManager:", address(am));
    }

    /// 2 txs — implementation + ERC1967 proxy (initialized in constructor)
    function step2_deploySyk(address accessManager) public broadcast {
        StrykeTokenChild impl = new StrykeTokenChild();
        address syk = address(
            new ERC1967Proxy(address(impl), abi.encodeWithSelector(StrykeTokenChild.initialize.selector, accessManager))
        );
        console.log("SYK impl:      ", address(impl));
        console.log("SYK (proxy):   ", syk);
    }

    /// 2 txs — implementation + ERC1967 proxy
    function step3_deployXSyk(address syk, address accessManager) public broadcast {
        XStrykeToken impl = new XStrykeToken();
        address xsyk = address(
            new ERC1967Proxy(
                address(impl), abi.encodeWithSelector(XStrykeToken.initialize.selector, syk, accessManager)
            )
        );
        console.log("xSYK impl:     ", address(impl));
        console.log("xSYK (proxy):  ", xsyk);
    }

    /// 1 tx
    function step4_deployBridgeController(address syk, address accessManager) public broadcast {
        SykBridgeController controller = new SykBridgeController(syk, accessManager);
        console.log("SykBridgeController:", address(controller));
    }

    /// 1 tx — broadcaster becomes adapter owner AND LayerZero delegate
    function step5_deployLzAdapter(address controller, address syk, address xsyk) public broadcast {
        SykLzAdapter adapter = new SykLzAdapter(LZ_ENDPOINT, _deployer(), controller, syk, xsyk);
        console.log("SykLzAdapter:", address(adapter));
        console.log("owner/delegate:", _deployer());
    }

    // ----------------------------------------------------------------- wiring

    /// 2 txs — controller gets role 4; role 4 gated to SYK mint/burn (mirrors Arbitrum/Base)
    function step6_wireRoles(address accessManager, address syk, address controller) public broadcast {
        AccessManager(accessManager).grantRole(BRIDGE_CONTROLLER_ROLE, controller, 0);
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = 0x40c10f19; // mint(address,uint256)
        selectors[1] = 0x9dc29fac; // burn(address,uint256)
        AccessManager(accessManager).setTargetFunctionRole(syk, selectors, BRIDGE_CONTROLLER_ROLE);
        console.log("roles wired");
    }

    /// 1 tx — 10M/day mint+burn allowance for the adapter
    function step7_setLimits(address controller, address adapter) public broadcast {
        SykBridgeController(controller).setLimits(adapter, DAILY_LIMIT, DAILY_LIMIT);
        console.log("limits set: 10M/day mint+burn");
    }

    /// 2 txs — adapter may call xSYK convert; excess vests to the Safe
    function step8_wireXSyk(address xsyk, address adapter) public broadcast {
        XStrykeToken(xsyk).updateContractWhitelist(adapter, true);
        XStrykeToken(xsyk).updateExcessReceiver(TREASURY_SAFE);
        console.log("xSYK wired");
    }

    /// 2 txs
    function step9_setPeers(address adapter) public broadcast {
        SykLzAdapter(adapter).setPeer(EID_ARBITRUM, bytes32(uint256(uint160(ARB_ADAPTER))));
        SykLzAdapter(adapter).setPeer(EID_BASE, bytes32(uint256(uint160(BASE_ADAPTER))));
        console.log("peers set: 30110 -> ARB adapter, 30184 -> BASE adapter");
    }

    /// 4 txs — 2-of-2 DVNs (Nethermind + LZ Labs), send conf 5 / receive conf 20
    function step10_setDvnConfigs(address adapter) public broadcast {
        IMessageLibManager ep = IMessageLibManager(LZ_ENDPOINT);
        ep.setConfig(adapter, SEND_ULN, _uln(EID_ARBITRUM, 5));
        ep.setConfig(adapter, SEND_ULN, _uln(EID_BASE, 5));
        ep.setConfig(adapter, RECEIVE_ULN, _uln(EID_ARBITRUM, 20));
        ep.setConfig(adapter, RECEIVE_ULN, _uln(EID_BASE, 20));
        console.log("DVN configs set (send+receive, Arb+Base)");
    }

    /// 1 tx — Safe becomes co-admin (deployer keeps admin for the launch window)
    function step11_grantSafeAdmin(address accessManager) public broadcast {
        AccessManager am = AccessManager(accessManager);
        am.grantRole(am.ADMIN_ROLE(), TREASURY_SAFE, 0);
        console.log("Safe granted admin:", TREASURY_SAFE);
    }

    // ------------------------------------------------------------ verification

    /// read-only — run WITHOUT --broadcast; reverts on any mis-wiring
    function verifyAll(address accessManager, address syk, address xsyk, address controller, address adapter)
        public
        view
    {
        AccessManager am = AccessManager(accessManager);

        require(StrykeTokenChild(syk).authority() == accessManager, "syk authority wrong");
        require(XStrykeToken(xsyk).authority() == accessManager, "xsyk authority wrong");

        (bool hasRole,) = am.hasRole(BRIDGE_CONTROLLER_ROLE, controller);
        require(hasRole, "controller missing role 4");
        require(
            am.getTargetFunctionRole(syk, 0x40c10f19) == BRIDGE_CONTROLLER_ROLE
                && am.getTargetFunctionRole(syk, 0x9dc29fac) == BRIDGE_CONTROLLER_ROLE,
            "mint/burn not gated to role 4"
        );

        require(SykBridgeController(controller).mintingMaxLimitOf(adapter) == DAILY_LIMIT, "mint limit wrong");
        require(SykBridgeController(controller).burningMaxLimitOf(adapter) == DAILY_LIMIT, "burn limit wrong");

        require(XStrykeToken(xsyk).whitelistedContracts(adapter), "adapter not whitelisted on xSYK");
        require(XStrykeToken(xsyk).excessReceiver() == TREASURY_SAFE, "excess receiver wrong");

        require(SykLzAdapter(adapter).peers(EID_ARBITRUM) == bytes32(uint256(uint160(ARB_ADAPTER))), "arb peer wrong");
        require(SykLzAdapter(adapter).peers(EID_BASE) == bytes32(uint256(uint160(BASE_ADAPTER))), "base peer wrong");

        _checkUln(adapter, SEND_ULN, EID_ARBITRUM, 5);
        _checkUln(adapter, SEND_ULN, EID_BASE, 5);
        _checkUln(adapter, RECEIVE_ULN, EID_ARBITRUM, 20);
        _checkUln(adapter, RECEIVE_ULN, EID_BASE, 20);

        (bool safeIsAdmin,) = am.hasRole(am.ADMIN_ROLE(), TREASURY_SAFE);
        require(safeIsAdmin, "safe not admin");

        console.log("ALL CHECKS PASSED");
        console.log("adapter owner:", SykLzAdapter(adapter).owner());
    }

    function _checkUln(address adapter, address lib, uint32 eid, uint64 confirmations) internal view {
        bytes memory raw = IMessageLibManager(LZ_ENDPOINT).getConfig(adapter, lib, eid, 2);
        UlnConfig memory cfg = abi.decode(raw, (UlnConfig));
        require(cfg.confirmations == confirmations, "uln confirmations wrong");
        require(cfg.requiredDVNCount == 2, "uln dvn count wrong");
        require(cfg.requiredDVNs[0] == DVN_NETHERMIND && cfg.requiredDVNs[1] == DVN_LZ_LABS, "uln dvns wrong");
    }

    function _uln(uint32 eid, uint64 confirmations) internal pure returns (SetConfigParam[] memory params) {
        address[] memory dvns = new address[](2);
        dvns[0] = DVN_NETHERMIND; // must be sorted ascending
        dvns[1] = DVN_LZ_LABS;
        params = new SetConfigParam[](1);
        params[0] = SetConfigParam(eid, 2, abi.encode(UlnConfig(confirmations, 2, 0, 0, dvns, new address[](0))));
    }
}
