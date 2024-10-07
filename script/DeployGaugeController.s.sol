// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {GaugeController} from "../src/gauge/GaugeController.sol";

contract DeployGaugeController is Script {
    address syk = 0xACC51FFDeF63fB0c014c882267C3A17261A5eD50;
    address xSyk = 0x50E04E222Fc1be96E94E86AcF1136cB0E97E1d40;
    address xSykStaking = 0x8263A867eF2d952a3fC0c7cD3cE0895Db30cEb4B;
    address accessManager = 0x91BDa4174c25EfeEF6f4e5721fa36e31e0015801;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        GaugeController gaugeControllerImplementation = new GaugeController();

        ERC1967Proxy gc = new ERC1967Proxy(
            address(gaugeControllerImplementation),
            abi.encodeWithSelector(GaugeController.initialize.selector, syk, xSyk, xSykStaking, accessManager)
        );

        console.log(address(gc));

        vm.stopBroadcast();
    }
}
