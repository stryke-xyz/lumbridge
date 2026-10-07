// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import {Script} from "forge-std/Script.sol";
import {console2 as console} from "forge-std/console2.sol";

import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";

import {SykLzAdapter} from "../src/token/bridge-adapters/SykLzAdapter.sol";
import {SendParams, MessagingFee} from "../src/interfaces/ISykLzAdapter.sol";

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
}

/// @notice Bridges SYK from Base to Robinhood Chain via the live LayerZero adapters.
///         No token approval needed — the adapter burns SYK directly from the sender.
///         Sender needs a little ETH on Base for the LayerZero fee (~0.0003 ETH).
///
///   export PRIVATE_KEY=<sender pk>
///   B=script/BridgeSykBaseToRobinhood.s.sol
///   BASE=https://mainnet.base.org
///
///   # 1. check balance + fee (read-only)
///   forge script $B --rpc-url $BASE --sig "check(uint256)" <AMOUNT_WEI>
///
///   # 2. bridge a specific amount to a recipient on Robinhood
///   forge script $B --rpc-url $BASE --broadcast --sig "bridge(uint256,address)" <AMOUNT_WEI> <TO_ON_RH>
///
///   # 3. or bridge the sender's ENTIRE SYK balance
///   forge script $B --rpc-url $BASE --broadcast --sig "bridgeAll(address)" <TO_ON_RH>
///
///   # verify arrival (1-3 min; track tx on layerzeroscan.com):
///   cast call 0x97C065EEd0309F182777BfFa41A9C0027c190DF1 "balanceOf(address)(uint256)" <TO_ON_RH> \
///     -r https://rpc.mainnet.chain.robinhood.com
contract BridgeSykBaseToRobinhood is Script {
    using OptionsBuilder for bytes;

    address constant SYK = 0xACC51FFDeF63fB0c014c882267C3A17261A5eD50; // SYK on Base
    address constant BASE_ADAPTER = 0x954EC795Bc449Cdc765a4aD4958dA23FC7Cff47c;
    uint32 constant EID_ROBINHOOD = 30416;
    uint256 constant DAILY_BURN_LIMIT = 10_000_000 ether;

    function _options() internal pure returns (bytes memory) {
        return OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0);
    }

    /// read-only pre-flight: balance, fee quote, limit check
    function check(uint256 amount) public view {
        address sender = vm.addr(vm.envUint("PRIVATE_KEY"));
        uint256 bal = IERC20Min(SYK).balanceOf(sender);
        console.log("sender:", sender);
        console.log("SYK balance (wei):", bal);
        console.log("amount to bridge (wei):", amount);
        require(block.chainid == 8453, "run with the Base RPC");
        require(bal >= amount, "insufficient SYK balance");
        require(amount <= DAILY_BURN_LIMIT, "exceeds 10M/day bridge limit - split into daily chunks");

        MessagingFee memory fee =
            SykLzAdapter(BASE_ADAPTER).quoteSend(SendParams(EID_ROBINHOOD, sender, amount, 0, _options()), false);
        console.log("LayerZero fee (wei):", fee.nativeFee);
        console.log("sender ETH balance (wei):", sender.balance);
        require(sender.balance >= fee.nativeFee, "not enough ETH on Base for the fee");
        console.log("READY - pathway configured, balance and fee OK");
    }

    /// bridges `amount` SYK from the broadcaster to `to` on Robinhood
    function bridge(uint256 amount, address to) public {
        require(block.chainid == 8453, "run with the Base RPC");
        require(amount > 0, "amount zero");
        require(to != address(0), "recipient zero");
        require(amount <= DAILY_BURN_LIMIT, "exceeds 10M/day bridge limit - split into daily chunks");

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address sender = vm.addr(pk);
        require(IERC20Min(SYK).balanceOf(sender) >= amount, "insufficient SYK balance");

        SendParams memory sp = SendParams(EID_ROBINHOOD, to, amount, 0, _options());
        MessagingFee memory fee = SykLzAdapter(BASE_ADAPTER).quoteSend(sp, false);
        console.log("LayerZero fee (wei):", fee.nativeFee);

        vm.startBroadcast(pk);
        SykLzAdapter(BASE_ADAPTER).send{value: fee.nativeFee}(sp, fee, sender);
        vm.stopBroadcast();

        console.log("bridged SYK (wei):", amount);
        console.log("to (on Robinhood):", to);
        console.log("track: https://layerzeroscan.com  |  SYK on RH: 0x97C065EEd0309F182777BfFa41A9C0027c190DF1");
    }

    /// bridges the broadcaster's entire SYK balance to `to` on Robinhood
    function bridgeAll(address to) external {
        address sender = vm.addr(vm.envUint("PRIVATE_KEY"));
        bridge(IERC20Min(SYK).balanceOf(sender), to);
    }
}
