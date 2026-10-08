// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.23;

import {Test, console2 as console} from "forge-std/Test.sol";

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {StakedSYK} from "../src/governance/StakedSYK.sol";

contract MockERC20 is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory name_, string memory symbol_, uint8 dec_) ERC20(name_, symbol_) {
        _dec = dec_;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Reward token that can revert or return false on transfer (paused / blacklisted).
contract PausableMockERC20 is ERC20 {
    enum Mode {
        Ok,
        Revert,
        ReturnFalse
    }

    Mode public mode;

    constructor() ERC20("Faulty", "FLTY") {}

    function setMode(Mode m) external {
        mode = m;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (mode == Mode.Revert) revert("paused");
        if (mode == Mode.ReturnFalse) return false;
        return super.transfer(to, amount);
    }
}

/// @notice Unit tests: mechanics, accounting, cooldown, admin gating.
contract StakedSYKUnitTest is Test {
    AccessManager am;
    StakedSYK st;
    MockERC20 syk;
    MockERC20 stockA; // 18 decimals (NVDA-like)
    MockERC20 usd6; // 6 decimals (USDG-like)

    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        syk = new MockERC20("Stryke", "SYK", 18);
        stockA = new MockERC20("NVIDIA Stock Token", "NVDA", 18);
        usd6 = new MockERC20("USDG", "USDG", 6);

        vm.startPrank(admin);
        am = new AccessManager(admin);
        st = new StakedSYK(address(syk), 7 days, address(am));
        st.addReward(address(syk), 7 days);
        st.addReward(address(stockA), 30 days);
        st.addReward(address(usd6), 10 days);
        vm.stopPrank();

        syk.mint(alice, 1_000_000 ether);
        syk.mint(bob, 1_000_000 ether);
        vm.prank(alice);
        syk.approve(address(st), type(uint256).max);
        vm.prank(bob);
        syk.approve(address(st), type(uint256).max);
    }

    function _notify(address token, uint256 amount) internal {
        MockERC20(token).mint(admin, amount);
        vm.startPrank(admin);
        MockERC20(token).approve(address(st), amount);
        st.notifyRewardAmount(token, amount);
        vm.stopPrank();
    }

    // ---------------- constructor / cooldown ----------------

    function test_constructor_rejectsCooldownAboveCap() public {
        vm.expectRevert(StakedSYK.StakedSYK_CooldownTooLong.selector);
        new StakedSYK(address(syk), 7 days + 1, address(am));
    }

    function test_setCooldown_capAndEffectOnNewRequestsOnly() public {
        vm.prank(admin);
        vm.expectRevert(StakedSYK.StakedSYK_CooldownTooLong.selector);
        st.setCooldown(8 days);

        vm.prank(alice);
        st.stake(100 ether);
        vm.prank(alice);
        st.initiateUnstake(40 ether); // 7d cooldown

        vm.prank(admin);
        st.setCooldown(3 days);
        vm.prank(alice);
        st.initiateUnstake(60 ether); // 3d cooldown

        StakedSYK.UnstakeRequest[] memory reqs = st.unstakeRequests(alice);
        assertEq(reqs[0].unlockAt, block.timestamp + 7 days, "old request must keep old cooldown");
        assertEq(reqs[1].unlockAt, block.timestamp + 3 days, "new request must use new cooldown");
    }

    // ---------------- stake / unstake / withdraw ----------------

    function test_stake_updatesBalances() public {
        vm.prank(alice);
        st.stake(100 ether);
        assertEq(st.balanceOf(alice), 100 ether);
        assertEq(st.totalSupply(), 100 ether);
        assertEq(syk.balanceOf(address(st)), 100 ether);

        vm.prank(alice);
        vm.expectRevert(StakedSYK.StakedSYK_AmountZero.selector);
        st.stake(0);
    }

    function test_withdraw_flow() public {
        vm.startPrank(alice);
        st.stake(100 ether);
        st.initiateUnstake(30 ether);
        skip(1 days);
        st.initiateUnstake(20 ether);

        assertEq(st.withdrawable(alice), 0);
        assertEq(st.withdraw(), 0, "nothing matured yet");

        skip(6 days); // request #1 matured (7d), #2 not (6d elapsed)
        assertEq(st.withdrawable(alice), 30 ether);
        uint256 balBefore = syk.balanceOf(alice);
        assertEq(st.withdraw(), 30 ether);
        assertEq(syk.balanceOf(alice) - balBefore, 30 ether);

        skip(1 days); // request #2 matured
        assertEq(st.withdraw(), 20 ether);
        assertEq(st.unstakeRequests(alice).length, 0);
        vm.stopPrank();

        assertEq(st.totalPendingUnstake(), 0);
        assertEq(st.balanceOf(alice), 50 ether);
    }

    function test_cancelUnstake_restakes() public {
        vm.startPrank(alice);
        st.stake(100 ether);
        st.initiateUnstake(100 ether);
        assertEq(st.totalSupply(), 0);

        st.cancelUnstake(0);
        assertEq(st.balanceOf(alice), 100 ether);
        assertEq(st.totalSupply(), 100 ether);
        assertEq(st.totalPendingUnstake(), 0);
        assertEq(st.unstakeRequests(alice).length, 0);

        vm.expectRevert(StakedSYK.StakedSYK_InvalidIndex.selector);
        st.cancelUnstake(0);
        vm.stopPrank();
    }

    function test_exit_initiatesFullBalanceAndClaims() public {
        _notify(address(syk), 700 ether);
        vm.prank(alice);
        st.stake(100 ether);
        skip(7 days);

        uint256 balBefore = syk.balanceOf(alice);
        vm.prank(alice);
        st.exit();

        assertEq(st.balanceOf(alice), 0);
        assertApproxEqRel(syk.balanceOf(alice) - balBefore, 700 ether, 1e15, "claim paid on exit");
        assertEq(st.unstakeRequests(alice)[0].amount, 100 ether);
    }

    // ---------------- rewards ----------------

    function test_rewards_multiToken_proRata() public {
        vm.prank(alice);
        st.stake(200 ether); // 2/3
        vm.prank(bob);
        st.stake(100 ether); // 1/3

        _notify(address(syk), 700 ether); // over 7d
        _notify(address(stockA), 30 ether); // over 30d
        _notify(address(usd6), 1_000e6); // over 10d

        skip(7 days);

        // SYK fully streamed; stock 7/30; usd6 7/10
        assertApproxEqRel(st.earned(address(syk), alice), uint256(1400 ether) / 3, 1e15);
        assertApproxEqRel(st.earned(address(stockA), alice), uint256(14 ether) / 3, 1e15);
        assertApproxEqRel(st.earned(address(usd6), alice), uint256(1400e6) / 3, 1e15);

        vm.prank(alice);
        st.claim();
        assertApproxEqRel(stockA.balanceOf(alice), uint256(14 ether) / 3, 1e15);
        assertApproxEqRel(usd6.balanceOf(alice), uint256(1400e6) / 3, 1e15);

        // bob gets half of alice
        assertApproxEqRel(st.earned(address(syk), bob), uint256(700 ether) / 3, 1e15);
    }

    function test_rewards_pendingUnstakeEarnsNothing() public {
        vm.prank(alice);
        st.stake(100 ether);
        vm.prank(bob);
        st.stake(100 ether);
        _notify(address(syk), 700 ether);

        skip(3.5 days);
        vm.prank(alice);
        st.initiateUnstake(100 ether); // stops earning at halfway

        skip(3.5 days);
        uint256 aliceEarned = st.earned(address(syk), alice);
        uint256 bobEarned = st.earned(address(syk), bob);

        assertApproxEqRel(aliceEarned, 175 ether, 1e15, "alice: half period at half share");
        assertApproxEqRel(bobEarned, 525 ether, 1e15, "bob: half at half share + half alone");
    }

    function test_rewards_lateStakerGetsNothingRetroactively() public {
        vm.prank(alice);
        st.stake(100 ether);
        _notify(address(syk), 700 ether);
        skip(7 days);

        vm.prank(bob);
        st.stake(100 ether); // period already over
        skip(1 days);
        assertEq(st.earned(address(syk), bob), 0);
        assertApproxEqRel(st.earned(address(syk), alice), 700 ether, 1e15);
    }

    function test_notify_rolloverMidPeriod() public {
        vm.prank(alice);
        st.stake(100 ether);
        _notify(address(syk), 700 ether);
        skip(3.5 days); // 350 streamed, 350 remaining

        _notify(address(syk), 350 ether); // new rate = (350+350)/7d
        skip(7 days);
        assertApproxEqRel(st.earned(address(syk), alice), 1050 ether, 1e15);
    }

    function test_rewardPerToken_zeroTotalSupplyDoesNotRevert() public {
        _notify(address(syk), 700 ether);
        skip(1 days);
        assertEq(st.rewardPerToken(address(syk)), 0);
        // stake after idle streaming — the idle rewards are simply undistributed
        vm.prank(alice);
        st.stake(100 ether);
        skip(6 days);
        assertApproxEqRel(st.earned(address(syk), alice), 600 ether, 1e15);
    }

    // ---------------- admin & config ----------------

    function test_restricted_revertForNonAdmin() public {
        bytes memory err = abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, alice);
        vm.startPrank(alice);
        vm.expectRevert(err);
        st.addReward(address(0xDEAD), 1 days);
        vm.expectRevert(err);
        st.setRewardsDuration(address(syk), 1 days);
        vm.expectRevert(err);
        st.notifyRewardAmount(address(syk), 1 ether);
        vm.expectRevert(err);
        st.setCooldown(1 days);
        vm.expectRevert(err);
        st.recoverERC20(address(0xDEAD), 1);
        vm.stopPrank();
    }

    function test_addReward_validation() public {
        vm.startPrank(admin);
        vm.expectRevert(StakedSYK.StakedSYK_RewardTokenExists.selector);
        st.addReward(address(syk), 1 days);
        vm.expectRevert(StakedSYK.StakedSYK_DurationZero.selector);
        st.addReward(address(0xDEAD), 0);

        for (uint160 i; i < 7; ++i) {
            st.addReward(address(uint160(0x1000) + i), 1 days);
        }
        assertEq(st.rewardTokensLength(), 10);
        vm.expectRevert(StakedSYK.StakedSYK_TooManyRewardTokens.selector);
        st.addReward(address(0xBEEF), 1 days);
        vm.stopPrank();
    }

    function test_setRewardsDuration_onlyWhenIdle() public {
        _notify(address(syk), 700 ether);
        vm.prank(admin);
        vm.expectRevert(StakedSYK.StakedSYK_RewardPeriodActive.selector);
        st.setRewardsDuration(address(syk), 14 days);

        skip(7 days + 1);
        vm.prank(admin);
        st.setRewardsDuration(address(syk), 14 days);
        (uint256 duration,,,,) = st.rewardData(address(syk));
        assertEq(duration, 14 days);

        vm.prank(admin);
        vm.expectRevert(StakedSYK.StakedSYK_RewardTokenUnknown.selector);
        st.setRewardsDuration(address(0xDEAD), 1 days);
    }

    function test_notify_unknownTokenAndZeroRateRevert() public {
        vm.startPrank(admin);
        vm.expectRevert(StakedSYK.StakedSYK_RewardTokenUnknown.selector);
        st.notifyRewardAmount(address(0xDEAD), 1 ether);

        MockERC20(address(syk)).mint(admin, 1);
        syk.approve(address(st), 1);
        vm.expectRevert(StakedSYK.StakedSYK_RewardRateZero.selector);
        st.notifyRewardAmount(address(syk), 1); // 1 wei over 7 days -> rate 0
        vm.stopPrank();
    }

    function test_recoverERC20_onlySurplus() public {
        vm.prank(alice);
        st.stake(100 ether);
        _notify(address(stockA), 30 ether);

        // nothing beyond staked principal / reserved rewards
        vm.startPrank(admin);
        vm.expectRevert(StakedSYK.StakedSYK_InsufficientSurplus.selector);
        st.recoverERC20(address(syk), 1);
        uint256 stockSurplus = st.surplus(address(stockA)); // integer-rate dust only
        vm.expectRevert(StakedSYK.StakedSYK_InsufficientSurplus.selector);
        st.recoverERC20(address(stockA), stockSurplus + 1);
        vm.stopPrank();

        // direct transfers are surplus and recoverable, principal stays
        syk.mint(address(st), 5 ether);
        vm.prank(admin);
        st.recoverERC20(address(syk), 5 ether);
        assertEq(syk.balanceOf(admin), 5 ether);
        assertEq(syk.balanceOf(address(st)), 100 ether);

        MockERC20 stray = new MockERC20("Stray", "STRAY", 18);
        stray.mint(address(st), 5 ether);
        vm.prank(admin);
        st.recoverERC20(address(stray), 5 ether);
        assertEq(stray.balanceOf(admin), 5 ether);
    }

    function test_unallocated_idleStreamIsRestreamed() public {
        _notify(address(syk), 700 ether); // nobody staked for the first half
        skip(3.5 days);
        assertApproxEqAbs(st.surplus(address(syk)), 350 ether, 1e6, "idle half is surplus");

        vm.prank(alice);
        st.stake(100 ether);
        skip(3.5 days + 1);
        assertApproxEqRel(st.earned(address(syk), alice), 350 ether, 1e12);

        // stream expired; re-stream the unallocated half without new funding
        vm.prank(admin);
        st.notifyRewardAmount(address(syk), 0);
        skip(7 days);
        assertApproxEqRel(st.earned(address(syk), alice), 700 ether, 1e12, "all 700 reaches stakers");

        vm.prank(alice);
        st.claim();
        assertApproxEqRel(syk.balanceOf(alice), 1_000_000 ether - 100 ether + 700 ether, 1e12);
        assertLe(st.surplus(address(syk)), 1e6, "only dust left");
    }

    function test_unallocated_rolledIntoNextFundedStream() public {
        _notify(address(stockA), 30 ether);
        skip(30 days); // whole stream idle

        vm.prank(alice);
        st.stake(100 ether);
        _notify(address(stockA), 30 ether); // streams new 30 + idle 30
        skip(30 days);
        assertApproxEqRel(st.earned(address(stockA), alice), 60 ether, 1e12);
    }

    function test_reservedNeverExceedsBalance() public {
        vm.prank(alice);
        st.stake(100 ether);
        _notify(address(stockA), 30 ether);
        skip(10 days);
        vm.prank(alice);
        st.initiateUnstake(100 ether); // supply 0 -> rest released
        skip(10 days);
        vm.prank(bob);
        st.stake(50 ether);
        _notify(address(stockA), 15 ether);
        skip(40 days);
        vm.prank(alice);
        st.claim();
        vm.prank(bob);
        st.claim();
        assertLe(st.rewardReserved(address(stockA)), stockA.balanceOf(address(st)));
        // everything funded (45) is either paid out or still in the contract
        assertEq(stockA.balanceOf(alice) + stockA.balanceOf(bob) + stockA.balanceOf(address(st)), 45 ether);
    }

    function test_claim_faultyRewardTokenDoesNotBlockOthers() public {
        PausableMockERC20 faulty = new PausableMockERC20();
        vm.prank(admin);
        st.addReward(address(faulty), 7 days);

        vm.prank(alice);
        st.stake(100 ether);
        _notify(address(syk), 700 ether);
        faulty.mint(admin, 70 ether);
        vm.startPrank(admin);
        faulty.approve(address(st), 70 ether);
        st.notifyRewardAmount(address(faulty), 70 ether);
        vm.stopPrank();
        skip(7 days);

        faulty.setMode(PausableMockERC20.Mode.Revert);
        uint256 sykBefore = syk.balanceOf(alice);
        vm.expectEmit(true, true, false, false, address(st));
        emit StakedSYK.RewardClaimFailed(alice, address(faulty), 0);
        vm.prank(alice);
        st.claim();
        assertApproxEqRel(syk.balanceOf(alice) - sykBefore, 700 ether, 1e12, "SYK still paid");
        assertApproxEqRel(st.rewards(address(faulty), alice), 70 ether, 1e12, "faulty reward kept owed");

        // explicit per-token claims: healthy works, faulty reverts
        address[] memory only = new address[](1);
        only[0] = address(faulty);
        vm.prank(alice);
        vm.expectRevert();
        st.claimRewards(only);

        faulty.setMode(PausableMockERC20.Mode.ReturnFalse);
        vm.prank(alice);
        st.claim();
        assertEq(faulty.balanceOf(alice), 0, "false return treated as failure");

        faulty.setMode(PausableMockERC20.Mode.Ok);
        vm.prank(alice);
        st.claimRewards(only);
        assertApproxEqRel(faulty.balanceOf(alice), 70 ether, 1e12, "paid once token recovers");
        assertEq(st.rewards(address(faulty), alice), 0);
    }

    function test_claimRewards_unknownTokenReverts() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(0xDEAD);
        vm.prank(alice);
        vm.expectRevert(StakedSYK.StakedSYK_RewardTokenUnknown.selector);
        st.claimRewards(tokens);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_accountingSolventAcrossRandomActions(uint256 seed) public {
        address[2] memory users = [alice, bob];
        for (uint256 step; step < 24; ++step) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            address user = users[r % 2];
            uint256 action = (r >> 8) % 6;
            uint256 amt = ((r >> 16) % 1_000 ether) + 1;

            vm.startPrank(user);
            if (action == 0) {
                st.stake(amt);
            } else if (action == 1 && st.balanceOf(user) > 0) {
                st.initiateUnstake(amt % st.balanceOf(user) + 1);
            } else if (action == 2) {
                st.withdraw();
            } else if (action == 3) {
                st.claim();
            }
            vm.stopPrank();
            if (action == 4) _notify(address(stockA), amt);
            skip((r >> 32) % 5 days);

            assertLe(st.rewardReserved(address(stockA)), stockA.balanceOf(address(st)), "stock insolvent");
            assertLe(
                st.rewardReserved(address(syk)) + st.totalSupply() + st.totalPendingUnstake(),
                syk.balanceOf(address(st)),
                "syk insolvent"
            );
        }

        skip(31 days);
        for (uint256 i; i < 2; ++i) {
            vm.startPrank(users[i]);
            st.claim();
            if (st.balanceOf(users[i]) > 0) st.initiateUnstake(st.balanceOf(users[i]));
            skip(7 days);
            st.withdraw();
            vm.stopPrank();
        }
        assertEq(st.totalSupply() + st.totalPendingUnstake(), 0);
        assertEq(st.surplus(address(stockA)), stockA.balanceOf(address(st)) - st.rewardReserved(address(stockA)));
    }

    /// @dev users' principal is never claimable as rewards even if notify over-commits
    function test_principalIsolation_cannotStreamStakedSyk() public {
        vm.prank(alice);
        st.stake(100 ether);
        _notify(address(syk), 700 ether);
        skip(7 days);

        vm.prank(alice);
        st.claim();
        // contract still holds alice's 100 principal (+ rounding dust from integer rate)
        assertGe(syk.balanceOf(address(st)), 100 ether);

        vm.startPrank(alice);
        st.initiateUnstake(100 ether);
        skip(7 days);
        assertEq(st.withdraw(), 100 ether);
        vm.stopPrank();
    }
}

