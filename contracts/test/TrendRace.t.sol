// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TrendRace} from "../src/TrendRace.sol";
import {MockV3Pool} from "../src/mocks/MockV3Pool.sol";
import {MockAgentID} from "../src/mocks/MockAgentID.sol";
import {MockToken} from "../src/mocks/MockToken.sol";

contract RevertingRegistry {
    function ownerOf(uint256) external pure returns (address) {
        revert("down");
    }
}

contract ShortReturnRegistry {
    fallback() external {
        assembly {
            mstore(0, 0x1234)
            return(0, 4)
        }
    }
}

contract GarbageRegistry {
    // returns a word with dirty upper bits whose low 160 bits equal the caller's address
    function ownerOf(uint256) external view returns (uint256) {
        return (uint256(1) << 200) | uint256(uint160(tx.origin));
    }
}

contract GasGuzzlerRegistry {
    function ownerOf(uint256) external view returns (address) {
        while (gasleft() > 100) {}
        return tx.origin;
    }
}

contract Reenterer {
    TrendRace public tr;
    uint256 public raceId;
    uint256 public otherRace;
    uint8 public mode; // 1 = reenter claim, 2 = reenter refund, 3 = reenter refund(otherRace)

    constructor(TrendRace t) {
        tr = t;
    }

    function enter(uint256 r, uint8 lane) external payable {
        tr.enter{value: msg.value}(r, lane);
    }

    function setMode(uint8 m, uint256 r, uint256 o) external {
        mode = m;
        raceId = r;
        otherRace = o;
    }

    function doClaim() external {
        tr.claim(raceId);
    }

    function doRefund() external {
        tr.refund(raceId);
    }

    receive() external payable {
        if (mode == 1) tr.claim(raceId);
        else if (mode == 2) tr.refund(raceId);
        else if (mode == 3) tr.refund(otherRace);
    }
}

