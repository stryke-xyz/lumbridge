// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.23;

import {Test, console} from "forge-std/Test.sol";

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {StrykeTokenRoot} from "../src/token/StrykeTokenRoot.sol";
import {Migrator} from "../src/migration/Migrator.sol";
import {MockToken} from "../src/mocks/MockToken.sol";

contract MigratorTest is Test {
    StrykeTokenRoot public syk;

    MockToken public dpx;
    MockToken public rdpx;

    Migrator public migrator;

    AccessManager public accessManager;

    Account public john;

    function setUp() public {
        vm.chainId(42161);
        john = makeAccount("john");
        deal(john.addr, 100 ether);

        StrykeTokenRoot sykImplementation = new StrykeTokenRoot();

        accessManager = new AccessManager(address(this));

        dpx = new MockToken(address(this));
        rdpx = new MockToken(address(this));

        syk = StrykeTokenRoot(
            address(
                new ERC1967Proxy(
                    address(sykImplementation),
                    abi.encodeWithSelector(StrykeTokenRoot.initialize.selector, address(accessManager))
                )
            )
        );

        migrator = new Migrator(address(dpx), address(rdpx), address(syk), address(accessManager));

        uint64 MINTER_SYK = 1;

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = bytes4(keccak256("mint(address,uint256)"));

        // Set role for migrator
        accessManager.grantRole(MINTER_SYK, address(migrator), 0);
        accessManager.grantRole(MINTER_SYK, address(this), 0);
        accessManager.setTargetFunctionRole(address(syk), selectors, MINTER_SYK);
    }

    function test_migrate() public {
        // Expect revert because incorrect token passed
        vm.expectRevert(Migrator.InvalidToken.selector);
        vm.prank(john.addr);
        migrator.migrate(address(0), 1 ether);

        // Expect revert because john has insufficient DPX
        vm.expectRevert();
        vm.prank(john.addr);
        migrator.migrate(address(dpx), 1 ether);

        // Mint DPX for john
        dpx.mint(john.addr, 1 ether);

        vm.startPrank(john.addr);
        dpx.approve(address(migrator), 1 ether);
        migrator.migrate(address(dpx), 1 ether);
        vm.stopPrank();

        assertEq(dpx.balanceOf(john.addr), 0);
        // Conversion rate for DPX to SYK is 1:100
        assertEq(syk.balanceOf(john.addr), 100 ether);

        // Burn johns SYK for the next assertion
        syk.burn(john.addr, 100 ether);

        // Expect revert because john has insufficient rDPX
        vm.expectRevert();
        vm.prank(john.addr);
        migrator.migrate(address(rdpx), 1 ether);

        // Mint rDPX for john
        rdpx.mint(john.addr, 1 ether);

        vm.startPrank(john.addr);
        rdpx.approve(address(migrator), 1 ether);
        migrator.migrate(address(rdpx), 1 ether);
        vm.stopPrank();

        assertEq(rdpx.balanceOf(john.addr), 0);
        // Conversion rate for rDPX to SYK is 1:13.3333
        assertEq(syk.balanceOf(john.addr), 13.3333 ether);

        syk.burn(john.addr, 13.3333 ether);

        // Try to migrate after the migration period is over
        skip((migrator.migrationPeriodEnd() - block.timestamp) + 1);
        dpx.mint(john.addr, 1 ether);

        vm.startPrank(john.addr);
        dpx.approve(address(migrator), 1 ether);
        vm.expectRevert(Migrator.MigrationPeriodOver.selector);
        migrator.migrate(address(dpx), 1 ether);
        vm.stopPrank();
    }

    function test_extendMigrationPeriod() public {
        vm.expectRevert(Migrator.MigrationPeriodNotOver.selector);
        migrator.extendMigrationPeriod(1);

        skip((migrator.migrationPeriodEnd() - block.timestamp) + 1);

        migrator.extendMigrationPeriod(1);
        assertEq(migrator.migrationPeriodEnd(), block.timestamp + 1);
    }

    function test_recoverERC20() public {
        dpx.mint(address(migrator), 100 ether);
        rdpx.mint(address(migrator), 1000 ether);

        assertEq(syk.balanceOf(address(this)), 0);

        address[] memory tokens = new address[](2);
        tokens[0] = address(dpx);
        tokens[1] = address(rdpx);
        migrator.recoverERC20(tokens);

        assertEq(dpx.balanceOf(address(this)), 100 ether);
        assertEq(rdpx.balanceOf(address(this)), 1000 ether);
    }
}
