// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice TESTNET / TEST ONLY. Minimal ERC-721 ownerOf + transfer for Agent ID discount tests.
contract MockAgentID {
    mapping(uint256 => address) public ownerOf;
    uint256 public next = 1;

    function mint(address to) external returns (uint256 id) {
        id = next++;
        ownerOf[id] = to;
    }

    function transferFrom(address from, address to, uint256 id) external {
        require(ownerOf[id] == from && msg.sender == from, "auth");
        ownerOf[id] = to;
    }
}
