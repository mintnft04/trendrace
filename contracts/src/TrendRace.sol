// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev Minimal PancakeSwap V3 / Uniswap V3 pool surface used by TrendRace.
interface IV3Pool {
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
    function liquidity() external view returns (uint128);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IERC721OwnerOf {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @title TrendRace — daily parimutuel race between token-basket "lanes" on BNB Smart Chain.
/// @notice Players stake BNB on the lane they think rises most over one race. The result is computed
///         in-contract from PancakeSwap V3 time-weighted average ticks. Nobody (operator, keeper, owner)
///         can choose the winner or move player stakes. Anyone may call the checkpoint / cancel functions.
/// @dev Price measurement: each race has 4 checkpoints, each recording every pool's tick cumulative *at the
///      moment of the call* (observe([0]), which works with any observation cardinality and cannot be moved by a
///      swap in the same block):
///        cp0 at `start`             -> cp1 at cp0 + TWAP_WINDOW   => start TWAP = (cum1-cum0)/(t1-t0)
///        cp2 at `start + DURATION`  -> cp3 at cp2 + TWAP_WINDOW   => end   TWAP = (cum3-cum2)/(t3-t2)
///      Each checkpoint must happen within CHECKPOINT_GRACE of its earliest time, otherwise the race is cancelled
///      (100% refunds). Entries close at `start`, i.e. before the start TWAP window opens.
contract TrendRace is ReentrancyGuard {
    // ------------------------------------------------------------------ constants
    uint16 public constant MAX_FEE_BPS = 500; // hard cap 5%
    uint256 public constant MAX_POOL_CAP = 20 ether; // hard max for the per-race stake cap
    uint256 public constant MIN_ENTRY_FLOOR = 0.001 ether;
    uint256 public constant POOL_TIMELOCK = 24 hours; // delay before a proposed pool can be used
    uint256 public constant MAX_LEAD = 7 days; // how far ahead a race may be created
    uint8 public constant MAX_LANES = 6;
    uint8 public constant MAX_TOKENS_PER_LANE = 5;
    uint8 public constant MAX_RACE_POOLS = 16;
    uint16 public constant NO_POOL = type(uint16).max;
    uint256 internal constant SCORE_SCALE = 1e6; // avg ticks are stored in micro-ticks
    uint256 internal constant LCM = 60; // lcm(1..6): lane mean is exact
    uint256 internal constant ORACLE_CALL_GAS = 150_000;

    // ------------------------------------------------------------------ immutables / roles
    address public immutable OWNER; // only withdraws accrued fees and replaces the operator
    uint256 public immutable RACE_DURATION;
    uint256 public immutable TWAP_WINDOW;
    uint256 public immutable CHECKPOINT_GRACE;
    address public operator;
    /// @notice Optional ERC-721 Agent ID registry for the fee discount. address(0) = discount off.
    ///         Entry NEVER depends on it: any wallet can enter any race without an Agent ID.
    address public agentRegistry;

    // ------------------------------------------------------------------ parameters (future races only)
    uint16 public feeBps = 400;
    uint16 public agentFeeBps = 250;
    uint256 public minEntry = 0.005 ether;
    uint256 public poolCap = 2 ether;
    bool public entriesPaused;

    uint256 public feesAccrued;

    // ------------------------------------------------------------------ pool registry
    struct PoolInfo {
        address pool;
        address tracked; // token whose price is tracked
        address quote; // the other token of the pool
        int8 sign; // +1 if tracked is token0 (tick up = tracked up), -1 otherwise
        uint64 activeAt; // usable in races created at/after this time
        bool removed;
        uint128 minLiquidity; // in-range liquidity required at every checkpoint
    }

    PoolInfo[] internal _pools;
    mapping(address => bool) public isUsdQuote;

    // ------------------------------------------------------------------ races
    enum Status {
        None,
        Open,
        Cancelled,
        Settled
    }

    struct Race {
        uint64 start;
        uint16 feeBps;
        uint16 agentFeeBps;
        Status status;
        uint8 laneCount;
        uint8 phase; // number of checkpoints taken (0..4)
        uint8 winners; // bitmask of winning lanes
        uint8 poolCount;
        uint128 cap;
        uint128 totalStake;
        uint128 winningStake;
        uint128 claimedWinStake;
        uint128 paidGross;
        bool dustSwept;
    }

    struct Player {
        uint128 total;
        uint16 fee;
        bool entered;
        bool done; // claimed or refunded
        bool usedAgent;
        uint256 agentId;
    }

    uint256 public raceCount;
    mapping(uint256 => Race) internal _races;
    mapping(uint256 => uint16[]) internal _racePools; // registry ids, unique per race
    mapping(uint256 => uint64[4]) internal _cpTime;
    mapping(uint256 => mapping(uint256 => int56[4])) internal _cum; // race => race-pool index => cumulative per cp
    mapping(uint256 => mapping(uint256 => bytes32)) public laneName;
    mapping(uint256 => mapping(uint256 => bytes)) internal _laneLegs; // 2 bytes per token: (leg A, leg B) race-pool idx, 0xff = none
    mapping(uint256 => mapping(uint256 => uint256)) public laneStake;
    mapping(uint256 => mapping(uint256 => int256)) public laneScore;
    mapping(uint256 => mapping(address => mapping(uint256 => uint256))) public stakeOf;
    mapping(uint256 => mapping(address => Player)) internal _players;
    mapping(uint256 => mapping(uint256 => address)) public agentIdUsedBy;

    // ------------------------------------------------------------------ events
    event OperatorChanged(address indexed operator);
    event ParamsChanged(uint16 feeBps, uint16 agentFeeBps, uint256 minEntry, uint256 poolCap);
    event EntriesPaused(bool paused);
    event AgentRegistryChanged(address registry);
    event PoolProposed(uint256 indexed id, address indexed pool, address tracked, address quote, uint128 minLiquidity, uint64 activeAt);
    event PoolRemoved(uint256 indexed id);
    event RaceCreated(uint256 indexed raceId, uint64 start, uint8 laneCount, uint16 feeBps, uint16 agentFeeBps, uint128 cap);
    event Entered(uint256 indexed raceId, address indexed player, uint8 lane, uint256 amount, uint16 fee, uint256 agentId, bool usedAgent);
    event Checkpoint(uint256 indexed raceId, uint8 phase, uint64 time);
    event Settled(uint256 indexed raceId, uint8 winners, uint256 totalStake, uint256 winningStake);
    event Cancelled(uint256 indexed raceId, uint8 reason);
    event Claimed(uint256 indexed raceId, address indexed player, uint256 gross, uint256 fee, uint256 payout);
    event Refunded(uint256 indexed raceId, address indexed player, uint256 amount);
    event DustSwept(uint256 indexed raceId, uint256 amount);
    event FeesWithdrawn(uint256 amount);

    // cancel reasons
    uint8 public constant CANCEL_BY_OPERATOR_BEFORE_START = 1;
    uint8 public constant CANCEL_FEWER_THAN_TWO_LANES = 2;
    uint8 public constant CANCEL_CHECKPOINT_MISSED = 3;
    uint8 public constant CANCEL_ORACLE_FAILED = 4;
    uint8 public constant CANCEL_LOW_LIQUIDITY = 5;
    uint8 public constant CANCEL_NO_WINNER_STAKE = 6;

    // ------------------------------------------------------------------ errors
    error NotOperator();
    error NotOwner();
    error BadParam();
    error BadPool();
    error BadRace();
    error EntryClosed();
    error TooSmall();
    error CapExceeded();
    error NotYet();
    error NothingToPay();
    error TransferFailed();
    error InsufficientGas();

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != OWNER) revert NotOwner();
        _;
    }

