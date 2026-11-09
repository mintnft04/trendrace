// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {TrendRace, IV3Pool} from "../src/TrendRace.sol";

interface IPoolFull is IV3Pool {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint32, bool);
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
        external
        returns (int256, int256);
}

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IAgent {
    function ownerOf(uint256) external view returns (address);
}

/// BSC mainnet fork simulation with the exact mainnet constructor config (deploy/mainnet_config.json).
/// Run: forge test --match-path test/Fork.t.sol --fork-url <bsc rpc> -vv
contract ForkTest is Test {
    using stdJson for string;

    TrendRace tr;
    string cfg;
    uint256 nPools;
    address[] poolAddr;
    address[] tracked;
    uint160 constant MIN_SQRT = 4295128739 + 1;
    uint160 constant MAX_SQRT = 1461446703485210103287273052203988822378723970342 - 1;
    uint256 constant D = 1 days;
    uint256 constant W = 30 minutes;

    // an Agent ID token seen minted on BSC (Transfer log); owner is read live from the fork
    uint256 constant AGENT_TOKEN = 0x0a447c9b6129a1c9639cfa6ec23a82d01337f22a88495470c47b163b6d09d688;

    function setUp() public {
        if (block.chainid != 56) return;
        cfg = vm.readFile("deploy/mainnet_config.json");
        nPools = 7;
        TrendRace.InitPool[] memory ip = new TrendRace.InitPool[](nPools);
        for (uint256 i; i < nPools; ++i) {
            string memory k = string.concat(".pools[", vm.toString(i), "]");
            address p = cfg.readAddress(string.concat(k, ".pool"));
            address t = cfg.readAddress(string.concat(k, ".tracked"));
            uint256 ml = vm.parseUint(cfg.readString(string.concat(k, ".minLiquidity")));
            ip[i] = TrendRace.InitPool(p, t, uint128(ml));
            poolAddr.push(p);
            tracked.push(t);
        }
        address[] memory usd = cfg.readAddressArray(".usdQuotes");
        uint256 g0 = gasleft();
        tr = new TrendRace(
            cfg.readAddress(".owner"),
            cfg.readAddress(".operator"),
            cfg.readAddress(".agentId"),
            cfg.readUint(".raceDuration"),
            cfg.readUint(".twapWindow"),
            cfg.readUint(".checkpointGrace"),
            usd,
            ip
        );
        console.log("deploy gas (approx, in-test):", g0 - gasleft());
    }

    function _lanes() internal view returns (bytes32[] memory names, uint16[][] memory a, uint16[][] memory b) {
        uint256 L = 5;
        names = new bytes32[](L);
        a = new uint16[][](L);
        b = new uint16[][](L);
        for (uint256 l; l < L; ++l) {
            string memory k = string.concat(".lanes[", vm.toString(l), "]");
            names[l] = bytes32(bytes(cfg.readString(string.concat(k, ".name"))));
            uint256[] memory la = cfg.readUintArray(string.concat(k, ".legA"));
            uint256[] memory lb = cfg.readUintArray(string.concat(k, ".legB"));
            a[l] = new uint16[](la.length);
            b[l] = new uint16[](lb.length);
            for (uint256 t; t < la.length; ++t) {
                a[l][t] = uint16(la[t]);
                b[l][t] = uint16(lb[t]);
            }
        }
    }

    function _tick(uint256 i) internal view returns (int24 t) {
        (, t,,,,,) = IPoolFull(poolAddr[i]).slot0();
    }

    /// buy (up=true) or sell the tracked token with `amount` of the token paid in
    function _swap(uint256 i, bool up, uint256 amount) internal {
        IPoolFull p = IPoolFull(poolAddr[i]);
        address t0 = p.token0();
        bool trackedIs0 = tracked[i] == t0;
        // buying tracked = paying the other token
        bool zeroForOne = up ? !trackedIs0 : trackedIs0;
        address payTok = zeroForOne ? t0 : p.token1();
        deal(payTok, address(this), amount);
        p.swap(address(this), zeroForOne, int256(amount), zeroForOne ? MIN_SQRT : MAX_SQRT, abi.encode(payTok));
    }

    function pancakeV3SwapCallback(int256 a0, int256 a1, bytes calldata data) external {
        address payTok = abi.decode(data, (address));
        uint256 owe = uint256(a0 > 0 ? a0 : a1);
        IERC20(payTok).transfer(msg.sender, owe);
    }

    uint256 raceId;
    address agentOwner;
    address[8] ps;
    int24[7] before;
    int24[7] afterT;

    function test_fork_fullRace_realPools() public {
        if (block.chainid != 56) return;
        _phaseCreateAndEnter();
        _phaseRun();
        _phaseCheckScores();
        _phaseClaims();
    }

    function _phaseCreateAndEnter() internal {
        address op = cfg.readAddress(".operator");
        (bytes32[] memory names, uint16[][] memory a, uint16[][] memory b) = _lanes();
        // all registered pools answer a real 30-min lookback right now and have >= minLiquidity
        uint32[] memory ago = new uint32[](2);
        ago[0] = 1800;
        for (uint256 i; i < nPools; ++i) {
            (int56[] memory c,) = IV3Pool(poolAddr[i]).observe(ago);
            assertEq(c.length, 2);
            assertGe(IV3Pool(poolAddr[i]).liquidity(), tr.poolInfo(i).minLiquidity);
        }
        vm.prank(op);
        raceId = tr.createRace(uint64(block.timestamp + 6 hours), names, a, b);
        assertEq(tr.racePools(raceId).length, 7);
        for (uint256 i; i < 8; ++i) {
            ps[i] = makeAddr(string.concat("p", vm.toString(i)));
            vm.deal(ps[i], 5 ether);
        }
        // real Agent ID holder gets the discount
        agentOwner = IAgent(cfg.readAddress(".agentId")).ownerOf(AGENT_TOKEN);
        vm.deal(agentOwner, 5 ether);
        vm.prank(agentOwner);
        tr.enterWithAgent{value: 0.2 ether}(raceId, 1, AGENT_TOKEN);
        assertEq(tr.player(raceId, agentOwner).fee, 250);
        uint256[8] memory amt = [uint256(0.1 ether), 0.25 ether, 0.05 ether, 0.3 ether, 0.2 ether, 0.15 ether, 0.1 ether, 0.4 ether];
        uint8[8] memory ln = [uint8(0), 1, 2, 3, 4, 1, 0, 4];
        for (uint256 i; i < 8; ++i) {
            vm.prank(ps[i]);
            tr.enter{value: amt[i]}(raceId, ln[i]);
        }
        assertEq(tr.race(raceId).totalStake, 1.75 ether);
        vm.prank(ps[0]);
        vm.expectRevert(TrendRace.CapExceeded.selector);
        tr.enter{value: 0.26 ether}(raceId, 0);
    }

    function _phaseRun() internal {
        uint256 id = raceId;
        for (uint256 i; i < nPools; ++i) before[i] = _tick(i);
        uint256 s = tr.race(id).start;
        vm.warp(s + 3);
        vm.roll(block.number + 1);
        vm.prank(makeAddr("keeper"));
        tr.checkpoint(id);
        vm.warp(s + 3 + W);
        vm.roll(block.number + 1);
        vm.prank(makeAddr("stranger"));
        tr.checkpoint(id);
        // during the race: BTC bought hard, SOL sold, ETH bought a little
        vm.warp(s + 6 hours);
        vm.roll(block.number + 1);
        _swap(1, true, 1_500_000 ether); // 1.5M USDT -> BTCB
        _swap(4, false, 3_000 ether); // sell SOL
        _swap(2, true, 50_000 ether); // 50k USDT -> ETH
        for (uint256 i; i < nPools; ++i) afterT[i] = _tick(i);
        console.log("BTC tick move:");
        console.logInt(int256(afterT[1]) - int256(before[1]));
        vm.warp(s + D + 5);
        vm.roll(block.number + 1);
        tr.checkpoint(id);
        vm.warp(s + D + 5 + W);
        vm.roll(block.number + 1);
        uint256 g0 = gasleft();
        tr.checkpoint(id);
        console.log("settle gas (7 pools, 5 lanes):", g0 - gasleft());
    }

    function _phaseCheckScores() internal view {
        uint256 id = raceId;
        int256[7] memory mv;
        for (uint256 i; i < nPools; ++i) {
            mv[i] = int256(tr.poolInfo(i).sign) * (int256(afterT[i]) - int256(before[i])) * 1e6;
        }
        assertEq(tr.laneScore(id, 0), mv[0] * 60);
        assertEq(tr.laneScore(id, 1), mv[1] * 60);
        assertEq(tr.laneScore(id, 2), mv[2] * 60);
        assertEq(tr.laneScore(id, 3), mv[3] * 60);
        assertEq(tr.laneScore(id, 4), (mv[4] + mv[0] + mv[5] + mv[6] + mv[0]) * 60 / 3);
        for (uint256 l; l < 5; ++l) console.logInt(tr.laneScore(id, l));
        TrendRace.Race memory r = tr.race(id);
        assertEq(uint8(r.status), uint8(TrendRace.Status.Settled));
        assertEq(r.winners, 2, "BTC lane wins");
        assertEq(r.winningStake, 0.6 ether);
    }

    function _phaseClaims() internal {
        uint256 id = raceId;
        address op = cfg.readAddress(".operator");
        uint256 b0 = agentOwner.balance;
        vm.prank(agentOwner);
        tr.claim(id);
        uint256 gross = uint256(0.2 ether) * 1.75 ether / 0.6 ether;
        assertEq(agentOwner.balance - b0, gross - gross * 250 / 10_000);
        b0 = ps[1].balance;
        vm.prank(ps[1]);
        tr.claim(id);
        uint256 g1 = uint256(0.25 ether) * 1.75 ether / 0.6 ether;
        assertEq(ps[1].balance - b0, g1 - g1 * 400 / 10_000);
        vm.prank(ps[5]);
        tr.claim(id);
        vm.prank(ps[0]);
        vm.expectRevert(TrendRace.NothingToPay.selector);
        tr.claim(id);
        tr.sweepDust(id);
        assertEq(address(tr).balance, tr.feesAccrued());
        address owner = cfg.readAddress(".owner");
        uint256 f = tr.feesAccrued();
        vm.prank(op);
        vm.expectRevert(TrendRace.NotOwner.selector);
        tr.withdrawFees(f);
        uint256 o0 = owner.balance;
        vm.prank(owner);
        tr.withdrawFees(f);
        assertEq(owner.balance - o0, f);
        assertEq(address(tr).balance, 0);
    }

    function test_fork_missedSettle_refund() public {
        if (block.chainid != 56) return;
        address op = cfg.readAddress(".operator");
        (bytes32[] memory names, uint16[][] memory a, uint16[][] memory b) = _lanes();
        vm.prank(op);
        uint256 id = tr.createRace(uint64(block.timestamp + 1 hours), names, a, b);
        address x = makeAddr("x");
        address y = makeAddr("y");
        vm.deal(x, 1 ether);
        vm.deal(y, 1 ether);
        vm.prank(x);
        tr.enter{value: 0.5 ether}(id, 0);
        vm.prank(y);
        tr.enter{value: 0.3 ether}(id, 4);
        uint256 s = tr.race(id).start;
        vm.warp(s);
        tr.checkpoint(id);
        vm.warp(s + W);
        tr.checkpoint(id);
        vm.warp(s + D);
        tr.checkpoint(id);
        vm.warp(s + D + W + 30 minutes + 1); // keeper dead past the grace
        vm.prank(y);
        tr.cancelStale(id);
        vm.prank(x);
        tr.refund(id);
        vm.prank(y);
        tr.refund(id);
        assertEq(x.balance, 1 ether);
        assertEq(y.balance, 1 ether);
        assertEq(address(tr).balance, 0);
    }
}
