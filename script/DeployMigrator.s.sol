// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import {CREATE3Factory} from "create3-factory/CREATE3Factory.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {SykMigrator} from "../src/migration/SykMigrator.sol";

contract DeployMigrator is Script {
    CREATE3Factory factory;

    address accessManager = 0x91BDa4174c25EfeEF6f4e5721fa36e31e0015801;
    address dpx = 0x6C2C06790b3E3E3c38e12Ee22F8183b37a13EE55;
    address rdpx = 0x32Eb7902D4134bf98A28b963D26de779AF92A212;
    address syk = 0xACC51FFDeF63fB0c014c882267C3A17261A5eD50;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        SykMigrator migrator = new SykMigrator(dpx, rdpx, syk, accessManager);

        console.log(address(migrator));

        vm.stopBroadcast();
    }
}
