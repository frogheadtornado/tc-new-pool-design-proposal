'use strict'
// The pure parts of the phase I walkthrough (e2e/src/phase1.js): what the design says each
// withdrawal path must produce, and the state file that carries results from one step to the next.

/**
 * What a withdrawal of `denomination` must produce on each path, from the pool's rules:
 * - registered relayer through the Router: the DAO is paid in TORN burned from the relayer's
 *   stake, the pool charges nothing, the proof accepts no pool fee (refund 0);
 * - anything else (unregistered relayer, own wallet straight to the pool, own wallet through the
 *   Router without a relayer): the pool keeps `poolFee` (protocol fee + premium) and the proof must allow it.
 * `relayerFee` is what the relayer charges the user, 0 when there is none.
 */
function expectedOutcome({ path, denomination, poolFee, relayerFee }) {
  switch (path) {
    case 'registered':
      return { userReceives: denomination - relayerFee, relayerReceives: relayerFee, poolKeeps: 0n, refund: 0n, burnsTorn: true }
    case 'unregistered':
      return {
        userReceives: denomination - relayerFee - poolFee,
        relayerReceives: relayerFee,
        poolKeeps: poolFee,
        refund: poolFee,
        burnsTorn: false
      }
    case 'self':
    case 'router':
      return { userReceives: denomination - poolFee, relayerReceives: 0n, poolKeeps: poolFee, refund: poolFee, burnsTorn: false }
    default:
      throw new Error(`unknown withdrawal path: ${path}`)
  }
}

// BigInts are written as strings with a marker, so that amounts come back as BigInts.
const BIGINT = 'bigint:'

function stringifyState(state) {
  return JSON.stringify(state, (key, value) => (typeof value === 'bigint' ? BIGINT + value.toString() : value), 2)
}

function parseState(text) {
  return JSON.parse(text, (key, value) => (typeof value === 'string' && value.startsWith(BIGINT) ? BigInt(value.slice(BIGINT.length)) : value))
}

module.exports = { expectedOutcome, stringifyState, parseState }
