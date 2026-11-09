// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TrendRaceTest} from "./TrendRace.t.sol";
import {TrendRace} from "../src/TrendRace.sol";

/// Flags referral tag: the site appends 20-byte referrer + 4-byte magic (0x7f1a6501) to enter/enterWithAgent calldata.
/// The deployed contract must ignore trailing calldata (abi decoding reads only the declared params).
contract TrailingCalldataTest is TrendRaceTest {
    bytes4 constant MAGIC = 0x7f1a6501;
    address constant REF = address(0x00000000000000000000000000000000DeaDBeef);

    function test_enter_withRefSuffix_succeeds() public {
        uint256 id = create4();
        bytes memory data = abi.encodePacked(abi.encodeCall(TrendRace.enter, (id, uint8(1))), REF, MAGIC);
        assertEq(data.length, 4 + 64 + 24);
        vm.prank(alice);
        (bool ok,) = address(tr).call{value: 0.01 ether}(data);
        assertTrue(ok, "enter with suffix reverted");
        assertEq(tr.stakeOf(id, alice, 1), 0.01 ether);
        assertEq(tr.laneStake(id, 1), 0.01 ether);
        assertEq(tr.race(id).totalStake, 0.01 ether);
    }

    function test_enterWithAgent_withRefSuffix_succeeds() public {
        uint256 id = create4();
        bytes memory data =
            abi.encodePacked(abi.encodeCall(TrendRace.enterWithAgent, (id, uint8(2), uint256(12345))), REF, MAGIC);
        vm.prank(bob);
        (bool ok,) = address(tr).call{value: 0.02 ether}(data);
        assertTrue(ok, "enterWithAgent with suffix reverted");
        assertEq(tr.stakeOf(id, bob, 2), 0.02 ether);
    }

    function test_suffix_samePayoutAsPlain() public {
        uint256 id = create4();
        vm.prank(alice);
        (bool ok,) = address(tr).call{value: 0.3 ether}(
            abi.encodePacked(abi.encodeCall(TrendRace.enter, (id, uint8(1))), REF, MAGIC)
        );
        assertTrue(ok);
        stake(carol, id, 0, 0.5 ether);
        runRace(id, 10, 200, 50, -30);
        (uint256 gross,,) = tr.claimable(id, alice);
        assertEq(gross, 0.8 ether);
    }

    function testFuzz_anySuffix(bytes calldata junk) public {
        vm.assume(junk.length < 200);
        uint256 id = create4();
        vm.prank(dave);
        (bool ok,) = address(tr).call{value: 0.005 ether}(
            abi.encodePacked(abi.encodeCall(TrendRace.enter, (id, uint8(3))), junk)
        );
        assertTrue(ok);
        assertEq(tr.stakeOf(id, dave, 3), 0.005 ether);
    }
}
