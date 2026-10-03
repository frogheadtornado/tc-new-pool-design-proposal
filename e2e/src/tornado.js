'use strict'
// Tornado Cash notes, the deposit Merkle tree and withdrawal proofs, as a wallet builds them.
// The circuit and the proving key are the ones the classic UI ships; proofs made here are checked by
// the verifier contract that is live on mainnet.

const crypto = require('crypto')
const fs = require('fs')
const path = require('path')
const zlib = require('zlib')
const { buildPedersenHash, buildMimcSponge } = require('circomlibjs')
const buildGroth16 = require('websnark/src/groth16')
const websnarkUtils = require('websnark/src/utils')

const LEVELS = 20
// keccak256("tornado") % FIELD_SIZE, the value of an empty leaf
const ZERO_VALUE = 21663839004416932945382355908790599225266501822907911457504978515578255421292n

const leBuffToBigInt = (buf) => BigInt('0x' + Buffer.from(buf).reverse().toString('hex'))
const bigIntToLeBuff = (value, length) => Buffer.from(value.toString(16).padStart(length * 2, '0'), 'hex').reverse()
const toHex = (value, bytes = 32) => '0x' + BigInt(value).toString(16).padStart(bytes * 2, '0')

let hashers
async function getHashers() {
  if (!hashers) {
    const pedersen = await buildPedersenHash()
    const mimc = await buildMimcSponge()
    hashers = {
      // Pedersen hash of a byte string, as the x coordinate of the resulting curve point
      pedersen: (data) => BigInt(pedersen.babyJub.F.toString(pedersen.babyJub.unpackPoint(pedersen.hash(data))[0])),
      // MiMC sponge of two field elements: what the pool's hashLeftRight computes
      mimc: (left, right) => BigInt(mimc.F.toString(mimc.multiHash([left, right])))
    }
  }
  return hashers
}

/** A new note for `amount` ETH on chain `netId`: two random 31-byte secrets and what derives from them. */
async function createNote(amount, netId) {
  return noteFromSecrets(amount, netId, leBuffToBigInt(crypto.randomBytes(31)), leBuffToBigInt(crypto.randomBytes(31)))
}

async function noteFromSecrets(amount, netId, nullifier, secret) {
  const { pedersen } = await getHashers()
  const preimage = Buffer.concat([bigIntToLeBuff(nullifier, 31), bigIntToLeBuff(secret, 31)])
  return {
    amount: String(amount),
    netId: Number(netId),
    nullifier,
    secret,
    commitment: pedersen(preimage),
    nullifierHash: pedersen(bigIntToLeBuff(nullifier, 31)),
    // The string a user keeps. Whoever holds it can withdraw the deposit.
    text: `tornado-eth-${amount}-${netId}-0x${preimage.toString('hex')}`
  }
}

/** Rebuild a note from the string the user kept. */
async function parseNote(text) {
  const match = /^tornado-eth-([\d.]+)-(\d+)-0x([0-9a-fA-F]{124})$/.exec(text)
  if (!match) throw new Error('not a Tornado ETH note')
  const preimage = Buffer.from(match[3], 'hex')
  return noteFromSecrets(match[1], match[2], leBuffToBigInt(preimage.subarray(0, 31)), leBuffToBigInt(preimage.subarray(31, 62)))
}

/** The pool's deposit tree, rebuilt from the commitments of its Deposit events in leaf order. */
async function buildTree(commitments) {
  const { mimc } = await getHashers()
  const zeros = [ZERO_VALUE]
  for (let level = 1; level <= LEVELS; level++) zeros.push(mimc(zeros[level - 1], zeros[level - 1]))

  const layers = [commitments.map(BigInt)]
  for (let level = 0; level < LEVELS; level++) {
    const below = layers[level]
    const above = []
    for (let i = 0; i < below.length; i += 2) {
      above.push(mimc(below[i], i + 1 < below.length ? below[i + 1] : zeros[level]))
    }
    layers.push(above)
  }

  return {
    root: layers[LEVELS].length ? layers[LEVELS][0] : zeros[LEVELS],
    path(index) {
      const pathElements = []
      const pathIndices = []
      for (let level = 0; level < LEVELS; level++) {
        const sibling = index ^ 1
        pathElements.push(sibling < layers[level].length ? layers[level][sibling] : zeros[level])
        pathIndices.push(index & 1)
        index >>= 1
      }
      return { pathElements, pathIndices }
    }
  }
}

/** Load the withdraw circuit and its proving key (compressed, as the classic UI ships them). */
async function loadProver(keysDir) {
  const read = (name) => {
    const file = path.join(keysDir, name)
    if (!fs.existsSync(file)) {
      throw new Error(`${name} not found in ${keysDir}. Set TORNADO_KEYS_DIR to a folder with the classic UI's static files.`)
    }
    return zlib.unzipSync(fs.readFileSync(file)) // zlib streams, despite the .gz name
  }
  const circuit = JSON.parse(read('tornado.json.gz').toString())
  const key = read('tornadoProvingKey.bin.gz')
  return {
    circuit,
    provingKey: key.buffer.slice(key.byteOffset, key.byteOffset + key.byteLength),
    groth16: await buildGroth16()
  }
}

/**
 * The withdrawal proof for `note`. The public inputs (root, nullifier hash, recipient, relayer, fee,
 * refund) are bound into the proof: change any of them and the pool's verifier rejects it.
 * In the fee-enforced pools `refund` is the highest ETH fee the note owner lets the pool charge:
 * 0 for a withdrawal through a registered relayer, the pool's `directWithdrawFee()` otherwise.
 */
async function proveWithdrawal(prover, { note, tree, leafIndex, recipient, relayer, fee, refund }) {
  const { pathElements, pathIndices } = tree.path(leafIndex)
  const input = {
    root: tree.root.toString(),
    nullifierHash: note.nullifierHash.toString(),
    recipient: BigInt(recipient).toString(),
    relayer: BigInt(relayer).toString(),
    fee: BigInt(fee).toString(),
    refund: BigInt(refund).toString(),
    nullifier: note.nullifier.toString(),
    secret: note.secret.toString(),
    pathElements: pathElements.map(String),
    pathIndices: pathIndices.map(String)
  }
  const proofData = await websnarkUtils.genWitnessAndProve(prover.groth16, input, prover.circuit, prover.provingKey)
  return websnarkUtils.toSolidityInput(proofData).proof
}

module.exports = { createNote, parseNote, buildTree, loadProver, proveWithdrawal, toHex }
