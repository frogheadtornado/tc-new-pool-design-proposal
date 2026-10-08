# Phase I walkthrough: where every wei goes

A step-by-step check of the 0.01 ETH pool as it is after the first proposal, on a local fork of mainnet. Anyone with Foundry and a mainnet RPC URL can run it; it spends no real ETH. The output of the last run, step by step, is in [`PHASE1-RESULTS.md`](PHASE1-RESULTS.md).

It answers five questions with real transactions, real notes and real zero-knowledge proofs:

1. What does a user get back on each withdrawal path, and what do the relayer and the DAO get?
2. Where does the DAO's share sit after each path: burned TORN, or ETH kept by the pool?
3. Can anyone take that ETH out of the pool before the staking contract is upgraded? (No. The attempt is part of the run and is expected to be refused.)
4. Can Governance change the fees, do withdrawals follow the new rates, and do the caps hold against values out of bounds?
5. Once the staking contract is upgraded (phase II, simulated on the fork), does the ETH reach the TORN lockers?

Every amount is read back from balances and events and compared with what the design says. The first mismatch stops the run.

## Requirements

- Foundry (`forge`, `cast`, `anvil`) and Node.js 18 or later.
- A mainnet RPC URL in `ETH_RPC_URL` or `RPC_URL`, or in a `.env` file in this repository or its parent folder. Any provider works; the fork reads the live contracts through it.
- The classic UI's circuit and proving key, `tornado.json.gz` and `tornadoProvingKey.bin.gz`, in `../classic-ui/static` or in the folder named by `TORNADO_KEYS_DIR`. They are the files the UI ships; the proofs made with them are checked by the verifier contract live on mainnet.

## One command

```bash
./e2e/phase1.sh
```

Starts a fork, runs every step below in order and writes `e2e/PHASE1-RESULTS.md`. Takes a few minutes; each proof takes about two seconds.

## One step at a time

Start a fork and leave it running in one terminal:

```bash
./e2e/phase1.sh fork
```

Then, from the repository root in another terminal, one command per step. Each prints what it did and keeps its results in `e2e/.work/phase1-state.json` for the next one.

### 1. `setup`

```bash
node e2e/src/phase1.js setup
```

Finds the 0.01 ETH pool in the InstanceRegistry. If the fork is from before the proposal's execution, it first passes the proposal deployed on mainnet (`0x0b3AD72fcEA25a3C7077AE6af6E4B91C4b55778B`) through the live Governance contract on the fork, with a voter given quorum, and prints that phase I was **simulated**. It then sets up the parties:

- a depositor with ETH on the fork;
- the registered relayer `0x4750…29C5`, a real relayer with TORN staked on mainnet, impersonated: the fork lets the script send transactions from its address, which is all the contracts see of a relayer;
- an address that never registered as a relayer;
- a staker who locks 10,000 TORN in Governance, to show later how fees reach lockers.

It prints the fee settings read from the contracts: 0.3% protocol fee, 0.3% premium, the FeeManager's TORN fee per withdrawal, and that the InstanceRegistry carries the same protocol fee as the pool.

### 2. `deposit`

```bash
node e2e/src/phase1.js deposit
```

Makes a new note and deposits 0.01 ETH through the Router, as the UI does. Prints the note, the transaction, the leaf index in the pool's Merkle tree and the pool's balance before and after. Run it before each withdrawal; each withdrawal spends the oldest unspent note.

### 3. `withdraw --via registered`

```bash
node e2e/src/phase1.js withdraw --via registered
```

The user rebuilds the pool's Merkle tree from its `Deposit` events, checks its root against the pool, and makes a proof for a fresh recipient with the registered relayer named in it, a relayer fee of 0.4% and **0 as the highest pool fee accepted**. The relayer sends it through the Router. Expected ledger:

| Who | Gets |
| --- | --- |
| User | 0.00996 ETH (99.6%) |
| Relayer | 0.00004 ETH (0.4%), and pays the gas |
| DAO in TORN | 0.3% of the note in TORN, burned from the relayer's stake at the FeeManager's price |
| DAO in ETH | nothing: the pool charges no ETH fee on this path |

Before sending, two things are tried and must be refused: someone else submitting the relayer's proof through the Router ("Only custom relayer"), and the relayer sending its proof straight to the pool to skip the TORN burn ("Protocol fee above what the note owner accepted"). After sending, the same note is tried again ("The note has been already spent").

### 4. `withdraw --via unregistered`

```bash
node e2e/src/phase1.js deposit
node e2e/src/phase1.js withdraw --via unregistered
```

Same, with an unregistered address as relayer and the pool fee (0.00006 ETH) as the highest fee accepted in the proof. Expected ledger:

| Who | Gets |
| --- | --- |
| User | 0.0099 ETH (99%) |
| Relayer | 0.00004 ETH (0.4%), no TORN burned |
| DAO in ETH | 0.00006 ETH (0.6%): 0.3% protocol fee + 0.3% premium, kept by the pool, `ProtocolFeeCharged(…, paidToStaking = false)` |

