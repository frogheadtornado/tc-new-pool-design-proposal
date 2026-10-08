'use strict'
// Phase I walkthrough on a local mainnet fork, one step at a time.
//
// It acts as each party would once the first proposal is executed: a user deposits 0.01 ETH and
// withdraws through each path (registered relayer, unregistered relayer, own wallet) with real
// zero-knowledge proofs, and every wei is traced: what the user gets, what the relayer gets, what
// the DAO gets in TORN or in ETH, and where that ETH sits. It then shows that the ETH fees cannot
// leave the pool until the staking contract is upgraded, simulates that upgrade (phase II), sweeps
// the fees to the staking contract and has a TORN locker claim its share.
//
// If the fork is from before the proposal's execution, `setup` passes the proposal that is already
// deployed on mainnet through the live Governance contract on the fork first, and says so.
//
// Every step is a test: it prints what it does, one line per value read from the chain and matched
// against the design (✓), and PASS or FAIL. The steps pass their results to each other through a
// state file in e2e/.work, and `report` turns that state into e2e/PHASE1-RESULTS.md, with what each
// test verifies, the expected result, whether it passed, the command and its output.
//
//   ./e2e/phase1.sh                         everything, on a fresh fork
//   ./e2e/phase1.sh fork                    a fork to run the steps against, one by one:
//   node e2e/src/phase1.js setup [--rpc URL] [--keys DIR] [--proposal ADDRESS]
//   node e2e/src/phase1.js deposit
//   node e2e/src/phase1.js withdraw --via registered | unregistered | self | router
//   node e2e/src/phase1.js fees --protocol 50 --premium 100   a Governance proposal changes the fees (1/10000 of the note)
//   node e2e/src/phase1.js caps             fee values out of bounds, and a non-Governance caller: all refused
//   node e2e/src/phase1.js sweep            before phase II: must be refused; after it: forwards the fees
//   node e2e/src/phase1.js phase2           simulates the staking upgrade on the fork
//   node e2e/src/phase1.js claim            a locker claims its ETH
//   node e2e/src/phase1.js report [--out FILE]

const fs = require('fs')
const path = require('path')
const { ethers } = require('ethers')
const tornado = require('./tornado')
const {
  REPO, ADDRESS, ABI, IMPLEMENTATION_SLOT, ZERO_ADDRESS, RELAYER_FEE_BPS, BPS, STAKER_LOCK, WITHDRAW_GAS_LIMIT,
  check, checkEq, checkClose, checksPassed, fmt, percent, Fork, artifact, passProposal
} = require('./common')
const { expectedOutcome, stringifyState, parseState } = require('./phase1-lib')
const { spec, render, PATHS } = require('./phase1-report')

// AddEthPoolsProposal as deployed on mainnet (verified on Etherscan). Used only if the fork is from
// before its execution.
const PROPOSAL = '0x0b3AD72fcEA25a3C7077AE6af6E4B91C4b55778B'
const DESCRIPTION = 'Add a 0.01 ETH pool with enforced fees'
const STAKING_DESCRIPTION = 'Upgrade TornadoStakingRewards to share ETH fees among TORN lockers'
const DENOMINATION = ethers.parseEther('0.01')
const STATE_ENABLED = 1n
const STATE_FILE = path.join(REPO, 'e2e', '.work', 'phase1-state.json')
const DEFAULTS = {
  rpc: 'http://127.0.0.1:8545',
  keys: process.env.TORNADO_KEYS_DIR || path.join(REPO, '..', 'classic-ui', 'static'),
  out: path.join(REPO, 'e2e', 'PHASE1-RESULTS.md'),
  proposal: PROPOSAL
}
// How far back `withdraw` looks for the pool's deposits, in blocks per request, and at most.
const LOG_CHUNK = 2000
const LOG_MAX_BLOCKS = 500000

const STEPS = ['setup', 'deposit', 'withdraw', 'fees', 'caps', 'sweep', 'phase2', 'claim', 'report', 'all']
const ALL = [
  'setup',
  'deposit', 'withdraw --via registered',
  'deposit', 'withdraw --via unregistered',
  'deposit', 'withdraw --via self',
  'deposit', 'withdraw --via router',
  // Governance raises the fees; the next withdrawals must follow them
  'fees --protocol 50 --premium 100',
  'deposit', 'withdraw --via registered',
  'deposit', 'withdraw --via self',
  // values out of bounds and a caller that is not Governance
  'caps',
  // the fees can be removed, and set back
  'fees --protocol 0 --premium 0',
  'deposit', 'withdraw --via self',
  'fees --protocol 30 --premium 30',
  'sweep', 'phase2', 'sweep', 'claim', 'report'
]

// --------------------------------------------------------------------------- arguments and state

function parseArgs(argv) {
  const args = { ...DEFAULTS }
  const given = {}
  const step = argv[2]
  check(STEPS.includes(step), `usage: node e2e/src/phase1.js <${STEPS.join('|')}> [--via registered|unregistered|self|router] [--protocol N --premium N] [--rpc URL] [--keys DIR] [--out FILE] [--proposal ADDRESS]`)
  for (let i = 3; i < argv.length; i += 2) {
    const name = argv[i].replace(/^--/, '')
    check(['via', 'rpc', 'keys', 'out', 'proposal', 'protocol', 'premium'].includes(name), `unknown option --${name}`)
    args[name] = given[name] = argv[i + 1]
  }
  if (step === 'withdraw') check(Object.keys(PATHS).includes(args.via), `withdraw needs --via ${Object.keys(PATHS).join('|')}`)
  if (step === 'fees') check(/^\d+$/.test(args.protocol || '') && /^\d+$/.test(args.premium || ''), 'fees needs --protocol N --premium N, in 1/10000 of the note (30 = 0.3%)')
  return { step, args, given }
}

function loadState() {
  check(fs.existsSync(STATE_FILE), `no state file: run \`setup\` first (${path.relative(process.cwd(), STATE_FILE)})`)
  return parseState(fs.readFileSync(STATE_FILE, 'utf8'))
}

function saveState(state) {
  fs.mkdirSync(path.dirname(STATE_FILE), { recursive: true })
  fs.writeFileSync(STATE_FILE, stringifyState(state))
}

