# 本地演示页

用浏览器直接操作本地 anvil 链上的拍卖合约，不需要 MetaMask、不需要联网。

设计文档：`docs/superpowers/specs/2026-11-17-demo-ui-design.md`

## 启动

需要三个进程，都在仓库根目录执行：

```bash
# 1. 本地链
anvil --host 127.0.0.1 --port 8545 --chain-id 31337

# 2. 部署合约（另开一个终端）
PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast

# 3. 静态服务（另开一个终端）
python3 -m http.server 5173 --bind 127.0.0.1
```

浏览器打开 **http://127.0.0.1:5173/demo/**

页面每 3 秒自动刷新链上状态。

## 两种网络

页面顶部可以切换：

| 模式 | 用途 | 行为 |
| --- | --- | --- |
| **本地 anvil** | 完整交互演示 | 创建、出价、结算、提取、推进时间全部可用 |
| **Sepolia 测试网（只读）** | 展示真实部署 | 读取已部署的 V2 合约状态，**不发送任何交易**、不需要私钥；顶部「查看地址」用于查询任意地址的待提取余额 |

Sepolia 模式默认 RPC 是 `https://sepolia.gateway.tenderly.co`。若该节点不可用，在浏览器控制台执行：

```js
localStorage.setItem('demo.sepoliaRpc', '你的 Sepolia RPC URL');
```

刷新即可生效。切回本地模式：`localStorage.setItem('demo.network', 'local')` 后刷新，或直接用顶部下拉。

Sepolia 上目前 `nextAuctionId = 0`（还没创建过拍卖），所以只读页面会显示空列表。

## 四个演示账户

页面顶部下拉切换，私钥是 anvil 的公开测试密钥，仅用于本地链：

| 角色 | 地址 |
| --- | --- |
| 卖家 | `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` |
| 买家A | `0x70997970C51812dc3A010C7d01b50e0d17dc79C8` |
| 买家B | `0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC` |
| 平台收款 | `0x90F79bf6EB2c4f870365E785982E1f101E93b906` |

## 演示流程

1. **切到「卖家」** → 创建拍卖：tokenId 填 `1`，起拍价 `1000`，时长 `3600`，计价代币选 `ETH + USDC` → 点「创建拍卖」
   - 页面会自动先 `approve` 再 `createAuction`。**必须是 NFT 持有者**（卖家）操作，否则 approve 会失败。
2. **切到「买家A」** → 在拍卖卡片里填 ETH 数量 `1` → 点「出价」（按 $3000/ETH 折算成 $3,000）
3. **切到「买家B」** → 先点工具区的「领取 5000 测试 USDC」→ 再在卡片里填 USDC 数量 `4000` → 点「出价」（$4,000 反超，买家A 的出价进入待退款）
4. 点工具区的「**推进时间 +1 小时**」→ 卡片状态变为「已结束待结算」
5. 任意账户在卡片上点「**结算**」→ NFT 转给买家B
6. **切到「卖家」** → 底部「可提取」显示货款 4,000 USDC → 点「提取」
7. **切到「买家A」** → 「可提取」显示退款 1 ETH → 点「提取」

## 常见问题

**出价报 `StalePrice`**：MockV3Aggregator 的 `updatedAt` 停在部署时刻，合约要求价格不超过 1 小时。点工具区的「**刷新预言机**」即可（只更新时间戳，不改价格）。

**创建拍卖报 `NotTokenOwner` / approve 失败**：当前下拉选中的不是 NFT 持有者，切到「卖家」。

**页面显示「未找到 deployments/local.json」**：先跑部署脚本；或在页面上手动填写 5 个地址。

**页面显示「无法连接本地链」**：确认 anvil 在 8545 上运行。

## 单元测试

纯计算逻辑（金额格式化、倒计时等）有独立单测：

```bash
node --test demo/lib.test.mjs
```
