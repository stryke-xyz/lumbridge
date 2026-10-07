// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import {Script} from "forge-std/Script.sol";
import {console2 as console} from "forge-std/console2.sol";

import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import {
    IMessageLibManager,
    SetConfigParam
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";
import {UlnConfig} from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/UlnBase.sol";

import {SykLzAdapter} from "../src/token/bridge-adapters/SykLzAdapter.sol";
import {SendParams, MessagingFee} from "../src/interfaces/ISykLzAdapter.sol";

/// @notice Opens the LayerZero pathway Arbitrum/Base <-> Robinhood for the existing SYK
///         adapters and provides small test sends. All txs signed by the adapter owner
///         (0xC4290eA730a461075141e6d5DF1e980E72F1BD1B).
///
///   export PRIVATE_KEY=<0xC429 key>
///   C=script/ConfigureRobinhoodSyk.s.sol
///   ARB=https://arb1.arbitrum.io/rpc
///   BASE=https://mainnet.base.org   # publicnode 403s on receipt queries
///   RH=https://rpc.mainnet.chain.robinhood.com
///
///   -- open the pathway (once per chain) --
///   forge script $C --rpc-url $ARB  --broadcast --sig "arbSetPeer()"
///   forge script $C --rpc-url $ARB  --broadcast --sig "arbSetDvnConfigs()"
///   forge script $C --rpc-url $BASE --broadcast --sig "baseSetPeer()"
///   forge script $C --rpc-url $BASE --broadcast --sig "baseSetDvnConfigs()"
///
///   -- pre-flight check (read-only, reverts if the pathway isn't ready) --
///   forge script $C --rpc-url $ARB  --sig "quoteArb()"
///   forge script $C --rpc-url $BASE --sig "quoteBase()"
///
///   -- test bridge (broadcaster must hold >= amount SYK; no approval needed) --
///   forge script $C --rpc-url $ARB  --broadcast --sig "testSendToRobinhood(uint256,address)" 1000000000000000000 <TO_ON_RH>
///   forge script $C --rpc-url $RH   --broadcast --sig "testSendBackToArbitrum(uint256,address)" 1000000000000000000 <TO_ON_ARB>
contract ConfigureRobinhoodSyk is Script {
    using OptionsBuilder for bytes;

    // adapters
    address constant ARB_ADAPTER = 0x8022418FBE0e8668a9BaCa3b87F933Cc52225c8e;
    address constant BASE_ADAPTER = 0x954EC795Bc449Cdc765a4aD4958dA23FC7Cff47c;
    address constant RH_ADAPTER = 0xa51175F9076B2535003AC146921485083aB3A63c;

    // LayerZero endpoint + libs + DVNs (Arbitrum)
    address constant LZ_ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c; // same on Arb & Base
    address constant ARB_SEND_ULN = 0x975bcD720be66659e3EB3C0e4F1866a3020E493A;
    address constant ARB_RECEIVE_ULN = 0x7B9E184e07a6EE1aC23eAe0fe8D6Be2f663f05e6;
    address constant ARB_DVN_LZ = 0x2f55C492897526677C5B68fb199ea31E2c126416;
    address constant ARB_DVN_NETHERMIND = 0xa7b5189bcA84Cd304D8553977c7C614329750d99;

    // Base
    address constant BASE_SEND_ULN = 0xB5320B0B3a13cC860893E2Bd79FCd7e13484Dda2;
    address constant BASE_RECEIVE_ULN = 0xc70AB6f32772f59fBfc23889Caf4Ba3376C84bAf;
    address constant BASE_DVN_LZ = 0x9e059a54699a285714207b43B055483E78FAac25;
    address constant BASE_DVN_NETHERMIND = 0xcd37CA043f8479064e10635020c65FfC005d36f6;

    uint32 constant EID_ARBITRUM = 30110;
    uint32 constant EID_ROBINHOOD = 30416;

    modifier broadcast() {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        _;
        vm.stopBroadcast();
    }

    // ------------------------------------------------------------- arbitrum

    /// 1 tx
    function arbSetPeer() public broadcast {
        SykLzAdapter(ARB_ADAPTER).setPeer(EID_ROBINHOOD, bytes32(uint256(uint160(RH_ADAPTER))));
        console.log("ARB adapter peer 30416 -> RH adapter set");
    }

    /// 2 txs — send conf 20, receive conf 5 (matches RH-side mirror config)
    function arbSetDvnConfigs() public broadcast {
        IMessageLibManager ep = IMessageLibManager(LZ_ENDPOINT);
        ep.setConfig(ARB_ADAPTER, ARB_SEND_ULN, _uln(EID_ROBINHOOD, 20, ARB_DVN_LZ, ARB_DVN_NETHERMIND));
        ep.setConfig(ARB_ADAPTER, ARB_RECEIVE_ULN, _uln(EID_ROBINHOOD, 5, ARB_DVN_LZ, ARB_DVN_NETHERMIND));
        console.log("ARB DVN configs set for eid 30416");
    }

    // ----------------------------------------------------------------- base

    /// 1 tx
    function baseSetPeer() public broadcast {
        SykLzAdapter(BASE_ADAPTER).setPeer(EID_ROBINHOOD, bytes32(uint256(uint160(RH_ADAPTER))));
        console.log("BASE adapter peer 30416 -> RH adapter set");
    }

    /// 2 txs
    function baseSetDvnConfigs() public broadcast {
        IMessageLibManager ep = IMessageLibManager(LZ_ENDPOINT);
        ep.setConfig(BASE_ADAPTER, BASE_SEND_ULN, _uln(EID_ROBINHOOD, 20, BASE_DVN_LZ, BASE_DVN_NETHERMIND));
        ep.setConfig(BASE_ADAPTER, BASE_RECEIVE_ULN, _uln(EID_ROBINHOOD, 5, BASE_DVN_LZ, BASE_DVN_NETHERMIND));
        console.log("BASE DVN configs set for eid 30416");
    }

    // ----------------------------------------------------- pre-flight quotes

    /// reverts with "Please set your OApp's DVNs and/or Executor" if the pathway isn't ready
    function quoteArb() public view {
        MessagingFee memory fee =
            SykLzAdapter(ARB_ADAPTER).quoteSend(SendParams(EID_ROBINHOOD, msg.sender, 1 ether, 0, _options()), false);
        console.log("ARB -> RH pathway OK, fee (wei):", fee.nativeFee);
    }

    function quoteBase() public view {
        MessagingFee memory fee =
            SykLzAdapter(BASE_ADAPTER).quoteSend(SendParams(EID_ROBINHOOD, msg.sender, 1 ether, 0, _options()), false);
        console.log("BASE -> RH pathway OK, fee (wei):", fee.nativeFee);
    }

    // ------------------------------------------------------------ test sends

    /// burns `amount` SYK from the broadcaster and mints to `to` on Robinhood.
    /// run with the Arbitrum OR Base RPC — the adapter is auto-picked by chain id.
    function testSendToRobinhood(uint256 amount, address to) public broadcast {
        address adapter = block.chainid == 42161 ? ARB_ADAPTER : BASE_ADAPTER;
        SendParams memory sp = SendParams(EID_ROBINHOOD, to, amount, 0, _options());
        MessagingFee memory fee = SykLzAdapter(adapter).quoteSend(sp, false);
        console.log("fee (wei):", fee.nativeFee);
        SykLzAdapter(adapter).send{value: fee.nativeFee}(sp, fee, msg.sender);
        console.log("sent", amount / 1e18, "SYK -> Robinhood, to:", to);
    }

    /// reverse test: run with the Robinhood RPC after SYK has arrived there
    function testSendBackToArbitrum(uint256 amount, address to) public broadcast {
        SendParams memory sp = SendParams(EID_ARBITRUM, to, amount, 0, _options());
        MessagingFee memory fee = SykLzAdapter(RH_ADAPTER).quoteSend(sp, false);
        console.log("fee (wei):", fee.nativeFee);
        SykLzAdapter(RH_ADAPTER).send{value: fee.nativeFee}(sp, fee, msg.sender);
        console.log("sent", amount / 1e18, "SYK -> Arbitrum, to:", to);
    }

    // -------------------------------------------------------------- helpers

    function _options() internal pure returns (bytes memory) {
        return OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0);
    }

    function _uln(uint32 eid, uint64 confirmations, address dvnA, address dvnB)
        internal
        pure
        returns (SetConfigParam[] memory params)
    {
        address[] memory dvns = new address[](2);
        (dvns[0], dvns[1]) = dvnA < dvnB ? (dvnA, dvnB) : (dvnB, dvnA);
        params = new SetConfigParam[](1);
        params[0] = SetConfigParam(eid, 2, abi.encode(UlnConfig(confirmations, 2, 0, 0, dvns, new address[](0))));
    }
}