// --------------------------------------------------------------------------- output and checks

/** What a step prints: shown on the console and kept in the state for the report. */
class Transcript {
  constructor(command) {
    this.command = command
    this.lines = []
  }
  heading(text) {
    this.print(`== ${text} ==`)
  }
  item(label, value) {
    this.print(`${label.padEnd(16)}${value}`)
  }
  pass(text) {
    this.print(`✓ ${text}`)
  }
  fail(text) {
    this.print(`✗ ${text}`)
  }
  print(text) {
    this.lines.push(text)
    console.log(text)
  }
}

/** A value read from the chain must equal what the design says; prints both. */
function verify(out, what, actual, expected, show = String) {
  checkEq(actual, expected, what)
  out.pass(`${what}: ${show(actual)} (expected ${show(expected)})`)
}

/** A condition that must hold; prints what was seen. */
function ensure(out, what, condition, seen) {
  check(condition, what)
  out.pass(seen ? `${what}: ${seen}` : what)
}

const eth = (v) => `${fmt(v)} ETH`
const tornAmt = (v) => `${fmt(v, 6)} TORN`

// --------------------------------------------------------------------------- the fork and contracts

async function connect(args, state) {
  const fork = new Fork(args.rpc)
  const { provider } = fork
  let nodeInfo
  try {
    nodeInfo = await provider.send('anvil_nodeInfo', [])
  } catch (error) {
    throw new Error(`${args.rpc} is not an anvil fork: start one with ./e2e/phase1.sh fork`)
  }
  const network = await provider.getNetwork()
  checkEq(network.chainId, 1n, 'the fork must be a fork of Ethereum mainnet (chain id)')
  const forkBlock = Number(nodeInfo.forkConfig.forkBlockNumber)
  if (state) checkEq(forkBlock, state.forkBlock, 'the fork changed since setup: run setup again')

  const at = (address, abi, signer) => new ethers.Contract(address, abi, signer || provider)
  const contracts = {
    governance: at(ADDRESS.governance, ABI.governance),
    torn: at(ADDRESS.torn, ABI.torn),
    staking: at(ADDRESS.staking, ABI.staking),
    relayerRegistry: at(ADDRESS.relayerRegistry, ABI.relayerRegistry),
    instanceRegistry: at(ADDRESS.instanceRegistry, ABI.instanceRegistry),
    feeManager: at(ADDRESS.feeManager, ABI.feeManager),
    router: at(ADDRESS.router, ABI.router),
    pool: state && state.pool ? at(state.pool, ABI.pool) : null
  }
  return { fork, provider, forkBlock, chainId: network.chainId, ...contracts, at }
}

/** A quorum-sized TORN holder with its TORN locked in Governance, created on first use. */
async function ensureVoter(ctx, state, out) {
  if (state.parties.voter) return ctx.fork.as(state.parties.voter)
  const { fork, governance, torn } = ctx
  const quorum = await governance.QUORUM_VOTES()
  const voter = await fork.account('phase1/voter', '10')
  await fork.setTorn(voter, quorum)
  const asVoter = await fork.as(voter)
  await fork.mined(torn.connect(asVoter).approve(ADDRESS.governance, quorum), 'voter approve')
  await fork.mined(governance.connect(asVoter).lockWithApproval(quorum), 'voter lock')
  checkEq(await governance.lockedBalance(voter), quorum, 'voter locked balance')
  out.item('voter', `${voter} (given ${fmt(quorum)} TORN on the fork, a quorum, and locked it in Governance to vote)`)
  state.parties.voter = voter
  state.parties.voterLock = quorum
  return asVoter
}

/** The fee-enforced 0.01 ETH pool among the registry's instances, or null if it is not there yet. */
async function findPool(ctx) {
  for (const address of await ctx.instanceRegistry.getAllInstanceAddresses()) {
    const instance = await ctx.instanceRegistry.instances(address)
    if (instance.isERC20 || instance.state !== STATE_ENABLED) continue
    const pool = ctx.at(address, ABI.pool)
    try {
      if ((await pool.denomination()) !== DENOMINATION) continue
      await pool.directWithdrawFee() // only the fee-enforced pool has it
      return pool
    } catch (error) {
      continue
    }
  }
  return null
}

/** The pool's Deposit events in leaf order, read backwards from the latest block until leaf 0. */
async function collectDeposits(ctx, pool) {
  const latest = await ctx.provider.getBlockNumber()
  const events = []
  let to = latest
  let seenFirst = false
  while (!seenFirst && to >= 0 && latest - to < LOG_MAX_BLOCKS) {
    const from = Math.max(0, to - LOG_CHUNK + 1)
    const chunk = await pool.queryFilter(pool.filters.Deposit(), from, to)
    events.push(...chunk)
    seenFirst = chunk.some((event) => Number(event.args.leafIndex) === 0)
    to = from - 1
  }
  check(seenFirst, `the pool's first deposit was not found within ${LOG_MAX_BLOCKS} blocks`)
  events.sort((a, b) => Number(a.args.leafIndex) - Number(b.args.leafIndex))
  checkEq(BigInt(events.length), BigInt(await pool.nextIndex()), 'number of deposits found')
  events.forEach((event, i) => checkEq(Number(event.args.leafIndex), i, 'deposit leaf order'))
  return events
}

const parseLogs = (iface, receipt, name) => receipt.logs.map((log) => { try { return iface.parseLog(log) } catch (e) { return null } }).find((log) => log && log.name === name)

let proverCache
async function getProver(keys) {
  if (!proverCache) proverCache = await tornado.loadProver(keys)
  return proverCache
}

// --------------------------------------------------------------------------- steps

const steps = {}

