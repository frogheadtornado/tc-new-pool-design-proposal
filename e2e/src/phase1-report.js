'use strict'
// The report of the phase I walkthrough (e2e/PHASE1-RESULTS.md): for each test, what it verifies,
// the expected result, whether it passed, the command and its output. Pure: it only reads the state.

const { ZERO_ADDRESS, BPS, RELAYER_FEE_BPS, fmt, percent, gitState } = require('./common')

const PATHS = {
  registered: 'Through a registered relayer (Router)',
  unregistered: 'Through an unregistered relayer (Router)',
  self: 'From the user\'s own wallet (no relayer)',
  router: 'From the user\'s own wallet through the Router (no relayer)'
}

// Used for the expected amounts when a step fails before the fees are read from the chain.
const DEFAULT_FEES = { denomination: 10n ** 16n, protocolFee: 30n, premium: 30n, poolFee: 60000000000000n }

/**
 * What a step verifies and what the design says must happen, with the amounts spelled out.
 * `opts.via` is the withdrawal path; `opts.upgraded` tells which sweep it is.
 */
function spec(step, opts = {}, fees) {
  const f = fees && fees.denomination ? fees : DEFAULT_FEES
  const d = f.denomination
  const poolFee = f.poolFee
  const relayerFee = (d * RELAYER_FEE_BPS) / BPS
  const pct = (x) => percent(x, d)
  const feeText = `${fmt(poolFee)} ETH (${pct(poolFee)}: ${pct((d * f.protocolFee) / BPS)} protocol fee + ${pct((d * f.premium) / BPS)} premium)`
  switch (step) {
    case 'setup':
      return {
        title: 'Setup',
        verifies: `The ${fmt(d)} ETH pool is registered and enabled in the InstanceRegistry (if the fork is from before the proposal's execution, the proposal deployed on mainnet is first passed through the live Governance contract on the fork), the pool, the registry and the FeeManager agree on the fee, the registered relayer has stake, and the staker's TORN is locked in Governance.`,
        expected: `A ${fmt(d)} ETH pool with the same protocol fee in the pool and in the registry, a direct-withdrawal fee of ${feeText}, a positive TORN fee in the FeeManager, a relayer registered with stake, and 10,000 TORN locked by the staker.`
      }
    case 'deposit':
      return {
        title: 'Deposit',
        verifies: `A user can deposit ${fmt(d)} ETH into the pool through the Router, as the UI does.`,
        expected: `The transaction succeeds, the pool emits Deposit with the note's commitment and the next leaf index, and the pool's balance rises by ${fmt(d)} ETH.`
      }
    case 'withdraw':
      switch (opts.via) {
        case 'registered':
          return {
            title: `Withdrawal ${PATHS.registered.toLowerCase()}`,
            verifies: 'A withdrawal through a registered relayer pays the DAO in TORN burned from the relayer\'s stake and nothing in ETH; the proof made for the relayer cannot be used by anyone else, nor sent straight to the pool to skip the burn; a spent note cannot be withdrawn twice.',
            expected: `The user receives ${fmt(d - relayerFee)} ETH (${pct(d - relayerFee)}: the note minus the ${pct(relayerFee)} relayer fee), the relayer receives ${fmt(relayerFee)} ETH and pays the gas, ${pct((d * f.protocolFee) / BPS)} of the note is burned in TORN from the relayer's stake (the FeeManager's fee for the pool), the pool keeps 0 ETH and the staking contract receives 0 ETH. The two bypass attempts and the replay are refused.`
          }
        case 'unregistered':
          return {
            title: `Withdrawal ${PATHS.unregistered.toLowerCase()}`,
            verifies: 'A withdrawal through an unregistered relayer pays the DAO in ETH kept by the pool, on top of the relayer\'s fee; no TORN is burned; the registered relayer cannot use that proof; a spent note cannot be withdrawn twice.',
            expected: `The user receives ${fmt(d - relayerFee - poolFee)} ETH (${pct(d - relayerFee - poolFee)}), the relayer receives ${fmt(relayerFee)} ETH and burns no TORN, the pool keeps ${feeText} and emits ProtocolFeeCharged with paidToStaking = false, and the staking contract receives 0 ETH. The bypass attempt and the replay are refused.`
          }
        case 'self':
          return {
            title: `Withdrawal ${PATHS.self.toLowerCase()}`,
            verifies: 'A withdrawal from the user\'s own wallet, with no relayer, pays the DAO in ETH kept by the pool; the proof cannot be redirected to another recipient; a spent note cannot be withdrawn twice.',
            expected: `The user receives ${fmt(d - poolFee)} ETH (${pct(d - poolFee)}) and pays its own gas, nobody else receives ETH, no TORN is burned, the pool keeps ${feeText} and emits ProtocolFeeCharged with paidToStaking = false, and the staking contract receives 0 ETH. The redirection and the replay are refused.`
          }
        case 'router':
          return {
            title: `Withdrawal ${PATHS.router.toLowerCase()}`,
            verifies: 'A withdrawal sent by the user through the Router without naming a relayer is treated like one from its own wallet: the Router burns nothing and the pool keeps the fee in ETH; the proof cannot be redirected; a spent note cannot be withdrawn twice.',
            expected: `The user receives ${fmt(d - poolFee)} ETH (${pct(d - poolFee)}) and pays its own gas, nobody else receives ETH, no TORN is burned, the pool keeps ${feeText} and emits ProtocolFeeCharged with paidToStaking = false, and the staking contract receives 0 ETH. The redirection and the replay are refused.`
          }
        default:
          throw new Error(`unknown withdrawal path: ${opts.via}`)
      }
    case 'sweep':
      return opts.upgraded
        ? {
            title: 'Sweep after the staking upgrade',
            verifies: 'After the staking upgrade, anyone can forward the fees the pool holds to the staking contract.',
            expected: 'sweepProtocolFees() succeeds, emits ProtocolFeesSwept for the whole accrued amount, the pool\'s accrued fees drop to 0 and the staking contract\'s balance rises by the same amount.'
          }
        : {
            title: 'Sweep before the staking upgrade',
            verifies: 'Before the staking upgrade, nobody can move the fees out of the pool: sweepProtocolFees() is refused and the fees stay where they are.',
            expected: 'The call is refused with "payment to STAKING_REWARDS did not go thru", because the staking implementation live today has no addEthRewards() function, and the fees are still in the pool afterwards. The refusal is the expected result: the test passes when the sweep is refused.'
          }
    case 'fees': {
      const protocol = BigInt(opts.protocol)
      const premium = BigInt(opts.premium)
      const newPoolFee = (d * (protocol + premium)) / BPS
      return {
        title: `Fee change by proposal: protocol fee ${pct((d * protocol) / BPS)}, premium ${pct((d * premium) / BPS)}`,
        verifies: 'Governance can change the pool\'s protocol fee and premium by proposal, within the caps, together with the InstanceRegistry\'s fee for the pool and the FeeManager\'s TORN fee, so that both withdrawal paths follow the new rates from then on.',
        expected: `After the proposal executes, the pool reports protocolFeePercentage = ${protocol} and directWithdrawPremiumPercentage = ${premium}, a direct-withdrawal fee of ${fmt(newPoolFee)} ETH (${pct(newPoolFee)}), the InstanceRegistry has ${protocol} for the pool, and the FeeManager's TORN fee is ${protocol === 0n ? '0' : `${pct((d * protocol) / BPS)} of the note at its oracle price`}.`
      }
    }
    case 'caps':
      return {
        title: 'Fee values out of bounds',
        verifies: 'The hard caps written in the pool hold: not even Governance can set the protocol fee above 1% (100) or the premium above 4% (400), the cap values themselves are accepted, nobody but Governance can change the fees, and a proposal carrying a value above a cap cannot be executed.',
        expected: 'Every attempt is refused and the fees are unchanged afterwards: "Fee above cap" for 101, "Premium above cap" for 401, "Only governance" for a caller that is not Governance, and the out-of-bounds proposal reverts on execution. The refusals are the expected results: the test passes when all of them are refused.'
      }
    case 'phase2':
      return {
        title: 'Phase II, simulated: the staking upgrade',
        verifies: 'The staking upgrade can be passed through the live Governance contract and replaces the staking implementation, without crediting anyone before the fees are swept.',
        expected: 'StakingUpgradeProposal executes, the staking proxy points to a new implementation that has code, and the staker is owed 0 ETH right after.'
      }
    case 'claim':
      return {
        title: 'A TORN locker claims its ETH',
        verifies: 'A TORN locker receives its pro-rata share of the swept fees.',
        expected: 'checkEthReward() shows the staker\'s share (its locked TORN over all the TORN locked in Governance, times the swept amount), getEthReward() pays exactly that, and nothing is left to claim.'
      }
    default:
      throw new Error(`no spec for step ${step}`)
  }
}

