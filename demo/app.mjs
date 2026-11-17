import { formatUsd8, parseUsdTo8, remainingSeconds, formatDuration, shortAddr } from './lib.mjs';

const { ethers } = window;

const NETWORKS = {
  local: {
    label: '本地 anvil',
    rpc: 'http://127.0.0.1:8545',
    file: '../deployments/local.json',
    readOnly: false,
  },
  sepolia: {
    label: 'Sepolia 测试网',
    rpc: localStorage.getItem('demo.sepoliaRpc') || 'https://sepolia.gateway.tenderly.co',
    file: '../deployments/sepolia.json',
    readOnly: true,
  },
};

let network = localStorage.getItem('demo.network') || 'local';
if (!NETWORKS[network]) network = 'local';
const NET = NETWORKS[network];
const provider = new ethers.JsonRpcProvider(NET.rpc);
const ZERO = ethers.ZeroAddress;

// anvil 默认前 4 个账户的公开测试私钥，仅用于本地链
const ACCOUNTS = [
  { label: '卖家', key: '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80' },
  { label: '买家A', key: '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d' },
  { label: '买家B', key: '0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a' },
  { label: '平台收款', key: '0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6' },
];
ACCOUNTS.forEach((a) => {
  a.address = new ethers.Wallet(a.key).address;
});

const auctionAbi = [
  'function createAuction(address nft, uint256 tokenId, uint256 startingPriceUsd, uint256 duration, address paymentToken) returns (uint256)',
  'function bid(uint256 auctionId) payable',
  'function bidWithERC20(uint256 auctionId, uint256 amount)',
  'function settle(uint256 auctionId)',
  'function withdrawRefund(uint256 auctionId)',
  'function withdrawProceeds(address token)',
  'function withdrawFees(address token)',
  'function getVersion() view returns (string)',
  'function nextAuctionId() view returns (uint256)',
  'function pendingRefunds(uint256 auctionId, address bidder, address token) view returns (uint256)',
  'function pendingProceeds(address account, address token) view returns (uint256)',
  'function pendingFees(address account, address token) view returns (uint256)',
  'function getAuction(uint256 auctionId) view returns (tuple(address nft, address seller, uint256 tokenId, uint256 startTime, uint256 endTime, uint256 startingPriceUsd, address paymentToken, address highestBidder, address highestBidToken, uint256 highestBidAmount, uint256 highestBidUsd, bool settled, bool ended))',
];
const nftAbi = [
  'function approve(address to, uint256 tokenId)',
  'function ownerOf(uint256 tokenId) view returns (address)',
  'function mint(address to, string uri) returns (uint256)',
];
const erc20Abi = [
  'function approve(address spender, uint256 amount) returns (bool)',
  'function allowance(address owner, address spender) view returns (uint256)',
  'function balanceOf(address account) view returns (uint256)',
  'function decimals() view returns (uint8)',
  'function mint(address to, uint256 amount)',
];
const feedAbi = ['function answer() view returns (int256)', 'function updateAnswer(int256 answer)'];

const ADDRESS_FIELDS = ['auctionProxy', 'metaNFT', 'mockUSDC', 'ethUsdFeed', 'usdcUsdFeed'];

let ADDRESSES = null;
let accountIndex = Number(localStorage.getItem('demo.account') ?? 0);
let auctions = [];
let lastVersion = '';
let usdcDecimals = 6;
let busy = false;

const el = (id) => document.getElementById(id);

function status(id, msg, kind = '') {
  const node = el(id);
  if (!node) return;
  node.textContent = msg;
  node.className = `status${kind ? ' ' + kind : ''}`;
}

function showError(msg) {
  const box = el('error');
  if (!msg) {
    box.classList.add('hidden');
    box.textContent = '';
    return;
  }
  box.textContent = msg;
  box.classList.remove('hidden');
}

function errText(err) {
  return err?.shortMessage || err?.reason || err?.message || String(err);
}

function currentAccount() {
  return ACCOUNTS[accountIndex] ?? ACCOUNTS[0];
}

function signer() {
  return new ethers.Wallet(currentAccount().key, provider);
}

function auctionContract(runner = provider) {
  return new ethers.Contract(ADDRESSES.auctionProxy, auctionAbi, runner);
}

