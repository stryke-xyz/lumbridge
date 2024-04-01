// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import {CREATE3Factory} from "create3-factory/CREATE3Factory.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

contract DeployAccessManager is Script {
    CREATE3Factory factory;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        factory = CREATE3Factory(0x9fBB3DF7C40Da2e5A0dE984fFE2CCB7C47cd0ABf);

        address accessManager = factory.deploy(
            bytes32(bytes("AccessManager")), abi.encodePacked(type(AccessManager).creationCode, abi.encode(msg.sender))
        );

        console.log(accessManager);

        vm.stopBroadcast();
    }
}
