// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import {CREATE3Factory} from "create3-factory/CREATE3Factory.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {StrykeTokenRoot} from "../src/token/StrykeTokenRoot.sol";

contract DeploySyk is Script {
    CREATE3Factory factory;

    address accessManager;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        factory = CREATE3Factory(0x9fBB3DF7C40Da2e5A0dE984fFE2CCB7C47cd0ABf);

        StrykeTokenRoot sykImplementation = new StrykeTokenRoot();

        address syk = factory.deploy(
            bytes32(bytes("SYK")),
            abi.encodePacked(
                type(ERC1967Proxy).creationCode,
                abi.encode(
                    address(sykImplementation),
                    abi.encodeWithSelector(StrykeTokenRoot.initialize.selector, address(accessManager))
                )
            )
        );

        console.log(syk);

        vm.stopBroadcast();
    }
}
