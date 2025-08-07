// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import {CREATE3Factory} from "create3-factory/CREATE3Factory.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {StrykeTokenChild} from "../src/token/StrykeTokenChild.sol";

contract DeploySykChild is Script {
    CREATE3Factory factory;

    address accessManager = 0x91BDa4174c25EfeEF6f4e5721fa36e31e0015801;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        factory = CREATE3Factory(0x9fBB3DF7C40Da2e5A0dE984fFE2CCB7C47cd0ABf);

        StrykeTokenChild sykImplementation = new StrykeTokenChild();

        address syk = factory.deploy(
            bytes32(bytes("SYK")),
            abi.encodePacked(
                type(ERC1967Proxy).creationCode,
                abi.encode(
                    address(sykImplementation),
                    abi.encodeWithSelector(StrykeTokenChild.initialize.selector, address(accessManager))
                )
            )
        );

        console.log(syk);

        vm.stopBroadcast();
    }
}