steps.setup = async (args, _state, out) => {
  const ctx = await connect(args, null)
  const { fork, provider, governance, torn, relayerRegistry, instanceRegistry, feeManager } = ctx
  const state = {
    rpc: args.rpc,
    keys: args.keys,
    chainId: ctx.chainId,
    forkBlock: ctx.forkBlock,
    proposal: args.proposal,
    simulatedPhase1: null,
    pool: null,
    parties: {},
    fees: {},
    notes: [],
    withdrawals: [],
    sweeps: [],
    phase2: null,
    claim: null,
    refusals: [],
    transcripts: []
  }
  out.heading('Setup')
  out.item('fork', `mainnet block ${ctx.forkBlock}, local anvil at ${args.rpc}`)

  // ---- the pool: already there, or deployed by passing the proposal through Governance on the fork
  let pool = await findPool(ctx)
  if (pool) {
    out.item('pool', `${pool.target}`)
    out.pass('the pool is in the InstanceRegistry and enabled: phase I has been executed on mainnet')
  } else {
    out.item('phase I', `not executed yet at this block: SIMULATING it on the fork with the proposal deployed on mainnet, ${args.proposal}`)
    ensure(out, 'the proposal contract exists on mainnet', (await provider.getCode(args.proposal)) !== '0x', args.proposal)
    const asVoter = await ensureVoter(ctx, state, out)
    const before = (await instanceRegistry.getAllInstanceAddresses()).length
    const { proposalId, execution } = await passProposal(fork, governance, asVoter, args.proposal, DESCRIPTION)
    out.pass(`the proposal was proposed, voted and executed through the live Governance contract (proposal #${proposalId}, execution ${execution.gasUsed.toLocaleString('en-US')} gas)`)
    const added = parseLogs(new ethers.Interface(artifact('AddEthPoolsProposal').abi), execution, 'PoolAdded')
    ensure(out, 'the execution emitted PoolAdded', added, added && `pool ${added.args.instance}`)
    pool = ctx.at(added.args.instance, ABI.pool)
    const found = await findPool(ctx)
    ensure(out, 'the pool is in the InstanceRegistry and enabled', found && found.target === pool.target, `${before} → ${before + 1} instances`)
    state.simulatedPhase1 = { proposalId: Number(proposalId), gasUsed: execution.gasUsed, block: execution.blockNumber, instancesBefore: before, instancesAfter: before + 1 }
  }
  state.pool = pool.target

  // ---- the fees, as the contracts have them
  const [denomination, protocolFee, premium, poolFee] = await Promise.all([pool.denomination(), pool.protocolFeePercentage(), pool.directWithdrawPremiumPercentage(), pool.directWithdrawFee()])
  const registry = await instanceRegistry.instances(pool.target)
  const tornFee = await feeManager.instanceFee(pool.target)
  verify(out, 'the pool\'s denomination', denomination, DENOMINATION, eth)
  out.item('fee settings', `protocol fee ${protocolFee} and premium ${premium}, in 1/10000 of the note (${percent((denomination * protocolFee) / BPS, denomination)} and ${percent((denomination * premium) / BPS, denomination)})`)
  verify(out, 'the pool\'s fee on withdrawals without a registered relayer (protocol fee + premium)', poolFee, (denomination * (protocolFee + premium)) / BPS, eth)
  verify(out, 'the InstanceRegistry\'s protocol fee for the pool, which sets the TORN burned on relayer withdrawals', BigInt(registry.protocolFeePercentage), protocolFee)
  ensure(out, 'the FeeManager has a TORN fee for the pool', tornFee > 0n, `${tornAmt(tornFee)} per withdrawal, ${percent((denomination * protocolFee) / BPS, denomination)} of the note at its oracle price`)
  Object.assign(state.fees, { denomination, protocolFee, premium, poolFee, registryFee: BigInt(registry.protocolFeePercentage), tornFee })

  // ---- the parties
  const depositor = await fork.account('phase1/depositor', '3')
  const relayer = ADDRESS.registeredRelayer
  const unregistered = await fork.account('phase1/unregistered-relayer', '1')
  const staker = await fork.account('phase1/staker', '1')
  out.item('depositor', `${depositor} (a user, given 3 ETH on the fork)`)
  out.item('relayer', `${relayer} (a relayer registered on mainnet; impersonated on the fork, its software is not run)`)
  out.item('unregistered', `${unregistered} (an address that never registered as a relayer)`)
  out.item('staker', `${staker} (given ${fmt(STAKER_LOCK)} TORN on the fork)`)
  await fork.setBalance(relayer, '1')
  verify(out, 'the relayer is registered (RelayerRegistry.workers)', await relayerRegistry.workers(relayer), relayer)
  const stake = await relayerRegistry.getRelayerBalance(relayer)
  ensure(out, 'the relayer has stake to burn from', stake > 0n, tornAmt(stake))
  verify(out, 'the unregistered relayer is not registered', await relayerRegistry.workers(unregistered), ZERO_ADDRESS)
  await fork.setTorn(staker, STAKER_LOCK)
  const asStaker = await fork.as(staker)
  await fork.mined(torn.connect(asStaker).approve(ADDRESS.governance, STAKER_LOCK), 'staker approve')
  await fork.mined(governance.connect(asStaker).lockWithApproval(STAKER_LOCK), 'staker lock')
  const totalLocked = await torn.balanceOf(await governance.userVault())
  verify(out, 'the staker locked its TORN in Governance', await governance.lockedBalance(staker), STAKER_LOCK, (v) => `${fmt(v)} TORN`)
  out.item('TORN locked', `${fmt(totalLocked, 2)} TORN in Governance in all; the staker holds ${percent(STAKER_LOCK, totalLocked)} of it`)
  Object.assign(state.parties, { depositor, relayer, unregistered, staker, stakerLock: STAKER_LOCK, totalLockedAtSetup: totalLocked })
  out.item('staking', `${ADDRESS.staking}, implementation ${ethers.dataSlice(await provider.getStorage(ADDRESS.staking, IMPLEMENTATION_SLOT), 12)} (live today: it cannot take ETH)`)
  return state
}