function render(state) {
  const lines = []
  const row = (...cells) => lines.push(`| ${cells.join(' | ')} |`)
  const fees = state.fees && state.fees.denomination ? state.fees : DEFAULT_FEES
  const tests = state.transcripts
  const passed = tests.filter((t) => t.pass).length
  const kept = state.withdrawals.reduce((sum, w) => sum + w.kept, 0n)
  const burned = state.withdrawals.reduce((sum, w) => sum + w.tornBurned, 0n)

  lines.push('# Phase I walkthrough on a local mainnet fork')
  lines.push('')
  lines.push('Generated by `e2e/phase1.sh`. Do not edit by hand: run the script again to refresh it. What each step does and how to run them one at a time is in `e2e/PHASE1.md`.')
  lines.push('')
  lines.push(`- **Date:** ${new Date().toISOString().slice(0, 16).replace('T', ' ')} UTC`)
  lines.push(`- **Chain:** local anvil fork of Ethereum mainnet (chain id ${state.chainId}), forked at block ${state.forkBlock}`)
  lines.push(`- **Code:** commit ${gitState()}`)
  lines.push(`- **Pool:** \`${state.pool}\`, ${fmt(fees.denomination)} ETH, ${state.simulatedPhase1 ? 'deployed on the fork by simulating the proposal\'s execution (the fork is from before it)' : 'as deployed on mainnet by the proposal'}`)
  lines.push(`- **Result:** ${passed === tests.length ? `all ${tests.length} tests passed` : `${passed} of ${tests.length} tests passed`}`)
  lines.push('')
  lines.push('## Tests')
  lines.push('')
  row('#', 'Test', 'Result')
  row('---', '---', '---')
  tests.forEach((t, i) => row(i + 1, `[${t.title}](#${i + 1}-${t.title.toLowerCase().replace(/[^a-z0-9 ]/g, '').replace(/ /g, '-')})`, t.pass ? `PASS (${t.checks} checks)` : `**FAIL:** ${t.error}`))
  lines.push('')
  if (state.withdrawals.length) {
    lines.push('## Where the funds went')
    lines.push('')
    lines.push('"DAO" is the TORN lockers: TORN burned from a relayer\'s stake is shared among them by the staking contract as today; ETH kept by the pool reaches them after phase II. Percentages are of the note. "Pool fee setting" is the protocol fee + premium in force at the time: the protocol fee is what a registered relayer burns in TORN, the sum is what every other path pays in ETH.')
    lines.push('')
    row('#', 'How it was withdrawn', 'Pool fee setting', 'User receives', 'Relayer receives', 'DAO receives in TORN', 'DAO receives in ETH', 'Gas paid by')
    row('---', '---', '---', '---', '---', '---', '---', '---')
    for (const w of state.withdrawals) {
      row(
        w.n,
        PATHS[w.pathName],
        `${percent((fees.denomination * w.feeSetting.protocolFee) / BPS, fees.denomination)} + ${percent((fees.denomination * w.feeSetting.premium) / BPS, fees.denomination)}`,
        `${fmt(w.userReceives)} ETH (${percent(w.userReceives, fees.denomination)})`,
        w.relayerAddress === ZERO_ADDRESS ? '—' : `${fmt(w.relayerReceives)} ETH (${percent(w.relayerReceives, fees.denomination)})`,
        w.tornBurned === 0n ? '—' : `${fmt(w.tornBurned, 6)} TORN (worth ${fmt(w.tornInEth)} ETH, ${percent(w.tornInEth, fees.denomination)}), burned from the relayer's stake`,
        w.kept === 0n ? '—' : `${fmt(w.kept)} ETH (${percent(w.kept, fees.denomination)}), kept by the pool`,
        `${w.gasPaidBy} (${fmt(w.gasCost, 9)} ETH)`
      )
    }
    lines.push('')
    lines.push(`After the withdrawals the pool held ${fmt(kept)} ETH of fees (\`accruedProtocolFees\`) and the relayer's stake was ${fmt(burned, 6)} TORN lower.`)
    const after = state.sweeps.find((s) => s.afterUpgrade)
    if (after && state.claim) {
      lines.push(`After the simulated staking upgrade, the sweep moved the ${fmt(after.amount)} ETH to the staking contract and the staker with ${fmt(state.parties.stakerLock)} of ${fmt(after.totalLocked, 2)} TORN locked claimed ${fmt(state.claim.claimed, 12)} ETH, its ${percent(state.parties.stakerLock, after.totalLocked)}.`)
    }
    lines.push('')
  }
  lines.push('## Each test')
  lines.push('')
  lines.push('Lines starting with ✓ are checks: each one is a value read from the chain that matched the design, or an attempt that was refused as it must be.')
  lines.push('')
  tests.forEach((t, i) => {
    lines.push(`### ${i + 1}. ${t.title}`)
    lines.push('')
    lines.push(`**Verifies:** ${t.verifies}`)
    lines.push('')
    lines.push(`**Expected:** ${t.expected}`)
    lines.push('')
    lines.push(`**Result:** ${t.pass ? `PASS (${t.checks} checks)` : `FAIL: ${t.error}`}`)
    lines.push('')
    lines.push(`**Command:** \`${t.command}\``)
    lines.push('')
    lines.push('**Output:**')
    lines.push('')
    lines.push('```text')
    lines.push(`$ ${t.command}`)
    lines.push(...t.lines)
    lines.push('```')
    lines.push('')
  })
  lines.push('## Limits of this walkthrough')
  lines.push('')
  lines.push('- The relayer is a registered relayer\'s address on the fork, not the relayer software. Live relayers must add the pool to their configuration before they can serve it.')
  lines.push('- Phase II is simulated: the staking upgrade is voted by one account given quorum on the fork, with the voting delay and the timelock skipped by moving the fork\'s clock. On mainnet it is a separate proposal.')
  lines.push('- The TORN price comes from the live oracle at the forked block, so TORN amounts differ between runs. ETH amounts do not.')
  lines.push('')
  lines.push('## How to reproduce')
  lines.push('')
  lines.push('```bash')
  lines.push('# needs Foundry (forge, cast, anvil) and Node.js; a mainnet RPC URL in ETH_RPC_URL or RPC_URL,')
  lines.push('# or in a .env file in this repository or its parent folder')
  lines.push('./e2e/phase1.sh')
  lines.push('```')
  lines.push('')
  return lines.join('\n')
}

module.exports = { spec, render, PATHS }
