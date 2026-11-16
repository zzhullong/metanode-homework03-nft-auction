# NFT 拍卖市场（Foundry 版）

MetaNodeAcademy LearningRoadmap `contract/homework03` 的实现：ERC721 NFT + 支持 ETH / ERC20 出价、通过 Chainlink 价格预言机折算 USD 比较的拍卖市场，拍卖合约采用 UUPS 可升级代理。

> 作业原文要求 Hardhat；本项目按确认改用纯 Foundry，功能与交付物一一对应。

设计文档：`docs/superpowers/specs/2026-11-16-nft-auction-design.md`

## 当前状态：已实现并通过本地测试

- 全部合约功能已实现：上架托管、ETH/ERC20 双币种出价、Chainlink USD 折算与陈旧校验、拉取式退款/货款/平台费、UUPS 升级、V2 分档动态手续费。
- 测试：`forge test` 共 66 个用例，65 通过、1 跳过（Sepolia fork 用例在未配置 RPC 时自动跳过）。
- 覆盖率：`src/` 行覆盖 99.6%（`NFTAuction` 99.3%、`NFTAuctionV2` 100%、`MetaNFT` 与 mocks 100%）；详见 `docs/test-report.md`。
- Sepolia 部署与验证待补（需要 RPC、私钥、Etherscan Key）。

实现要点（详见源码注释）：
- 上架是无需许可的：NFT 持有者授权后自行调用 `createAuction`，NFT 托管进拍卖合约。
- 出价只有两种入口：`bid()` 用 `msg.value`，`bidWithERC20()` 明确拒绝附带 ETH，避免金额歧义。
- 所有币种统一折算成 8 位小数 USD 比较；预言机答案必须为正、未陈旧、round 完整。
- 被超越的出价、卖家货款、平台费全部记账为「待提取」，由本人调用 `withdrawRefund` / `withdrawProceeds` / `withdrawFees` 拉取，结算不会因为收款方拒收而失败。
- NFT 交付使用 `transferFrom`，避免最高出价者是合约但未实现 `onERC721Received` 时拍卖永久卡死。
- V2 只在 V1 存储布局末尾追加变量，费率按成交 USD 价值分档，且在成交币种里扣费、不读预言机。

## 架构

```
src/
├── MetaNFT.sol                 ERC721 + 公开 mint(to, uri)
├── NFTAuction.sol              V1：托管上架、双币种出价、预言机折算、拉取式退款/货款、UUPS
├── NFTAuctionV2.sol            V2：追加存储 + 分档动态手续费
├── interfaces/AggregatorV3Interface.sol
└── mocks/
    ├── MockERC20.sol           可配 decimals 的 ERC20
    └── MockV3Aggregator.sol    Chainlink aggregator mock（可设 answer / updatedAt）
script/
├── Deploy.s.sol                部署 NFT + MockUSDC + feeds + 拍卖代理
└── Upgrade.s.sol               V1 → V2 升级并初始化费率
test/
├── MetaNFT.t.sol               NFT 单元测试（已实现）
├── NFTAuction.t.sol            拍卖单元测试（骨架）
├── NFTAuctionIntegration.t.sol 跨币种全流程 + 升级 + fuzz
└── NFTAuctionFork.t.sol        Sepolia fork（无 RPC 自动跳过）
```

关键设计：
- USD 统一 8 位小数；预言机读取校验 `answer > 0`、`updatedAt` 未超过 `maxOracleStaleness`（默认 1 小时）、`answeredInRound >= roundId`。
- 退款、卖家货款、平台费全部拉取式（pull-based），结算时不主动打款；NFT 交付用 `transferFrom` 而非 `safeTransferFrom`。
- 存储布局冻结：`NFTAuctionV2` 只在末尾追加，不改动 V1 变量与 `Auction` 结构体。
- 代理部署直接使用 `ERC1967Proxy`，升级走合约自带 `upgradeToAndCall`，不引入 FFI 插件。

## 快速开始

```bash
forge build                  # 编译全部合约
forge test                   # 65 通过 / 1 跳过（fork 用例需 SEPOLIA_RPC_URL）
forge coverage --report summary
forge fmt
```

依赖版本：forge-std v1.17.0、OpenZeppelin v5.4.0（v5.5+ 移除了 `ReentrancyGuardUpgradeable`，不要升级）、Solidity 0.8.38（源码 `pragma` 为 `^0.8.28`，0.8.28+ 均可编译）。

若本机已有 solc、不想让 Foundry 联网下载编译器：在本地 `.env` 里写 `FOUNDRY_PROFILE=local`，并把 `foundry.toml` 中 `[profile.local].solc` 指向本机 solc 路径（本项目已指向 `~/.local/bin/solc`）。

## 本地部署

```bash
anvil
PRIVATE_KEY=<anvil 私钥> forge script script/Deploy.s.sol \
  --rpc-url http://127.0.0.1:8545 --broadcast
```

产物写入 `deployments/local.json`。

## Sepolia 部署

1. 复制 `.env.example` 为 `.env` 并填写 `SEPOLIA_RPC_URL`、`PRIVATE_KEY`、`ETHERSCAN_API_KEY`、可选 `FEE_RECIPIENT`。
2. 部署 V1：

```bash
source .env
forge script script/Deploy.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast --verify
```

3. 升级到 V2：

```bash
forge script script/Upgrade.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast --verify
```

4. 地址记录在 `deployments/sepolia.json`，并同步到 README（待部署后填写）。

Sepolia 上 ETH/USD 使用官方 Chainlink feed（`0x694AA1769357215DE4FAC081bf1f309aDC325306`），MockUSDC 使用自部署 `MockV3Aggregator`（`updatedAt = block.timestamp`）。接入真实 ERC20 时 owner 调用 `setPriceFeed` 换成官方 feed 即可。

## 测试报告

见 `docs/test-report.md`（实现完成后运行 `forge test -vv` 与 `forge coverage --report summary` 填写）。