steps.deposit = async (args, state, out) => {
  const ctx = await connect(args, state)
  const { fork, provider, router, pool } = ctx
  const n = state.notes.length + 1
  const note = await tornado.createNote(0.01, state.chainId)
  const asDepositor = await fork.as(state.parties.depositor)
  const poolBefore = await provider.getBalance(pool.target)
  out.heading(`Deposit ${n}`)
  out.item('note', `${note.text} (new, made by the user)`)
  out.item('deposited by', `${state.parties.depositor} through the Router, as the UI does`)
  const receipt = await fork.mined(router.connect(asDepositor).deposit(pool.target, tornado.toHex(note.commitment), '0x', { value: state.fees.denomination }), `deposit ${n}`)
  out.item('tx', `${receipt.hash} (${receipt.gasUsed.toLocaleString('en-US')} gas, paid by the depositor)`)
  const deposited = parseLogs(pool.interface, receipt, 'Deposit')
  ensure(out, 'the pool emitted Deposit', deposited, deposited && `leaf index ${deposited.args.leafIndex}`)
  verify(out, 'the deposit carries the note\'s commitment', BigInt(deposited.args.commitment), note.commitment, (v) => tornado.toHex(v))
  verify(out, 'the leaf index is the next one', Number(deposited.args.leafIndex), state.notes.length)
  const poolAfter = await provider.getBalance(pool.target)
  verify(out, 'the pool\'s balance rose by the note', poolAfter - poolBefore, state.fees.denomination, eth)
  out.item('pool balance', `${fmt(poolBefore)} → ${fmt(poolAfter)} ETH`)
  state.notes.push({ n, text: note.text, leafIndex: Number(deposited.args.leafIndex), tx: receipt.hash, gas: receipt.gasUsed, block: receipt.blockNumber, spent: false })
  return state
}

