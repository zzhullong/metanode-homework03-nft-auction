// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { NFTAuction } from "./NFTAuction.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title NFTAuction V2
/// @notice 在 V1 基础上加入“按成交金额分档的动态平台费”（作业可选挑战）。
/// @dev 升级安全性依赖两点：
///      1. 存储只在 V1 布局末尾追加，V1 的变量顺序和 Auction 结构体保持原样；
///      2. V2 不新增父合约（继承会改变线性化顺序、影响存储布局），只覆写 V1 的钩子函数。
contract NFTAuctionV2 is NFTAuction {
    // ---------------------------------------------------------------------
    // 存储追加（必须排在 V1 所有变量之后）
    // ---------------------------------------------------------------------

    uint256 public feeTier1CutoffUsd; // 成交额 < 该值 => 使用 feeTier1Bps（USD，8 位小数）
    uint256 public feeTier2CutoffUsd; // 成交额 < 该值 => 使用 feeTier2Bps
    uint16 public feeTier1Bps; // 第一档费率（basis points，200 = 2%）
    uint16 public feeTier2Bps; // 第二档费率
    uint16 public feeTier3Bps; // 第三档费率（超过第二档上限）
    uint16 public maxFeeBps; // 费率硬上限，防止 owner 配置出离谱的费用

    event FeeTiersUpdated(uint256 cutoff1Usd, uint256 cutoff2Usd, uint16 bps1, uint16 bps2, uint16 bps3);
    event MaxFeeBpsUpdated(uint16 maxFeeBps);

    error InvalidFeeTiers();
    error FeeAboveMaximum(uint16 bps);

    /// @notice 升级时一次性初始化 V2 的费率参数。
    /// @dev reinitializer(2) 会写入“版本 2 已初始化”的标记，只能执行一次，
    ///      同时不会与 V1 的 initializer(1) 冲突。
    /// @param cutoff1Usd 第一档上限（USD，8 位小数），默认 $1,000。
    /// @param cutoff2Usd 第二档上限，默认 $10,000。
    /// @param bps1 成交额低于第一档上限时的费率，默认 200 = 2%。
    /// @param bps2 成交额低于第二档上限时的费率，默认 150 = 1.5%。
    /// @param bps3 其余情况的费率，默认 100 = 1%。
    function initializeV2(uint256 cutoff1Usd, uint256 cutoff2Usd, uint16 bps1, uint16 bps2, uint16 bps3)
        external
        reinitializer(2)
    {
        // 分档必须单调递增，否则 getFeeBps 的分支会互相覆盖，费率不可预期。
        if (cutoff1Usd == 0 || cutoff2Usd <= cutoff1Usd) revert InvalidFeeTiers();

        // 费率上限 10%：升级初始化时同样受约束，避免部署脚本传入危险值。
        uint16 cap = 1000;
        if (bps1 > cap || bps2 > cap || bps3 > cap) revert FeeAboveMaximum(cap);

        feeTier1CutoffUsd = cutoff1Usd;
        feeTier2CutoffUsd = cutoff2Usd;
        feeTier1Bps = bps1;
        feeTier2Bps = bps2;
        feeTier3Bps = bps3;
        maxFeeBps = cap;

        emit FeeTiersUpdated(cutoff1Usd, cutoff2Usd, bps1, bps2, bps3);
        emit MaxFeeBpsUpdated(cap);
    }

    // ---------------------------------------------------------------------
    // owner 配置
    // ---------------------------------------------------------------------

    /// @notice 调整三档费率与两个分界点。
    function setFeeTiers(uint256 cutoff1Usd, uint256 cutoff2Usd, uint16 bps1, uint16 bps2, uint16 bps3)
        external
        onlyOwner
    {
        if (cutoff1Usd == 0 || cutoff2Usd <= cutoff1Usd) revert InvalidFeeTiers();

        // 以当前 maxFeeBps 为准逐个校验，任何一档越界都整体回滚。
        if (bps1 > maxFeeBps) revert FeeAboveMaximum(bps1);
        if (bps2 > maxFeeBps) revert FeeAboveMaximum(bps2);
        if (bps3 > maxFeeBps) revert FeeAboveMaximum(bps3);

        feeTier1CutoffUsd = cutoff1Usd;
        feeTier2CutoffUsd = cutoff2Usd;
        feeTier1Bps = bps1;
        feeTier2Bps = bps2;
        feeTier3Bps = bps3;

        emit FeeTiersUpdated(cutoff1Usd, cutoff2Usd, bps1, bps2, bps3);
    }

    /// @notice 调整费率硬上限。调低后不会自动修正已保存的费率档位，
    ///         但 getFeeBps 只读取档位值，因此建议同时调用 setFeeTiers 收敛。
    function setMaxFeeBps(uint16 maxFeeBps_) external onlyOwner {
        // 100% 是绝对上限；实际业务上限由 owner 自行设定得更低。
        if (maxFeeBps_ > 10_000) revert FeeAboveMaximum(10_000);
        maxFeeBps = maxFeeBps_;
        emit MaxFeeBpsUpdated(maxFeeBps_);
    }

    // ---------------------------------------------------------------------
    // 费率
    // ---------------------------------------------------------------------

    /// @notice 根据成交 USD 价值返回适用的费率（basis points）。
    /// @dev 分档依据是结算时记录下来的 highestBidUsd，结算过程完全不读预言机。
    function getFeeBps(uint256 highestBidUsd) public view returns (uint16) {
        if (highestBidUsd < feeTier1CutoffUsd) return feeTier1Bps;
        if (highestBidUsd < feeTier2CutoffUsd) return feeTier2Bps;
        return feeTier3Bps;
    }

    /// @dev 覆写 V1 钩子：费用在成交币种里计算（不是 USD 金额），
    ///      因此卖家与平台的待提取余额都能直接用原币种结算。
    ///      mulDiv 向下取整，产生的极小 dust 归卖家所有，不会凭空多出钱。
    function _calculateFee(uint256 highestBidUsd, uint256 amount) internal view override returns (uint256) {
        uint16 bps = getFeeBps(highestBidUsd);
        if (bps == 0) return 0;
        return Math.mulDiv(amount, bps, 10_000);
    }

    function getVersion() external pure override returns (string memory) {
        return "NFTAuction V2";
    }
}