function tokenLabel(token) {
  if (!token || token === ZERO) return 'ETH';
  return token.toLowerCase() === ADDRESSES.mockUSDC.toLowerCase() ? 'USDC' : shortAddr(token);
}

function formatToken(amount, token) {
  if (!token || token === ZERO) return `${fmtUnits(amount, 18)} ETH`;
  return `${fmtUnits(amount, usdcDecimals)} ${tokenLabel(token)}`;
}

function fmtUnits(value, decimals) {
  const [whole, frac = ''] = ethers.formatUnits(value, decimals).split('.');
  return `${Number(whole).toLocaleString('en-US')}.${(frac + '00').slice(0, 2)}`;
}

function captureInputs(root) {
  const map = {};
  root.querySelectorAll('input,select').forEach((node) => {
    if (node.id) map[node.id] = node.value;
  });
  return map;
}

function restoreInputs(root, map) {
  root.querySelectorAll('input,select').forEach((node) => {
    if (node.id && map[node.id] !== undefined && node.value !== map[node.id]) {
      node.value = map[node.id];
    }
  });
}

async function loadAddresses() {
  const cacheKey = `demo.addresses.${network}`;
  try {
    const res = await fetch(NET.file, { cache: 'no-store' });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const json = await res.json();
    const missing = ADDRESS_FIELDS.filter((key) => !json[key]);
    if (missing.length) throw new Error(`缺少字段 ${missing.join(', ')}`);
    localStorage.setItem(cacheKey, JSON.stringify(json));
    return json;
  } catch {
    const raw = localStorage.getItem(cacheKey);
    return raw ? JSON.parse(raw) : null;
  }
}

function renderManualAddressForm() {
  el('manual-section').classList.remove('hidden');
  const form = el('manual-form');
  form.innerHTML = '';
  ADDRESS_FIELDS.forEach((field) => {
    const label = document.createElement('label');
    label.textContent = field;
    const input = document.createElement('input');
    input.id = `m-${field}`;
    input.placeholder = '0x...';
    input.style.width = '330px';
    label.appendChild(input);
    form.appendChild(label);
  });
  const save = document.createElement('button');
  save.textContent = '保存地址';
  save.onclick = () => {
    const next = {};
    for (const field of ADDRESS_FIELDS) {
      const value = el(`m-${field}`).value.trim();
      if (!ethers.isAddress(value)) {
        showError(`地址格式不正确：${field}`);
        return;
      }
      next[field] = value;
    }
    localStorage.setItem(`demo.addresses.${network}`, JSON.stringify(next));
    location.reload();
  };
  form.appendChild(save);
}

async function initContracts() {
  ADDRESSES = await loadAddresses();
  if (!ADDRESSES) {
    renderManualAddressForm();
    throw new Error(`未找到 ${NET.file.replace('../', '')}，请先运行部署脚本`);
  }
  el('c-nft').value = ADDRESSES.metaNFT;
  if (el('watch')) el('watch').value = ADDRESSES.deployer ?? '';
  try {
    const token = new ethers.Contract(ADDRESSES.mockUSDC, erc20Abi, provider);
    usdcDecimals = Number(await token.decimals());
  } catch {
    usdcDecimals = 6;
  }
}

function renderAccounts() {
  const select = el('account');
  select.innerHTML = '';
  ACCOUNTS.forEach((account, index) => {
    const opt = document.createElement('option');
    opt.value = String(index);
    opt.textContent = `${account.label} ${shortAddr(account.address)}`;
    opt.selected = index === accountIndex;
    select.appendChild(opt);
  });
  select.onchange = () => {
    accountIndex = Number(select.value);
    localStorage.setItem('demo.account', String(accountIndex));
    renderWithdraw();
  };
}

async function readHeader() {
  const network = await provider.getNetwork();
  el('chainId').textContent = String(network.chainId);
  const version = await auctionContract().getVersion();
  lastVersion = version;
  el('version').textContent = version;
}