steps.withdraw = async (args, state, out) => {
  const ctx = await connect(args, state)
  const { fork, provider, router, pool, relayerRegistry, feeManager } = ctx
  const pathName = args.via
  // self: from the user's wallet straight to the pool; router: from the user's wallet through the Router
  const noRelayer = pathName === 'self' || pathName === 'router'
  const entry = state.notes.find((note) => !note.spent)
  check(entry, 'no unspent note: run `deposit` first')
  const { denomination, poolFee } = state.fees
  const n = state.withdrawals.length + 1
  out.heading(`Withdrawal ${n}: ${PATHS[pathName].toLowerCase()}`)
  out.item('fee setting', `protocol fee ${percent((denomination * state.fees.protocolFee) / BPS, denomination)}, premium ${percent((denomination * state.fees.premium) / BPS, denomination)}: a registered relayer burns the protocol fee in TORN, any other path pays ${fmt(poolFee)} ETH (${percent(poolFee, denomination)})`)

  // ---- the user rebuilds the tree from the pool's events and proves its note is in it
  const note = await tornado.parseNote(entry.text)
  out.item('note', `${entry.text} (deposit ${entry.n})`)
  const deposits = await collectDeposits(ctx, pool)
  const tree = await tornado.buildTree(deposits.map((event) => event.args.commitment))
  verify(out, 'the Merkle tree rebuilt from the pool\'s Deposit events has the pool\'s root', tornado.toHex(tree.root), await pool.getLastRoot())
  const leafIndex = deposits.findIndex((event) => BigInt(event.args.commitment) === note.commitment)
  verify(out, 'the note is among the deposits, at its leaf index', leafIndex, entry.leafIndex)

  const recipient = await fork.account(`phase1/recipient-${n}`, noRelayer ? '0.02' : undefined)
  const relayerAddress = pathName === 'registered' ? state.parties.relayer : pathName === 'unregistered' ? state.parties.unregistered : ZERO_ADDRESS
  const relayerFee = relayerAddress === ZERO_ADDRESS ? 0n : (denomination * RELAYER_FEE_BPS) / BPS
  const expected = expectedOutcome({ path: pathName, denomination, poolFee, relayerFee })
  const prover = await getProver(args.keys)
  const started = Date.now()
  const proof = await tornado.proveWithdrawal(prover, { note, tree, leafIndex, recipient, relayer: relayerAddress, fee: relayerFee, refund: expected.refund })
  const proofSeconds = (Date.now() - started) / 1000
  const withdrawArgs = [proof, tornado.toHex(tree.root), tornado.toHex(note.nullifierHash), recipient, relayerAddress, relayerFee, expected.refund]
  out.item('proof', `made in ${proofSeconds.toFixed(1)} s with the classic UI's circuit; it binds the recipient ${recipient}, the relayer ${relayerAddress === ZERO_ADDRESS ? '(none)' : relayerAddress}, the relayer fee ${fmt(relayerFee)} ETH and the highest pool fee the user accepts, ${fmt(expected.refund)} ETH`)

  // ---- who sends it, and to which contract
  const sender = noRelayer ? recipient : relayerAddress
  const asSender = await fork.as(sender)
  const viaRouter = pathName !== 'self'
  const call = (signer, a, dry) => {
    const target = viaRouter ? router.connect(signer) : pool.connect(signer)
    const fn = dry ? target.withdraw.staticCall : target.withdraw
    return viaRouter ? fn(pool.target, ...a, { gasLimit: WITHDRAW_GAS_LIMIT }) : fn(...a, { gasLimit: WITHDRAW_GAS_LIMIT })
  }
  out.item('sent by', `${sender} (${pathName === 'self' ? 'the recipient, from its own wallet, straight to the pool' : pathName === 'router' ? 'the recipient, from its own wallet, through the Router without naming a relayer' : pathName === 'registered' ? 'the registered relayer, through the Router' : 'the unregistered relayer, through the Router'})`)

  // ---- things that must not work, tried without sending anything
  const refuse = async (what, promise, expectedReason) => {
    const reason = await fork.revertReason(promise)
    ensure(out, `refused: ${what}`, reason && reason.toLowerCase().includes(expectedReason.toLowerCase()), `"${reason}"`)
    state.refusals.push({ withdrawal: n, what, reason })
  }
  if (pathName === 'registered') {
    const impostor = await fork.account('phase1/impostor', '1')
    await refuse('someone else sends the relayer\'s proof through the Router', call(await fork.as(impostor), withdrawArgs, true), 'Only custom relayer')
    await refuse('the relayer sends its proof straight to the pool, skipping the Router and the TORN burn', pool.connect(asSender).withdraw.staticCall(...withdrawArgs, { gasLimit: WITHDRAW_GAS_LIMIT }), 'above what the note owner accepted')
  }
  if (pathName === 'unregistered') {
    await refuse('the registered relayer sends the unregistered relayer\'s proof through the Router', call(await fork.as(state.parties.relayer), withdrawArgs, true), 'only relayer')
  }
  if (state.fees.previousPoolFee !== undefined && state.fees.previousPoolFee < poolFee && expected.poolKeeps > 0n) {
    // A fee raise cannot be applied to a proof made before it: the user accepted the old fee in the proof.
    const stale = await tornado.proveWithdrawal(prover, { note, tree, leafIndex, recipient, relayer: relayerAddress, fee: relayerFee, refund: state.fees.previousPoolFee })
    await refuse(`a proof made before the fee raise, accepting only the old fee of ${fmt(state.fees.previousPoolFee)} ETH`, call(asSender, [stale, ...withdrawArgs.slice(1, 6), state.fees.previousPoolFee], true), 'above what the note owner accepted')
    delete state.fees.previousPoolFee
  }
  if (noRelayer) {
    const thief = await fork.account('phase1/thief', '1')
    const redirected = [...withdrawArgs]
    redirected[3] = thief
    await refuse('someone copies the proof and changes the recipient to their own address', call(await fork.as(thief), redirected, true), 'Invalid withdraw proof')
  }

  // ---- the withdrawal, and where every wei went
  const before = {
    recipient: await provider.getBalance(recipient),
    relayer: relayerAddress === ZERO_ADDRESS ? 0n : await provider.getBalance(relayerAddress),
    pool: await provider.getBalance(pool.target),
    staking: await provider.getBalance(ADDRESS.staking),
    accrued: await pool.accruedProtocolFees(),
    stake: await relayerRegistry.getRelayerBalance(state.parties.relayer)
  }
  const receipt = await fork.mined(call(asSender, withdrawArgs, false), `withdrawal ${n}`)
  out.item('tx', `${receipt.hash} (${receipt.gasUsed.toLocaleString('en-US')} gas, ${fmt(receipt.gasCost, 9)} ETH, paid by the ${noRelayer ? 'user' : 'relayer'})`)
  const gasPaidBy = (address) => (address === sender ? receipt.gasCost : 0n)
  const userReceives = (await provider.getBalance(recipient)) - before.recipient + gasPaidBy(recipient)
  const relayerReceives = relayerAddress === ZERO_ADDRESS ? 0n : (await provider.getBalance(relayerAddress)) - before.relayer + gasPaidBy(relayerAddress)
  const poolPaid = before.pool - (await provider.getBalance(pool.target))
  const toStaking = (await provider.getBalance(ADDRESS.staking)) - before.staking
  const kept = (await pool.accruedProtocolFees()) - before.accrued
  const tornBurned = before.stake - (await relayerRegistry.getRelayerBalance(state.parties.relayer))
  const feeEvent = parseLogs(pool.interface, receipt, 'ProtocolFeeCharged')

  verify(out, 'the note is now spent', await pool.isSpent(tornado.toHex(note.nullifierHash)), true)
  verify(out, `the user received (${percent(userReceives, denomination)} of the note${noRelayer ? `, before ${fmt(receipt.gasCost, 9)} ETH of its own gas` : ''})`, userReceives, expected.userReceives, eth)
  verify(out, relayerAddress === ZERO_ADDRESS ? 'no relayer, so no relayer fee' : `the relayer received (${percent(relayerReceives, denomination)})`, relayerReceives, expected.relayerReceives, eth)
  if (expected.burnsTorn) {
    const tornFee = await feeManager.instanceFee(pool.target)
    verify(out, 'DAO in TORN: burned from the relayer\'s stake, the FeeManager\'s fee for the pool', tornBurned, tornFee, tornAmt)
    if (state.fees.protocolFee > 0n) ensure(out, 'some TORN was burned', tornBurned > 0n, `${tornAmt(tornBurned)}, worth ${fmt((tornBurned * ((denomination * state.fees.protocolFee) / BPS)) / tornFee)} ETH at the FeeManager's price`)
    else ensure(out, 'no TORN burned: the protocol fee is 0', tornBurned === 0n)
    ensure(out, 'DAO in ETH: none, the pool emitted no ProtocolFeeCharged', !feeEvent)
  } else {
    verify(out, 'DAO in TORN: none, nothing burned from the relayer\'s stake', tornBurned, 0n, tornAmt)
    if (expected.poolKeeps > 0n) ensure(out, 'DAO in ETH: the pool emitted ProtocolFeeCharged(amount, paidToStaking = false)', feeEvent && feeEvent.args.amount === expected.poolKeeps && feeEvent.args.paidToStaking === false, feeEvent && `amount ${fmt(feeEvent.args.amount)} ETH, paidToStaking ${feeEvent.args.paidToStaking}`)
    else ensure(out, 'DAO in ETH: none, the fee is 0 and the pool emitted no ProtocolFeeCharged', !feeEvent)
  }
  verify(out, `the pool kept for the lockers (${percent(kept, denomination)})`, kept, expected.poolKeeps, eth)
  verify(out, 'what left the pool', poolPaid, denomination - expected.poolKeeps, eth)
  verify(out, 'the staking contract received nothing: it cannot take ETH before phase II', toStaking, 0n, eth)
  await refuse('the same note is withdrawn a second time', call(asSender, withdrawArgs, true), 'already spent')
  out.item('pool now holds', `${fmt(await pool.accruedProtocolFees())} ETH of fees waiting for phase II`)

  // The TORN burned, valued at the oracle price the FeeManager used: tornFee TORN is 0.3% of the note.
  const tornInEth = tornBurned === 0n || state.fees.tornFee === 0n ? 0n : (tornBurned * ((denomination * state.fees.protocolFee) / BPS)) / state.fees.tornFee
  entry.spent = true
  state.withdrawals.push({
    n, pathName, note: entry.n, tx: receipt.hash, block: receipt.blockNumber, recipient, relayerAddress, relayerFee, sender, viaRouter,
    userReceives, relayerReceives, kept, tornBurned, tornInEth, poolPaid, gas: receipt.gasUsed, gasCost: receipt.gasCost,
    gasPaidBy: noRelayer ? 'user' : 'relayer', proofSeconds, accruedAfter: await pool.accruedProtocolFees(),
    feeSetting: { protocolFee: state.fees.protocolFee, premium: state.fees.premium }
  })
  return state
}