contract TrendRaceTest is Test {
    TrendRace tr;
    MockAgentID agent;
    address USDT;
    address WBNB;
    address BTC;
    address ETH;
    address CAKE;
    MockV3Pool pBNB; // WBNB/USDT
    MockV3Pool pBTC; // BTC/USDT
    MockV3Pool pETH; // ETH/WBNB
    MockV3Pool pCAKE; // CAKE/WBNB

    address owner = address(0x9135);
    address op = address(0x615C);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA401);
    address dave = address(0xDA7E);
    address rando = address(0x7A2D0);

    uint256 constant D = 1 days;
    uint256 constant W = 30 minutes;
    uint256 constant G = 30 minutes;
    uint16 constant NONE = type(uint16).max;
    uint128 constant MINLIQ = 1e18;

    function setUp() public {
        vm.warp(1_800_000_000);
        USDT = address(new MockToken("USDT"));
        WBNB = address(new MockToken("WBNB"));
        BTC = address(new MockToken("BTCB"));
        ETH = address(new MockToken("ETH"));
        CAKE = address(new MockToken("CAKE"));
        pBNB = new MockV3Pool(WBNB, USDT, 0, 1e20);
        pBTC = new MockV3Pool(BTC, USDT, 0, 1e20);
        pETH = new MockV3Pool(ETH, WBNB, 0, 1e20);
        pCAKE = new MockV3Pool(CAKE, WBNB, 0, 1e20);
        agent = new MockAgentID();
        address[] memory usd = new address[](1);
        usd[0] = USDT;
        TrendRace.InitPool[] memory ip = new TrendRace.InitPool[](4);
        ip[0] = TrendRace.InitPool(address(pBNB), WBNB, MINLIQ);
        ip[1] = TrendRace.InitPool(address(pBTC), BTC, MINLIQ);
        ip[2] = TrendRace.InitPool(address(pETH), ETH, MINLIQ);
        ip[3] = TrendRace.InitPool(address(pCAKE), CAKE, MINLIQ);
        tr = new TrendRace(owner, op, address(agent), D, W, G, usd, ip);
        for (uint256 i; i < 6; ++i) {
            vm.deal([alice, bob, carol, dave, rando, address(this)][i], 100 ether);
        }
    }

    // ---------------------------------------------------------------- helpers
    /// set the tracked token's price tick in quote terms (handles token ordering)
    function setPx(MockV3Pool p, address tracked, int24 t) internal {
        vm.prank(address(this));
        p.setTick(p.token0() == tracked ? t : -t);
    }

    function create4() internal returns (uint256 id) {
        bytes32[] memory names = new bytes32[](4);
        names[0] = "BNB";
        names[1] = "BTC";
        names[2] = "ETH";
        names[3] = "CAKE";
        uint16[][] memory a = new uint16[][](4);
        uint16[][] memory b = new uint16[][](4);
        for (uint256 i; i < 4; ++i) {
            a[i] = new uint16[](1);
            b[i] = new uint16[](1);
        }
        a[0][0] = 0;
        b[0][0] = NONE;
        a[1][0] = 1;
        b[1][0] = NONE;
        a[2][0] = 2;
        b[2][0] = 0;
        a[3][0] = 3;
        b[3][0] = 0;
        vm.prank(op);
        id = tr.createRace(uint64(block.timestamp + 12 hours), names, a, b);
    }

    function startOf(uint256 id) internal view returns (uint256) {
        return tr.race(id).start;
    }

    /// run all 4 checkpoints; endMoves are the tracked-token ticks during the end window
    function runRace(uint256 id, int24 bnb, int24 btc, int24 eth, int24 cake) internal {
        uint256 s = startOf(id);
        vm.warp(s);
        vm.prank(rando);
        tr.checkpoint(id);
        if (tr.race(id).status != TrendRace.Status.Open) return;
        vm.warp(s + W);
        tr.checkpoint(id);
        setPx(pBNB, WBNB, bnb);
        setPx(pBTC, BTC, btc);
        setPx(pETH, ETH, eth);
        setPx(pCAKE, CAKE, cake);
        vm.warp(s + D);
        tr.checkpoint(id);
        vm.warp(s + D + W);
        vm.prank(rando);
        tr.checkpoint(id);
    }

    function stake(address who, uint256 id, uint8 lane, uint256 amt) internal {
        vm.prank(who);
        tr.enter{value: amt}(id, lane);
    }

    // ---------------------------------------------------------------- payout math
    function test_normalWin_payoutMath() public {
        uint256 id = create4();
        stake(alice, id, 1, 0.3 ether); // BTC
        stake(bob, id, 1, 0.1 ether); // BTC
        stake(carol, id, 0, 0.5 ether); // BNB
        stake(dave, id, 2, 0.1 ether); // ETH
        runRace(id, 10, 200, 50, -30);
        TrendRace.Race memory r = tr.race(id);
        assertEq(uint8(r.status), uint8(TrendRace.Status.Settled));
        assertEq(r.winners, 2); // lane 1
        assertEq(r.totalStake, 1 ether);
        assertEq(r.winningStake, 0.4 ether);
        uint256 a0 = alice.balance;
        vm.prank(alice);
        tr.claim(id);
        // gross = 0.3 * 1 / 0.4 = 0.75 ; fee 4% = 0.03
        assertEq(alice.balance - a0, 0.72 ether);
        uint256 b0 = bob.balance;
        vm.prank(bob);
        tr.claim(id);
        assertEq(bob.balance - b0, 0.24 ether);
        assertEq(tr.feesAccrued(), 0.04 ether);
        vm.prank(carol);
        vm.expectRevert(TrendRace.NothingToPay.selector);
        tr.claim(id);
        vm.prank(alice);
        vm.expectRevert(TrendRace.NothingToPay.selector);
        tr.claim(id);
        assertEq(address(tr).balance, 0.04 ether);
        tr.sweepDust(id);
        assertEq(tr.feesAccrued(), 0.04 ether);
    }

    function test_scores_conversionLeg_and_mean() public {
        // ETH up 100 vs WBNB but WBNB down 100 vs USD => ETH lane score 0 in USD
        uint256 id = create4();
        stake(alice, id, 0, 0.01 ether);
        stake(bob, id, 2, 0.01 ether);
        runRace(id, -100, -5, 100, 0);
        assertEq(tr.laneScore(id, 0), -100 * 1e6 * 60);
        assertEq(tr.laneScore(id, 1), -5 * 1e6 * 60);
        assertEq(tr.laneScore(id, 2), 0);
        assertEq(tr.laneScore(id, 3), -100 * 1e6 * 60);
        assertEq(tr.race(id).winners, 4); // ETH lane
    }

    function test_basketMean_twoTokens() public {
        bytes32[] memory names = new bytes32[](2);
        names[0] = "MAJORS";
        names[1] = "CAKE";
        uint16[][] memory a = new uint16[][](2);
        uint16[][] memory b = new uint16[][](2);
        a[0] = new uint16[](2);
        b[0] = new uint16[](2);
        a[0][0] = 1;
        b[0][0] = NONE;
        a[0][1] = 2;
        b[0][1] = 0; // BTC + ETH(usd)
        a[1] = new uint16[](1);
        b[1] = new uint16[](1);
        a[1][0] = 3;
        b[1][0] = 0;
        vm.prank(op);
        uint256 id = tr.createRace(uint64(block.timestamp + 1 hours), names, a, b);
        assertEq(tr.racePools(id).length, 4); // BTC, ETH, BNB, CAKE (BNB deduped)
        stake(alice, id, 0, 0.01 ether);
        stake(bob, id, 1, 0.01 ether);
        runRace(id, 0, 30, 10, 19); // majors mean (30+10)/2 = 20 > 19
        assertEq(tr.laneScore(id, 0), 20 * 1e6 * 60);
        assertEq(tr.race(id).winners, 1);
    }

    function test_tie_sharesPool() public {
        uint256 id = create4();
        stake(alice, id, 0, 0.2 ether);
        stake(bob, id, 1, 0.6 ether);
        stake(carol, id, 3, 0.2 ether);
        runRace(id, 50, 50, -50, -50); // BNB and BTC tie (ETH/CAKE net 0 in USD)
        TrendRace.Race memory r = tr.race(id);
        assertEq(r.winners, 3);
        assertEq(r.winningStake, 0.8 ether);
        uint256 a0 = alice.balance;
        vm.prank(alice);
        tr.claim(id);
        assertEq(alice.balance - a0, 0.24 ether); // 0.25 gross - 4%
        uint256 b0 = bob.balance;
        vm.prank(bob);
        tr.claim(id);
        assertEq(bob.balance - b0, 0.72 ether);
    }

    function test_rounding_dust() public {
        uint256 id = create4();
        stake(alice, id, 1, 0.005 ether + 1);
        stake(bob, id, 1, 0.005 ether + 2);
        stake(carol, id, 1, 0.005 ether + 4);
        stake(dave, id, 0, 0.007 ether + 3);
        runRace(id, 0, 1, 0, 0);
        uint256 before = address(tr).balance;
        uint256 paid;
        address[3] memory ws = [alice, bob, carol];
        for (uint256 i; i < 3; ++i) {
            uint256 b0 = ws[i].balance;
            vm.prank(ws[i]);
            tr.claim(id);
            paid += ws[i].balance - b0;
        }
        assertEq(before - paid, address(tr).balance);
        assertEq(address(tr).balance, tr.feesAccrued() + (tr.race(id).totalStake - tr.race(id).paidGross));
        tr.sweepDust(id);
        assertEq(address(tr).balance, tr.feesAccrued());
        vm.expectRevert(TrendRace.NotYet.selector);
        tr.sweepDust(id);
    }

    function test_sweepDust_onlyAfterAllWinnersClaimed() public {
        uint256 id = create4();
        stake(alice, id, 1, 0.01 ether);
        stake(bob, id, 1, 0.01 ether);
        stake(carol, id, 0, 0.01 ether);
        runRace(id, 0, 1, 0, 0);
        vm.prank(alice);
        tr.claim(id);
        vm.expectRevert(TrendRace.NotYet.selector);
        tr.sweepDust(id);
    }

    /// fuzz: arbitrary stakes on 4 lanes by 4 players; contract never pays more than it holds,
    /// and after everyone claims: balance == feesAccrued + dust, dust < number of winners.
    function testFuzz_payoutConservation(uint96[4] memory amts, uint8[4] memory lanes, int16 w) public {
        uint256 id = create4();
        address[4] memory ps = [alice, bob, carol, dave];
        uint256 total;
        for (uint256 i; i < 4; ++i) {
            uint256 amt = bound(amts[i], 0.005 ether, 0.45 ether);
            uint8 l = lanes[i] % 4;
            stake(ps[i], id, l, amt);
            total += amt;
        }
        int24 winTick = int24(bound(int256(w), 1, 5000));
        uint8 winLane = lanes[0] % 4; // make player 0's lane win
        int24[4] memory t;
        t[winLane] = winTick;
        // ETH & CAKE lanes include the BNB move; keep BNB 0 unless BNB lane wins
        if (winLane == 0) {
            t[0] = winTick;
            t[2] = -winTick;
            t[3] = -winTick;
        } // keep conversions neutral
        runRace(id, t[0], t[1], t[2], t[3]);
        TrendRace.Race memory r = tr.race(id);
        if (r.status == TrendRace.Status.Cancelled) {
            for (uint256 i; i < 4; ++i) {
                if (tr.player(id, ps[i]).total > 0) {
                    vm.prank(ps[i]);
                    tr.refund(id);
                }
            }
            assertEq(address(tr).balance, 0);
            return;
        }
        uint256 paid;
        uint256 fees;
        for (uint256 i; i < 4; ++i) {
            (uint256 g, uint256 f,) = tr.claimable(id, ps[i]);
            if (g == 0) continue;
            uint256 b0 = ps[i].balance;
            vm.prank(ps[i]);
            tr.claim(id);
            assertEq(ps[i].balance - b0, g - f);
            paid += g;
            fees += f;
        }
        assertLe(paid, total);
        assertLt(total - paid, 4); // dust < #winners
        assertEq(address(tr).balance, total - paid + fees);
        assertEq(tr.feesAccrued(), fees);
        tr.sweepDust(id);
        assertEq(address(tr).balance, tr.feesAccrued());
        if (tr.feesAccrued() > 0) {
            uint256 f = tr.feesAccrued();
            vm.prank(owner);
            tr.withdrawFees(f);
        }
        assertEq(address(tr).balance, 0);
    }

    // ---------------------------------------------------------------- refunds / cancels
    function _refundAll(uint256 id, address[] memory ps, uint256[] memory amts) internal {
        for (uint256 i; i < ps.length; ++i) {
            uint256 b0 = ps[i].balance;
            vm.prank(ps[i]);
            tr.refund(id);
            assertEq(ps[i].balance - b0, amts[i]);
            vm.prank(ps[i]);
            vm.expectRevert(TrendRace.NothingToPay.selector);
            tr.refund(id);
        }
    }

    function test_noWinnerStake_refund() public {
        uint256 id = create4();
        stake(alice, id, 0, 0.1 ether);
        stake(alice, id, 2, 0.05 ether);
        stake(bob, id, 1, 0.2 ether);
        runRace(id, 0, 0, 0, 500); // CAKE wins, nobody on CAKE
        TrendRace.Race memory r = tr.race(id);
        assertEq(uint8(r.status), uint8(TrendRace.Status.Cancelled));
        address[] memory ps = new address[](2);
        ps[0] = alice;
        ps[1] = bob;
        uint256[] memory a = new uint256[](2);
        a[0] = 0.15 ether;
        a[1] = 0.2 ether;
        _refundAll(id, ps, a);
        assertEq(address(tr).balance, 0);
        assertEq(tr.feesAccrued(), 0);
        vm.prank(alice);
        vm.expectRevert(TrendRace.BadRace.selector);
        tr.claim(id);
    }

    function test_fewerThanTwoLanes_cancelAtStart() public {
        uint256 id = create4();
        stake(alice, id, 1, 0.1 ether);
        stake(bob, id, 1, 0.1 ether);
        vm.warp(startOf(id));
        tr.checkpoint(id);
        assertEq(uint8(tr.race(id).status), uint8(TrendRace.Status.Cancelled));
        vm.prank(alice);
        tr.refund(id);
        vm.prank(bob);
        tr.refund(id);
        assertEq(address(tr).balance, 0);
    }

    function test_emptyRace_cancel() public {
        uint256 id = create4();
        vm.warp(startOf(id));
        tr.checkpoint(id);
        assertEq(uint8(tr.race(id).status), uint8(TrendRace.Status.Cancelled));
    }

    function _twoStakes(uint256 id) internal {
        stake(alice, id, 0, 0.1 ether);
        stake(bob, id, 1, 0.1 ether);
    }

    function test_missedCheckpoint_eachPhase_cancel() public {
        for (uint256 ph; ph < 4; ++ph) {
            uint256 id = create4();
            _twoStakes(id);
            uint256 s = startOf(id);
            uint256[4] memory at = [s, s + W, s + D, s + D + W];
            for (uint256 k; k < ph; ++k) {
                vm.warp(at[k]);
                tr.checkpoint(id);
            }
            (, uint256 earliest, uint256 deadline) = tr.nextCheckpointWindow(id);
            assertEq(deadline, earliest + G);
            vm.warp(deadline);
            vm.prank(rando);
            vm.expectRevert(TrendRace.NotYet.selector);
            tr.cancelStale(id);
            vm.warp(deadline + 1);
            vm.prank(rando);
            tr.cancelStale(id);
            assertEq(uint8(tr.race(id).status), uint8(TrendRace.Status.Cancelled));
            vm.prank(alice);
            tr.refund(id);
            vm.prank(bob);
            tr.refund(id);
        }
        assertEq(address(tr).balance, 0);
    }

    function test_lateCheckpoint_selfCancels() public {
        uint256 id = create4();
        _twoStakes(id);
        vm.warp(startOf(id) + G + 1);
        tr.checkpoint(id);
        assertEq(uint8(tr.race(id).status), uint8(TrendRace.Status.Cancelled));
    }

    function test_checkpoint_tooEarly_reverts() public {
        uint256 id = create4();
        _twoStakes(id);
        vm.warp(startOf(id) - 1);
        vm.expectRevert(TrendRace.NotYet.selector);
        tr.checkpoint(id);
        vm.warp(startOf(id));
        tr.checkpoint(id);
        vm.warp(startOf(id) + W - 1);
        vm.expectRevert(TrendRace.NotYet.selector);
        tr.checkpoint(id);
    }

    function test_oracleBroken_cancel() public {
        uint256 id = create4();
        _twoStakes(id);
        uint256 s = startOf(id);
        vm.warp(s);
        tr.checkpoint(id);
        vm.warp(s + W);
        tr.checkpoint(id);
        pETH.setBroken(true);
        vm.warp(s + D);
        tr.checkpoint(id);
        assertEq(uint8(tr.race(id).status), uint8(TrendRace.Status.Cancelled));
        vm.prank(alice);
        tr.refund(id);
    }

    function test_lowLiquidity_cancel_atSettle() public {
        uint256 id = create4();
        _twoStakes(id);
        uint256 s = startOf(id);
        vm.warp(s);
        tr.checkpoint(id);
        vm.warp(s + W);
        tr.checkpoint(id);
        vm.warp(s + D);
        tr.checkpoint(id);
        pBTC.setLiquidity(MINLIQ - 1);
        vm.warp(s + D + W);
        tr.checkpoint(id);
        assertEq(uint8(tr.race(id).status), uint8(TrendRace.Status.Cancelled));
        vm.prank(bob);
        tr.refund(id);
    }

    function test_lowGas_cannotForceCancel() public {
        uint256 id = create4();
        _twoStakes(id);
        vm.warp(startOf(id));
        (bool ok,) = address(tr).call{gas: 120_000}(abi.encodeCall(TrendRace.checkpoint, (id)));
        assertFalse(ok);
        assertEq(uint8(tr.race(id).status), uint8(TrendRace.Status.Open));
        assertEq(tr.race(id).phase, 0);
        tr.checkpoint(id);
        assertEq(tr.race(id).phase, 1);
    }

    function test_settleByAnyone_and_noDoubleSettle() public {
        uint256 id = create4();
        _twoStakes(id);
        runRace(id, 5, 0, 0, 0); // checkpoints called by rando / test contract
        assertEq(uint8(tr.race(id).status), uint8(TrendRace.Status.Settled));
        vm.expectRevert(TrendRace.BadRace.selector);
        tr.checkpoint(id);
        vm.expectRevert(TrendRace.BadRace.selector);
        tr.cancelStale(id);
    }

    function test_resultIndependentOfCaller_onlyPrices() public {
        // the same price path gives the same result whoever calls and whether calls are a few seconds late
        uint256 id1 = create4();
        _twoStakes(id1);
        uint256 s = startOf(id1);
        vm.warp(s + 7);
        tr.checkpoint(id1);
        vm.warp(s + 7 + W + 3);
        vm.prank(alice);
        tr.checkpoint(id1);
        setPx(pBNB, WBNB, -20);
        setPx(pBTC, BTC, 15);
        vm.warp(s + D + 11);
        vm.prank(bob);
        tr.checkpoint(id1);
        vm.warp(s + D + W + 40);
        vm.prank(carol);
        tr.checkpoint(id1);
        assertEq(tr.race(id1).winners, 2);
        assertEq(tr.laneScore(id1, 1), 15 * 1e6 * 60);
    }

    function test_operatorCancelBeforeStart_only() public {
        uint256 id = create4();
        _twoStakes(id);
        vm.prank(rando);
        vm.expectRevert(TrendRace.NotOperator.selector);
        tr.cancelBeforeStart(id);
        vm.warp(startOf(id));
        vm.prank(op);
        vm.expectRevert(TrendRace.BadRace.selector);
        tr.cancelBeforeStart(id);
        uint256 id2 = create4();
        _twoStakes(id2);
        vm.prank(op);
        tr.cancelBeforeStart(id2);
        vm.prank(alice);
        tr.refund(id2);
    }

    // ---------------------------------------------------------------- agent id
    function test_agentDiscount_feeAndLock() public {
        uint256 id = create4();
        uint256 aid = agent.mint(alice);
        vm.prank(alice);
        tr.enterWithAgent{value: 0.4 ether}(id, 1, aid);
        vm.prank(alice);
        tr.enter{value: 0.1 ether}(id, 1); // later plain entry keeps agent fee
        vm.prank(alice);
        tr.enterWithAgent{value: 0.1 ether}(id, 1, aid); // same agent ok
        stake(bob, id, 0, 0.4 ether);
        assertEq(tr.player(id, alice).fee, 250);
        assertEq(tr.player(id, bob).fee, 400);
        runRace(id, 0, 9, 0, 0);
        uint256 a0 = alice.balance;
        vm.prank(alice);
        tr.claim(id);
        // gross 1.0, fee 2.5%
        assertEq(alice.balance - a0, 0.975 ether);
        assertEq(tr.feesAccrued(), 0.025 ether);
    }

    function test_agentReuse_fallsBackToNormalFee_sameRace_discountNextRace() public {
        uint256 id = create4();
        uint256 aid = agent.mint(alice);
        vm.prank(alice);
        tr.enterWithAgent{value: 0.01 ether}(id, 1, aid);
        vm.prank(alice);
        agent.transferFrom(alice, bob, aid);
        // id already used in this race by alice: bob still enters, at the normal fee
        vm.prank(bob);
        tr.enterWithAgent{value: 0.01 ether}(id, 0, aid);
        assertEq(tr.player(id, bob).fee, 400);
        assertFalse(tr.player(id, bob).usedAgent);
        assertEq(tr.agentIdUsedBy(id, aid), alice);
        uint256 id2 = create4();
        vm.prank(bob);
        tr.enterWithAgent{value: 0.01 ether}(id2, 0, aid);
        assertEq(tr.player(id2, bob).fee, 250);
        assertEq(tr.agentIdUsedBy(id2, aid), bob);
    }

    function test_agent_notOwner_entersAtNormalFee_and_feeLockedAtFirstEntry() public {
        uint256 id = create4();
        uint256 aid = agent.mint(alice);
        vm.prank(bob);
        tr.enterWithAgent{value: 0.01 ether}(id, 0, aid); // not owner -> normal fee, entry succeeds
        assertEq(tr.player(id, bob).fee, 400);
        assertEq(tr.agentIdUsedBy(id, aid), address(0));
        assertEq(tr.stakeOf(id, bob, 0), 0.01 ether);
        // plain first entry locks normal fee; a later agent entry does not change it
        stake(carol, id, 0, 0.01 ether);
        uint256 cid = agent.mint(carol);
        vm.prank(carol);
        tr.enterWithAgent{value: 0.01 ether}(id, 0, cid);
        assertEq(tr.player(id, carol).fee, 400);
        assertEq(tr.agentIdUsedBy(id, cid), address(0));
        // one agent per wallet per race: alice cannot switch to a second agent (fee stays, id2 not consumed)
        uint256 aid2 = agent.mint(alice);
        vm.prank(alice);
        tr.enterWithAgent{value: 0.01 ether}(id, 0, aid);
        vm.prank(alice);
        tr.enterWithAgent{value: 0.01 ether}(id, 0, aid2);
        assertEq(tr.player(id, alice).fee, 250);
        assertEq(tr.agentIdUsedBy(id, aid2), address(0));
        assertEq(tr.player(id, alice).total, 0.02 ether);
    }

    function test_entry_withoutAgentId_everyLane() public {
        uint256 id = create4();
        for (uint8 l; l < 4; ++l) stake(dave, id, l, 0.01 ether);
        assertEq(tr.player(id, dave).fee, 400);
        assertEq(tr.player(id, dave).total, 0.04 ether);
    }

    function test_registryUnset_discountOff_entryWorks() public {
        uint256 aid = agent.mint(alice);
        vm.prank(rando);
        vm.expectRevert(TrendRace.NotOperator.selector);
        tr.setAgentRegistry(address(0));
        vm.prank(op);
        tr.setAgentRegistry(address(0));
        uint256 id = create4();
        vm.prank(alice);
        tr.enterWithAgent{value: 0.01 ether}(id, 0, aid);
        assertEq(tr.player(id, alice).fee, 400);
        assertFalse(tr.player(id, alice).usedAgent);
        stake(bob, id, 1, 0.01 ether);
        // registry set again -> discount applies in new races
        vm.prank(op);
        tr.setAgentRegistry(address(agent));
        uint256 id2 = create4();
        vm.prank(alice);
        tr.enterWithAgent{value: 0.01 ether}(id2, 0, aid);
        assertEq(tr.player(id2, alice).fee, 250);
    }

    function _registryCase(address reg) internal {
        vm.prank(op);
        tr.setAgentRegistry(reg);
        uint256 id = create4();
        vm.prank(alice, alice);
        tr.enterWithAgent{value: 0.01 ether}(id, 2, 7);
        assertEq(tr.player(id, alice).fee, 400);
        assertFalse(tr.player(id, alice).usedAgent);
        assertEq(tr.stakeOf(id, alice, 2), 0.01 ether);
    }

    function test_registryReverting_entryStillWorks() public {
        _registryCase(address(new RevertingRegistry()));
    }

    function test_registryMisbehaving_entryStillWorks() public {
        _registryCase(address(new ShortReturnRegistry()));
        _registryCase(address(new GarbageRegistry()));
        _registryCase(address(new GasGuzzlerRegistry()));
        _registryCase(address(0xdead)); // EOA / no code
    }

    function test_discountRate_adjustable_zeroToFee() public {
        uint256 aid = agent.mint(alice);
        vm.prank(op);
        tr.setParams(400, 0, 0.005 ether, 2 ether); // agent fee 0% allowed (discount = full fee)
        uint256 id = create4();
        vm.prank(alice);
        tr.enterWithAgent{value: 0.01 ether}(id, 0, aid);
        assertEq(tr.player(id, alice).fee, 0);
        vm.prank(op);
        tr.setParams(400, 400, 0.005 ether, 2 ether); // no discount
        uint256 id2 = create4();
        vm.prank(alice);
        tr.enterWithAgent{value: 0.01 ether}(id2, 0, aid);
        assertEq(tr.player(id2, alice).fee, 400);
    }

    function test_noFreeEntries() public {
        uint256 id = create4();
        uint256 aid = agent.mint(alice);
        vm.prank(alice);
        vm.expectRevert(TrendRace.TooSmall.selector);
        tr.enterWithAgent{value: 0}(id, 0, aid);
        vm.prank(op);
        tr.setParams(400, 0, 0.005 ether, 2 ether);
        uint256 id0 = create4();
        vm.prank(alice);
        vm.expectRevert(TrendRace.TooSmall.selector);
        tr.enterWithAgent{value: 0}(id0, 0, aid); // even at 0% agent fee, stake >= minEntry is required
        vm.prank(alice);
        vm.expectRevert(TrendRace.TooSmall.selector);
        tr.enter{value: 0.005 ether - 1}(id, 0);
    }

    // ---------------------------------------------------------------- caps / params
    function test_poolCap_and_entryWindow() public {
        uint256 id = create4();
        stake(alice, id, 0, 1.5 ether);
        vm.prank(bob);
        vm.expectRevert(TrendRace.CapExceeded.selector);
        tr.enter{value: 0.5 ether + 1}(id, 1);
        stake(bob, id, 1, 0.5 ether); // exactly 2 BNB
        vm.prank(op);
        tr.setEntriesPaused(true);
        uint256 id2 = create4();
        vm.prank(carol);
        vm.expectRevert(TrendRace.EntryClosed.selector);
        tr.enter{value: 0.01 ether}(id2, 1);
        vm.prank(op);
        tr.setEntriesPaused(false);
        vm.prank(carol);
        vm.expectRevert(TrendRace.BadParam.selector);
        tr.enter{value: 0.01 ether}(id2, 4);
        vm.warp(startOf(id2));
        vm.prank(carol);
        vm.expectRevert(TrendRace.EntryClosed.selector);
        tr.enter{value: 0.01 ether}(id2, 1);
    }

    function test_setParams_bounds_and_futureOnly() public {
        vm.startPrank(op);
        vm.expectRevert(TrendRace.BadParam.selector);
        tr.setParams(501, 250, 0.005 ether, 2 ether);
        vm.expectRevert(TrendRace.BadParam.selector);
        tr.setParams(400, 401, 0.005 ether, 2 ether);
        vm.expectRevert(TrendRace.BadParam.selector);
        tr.setParams(400, 250, 0.005 ether, 20 ether + 1);
        vm.expectRevert(TrendRace.BadParam.selector);
        tr.setParams(400, 250, 0.0009 ether, 2 ether);
        vm.stopPrank();
        uint256 id = create4();
        vm.prank(op);
        tr.setParams(500, 300, 0.01 ether, 5 ether);
        assertEq(tr.race(id).feeBps, 400);
        assertEq(tr.race(id).cap, 2 ether);
        uint256 id2 = create4();
        assertEq(tr.race(id2).feeBps, 500);
        assertEq(tr.race(id2).agentFeeBps, 300);
        assertEq(tr.race(id2).cap, 5 ether);
    }

    // ---------------------------------------------------------------- access control
    function test_accessControl() public {
        bytes32[] memory names = new bytes32[](2);
        uint16[][] memory a = new uint16[][](2);
        vm.startPrank(rando);
        vm.expectRevert(TrendRace.NotOperator.selector);
        tr.createRace(uint64(block.timestamp + 1 hours), names, a, a);
        vm.expectRevert(TrendRace.NotOperator.selector);
        tr.setParams(400, 250, 0.005 ether, 2 ether);
        vm.expectRevert(TrendRace.NotOperator.selector);
        tr.setEntriesPaused(true);
        vm.expectRevert(TrendRace.NotOperator.selector);
        tr.proposePool(address(pBNB), WBNB, 1);
        vm.expectRevert(TrendRace.NotOperator.selector);
        tr.removePool(0);
        vm.expectRevert(TrendRace.NotOwner.selector);
        tr.setOperator(rando);
        vm.expectRevert(TrendRace.NotOwner.selector);
        tr.withdrawFees(1);
        vm.stopPrank();
        // operator cannot withdraw fees or change operator
        vm.startPrank(op);
        vm.expectRevert(TrendRace.NotOwner.selector);
        tr.withdrawFees(1);
        vm.expectRevert(TrendRace.NotOwner.selector);
        tr.setOperator(op);
        vm.stopPrank();
        // owner cannot act as operator
        vm.prank(owner);
        vm.expectRevert(TrendRace.NotOperator.selector);
        tr.setParams(400, 250, 0.005 ether, 2 ether);
        // owner replaces operator
        vm.prank(owner);
        tr.setOperator(carol);
        assertEq(tr.operator(), carol);
        vm.prank(op);
        vm.expectRevert(TrendRace.NotOperator.selector);
        tr.setEntriesPaused(true);
    }

    function test_owner_withdraw_onlyFees() public {
        uint256 id = create4();
        stake(alice, id, 1, 1 ether);
        stake(bob, id, 0, 1 ether);
        runRace(id, 0, 3, 0, 0);
        vm.prank(owner);
        vm.expectRevert(TrendRace.BadParam.selector);
        tr.withdrawFees(1); // no fees until a claim
        vm.prank(alice);
        tr.claim(id);
        uint256 f = tr.feesAccrued();
        assertEq(f, 0.08 ether);
        vm.prank(owner);
        vm.expectRevert(TrendRace.BadParam.selector);
        tr.withdrawFees(f + 1);
        uint256 o0 = owner.balance;
        vm.prank(owner);
        tr.withdrawFees(f);
        assertEq(owner.balance - o0, f);
        assertEq(address(tr).balance, 0);
    }

    function test_owner_cannotTouchStakes() public {
        uint256 id = create4();
        stake(alice, id, 1, 1 ether);
        vm.prank(owner);
        vm.expectRevert(TrendRace.BadParam.selector);
        tr.withdrawFees(1 ether);
        assertEq(address(tr).balance, 1 ether);
    }

    function test_plainTransfer_rejected() public {
        (bool ok,) = address(tr).call{value: 1 ether}("");
        assertFalse(ok);
    }

    // ---------------------------------------------------------------- pool registry
    function test_poolTimelock_and_removal() public {
        MockToken x = new MockToken("X");
        MockV3Pool px = new MockV3Pool(address(x), USDT, 0, 1e20);
        vm.prank(op);
        uint256 pid = tr.proposePool(address(px), address(x), MINLIQ);
        assertEq(pid, 4);
        bytes32[] memory names = new bytes32[](2);
        uint16[][] memory a = new uint16[][](2);
        uint16[][] memory b = new uint16[][](2);
        a[0] = new uint16[](1);
        b[0] = new uint16[](1);
        a[1] = new uint16[](1);
        b[1] = new uint16[](1);
        a[0][0] = uint16(pid);
        b[0][0] = NONE;
        a[1][0] = 1;
        b[1][0] = NONE;
        vm.prank(op);
        vm.expectRevert(TrendRace.BadPool.selector);
        tr.createRace(uint64(block.timestamp + 1 hours), names, a, b);
        vm.warp(block.timestamp + 24 hours - 1);
        vm.prank(op);
        vm.expectRevert(TrendRace.BadPool.selector);
        tr.createRace(uint64(block.timestamp + 1 hours), names, a, b);
        vm.warp(block.timestamp + 1);
        vm.prank(op);
        uint256 id = tr.createRace(uint64(block.timestamp + 1 hours), names, a, b);
        // removal blocks new races but not the running one
        vm.prank(op);
        tr.removePool(pid);
        vm.prank(op);
        vm.expectRevert(TrendRace.BadPool.selector);
        tr.createRace(uint64(block.timestamp + 1 hours), names, a, b);
        stake(alice, id, 0, 0.01 ether);
        stake(bob, id, 1, 0.01 ether);
        uint256 s = startOf(id);
        vm.warp(s);
        tr.checkpoint(id);
        vm.warp(s + W);
        tr.checkpoint(id);
        px.setTick(px.token0() == address(x) ? int24(40) : int24(-40));
        vm.warp(s + D);
        tr.checkpoint(id);
        vm.warp(s + D + W);
        tr.checkpoint(id);
        assertEq(tr.race(id).winners, 1);
    }

    function test_createRace_validation() public {
        bytes32[] memory names = new bytes32[](2);
        uint16[][] memory a = new uint16[][](2);
        uint16[][] memory b = new uint16[][](2);
        a[0] = new uint16[](1);
        b[0] = new uint16[](1);
        a[1] = new uint16[](1);
        b[1] = new uint16[](1);
        a[0][0] = 2;
        b[0][0] = NONE; // ETH/WBNB without USD conversion
        a[1][0] = 1;
        b[1][0] = NONE;
        vm.startPrank(op);
        vm.expectRevert(TrendRace.BadPool.selector);
        tr.createRace(uint64(block.timestamp + 1 hours), names, a, b);
        b[0][0] = 1; // wrong conversion pool (BTC/USDT)
        vm.expectRevert(TrendRace.BadPool.selector);
        tr.createRace(uint64(block.timestamp + 1 hours), names, a, b);
        b[0][0] = 0;
        b[1][0] = 0; // USD-quoted pool must not have a conversion
        vm.expectRevert(TrendRace.BadPool.selector);
        tr.createRace(uint64(block.timestamp + 1 hours), names, a, b);
        b[1][0] = NONE;
        vm.expectRevert(TrendRace.BadParam.selector);
        tr.createRace(uint64(block.timestamp), names, a, b); // start must be in future
        vm.expectRevert(TrendRace.BadParam.selector);
        tr.createRace(uint64(block.timestamp + 7 days + 1), names, a, b);
        a[1][0] = 99;
        vm.expectRevert(TrendRace.BadPool.selector);
        tr.createRace(uint64(block.timestamp + 1 hours), names, a, b);
        a[1][0] = 1;
        tr.createRace(uint64(block.timestamp + 1 hours), names, a, b);
        // one lane is not a race
        bytes32[] memory one = new bytes32[](1);
        uint16[][] memory a1 = new uint16[][](1);
        vm.expectRevert(TrendRace.BadParam.selector);
        tr.createRace(uint64(block.timestamp + 1 hours), one, a1, a1);
        vm.stopPrank();
        // propose pool with tracked token not in pool
        vm.prank(op);
        vm.expectRevert(TrendRace.BadPool.selector);
        tr.proposePool(address(pBNB), BTC, 1);
    }

    function test_constructor_bounds() public {
        address[] memory usd = new address[](0);
        TrendRace.InitPool[] memory ip = new TrendRace.InitPool[](0);
        vm.expectRevert(TrendRace.BadParam.selector);
        new TrendRace(owner, op, address(0), 2 hours, 30 minutes, 31 minutes, usd, ip);
        vm.expectRevert(TrendRace.BadParam.selector);
        new TrendRace(address(0), op, address(0), D, W, G, usd, ip);
        TrendRace t2 = new TrendRace(owner, op, address(0), D, W, G, usd, ip);
        assertEq(t2.agentRegistry(), address(0));
    }

    // ---------------------------------------------------------------- reentrancy
    function test_reentrancy_claim() public {
        Reenterer att = new Reenterer(tr);
        uint256 id = create4();
        att.enter{value: 0.5 ether}(id, 1);
        stake(bob, id, 0, 0.5 ether);
        runRace(id, 0, 7, 0, 0);
        att.setMode(1, id, 0);
        vm.expectRevert(TrendRace.TransferFailed.selector);
        att.doClaim();
        assertEq(address(tr).balance, 1 ether);
        att.setMode(0, id, 0);
        att.doClaim();
        assertEq(address(att).balance, 0.96 ether);
        vm.expectRevert(TrendRace.NothingToPay.selector);
        att.doClaim();
    }

    function test_reentrancy_refund_crossRace() public {
        Reenterer att = new Reenterer(tr);
        uint256 id = create4();
        uint256 id2 = create4();
        att.enter{value: 0.5 ether}(id, 1);
        att.enter{value: 0.5 ether}(id2, 1);
        vm.prank(op);
        tr.cancelBeforeStart(id);
        vm.prank(op);
        tr.cancelBeforeStart(id2);
        att.setMode(2, id, 0);
        vm.expectRevert(TrendRace.TransferFailed.selector);
        att.doRefund();
        att.setMode(3, id, id2);
        vm.expectRevert(TrendRace.TransferFailed.selector);
        att.doRefund();
        assertEq(address(tr).balance, 1 ether);
        att.setMode(0, id, 0);
        att.doRefund();
        assertEq(address(att).balance, 0.5 ether);
    }


    /// fuzz: 8 players, each on up to 2 lanes, random end ticks (ties possible), agent/non-agent fees mixed.
    function testFuzz_multiLane_conservation(uint256 seed, int8[4] memory ticks) public {
        uint256 id = create4();
        address[] memory ps = new address[](8);
        uint256 total;
        for (uint256 i; i < 8; ++i) {
            ps[i] = address(uint160(0x1000 + i));
            vm.deal(ps[i], 10 ether);
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            if (r % 3 == 0) {
                uint256 aid = agent.mint(ps[i]);
                vm.prank(ps[i]);
                uint256 amt0 = 0.005 ether + (r >> 8) % 0.1 ether;
                tr.enterWithAgent{value: amt0}(id, uint8((r >> 64) % 4), aid);
                total += amt0;
            }
            uint256 amt = 0.005 ether + (r >> 16) % 0.12 ether;
            stake(ps[i], id, uint8((r >> 128) % 4), amt);
            total += amt;
        }
        runRace(id, ticks[0], ticks[1], ticks[2], ticks[3]);
        TrendRace.Race memory rc = tr.race(id);
        assertEq(rc.totalStake, total);
        if (rc.status == TrendRace.Status.Cancelled) {
            for (uint256 i; i < 8; ++i) {
                uint256 b0 = ps[i].balance;
                vm.prank(ps[i]);
                tr.refund(id);
                assertEq(ps[i].balance - b0, tr.player(id, ps[i]).total);
            }
            assertEq(address(tr).balance, 0);
            return;
        }
        uint256 paid;
        uint256 fees;
        uint256 winners;
        for (uint256 i; i < 8; ++i) {
            (uint256 g, uint256 f,) = tr.claimable(id, ps[i]);
            if (g == 0) continue;
            ++winners;
            assertLe(f * 10_000, g * 400);
            vm.prank(ps[i]);
            tr.claim(id);
            paid += g;
            fees += f;
        }
        assertLe(paid, total);
        assertLe(total - paid, winners);
        assertEq(address(tr).balance, total - paid + fees);
        tr.sweepDust(id);
        assertEq(address(tr).balance, tr.feesAccrued());
    }

    function test_gas_fullRace_fourPools() public {
        uint256 id = create4();
        _twoStakes(id);
        uint256 s = startOf(id);
        vm.warp(s);
        uint256 g0 = gasleft();
        tr.checkpoint(id);
        emit log_named_uint("checkpoint0 gas (4 pools)", g0 - gasleft());
        vm.warp(s + W);
        tr.checkpoint(id);
        vm.warp(s + D);
        tr.checkpoint(id);
        vm.warp(s + D + W);
        g0 = gasleft();
        tr.checkpoint(id);
        emit log_named_uint("settle checkpoint gas (4 pools)", g0 - gasleft());
    }
}