async function refreshAuctions() {
  if (busy || !ADDRESSES) return;
  busy = true;
  try {
    const contract = auctionContract();
    const count = Number(await contract.nextAuctionId());
    const list = [];
    for (let id = count - 1; id >= 0; id -= 1) {
      const a = await contract.getAuction(id);
      list.push({
        id,
        nft: a.nft,
        seller: a.seller,
        tokenId: a.tokenId,
        endTime: a.endTime,
        startingPriceUsd: a.startingPriceUsd,
        paymentToken: a.paymentToken,
        highestBidder: a.highestBidder,
        highestBidToken: a.highestBidToken,
        highestBidAmount: a.highestBidAmount,
        highestBidUsd: a.highestBidUsd,
        settled: a.settled,
      });
    }
    auctions = list;
    showError('');
    await readHeader();
    renderAuctions();
    await renderWithdraw();
  } catch (err) {
    showError(`无法连接本地链或合约地址不正确：${errText(err)}`);
  } finally {
    busy = false;
  }
}

function cardStatus(a) {
  if (a.settled) return { cls: 'done', text: '已结算' };
  const left = remainingSeconds(a.endTime, Math.floor(Date.now() / 1000));
  return left > 0 ? { cls: 'live', text: '进行中' } : { cls: 'ended', text: '已结束待结算' };
}

function renderAuctions() {
  const list = el('auction-list');
  if (!auctions.length) {
    list.innerHTML = NET.readOnly
      ? '<div class="empty">Sepolia 上暂无拍卖记录。</div>'
      : '<div class="empty">暂无拍卖。用上方表单创建第一场。</div>';
    return;
  }
  const saved = captureInputs(list);
  list.innerHTML = '';

  auctions.forEach((a) => {
    const st = cardStatus(a);
    const highest = a.highestBidder === ZERO
      ? '暂无出价'
      : `${formatUsd8(a.highestBidUsd)} · ${fmtUnits(a.highestBidAmount, a.highestBidToken === ZERO ? 18 : usdcDecimals)} ${tokenLabel(a.highestBidToken)}`;

    const card = document.createElement('div');
    card.className = 'card';
    card.innerHTML = `
      <div class="card-head">
        <span class="card-title">#${a.id} · NFT#${a.tokenId}</span>
        <span class="tag ${st.cls}">${st.text}</span>
        <span class="tag">${a.paymentToken === ZERO ? '仅 ETH' : 'ETH + USDC'}</span>
        <span class="tag">卖家 ${shortAddr(a.seller)}</span>
      </div>
      <div class="rows">
        <div><span>起拍价</span>$${formatUsd8(a.startingPriceUsd)}</div>
        <div><span>最高出价</span>${highest}</div>
        <div><span>剩余时间</span>${a.settled ? '<b>已结束</b>' : `<b class="remaining" data-end="${a.endTime}">—</b>`}</div>
      </div>
      ${a.settled || NET.readOnly ? '' : `
      <div class="actions">
        <label style="display:flex;gap:6px;align-items:center;color:var(--muted);font-size:12px">ETH
          <input id="bid-eth-${a.id}" value="1" style="width:90px" />
          <button class="secondary" data-action="bid-eth" data-id="${a.id}">出价</button>
        </label>
        <label style="display:flex;gap:6px;align-items:center;color:var(--muted);font-size:12px">USDC
          <input id="bid-usdc-${a.id}" value="1000" style="width:90px" />
          <button class="secondary" data-action="bid-usdc" data-id="${a.id}">出价</button>
        </label>
        ${st.cls === 'ended' ? `<button data-action="settle" data-id="${a.id}">结算</button>` : ''}
      </div>`}
      <div class="card-error" id="card-error-${a.id}"></div>
    `;
    list.appendChild(card);
  });

  restoreInputs(list, saved);
  tickCountdowns();
}

function tickCountdowns() {
  const now = Math.floor(Date.now() / 1000);
  document.querySelectorAll('.remaining').forEach((node) => {
    const end = Number(node.dataset.end);
    node.textContent = formatDuration(remainingSeconds(BigInt(end), now));
  });
}

function viewAddress() {
  if (!NET.readOnly) return currentAccount().address;
  const raw = el('watch')?.value.trim();
  return ethers.isAddress(raw) ? raw : (ADDRESSES?.deployer ?? ZERO);
}

