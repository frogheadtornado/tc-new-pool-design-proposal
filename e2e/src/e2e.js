'use strict'
// End-to-end test of the fee-enforced pools and the staking upgrade on a local mainnet fork.
//
// Expects an anvil fork (started with --auto-impersonate) on which script/Deploy.s.sol has been run
// (it deploys the proposal; the proposal deploys the pool), and the proposal's address in --proposal.
// It then acts as each party would: a TORN holder passes the proposal through Governance, users make
// notes, deposit and withdraw with real zero-knowledge proofs through every path, and a staker
// collects TORN and ETH rewards. Every amount is measured from balances on the fork and compared
// with what the design says; any mismatch stops the run. The measurements go into a Markdown report.
//
// Use ./run.sh, which starts the fork, deploys and calls this file.

const { execFileSync } = require('child_process')
const fs = require('fs')
const path = require('path')
const { ethers } = require('ethers')
const tornado = require('./tornado')

const REPO = path.resolve(__dirname, '..', '..')

const ADDRESS = {
  governance: '0x5efda50f22d34F262c29268506C5Fa42cB56A1Ce',
  torn: '0x77777FeDdddFfC19Ff86DB637967013e6C6A116C',
  instanceRegistry: '0xB20c66C4DE72433F3cE747b58B86830c459CA911',
  relayerRegistry: '0x58E8dCC13BE9780fC42E8723D8EaD4CF46943dF2',
  router: '0xd90e2f925DA726b50C4Ed8D0Fb90Ad053324F31b',
  staking: '0x5B3f656C80E8ddb9ec01Dd9018815576E9238c29',
  feeManager: '0x5f6c97C6AD7bdd0AE7E0Dd4ca33A4ED3fDabD4D7',
  legacy1EthPool: '0x47CE0C6eD5B0Ce3d3A51fdb1C52DC66a7c3c2936',
  // A relayer registered on mainnet, with stake. Its software is not run: the test sends the
  // transaction from its address, which is all the contracts see of a relayer.
  registeredRelayer: '0x4750BCfcC340AA4B31be7e71fa072716d28c29C5'
}

const ABI = {
  governance: [
    'function QUORUM_VOTES() view returns (uint256)',
    'function VOTING_DELAY() view returns (uint256)',
    'function VOTING_PERIOD() view returns (uint256)',
    'function EXECUTION_DELAY() view returns (uint256)',
    'function proposalCount() view returns (uint256)',
    'function state(uint256) view returns (uint8)',
    'function lockedBalance(address) view returns (uint256)',
    'function userVault() view returns (address)',
    'function lockWithApproval(uint256)',
    'function unlock(uint256)',
    'function propose(address,string) returns (uint256)',
    'function castVote(uint256,bool)',
    'function execute(uint256) payable'
  ],
  torn: ['function balanceOf(address) view returns (uint256)', 'function approve(address,uint256) returns (bool)'],
  staking: [
    'function checkReward(address) view returns (uint256)',
    'function checkEthReward(address) view returns (uint256)',
    'function getReward()',
    'function getEthReward()'
  ],
  relayerRegistry: [
    'function workers(address) view returns (address)',
    'function getRelayerBalance(address) view returns (uint256)'
  ],
  instanceRegistry: [
    'function getAllInstanceAddresses() view returns (address[])',
    'function instances(address) view returns (bool isERC20, address token, uint8 state, uint24 uniswapPoolSwappingFee, uint32 protocolFeePercentage)'
  ],
  feeManager: [
    'function instanceFee(address) view returns (uint160)',
    'function calculatePoolFee(address) view returns (uint160)'
  ],
  router: [
    'function deposit(address,bytes32,bytes) payable',
    'function withdraw(address,bytes,bytes32,bytes32,address,address,uint256,uint256) payable'
  ],
  pool: [
    'function denomination() view returns (uint256)',
    'function protocolFeePercentage() view returns (uint256)',
    'function directWithdrawPremiumPercentage() view returns (uint256)',
    'function directWithdrawFee() view returns (uint256)',
    'function accruedProtocolFees() view returns (uint256)',
    'function getLastRoot() view returns (bytes32)',
    'function isSpent(bytes32) view returns (bool)',
    'function withdraw(bytes,bytes32,bytes32,address,address,uint256,uint256) payable',
    'function sweepProtocolFees()',
    'event Deposit(bytes32 indexed commitment, uint32 leafIndex, uint256 timestamp)',
    'event ProtocolFeeCharged(address indexed relayer, uint256 amount, bool paidToStaking)'
  ]
}

const DESCRIPTION = 'Add a 0.01 ETH pool with enforced fees'
const STAKING_DESCRIPTION = 'Upgrade TornadoStakingRewards to share ETH fees among TORN lockers'
// Not a withdrawal: the point of the run at which the later proposal, the staking upgrade, is executed.
const STAKING_UPGRADE = 'stakingUpgrade'
const IMPLEMENTATION_SLOT = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc'
const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000'
const STATE_EXECUTED = 5n
// What a relayer charges the user in this test: 0.4% of the note, the usual rate on mainnet.
// (Live relayers add their gas cost on top; here the relayer simply pays the gas.)
const RELAYER_FEE_BPS = 40n
const BPS = 10000n
const STAKER_LOCK = ethers.parseEther('10000')
const WITHDRAW_GAS_LIMIT = 1_500_000n