    struct InitPool {
        address pool;
        address tracked;
        uint128 minLiquidity;
    }

    /// @param initialPools pools usable immediately (published at deploy); later additions are timelocked 24h.
    constructor(
        address owner_,
        address operator_,
        address agentId_,
        uint256 raceDuration_,
        uint256 twapWindow_,
        uint256 checkpointGrace_,
        address[] memory usdQuotes,
        InitPool[] memory initialPools
    ) {
        if (owner_ == address(0) || operator_ == address(0)) revert BadParam();
        if (twapWindow_ < 60 || checkpointGrace_ < 60) revert BadParam();
        if (raceDuration_ < 2 * (twapWindow_ + checkpointGrace_)) revert BadParam();
        OWNER = owner_;
        operator = operator_;
        agentRegistry = agentId_;
        RACE_DURATION = raceDuration_;
        TWAP_WINDOW = twapWindow_;
        CHECKPOINT_GRACE = checkpointGrace_;
        for (uint256 i; i < usdQuotes.length; ++i) {
            isUsdQuote[usdQuotes[i]] = true;
        }
        for (uint256 i; i < initialPools.length; ++i) {
            _addPool(initialPools[i].pool, initialPools[i].tracked, initialPools[i].minLiquidity, uint64(block.timestamp));
        }
        emit OperatorChanged(operator_);
    }