Also refused: the registered relayer trying to send this proof through the Router ("only relayer").

### 5. `withdraw --via self`

```bash
node e2e/src/phase1.js deposit
node e2e/src/phase1.js withdraw --via self
```

No relayer: the recipient sends the proof straight to the pool from its own wallet and pays the gas. Expected ledger:

| Who | Gets |
| --- | --- |
| User | 0.00994 ETH (99.4%), minus its own gas |
| DAO in ETH | 0.00006 ETH (0.6%), kept by the pool |

Also refused: someone copying the proof and changing the recipient to their own address ("Invalid withdraw proof").

### 6. `withdraw --via router`

```bash
node e2e/src/phase1.js deposit
node e2e/src/phase1.js withdraw --via router
```

The fourth way in: the user sends its own proof through the Router without naming a relayer (`_relayer = 0`), instead of calling the pool directly. The Router calls the RelayerRegistry, which burns nothing for an unregistered sender naming no relayer, and the pool treats it like a self-withdrawal. Expected ledger: the same as step 5, 0.00994 ETH to the user and 0.00006 ETH kept by the pool. Also refused: the redirected proof.

### 7. `fees --protocol 50 --premium 100`

```bash
node e2e/src/phase1.js fees --protocol 50 --premium 100
node e2e/src/phase1.js deposit
node e2e/src/phase1.js withdraw --via registered
node e2e/src/phase1.js deposit
node e2e/src/phase1.js withdraw --via self
```

Governance changes the fees. Values are in 1/10000 of the note: 50 is 0.5%, 100 is 1%. The step deploys a small proposal contract on the fork (`test/utils/FeeChangeProposal.sol`) and passes it through the live Governance contract, with the vote simulated as in `setup`. The proposal changes the three places a fee lives: the pool's protocol fee and premium, the InstanceRegistry's protocol fee for the pool (what a registered relayer burns in TORN) and the FeeManager's cached TORN fee. The step reads all three back and checks them.

The two withdrawals that follow must use the new rates: the registered relayer burns 0.5% of the note in TORN, and the self-withdrawal pays 1.5%, 0.00015 ETH, to the pool. The self-withdrawal also tries a proof made with the **old** fee as the highest accepted, which must be refused: a fee raise never applies to a proof made before it.

### 8. `caps`

```bash
node e2e/src/phase1.js caps
```

Values out of bounds. The pool has two constants no proposal can change, `MAX_PROTOCOL_FEE_PERCENTAGE` = 100 (1%) and `MAX_DIRECT_WITHDRAW_PREMIUM_PERCENTAGE` = 400 (4%). The step, without sending anything, has Governance itself try 101, 10000 and 401 ("Fee above cap", "Premium above cap"), checks that 100 and 400 are accepted, has a random address try to change the fees ("Only governance"), and then passes a real proposal carrying 101 through the vote and shows that its execution reverts. **Every refusal is the expected result**; the step checks afterwards that nothing changed.

### 9. `fees --protocol 0 --premium 0`

```bash
node e2e/src/phase1.js fees --protocol 0 --premium 0
node e2e/src/phase1.js deposit
node e2e/src/phase1.js withdraw --via self
```

The fees can be removed. With both at 0 the FeeManager's TORN fee is 0 and a self-withdrawal pays the user the whole 0.01 ETH, with nothing kept by the pool.

### 10. `fees --protocol 30 --premium 30`

```bash
node e2e/src/phase1.js fees --protocol 30 --premium 30
```

Back to the initial 0.3% + 0.3%, so that the rest of the walkthrough runs with the values the proposal deploys.

### 11. `sweep`, before the staking upgrade

```bash
node e2e/src/phase1.js sweep
```

Anyone calls `sweepProtocolFees()` to send the fees the pool holds to the staking contract. **It is refused, and that is the expected result: the step passes when it is refused.** The sweep pays by calling `addEthRewards()` on the staking contract, and the implementation live today has no such function, so the call fails and the pool keeps the fees. Nobody, Governance included, can move them until phase II. The step checks the fees are still in the pool and the staking contract received nothing.

### 12. `phase2`, simulated

```bash
node e2e/src/phase1.js phase2
```

Deploys `StakingUpgradeProposal` on the fork and passes it through the live Governance contract the same way, with the voting delay and the timelock skipped by moving the fork's clock. Prints the staking implementation before and after. On mainnet this is a separate proposal, voted after this one.

### 13. `sweep`, after the upgrade

```bash
node e2e/src/phase1.js sweep
```

The same call now succeeds: the whole accrued amount moves from the pool to the staking contract, `ProtocolFeesSwept` is emitted, the pool holds 0.

### 14. `claim`

```bash
node e2e/src/phase1.js claim
```

The staker from step 1 calls `getEthReward()` and receives its share of the swept ETH, pro rata to its 10,000 TORN among all the TORN locked in Governance. Nothing is left for it to claim afterwards; the rest stays in the staking contract for the other lockers.