const PATHS = {
  registered: 'Through a registered relayer (Router)',
  direct: 'Directly by the user (no relayer)',
  routerNoRelayer: 'By the user through the Router (no relayer)',
  custom: 'Through an unregistered relayer (Router)'
}

// --------------------------------------------------------------------------- small helpers

function check(condition, message) {
  if (!condition) throw new Error(`CHECK FAILED: ${message}`)
}

function checkEq(actual, expected, what) {
  check(actual === expected, `${what}: got ${actual}, expected ${expected}`)
}

function checkClose(actual, expected, tolerance, what) {
  const diff = actual > expected ? actual - expected : expected - actual
  check(diff <= tolerance, `${what}: got ${actual}, expected ${expected} (tolerance ${tolerance})`)
}

/** An 18-decimal amount rounded to `places` decimals, without trailing zeros, thousands separated. */
function fmt(value, places = 8) {
  const unit = 10n ** BigInt(18 - places)
  const rounded = ((value + unit / 2n) / unit) * unit
  const [whole, fraction = ''] = ethers.formatEther(rounded).split('.')
  const trimmed = fraction.slice(0, places).replace(/0+$/, '')
  const grouped = whole.replace(/\B(?=(\d{3})+(?!\d))/g, ',')
  return trimmed ? `${grouped}.${trimmed}` : grouped
}

/** `part` as a percentage of `whole`, rounded to four decimals. */
function percent(part, whole) {
  return `${Number((part * 1000000n + whole / 2n) / whole) / 10000}%`
}

function parseArgs() {
  const args = {}
  for (let i = 2; i < process.argv.length; i += 2) args[process.argv[i].replace(/^--/, '')] = process.argv[i + 1]
  for (const name of ['rpc', 'keys', 'out', 'proposal']) check(args[name], `missing --${name}`)
  return args
}

// --------------------------------------------------------------------------- the fork

class Fork {
  constructor(rpcUrl) {
    this.provider = new ethers.JsonRpcProvider(rpcUrl, undefined, { pollingInterval: 50, cacheTimeout: -1 })
  }

  /** An address nobody uses on mainnet, derived from a label so that runs are comparable. */
  async account(label, etherBalance) {
    const address = ethers.getAddress(ethers.dataSlice(ethers.id(`tc-new-pool-design-proposal/e2e/${label}`), 12))
    check((await this.provider.getCode(address)) === '0x', `test account ${label} has code on mainnet`)
    if (etherBalance !== undefined) await this.setBalance(address, etherBalance)
    return address
  }

  /** Send transactions as `address`. The fork runs with --auto-impersonate, so no key is needed. */
  async as(address) {
    await this.provider.send('anvil_impersonateAccount', [address])
    return new ethers.JsonRpcSigner(this.provider, address)
  }

  async setBalance(address, etherBalance) {
    await this.provider.send('anvil_setBalance', [address, ethers.toQuantity(ethers.parseEther(etherBalance))])
  }

  /** Give `address` TORN by writing its balance (slot 0 mapping of the token). */
  async setTorn(address, amount) {
    const slot = ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(['address', 'uint256'], [address, 0]))
    await this.provider.send('anvil_setStorageAt', [ADDRESS.torn, slot, ethers.toBeHex(amount, 32)])
  }

  async skipTime(seconds) {
    await this.provider.send('evm_increaseTime', [Number(seconds)])
    await this.provider.send('evm_mine', [])
  }

  /** Wait for a transaction and return its receipt with the ETH its sender paid for gas. */
  async mined(txPromise, what) {
    const receipt = await (await txPromise).wait()
    check(receipt.status === 1, `${what} reverted`)
    receipt.gasCost = receipt.gasUsed * receipt.gasPrice
    return receipt
  }

  /** The revert reason of a call that must fail. */
  async revertReason(callPromise) {
    try {
      await callPromise
    } catch (error) {
      return error.reason || error.shortMessage || error.message
    }
    return null
  }
}

// --------------------------------------------------------------------------- the test

