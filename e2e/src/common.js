'use strict'
// What the end-to-end walkthrough (phase1.js) and its report share: the live contracts, the fork,
// checks and formatting.

const { execFileSync } = require('child_process')
const fs = require('fs')
const path = require('path')
const { ethers } = require('ethers')

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
    'function MAX_PROTOCOL_FEE_PERCENTAGE() view returns (uint256)',
    'function MAX_DIRECT_WITHDRAW_PREMIUM_PERCENTAGE() view returns (uint256)',
    'function setProtocolFeePercentage(uint256)',
    'function setDirectWithdrawPremiumPercentage(uint256)',
    'function accruedProtocolFees() view returns (uint256)',
    'function getLastRoot() view returns (bytes32)',
    'function isSpent(bytes32) view returns (bool)',
    'function withdraw(bytes,bytes32,bytes32,address,address,uint256,uint256) payable',
    'function sweepProtocolFees()',
    'function nextIndex() view returns (uint32)',
    'event Deposit(bytes32 indexed commitment, uint32 leafIndex, uint256 timestamp)',
    'event ProtocolFeesSwept(uint256 amount)',
    'event ProtocolFeeCharged(address indexed relayer, uint256 amount, bool paidToStaking)'
  ]
}

const IMPLEMENTATION_SLOT = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc'
const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000'
const STATE_EXECUTED = 5n
// What a relayer charges the user in this test: 0.4% of the note, the usual rate on mainnet.
// (Live relayers add their gas cost on top; here the relayer simply pays the gas.)
const RELAYER_FEE_BPS = 40n
const BPS = 10000n
const STAKER_LOCK = ethers.parseEther('10000')
const WITHDRAW_GAS_LIMIT = 1_500_000n

// --------------------------------------------------------------------------- checks and formatting

let passed = 0

function check(condition, message) {
  if (!condition) throw new Error(`CHECK FAILED: ${message}`)
  passed++
}

/** How many checks have passed so far in this process. */
function checksPassed() {
  return passed
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

/** Compiled artifact of a contract in this repository (needs `forge build`). */
function artifact(name) {
  const file = path.join(REPO, 'out', `${name}.sol`, `${name}.json`)
  check(fs.existsSync(file), `${file} not found: run \`forge build\` first`)
  return JSON.parse(fs.readFileSync(file))
}

/**
 * Pass `target` through the live Governance contract on the fork as `asVoter`, a signer with quorum
 * locked: propose, skip the voting delay, vote, skip the voting period and the timelock, execute.
 * Returns the proposal id and the execution receipt.
 */
async function passProposal(fork, governance, asVoter, target, description) {
  await fork.mined(governance.connect(asVoter).propose(target, description), 'propose')
  const proposalId = await governance.proposalCount()
  await fork.skipTime((await governance.VOTING_DELAY()) + 1n)
  await fork.mined(governance.connect(asVoter).castVote(proposalId, true), 'vote')
  await fork.skipTime((await governance.VOTING_PERIOD()) + (await governance.EXECUTION_DELAY()) + 1n)
  const execution = await fork.mined(governance.connect(asVoter).execute(proposalId), 'execute')
  checkEq(await governance.state(proposalId), STATE_EXECUTED, `proposal ${proposalId} state after execution`)
  return { proposalId, execution }
}

function gitState() {
  try {
    const commit = execFileSync('git', ['rev-parse', '--short', 'HEAD'], { cwd: REPO }).toString().trim()
    const dirty = execFileSync('git', ['status', '--porcelain'], { cwd: REPO }).toString().trim() !== ''
    return dirty ? `${commit} plus uncommitted changes` : commit
  } catch (error) {
    return 'unknown'
  }
}

module.exports = {
  REPO,
  ADDRESS,
  ABI,
  IMPLEMENTATION_SLOT,
  ZERO_ADDRESS,
  STATE_EXECUTED,
  RELAYER_FEE_BPS,
  BPS,
  STAKER_LOCK,
  WITHDRAW_GAS_LIMIT,
  check,
  checkEq,
  checkClose,
  checksPassed,
  fmt,
  percent,
  Fork,
  artifact,
  passProposal,
  gitState
}