/** Reads the pool's, the registry's and the FeeManager's fee settings for the pool. */
async function readFees(ctx, pool) {
  const [denomination, protocolFee, premium, poolFee] = await Promise.all([pool.denomination(), pool.protocolFeePercentage(), pool.directWithdrawPremiumPercentage(), pool.directWithdrawFee()])
  const registry = await ctx.instanceRegistry.instances(pool.target)
  const tornFee = await ctx.feeManager.instanceFee(pool.target)
  return { denomination, protocolFee, premium, poolFee, registryFee: BigInt(registry.protocolFeePercentage), tornFee }
}

steps.fees = async (args, state, out) => {
  const ctx = await connect(args, state)
  const { fork, governance, pool } = ctx
  const protocol = BigInt(args.protocol)
  const premium = BigInt(args.premium)
  const { denomination } = state.fees
  const pct = (bps) => percent((denomination * bps) / BPS, denomination)
  out.heading(`Fee change by proposal: protocol fee ${pct(protocol)}, premium ${pct(premium)}`)
  out.item('before', `protocol fee ${state.fees.protocolFee} (${pct(state.fees.protocolFee)}), premium ${state.fees.premium} (${pct(state.fees.premium)}), registry ${state.fees.registryFee}, FeeManager ${tornAmt(state.fees.tornFee)} per relayer withdrawal`)
  out.item('what', `a FeeChangeProposal contract is deployed on the fork and passed through the live Governance contract (SIMULATED vote). It sets the pool's protocol fee to ${protocol} and premium to ${premium}, re-registers the pool in the InstanceRegistry with protocol fee ${protocol}, and refreshes the FeeManager's TORN fee`)
  const asVoter = await ensureVoter(ctx, state, out)
  const art = artifact('FeeChangeProposal')
  const proposal = await new ethers.ContractFactory(art.abi, art.bytecode.object, asVoter).deploy(pool.target, protocol, premium)
  await proposal.waitForDeployment()
  const { proposalId, execution } = await passProposal(fork, governance, asVoter, proposal.target, `Set the ${fmt(denomination)} ETH pool fees to ${protocol} + ${premium}`)
  out.item('proposal', `${proposal.target} (#${proposalId}, executed with ${execution.gasUsed.toLocaleString('en-US')} gas)`)
  const fees = await readFees(ctx, pool)
  verify(out, 'the pool\'s protocol fee', fees.protocolFee, protocol)
  verify(out, 'the pool\'s premium', fees.premium, premium)
  verify(out, `the pool\'s fee on withdrawals without a registered relayer (${pct(protocol + premium)})`, fees.poolFee, (denomination * (protocol + premium)) / BPS, eth)
  verify(out, 'the InstanceRegistry\'s protocol fee for the pool', fees.registryFee, protocol)
  const recomputed = await ctx.feeManager.calculatePoolFee(pool.target)
  verify(out, 'the FeeManager\'s TORN fee was refreshed (cached = recomputed)', fees.tornFee, recomputed, tornAmt)
  if (protocol === 0n) verify(out, 'with a protocol fee of 0 the FeeManager charges relayers nothing', fees.tornFee, 0n, tornAmt)
  else ensure(out, `the FeeManager\'s TORN fee is ${pct(protocol)} of the note at its oracle price`, fees.tornFee > 0n, tornAmt(fees.tornFee))
  state.feeChanges = state.feeChanges || []
  state.feeChanges.push({ proposal: proposal.target, proposalId: Number(proposalId), before: { ...state.fees }, after: fees })
  state.fees = { ...fees, previousPoolFee: state.fees.poolFee }
  out.item('after', `protocol fee ${fees.protocolFee} (${pct(fees.protocolFee)}), premium ${fees.premium} (${pct(fees.premium)}): a registered relayer now burns ${tornAmt(fees.tornFee)}, any other path pays ${fmt(fees.poolFee)} ETH`)
  return state
}

