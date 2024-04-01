// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import {CREATE3Factory} from "create3-factory/CREATE3Factory.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {XStrykeToken} from "../src/governance/XStrykeToken.sol";

contract DeployXSyk is Script {
    CREATE3Factory factory;

    address accessManager;
    address syk;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        factory = CREATE3Factory(0x9fBB3DF7C40Da2e5A0dE984fFE2CCB7C47cd0ABf);

        XStrykeToken xSykImplementation = new XStrykeToken();

        address xsyk = factory.deploy(
            bytes32(bytes("xSYK")),
            abi.encodePacked(
                type(ERC1967Proxy).creationCode,
                abi.encode(
                    address(xSykImplementation),
                    abi.encodeWithSelector(XStrykeToken.initialize.selector, address(syk), address(accessManager))
                )
            )
        );

        console.log(xsyk);

        vm.stopBroadcast();
    }
}
