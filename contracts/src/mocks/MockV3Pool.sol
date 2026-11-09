// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice TESTNET / TEST ONLY. Scripted V3-style oracle: piecewise-constant tick, exact tick cumulatives.
contract MockV3Pool {
    address public immutable token0;
    address public immutable token1;
    address public immutable admin;
    int24 public tick;
    uint128 public liquidity;
    int56 public cumLast;
    uint32 public tLast;
    bool public broken;

    constructor(address t0, address t1, int24 tick_, uint128 liq) {
        (token0, token1) = t0 < t1 ? (t0, t1) : (t1, t0);
        admin = msg.sender;
        tick = tick_;
        liquidity = liq;
        tLast = uint32(block.timestamp);
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "admin");
        _;
    }

    function setTick(int24 t) external onlyAdmin {
        cumLast += int56(tick) * int56(uint56(uint32(block.timestamp) - tLast));
        tLast = uint32(block.timestamp);
        tick = t;
    }

    function setLiquidity(uint128 l) external onlyAdmin {
        liquidity = l;
    }

    function setBroken(bool b) external onlyAdmin {
        broken = b;
    }

    function observe(uint32[] calldata secondsAgos) external view returns (int56[] memory c, uint160[] memory s) {
        require(!broken, "OLD");
        c = new int56[](secondsAgos.length);
        s = new uint160[](secondsAgos.length);
        for (uint256 i; i < secondsAgos.length; ++i) {
            uint32 target = uint32(block.timestamp) - secondsAgos[i];
            require(target >= tLast, "OLD");
            c[i] = cumLast + int56(tick) * int56(uint56(target - tLast));
        }
    }
}