    /// @dev No plain BNB transfers: every wei in the contract is a stake or accrued fee.
    receive() external payable {
        revert BadParam();
    }

    // ================================================================== owner
    function setOperator(address op) external onlyOwner {
        if (op == address(0)) revert BadParam();
        operator = op;
        emit OperatorChanged(op);
    }

    function withdrawFees(uint256 amount) external onlyOwner nonReentrant {
        if (amount == 0 || amount > feesAccrued) revert BadParam();
        feesAccrued -= amount;
        emit FeesWithdrawn(amount);
        _send(OWNER, amount);
    }

    // ================================================================== operator config
    function setParams(uint16 fee_, uint16 agentFee_, uint256 minEntry_, uint256 poolCap_) external onlyOperator {
        if (fee_ > MAX_FEE_BPS || agentFee_ > fee_) revert BadParam();
        if (minEntry_ < MIN_ENTRY_FLOOR || poolCap_ > MAX_POOL_CAP || poolCap_ < minEntry_) revert BadParam();
        feeBps = fee_;
        agentFeeBps = agentFee_;
        minEntry = minEntry_;
        poolCap = poolCap_;
        emit ParamsChanged(fee_, agentFee_, minEntry_, poolCap_);
    }

    /// @notice Pauses NEW entries only. Checkpoints, settlement, claims and refunds can never be paused.
    function setEntriesPaused(bool p) external onlyOperator {
        entriesPaused = p;
        emit EntriesPaused(p);
    }

    /// @notice Set (or clear with address(0)) the optional Agent ID registry used for the fee discount.
    function setAgentRegistry(address registry) external onlyOperator {
        agentRegistry = registry;
        emit AgentRegistryChanged(registry);
    }

    function proposePool(address pool, address tracked, uint128 minLiquidity) external onlyOperator returns (uint256 id) {
        id = _addPool(pool, tracked, minLiquidity, uint64(block.timestamp + POOL_TIMELOCK));
    }

    /// @notice Removal only affects races created afterwards; a running race keeps its pools.
    function removePool(uint256 id) external onlyOperator {
        if (id >= _pools.length) revert BadParam();
        _pools[id].removed = true;
        emit PoolRemoved(id);
    }

    function _addPool(address pool, address tracked, uint128 minLiquidity, uint64 activeAt) internal returns (uint256 id) {
        if (pool.code.length == 0 || minLiquidity == 0) revert BadPool();
        address t0 = IV3Pool(pool).token0();
        address t1 = IV3Pool(pool).token1();
        int8 sign;
        address quote;
        if (tracked == t0) {
            sign = 1;
            quote = t1;
        } else if (tracked == t1) {
            sign = -1;
            quote = t0;
        } else {
            revert BadPool();
        }
        id = _pools.length;
        if (id >= NO_POOL) revert BadPool();
        _pools.push(PoolInfo(pool, tracked, quote, sign, activeAt, false, minLiquidity));
        emit PoolProposed(id, pool, tracked, quote, minLiquidity, activeAt);
    }