async function renderWithdraw() {
  const box = el('withdraw-body');
  if (!ADDRESSES) return;
  const saved = captureInputs(box);
  const account = viewAddress();
  try {
    const contract = auctionContract();
    const rows = [];

    for (const token of [ZERO, ADDRESSES.mockUSDC]) {
      const proceeds = await contract.pendingProceeds(account, token);
      if (proceeds > 0n) {
        rows.push({ kind: '货款', token, amount: proceeds, action: 'proceeds' });
      }
      const fees = await contract.pendingFees(account, token);
      if (fees > 0n) {
        rows.push({ kind: '平台费', token, amount: fees, action: 'fees' });
      }
      for (const a of auctions) {
        const refund = await contract.pendingRefunds(a.id, account, token);
        if (refund > 0n) {
          rows.push({ kind: `退款 #${a.id}`, token, amount: refund, action: 'refund', auctionId: a.id });
        }
      }
    }

    if (!rows.length) {
      box.innerHTML = '<div class="empty">当前账户没有可提取的余额。</div>';
      return;
    }

    box.innerHTML = '';
    rows.forEach((row) => {
      const div = document.createElement('div');
      div.className = 'wrow';
      div.innerHTML = `
        <span class="label">${row.kind} · ${tokenLabel(row.token)}</span>
        <span class="amount">${formatToken(row.amount, row.token)}</span>
        ${NET.readOnly ? '' : `<button class="secondary" data-action="${row.action}" data-token="${row.token}" ${row.auctionId !== undefined ? `data-id="${row.auctionId}"` : ''}>提取</button>`}
      `;
      box.appendChild(div);
    });
    restoreInputs(box, saved);
  } catch (err) {
    box.innerHTML = `<div class="empty">读取余额失败：${errText(err)}</div>`;
  }
}

async function runAction(label, fn) {
  try {
    await fn();
    return true;
  } catch (err) {
    status('tools-status', `${label}失败：${errText(err)}`, 'err');
    return false;
  }
}

async function handleBidEth(id) {
  const value = el(`bid-eth-${id}`)?.value ?? '1';
  const errorBox = el(`card-error-${id}`);
  errorBox.textContent = '';
  try {
    const tx = await auctionContract(signer()).bid(id, { value: ethers.parseEther(value) });
    errorBox.textContent = '交易已提交，等待确认…';
    await tx.wait();
    errorBox.textContent = '';
    await refreshAuctions();
  } catch (err) {
    errorBox.textContent = `出价失败：${errText(err)}`;
  }
}

async function handleBidUsdc(id) {
  const value = el(`bid-usdc-${id}`)?.value ?? '1000';
  const errorBox = el(`card-error-${id}`);
  errorBox.textContent = '';
  try {
    const amount = ethers.parseUnits(value, usdcDecimals);
    const wallet = signer();
    const token = new ethers.Contract(ADDRESSES.mockUSDC, erc20Abi, wallet);
    const allowance = await token.allowance(wallet.address, ADDRESSES.auctionProxy);
    if (allowance < amount) {
      const approveTx = await token.approve(ADDRESSES.auctionProxy, amount);
      await approveTx.wait();
    }
    const tx = await auctionContract(wallet).bidWithERC20(id, amount);
    errorBox.textContent = '交易已提交，等待确认…';
    await tx.wait();
    errorBox.textContent = '';
    await refreshAuctions();
  } catch (err) {
    errorBox.textContent = `出价失败：${errText(err)}`;
  }
}

async function handleSettle(id) {
  const errorBox = el(`card-error-${id}`);
  errorBox.textContent = '';
  try {
    const tx = await auctionContract(signer()).settle(id);
    errorBox.textContent = '交易已提交，等待确认…';
    await tx.wait();
    errorBox.textContent = '';
    await refreshAuctions();
  } catch (err) {
    errorBox.textContent = `结算失败：${errText(err)}`;
  }
}

async function handleWithdraw(action, token, id) {
  try {
    const wallet = signer();
    const contract = auctionContract(wallet);
    let tx;
    if (action === 'refund') tx = await contract.withdrawRefund(Number(id));
    else if (action === 'proceeds') tx = await contract.withdrawProceeds(token);
    else tx = await contract.withdrawFees(token);
    await tx.wait();
    await refreshAuctions();
  } catch (err) {
    showError(`提取失败：${errText(err)}`);
  }
}

