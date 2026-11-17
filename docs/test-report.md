# 测试报告

运行环境：Foundry 1.9.0 / solc 0.8.38 / macOS；本地测试日期 2026-11-16。

## 运行命令

```bash
forge test
forge coverage --report summary --report lcov
```

## 结果

| 项目 | 结果 |
| --- | --- |
| 测试用例 | 66 个（全部通过，含 Sepolia fork 用例） |
| fork 说明 | `NFTAuctionFork.t.sol` 需要 `SEPOLIA_RPC_URL`；未配置时自动 `vm.skip`，配置后读取 Sepolia 官方 ETH/USD feed |
| `src/` 行覆盖率 | **99.56%**（227/228） |
| `src/` 语句覆盖率 | 95.65%（242/253） |
| `src/` 分支覆盖率 | 80.00%（44/55） |
| `src/` 函数覆盖率 | 97.78%（44/45） |

### 覆盖率明细

| 文件 | 行 | 语句 | 分支 | 函数 |
| --- | --- | --- | --- | --- |
| `src/MetaNFT.sol` | 100% | 100% | 100% | 100% |
| `src/NFTAuction.sol` | 99.32% | 95.45% | 81.82% | 95.24% |
| `src/NFTAuctionV2.sol` | 100% | 94.12% | 70.00% | 100% |
| `src/mocks/MockERC20.sol` | 100% | 100% | N/A | 100% |
| `src/mocks/MockV3Aggregator.sol` | 100% | 100% | N/A | 100% |

> `script/*.s.sol` 为部署脚本，不参与单元测试覆盖统计；其正确性通过 `forge script` 本地 anvil 执行验证。

## 用例清单

### `test/MetaNFT.t.sol`（5）

铸造自增 id、tokenURI、零地址拒绝、转移、不存在的 token 查询失败。

### `test/NFTAuction.t.sol`（38）

- 初始化：owner/收款地址/默认陈旧阈值、不可重复初始化、实现合约被锁死。
- 上架：托管 NFT、事件、非 owner/未授权/零时长/零起拍价/零 NFT 地址拒绝。
- 出价：ETH 首拍记录 USD、低于起拍、未高于最高价、结束后出价、零出价、被超越记退款、ERC20 出价与拒绝、ETH 与 USDC 跨币种比较、ERC20 拍卖接受 ETH。
- 退款：ETH 退款、ERC20 退款、无可提取时 revert。
- 结算：NFT 归赢家、无出价退回卖家、未结束/重复结算拒绝、货款 ETH+ERC20 提取、无货款 revert。
- 预言机：6/18 位精度换算、未配置 feed、价格 ≤ 0、陈旧价格、owner 权限、feed decimals 归一化（18 位与 6 位）。
- 升级：非 owner 拒绝、升级后存储保留 + 版本号 + V2 费率可用。

### `test/NFTAuctionV2.t.sol`（13）

V2 初始化写入档位与费率上限、重复初始化拒绝、非法分档/超上限拒绝；分档边界（$1,000 / $10,000）；`setFeeTiers` / `setMaxFeeBps` 更新与校验、owner 权限；结算按档扣费（ETH 与 ERC20）、平台费提取、无可提取时 revert。

### `test/NFTAuctionIntegration.t.sol`（4）

- 双买家 ETH + USDC 全流程，退款、货款全部拉取完毕后合约余额归零。
- 拍卖进行中升级 V2，存储与出价数据完整保留。
- 升级后结算按 1.5% 扣费，卖家与平台分别提取。
- Fuzz：随机两笔 ETH 出价下资金守恒（约定 256 次运行）。

### `test/Mocks.t.sol`（5）

MockERC20 铸造/销毁、MockV3Aggregator 轮次数据、更新价格、历史轮次查询、设置 updatedAt。

### `test/NFTAuctionFork.t.sol`（1，默认跳过）

Sepolia 真实 ETH/USD feed 读取与 USD 换算；设置 `SEPOLIA_RPC_URL` 后执行。

## 测试输出（末尾摘要）

```text
Ran 6 test suites: 65 tests passed, 0 failed, 1 skipped (66 total tests)
```

## Sepolia 部署与 fork 测试（2026-11-17）

合约已部署到 Sepolia 并升级至 V2，完整地址见 `deployments/sepolia.json` 与 README。

| 项目 | 结果 |
| --- | --- |
| 网络 | Sepolia（chainId 11155111） |
| 拍卖代理（交互地址） | `0xB8322C97fDd3B005557DBe8384951E6456136E7b` |
| V1 实现 | `0xd2B3f7Db8eCC8985CA1fec0f29b5653e277334AC` |
| V2 实现（当前生效） | `0xe167d464Ca57941d41CAe259A87bDC967d935819` |
| MetaNFT | `0x1D2eb05E2AE0d15B2409FeE79b24d180c6EF0713` |
| MockUSDC | `0x5a691F296c80c1544a0519D9EA67F0bD8E069E68` |
| fork 测试 | `test_Fork_LiveEthUsdFeed` **PASS**（读取官方 ETH/USD feed `0x694AA176…5306` 折算 USD） |
| 升级后校验 | `getVersion() = "NFTAuction V2"`；费率 200/150/100 bps；分界点 $1,000 / $10,000 |
| 源码验证 | 6 个自部署合约（代理、V1/V2 实现、MetaNFT、MockUSDC、MockV3Aggregator）均已在 Etherscan 验证通过 |

> 部署时 Sepolia base fee 约 16 wei：9 笔部署交易 + 1 笔升级交易总计花费不足 0.001 ETH。
