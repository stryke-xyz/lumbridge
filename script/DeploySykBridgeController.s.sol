// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {SykBridgeController} from "../src/token/SykBridgeController.sol";

contract DeploySykBridgeController is Script {
    address syk = 0xACC51FFDeF63fB0c014c882267C3A17261A5eD50;
    address accessManager = 0x91BDa4174c25EfeEF6f4e5721fa36e31e0015801;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        SykBridgeController bridgeController = new SykBridgeController(syk, accessManager);

        console.log(address(bridgeController));

        vm.stopBroadcast();
    }
}