async function main() {
  const args = parseArgs()
  const fork = new Fork(args.rpc)
  const { provider } = fork
  const report = { checks: [], withdrawals: [] }

  const governance = new ethers.Contract(ADDRESS.governance, ABI.governance, provider)
  const torn = new ethers.Contract(ADDRESS.torn, ABI.torn, provider)
  const staking = new ethers.Contract(ADDRESS.staking, ABI.staking, provider)
  const relayerRegistry = new ethers.Contract(ADDRESS.relayerRegistry, ABI.relayerRegistry, provider)
  const instanceRegistry = new ethers.Contract(ADDRESS.instanceRegistry, ABI.instanceRegistry, provider)
  const feeManager = new ethers.Contract(ADDRESS.feeManager, ABI.feeManager, provider)
  const router = new ethers.Contract(ADDRESS.router, ABI.router, provider)
  const vault = await governance.userVault()

  const network = await provider.getNetwork()
  // The mainnet block the fork starts from; everything after it happened only on the fork.
  const forkBlock = Number((await provider.send('anvil_nodeInfo', [])).forkConfig.forkBlockNumber)
  report.chainId = network.chainId
  report.forkBlock = forkBlock

  // ---- what the deploy script put on the fork: the proposal, and nothing else
  const artifact = (name) => JSON.parse(fs.readFileSync(path.join(REPO, 'out', `${name}.sol`, `${name}.json`)))
  const proposalAddress = ethers.getAddress(args.proposal)
  checkEq(
    await provider.getCode(proposalAddress),
    artifact('AddEthPoolsProposal').deployedBytecode.object,
    'the contract at --proposal is the compiled AddEthPoolsProposal'
  )
  report.proposal = proposalAddress
  const implementationOfStaking = async () =>
    ethers.getAddress(ethers.dataSlice(await provider.getStorage(ADDRESS.staking, IMPLEMENTATION_SLOT), 12))
  const liveImplementation = await implementationOfStaking()
  console.log(`fork of mainnet block ${forkBlock}, proposal ${proposalAddress}`)

  // ---- 1. Governance: a TORN holder locks, proposes, votes and executes
  const voter = await fork.account('voter', '10')
  const quorum = await governance.QUORUM_VOTES()
  await fork.setTorn(voter, quorum)
  const asVoter = await fork.as(voter)
  await fork.mined(torn.connect(asVoter).approve(ADDRESS.governance, quorum), 'approve')
  await fork.mined(governance.connect(asVoter).lockWithApproval(quorum), 'lock')
  // propose → wait → vote → wait → execute, through the live Governance contract
  const passAndExecute = async (target, description) => {
    await fork.mined(governance.connect(asVoter).propose(target, description), 'propose')
    const proposalId = await governance.proposalCount()
    await fork.skipTime((await governance.VOTING_DELAY()) + 1n)
    await fork.mined(governance.connect(asVoter).castVote(proposalId, true), 'vote')
    await fork.skipTime((await governance.VOTING_PERIOD()) + (await governance.EXECUTION_DELAY()) + 1n)
    const execution = await fork.mined(governance.connect(asVoter).execute(proposalId), 'execute')
    checkEq(await governance.state(proposalId), STATE_EXECUTED, 'proposal state')
    return { proposalId, gasUsed: execution.gasUsed }
  }

  const instancesBefore = await instanceRegistry.getAllInstanceAddresses()
  const execution = await passAndExecute(proposalAddress, DESCRIPTION)

  // The pool is the instance the proposal added to the registry. It did not exist before.
  const instancesAfter = await instanceRegistry.getAllInstanceAddresses()
  checkEq(instancesAfter.length, instancesBefore.length + 1, 'registered instances')
  const pool = new ethers.Contract(instancesAfter[instancesBefore.length], ABI.pool, provider)
  check(!instancesBefore.includes(pool.target), 'the pool was registered before the proposal')
  check((await provider.getCode(pool.target)) !== '0x', 'the proposal did not deploy the pool')
  checkEq(
    await provider.getCode(pool.target),
    artifact('FeeEnforcedTornado_eth').deployedBytecode.object,
    'the pool is the compiled FeeEnforcedTornado_eth'
  )
  report.pool = pool.target
  const denomination = await pool.denomination()
  const amount = ethers.formatEther(denomination)
  report.amount = amount
  checkEq(await implementationOfStaking(), liveImplementation, 'the pool proposal leaves the staking contract alone')
  const registered = await instanceRegistry.instances(pool.target)
  checkEq(registered.state, 1n, 'pool enabled in the registry')
  checkEq(registered.protocolFeePercentage, 30n, 'registry fee')
  checkEq(await pool.protocolFeePercentage(), 30n, 'pool protocol fee')
  checkEq(await pool.directWithdrawPremiumPercentage(), 30n, 'pool premium')
  report.execution = {
    proposalId: execution.proposalId,
    gasUsed: execution.gasUsed,
    instancesBefore: instancesBefore.length,
    instancesAfter: instancesAfter.length
  }
  console.log(`proposal ${execution.proposalId} executed with ${execution.gasUsed} gas: pool ${pool.target}`)

  // ---- 2. A staker locks TORN before any fee is paid
  const staker = await fork.account('staker', '1')
  await fork.setTorn(staker, STAKER_LOCK)
  const asStaker = await fork.as(staker)
  await fork.mined(torn.connect(asStaker).approve(ADDRESS.governance, STAKER_LOCK), 'approve')
  await fork.mined(governance.connect(asStaker).lockWithApproval(STAKER_LOCK), 'staker lock')
  const totalLocked = await torn.balanceOf(vault)
  checkEq(await staking.checkReward(staker), 0n, 'staker TORN reward before any fee')
  // The staking contract cannot handle ETH yet: the function does not exist in the live implementation.
  check((await fork.revertReason(staking.checkEthReward.staticCall(staker))) !== null, 'ETH rewards exist before the upgrade')

  // ---- 3. Notes, deposits and withdrawals through every path
  const prover = await tornado.loadProver(args.keys)
  const relayer = ADDRESS.registeredRelayer
  checkEq(await relayerRegistry.workers(relayer), relayer, 'relayer is registered on the fork')
  await fork.setBalance(relayer, '10')
  const asRelayer = await fork.as(relayer)
  const customRelayer = await fork.account('unregistered-relayer', '10')
  checkEq(await relayerRegistry.workers(customRelayer), ZERO_ADDRESS, 'custom relayer is not registered')
  const depositor = await fork.account('depositor', '100')
  const asDepositor = await fork.as(depositor)
  // TORN burned for 0.3% of 1 ETH at the oracle price, read from the live 1 ETH pool
  const tornPerEthOfFee = await feeManager.calculatePoolFee(ADDRESS.legacy1EthPool)

  // One withdrawal through each path the pool distinguishes while the staking contract is the one live
  // today, then the later proposal that upgrades it, then one more withdrawal.
  const plan = ['registered', 'direct', 'routerNoRelayer', 'custom', STAKING_UPGRADE, 'direct']

  let totalTornBurned = 0n
  let totalEthFees = 0n
  let keptByPool = 0n
  let stakingUpgraded = false
  let payments = 0n
  for (const pathName of plan) {
    if (pathName === STAKING_UPGRADE) {
      // ---- 4. Before the upgrade the staker can claim TORN, as today. The ETH is still in the pool.
      const stakerShareTorn = (totalTornBurned * STAKER_LOCK) / totalLocked
      const pendingTorn = await staking.checkReward(staker)
      checkClose(pendingTorn, stakerShareTorn, 2n, 'staker TORN reward')
      const tornBeforeClaim = await torn.balanceOf(staker)
      await fork.mined(staking.connect(asStaker).getReward(), 'getReward')
      const tornClaimed = (await torn.balanceOf(staker)) - tornBeforeClaim
      checkEq(tornClaimed, pendingTorn, 'TORN claimed')
      checkEq(await pool.accruedProtocolFees(), keptByPool, 'ETH fees kept by the pool')
      checkEq(await provider.getBalance(ADDRESS.staking), 0n, 'ETH in the staking contract before the upgrade')
      const early = await fork.revertReason(pool.connect(asStaker).sweepProtocolFees.staticCall())
      check(early && early.includes('did not go thru'), `the fees could be forwarded before the upgrade: ${early}`)
      report.checks.push({
        what: 'Someone tries to forward the fees kept by the pool before the staking contract is upgraded',
        result: `Rejected: "${early}". The fees stay in the pool`
      })

      // ---- 5. The later proposal: the staking upgrade, deployed and passed like the first one
      const stakingArtifact = artifact('StakingUpgradeProposal')
      const stakingProposal = await new ethers.ContractFactory(stakingArtifact.abi, stakingArtifact.bytecode.object, asVoter).deploy()
      await stakingProposal.waitForDeployment()
      const upgrade = await passAndExecute(stakingProposal.target, STAKING_DESCRIPTION)
      const newImplementation = await implementationOfStaking()
      check(newImplementation !== liveImplementation, 'the staking proposal did not upgrade the staking contract')
      check((await provider.getCode(newImplementation)) !== '0x', 'the new staking implementation has no code')
      checkEq(await staking.checkEthReward(staker), 0n, 'staker ETH reward right after the upgrade')

      // ---- 6. Anyone forwards what the pool kept
      const anyone = await fork.account('anyone', '1')
      await fork.mined(pool.connect(await fork.as(anyone)).sweepProtocolFees(), 'sweep')
      checkEq(await pool.accruedProtocolFees(), 0n, 'nothing left in the pool after the sweep')
      checkEq(await provider.getBalance(ADDRESS.staking), keptByPool, 'ETH in the staking contract after the sweep')
      payments += 1n

      stakingUpgraded = true
      report.upgrade = {
        proposal: stakingProposal.target,
        proposalId: upgrade.proposalId,
        gasUsed: upgrade.gasUsed,
        newImplementation,
        swept: keptByPool,
        pendingTorn,
        tornClaimed
      }
      console.log(`staker claimed ${fmt(tornClaimed, 6)} TORN; staking proposal ${upgrade.proposalId} executed with ${upgrade.gasUsed} gas; ${fmt(keptByPool)} ETH swept to the staking contract`)
      continue
    }
    const label = `${report.withdrawals.length + 1}. ${Number(amount)} ETH, ${PATHS[pathName].toLowerCase()}`
    const i = report.withdrawals.length

    // The user makes a note and deposits through the Router, as the UI does.
    const noteText = (await tornado.createNote(Number(amount), network.chainId)).text
    const depositNote = await tornado.parseNote(noteText)
    const deposit = await fork.mined(
      router.connect(asDepositor).deposit(pool.target, tornado.toHex(depositNote.commitment), '0x', { value: denomination }),
      'deposit'
    )

    // Later, with only the note string, the user rebuilds the pool's tree from its events and proves
    // that the note is one of the deposits without revealing which.
    const note = await tornado.parseNote(noteText)
    const deposits = (await pool.queryFilter(pool.filters.Deposit(), forkBlock + 1)).sort(
      (a, b) => Number(a.args.leafIndex) - Number(b.args.leafIndex)
    )
    const tree = await tornado.buildTree(deposits.map((event) => event.args.commitment))
    checkEq(tornado.toHex(tree.root), await pool.getLastRoot(), 'rebuilt Merkle root')
    const leafIndex = deposits.findIndex((event) => BigInt(event.args.commitment) === note.commitment)
    check(leafIndex >= 0, 'deposit not found among the pool events')

    const recipient = await fork.account(`recipient-${i + 1}`, pathName === 'direct' || pathName === 'routerNoRelayer' ? '1' : undefined)
    const relayerAddress = pathName === 'registered' ? relayer : pathName === 'custom' ? customRelayer : ZERO_ADDRESS
    const relayerFee = relayerAddress === ZERO_ADDRESS ? 0n : (denomination * RELAYER_FEE_BPS) / BPS
    // The note owner states in the proof the most the pool may charge: nothing when a registered
    // relayer is used (the DAO is paid by the relayer's TORN burn), the pool's fee otherwise.
    const acceptedFee = pathName === 'registered' ? 0n : await pool.directWithdrawFee()
    const started = Date.now()
    const proof = await tornado.proveWithdrawal(prover, {
      note,
      tree,
      leafIndex,
      recipient,
      relayer: relayerAddress,
      fee: relayerFee,
      refund: acceptedFee
    })
    const proofSeconds = (Date.now() - started) / 1000
    const withdrawArgs = [
      proof,
      tornado.toHex(tree.root),
      tornado.toHex(note.nullifierHash),
      recipient,
      relayerAddress,
      relayerFee,
      acceptedFee
    ]

    // Who sends the transaction, and to which contract
    const sender = pathName === 'registered' ? relayer : pathName === 'custom' ? customRelayer : recipient
    const asSender = pathName === 'registered' ? asRelayer : await fork.as(sender)
    const viaRouter = pathName !== 'direct'
    const send = () =>
      viaRouter
        ? router.connect(asSender).withdraw(pool.target, ...withdrawArgs, { gasLimit: WITHDRAW_GAS_LIMIT })
        : pool.connect(asSender).withdraw(...withdrawArgs, { gasLimit: WITHDRAW_GAS_LIMIT })

    // Things that must not work, tried without sending anything (first time each case comes up)
    if (pathName === 'registered' && !report.checks.some((c) => c.id === 'impostor')) {
      const impostor = await fork.account('impostor', '1')
      const reason = await fork.revertReason(
        router.connect(await fork.as(impostor)).withdraw.staticCall(pool.target, ...withdrawArgs, { gasLimit: WITHDRAW_GAS_LIMIT })
      )
      check(reason && reason.includes('Only custom relayer'), `impostor was not rejected: ${reason}`)
      report.checks.push({
        id: 'impostor',
        what: 'Someone else submits a withdrawal that names the registered relayer, through the Router',
        result: `Rejected: "${reason}"`
      })

      // The same proof sent straight to the pool, skipping the Router: by the relayer (which would
      // keep its fee and burn no TORN) or by anyone who copied it from the mempool.
      for (const [who, signer] of [['The registered relayer', asRelayer], ['Someone else', await fork.as(impostor)]]) {
        const direct = await fork.revertReason(
          pool.connect(signer).withdraw.staticCall(...withdrawArgs, { gasLimit: WITHDRAW_GAS_LIMIT })
        )
        check(direct && direct.includes('above what the note owner accepted'), `direct submission was not rejected: ${direct}`)
        report.checks.push({
          id: `skip-router-${who}`,
          what: `${who} sends the proof made for the relayer straight to the pool, which would charge the user the pool fee`,
          result: `Rejected: "${direct}"`
        })
      }
    }
    if (pathName === 'direct' && !report.checks.some((c) => c.id === 'redirect')) {
      const thief = await fork.account('thief', '1')
      const redirected = [...withdrawArgs]
      redirected[3] = thief
      const reason = await fork.revertReason(
        pool.connect(await fork.as(thief)).withdraw.staticCall(...redirected, { gasLimit: WITHDRAW_GAS_LIMIT })
      )
      check(reason && reason.includes('Invalid withdraw proof'), `redirected withdrawal was not rejected: ${reason}`)
      report.checks.push({
        id: 'redirect',
        what: "Someone copies a user's proof and changes the recipient to their own address",
        result: `Rejected: "${reason}"`
      })
    }

    const before = {
      recipient: await provider.getBalance(recipient),
      sender: await provider.getBalance(sender),
      relayerEth: await provider.getBalance(relayerAddress),
      staking: await provider.getBalance(ADDRESS.staking),
      stake: await relayerRegistry.getRelayerBalance(relayer),
      pool: await provider.getBalance(pool.target)
    }
    const withdrawal = await fork.mined(send(), label)
    const gasPaidBy = (address) => (address === sender ? withdrawal.gasCost : 0n)

    const userReceives = (await provider.getBalance(recipient)) - before.recipient + gasPaidBy(recipient)
    const relayerReceives =
      relayerAddress === ZERO_ADDRESS ? 0n : (await provider.getBalance(relayerAddress)) - before.relayerEth + gasPaidBy(relayerAddress)
    const toStaking = (await provider.getBalance(ADDRESS.staking)) - before.staking
    const daoTorn = before.stake - (await relayerRegistry.getRelayerBalance(relayer))

    // What the design says should have happened. The pool charges the same ETH fee before and after
    // the staking upgrade. Before it, the staking contract cannot take ETH, so the pool keeps the fee
    // for the lockers; after it, the fee is paid to the staking contract in the same transaction.
    const expectedEthFee = pathName === 'registered' ? 0n : (denomination * 60n) / BPS
    const daoEth = expectedEthFee
    checkEq(await pool.isSpent(tornado.toHex(note.nullifierHash)), true, `${label}: note spent`)
    checkEq(userReceives, denomination - relayerFee - expectedEthFee, `${label}: user receives`)
    checkEq(relayerReceives, relayerFee, `${label}: relayer receives`)
    if (stakingUpgraded) {
      checkEq(toStaking, expectedEthFee, `${label}: ETH to the staking contract`)
      checkEq(await pool.accruedProtocolFees(), 0n, `${label}: nothing left waiting in the pool`)
      checkEq(before.pool - (await provider.getBalance(pool.target)), denomination, `${label}: pool pays out one note`)
      if (expectedEthFee > 0n) payments += 1n
    } else {
      keptByPool += expectedEthFee
      checkEq(toStaking, 0n, `${label}: no ETH to the staking contract before the upgrade`)
      checkEq(await pool.accruedProtocolFees(), keptByPool, `${label}: fee kept by the pool`)
      checkEq(before.pool - (await provider.getBalance(pool.target)), denomination - expectedEthFee, `${label}: pool pays out the note less the fee it keeps`)
    }
    if (pathName === 'registered') {
      checkEq(daoTorn, await feeManager.instanceFee(pool.target), `${label}: TORN burned is the FeeManager fee`)
      checkClose(daoTorn, (tornPerEthOfFee * denomination) / ethers.WeiPerEther, 10n, `${label}: TORN burned is 0.3% at the live pools' rate`)
    } else {
      checkEq(daoTorn, 0n, `${label}: no TORN burned`)
      checkEq(expectedEthFee, await pool.directWithdrawFee(), `${label}: fee matches the pool's getter`)
    }

    // A spent note cannot be used again
    if (!report.checks.some((c) => c.id === 'replay')) {
      const reason = await fork.revertReason(
        viaRouter
          ? router.connect(asSender).withdraw.staticCall(pool.target, ...withdrawArgs, { gasLimit: WITHDRAW_GAS_LIMIT })
          : pool.connect(asSender).withdraw.staticCall(...withdrawArgs, { gasLimit: WITHDRAW_GAS_LIMIT })
      )
      check(reason && reason.includes('already spent'), `replay was not rejected: ${reason}`)
      report.checks.push({ id: 'replay', what: 'The same note is withdrawn a second time', result: `Rejected: "${reason}"` })
    }

    totalTornBurned += daoTorn
    totalEthFees += daoEth
    report.withdrawals.push({
      amount,
      pathName,
      denomination,
      userReceives,
      relayerReceives,
      daoTorn,
      daoTornInEth: tornPerEthOfFee === 0n ? 0n : (daoTorn * ethers.parseEther('0.003')) / tornPerEthOfFee,
      daoEth,
      keptByPool: !stakingUpgraded && daoEth > 0n,
      afterUpgrade: stakingUpgraded,
      depositGas: deposit.gasUsed,
      withdrawGas: withdrawal.gasUsed,
      proofSeconds,
      gasPaidBy: pathName === 'registered' ? 'relayer' : pathName === 'custom' ? 'relayer' : 'user',
      gasCost: withdrawal.gasCost
    })
    const where = daoEth === 0n ? '' : stakingUpgraded ? ' (paid to the staking contract)' : ' (kept by the pool)'
    console.log(`${label}: user ${fmt(userReceives)} ETH, relayer ${fmt(relayerReceives)} ETH, DAO ${fmt(daoTorn, 6)} TORN + ${fmt(daoEth)} ETH${where}`)
  }

  // ---- 7. After the upgrade the staker collects the ETH: what the pool had kept and what came since
  const stakerShareEth = (totalEthFees * STAKER_LOCK) / totalLocked
  const pendingEth = await staking.checkEthReward(staker)
  // Each payment rounds down twice (the index, then the share): allow two wei per payment.
  checkClose(pendingEth, stakerShareEth, 2n * payments, 'staker ETH reward')

  const ethBeforeClaim = await provider.getBalance(staker)
  const ethClaim = await fork.mined(staking.connect(asStaker).getEthReward(), 'getEthReward')
  const ethClaimed = (await provider.getBalance(staker)) - ethBeforeClaim + ethClaim.gasCost
  checkEq(ethClaimed, pendingEth, 'ETH claimed')
  checkEq(await staking.checkReward(staker), 0n, 'TORN reward after claiming')
  checkEq(await staking.checkEthReward(staker), 0n, 'ETH reward after claiming')

  const tornBeforeUnlock = await torn.balanceOf(staker)
  await fork.mined(governance.connect(asStaker).unlock(STAKER_LOCK), 'unlock')
  const tornUnlocked = (await torn.balanceOf(staker)) - tornBeforeUnlock
  checkEq(tornUnlocked, STAKER_LOCK, 'TORN returned on unlock')
  checkEq(await governance.lockedBalance(staker), 0n, 'locked balance after unlock')

  // The voter of step 1 is a locker too and was credited the same way, in proportion to its lock.
  const voterPendingEth = await staking.checkEthReward(voter)
  checkClose(voterPendingEth, (totalEthFees * quorum) / totalLocked, 2n * payments, 'voter ETH reward')

  report.staker = {
    locked: STAKER_LOCK,
    totalLocked,
    totalTornBurned,
    totalEthFees,
    pendingTorn: report.upgrade.pendingTorn,
    pendingEth,
    tornClaimed: report.upgrade.tornClaimed,
    ethClaimed,
    ethClaimGas: ethClaim.gasUsed,
    tornUnlocked,
    stakingEthLeft: await provider.getBalance(ADDRESS.staking),
    voterLocked: quorum,
    voterPendingEth
  }
  console.log(`staker claimed ${fmt(ethClaimed, 10)} ETH, then unlocked ${fmt(tornUnlocked)} TORN`)

  prover.groth16.terminate()
  fs.writeFileSync(args.out, render(report))
  console.log(`\nAll checks passed. Report written to ${path.relative(process.cwd(), args.out)}`)
}

