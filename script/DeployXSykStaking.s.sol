// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {XSykStaking} from "../src/governance/XSykStaking.sol";

contract DeployXSykStaking is Script {
    address accessManager = 0x91BDa4174c25EfeEF6f4e5721fa36e31e0015801;
    address xSyk = 0x50E04E222Fc1be96E94E86AcF1136cB0E97E1d40;
    address syk = 0xACC51FFDeF63fB0c014c882267C3A17261A5eD50;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        XSykStaking xSykStaking = new XSykStaking(xSyk, syk, xSyk, accessManager);

        console.log(address(xSykStaking));

        vm.stopBroadcast();
    }
}