steps.caps = async (args, state, out) => {
  const ctx = await connect(args, state)
  const { fork, provider, governance, pool } = ctx
  out.heading('Fee values out of bounds')
  const feeCap = await pool.MAX_PROTOCOL_FEE_PERCENTAGE()
  const premiumCap = await pool.MAX_DIRECT_WITHDRAW_PREMIUM_PERCENTAGE()
  const { denomination } = state.fees
  const pct = (bps) => percent((denomination * bps) / BPS, denomination)
  out.item('caps', `MAX_PROTOCOL_FEE_PERCENTAGE = ${feeCap} (${pct(feeCap)}), MAX_DIRECT_WITHDRAW_PREMIUM_PERCENTAGE = ${premiumCap} (${pct(premiumCap)}): constants in the pool, no proposal can change them`)
  const before = await readFees(ctx, pool)
  // Calls as Governance itself (impersonated), tried without sending anything
  await fork.setBalance(ADDRESS.governance, '1')
  const asGovernance = await fork.as(ADDRESS.governance)
  const refused = async (what, promise, expectedReason) => {
    const reason = await fork.revertReason(promise)
    ensure(out, `refused: ${what}`, reason && reason.toLowerCase().includes(expectedReason.toLowerCase()), `"${reason}"`)
  }
  await refused(`Governance sets the protocol fee to ${feeCap + 1n} (${pct(feeCap + 1n)})`, pool.connect(asGovernance).setProtocolFeePercentage.staticCall(feeCap + 1n), 'Fee above cap')
  await refused(`Governance sets the protocol fee to 10000 (100%)`, pool.connect(asGovernance).setProtocolFeePercentage.staticCall(10000n), 'Fee above cap')
  await refused(`Governance sets the premium to ${premiumCap + 1n} (${pct(premiumCap + 1n)})`, pool.connect(asGovernance).setDirectWithdrawPremiumPercentage.staticCall(premiumCap + 1n), 'Premium above cap')
  ensure(out, `the cap values themselves are accepted: protocol fee ${feeCap} and premium ${premiumCap} (tried without sending)`, (await fork.revertReason(pool.connect(asGovernance).setProtocolFeePercentage.staticCall(feeCap))) === null && (await fork.revertReason(pool.connect(asGovernance).setDirectWithdrawPremiumPercentage.staticCall(premiumCap))) === null)
  const anyone = await fork.account('phase1/anyone', '1')
  await refused('someone who is not Governance sets the protocol fee to 50', pool.connect(await fork.as(anyone)).setProtocolFeePercentage.staticCall(50n), 'Only governance')
  await refused('someone who is not Governance sets the premium to 0', pool.connect(await fork.as(anyone)).setDirectWithdrawPremiumPercentage.staticCall(0n), 'Only governance')
  // A real proposal carrying a value above the cap: it passes the vote, but cannot be executed
  const asVoter = await ensureVoter(ctx, state, out)
  const art = artifact('FeeChangeProposal')
  const proposal = await new ethers.ContractFactory(art.abi, art.bytecode.object, asVoter).deploy(pool.target, feeCap + 1n, state.fees.premium)
  await proposal.waitForDeployment()
  await fork.mined(governance.connect(asVoter).propose(proposal.target, `Set the pool protocol fee to ${feeCap + 1n}`), 'propose')
  const proposalId = await governance.proposalCount()
  await fork.skipTime((await governance.VOTING_DELAY()) + 1n)
  await fork.mined(governance.connect(asVoter).castVote(proposalId, true), 'vote')
  await fork.skipTime((await governance.VOTING_PERIOD()) + (await governance.EXECUTION_DELAY()) + 1n)
  out.item('proposal', `${proposal.target} (#${proposalId}) would set the protocol fee to ${feeCap + 1n}; it was proposed and voted (SIMULATED), then executed`)
  await refused(`executing proposal #${proposalId}`, governance.connect(asVoter).execute.staticCall(proposalId), 'reverted')
  out.item('why', 'Governance delegatecalls the proposal, the pool answers "Fee above cap" (checked above) and Governance passes the revert on; the proposal stays unexecuted and expires')
  const after = await readFees(ctx, pool)
  verify(out, 'the protocol fee is unchanged', after.protocolFee, before.protocolFee)
  verify(out, 'the premium is unchanged', after.premium, before.premium)
  verify(out, 'the InstanceRegistry fee is unchanged', after.registryFee, before.registryFee)
  state.caps = { feeCap, premiumCap, proposal: proposal.target, proposalId: Number(proposalId) }
  return state
}

steps.sweep = async (args, state, out) => {
  const ctx = await connect(args, state)
  const { fork, provider, pool } = ctx
  const anyone = await fork.account('phase1/anyone', '1')
  const before = { accrued: await pool.accruedProtocolFees(), pool: await provider.getBalance(pool.target), staking: await provider.getBalance(ADDRESS.staking) }
  check(before.accrued > 0n, 'the pool holds no fees: run some withdrawals first')
  const upgraded = state.phase2 !== null
  out.heading(`Sweep ${upgraded ? 'after' : 'before'} the staking upgrade`)
  out.item('called by', `${anyone} (anyone may call sweepProtocolFees())`)
  out.item('pool holds', `${fmt(before.accrued)} ETH of fees (accruedProtocolFees); staking contract balance ${fmt(before.staking)} ETH`)
  if (!upgraded) {
    const reason = await fork.revertReason(pool.connect(await fork.as(anyone)).sweepProtocolFees.staticCall())
    ensure(out, 'the sweep was refused, as it must be before the upgrade', reason && reason.includes('did not go thru'), `"${reason}"`)
    out.item('why', 'the sweep pays the fees by calling addEthRewards() on the staking contract, and the implementation live today has no such function')
    verify(out, 'the fees are still in the pool', await pool.accruedProtocolFees(), before.accrued, eth)
    verify(out, 'the staking contract received nothing', (await provider.getBalance(ADDRESS.staking)) - before.staking, 0n, eth)
    state.sweeps.push({ afterUpgrade: false, refused: true, reason, accrued: before.accrued, pass: true })
    return state
  }
  const receipt = await fork.mined(pool.connect(await fork.as(anyone)).sweepProtocolFees(), 'sweep')
  out.item('tx', `${receipt.hash} (${receipt.gasUsed.toLocaleString('en-US')} gas)`)
  const swept = parseLogs(pool.interface, receipt, 'ProtocolFeesSwept')
  ensure(out, 'the pool emitted ProtocolFeesSwept for the whole accrued amount', swept && swept.args.amount === before.accrued, swept && eth(swept.args.amount))
  verify(out, 'nothing is left in the pool', await pool.accruedProtocolFees(), 0n, eth)
  verify(out, 'the pool\'s balance dropped by the fees', before.pool - (await provider.getBalance(pool.target)), before.accrued, eth)
  verify(out, 'the staking contract received the fees', (await provider.getBalance(ADDRESS.staking)) - before.staking, before.accrued, eth)
  const totalLocked = await ctx.torn.balanceOf(await ctx.governance.userVault())
  state.sweeps.push({ afterUpgrade: true, refused: false, amount: before.accrued, tx: receipt.hash, gas: receipt.gasUsed, totalLocked, pass: true })
  out.item('staking', `balance ${fmt(before.staking)} → ${fmt(await provider.getBalance(ADDRESS.staking))} ETH, now owed to the ${fmt(totalLocked, 2)} TORN locked in Governance, pro rata`)
  return state
}

