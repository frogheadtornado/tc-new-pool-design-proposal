'use strict'
// The helpers shared by the two end-to-end scripts.
const { test } = require('node:test')
const assert = require('node:assert/strict')
const { fmt, percent, ADDRESS, ABI } = require('../src/common')

test('fmt prints 18-decimal amounts rounded, without trailing zeros, with thousands separators', () => {
  assert.equal(fmt(10n ** 16n), '0.01')
  assert.equal(fmt(60000000000000n), '0.00006')
  assert.equal(fmt(11673000000000000n, 6), '0.011673')
  assert.equal(fmt(2686443560000000000000000n, 2), '2,686,443.56')
  assert.equal(fmt(0n), '0')
})

test('percent prints a part of a whole with four decimals', () => {
  assert.equal(percent(60000000000000n, 10n ** 16n), '0.6%')
  assert.equal(percent(9940000000000000n, 10n ** 16n), '99.4%')
})

test('the live contract addresses and ABIs both scripts need are exported', () => {
  assert.equal(ADDRESS.router, '0xd90e2f925DA726b50C4Ed8D0Fb90Ad053324F31b')
  assert.ok(ABI.pool.some((f) => f.startsWith('function sweepProtocolFees')))
  assert.ok(ABI.staking.some((f) => f.startsWith('function getEthReward')))
})