### 15. `report`

```bash
node e2e/src/phase1.js report
```

Writes `e2e/PHASE1-RESULTS.md`: the "where the funds went" table, the fee's journey from the pool to the lockers, every refused attempt, gas, the contracts, and the output of each step.

## Reading the output

Every step is a test. It prints what it does, then one line per value read from the chain and compared with the design, and ends with `PASS: N checks matched the design` or `✗ FAILED: <what did not match>`. Lines starting with `✓` are those checks: an amount with the expected amount next to it, or an attempt that was refused as it must be. This is what the registered-relayer withdrawal printed in the run recorded in `PHASE1-RESULTS.md`:

```text
$ node e2e/src/phase1.js withdraw --via registered
== Withdrawal 1: through a registered relayer (router) ==
fee setting     protocol fee 0.3%, premium 0.3%: a registered relayer burns the protocol fee in TORN, any other path pays 0.00006 ETH (0.6%)
note            tornado-eth-0.01-1-0xff863049e7a122e89fe827d27f638698768360558c80cc5138140c7fd56f578e37c408cd0a36c5f7f373cb003840bd2786fefb230487d2f6fd2a04432b1e (deposit 1)
✓ the Merkle tree rebuilt from the pool's Deposit events has the pool's root: 0x1bf69cf1dbbb8e2c5215978b12f27525d60700bdb472bcc8b8b426d47d351d15 (expected 0x1bf69cf1dbbb8e2c5215978b12f27525d60700bdb472bcc8b8b426d47d351d15)
✓ the note is among the deposits, at its leaf index: 0 (expected 0)
proof           made in 2.3 s with the classic UI's circuit; it binds the recipient 0xdEddC6C4237cA3F6de96C83Ec8AF10c36901cbAf, the relayer 0x4750BCfcC340AA4B31be7e71fa072716d28c29C5, the relayer fee 0.00004 ETH and the highest pool fee the user accepts, 0 ETH
sent by         0x4750BCfcC340AA4B31be7e71fa072716d28c29C5 (the registered relayer, through the Router)
✓ refused: someone else sends the relayer's proof through the Router: "Only custom relayer"
✓ refused: the relayer sends its proof straight to the pool, skipping the Router and the TORN burn: "Protocol fee above what the note owner accepted"
tx              0xda56a7bf2088e4d0510d1b105aea638a894f47be1479d85b3c07d8ad82b976b1 (440,378 gas, 0.000022423 ETH, paid by the relayer)
✓ the note is now spent: true (expected true)
✓ the user received (99.6% of the note): 0.00996 ETH (expected 0.00996 ETH)
✓ the relayer received (0.4%): 0.00004 ETH (expected 0.00004 ETH)
✓ DAO in TORN: burned from the relayer's stake, the FeeManager's fee for the pool: 0.01118 TORN (expected 0.01118 TORN)
✓ some TORN was burned: 0.01118 TORN, worth 0.00003 ETH at the FeeManager's price
✓ DAO in ETH: none, the pool emitted no ProtocolFeeCharged
✓ the pool kept for the lockers (0%): 0 ETH (expected 0 ETH)
✓ what left the pool: 0.01 ETH (expected 0.01 ETH)
✓ the staking contract received nothing: it cannot take ETH before phase II: 0 ETH (expected 0 ETH)
✓ refused: the same note is withdrawn a second time: "The note has been already spent"
pool now holds  0 ETH of fees waiting for phase II
PASS: 23 checks matched the design
```

The withdrawals print the same checks in the same order, so the paths can be compared line by line: what the user received, what the relayer received, the DAO's share in TORN, the DAO's share in ETH, what left the pool, what the staking contract received.

`PHASE1-RESULTS.md` has, for each test in order: what it verifies, the expected result with the amounts spelled out, PASS with the number of checks or FAIL with the first mismatch, the command, and the output above. A failed step is recorded the same way, and `./e2e/phase1.sh` still writes the report before exiting with an error, so the failure is on file.

The word SIMULATED marks the two things that happen on the fork only: the proposal's execution in `setup` when the fork predates it, and the staking upgrade in `phase2`.

## Limits

- The relayer is a registered relayer's address, not its software. Live relayers must add the pool to their configuration before they can serve it.
- Votes are cast by one account given quorum on the fork; delays are skipped by moving the clock.
- The TORN amounts depend on the live oracle price at the forked block and differ between runs. The ETH amounts do not.

## Options

| Variable | Effect |
| --- | --- |
| `FORK_BLOCK` | fork this block instead of the latest (needs an archive RPC) |
| `ANVIL_PORT` | port for the fork (default 8545) |
| `TORNADO_KEYS_DIR` | folder with the circuit and proving key |

`node e2e/src/phase1.js <step> --rpc URL --keys DIR --out FILE --proposal ADDRESS` overrides the fork URL, the keys folder, the report file and the proposal address.
