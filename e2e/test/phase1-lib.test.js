'use strict'
// Unit tests for the pure parts of the phase I walkthrough: what each withdrawal path must produce,
// and the state file that passes results from one step to the next.
const { test } = require('node:test')
const assert = require('node:assert/strict')
const { expectedOutcome, stringifyState, parseState } = require('../src/phase1-lib')

const denomination = 10n ** 16n // 0.01 ETH
const poolFee = (denomination * 60n) / 10000n // 0.3% protocol fee + 0.3% premium
const relayerFee = (denomination * 40n) / 10000n // 0.4%, what the relayer charges in the walkthrough

test('registered relayer: user pays only the relayer fee, pool keeps nothing, proof accepts no pool fee', () => {
  const o = expectedOutcome({ path: 'registered', denomination, poolFee, relayerFee })
  assert.equal(o.userReceives, denomination - relayerFee)
  assert.equal(o.relayerReceives, relayerFee)
  assert.equal(o.poolKeeps, 0n)
  assert.equal(o.refund, 0n)
  assert.equal(o.burnsTorn, true)
})

test('unregistered relayer: pool keeps the fee on top of the relayer fee, no TORN burned', () => {
  const o = expectedOutcome({ path: 'unregistered', denomination, poolFee, relayerFee })
  assert.equal(o.userReceives, denomination - relayerFee - poolFee)
  assert.equal(o.relayerReceives, relayerFee)
  assert.equal(o.poolKeeps, poolFee)
  assert.equal(o.refund, poolFee)
  assert.equal(o.burnsTorn, false)
})

test('self withdrawal: pool keeps the fee, nothing to a relayer', () => {
  const o = expectedOutcome({ path: 'self', denomination, poolFee, relayerFee })
  assert.equal(o.userReceives, denomination - poolFee)
  assert.equal(o.relayerReceives, 0n)
  assert.equal(o.poolKeeps, poolFee)
  assert.equal(o.refund, poolFee)
  assert.equal(o.burnsTorn, false)
})

test('through the Router with no relayer: same as a self withdrawal, the pool keeps the fee', () => {
  const o = expectedOutcome({ path: 'router', denomination, poolFee, relayerFee })
  assert.deepEqual(o, expectedOutcome({ path: 'self', denomination, poolFee, relayerFee }))
})

test('unknown path is refused', () => {
  assert.throws(() => expectedOutcome({ path: 'teleport', denomination, poolFee, relayerFee }), /unknown withdrawal path/)
})

test('state survives a round trip through the state file, BigInts included', () => {
  const state = { pool: '0xabc', amounts: { fee: 60000000000000n, zero: 0n }, notes: [{ leafIndex: 3, spent: false }], text: 'x' }
  const restored = parseState(stringifyState(state))
  assert.deepEqual(restored, state)
  assert.equal(typeof restored.amounts.fee, 'bigint')
  assert.equal(typeof restored.notes[0].leafIndex, 'number')
})
