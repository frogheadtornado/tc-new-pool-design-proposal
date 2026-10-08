'use strict'
// The report of the phase I walkthrough: one block per test with what it verifies, the expected
// result, whether it passed, the command and its output.
const { test } = require('node:test')
const assert = require('node:assert/strict')
const { spec, render } = require('../src/phase1-report')

const fees = { denomination: 10n ** 16n, protocolFee: 30n, premium: 30n, poolFee: 60000000000000n, tornFee: 11180000000000000n }

test('spec says what a registered-relayer withdrawal verifies and the amounts it expects', () => {
  const s = spec('withdraw', { via: 'registered' }, fees)
  assert.match(s.verifies, /registered relayer/)
  assert.match(s.expected, /0\.00996 ETH/)
  assert.match(s.expected, /0\.00004 ETH/)
  assert.match(s.expected, /TORN/)
})

test('spec for the Router-without-relayer path expects the pool fee and no relayer', () => {
  const s = spec('withdraw', { via: 'router' }, fees)
  assert.match(s.verifies, /Router/)
  assert.match(s.expected, /0\.00994 ETH/)
  assert.match(s.expected, /0\.00006 ETH/)
})

test('spec for a fee change spells out the new rates and the new direct-withdrawal fee', () => {
  const s = spec('fees', { protocol: 50n, premium: 100n }, fees)
  assert.match(s.title, /0\.5%/)
  assert.match(s.title, /1%/)
  assert.match(s.verifies, /Governance/)
  assert.match(s.expected, /0\.00015 ETH/)
  assert.match(s.expected, /InstanceRegistry/)
})

test('spec for the caps says every attempt must be refused', () => {
  const s = spec('caps', {}, fees)
  assert.match(s.verifies, /1%/)
  assert.match(s.verifies, /4%/)
  assert.match(s.expected, /refused/i)
  assert.match(s.expected, /Only governance/)
})

test('spec for the sweep before the upgrade says the refusal is the expected result', () => {
  const s = spec('sweep', { upgraded: false }, fees)
  assert.match(s.expected, /refused/i)
  assert.match(s.expected, /addEthRewards/)
})

test('render writes one block per test with verifies, expected, result, command and output', () => {
  const state = {
    chainId: 1n, forkBlock: 100, proposal: '0xprop', pool: '0xpool', simulatedPhase1: null, fees,
    parties: { stakerLock: 10n ** 22n, relayer: '0xrelayer' }, notes: [], sweeps: [], phase2: null, claim: null, refusals: [],
    withdrawals: [{ n: 1, pathName: 'self', userReceives: 9940000000000000n, relayerReceives: 0n, relayerAddress: '0x0000000000000000000000000000000000000000', tornBurned: 0n, tornInEth: 0n, kept: 60000000000000n, gasPaidBy: 'user', gasCost: 1n, feeSetting: { protocolFee: 30n, premium: 30n } }],
    transcripts: [
      { command: 'node e2e/src/phase1.js setup', title: 'Setup', verifies: 'V1', expected: 'E1', pass: true, checks: 9, lines: ['== Setup ==', 'pool  0xpool'] },
      { command: 'node e2e/src/phase1.js claim', title: 'Claim', verifies: 'V2', expected: 'E2', pass: false, error: 'nothing to claim', checks: 0, lines: ['== Claim ==', '✗ FAILED: nothing to claim'] }
    ]
  }
  const md = render(state)
  assert.match(md, /### 1\. Setup/)
  assert.match(md, /\*\*Verifies:\*\* V1/)
  assert.match(md, /\*\*Expected:\*\* E1/)
  assert.match(md, /\*\*Result:\*\* PASS \(9 checks\)/)
  assert.match(md, /\*\*Command:\*\* `node e2e\/src\/phase1\.js setup`/)
  assert.match(md, /```text\n\$ node e2e\/src\/phase1\.js setup\n== Setup ==\npool  0xpool\n```/)
  assert.match(md, /### 2\. Claim/)
  assert.match(md, /\*\*Result:\*\* FAIL: nothing to claim/)
  assert.match(md, /\*\*Result:\*\* 1 of 2 tests passed/)
  assert.match(md, /\| 1 \| From the user's own wallet \(no relayer\) \| 0\.3% \+ 0\.3% \| 0\.00994 ETH \(99\.4%\)/)
})
