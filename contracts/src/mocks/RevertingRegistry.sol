// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice TESTNET / TEST ONLY. Agent registry whose ownerOf always reverts.
contract RevertingRegistry {
    function ownerOf(uint256) external pure returns (address) {
        revert("registry down");
    }
}
