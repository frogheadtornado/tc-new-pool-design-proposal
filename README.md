# A First Fee-Enforced Pool — Tornado Cash Governance Proposal

Tornado Cash governance proposal that adds a first pool whose DAO fee is impossible to bypass: 0.01 ETH. The proposal is one contract, and the pool is deployed when the proposal is executed. It is the first of three steps and it is meant to be tried on mainnet with small amounts. This repo contains the on-chain proposal, the new pool contract, mainnet-fork tests (Foundry) and an end-to-end test with real notes and proofs. It also contains the code of the second step, for review.

## The plan in three proposals

| | What it does | Status |
| --- | --- | --- |
| 1. This proposal | Deploys the 0.01 ETH pool with enforced fees and registers it. | `src/AddEthPoolsProposal.sol` |
| 2. Staking upgrade | Upgrades TornadoStakingRewards so that it can take the ETH fees and share them among TORN lockers. | Code ready in `src/staking/`, to be proposed after this one |
| 3. Rollout | Once everything has been tested on mainnet: deploys the other pools (0.03, 0.3 and 3 ETH) and updates the interface (IPFS) so that it shows the new pools. | Not written yet |

Each proposal is a single contract that deploys what it adds when Governance executes it.

## Summary

- Adds one new ETH pool to Tornado Cash: 0.01 ETH. No interface lists it yet, so it does not change anything for people using the live 0.1, 1, 10 and 100 ETH pools. The other denominations come with the third proposal.
- The pool uses a new contract, `FeeEnforcedTornado_eth`, which charges the DAO fee inside the pool, so no withdrawal path can skip it:

  | Pool | Protocol fee | Premium | Withdrawal through a registered relayer | Any other withdrawal (direct, self-relay, unregistered relayer) |
  | --- | --- | --- | --- | --- |
  | 0.01 ETH | 0.3% | 0.3% | 0.3% in TORN, burned from the relayer's stake | 0.3% + 0.3% = 0.6% in ETH to TORN lockers |

  The **protocol fee** is paid on every withdrawal: in TORN by registered relayers, in ETH by everyone else. The **premium** is paid in ETH, on top of the protocol fee, only by withdrawals that do not use a registered relayer.