    function _usable(uint256 id) internal view returns (bool) {
        if (id >= _pools.length) return false;
        PoolInfo storage p = _pools[id];
        return !p.removed && p.activeAt <= block.timestamp;
    }

    // ================================================================== race creation
    /// @param legA  per lane, per token: registry id of the token's main pool
    /// @param legB  per lane, per token: registry id of the conversion pool (quote -> USD) or NO_POOL if the
    ///              main pool is already USD-quoted.
    function createRace(uint64 start, bytes32[] calldata names, uint16[][] calldata legA, uint16[][] calldata legB)
        external
        onlyOperator
        returns (uint256 raceId)
    {
        uint256 lanes = names.length;
        if (lanes < 2 || lanes > MAX_LANES || legA.length != lanes || legB.length != lanes) revert BadParam();
        if (start <= block.timestamp || start > block.timestamp + MAX_LEAD) revert BadParam();

        raceId = ++raceCount;
        Race storage r = _races[raceId];
        r.start = start;
        r.feeBps = feeBps;
        r.agentFeeBps = agentFeeBps;
        r.status = Status.Open;
        r.laneCount = uint8(lanes);
        r.cap = uint128(poolCap);

        uint16[] storage rp = _racePools[raceId];
        for (uint256 l; l < lanes; ++l) {
            uint256 n = legA[l].length;
            if (n == 0 || n > MAX_TOKENS_PER_LANE || legB[l].length != n) revert BadParam();
            bytes memory legs = new bytes(2 * n);
            for (uint256 t; t < n; ++t) {
                uint16 a = legA[l][t];
                uint16 b = legB[l][t];
                if (!_usable(a)) revert BadPool();
                PoolInfo storage pa = _pools[a];
                if (isUsdQuote[pa.quote]) {
                    if (b != NO_POOL) revert BadPool();
                } else {
                    if (b == NO_POOL || !_usable(b)) revert BadPool();
                    PoolInfo storage pb = _pools[b];
                    if (pb.tracked != pa.quote || !isUsdQuote[pb.quote]) revert BadPool();
                }
                legs[2 * t] = bytes1(_racePoolIndex(rp, a));
                legs[2 * t + 1] = b == NO_POOL ? bytes1(0xff) : bytes1(_racePoolIndex(rp, b));
            }
            laneName[raceId][l] = names[l];
            _laneLegs[raceId][l] = legs;
        }
        r.poolCount = uint8(rp.length);
        emit RaceCreated(raceId, start, uint8(lanes), r.feeBps, r.agentFeeBps, r.cap);
    }

    function _racePoolIndex(uint16[] storage rp, uint16 id) internal returns (uint8) {
        uint256 len = rp.length;
        for (uint256 i; i < len; ++i) {
            if (rp[i] == id) return uint8(i);
        }
        if (len >= MAX_RACE_POOLS) revert BadParam();
        rp.push(id);
        return uint8(len);
    }

    /// @notice Operator may void a race only before it starts (no price information exists yet). Full refunds.
    function cancelBeforeStart(uint256 raceId) external onlyOperator {
        Race storage r = _races[raceId];
        if (r.status != Status.Open || block.timestamp >= r.start) revert BadRace();
        _cancel(raceId, r, CANCEL_BY_OPERATOR_BEFORE_START);
    }

    // ================================================================== entries
    function enter(uint256 raceId, uint8 lane) external payable nonReentrant {
        Player storage p = _players[raceId][msg.sender];
        Race storage r = _races[raceId];
        if (!p.entered) {
            p.entered = true;
            p.fee = r.feeBps;
        }
        _enter(raceId, r, p, lane);
    }

    /// @notice Optional discount path. Tries to apply the Agent ID discount on the wallet's FIRST entry in the race;
    ///         if the registry is unset, reverts, misbehaves, the caller does not own the id, or the id was already
    ///         used by another wallet in this race, the entry still goes through at the normal fee. Never blocks entry.
    ///         The fee is locked per wallet per race at its first entry; one Agent ID per wallet per race.
    function enterWithAgent(uint256 raceId, uint8 lane, uint256 agentId) external payable nonReentrant {
        Player storage p = _players[raceId][msg.sender];
        Race storage r = _races[raceId];
        if (!p.entered) {
            p.entered = true;
            p.fee = r.feeBps;
            if (agentIdUsedBy[raceId][agentId] == address(0) && _ownsAgent(msg.sender, agentId)) {
                agentIdUsedBy[raceId][agentId] = msg.sender;
                p.usedAgent = true;
                p.agentId = agentId;
                p.fee = r.agentFeeBps;
            }
        }
        _enter(raceId, r, p, lane);
    }

