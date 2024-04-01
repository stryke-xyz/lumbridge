// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import {CREATE3Factory} from "create3-factory/CREATE3Factory.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {SykMigrator} from "../src/migration/SykMigrator.sol";

contract DeployMigrator is Script {
    CREATE3Factory factory;

    address accessManager;
    address dpx;
    address rdpx;
    address syk;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        SykMigrator migrator = new SykMigrator(dpx, rdpx, syk, accessManager);

        console.log(address(migrator));

        vm.stopBroadcast();
    }
}