- The DAO is paid once per withdrawal, never twice. When a registered relayer brings the withdrawal, the pool takes nothing: the relayer charges the user its own fee (around 0.4% today) and 0.3% is burned from its TORN stake, exactly as on the live pools. Relayers need no change to how they charge.
- The note owner fixes in the proof the most the pool may charge. A proof made for a registered relayer accepts no pool fee, so neither the relayer nor anyone who sees it in the mempool can send it down a path where the pool would take the fee out of the owner's payout.
- These fees are starting values. Governance can change the protocol fee and the premium of the pool at any time, within hard caps (see [Protocol fee details](#protocol-fee-details)).

- The ETH fee is for the TORN lockers. The staking contract that shares rewards among them cannot take ETH today, and this proposal does not change it. Until the second proposal upgrades it, the pool holds the ETH fees. Nobody can take them out: the only exit is `sweepProtocolFees()`, which anyone can call and which sends them to the staking contract once it accepts ETH. After the upgrade the pool pays each fee to the staking contract in the same transaction as the withdrawal.
- Withdrawals through a registered relayer need nothing new: the DAO is paid in TORN burned from the relayer's stake, which lockers earn and claim as they do today.
- Users can always withdraw, with or without a relayer. Nothing in the fee logic can lock funds.
- The pool is deployed when the proposal is executed, by Governance (about 3.7M gas). It does not exist before that. The only thing deployed before the vote is the proposal contract itself, which Governance needs in order to vote on it.
- This proposal does not touch the staking contract, Governance, the Router, the RelayerRegistry or any live pool.

## The problem: users can bypass DAO fees

In Tornado Cash, a pool's protocol fee (`protocolFeePercentage`, e.g. `30` = 0.3%) is a value stored in the InstanceRegistry. The classic pool contract never charges it. It is only collected when a withdrawal goes through the TornadoRouter, which calls `RelayerRegistry.burn` to burn TORN from the relayer's stake. That leaves two ways to withdraw without paying the DAO anything:

1. **Calling the pool directly.** `pool.withdraw()` is public. Skipping the Router means `burn` never runs.
2. **Using an unregistered ("custom") relayer through the Router.** `burn` deliberately lets these through without burning:

   ```solidity
   // RelayerRegistry.burn (live code)
   address masterAddress = workers[sender];
   if (masterAddress == address(0)) {
       require(workers[relayer] == address(0), "Only custom relayer");
       return; // nothing is burned
   }
   ```

   This includes naming `_relayer = address(0)`, since `workers[0] == 0`.

As a result, the DAO only gets paid when users choose to use a registered relayer. Any pool deployed with the classic contract has the same gap.

## How this proposal solves it

The new pool uses `FeeEnforcedTornado_eth`, which charges the fee **inside the pool**. Every withdrawal, whatever path it takes, ends in `pool.withdraw()`, so the fee cannot be skipped by avoiding the Router or the RelayerRegistry.

On each withdrawal the pool decides whether it comes from a registered relayer through the Router:

```solidity
bool viaRegisteredRelayer =
    _relayer != address(0) &&
    msg.sender == RelayerRegistry.tornadoRouter() &&
    RelayerRegistry.workers(_relayer) == _relayer;
```

These three conditions are exactly the case where `burn` cannot be skipped:

- `msg.sender` is the Router, so `burn` has run in this same transaction.
- `_relayer` is a registered relayer master (and not `0`), so `burn` cannot take the "custom relayer" branch: it requires the Router's caller to be a worker of `_relayer` and burns the registry fee from its stake, or reverts if the stake is too low.
- `_relayer` is part of the zero-knowledge proof, so nobody can change it after the user signs the withdrawal.

If all three hold, the withdrawal pays the registry fee in TORN (0.3%) and the pool charges nothing extra. In every other case, the pool keeps its direct-withdrawal fee for the TORN lockers, provided the proof says its owner accepts that fee (see [Protocol fee details](#protocol-fee-details)). Every attempt to avoid the fee therefore ends up paying or failing:

| Attempt to avoid the fee | Result |
| --- | --- |
| Call the pool directly | Pool charges the ETH fee |
| Send a proof made for a registered relayer straight to the pool | Reverts: that proof accepts no pool fee, so its owner cannot be charged because someone picked another path |
| Unregistered relayer through the Router | `burn` burns nothing, pool charges the ETH fee |
| `_relayer = 0` through the Router | `burn` burns nothing, pool charges the ETH fee |
| Unregistered sender naming a registered relayer through the Router | `burn` reverts ("Only custom relayer") |
| Registered relayer without enough stake | `burn` reverts |
| Registered relayer through the Router | Registry fee in TORN, no ETH fee |

Design choices that keep this safe for users:

- **Withdrawals never depend on relayers, Governance or the staking contract.** Users can always withdraw directly; they just pay the ETH fee. If the RelayerRegistry or the staking contract ever breaks, or is replaced by a hostile version, withdrawals keep working (see [Protocol fee details](#protocol-fee-details)).
- **Skipping registered relayers costs more.** A relayer typically charges the user around 0.4% and pays 0.3% of the denomination to the DAO in TORN out of its stake. A withdrawal without a registered relayer pays the DAO 0.6% in ETH. On a note this small the 0.3% premium is a small amount (0.00003 ETH) next to gas, so Governance may want to raise it later. Using a relayer also protects privacy: withdrawing directly requires funding the withdrawing address with gas.
- **The DAO controls the fee, within limits.** Governance can change the fee and the premium of the pool, capped at 1% and 4%, so even a compromised Governance cannot drain deposits through the fee.
- **Minimal new code.** `FeeEnforcedTornado_eth` reuses the verified classic `Tornado` base unchanged; only `_processWithdraw` differs. The circuit and verifier are the same as the live pools.

The live 0.1, 1, 10 and 100 ETH pools are already deployed and cannot be changed, so they keep the gap; this proposal only covers the pool it adds.

## How it works

### What is deployed, and when

**Before the vote**, one contract, by anyone: the proposal, `AddEthPoolsProposal`. Governance votes on a contract that already exists, so this one cannot be avoided. `script/Deploy.s.sol` deploys it, as an ordinary contract deployment.

**When the proposal is executed**, Governance creates the pool, with a plain `new FeeEnforcedTornado_eth(...)` in the proposal's code. The pool does not exist until then: nobody can use it before the DAO has approved it, and a defeated proposal leaves nothing behind. Its address is in the `PoolAdded` event and it is the instance the proposal adds to the InstanceRegistry.

Governance records the hash of the proposal's code when it is proposed and checks it again at execution, so the code that is voted on is the code that runs.

### What the proposal does

`AddEthPoolsProposal.executeProposal()` is delegatecalled by Tornado Governance after the vote passes. It:

1. Deploys the pool: `FeeEnforcedTornado_eth` for 0.01 ETH with merkle height 20, `operator = address(0)`, the shared verifier and the MiMC `Hasher` library at the same address as the live 1/10/100 ETH pools. It starts with `protocolFeePercentage = 30` and `directWithdrawPremiumPercentage = 30`.
2. Registers it as `ENABLED` in the [InstanceRegistry](https://etherscan.io/address/0xB20c66C4DE72433F3cE747b58B86830c459CA911) so the [Tornado Router](https://etherscan.io/address/0xd90e2f925DA726b50C4Ed8D0Fb90Ad053324F31b) can route deposits and withdrawals, with the same `protocolFeePercentage` as the pool. That value sets the TORN burned on registered-relayer withdrawals, so the pool and the registry start with the same protocol fee.
3. Refreshes the pool's TORN fee in the [FeeManager](https://etherscan.io/address/0x5f6c97C6AD7bdd0AE7E0Dd4ca33A4ED3fDabD4D7). The FeeManager caches that fee for two days and anyone can make it cache 0 for a pool that is not registered yet, which would leave registered-relayer withdrawals free until someone refreshed it.

Fees use the same scale as the live FeeManager: values are divided by `10000`, so `30` = 0.3%.

If any step fails, execution reverts as a whole and nothing is deployed. Called directly, outside Governance, the proposal reverts: only Governance can register a pool.

### How a withdrawal is charged

- **Registered relayer through the Router:** the Router calls `burn`, which burns the registry fee (in TORN, at the Uniswap TWAP price) from the relayer's stake: 0.3% of the denomination. The pool pays `denomination - relayerFee` to the user and `relayerFee` to the relayer, and takes nothing itself.
- **Any other path:** the pool keeps `protocolFeePercentage + directWithdrawPremiumPercentage` of the denomination (0.3% + 0.3%) for the TORN lockers, and pays the rest to the user (minus any relayer fee). Until the staking upgrade the pool holds that ETH; after it, the pool pays it into the lockers' ETH rewards in the same transaction.

Examples:

| Note | Path | User receives | Relayer | TORN lockers |
| --- | --- | --- | --- | --- |
| 0.01 ETH | Registered relayer charging X ETH | 0.01 − X ETH | X ETH, pays gas and ~0.00003 ETH worth of TORN from its stake | ~0.00003 ETH worth of TORN |
| 0.01 ETH | Direct withdrawal | 0.00994 ETH, pays own gas | — | 0.00006 ETH (held by the pool until the staking upgrade) |

## Protocol fee details

- "Registered" = `msg.sender == RelayerRegistry.tornadoRouter()` and `RelayerRegistry.workers(_relayer) == _relayer` and `_relayer != 0`. Together these force `burn` to require the Router's caller to be a worker of `_relayer` and to burn its stake.
- The ETH fee is `protocolFeePercentage` + `directWithdrawPremiumPercentage`, both in basis points (divided by `PROTOCOL_FEE_DIVIDER` = 10000). Read them with `protocolFeePercentage()`, `directWithdrawPremiumPercentage()`, `directWithdrawFeePercentage()` (the sum) and `directWithdrawFee()` (amount in wei).
- Governance can change the fee with `setProtocolFeePercentage()`, up to the hard cap `MAX_PROTOCOL_FEE_PERCENTAGE` = 100 (1%), and the premium with `setDirectWithdrawPremiumPercentage()`, up to `MAX_DIRECT_WITHDRAW_PREMIUM_PERCENTAGE` = 400 (4%). The worst case is therefore 5% on direct withdrawals, so a compromised Governance cannot drain deposits through the fee. The TORN burned on registered-relayer withdrawals comes from the InstanceRegistry `protocolFeePercentage`, so a proposal that changes the protocol fee should update both the pool and the registry. The registry and the fee recipient are fixed at deploy.
- The pool tries to pay the ETH fee during the withdrawal by calling `addEthRewards()` on the staking contract (`STAKING_REWARDS`) with a gas-capped call (`FEE_TRANSFER_GAS` = 150k; once the staking contract is upgraded the payment needs about 43k the first time and 26k afterwards). If the staking contract cannot take it, the withdrawal still succeeds and the fee stays in the pool, counted in `accruedProtocolFees`. That is the case for every fee until the staking upgrade, because the staking contract live today has no such function. It would also be the case later if the staking contract reverted, ran out of gas or had no TORN locked. Anyone can send the fees held by the pool to the staking contract with `sweepProtocolFees()`; it reverts, and changes nothing, while the staking contract cannot take them. The event `ProtocolFeeCharged(relayer, amount, paidToStaking)` records which happened.
- **The owner's consent is in the proof.** `withdraw` takes the classic `_refund` argument, a public input of the proof that ETH pools leave at zero. Here it is the highest ETH fee the note owner accepts, and the withdrawal reverts if the pool would charge more. A wallet sets it to 0 for a withdrawal through a registered relayer and to `directWithdrawFee()` otherwise. Which fee applies depends on who submits the proof, and the proof does not bind that, so without this:
  - a relayer could send the user's proof straight to the pool, keep its fee, burn no stake and leave the user to pay the pool fee, and anyone watching the mempool could do the same;
  - a fee raised by Governance after the proof was made would be charged without the owner's agreement (now the old proof is refused and the owner makes a new one);
  - if the pool's registry read failed after the Router had burned the relayer's stake, the withdrawal would pay twice (now it reverts).
- The fee receiver cannot use the payment to block a withdrawal. The reentrancy guard of the classic base reverts the outer call when a nested guarded call completes. So `sweepProtocolFees()` is deliberately left outside the guard, and deposits and withdrawals are refused while a fee is being paid (`feePaymentLock`), whatever gas they would need.
- **The TORN side relies on the FeeManager's price.** The TORN burned from a registered relayer is computed by the live FeeManager from a 90-minute average of the TORN/WETH Uniswap pool, cached for up to two days and refreshable by anyone. That pool is thin (about 27,000 TORN and 77 WETH when reviewed), so someone who holds its price up for the window lowers the burn until the next refresh; a review estimated well under 1 ETH to halve it if nobody trades against the move. The live pools work this way today. It matters little for 0.01 ETH notes and should be hardened in the FeeManager before larger pools are added.
- If the staking upgrade were never approved, the ETH fees collected by this pool would stay in it: there is no other way out. With a 0.01 ETH pool that no interface lists, that is a small amount.
- The premium is independent of the fee: setting the fee to 0 still charges the premium. To make direct withdrawals free, set both to 0.
- RelayerRegistry reads are raw `staticcall`s capped at `REGISTRY_CALL_GAS` = 50k gas (each read needs ~8k) that copy at most 32 bytes of return data. The registry is a proxy that Governance can upgrade, so a broken or malicious version could revert, consume all the gas it is given, or return a huge payload (a "return bomb": copying the reply into the pool's memory would cost more gas than the pool has left, so every withdrawal would revert). With the cap and the bounded copy, any of these only means the pool treats the withdrawal as not coming from a registered relayer and charges the ETH fee. Funds never depend on relayers, Governance or the staking contract to exit.

## The second proposal: the staking upgrade

**Not part of this proposal.** This section describes what comes next, so that it can be reviewed in advance. The code is in `src/staking/`: the new implementation, `TornadoStakingRewards.sol`, and the proposal that deploys it and upgrades the staking contract to it, `StakingUpgradeProposal.sol`. Like the first proposal it is a single contract, and the new implementation is created with a plain `new TornadoStakingRewards(...)` when Governance executes it (about 2.1M gas). It refuses to run if the staking implementation is no longer the one the new code was derived from (`0x9c97be37840f0e754bb7aDB1b16fD0954A2BA248`).

[TornadoStakingRewards](https://etherscan.io/address/0x5B3f656C80E8ddb9ec01Dd9018815576E9238c29) already shares burned relayer stake among TORN lockers: each burn raises a counter, "TORN earned per locked TORN", and a locker is owed the counter's rise since their balance last changed, times their locked TORN. Governance tells the contract before every lock and unlock, so a new locker earns nothing from earlier burns and a locker who leaves keeps what they earned.

The new implementation keeps the same bookkeeping for other assets, with one counter per asset: ETH, and each token that Governance adds.

| Function | What it does |
| --- | --- |
| `addEthRewards()` payable | Adds the ETH sent with the call to the lockers' rewards: raises "ETH earned per locked TORN" by the amount divided by the TORN locked in Governance. Called by the pools; anyone may call it. |
| `checkEthReward(account)` | ETH the account can claim. |
| `getEthReward()` | Sends the caller their ETH. `getReward()` stays TORN only. |
| `addRewardToken(token)` | Governance only. Lets a token pay rewards. At most `MAX_REWARD_TOKENS` = 4 tokens, and a token cannot be taken off the list. |
| `addTokenRewards(token)` | Shares among the lockers the amount of the token that reached the contract since the last call. A pool pays a fee by sending the token and then calling this; anyone may call it. |
| `checkTokenReward(token, account)` | Amount of the token the account can claim. |
| `getTokenReward(token)` | Sends the caller their rewards in that token. |
| `getRewardTokens()` | The tokens added so far. |
| `getEthRewardUpTo(n)`, `getTokenRewardUpTo(token, n)` | The same claims in steps, for an account that has changed its locked balance thousands of times since its last claim. |

On the existing lock/unlock notification (`updateRewardsOnLockedBalanceChange`) the contract settles TORN as before and, for all the other assets together, takes one checkpoint. See [How the cost of a lock stays the same](#how-the-cost-of-a-lock-stays-the-same).

Once the upgrade is executed, anyone calls `sweepProtocolFees()` on the pool and the ETH it has been holding is shared among the lockers.

### Tokens: ready, not used yet

The staking upgrade adds no token and no token pool exists. The code is there so that a later proposal that deploys pools in DAI, USDT or another token only has to call `addRewardToken`, instead of upgrading the staking contract again.

A pool would pay a fee in a token by sending it to the staking contract and calling `addTokenRewards(token)`. The contract compares its balance of the token with what it has already shared, and shares the difference. So:

- It shares what arrived, not what the sender says it sent. A token that keeps part of each transfer (USDT can be set to do so) cannot leave the contract owing more than it holds.
- If the call fails or is never made, nothing is lost: the tokens are shared by the next call, whoever makes it.
- Tokens whose `transfer` returns nothing, like USDT, work.
- TORN rewards are not part of this and do not change: lockers keep earning TORN from the relayers' burned stake and keep claiming it with `getReward()`, as today. TORN is only kept off the list of added tokens, because it already has its own bookkeeping. On that list, the contract would take all the TORN it holds (the relayers' stake and the TORN rewards not claimed yet, about 468,000 TORN today) for new fees and share it out a second time.
- A token that stops working (paused, or the staking contract blocked by the token's issuer) cannot stop locking, unlocking, relayer burns or the rewards in other assets, because the lock/unlock notification never calls a token. Only claims of that token fail.
- Governance should only add plain tokens. A token whose balances change by themselves (rebasing) would break the accounting of that token.

Token pools need their own pool contract and their own proposal. This repository does not contain one.

### How the cost of a lock stays the same

Governance wraps the lock/unlock notification in `try/catch`: if the notification fails, the lock or unlock goes on, and the rewards of that account are later worked out on the wrong balance. After a lock that is too much, and it is taken from the other lockers. This is how Governance works today, for TORN rewards.

The notification can only fail by running out of gas. A call that runs out of gas leaves its caller 1/64 of the gas, and that happens twice here, in Governance and in the staking proxy. So the trick only works if about 1/32 of the notification's gas is enough to finish the lock or unlock. The notification therefore has to stay cheap, and it must not get more expensive with every asset that is added.

That is why ETH and token rewards are not settled on each lock and unlock, asset by asset. Instead:

- A lock or unlock takes one **checkpoint** for the account: a single storage word with the TORN it had locked until then and, for every asset at once, where that asset's "earned per locked TORN" counter stood. If no fee arrived in any asset since the account's last checkpoint, nothing is written.
- The rewards are worked out when they are claimed: for each stretch between two checkpoints, the rise of the counter times the TORN locked in that stretch.
- To be able to look a counter up as it stood at a checkpoint, each asset's counter is kept in numbered versions. Once a checkpoint refers to a version, that version is never written again, and the next fee starts a new one.

A checkpoint has room for ETH and four tokens, which is where `MAX_REWARD_TOKENS` = 4 comes from. Within that, the cost of a lock or unlock does not depend on how many tokens there are:

| Staking contract | Gas for the most expensive unlock / lock | Gas needed to complete an unlock / lock while the notification fails | Margin |
| --- | --- | --- | --- |
| Live today (TORN) | 70,484 / 71,885 | 394,441 / 441,017 | 5.6 / 6.1 times |
| After the staking upgrade, ETH only | 98,644 / 100,074 | 394,441 / 441,017 | 4.0 / 4.4 times |
| After the staking upgrade, with four tokens added | 98,644 / 100,074 | 394,441 / 441,017 | 4.0 / 4.4 times |

The left column is the worst case for the notification: the first one of an account that locked before the staking contract existed and has not moved since, so that nothing is noted down for it yet, with fees received in every asset. The middle column is the best case for the caller: everything Governance uses after the notification was already read or written in the same transaction, which makes it cheaper. Once only, the first checkpoint anybody takes after the upgrade costs a little more (116,025 / 117,456, a margin of 3.4 / 3.75). `testRewardUpdateCannotBeSkippedByChoosingTheGas` measures all of this, and fails if the margin drops below 3.5 (3 for that first checkpoint) or if a lock with four tokens costs more than a lock with none.

What this costs:

- A claim goes through the account's checkpoints since its last claim of that asset, so it costs more gas for an account that changed its locked balance many times in between (about 5,000 gas for each change). `getEthRewardUpTo` and `getTokenRewardUpTo` claim in steps if that ever became too much for one transaction.
- The first fee paid in an asset after anybody's lock or unlock starts a new version, which costs the payer about 5,000 gas more (51,000 instead of 46,000 for the first payment; the pool allows 150,000).

These numbers follow from the gas costs of the network, which can change in a network upgrade. The test should be run again before the staking upgrade is proposed, and before any token is added.

### What changes in the contract, and what does not

- The file is the Sourcify-verified source of the live implementation plus additions marked `Asset rewards`. Compiled unmodified with the live settings it reproduced the live code byte for byte, apart from immutable values and the metadata trailer.
- Storage slots 0–3 keep the live layout. The additions use slots 4–10, which are empty on mainnet.
- A counter is refused beyond 128 bits, which would take more than 3e13 ETH for each TORN locked. A checkpoint keeps the locked balance in 84 bits (all the TORN there is fits), each version in 30 bits and the number of checkpoints of an account in 22 bits.
  - An asset that used up its versions (over a billion) would refuse further fees until the staking contract was upgraded again; the pools would keep them meanwhile. Anyone can start a new version, with a lock followed by a payment of any size, at about 50,000 to 70,000 gas each. Using them all up would take more than 5e13 gas, several months of every block on mainnet, and gain nothing.
  - An account that used up its checkpoints (over four million) would stop earning in these assets. Only its own locks and unlocks take checkpoints, so nobody can push another account towards that.
- The only changed original lines are the constructor: the reward scale `ratioConstant` is now passed in instead of read from TORN's total supply. The live value was the supply when the current implementation was deployed; TORN has been burned since, and recomputing it would rescale the TORN rewards already accumulated. The proposal passes in the live value.
- TORN rewards, relayer stake burns and Governance's lock/unlock work as before. The proxy address does not change, so Governance and the RelayerRegistry need no change.

### Things to know

- ETH must come in through `addEthRewards()`. A plain transfer is rejected. ETH forced in some other way, for example by a self-destructing contract, is not credited to anyone.
- If no TORN is locked, `addEthRewards()` reverts and the pool keeps the fee until it can be swept.
- `getEthReward()` pays the caller. A locker that is a contract unable to receive ETH cannot claim.
- A fee is shared by the TORN locked at the moment it arrives, and Governance has no minimum lock time outside voting. This is the same for TORN rewards today. A large holder can therefore lock just before a fee is paid, or before sweeping accrued fees, and unlock after; a holder who withdraws without a relayer gets part of its own fee back that way (about 10% with 300,000 TORN). A minimum lock time in Governance would remove this; it is a separate change, worth making before larger pools are added.
- The split divides each fee by the TORN held by the Governance vault, as the TORN rewards do. It pays out exactly what came in only while the vault holds the sum of all locked balances. That holds today: at block 26,111,393 the vault held 2,578,238.552479532239793190 TORN, the exact sum of the 590 non-zero `lockedBalance` entries among the 2,126 accounts found in TORN transfers to and from Governance and its vault and in Governance events. A balance written straight to storage would not appear in that list. If the vault ever held less than that sum, the last lockers to claim would find the contract short; if it held more, part of each fee would stay unclaimed.
- Rounding favours the contract: a few wei per payment stay behind.

## Compiler and bytecode

| | This proposal | Second proposal (staking upgrade) |
| --- | --- | --- |
| Contract | `AddEthPoolsProposal`, `FeeEnforcedTornado_eth` (classic `Tornado` base from `src/classic/TornadoCash_eth.sol`) | `StakingUpgradeProposal`, `TornadoStakingRewards` |
| solc | `0.5.11`, optimizer **200** runs, **petersburg** | `0.6.12`, optimizer **200** runs, **istanbul** |
| Same settings as | the live ETH pools ([1 ETH](https://etherscan.io/address/0x47CE0C6eD5B0Ce3d3A51fdb1C52DC66a7c3c2936) / 10 / 100) | the live implementation |
| Hasher library | `0x83584f83f26aF4eDDA9CBe8C730bc87C364b28fe` | — |

`FeeEnforcedTornado_eth` is new code, so no pool is bytecode-identical to the live pools and the contract needs its own review. So does the staking implementation, before the second proposal.

## Addresses

| Role | Address |
| --- | --- |
| Governance | `0x5efda50f22d34F262c29268506C5Fa42cB56A1Ce` |
| InstanceRegistry | `0xB20c66C4DE72433F3cE747b58B86830c459CA911` |
| TornadoRouter | `0xd90e2f925DA726b50C4Ed8D0Fb90Ad053324F31b` |
| Verifier | `0xce172ce1F20EC0B3728c9965470eaf994A03557A` |
| Hasher | `0x83584f83f26aF4eDDA9CBe8C730bc87C364b28fe` |
| RelayerRegistry | `0x58E8dCC13BE9780fC42E8723D8EaD4CF46943dF2` |
| TornadoStakingRewards (proxy) | `0x5B3f656C80E8ddb9ec01Dd9018815576E9238c29` |
| TornadoStakingRewards (live implementation) | `0x9c97be37840f0e754bb7aDB1b16fD0954A2BA248` |

The proposal gets its address when it is deployed, and the pool when the proposal is executed.

## Develop

```bash
git submodule update --init --recursive
forge build
ETH_RPC_URL=https://ethereum-rpc.publicnode.com forge test -vvv
```

All tests run against a mainnet fork: the latest block, or `FORK_BLOCK` when set (needs an archive RPC). The suites first deploy the proposal, as before a real vote; executing it then deploys the pool. Once the proposal has been executed on mainnet, pin `FORK_BLOCK` to a block before the execution.

`test/AddEthPoolsProposal.t.sol` spoofs a quorum-sized TORN holder (`deal`), runs the live governance cycle (`propose` → warp voting delay → `castVote` → warp voting period + execution delay → `execute`) and asserts that the pool does not exist before execution, that execution deploys the compiled pool and registers it as `ENABLED` with the expected fees, that the staking contract is left untouched, and that execution fits under the per-transaction gas cap. It also covers the proposal called directly (it reverts) and the deployment script, which must deploy the proposal and nothing else.

`test/FeeEnforcedTornado_eth.t.sol` executes the proposal the same way, mocks the SNARK verifier, and withdraws through every path. Most of it runs in the state after both proposals (pool live, staking upgraded), where the fee reaches the lockers at once. The state between the two (pool live, staking as today) has its own tests: the pool holds the fee and the withdrawal goes through, the fee cannot be forwarded yet, it is forwarded after the upgrade, and relayed withdrawals work as on the live pools. To test the pool contract at larger amounts too, the fixture deploys the same code for 0.03, 0.3, 3 and 30 ETH and registers it as Governance, the way a later proposal would. It covers: registered relayer via Router (0.3% burned in TORN at the live pools' rate, no ETH fee on top), relayer without stake (reverts), unregistered sender naming a registered relayer (reverts), custom relayer via Router, `_relayer = 0`, a proof made for a registered relayer sent straight to the pool (reverts), the limit the note owner sets on the pool fee and a fee raised after the proof was made, direct self-withdraw, fees above denomination, a reverting, gas-burning or return-bomb RelayerRegistry (withdrawal still succeeds, ETH fee charged), immediate fee payment to the staking contract and the locker's claim, a reverting, gas-burning or return-bomb staking contract (withdrawal still succeeds, fee accrues), a staking contract that calls back into the pool during the payment (sweeping it, or trying a deposit or a withdrawal), a FeeManager fee cached as zero before registration, the gas allowance of the fee payment, the sweep of accrued fees, and fee changes (getters, a real governance proposal changing fee and premium, premium added to the fee, zero fee still charging the premium, both caps, non-governance callers). The registered-relayer cases use the live relayer `0x4750…29C5`.

The remaining two suites are for the second proposal. `test/StakingUpgradeProposal.t.sol` passes `StakingUpgradeProposal` through Governance and asserts that the new implementation does not exist before execution, that execution deploys the compiled implementation and upgrades the proxy to it with the same reward scale and no reward token, that it refuses to run on top of another implementation, and that fees held by the pool since the first proposal reach the lockers after the second.

`test/TornadoStakingRewards.t.sol` upgrades the live staking proxy the way that proposal does and checks the ETH rewards (split by locked TORN, nothing for a locker who joins later, locking more or unlocking keeps what was earned, a claim pays once even if the locker calls back while being paid, randomized lock/unlock/pay/claim sequences never pay out more than came in, plain transfers and payments with nothing locked are rejected, a contract that cannot receive ETH cannot claim), the token rewards (the same cases with DAI and USDT; who can add a token, and that an address without code, a repeated token, a fifth token or TORN, which keeps its own rewards, are refused; tokens shared once, tokens sent without calling the contract, sent while nothing is locked or held before the token was added; each asset accounted on its own; a token that keeps part of each transfer; a token that stops working; the largest values that fit), the checkpoints (rewards across many changes of balance, no checkpoint when no fee arrived, a token added when checkpoints already exist, claims in steps, the limits of what a checkpoint holds, and randomized sequences in every asset checked against an independent calculation of what each locker earned, with a locker from before the upgrade, fees and locks of zero and partial claims), that a lock or unlock cannot complete without the reward update whatever gas the caller picks and costs the same with four tokens as with none, and that the upgrade leaves TORN rewards alone (pending rewards and reward scale unchanged, including for the largest real locker; burns still accrue, Governance's lock/unlock notification still succeeds, a relayed withdrawal on a live pool still burns stake).

### End-to-end test on a local fork

`./e2e/run.sh` starts a local anvil fork of mainnet, deploys with `script/Deploy.s.sol`, passes the proposal through the live Governance contract, then makes real notes, deposits and withdraws from the pool with real zero-knowledge proofs (registered relayer, unregistered relayer, direct, through the Router without a relayer), and has a staker claim TORN. Up to there it is what mainnet will look like after this proposal: the ETH fees are in the pool. It then goes on with the second proposal: it passes the staking upgrade through Governance, forwards the fees the pool was holding, makes one more withdrawal, and has the staker claim ETH and unlock. Nothing is mocked: the withdrawals are checked by the verifier contract that is live on mainnet. Every amount is compared with the design and the run stops at the first mismatch. The measured amounts are written to [`e2e/RESULTS.md`](e2e/RESULTS.md).

It needs Node.js and the classic UI's `tornado.json.gz` and `tornadoProvingKey.bin.gz` (looked for in `../classic-ui/static`, or in `TORNADO_KEYS_DIR`). The RPC URL is read from `ETH_RPC_URL` or `RPC_URL`, or from a `.env` file in this repository or its parent folder.

## Governance submission

1. Run `forge script script/Deploy.s.sol --rpc-url $ETH_RPC_URL --broadcast` with a funded account. It deploys the proposal, `AddEthPoolsProposal` (one transaction, about 2.6M gas), and prints its address.
2. Verify its source on Etherscan.
3. Call `Governance.propose(proposalAddress, description)` with ≥ proposal threshold locked TORN. The interface shows the description best as JSON with a `title` and a `description` field, for example `{"title":"Add a 0.01 ETH pool with enforced fees","description":"..."}`.
4. After voting + timelock, anyone can `execute(proposalId)`. It uses about 3.7M gas; the limit for one transaction is 16.8M.
5. Verify the source of the pool on Etherscan. Its address is in the `PoolAdded` event of the execution.

## Layout

```
src/AddEthPoolsProposal.sol            # this proposal: deploys the 0.01 ETH pool and registers it (solc 0.5.11)
src/FeeEnforcedTornado_eth.sol         # fee-enforcing pool
src/classic/TornadoCash_eth.sol        # verified classic mixer source (Tornado base + Hasher)
src/interfaces/                        # InstanceRegistry and FeeManager ABIs
src/staking/                           # the second proposal, for a later vote (solc 0.6.12):
src/staking/StakingUpgradeProposal.sol #   deploys the new staking implementation and upgrades the proxy
src/staking/TornadoStakingRewards.sol  #   new staking implementation: live source + rewards in ETH and tokens
src/staking/vendor/                    #   its dependencies, as verified for the live implementation
script/Deploy.s.sol                    # deploys this proposal
test/AddEthPoolsProposal.t.sol
test/FeeEnforcedTornado_eth.t.sol
test/StakingUpgradeProposal.t.sol
test/TornadoStakingRewards.t.sol
test/utils/ProposalFixture.sol         # shared fork, deployment and governance execution
e2e/run.sh                             # end-to-end test on a local fork, with real notes and proofs
e2e/src/                               # its code: notes, Merkle tree and proofs; the test itself
e2e/RESULTS.md                         # amounts measured by the last run
```