    uint256 internal constant AGENT_CALL_GAS = 60_000;

    /// @dev Bounded, non-reverting ownerOf check. Any failure => false (normal fee).
    function _ownsAgent(address who, uint256 agentId) internal view returns (bool) {
        address reg = agentRegistry;
        if (reg == address(0) || reg.code.length == 0) return false;
        (bool ok, bytes memory ret) =
            reg.staticcall{gas: AGENT_CALL_GAS}(abi.encodeWithSelector(IERC721OwnerOf.ownerOf.selector, agentId));
        if (!ok || ret.length < 32) return false;
        uint256 word;
        assembly {
            word := mload(add(ret, 32))
        }
        if (word >> 160 != 0) return false;
        return address(uint160(word)) == who;
    }

    function _enter(uint256 raceId, Race storage r, Player storage p, uint8 lane) internal {
        if (r.status != Status.Open || block.timestamp >= r.start || entriesPaused) revert EntryClosed();
        if (lane >= r.laneCount) revert BadParam();
        if (msg.value < minEntry) revert TooSmall();
        uint256 newTotal = uint256(r.totalStake) + msg.value;
        if (newTotal > r.cap) revert CapExceeded();
        r.totalStake = uint128(newTotal);
        p.total += uint128(msg.value);
        laneStake[raceId][lane] += msg.value;
        stakeOf[raceId][msg.sender][lane] += msg.value;
        emit Entered(raceId, msg.sender, lane, msg.value, p.fee, p.agentId, p.usedAgent);
    }

    // ================================================================== checkpoints / settlement (anyone)
    /// @notice Earliest time and deadline of the next checkpoint.
    function nextCheckpointWindow(uint256 raceId) public view returns (uint8 phase, uint256 earliest, uint256 deadline) {
        Race storage r = _races[raceId];
        phase = r.phase;
        uint64[4] storage t = _cpTime[raceId];
        if (phase == 0) earliest = r.start;
        else if (phase == 1) earliest = uint256(t[0]) + TWAP_WINDOW;
        else if (phase == 2) earliest = uint256(r.start) + RACE_DURATION;
        else if (phase == 3) earliest = uint256(t[2]) + TWAP_WINDOW;
        else return (phase, 0, 0);
        deadline = earliest + CHECKPOINT_GRACE;
    }

    /// @notice Records the next price checkpoint; the 4th checkpoint settles the race. Callable by anyone.
    ///         If the checkpoint deadline has passed, the race is cancelled instead (full refunds).
    function checkpoint(uint256 raceId) external {
        Race storage r = _races[raceId];
        if (r.status != Status.Open) revert BadRace();
        (uint8 phase, uint256 earliest, uint256 deadline) = nextCheckpointWindow(raceId);
        if (phase >= 4) revert BadRace();
        if (block.timestamp < earliest) revert NotYet();
        if (block.timestamp > deadline) {
            _cancel(raceId, r, CANCEL_CHECKPOINT_MISSED);
            return;
        }
        if (phase == 0 && _stakedLanes(raceId, r.laneCount) < 2) {
            _cancel(raceId, r, CANCEL_FEWER_THAN_TWO_LANES);
            return;
        }
        uint16[] storage rp = _racePools[raceId];
        uint256 n = rp.length;
        uint32[] memory ago = new uint32[](1);
        for (uint256 i; i < n; ++i) {
            PoolInfo storage pi = _pools[rp[i]];
            (bool ok, int56 cum, uint128 liq) = _read(pi.pool, ago);
            if (!ok) {
                _cancel(raceId, r, CANCEL_ORACLE_FAILED);
                return;
            }
            if (liq < pi.minLiquidity) {
                _cancel(raceId, r, CANCEL_LOW_LIQUIDITY);
                return;
            }
            _cum[raceId][i][phase] = cum;
        }
        _cpTime[raceId][phase] = uint64(block.timestamp);
        r.phase = phase + 1;
        emit Checkpoint(raceId, phase, uint64(block.timestamp));
        if (phase == 3) _settle(raceId, r);
    }

