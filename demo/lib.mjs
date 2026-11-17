export function formatUsd8(v) {
  const n = Number(v) / 1e8;
  return n.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

export function parseUsdTo8(input) {
  const s = String(input ?? '').trim();
  if (!/^\d+(\.\d{1,2})?$/.test(s)) throw new Error('金额格式不正确');
  const [intPart, fracPart = ''] = s.split('.');
  return BigInt(intPart) * 100000000n + BigInt((fracPart + '00000000').slice(0, 8));
}

export function remainingSeconds(endTime, nowSec) {
  const diff = Number(endTime) - Number(nowSec);
  return diff > 0 ? diff : 0;
}

export function formatDuration(sec) {
  if (sec <= 0) return '已结束';
  const h = Math.floor(sec / 3600);
  const m = Math.floor((sec % 3600) / 60);
  const s = sec % 60;
  const mm = String(m).padStart(2, '0');
  const ss = String(s).padStart(2, '0');
  return h > 0 ? `${h}:${mm}:${ss}` : `${mm}:${ss}`;
}

export function shortAddr(a) {
  if (!a) return '';
  return `${a.slice(0, 6)}…${a.slice(-4)}`;
}
