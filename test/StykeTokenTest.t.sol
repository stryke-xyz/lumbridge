// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.23;

import {Test, console} from "forge-std/Test.sol";

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {StrykeTokenRoot} from "../src/token/StrykeTokenRoot.sol";

contract StykeTokenTest is Test {
    StrykeTokenRoot public syk;

    AccessManager public accessManager;

    Account public john;

    uint256 public inflationPerYear = 3_000_000 ether;

    function setUp() public {
        vm.chainId(42161);
        john = makeAccount("john");
        deal(john.addr, 100 ether);

        StrykeTokenRoot sykImplementation = new StrykeTokenRoot();

        accessManager = new AccessManager(address(this));

        syk = StrykeTokenRoot(
            address(
                new ERC1967Proxy(
                    address(sykImplementation),
                    abi.encodeWithSelector(StrykeTokenRoot.initialize.selector, address(accessManager))
                )
            )
        );
    }

    function test_setInflationPerYear() public {
        // emissionRatePerSecond = 3m / seconds in a year
        uint256 emissionRatePerSecond = 95129375951293759;
        // Unauthorized addresses should not be able to set the inflation
        vm.prank(john.addr);
        vm.expectRevert();
        syk.setInflationPerYear(inflationPerYear);

        syk.setInflationPerYear(inflationPerYear);
        assertEq(syk.inflationPerYear(), inflationPerYear, "Inflation per year incorrectly set");
        assertEq(syk.emissionRatePerSecond(), emissionRatePerSecond, "Emission rate per second incorrectly set");
    }

    function test_stryke() public {
        syk.setInflationPerYear(inflationPerYear);

        // Skip 7 days in time to check if correct amount of tokens are being emitted for 7 days
        skip(7 days);

        uint256 emissionRatePerSecond = syk.emissionRatePerSecond();

        uint256 totalEmissionsFor7Days = emissionRatePerSecond * 7 days;

        vm.expectRevert();
        syk.stryke(totalEmissionsFor7Days + 1);

        syk.stryke(totalEmissionsFor7Days);
        assertEq(syk.balanceOf(address(this)), totalEmissionsFor7Days, "Incorrect balanceOf");
    }

    function testFail_stryke() public {
        vm.prank(john.addr);
        syk.stryke(1 ether);
    }
}
