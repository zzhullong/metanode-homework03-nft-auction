// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AggregatorV3Interface } from "../interfaces/AggregatorV3Interface.sol";

/// @notice Chainlink-compatible aggregator mock with settable answer and updatedAt.
contract MockV3Aggregator is AggregatorV3Interface {
    uint8 private immutable _decimals;
    int256 private _answer;
    uint256 private _updatedAt;
    uint80 private _roundId;

    constructor(uint8 decimals_, int256 initialAnswer) {
        _decimals = decimals_;
        _answer = initialAnswer;
        _updatedAt = block.timestamp;
        _roundId = 1;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function description() external pure override returns (string memory) {
        return "MockV3Aggregator";
    }

    function version() external pure override returns (uint256) {
        return 0;
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (_roundId, _answer, _updatedAt, _updatedAt, _roundId);
    }

    function getRoundData(uint80 roundId_) external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId_, _answer, _updatedAt, _updatedAt, roundId_);
    }

    /// @notice Sets the latest answer and refreshes updatedAt to the current block.
    function updateAnswer(int256 newAnswer) external {
        _answer = newAnswer;
        _updatedAt = block.timestamp;
        _roundId += 1;
    }

    /// @notice Backdates updatedAt so tests can exercise staleness checks.
    function setUpdatedAt(uint256 updatedAt_) external {
        _updatedAt = updatedAt_;
    }

    function roundId() external view returns (uint80) {
        return _roundId;
    }

    function answer() external view returns (int256) {
        return _answer;
    }

    function updatedAt() external view returns (uint256) {
        return _updatedAt;
    }
}