steps.phase2 = async (args, state, out) => {
  check(state.phase2 === null, 'phase II has already been simulated on this fork')
  const ctx = await connect(args, state)
  const { fork, provider, governance, staking } = ctx
  out.heading('Phase II, SIMULATED on the fork: the staking upgrade')
  out.item('what', 'StakingUpgradeProposal is deployed on the fork and passed through the live Governance contract: proposed, voted with an impersonated quorum, timelock skipped, executed. On mainnet this is a separate proposal.')
  const asVoter = await ensureVoter(ctx, state, out)
  const implBefore = ethers.dataSlice(await provider.getStorage(ADDRESS.staking, IMPLEMENTATION_SLOT), 12)
  const art = artifact('StakingUpgradeProposal')
  const proposal = await new ethers.ContractFactory(art.abi, art.bytecode.object, asVoter).deploy()
  await proposal.waitForDeployment()
  const { proposalId, execution } = await passProposal(fork, governance, asVoter, proposal.target, STAKING_DESCRIPTION)
  out.item('proposal', `${proposal.target} (#${proposalId}, executed with ${execution.gasUsed.toLocaleString('en-US')} gas)`)
  const implAfter = ethers.dataSlice(await provider.getStorage(ADDRESS.staking, IMPLEMENTATION_SLOT), 12)
  ensure(out, 'the staking proxy points to a new implementation', implAfter !== implBefore, `${implBefore} → ${implAfter}`)
  ensure(out, 'the new implementation has code', (await provider.getCode(implAfter)) !== '0x')
  verify(out, 'the staker is owed nothing yet: the fees are still in the pool until someone sweeps them', await staking.checkEthReward(state.parties.staker), 0n, eth)
  state.phase2 = { proposal: proposal.target, proposalId: Number(proposalId), gasUsed: execution.gasUsed, implBefore, implAfter, block: execution.blockNumber }
  return state
}

steps.claim = async (args, state, out) => {
  const sweep = state.sweeps.find((s) => s.afterUpgrade)
  check(state.phase2 && sweep, 'nothing to claim: run `phase2` and then `sweep` first')
  const ctx = await connect(args, state)
  const { fork, provider, staking } = ctx
  const { staker, stakerLock } = state.parties
  out.heading('A TORN locker claims its ETH')
  out.item('staker', `${staker}, ${fmt(stakerLock)} of ${fmt(sweep.totalLocked, 2)} TORN locked (${percent(stakerLock, sweep.totalLocked)})`)
  const share = (sweep.amount * stakerLock) / sweep.totalLocked
  const owed = await staking.checkEthReward(staker)
  checkClose(owed, share, 2n, 'the staker is owed its share of the swept fees')
  out.pass(`the staker is owed its share of the ${fmt(sweep.amount)} ETH swept: ${fmt(owed, 12)} ETH shown by checkEthReward() (expected ${fmt(share, 12)} ETH, within rounding)`)
  const before = await provider.getBalance(staker)
  const receipt = await fork.mined(staking.connect(await fork.as(staker)).getEthReward(), 'getEthReward')
  out.item('tx', `${receipt.hash} (${receipt.gasUsed.toLocaleString('en-US')} gas)`)
  const claimed = (await provider.getBalance(staker)) - before + receipt.gasCost
  verify(out, 'getEthReward() paid what was owed', claimed, owed, (v) => `${fmt(v, 12)} ETH`)
  verify(out, 'nothing is left to claim', await staking.checkEthReward(staker), 0n, eth)
  const left = await provider.getBalance(ADDRESS.staking)
  const voterOwed = state.parties.voter ? await staking.checkEthReward(state.parties.voter) : null
  state.claim = { owed, claimed, tx: receipt.hash, gas: receipt.gasUsed, share, left, voterOwed }
  out.item('staking', `still holds ${fmt(left, 12)} ETH for the other lockers${voterOwed !== null ? `, for example ${fmt(voterOwed, 12)} ETH for the voter with ${fmt(state.parties.voterLock)} TORN locked` : ''}`)
  return state
}

steps.report = async (args, state, out) => {
  check(state.transcripts.length > 0, 'nothing to report: run some steps first')
  fs.writeFileSync(args.out, render(state))
  out.heading('Report')
  out.item('written', path.relative(process.cwd(), args.out))
  return state
}

// --------------------------------------------------------------------------- main

/** Runs one step as a test: records what it verifies, the expected result, PASS or FAIL and the output. */
async function runStep(step, args, state) {
  const command = `node e2e/src/phase1.js ${step}${step === 'withdraw' ? ` --via ${args.via}` : ''}${step === 'fees' ? ` --protocol ${args.protocol} --premium ${args.premium}` : ''}`
  const out = new Transcript(command)
  const before = checksPassed()
  const opts = { via: args.via, protocol: args.protocol, premium: args.premium, upgraded: state ? state.phase2 !== null : false }
  let next = state
  let error = null
  try {
    next = await steps[step](args, state, out)
  } catch (e) {
    error = (e.message || String(e)).replace(/^CHECK FAILED: /, '')
    out.fail(`FAILED: ${error}`)
  }
  const checks = checksPassed() - before
  if (!error && step !== 'report') out.print(`PASS: ${checks} checks matched the design`)
  if (step !== 'report' && next) {
    const { title, verifies, expected } = spec(step, opts, next.fees)
    next.transcripts.push({ command, title, verifies, expected, pass: !error, error, checks, lines: out.lines })
  }
  if (next) saveState(next)
  console.log('')
  if (error) throw Object.assign(new Error(error), { step, state: next })
  return next
}

async function main() {
  const { step, args, given } = parseArgs(process.argv)
  if (step === 'all') {
    let state = null
    try {
      for (const command of ALL) {
        const [name, ...rest] = command.split(' ')
        const options = {}
        for (let i = 0; i < rest.length; i += 2) options[rest[i].replace(/^--/, '')] = rest[i + 1]
        state = await runStep(name, { ...args, ...options }, state)
      }
      console.log(`All tests passed. Report written to ${path.relative(process.cwd(), args.out)}`)
    } catch (e) {
      if (e.state && e.state.transcripts.length) {
        fs.writeFileSync(args.out, render(e.state))
        console.error(`Step ${e.step} FAILED. Report written to ${path.relative(process.cwd(), args.out)}`)
      }
      process.exitCode = 1
    }
  } else if (step === 'setup') {
    await runStep(step, args, null)
  } else {
    // The fork and the keys folder are remembered from setup, unless given again.
    const state = loadState()
    if (!given.rpc) args.rpc = state.rpc
    if (!given.keys) args.keys = state.keys
    await runStep(step, args, state)
  }
  if (proverCache) proverCache.groth16.terminate()
}

main().catch((error) => {
  if (!error.step) console.error(`\n${error.message || error}`) // a failed step has already printed its reason
  if (proverCache) proverCache.groth16.terminate()
  process.exit(1)
})