/// @notice Fork tests on Robinhood Chain: real SYK, real AccessManager, real tokenized
///         stocks (NVDA, GME) dealt from live DEX pools.
/// Run: forge test --match-contract StakedSYKRobinhoodForkTest -vv
contract StakedSYKRobinhoodForkTest is Test {
    string constant RH_RPC = "https://rpc.mainnet.chain.robinhood.com";
    uint256 constant PIN_BLOCK = 69174766;

    // live Robinhood contracts (deployed in this project)
    address constant SYK = 0x97C065EEd0309F182777BfFa41A9C0027c190DF1;
    address constant ACCESS_MANAGER = 0x99fF939Ef399f5569d57868d43118e6586F574d9;
    address constant ADMIN = 0xC4290eA730a461075141e6d5DF1e980E72F1BD1B; // AccessManager admin
    address constant BRIDGE_CONTROLLER = 0x0189D0E3965FCa86bCA5659eBDbFe8dCc9aa36B0;
    address constant LZ_ADAPTER = 0xa51175F9076B2535003AC146921485083aB3A63c; // may mint via controller

    // live tokenized stocks + their deepest pools (token custodians to deal from)
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant NVDA_POOL = 0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3;
    address constant GME = 0x1b0E319c6A659F002271B69dB8A7df2F911c153E;
    address constant GME_POOL = 0xE2b46c905E12Ab8E2f864e4821a4325884C1B126;

    StakedSYK st;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        vm.selectFork(vm.createFork(RH_RPC, PIN_BLOCK));
        assertEq(block.chainid, 4663);

        st = new StakedSYK(SYK, 7 days, ACCESS_MANAGER);

        // reward config by the live AccessManager admin
        vm.startPrank(ADMIN);
        st.addReward(SYK, 7 days);
        st.addReward(NVDA, 30 days);
        st.addReward(GME, 30 days);
        vm.stopPrank();

        // deal SYK by minting through the live bridge controller (as the LZ adapter would)
        vm.startPrank(LZ_ADAPTER);
        (bool ok,) = BRIDGE_CONTROLLER.call(abi.encodeWithSignature("mint(address,uint256)", alice, 200_000 ether));
        require(ok, "mint alice");
        (ok,) = BRIDGE_CONTROLLER.call(abi.encodeWithSignature("mint(address,uint256)", bob, 100_000 ether));
        require(ok, "mint bob");
        (ok,) = BRIDGE_CONTROLLER.call(abi.encodeWithSignature("mint(address,uint256)", ADMIN, 10_000 ether));
        require(ok, "mint admin");
        vm.stopPrank();

        // deal real stock tokens from live pools
        vm.prank(NVDA_POOL);
        IERC20(NVDA).transfer(ADMIN, 100 ether);
        vm.prank(GME_POOL);
        IERC20(GME).transfer(ADMIN, 50 ether);

        vm.prank(alice);
        IERC20(SYK).approve(address(st), type(uint256).max);
        vm.prank(bob);
        IERC20(SYK).approve(address(st), type(uint256).max);
    }

    function _notifyAll() internal {
        vm.startPrank(ADMIN);
        IERC20(SYK).approve(address(st), 7_000 ether);
        st.notifyRewardAmount(SYK, 7_000 ether);
        IERC20(NVDA).approve(address(st), 90 ether);
        st.notifyRewardAmount(NVDA, 90 ether);
        IERC20(GME).approve(address(st), 30 ether);
        st.notifyRewardAmount(GME, 30 ether);
        vm.stopPrank();
    }

    function test_fork_stockTokensAreFreelyTransferable() public {
        // sanity for the RWA question: plain transfers to fresh EOAs and contracts succeed
        vm.prank(NVDA_POOL);
        IERC20(NVDA).transfer(alice, 1 ether);
        vm.prank(alice);
        IERC20(NVDA).transfer(address(st), 0.5 ether);
        assertEq(IERC20(NVDA).balanceOf(address(st)), 0.5 ether);

        vm.prank(GME_POOL);
        IERC20(GME).transfer(alice, 1 ether);
        vm.prank(alice);
        IERC20(GME).transfer(bob, 1 ether);
        assertEq(IERC20(GME).balanceOf(bob), 1 ether);
    }

    function test_fork_fullLifecycle_stakeEarnStocksWithdraw() public {
        vm.prank(alice);
        st.stake(200_000 ether); // 2/3
        vm.prank(bob);
        st.stake(100_000 ether); // 1/3

        _notifyAll();
        skip(7 days);

        // SYK reward fully streamed; NVDA/GME at 7/30 of period
        assertApproxEqRel(st.earned(SYK, alice), uint256(14_000 ether) / 3, 1e15);
        assertApproxEqRel(st.earned(NVDA, alice), 14 ether, 1e15); // 90 * 7/30 * 2/3
        assertApproxEqRel(st.earned(GME, alice), uint256(14 ether) / 3, 1e15); // 30 * 7/30 * 2/3

        vm.prank(alice);
        st.claim();
        assertApproxEqRel(IERC20(NVDA).balanceOf(alice), 14 ether, 1e15, "real NVDA paid out");
        assertApproxEqRel(IERC20(GME).balanceOf(alice), uint256(14 ether) / 3, 1e15, "real GME paid out");

        // cooldown flow with real SYK
        uint256 sykBefore = IERC20(SYK).balanceOf(alice);
        vm.startPrank(alice);
        st.initiateUnstake(200_000 ether);
        assertEq(st.withdraw(), 0, "cooldown must gate withdrawal");
        skip(7 days);
        assertEq(st.withdraw(), 200_000 ether);
        vm.stopPrank();
        assertEq(IERC20(SYK).balanceOf(alice) - sykBefore, 200_000 ether);

        // bob keeps earning NVDA/GME after alice leaves
        uint256 bobNvdaBefore = st.earned(NVDA, bob);
        skip(7 days);
        assertGt(st.earned(NVDA, bob), bobNvdaBefore);
    }

    function test_fork_cooldownReconfiguration() public {
        vm.prank(ADMIN);
        st.setCooldown(3 days);

        vm.startPrank(alice);
        st.stake(1_000 ether);
        st.initiateUnstake(1_000 ether);
        skip(3 days - 1);
        assertEq(st.withdraw(), 0);
        skip(1);
        assertEq(st.withdraw(), 1_000 ether);
        vm.stopPrank();
    }

    function test_fork_nonAdminCannotConfigure() public {
        bytes memory err = abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, alice);
        vm.startPrank(alice);
        vm.expectRevert(err);
        st.setCooldown(1 days);
        vm.expectRevert(err);
        st.addReward(address(0xDEAD), 1 days);
        vm.expectRevert(err);
        st.notifyRewardAmount(SYK, 1 ether);
        vm.stopPrank();
    }

    function test_fork_treasurySafeCanAlsoAdministrate() public {
        // the treasury Safe was granted co-admin on the RH AccessManager (step 11)
        address treasurySafe = 0x2fa6F21eCfE274f594F470c376f5BDd061E08a37;
        (bool isAdmin,) = AccessManager(ACCESS_MANAGER).hasRole(0, treasurySafe);
        vm.skip(!isAdmin); // skip gracefully if step 11 hasn't been executed yet

        vm.prank(treasurySafe);
        st.setCooldown(5 days);
        assertEq(st.cooldown(), 5 days);
    }
}