async function handleCreate() {
  status('create-status', '处理中…');
  let step = '读取表单';
  try {
    const nft = el('c-nft').value.trim();
    const tokenId = el('c-tokenId').value.trim();
    const price = el('c-price').value.trim();
    const duration = el('c-duration').value.trim();
    const payment = el('c-payment').value;

    if (!ethers.isAddress(nft)) throw new Error('NFT 地址格式不正确');
    const startingPriceUsd = parseUsdTo8(price);
    const wallet = signer();

    step = 'approve';
    const nftContract = new ethers.Contract(nft, nftAbi, wallet);
    const approveTx = await nftContract.approve(ADDRESSES.auctionProxy, tokenId);
    await approveTx.wait();

    step = 'createAuction';
    const tx = await auctionContract(wallet).createAuction(
      nft,
      tokenId,
      startingPriceUsd,
      duration,
      payment === 'usdc' ? ADDRESSES.mockUSDC : ZERO,
    );
    await tx.wait();
    status('create-status', '创建成功', 'ok');
    await refreshAuctions();
  } catch (err) {
    status('create-status', `创建失败（${step}）：${errText(err)}`, 'err');
  }
}

async function handleAdvance() {
  await runAction('推进时间', async () => {
    await provider.send('evm_increaseTime', [3600]);
    await provider.send('evm_mine', []);
    status('tools-status', '已推进 1 小时', 'ok');
    await refreshAuctions();
  });
}

async function handleRefreshOracles() {
  await runAction('刷新预言机', async () => {
    const wallet = signer();
    for (const feed of [ADDRESSES.ethUsdFeed, ADDRESSES.usdcUsdFeed]) {
      const contract = new ethers.Contract(feed, feedAbi, wallet);
      const current = await contract.answer();
      const tx = await contract.updateAnswer(current);
      await tx.wait();
    }
    status('tools-status', '预言机时间戳已刷新（价格不变）', 'ok');
  });
}

async function handleMintUsdc() {
  await runAction('领取测试 USDC', async () => {
    const wallet = signer();
    const token = new ethers.Contract(ADDRESSES.mockUSDC, erc20Abi, wallet);
    const tx = await token.mint(wallet.address, ethers.parseUnits('5000', usdcDecimals));
    await tx.wait();
    status('tools-status', `已向 ${shortAddr(wallet.address)} 铸造 5000 USDC`, 'ok');
    await refreshAuctions();
  });
}

function bindEvents() {
  el('refresh').onclick = () => refreshAuctions();
  el('c-submit').onclick = () => handleCreate();
  el('t-advance').onclick = () => handleAdvance();
  el('t-oracle').onclick = () => handleRefreshOracles();
  el('t-usdc').onclick = () => handleMintUsdc();

  el('auction-list').addEventListener('click', (event) => {
    const btn = event.target.closest('button[data-action]');
    if (!btn) return;
    const id = Number(btn.dataset.id);
    const action = btn.dataset.action;
    if (action === 'bid-eth') handleBidEth(id);
    else if (action === 'bid-usdc') handleBidUsdc(id);
    else if (action === 'settle') handleSettle(id);
  });

  el('withdraw-body').addEventListener('click', (event) => {
    const btn = event.target.closest('button[data-action]');
    if (!btn) return;
    handleWithdraw(btn.dataset.action, btn.dataset.token, btn.dataset.id);
  });
}

function applyNetworkUi() {
  const netSelect = el('network');
  netSelect.value = network;
  netSelect.onchange = () => {
    localStorage.setItem('demo.network', netSelect.value);
    location.reload();
  };
  if (!NET.readOnly) return;
  el('readonly-note').classList.remove('hidden');
  el('create').classList.add('hidden');
  el('tools').classList.add('hidden');
  el('account-wrap').classList.add('hidden');
  el('watch-wrap').classList.remove('hidden');
  el('watch').onchange = () => renderWithdraw();
}

async function init() {
  applyNetworkUi();
  if (!NET.readOnly) renderAccounts();
  bindEvents();
  try {
    await initContracts();
  } catch (err) {
    showError(errText(err));
  }
  await refreshAuctions();
  setInterval(tickCountdowns, 1000);
  setInterval(() => {
    if (!document.hidden) refreshAuctions();
  }, 3000);
}

init();