// --------------------------------------------------------------------------- the report

function gitState() {
  try {
    const commit = execFileSync('git', ['rev-parse', '--short', 'HEAD'], { cwd: REPO }).toString().trim()
    const dirty = execFileSync('git', ['status', '--porcelain'], { cwd: REPO }).toString().trim() !== ''
    return dirty ? `${commit} plus uncommitted changes` : commit
  } catch (error) {
    return 'unknown'
  }
}

function render(report) {
  const lines = []
  const { staker } = report
  const row = (...cells) => lines.push(`| ${cells.join(' | ')} |`)

  lines.push('# End-to-end test on a local mainnet fork')
  lines.push('')
  lines.push('Generated by `e2e/run.sh`. Do not edit by hand: run the script again to refresh it.')
  lines.push('')
  lines.push(`- **Date:** ${new Date().toISOString().slice(0, 16).replace('T', ' ')} UTC`)
  lines.push(`- **Chain:** local anvil fork of Ethereum mainnet (chain id ${report.chainId}), forked at block ${report.forkBlock}`)
  lines.push(`- **Code:** commit ${gitState()}`)
  lines.push('- **Result:** every step succeeded and every amount matched the design.')
  lines.push('')
  lines.push('## What was done')
  lines.push('')
  lines.push('1. `script/Deploy.s.sol` deployed the proposal on the fork: one contract. The pool did not exist yet.')
  lines.push(`2. A TORN holder with quorum locked, proposed, voted and executed the proposal through the live Governance contract. Execution used ${report.execution.gasUsed.toLocaleString('en-US')} gas. It deployed the ${Number(report.amount)} ETH pool and registered it (${report.execution.instancesBefore} to ${report.execution.instancesAfter} instances). It did not touch the staking contract.`)
  lines.push('3. A staker locked 10,000 TORN in Governance.')
  lines.push('4. For each row of the table below, a user generated a new note, deposited through the Router, rebuilt the pool\'s Merkle tree from its events and generated a real zero-knowledge proof with the circuit and proving key of the classic UI. The withdrawal was checked by the verifier contract that is live on mainnet; nothing was mocked.')
  lines.push('5. After the first four withdrawals, with the staking contract still the one live today, the staker claimed the TORN. The ETH fees were in the pool.')
  lines.push(`6. The later proposal, the staking upgrade (\`StakingUpgradeProposal\`), was deployed and passed through Governance the same way. Its execution used ${report.upgrade.gasUsed.toLocaleString('en-US')} gas: it deployed the new staking implementation and upgraded the staking contract to it.`)
  lines.push(`7. Someone called \`sweepProtocolFees()\` on the pool, which sent the ${fmt(report.upgrade.swept)} ETH it had kept to the staking contract.`)
  lines.push('8. One more withdrawal was made, now with the staking contract upgraded.')
  lines.push('9. The staker claimed the ETH, then unlocked.')
  lines.push('')
  lines.push('## Withdrawals: who received what')
  lines.push('')
  lines.push('"DAO" is the TORN lockers: TORN burned from a relayer\'s stake and ETH charged by the pool are both shared among lockers by the staking contract.')
  lines.push('')
  row('#', 'Note', 'How it was withdrawn', 'Staking contract', 'User receives', 'Relayer receives', 'DAO receives in TORN', 'DAO receives in ETH')
  row('---', '---', '---', '---', '---', '---', '---', '---')
  report.withdrawals.forEach((w, i) => {
    row(
      i + 1,
      `${Number(w.amount)} ETH`,
      PATHS[w.pathName],
      w.afterUpgrade ? 'upgraded' : 'as today',
      `${fmt(w.userReceives)} ETH (${percent(w.userReceives, w.denomination)})`,
      w.relayerReceives === 0n ? '—' : `${fmt(w.relayerReceives)} ETH (${percent(w.relayerReceives, w.denomination)})`,
      w.daoTorn === 0n ? '—' : `${fmt(w.daoTorn, 6)} TORN (worth ${fmt(w.daoTornInEth)} ETH, ${percent(w.daoTornInEth, w.denomination)})`,
      w.daoEth === 0n
        ? '—'
        : `${fmt(w.daoEth)} ETH (${percent(w.daoEth, w.denomination)}), ${w.keptByPool ? 'kept by the pool until the staking upgrade' : 'paid to the staking contract in the same transaction'}`
    )
  })
  lines.push('')
  lines.push('How to read it:')
  lines.push('')
  lines.push('- **Registered relayer:** the user pays the relayer\'s fee (0.4% in this test) and nothing else. The DAO is paid once, in TORN taken from the relayer\'s stake and worth 0.3% of the note at the FeeManager\'s oracle price. The pool takes no ETH, so the relayer nets 0.1% before gas. This works with the staking contract as it is today.')
  lines.push('- **No registered relayer:** the pool keeps 0.6% of the note (0.3% protocol fee plus 0.3% premium) for the lockers. An unregistered relayer still receives the fee the user agreed to, but burns no TORN.')
  lines.push('- **Where the ETH goes:** the staking contract that is live today cannot take ETH. Until the staking upgrade the pool holds the fees, and nobody can take them out: the only way out is `sweepProtocolFees()`, which sends them to the staking contract and only works once it is upgraded. After the upgrade the pool pays each fee to the staking contract in the same transaction.')
  lines.push('- The user fixes in the proof the most the pool may charge: nothing with a registered relayer, the pool fee otherwise. The table "Things that must not work" shows what happens when someone tries another path.')
  lines.push('- Percentages are of the note. Gas is not included: the relayer pays it when there is one, the user otherwise.')
  lines.push('')
  lines.push('## What the staker received')
  lines.push('')
  row('', 'TORN', 'ETH')
  row('---', '---', '---')
  row('For the lockers, from the withdrawals above', `${fmt(staker.totalTornBurned, 6)} TORN`, `${fmt(staker.totalEthFees)} ETH, of which ${fmt(report.upgrade.swept)} ETH waited in the pool for the staking upgrade`)
  row(
    `Staker's share: ${fmt(staker.locked)} of ${fmt(staker.totalLocked, 2)} TORN locked (${percent(staker.locked, staker.totalLocked)})`,
    `${fmt(staker.pendingTorn, 8)} TORN shown by \`checkReward\``,
    `${fmt(staker.pendingEth, 12)} ETH shown by \`checkEthReward\``
  )
  row('Received on claiming', `${fmt(staker.tornClaimed, 8)} TORN from \`getReward()\`, before the staking upgrade`, `${fmt(staker.ethClaimed, 12)} ETH from \`getEthReward()\`, after it`)
  row('Left to claim afterwards', '0', '0')
  row('Returned by `unlock`', `${fmt(staker.tornUnlocked)} TORN`, '—')
  lines.push('')
  lines.push(`The other lockers were credited in the same proportion. For example the voter of step 2, with ${fmt(staker.voterLocked)} TORN locked, could claim ${fmt(staker.voterPendingEth, 10)} ETH. After the staker's claim the staking contract still held ${fmt(staker.stakingEthLeft, 10)} ETH for them.`)
  lines.push('')
  lines.push('## Things that must not work')
  lines.push('')
  row('Attempt', 'Result')
  row('---', '---')
  for (const item of report.checks) row(item.what, item.result)
  lines.push('')
  lines.push('## Gas')
  lines.push('')
  row('#', 'Note', 'Path', 'Deposit gas', 'Withdrawal gas', 'Gas paid by', 'Proof time')
  row('---', '---', '---', '---', '---', '---', '---')
  report.withdrawals.forEach((w, i) => {
    row(
      i + 1,
      `${Number(w.amount)} ETH`,
      PATHS[w.pathName],
      w.depositGas.toLocaleString('en-US'),
      w.withdrawGas.toLocaleString('en-US'),
      `${w.gasPaidBy} (${fmt(w.gasCost, 9)} ETH)`,
      `${w.proofSeconds.toFixed(1)} s`
    )
  })
  lines.push('')
  lines.push('## Contracts on the fork')
  lines.push('')
  row('Contract', 'Address')
  row('---', '---')
  row('AddEthPoolsProposal (the proposal, deployed before the vote)', `\`${report.proposal}\``)
  row(`${Number(report.amount)} ETH pool (deployed by the proposal)`, `\`${report.pool}\``)
  row('StakingUpgradeProposal (the later proposal)', `\`${report.upgrade.proposal}\``)
  row('TornadoStakingRewards, new implementation (deployed by the later proposal)', `\`${report.upgrade.newImplementation}\``)
  lines.push('')
  lines.push('The pool and the staking implementation are created by Governance when each proposal is executed, so their addresses depend on how many contracts Governance has created before.')
  lines.push('')
  lines.push('## Limits of this test')
  lines.push('')
  lines.push('- The relayer is a registered relayer\'s address on the fork, not the relayer software. Live relayers must add the new pool addresses to their configuration before they can serve them.')
  lines.push('- The governance vote is cast by one account given quorum on the fork. Voting delay and timelock are skipped by moving the fork\'s clock.')
  lines.push('- The TORN price comes from the live oracle at the forked block, so TORN amounts differ between runs. ETH amounts do not.')
  lines.push('')
  lines.push('## How to reproduce')
  lines.push('')
  lines.push('```bash')
  lines.push('# needs Foundry (forge, cast, anvil) and Node.js; a mainnet RPC URL in ETH_RPC_URL or RPC_URL,')
  lines.push('# or in a .env file in this repository or its parent folder')
  lines.push('./e2e/run.sh')
  lines.push('```')
  lines.push('')
  lines.push('The script starts the fork, deploys, runs every step above and rewrites this file. It stops at the first amount that does not match. Set `FORK_BLOCK` to fork a specific block (needs an archive RPC) and `TORNADO_KEYS_DIR` if the classic UI\'s `static` folder is not at `../classic-ui/static`.')
  lines.push('')
  return lines.join('\n')
}

main().catch((error) => {
  console.error(error.message || error)
  process.exit(1)
})