    /// @notice Cancels a race whose next checkpoint deadline has passed. Callable by anyone.
    function cancelStale(uint256 raceId) external {
        Race storage r = _races[raceId];
        if (r.status != Status.Open) revert BadRace();
        (uint8 phase,, uint256 deadline) = nextCheckpointWindow(raceId);
        if (phase >= 4 || block.timestamp <= deadline) revert NotYet();
        _cancel(raceId, r, CANCEL_CHECKPOINT_MISSED);
    }

    /// @dev Oracle read with a fixed gas stipend; caller must supply enough gas so that a failure is genuine
    ///      (prevents griefing a cancel by under-supplying gas).
    function _read(address pool, uint32[] memory ago) internal view returns (bool ok, int56 cum, uint128 liq) {
        if (gasleft() < (ORACLE_CALL_GAS * 64) / 63 + 20_000) revert InsufficientGas();
        try IV3Pool(pool).observe{gas: ORACLE_CALL_GAS}(ago) returns (int56[] memory c, uint160[] memory) {
            if (c.length != 1) return (false, 0, 0);
            cum = c[0];
        } catch {
            return (false, 0, 0);
        }
        if (gasleft() < (ORACLE_CALL_GAS * 64) / 63 + 20_000) revert InsufficientGas();
        try IV3Pool(pool).liquidity{gas: ORACLE_CALL_GAS}() returns (uint128 l) {
            liq = l;
        } catch {
            return (false, 0, 0);
        }
        ok = true;
    }

    function _stakedLanes(uint256 raceId, uint8 lanes) internal view returns (uint256 k) {
        for (uint256 l; l < lanes; ++l) {
            if (laneStake[raceId][l] > 0) ++k;
        }
    }

    /// @dev Pure function of recorded on-chain data.
    function _settle(uint256 raceId, Race storage r) internal {
        int256[] memory move = _moves(raceId, r.poolCount);
        uint8 lanes = r.laneCount;
        int256[] memory score = new int256[](lanes);
        int256 best = type(int256).min;
        for (uint256 l; l < lanes; ++l) {
            int256 s = _laneScore(raceId, l, move);
            score[l] = s;
            laneScore[raceId][l] = s;
            if (s > best) best = s;
        }
        uint8 winners;
        uint256 winStake;
        for (uint256 l; l < lanes; ++l) {
            if (score[l] == best) {
                winners |= uint8(1 << l);
                winStake += laneStake[raceId][l];
            }
        }
        r.winners = winners;
        if (winStake == 0) {
            _cancel(raceId, r, CANCEL_NO_WINNER_STAKE);
            return;
        }
        r.winningStake = uint128(winStake);
        r.status = Status.Settled;
        emit Settled(raceId, winners, r.totalStake, winStake);
    }

    /// @dev Per race-pool signed move of the tracked token: end TWAP tick - start TWAP tick, in micro-ticks.
    function _moves(uint256 raceId, uint256 n) internal view returns (int256[] memory move) {
        uint64[4] storage t = _cpTime[raceId];
        int256 dtS = int256(uint256(t[1] - t[0]));
        int256 dtE = int256(uint256(t[3] - t[2]));
        move = new int256[](n);
        uint16[] storage rp = _racePools[raceId];
        for (uint256 i; i < n; ++i) {
            int56[4] storage c = _cum[raceId][i];
            int256 avgS = (int256(c[1]) - int256(c[0])) * int256(SCORE_SCALE) / dtS;
            int256 avgE = (int256(c[3]) - int256(c[2])) * int256(SCORE_SCALE) / dtE;
            move[i] = int256(_pools[rp[i]].sign) * (avgE - avgS);
        }
    }

