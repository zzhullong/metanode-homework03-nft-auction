import test from 'node:test';
import assert from 'node:assert/strict';
import { formatUsd8, parseUsdTo8, remainingSeconds, formatDuration, shortAddr } from './lib.mjs';

test('formatUsd8 转美元字符串并千分位', () => {
  assert.equal(formatUsd8(400000000000n), '4,000.00');
  assert.equal(formatUsd8(100000000n), '1.00');
  assert.equal(formatUsd8(0n), '0.00');
});

test('parseUsdTo8 接受整数与两位小数', () => {
  assert.equal(parseUsdTo8('1000'), 100000000000n);
  assert.equal(parseUsdTo8('1000.5'), 100050000000n);
  assert.equal(parseUsdTo8('0.01'), 1000000n);
});

test('parseUsdTo8 拒绝空值、负数、非数字、超过两位小数', () => {
  assert.throws(() => parseUsdTo8(''), /金额格式不正确/);
  assert.throws(() => parseUsdTo8('-1'), /金额格式不正确/);
  assert.throws(() => parseUsdTo8('abc'), /金额格式不正确/);
  assert.throws(() => parseUsdTo8('1.234'), /金额格式不正确/);
});

test('remainingSeconds 不为负', () => {
  assert.equal(remainingSeconds(2000n, 1000), 1000);
  assert.equal(remainingSeconds(900n, 1000), 0);
});

test('formatDuration 三种形态', () => {
  assert.equal(formatDuration(0), '已结束');
  assert.equal(formatDuration(59), '00:59');
  assert.equal(formatDuration(61), '01:01');
  assert.equal(formatDuration(3661), '1:01:01');
});

test('shortAddr 截断保留首尾', () => {
  assert.equal(shortAddr('0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266'), '0xf39F…2266');
});
