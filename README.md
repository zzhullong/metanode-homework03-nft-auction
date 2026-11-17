# NFT 拍卖市场（Foundry 版）

MetaNodeAcademy LearningRoadmap `contract/homework03` 的实现：ERC721 NFT + 支持 ETH / ERC20 出价、通过 Chainlink 价格预言机折算 USD 比较的拍卖市场，拍卖合约采用 UUPS 可升级代理。

仓库：https://github.com/zzhullong/metanode-homework03-nft-auction

> 作业原文要求 Hardhat；本项目按确认改用纯 Foundry，功能与交付物一一对应。

设计文档：`docs/superpowers/specs/2026-11-16-nft-auction-design.md`

## 与作业要求的对应关系

| 作业要求 | 实现位置 | 对应测试 |
| --- | --- | --- |
| ERC721 NFT（铸造、转移、tokenURI） | [src/MetaNFT.sol](src/MetaNFT.sol) | [test/MetaNFT.t.sol](test/MetaNFT.t.sol)（5 个用例） |
| 拍卖上架，NFT 托管进合约 | `createAuction`（[src/NFTAuction.sol:165](src/NFTAuction.sol#L165)） | `test_CreateAuction_*`（6 个） |
| ETH / ERC20 双币种出价，统一折算 USD 比价 | `bid`、`bidWithERC20`（[src/NFTAuction.sol:210](src/NFTAuction.sol#L210)） | `test_Bid_*`（11 个，含 `test_Bid_CrossCurrencyUsdComparison`） |
| Chainlink 预言机折算 + 陈旧校验 | `getUsdValue`、`setPriceFeed`（[src/NFTAuction.sol:388](src/NFTAuction.sol#L388)） | `test_GetUsdValue_*`（5 个） |
| 拉取式退款 / 货款 / 平台费 | `withdrawRefund` / `withdrawProceeds` / `withdrawFees`（[src/NFTAuction.sol:283](src/NFTAuction.sol#L283)） | `test_Withdraw*`（5 个） |
| 结算并交付 NFT | `settle`（[src/NFTAuction.sol:347](src/NFTAuction.sol#L347)） | `test_Settle_*`（4 个） |
| UUPS 可升级代理 | [src/NFTAuction.sol:21](src/NFTAuction.sol#L21) + [script/Upgrade.s.sol](script/Upgrade.s.sol) | `test_Upgrade_*`（2 个）+ 集成测试中的升级用例 |
| 动态手续费（按成交额分档） | [src/NFTAuctionV2.sol:100](src/NFTAuctionV2.sol#L100) `getFeeBps` | [test/NFTAuctionV2.t.sol](test/NFTAuctionV2.t.sol)（13 个用例） |
| 部署脚本与测试网部署 | [script/Deploy.s.sol](script/Deploy.s.sol)、[script/Upgrade.s.sol](script/Upgrade.s.sol) | 已部署并升级至 V2，地址见下方「Sepolia 部署」 |
| 测试报告与覆盖率 | — | [docs/test-report.md](docs/test-report.md)（`src/` 行覆盖 99.56%） |

## 当前状态：已实现并通过本地测试

- 全部合约功能已实现：上架托管、ETH/ERC20 双币种出价、Chainlink USD 折算与陈旧校验、拉取式退款/货款/平台费、UUPS 升级、V2 分档动态手续费。
- 测试：`forge test` 共 66 个用例，**全部通过**（配置 `SEPOLIA_RPC_URL` 后 fork 用例不再跳过，已对 Sepolia 真实 ETH/USD feed 跑通）。
- 覆盖率：`src/` 行覆盖 99.6%（`NFTAuction` 99.3%、`NFTAuctionV2` 100%、`MetaNFT` 与 mocks 100%）；详见 `docs/test-report.md`。
- **已部署到 Sepolia、升级至 V2，并在 Etherscan 完成源码验证**，地址与验证链接见下方「Sepolia 部署」。

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
├── NFTAuction.t.sol            拍卖单元测试（38 个用例）
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
git clone --recursive git@github.com:zzhullong/metanode-homework03-nft-auction.git
# 已 clone 过的仓库请同步子模块（OZ 已由 v5.4.0 升级到 v5.7.0，不同步会找不到 import）
git submodule update --init --recursive

forge build                  # 编译全部合约
forge test                   # 66 通过（fork 用例需 SEPOLIA_RPC_URL，未配置时自动跳过）
forge coverage --report summary
forge fmt
```

依赖版本：forge-std v1.17.0、OpenZeppelin v5.7.0、Solidity 0.8.38（源码 `pragma` 固定为 `0.8.38`）。OZ v5.5+ 不再提供 `ReentrancyGuardUpgradeable`，本项目改用核心包的 `@openzeppelin/contracts/utils/ReentrancyGuard.sol`（同为 ERC-7201 命名空间存储，无需初始化调用）。

若本机已有 solc、不想让 Foundry 联网下载编译器：在本地 `.env` 里写 `FOUNDRY_PROFILE=local`，并把 `foundry.toml` 中 `[profile.local].solc` 指向本机 solc 路径（本项目已指向 `~/.local/bin/solc`）。

## 本地部署

```bash
anvil
PRIVATE_KEY=<anvil 私钥> forge script script/Deploy.s.sol \
  --rpc-url http://127.0.0.1:8545 --broadcast
```

产物写入 `deployments/local.json`。

### 本地演示页

`demo/` 提供一个纯浏览器操作页面：本地链模式下可创建拍卖、出价、结算、提取，Sepolia 模式只读查看真实部署状态。无需 MetaMask、无需外网（ethers 本地 vendor）。

```bash
python3 -m http.server 5173 --bind 127.0.0.1   # 仓库根目录执行
# 浏览器打开 http://127.0.0.1:5173/demo/
```

启动步骤与演示剧本见 [demo/README.md](demo/README.md)；纯逻辑单测：`node --test demo/lib.test.mjs`。

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

4. 地址记录在 `deployments/sepolia.json`，并同步到下方表格。

### 已部署地址（Sepolia，chainId 11155111）

| 合约 | 地址 | Etherscan |
| --- | --- | --- |
| **NFTAuction 代理（交互用这个）** | `0x9D6f4d339A62A351858cd28A5E550A03cb3739C6` | [查看](https://sepolia.etherscan.io/address/0x9D6f4d339A62A351858cd28A5E550A03cb3739C6#code) |
| V1 实现 | `0x94ED19b9277A34055FEF762F3303F41fE0EbFB95` | [查看](https://sepolia.etherscan.io/address/0x94ED19b9277A34055FEF762F3303F41fE0EbFB95#code) |
| V2 实现（当前生效） | `0x242904fe2BbC187D710289d7d202314273d10A7D` | [查看](https://sepolia.etherscan.io/address/0x242904fe2BbC187D710289d7d202314273d10A7D#code) |
| MetaNFT | `0xb944977eb0929fCEC867d10AA17eA0973fC3489a` | [查看](https://sepolia.etherscan.io/address/0xb944977eb0929fCEC867d10AA17eA0973fC3489a#code) |
| MockUSDC（6 位小数） | `0xc58EF42d22379F0352F9770f373A3fddDc69C810` | [查看](https://sepolia.etherscan.io/address/0xc58EF42d22379F0352F9770f373A3fddDc69C810#code) |
| ETH/USD feed（官方 Chainlink） | `0x694AA1769357215DE4FAC081bf1f309aDC325306` | [查看](https://sepolia.etherscan.io/address/0x694AA1769357215DE4FAC081bf1f309aDC325306) |
| USDC/USD feed（自部署 mock） | `0x2D1F4D6D5661ead9da7A76F506ef74D9E8AAa256` | [查看](https://sepolia.etherscan.io/address/0x2D1F4D6D5661ead9da7A76F506ef74D9E8AAa256#code) |

以上 6 个自部署合约均已在 Etherscan 完成源码验证。

部署者 / owner / feeRecipient：`0x669A0F2529889989971d746acEC08339A02006de`（演示用钱包，仅持有测试币）

Sepolia 上 ETH/USD 使用官方 Chainlink feed（`0x694AA1769357215DE4FAC081bf1f309aDC325306`），MockUSDC 使用自部署 `MockV3Aggregator`（`updatedAt = block.timestamp`）。接入真实 ERC20 时 owner 调用 `setPriceFeed` 换成官方 feed 即可。

## 测试报告

见 `docs/test-report.md`（实现完成后运行 `forge test -vv` 与 `forge coverage --report summary` 填写）。
