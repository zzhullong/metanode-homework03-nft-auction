// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";

import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { MockV3Aggregator } from "../src/mocks/MockV3Aggregator.sol";

/// @dev 测试辅助合约（mocks）自身的行为测试，避免它们悄悄失真误导拍卖测试。
contract MocksTest is Test {
    address internal alice = makeAddr("alice");

    function test_MockERC20_MintAndBurn() public {
        MockERC20 token = new MockERC20("Mock", "MCK", 6);

        token.mint(alice, 1_000e6);
        assertEq(token.balanceOf(alice), 1_000e6);
        assertEq(token.decimals(), 6);

        token.burn(alice, 400e6);
        assertEq(token.balanceOf(alice), 600e6);
    }

    function test_MockV3Aggregator_ReportsRoundData() public {
        MockV3Aggregator feed = new MockV3Aggregator(8, 3000e8);

        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = feed.latestRoundData();
        assertEq(roundId, 1);
        assertEq(answer, 3000e8);
        assertEq(updatedAt, block.timestamp);
        assertEq(answeredInRound, roundId);
        assertEq(feed.decimals(), 8);
        assertEq(feed.description(), "MockV3Aggregator");
        assertEq(feed.version(), 0);
    }

    function test_MockV3Aggregator_UpdateAnswerBumpsRound() public {
        MockV3Aggregator feed = new MockV3Aggregator(8, 3000e8);

        vm.warp(block.timestamp + 1 hours);
        feed.updateAnswer(2500e8);

        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        assertEq(answer, 2500e8);
        assertEq(updatedAt, block.timestamp);
        assertEq(feed.roundId(), 2);
        assertEq(feed.answer(), 2500e8);
        assertEq(feed.updatedAt(), block.timestamp);
    }

    function test_MockV3Aggregator_GetRoundData() public {
        MockV3Aggregator feed = new MockV3Aggregator(8, 3000e8);

        (uint80 roundId, int256 answer,,,) = feed.getRoundData(42);
        assertEq(roundId, 42);
        assertEq(answer, 3000e8);
    }

    function test_MockV3Aggregator_SetUpdatedAtForStaleTests() public {
        MockV3Aggregator feed = new MockV3Aggregator(8, 3000e8);

        feed.setUpdatedAt(123);
        assertEq(feed.updatedAt(), 123);
    }
}
