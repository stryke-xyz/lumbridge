// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test, console} from "forge-std/Test.sol";

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {XStrykeToken} from "../src/governance/XStrykeToken.sol";
import {StrykeTokenRoot} from "../src/token/StrykeTokenRoot.sol";
import {IXStrykeToken, VestData, VestStatus, RedeemSettings} from "../src/interfaces/IXStrykeToken.sol";

contract XStrykeTokenTest is Test {
    StrykeTokenRoot public syk;

    XStrykeToken public xSyk;

    AccessManager public accessManager;

    Account public john;
    Account public doe;

    function setUp() public {
        vm.chainId(42161);
        john = makeAccount("john");
        deal(john.addr, 100 ether);

        doe = makeAccount("doe");
        deal(doe.addr, 100 ether);

        StrykeTokenRoot sykImplementation = new StrykeTokenRoot();
        XStrykeToken xSykImplementation = new XStrykeToken();

        accessManager = new AccessManager(address(this));

        syk = StrykeTokenRoot(
            address(
                new ERC1967Proxy(
                    address(sykImplementation),
                    abi.encodeWithSelector(StrykeTokenRoot.initialize.selector, address(accessManager))
                )
            )
        );

        xSyk = XStrykeToken(
            address(
                new ERC1967Proxy(
                    address(xSykImplementation),
                    abi.encodeWithSelector(XStrykeToken.initialize.selector, address(syk), address(accessManager))
                )
            )
        );
    }

    function test_updateExcessReceiver() public {
        Account memory excessReceiver = makeAccount("excessReceiver");

        xSyk.updateExcessReceiver(excessReceiver.addr);

        assertEq(xSyk.excessReceiver(), excessReceiver.addr);
    }

    function test_updateRedeemSettings() public {
        // Check when minRatio is greater than maxRatio
        RedeemSettings memory _redeemSettings =
            RedeemSettings({minRatio: 100, maxRatio: 90, minDuration: 7 days, maxDuration: 180 days});

        vm.expectRevert(IXStrykeToken.XStrykeToken_WrongRatioValues.selector);
        xSyk.updateRedeemSettings(_redeemSettings);

        // Check when maxRatio is greater than the allowed MAX_RATIO
        _redeemSettings = RedeemSettings({minRatio: 10, maxRatio: 101, minDuration: 7 days, maxDuration: 180 days});

        vm.expectRevert(IXStrykeToken.XStrykeToken_WrongRatioValues.selector);
        xSyk.updateRedeemSettings(_redeemSettings);

        // Check when minDuration is greater than maxDuration
        _redeemSettings = RedeemSettings({minRatio: 50, maxRatio: 100, minDuration: 7 days, maxDuration: 6 days});

        vm.expectRevert(IXStrykeToken.XStrykeToken_WrongDurationValues.selector);
        xSyk.updateRedeemSettings(_redeemSettings);

        // Check if redeemSettings were set correctly
        _redeemSettings = RedeemSettings({minRatio: 10, maxRatio: 90, minDuration: 7 days, maxDuration: 90 days});

        xSyk.updateRedeemSettings(_redeemSettings);

        (uint256 minRatio, uint256 maxRatio, uint256 minDuration, uint256 maxDuration) = xSyk.redeemSettings();

        assertEq(minRatio, _redeemSettings.minRatio);
        assertEq(maxRatio, _redeemSettings.maxRatio);
        assertEq(minDuration, _redeemSettings.minDuration);
        assertEq(maxDuration, _redeemSettings.maxDuration);
    }

    function test_convert() public {
        // Fail if john has no SYK to convert
        vm.startPrank(john.addr, john.addr);
        syk.approve(address(xSyk), 1 ether);
        vm.expectRevert();
        xSyk.convert(1 ether, john.addr);
        vm.stopPrank();

        // Mint some SYK tokens to john
        syk.mint(john.addr, 1 ether);

        // Convert SYK tokens to xSYK tokens
        vm.startPrank(john.addr, john.addr);
        syk.approve(address(xSyk), 1 ether);
        xSyk.convert(1 ether, john.addr);
        vm.stopPrank();

        assertEq(xSyk.balanceOf(john.addr), 1 ether, "Incorrect xSYK token balance after conversion");
        assertEq(syk.balanceOf(john.addr), 0, "Incorrect SYK token balance after conversion");
    }

    function test_vestBasic() public {
        // Amount 0
        vm.startPrank(john.addr);
        vm.expectRevert(IXStrykeToken.XStrykeToken_AmountZero.selector);
        xSyk.vest(0, 7 days);
        vm.stopPrank();

        // Duration lower than minDuration
        vm.startPrank(john.addr);
        vm.expectRevert(IXStrykeToken.XStrykeToken_DurationTooLow.selector);
        xSyk.vest(1 ether, 6 days);
        vm.stopPrank();

        // Try to vest without any xSYK
        vm.startPrank(john.addr);
        vm.expectRevert();
        xSyk.vest(1 ether, 7 days);
        vm.stopPrank();

        syk.mint(john.addr, 1 ether);

        vm.startPrank(john.addr, john.addr);

        syk.approve(address(xSyk), 1 ether);
        xSyk.convert(1 ether, john.addr);
        xSyk.vest(1 ether, 7 days);

        (address account, uint256 sykAmount, uint256 xSykAmount, uint256 maturity,) = xSyk.vests(0);

        assertEq(account, john.addr);
        // Since its minDuration user gets back only 50%
        assertEq(sykAmount, 0.5 ether);
        assertEq(xSykAmount, 1 ether);
        assertEq(maturity, block.timestamp + 7 days);

        vm.stopPrank();
    }

    function test_vestMoreCases() public {
        address account;
        uint256 sykAmount;
        uint256 xSykAmount;
        uint256 maturity;

        syk.mint(john.addr, 1 ether);

        vm.startPrank(john.addr, john.addr);

        syk.approve(address(xSyk), 1 ether);
        xSyk.convert(1 ether, john.addr);
        xSyk.vest(1 ether, 179 days);

        (account, sykAmount, xSykAmount, maturity,) = xSyk.vests(0);

        assertEq(account, john.addr);
        assertEq(sykAmount, 0.99 ether);
        assertEq(xSykAmount, 1 ether);
        assertEq(maturity, block.timestamp + 179 days);

        vm.stopPrank();

        syk.mint(john.addr, 1 ether);

        vm.startPrank(john.addr, john.addr);

        syk.approve(address(xSyk), 1 ether);
        xSyk.convert(1 ether, john.addr);
        xSyk.vest(1 ether, 60 days);

        (account, sykAmount, xSykAmount, maturity,) = xSyk.vests(1);

        assertEq(account, john.addr);
        assertEq(sykAmount, 0.65 ether);
        assertEq(xSykAmount, 1 ether);
        assertEq(maturity, block.timestamp + 60 days);

        vm.stopPrank();

        syk.mint(john.addr, 1 ether);

        vm.startPrank(john.addr, john.addr);

        syk.approve(address(xSyk), 1 ether);
        xSyk.convert(1 ether, john.addr);
        xSyk.vest(1 ether, 180 days);

        (account, sykAmount, xSykAmount, maturity,) = xSyk.vests(2);

        assertEq(account, john.addr);
        assertEq(sykAmount, 1 ether);
        assertEq(xSykAmount, 1 ether);
        assertEq(maturity, block.timestamp + 180 days);

        vm.stopPrank();

        // Test case where duration is set to 0 (this is used for instant redemption of SYK to xSYK)
        xSyk.updateRedeemSettings(RedeemSettings({minDuration: 0, maxDuration: 1, minRatio: 100, maxRatio: 100}));
        syk.mint(john.addr, 1 ether);
        vm.startPrank(john.addr, john.addr);

        syk.approve(address(xSyk), 1 ether);
        xSyk.convert(1 ether, john.addr);
        xSyk.vest(1 ether, 0);

        assertEq(syk.balanceOf(john.addr), 1 ether);

        vm.stopPrank();
    }

    function test_redeemAndCancelVest() public {
        syk.mint(john.addr, 1 ether);

        vm.startPrank(john.addr, john.addr);

        syk.approve(address(xSyk), 1 ether);
        xSyk.convert(1 ether, john.addr);
        xSyk.vest(1 ether, 7 days);

        vm.expectRevert(IXStrykeToken.XStrykeToken_VestingHasNotMatured.selector);
        xSyk.redeem(0);

        skip(7 days);

        // Cancel vesting and try to redeem
        xSyk.cancelVest(0);
        // User gets back xSYK after cancelling
        assertEq(xSyk.balanceOf(john.addr), 1 ether);
        assertEq(xSyk.balanceOf(address(xSyk)), 0);
        vm.expectRevert(IXStrykeToken.XStrykeToken_VestingNotActive.selector);
        xSyk.redeem(0);

        xSyk.vest(1 ether, 7 days);
        skip(7 days);
        xSyk.redeem(1);
        uint256 excess = 0.5 ether;
        assertEq(syk.balanceOf(address(this)), excess);
        assertEq(syk.balanceOf(john.addr), 0.5 ether);

        vm.expectRevert(IXStrykeToken.XStrykeToken_VestingNotActive.selector);
        xSyk.cancelVest(1);

        vm.stopPrank();
    }
}
