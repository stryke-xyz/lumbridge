// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import {Test, console2 as console} from "forge-std/Test.sol";

interface IXSykMin {
    function convert(uint256 amount, address to) external;
    function whitelistedContracts(address) external view returns (bool);
}

/// @notice Proves that bridging with xSykAmount > 0 into Arbitrum/Base would revert on
///         lzReceive (adapter is not whitelisted on xSYK), which would strand the message.
///         UI must always send xSykAmount = 0.
contract XSykBridgeSafetyTest is Test {
    address constant ARB_ADAPTER = 0x8022418FBE0e8668a9BaCa3b87F933Cc52225c8e;
    address constant ARB_XSYK = 0x50E04E222Fc1be96E94E86AcF1136cB0E97E1d40;
    address constant BASE_ADAPTER = 0x954EC795Bc449Cdc765a4aD4958dA23FC7Cff47c;

    address constant RH_ADAPTER = 0xa51175F9076B2535003AC146921485083aB3A63c;
    address constant RH_XSYK = 0x90fba4EC914B263EA7b6711C4fE4C5a3859081C5;

    function test_arb_convertFromAdapterReverts() public {
        vm.selectFork(vm.createFork("https://arb1.arbitrum.io/rpc"));
        assertFalse(IXSykMin(ARB_XSYK).whitelistedContracts(ARB_ADAPTER), "arb adapter unexpectedly whitelisted");

        vm.prank(ARB_ADAPTER, makeAddr("origin")); // msg.sender != tx.origin => contract path
        vm.expectRevert(); // ContractWhitelist_NotWhitelisted
        IXSykMin(ARB_XSYK).convert(1 ether, address(0xBEEF));
        console.log("ARB: xSykAmount>0 would revert lzReceive -> message stranded");
    }

    function test_base_convertFromAdapterReverts() public {
        vm.selectFork(vm.createFork("https://mainnet.base.org"));
        assertFalse(IXSykMin(ARB_XSYK).whitelistedContracts(BASE_ADAPTER), "base adapter unexpectedly whitelisted");

        vm.prank(BASE_ADAPTER, makeAddr("origin"));
        vm.expectRevert();
        IXSykMin(ARB_XSYK).convert(1 ether, address(0xBEEF));
        console.log("BASE: xSykAmount>0 would revert lzReceive -> message stranded");
    }

    function test_robinhood_adapterIsWhitelisted() public {
        vm.selectFork(vm.createFork("https://rpc.mainnet.chain.robinhood.com"));
        assertTrue(IXSykMin(RH_XSYK).whitelistedContracts(RH_ADAPTER), "rh adapter should be whitelisted");
        console.log("RH: xSYK conversion is wired, but unused -> still send xSykAmount = 0");
    }
}
