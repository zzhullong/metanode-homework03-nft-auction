# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

NFT 拍卖市场（MetaNodeAcademy contract/homework03）：ERC721 NFT 托管拍卖，支持 ETH / ERC20 双币种出价，经 Chainlink 预言机折算成 8 位小数 USD 统一比价；拍卖合约为 UUPS 可升级代理，V2 增加按成交额分档的动态平台费。**已部署到 Sepolia 并完成 Etherscan 源码验证**（地址见 `deployments/sepolia.json` 与 README）。

## 常用命令

```bash
forge build                          # 编译
forge test                           # 全部测试（无 SEPOLIA_RPC_URL 时 fork 用例自动跳过）
forge test --match-test test_Settle_TransfersNftToWinner -vv   # 单个用例
forge test --gas-report              # gas 报告
forge coverage --report summary      # 覆盖率
forge fmt                            # 格式化（提交前必须无 diff）
forge inspect NFTAuction storageLayout   # 存储布局对比（升级安全性检查）

# 本地链部署（地址确定性）
anvil --host 127.0.0.1 --port 8545 --chain-id 31337
PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast

# Sepolia 部署 / 升级（.env 提供 SEPOLIA_RPC_URL / PRIVATE_KEY / ETHERSCAN_API_KEY）
source .env && forge script script/Deploy.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast --verify
source .env && forge script script/Upgrade.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast --verify
# 注意：旧广播记录有未完成回执（如 RPC 限流）时会拒绝重新广播，需加 --start-fresh

# Etherscan 验证（构造器参数不可省，否则字节码比对失败）
forge verify-contract <MetaNFT地址> src/MetaNFT.sol:MetaNFT --chain sepolia --etherscan-api-key $ETHERSCAN_API_KEY
forge verify-contract <USDC地址> src/mocks/MockERC20.sol:MockERC20 --chain sepolia --etherscan-api-key $ETHERSCAN_API_KEY \
  --constructor-args $(cast abi-encode "constructor(string,string,uint8)" "Mock USD Coin" "mUSDC" 6)
forge verify-contract <feed地址> src/mocks/MockV3Aggregator.sol:MockV3Aggregator --chain sepolia --etherscan-api-key $ETHERSCAN_API_KEY \
  --constructor-args $(cast abi-encode "constructor(uint8,int256)" 8 100000000)
# ERC1967Proxy 的构造器参数 = (V1实现地址, initialize(deployer, deployer) 的 calldata)

# 演示页（本地链可交互，Sepolia 只读）
python3 -m http.server 5173 --bind 127.0.0.1   # 打开 http://127.0.0.1:5173/demo/

# 演示页纯逻辑单测
node --test demo/lib.test.mjs
```

`.env` 已 gitignore，含 `FOUNDRY_PROFILE=local`（用本机 `~/.local/bin/solc`，避免联网下载编译器）。

完整的知识点梳理与「业务难题 → 解决方案」对照表见 `docs/knowledge.md`。

## 关键约束（改代码前必读）

- **存储布局已冻结**：合约经 UUPS 代理部署在 Sepolia。`NFTAuction`（V1）的变量顺序绝不能改动；`NFTAuctionV2` 只能在末尾追加。改存储相关代码后必须 `forge inspect` 对比布局，并通过升级保留测试（`test_Upgrade_PreservesStorageAndSetsVersion`、`test_Integration_UpgradeMidAuctionPreservesStorage`）。
- **pragma 精确锁定 `0.8.38`**（不带 `^`），是有意为之，避免编译器漂移。
- **OZ 锁定 v5.7.0**（git 子模块）。注意 v5.5+ 已移除 `ReentrancyGuardUpgradeable`，本项目用核心包 `ReentrancyGuard`（同为 ERC-7201 槽，代理升级不错位）。clone 后需 `git submodule update --init --recursive`。
- **源码中的优化注释不可删**：`NFTAuction.sol` 的六处 gas 优化/安全加固保留着原写法注释与优化缘由（用户明确要求），修改这些函数时保留注释结构。
- 公开 RPC 偶尔失效时可用备选：`https://sepolia.gateway.tenderly.co`（当前 .env 默认 Infura，曾限流 429）。

## 架构

```
NFTAuction (V1, UUPS)  ──upgradeToAndCall──▶  NFTAuctionV2 (仅追加存储 + 分档费率)
```

- **双币种比价**：`getUsdValue(token, amount)` 经 Chainlink `latestRoundData` 折算 8 位 USD，含四重校验（answer>0 / 未陈旧 / 非未来时间戳 / 轮次完整）。
- **出价时冻结 USD**：`highestBidUsd` 在出价时写入，`settle` 不再读预言机——预言机故障不会卡死已结束的拍卖。
- **全拉取式资金流**：被超越出价 → `pendingRefunds`；卖家货款 → `pendingProceeds`；平台费 → `pendingFees`。结算只转移 NFT + 记账。
- **费率演进靠虚函数钩子**：V1 `_calculateFee` 恒 0；V2 覆写按 `highestBidUsd` 分档（<$1,000 → 2%，<$10,000 → 1.5%，其余 1%），`initializeV2` 用 `reinitializer(2)`。
- **结算用 `transferFrom` 而非 `safeTransferFrom`**（防买家合约缺回调卡死）；ETH 转账用 `Address.sendValue`（不用 2300 gas 的 transfer）。
- `demo/`：静态演示页（本地 vendor ethers v6），双模式——本地 anvil 完整交互 / Sepolia 只读；地址读 `deployments/*.json`。

## 已知设计取舍（不是 bug，勿"修复"）

- 无防狙击机制（末段出价延长属 V3 方向）。
- 恶意 NFT 合约可让 `settle` revert（未做 owner 逃生舱）。
- Sepolia 上的 MockUSDC 任何人可 mint（演示代币）。其 mock feed 的 `updatedAt` 停在部署时刻，**约 1 小时后 USDC 出价会 `StalePrice`**，刷新：`cast send <usdcFeed> "updateAnswer(int256)" 100000000 ...`；本地 anvil 推进时间后同理（演示页有「刷新预言机」按钮）。

## 提交规范

- 中文 commit message，说明"为什么"。
- `deployments/local.json` 与 broadcast 时间戳副本已 gitignore；`deployments/sepolia.json` 与各网络 `run-latest.json` 入库。
- 提交前跑 `forge fmt` 与 `forge test`（配置 RPC 时 66 用例应全绿）。
