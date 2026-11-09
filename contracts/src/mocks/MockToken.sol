// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice TESTNET / TEST ONLY. Address placeholder for mock pool tokens.
contract MockToken {
    string public symbol;

    constructor(string memory s) {
        symbol = s;
    }
}