    /// @dev Equal-weight mean of the lane's token USD moves (token move = main leg + optional quote->USD leg), x60.
    function _laneScore(uint256 raceId, uint256 l, int256[] memory move) internal view returns (int256) {
        bytes storage legs = _laneLegs[raceId][l];
        uint256 nt = legs.length / 2;
        int256 sum;
        for (uint256 k; k < nt; ++k) {
            sum += move[uint8(legs[2 * k])];
            uint8 b = uint8(legs[2 * k + 1]);
            if (b != 0xff) sum += move[b];
        }
        return sum * int256(LCM) / int256(nt); // exact: nt divides 60
    }

    function _cancel(uint256 raceId, Race storage r, uint8 reason) internal {
        r.status = Status.Cancelled;
        emit Cancelled(raceId, reason);
    }

    // ================================================================== payouts (pull)
    function claimable(uint256 raceId, address who) public view returns (uint256 gross, uint256 fee, uint256 winStake) {
        Race storage r = _races[raceId];
        Player storage p = _players[raceId][who];
        if (r.status != Status.Settled || p.done) return (0, 0, 0);
        for (uint256 l; l < r.laneCount; ++l) {
            if (r.winners & (1 << l) != 0) winStake += stakeOf[raceId][who][l];
        }
        if (winStake == 0) return (0, 0, 0);
        gross = winStake * r.totalStake / r.winningStake;
        fee = gross * p.fee / 10_000;
    }

    function claim(uint256 raceId) external nonReentrant {
        Race storage r = _races[raceId];
        if (r.status != Status.Settled) revert BadRace();
        (uint256 gross, uint256 fee, uint256 winStake) = claimable(raceId, msg.sender);
        if (gross == 0) revert NothingToPay();
        _players[raceId][msg.sender].done = true;
        r.claimedWinStake += uint128(winStake);
        r.paidGross += uint128(gross);
        feesAccrued += fee;
        uint256 payout = gross - fee;
        emit Claimed(raceId, msg.sender, gross, fee, payout);
        _send(msg.sender, payout);
    }

    /// @notice 100% refund of a player's stake in a cancelled race. Never pausable.
    function refund(uint256 raceId) external nonReentrant {
        Race storage r = _races[raceId];
        if (r.status != Status.Cancelled) revert BadRace();
        Player storage p = _players[raceId][msg.sender];
        uint256 amount = p.total;
        if (amount == 0 || p.done) revert NothingToPay();
        p.done = true;
        emit Refunded(raceId, msg.sender, amount);
        _send(msg.sender, amount);
    }

    /// @notice After every winner has claimed, integer-division dust (a few wei) moves to fees. Anyone may call.
    function sweepDust(uint256 raceId) external {
        Race storage r = _races[raceId];
        if (r.status != Status.Settled || r.dustSwept || r.claimedWinStake != r.winningStake) revert NotYet();
        r.dustSwept = true;
        uint256 dust = uint256(r.totalStake) - r.paidGross;
        feesAccrued += dust;
        emit DustSwept(raceId, dust);
    }

    function _send(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    // ================================================================== views
    function poolCount() external view returns (uint256) {
        return _pools.length;
    }

    function poolInfo(uint256 id) external view returns (PoolInfo memory) {
        return _pools[id];
    }

    function race(uint256 raceId) external view returns (Race memory) {
        return _races[raceId];
    }

    function racePools(uint256 raceId) external view returns (uint16[] memory) {
        return _racePools[raceId];
    }

    function laneLegs(uint256 raceId, uint256 lane) external view returns (bytes memory) {
        return _laneLegs[raceId][lane];
    }

    function checkpointTimes(uint256 raceId) external view returns (uint64[4] memory) {
        return _cpTime[raceId];
    }

    function cumulatives(uint256 raceId, uint256 racePoolIdx) external view returns (int56[4] memory) {
        return _cum[raceId][racePoolIdx];
    }

    function player(uint256 raceId, address who) external view returns (Player memory) {
        return _players[raceId][who];
    }
}
