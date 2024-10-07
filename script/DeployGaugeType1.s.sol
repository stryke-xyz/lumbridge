// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {GaugeController} from "../src/gauge/GaugeController.sol";
import {GaugeType1} from "../src/gauge/GaugeType1.sol";
import {GaugeInfo} from "../src/interfaces/IGaugeController.sol";

contract DeployGaugeType1 is Script {
    address syk = 0xACC51FFDeF63fB0c014c882267C3A17261A5eD50;
    address gaugeController = 0xFdf1B2c4E291b17f8E998e89cF28985fAF3cE6A1;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        GaugeType1 gaugeImplementation = new GaugeType1();

        GaugeType1 pcsWethUsdcGauge = GaugeType1(
            address(
                new ERC1967Proxy(
                    address(gaugeImplementation),
                    abi.encodeWithSelector(
                        GaugeType1.initialize.selector, 0xf885390B75035e94ac72AeF3E0D0eD5ec3b85d37, gaugeController, syk
                    )
                )
            )
        );

        console.log(address(pcsWethUsdcGauge));

        GaugeType1 pcsWbtcUsdcGauge = GaugeType1(
            address(
                new ERC1967Proxy(
                    address(gaugeImplementation),
                    abi.encodeWithSelector(
                        GaugeType1.initialize.selector, 0xf885390B75035e94ac72AeF3E0D0eD5ec3b85d37, gaugeController, syk
                    )
                )
            )
        );

        console.log(address(pcsWbtcUsdcGauge));

        GaugeType1 orangePcsWethUsdcGauge = GaugeType1(
            address(
                new ERC1967Proxy(
                    address(gaugeImplementation),
                    abi.encodeWithSelector(
                        GaugeType1.initialize.selector, 0xf885390B75035e94ac72AeF3E0D0eD5ec3b85d37, gaugeController, syk
                    )
                )
            )
        );

        console.log(address(orangePcsWethUsdcGauge));

        GaugeType1 orangePcsWbtcUsdcGauge = GaugeType1(
            address(
                new ERC1967Proxy(
                    address(gaugeImplementation),
                    abi.encodeWithSelector(
                        GaugeType1.initialize.selector, 0xf885390B75035e94ac72AeF3E0D0eD5ec3b85d37, gaugeController, syk
                    )
                )
            )
        );

        console.log(address(orangePcsWbtcUsdcGauge));

        GaugeType1 orangePcsArbUsdcGauge = GaugeType1(
            address(
                new ERC1967Proxy(
                    address(gaugeImplementation),
                    abi.encodeWithSelector(
                        GaugeType1.initialize.selector, 0xf885390B75035e94ac72AeF3E0D0eD5ec3b85d37, gaugeController, syk
                    )
                )
            )
        );

        console.log(address(orangePcsArbUsdcGauge));

        GaugeInfo memory pcsWethUsdcGaugeInfo =
            GaugeInfo({gaugeType: 1, chainId: 42161, baseReward: 3250 ether, gaugeAddress: address(pcsWethUsdcGauge)});

        GaugeInfo memory pcsWbtcUsdcGaugeInfo =
            GaugeInfo({gaugeType: 1, chainId: 42161, baseReward: 3250 ether, gaugeAddress: address(pcsWbtcUsdcGauge)});

        GaugeInfo memory orangePcsWethUsdcGaugeInfo = GaugeInfo({
            gaugeType: 1,
            chainId: 42161,
            baseReward: 3250 ether,
            gaugeAddress: address(orangePcsWethUsdcGauge)
        });

        GaugeInfo memory orangePcsWbtcUsdcGaugeInfo = GaugeInfo({
            gaugeType: 1,
            chainId: 42161,
            baseReward: 3250 ether,
            gaugeAddress: address(orangePcsWbtcUsdcGauge)
        });

        GaugeInfo memory orangePcsArbUsdcGaugeInfo = GaugeInfo({
            gaugeType: 1,
            chainId: 42161,
            baseReward: 2000 ether,
            gaugeAddress: address(orangePcsArbUsdcGauge)
        });

        GaugeController gc = GaugeController(gaugeController);

        gc.setTotalRewardPerEpoch(50000 ether);

        bytes32 pcsWethUsdcGaugeId = gc.addGauge(pcsWethUsdcGaugeInfo);
        console.logBytes32(pcsWethUsdcGaugeId);

        bytes32 pcsWbtcUsdcGaugeId = gc.addGauge(pcsWbtcUsdcGaugeInfo);
        console.logBytes32(pcsWbtcUsdcGaugeId);

        bytes32 orangePcsWethUsdcGaugeId = gc.addGauge(orangePcsWethUsdcGaugeInfo);
        console.logBytes32(orangePcsWethUsdcGaugeId);

        bytes32 orangePcsWbtcUsdcGaugeId = gc.addGauge(orangePcsWbtcUsdcGaugeInfo);
        console.logBytes32(orangePcsWbtcUsdcGaugeId);

        bytes32 orangePcsArbUsdcGaugeId = gc.addGauge(orangePcsArbUsdcGaugeInfo);
        console.logBytes32(orangePcsArbUsdcGaugeId);

        vm.stopBroadcast();
    }
}
