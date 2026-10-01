# Add ETH Pools — Tornado Cash Governance Proposal

Tornado Cash governance proposal that adds 0.01, 0.03, 0.3, 3 and 30 ETH anonymity pools whose DAO fee is impossible to bypass. This repo contains the on-chain proposal, the new pool contract and mainnet-fork tests (Foundry).

## Summary

- Adds five new ETH pools to Tornado Cash: 0.01, 0.03, 0.3, 3 and 30 ETH. Together with the live 0.1, 1, 10 and 100 ETH pools, the denominations become `0.01 — 0.03 — 0.1 — 0.3 — 1 — 3 — 10 — 30 — 100` ETH.
- All five pools use a new contract, `FeeEnforcedTornado_eth`, which charges the DAO fee inside the pool, so no withdrawal path can skip it:

  | Pool | Protocol fee | Premium | Withdrawal through a registered relayer | Any other withdrawal (direct, self-relay, unregistered relayer) |
  | --- | --- | --- | --- | --- |
  | 0.01, 0.03, 0.3 ETH | 0 | 0.3% | Free | 0 + 0.3% = 0.3% in ETH to the DAO |
  | 3, 30 ETH | 0.3% | 0.3% | 0.3% in TORN, burned from the relayer's stake | 0.3% + 0.3% = 0.6% in ETH to the DAO |

  The **protocol fee** is paid on every withdrawal: in TORN by registered relayers, in ETH by everyone else. The **premium** is paid in ETH, on top of the protocol fee, only by withdrawals that do not use a registered relayer.

- The ETH fee is sent to the DAO (Governance contract) in the same transaction as the withdrawal.
- Users can always withdraw, with or without a relayer. Nothing in the fee logic can lock funds.

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

Every new pool uses `FeeEnforcedTornado_eth`, which charges the fee **inside the pool**. Every withdrawal, whatever path it takes, ends in `pool.withdraw()`, so the fee cannot be skipped by avoiding the Router or the RelayerRegistry.

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

If all three hold, the withdrawal pays the registry fee in TORN (0.3% on 3 and 30 ETH, nothing on 0.01, 0.03 and 0.3 ETH) and the pool charges nothing extra. In every other case, the pool keeps its direct-withdrawal fee itself and sends it to Governance. Every bypass therefore ends up paying:

| Attempt to avoid the fee | Result |
| --- | --- |
| Call the pool directly | Pool charges the ETH fee |
| Call the pool directly naming a registered relayer | Pool charges the ETH fee (no Router, so no stake was burned) |
| Unregistered relayer through the Router | `burn` burns nothing, pool charges the ETH fee |
| `_relayer = 0` through the Router | `burn` burns nothing, pool charges the ETH fee |
| Unregistered sender naming a registered relayer through the Router | `burn` reverts ("Only custom relayer") |
| Registered relayer without enough stake | `burn` reverts |
| Registered relayer through the Router | Registry fee in TORN, no ETH fee |

Design choices that keep this safe for users:

- **Withdrawals never depend on relayers or Governance.** Users can always withdraw directly; they just pay the ETH fee. If the RelayerRegistry or Governance ever breaks, withdrawals keep working (see [Protocol fee details](#protocol-fee-details)).
- **Registered relayers are always the cheaper option.** On 0.01, 0.03 and 0.3 ETH they pay nothing versus 0.3% directly; on 3 and 30 ETH they pay 0.3% versus 0.6%. This also protects privacy: withdrawing directly requires funding the withdrawing address with gas.
- **The DAO controls the fee, within limits.** Governance can change the fee and the premium on each pool, capped at 1% and 4%, so even a compromised Governance cannot drain deposits through the fee.
- **Minimal new code.** `FeeEnforcedTornado_eth` reuses the verified classic `Tornado` base unchanged; only `_processWithdraw` differs. The circuit and verifier are the same as the live pools.

The live 0.1, 1, 10 and 100 ETH pools are already deployed and cannot be changed, so they keep the gap; this proposal only covers the pools it creates.

## How it works

### What the proposal does

`AddEthPoolsProposal.executeProposal()` is delegatecalled by Tornado Governance after the vote passes. For each denomination it:

1. Deploys a `FeeEnforcedTornado_eth` pool (merkle height 20, `operator = address(0)`, the shared verifier, and the MiMC `Hasher` library at the same address as the live 1/10/100 ETH pools) with `directWithdrawPremiumPercentage = 30` and:
   - 0.01, 0.03, 0.3 ETH: `protocolFeePercentage = 0`.
   - 3, 30 ETH: `protocolFeePercentage = 30`.
2. Registers it as `ENABLED` in the [InstanceRegistry](https://etherscan.io/address/0xB20c66C4DE72433F3cE747b58B86830c459CA911) so the [Tornado Router](https://etherscan.io/address/0xd90e2f925DA726b50C4Ed8D0Fb90Ad053324F31b) can route deposits and withdrawals, with the same `protocolFeePercentage` as the pool. That value sets the TORN burned on registered-relayer withdrawals, so the pool and the registry always start with the same protocol fee.

Fees use the same scale as the live FeeManager: values are divided by `10000`, so `30` = 0.3%.

### How a withdrawal is charged

- **Registered relayer through the Router:** the Router calls `burn`, which burns the registry fee (in TORN, at the Uniswap TWAP price) from the relayer's stake: 0.3% on 3 and 30 ETH, nothing on 0.01, 0.03 and 0.3 ETH. The pool pays `denomination - relayerFee` to the user and `relayerFee` to the relayer.
- **Any other path:** the pool keeps `protocolFeePercentage + directWithdrawPremiumPercentage` of the denomination (0 + 0.3% on 0.01, 0.03 and 0.3 ETH; 0.3% + 0.3% on 3 and 30 ETH), sends it to Governance in the same transaction, and pays the rest to the user (minus any relayer fee).

Examples:

| Note | Path | User receives | Relayer | DAO |
| --- | --- | --- | --- | --- |
| 0.3 ETH | Registered relayer charging X ETH | 0.3 − X ETH | X ETH, pays gas | — |
| 0.3 ETH | Direct withdrawal | 0.2991 ETH, pays own gas | — | 0.0009 ETH to Governance |
| 30 ETH | Registered relayer charging X ETH | 30 − X ETH | X ETH, pays gas and ~0.09 ETH worth of TORN from its stake | ~0.09 ETH worth of TORN, distributed to TORN lockers |
| 30 ETH | Direct withdrawal | 29.82 ETH, pays own gas | — | 0.18 ETH to Governance |

## Protocol fee details

- "Registered" = `msg.sender == RelayerRegistry.tornadoRouter()` and `RelayerRegistry.workers(_relayer) == _relayer` and `_relayer != 0`. Together these force `burn` to require the Router's caller to be a worker of `_relayer` and to burn its stake.
- The ETH fee is `protocolFeePercentage` + `directWithdrawPremiumPercentage`, both in basis points (divided by `PROTOCOL_FEE_DIVIDER` = 10000). Read them with `protocolFeePercentage()`, `directWithdrawPremiumPercentage()`, `directWithdrawFeePercentage()` (the sum) and `directWithdrawFee()` (amount in wei).
- Governance can change the fee with `setProtocolFeePercentage()`, up to the hard cap `MAX_PROTOCOL_FEE_PERCENTAGE` = 100 (1%), and the premium with `setDirectWithdrawPremiumPercentage()`, up to `MAX_DIRECT_WITHDRAW_PREMIUM_PERCENTAGE` = 400 (4%). The worst case is therefore 5% on direct withdrawals, so a compromised Governance cannot drain deposits through the fee. The TORN burned on registered-relayer withdrawals comes from the InstanceRegistry `protocolFeePercentage`, so a proposal that changes the protocol fee should update both the pool and the registry. The registry address is fixed at deploy.
- The ETH fee is sent to Governance during the withdrawal with a gas-capped call (`FEE_TRANSFER_GAS` = 50k; Governance needs ~5.3k). If Governance cannot receive it (reverts, runs out of gas, broken upgrade), the withdrawal still succeeds and the fee accrues in the pool. Anyone can later send accrued fees to Governance with `sweepProtocolFees()`. The event `ProtocolFeeCharged(relayer, amount, paidToGovernance)` records which happened.
- The premium is independent of the fee: setting the fee to 0 still charges the premium. To make direct withdrawals free, set both to 0.
- RelayerRegistry reads are raw `staticcall`s capped at `REGISTRY_CALL_GAS` = 50k gas (each read needs ~8k) that copy at most 32 bytes of return data. The registry is a proxy that Governance can upgrade, so a broken or malicious version could revert, consume all the gas it is given, or return a huge payload (a "return bomb": copying the reply into the pool's memory would cost more gas than the pool has left, so every withdrawal would revert). With the cap and the bounded copy, any of these only means the pool treats the withdrawal as not coming from a registered relayer and charges the ETH fee. Funds never depend on relayers or Governance to exit.

## Using the ETH fees

Governance (`0x5efda50f22d34F262c29268506C5Fa42cB56A1Ce`) only receives the ETH: its `receive()` is empty and it has no logic to distribute it. The ETH stays there until a governance proposal moves it. Only TORN is distributed automatically: relayer stake burned on registered-relayer withdrawals goes to [TornadoStakingRewards](https://etherscan.io/address/0x5B3f656C80E8ddb9ec01Dd9018815576E9238c29) (`addBurnRewards`), and TORN lockers claim it with `getReward()`. TornadoStakingRewards does not handle ETH, so the fees must not be sent there directly.

The DAO can choose, and change its choice at any time by proposal, between:

1. **Distribute to TORN lockers.** A periodic proposal swaps the accumulated ETH for TORN (e.g. on Uniswap), transfers the TORN to TornadoStakingRewards and calls `addBurnRewards(amount)`. Governance is allowed to call it (`msg.sender == Governance || msg.sender == relayerRegistry`). The ETH then reaches lockers exactly like the relayer fee, pro rata to locked TORN. No code change is needed; each distribution needs a vote. The TORN must be transferred before `addBurnRewards`, which only updates the reward rate.
2. **Keep it as treasury.** Leave the ETH in Governance and spend it through proposals: grants for community contributors, security reviews and audits, relayer or infrastructure support, etc. This also needs no code change.

Both options can be combined, for example by distributing part of the fees and keeping the rest.

## Compiler and bytecode

All pools are compiled with the same settings as the live mainnet ETH pools ([1 ETH](https://etherscan.io/address/0x47CE0C6eD5B0Ce3d3A51fdb1C52DC66a7c3c2936) / 10 / 100):

| Setting | Value |
| --- | --- |
| Contract | `FeeEnforcedTornado_eth` (classic `Tornado` base from `src/classic/TornadoCash_eth.sol`) |
| solc | `0.5.11` (optimizer **200** runs, **petersburg**) |
| Hasher library | `0x83584f83f26aF4eDDA9CBe8C730bc87C364b28fe` |

`FeeEnforcedTornado_eth` is new code, so no pool is bytecode-identical to the live pools and the contract needs its own review. The fork test asserts that each deployed pool's **metadata-stripped** runtime bytecode equals the compiled `FeeEnforcedTornado_eth` artifact from this repo, so the code Governance deploys is exactly the code in `src/`.

## Addresses

| Role | Address |
| --- | --- |
| Governance | `0x5efda50f22d34F262c29268506C5Fa42cB56A1Ce` |
| InstanceRegistry | `0xB20c66C4DE72433F3cE747b58B86830c459CA911` |
| TornadoRouter | `0xd90e2f925DA726b50C4Ed8D0Fb90Ad053324F31b` |
| Verifier | `0xce172ce1F20EC0B3728c9965470eaf994A03557A` |
| Hasher | `0x83584f83f26aF4eDDA9CBe8C730bc87C364b28fe` |
| RelayerRegistry | `0x58E8dCC13BE9780fC42E8723D8EaD4CF46943dF2` |

## Develop

```bash
forge install
forge build
ETH_RPC_URL=https://ethereum-rpc.publicnode.com forge test -vvv
```

`test/AddEthPoolsProposal.t.sol` spoofs a quorum-sized TORN holder (`deal`), runs the live governance cycle (`propose` → warp voting delay → `castVote` → warp voting period + execution delay → `execute`), asserts all five pools are `ENABLED` with the expected fees and the compiled `FeeEnforcedTornado_eth` code, then deposits into each via the Tornado Router.

`test/FeeEnforcedTornado_eth.t.sol` executes the proposal the same way, mocks the SNARK verifier, and withdraws from the pools through every path: registered relayer via Router (TORN burned on 3/30 ETH, nothing on 0.01/0.03/0.3 ETH), relayer without stake (reverts), unregistered sender naming a registered relayer (reverts), custom relayer via Router, `_relayer = 0`, direct call naming a registered relayer, direct self-withdraw, fees above denomination, a reverting, gas-burning or return-bomb RelayerRegistry (withdrawal still succeeds, ETH fee charged), immediate fee payment to Governance, a reverting or gas-burning Governance (withdrawal still succeeds, fee accrues), the sweep of accrued fees, and fee changes (getters, a real governance proposal changing fee and premium, premium added to the fee, zero fee still charging the premium, both caps, non-governance callers). The registered-relayer cases use the live relayer `0x4750…29C5`.

## Governance submission

1. Deploy `AddEthPoolsProposal` (no constructor args)
2. Verify source on Etherscan
3. Call `Governance.propose(proposalAddress, "Add 0.01, 0.03, 0.3, 3, and 30 ETH Tornado Cash anonymity pools")` with ≥ proposal threshold locked TORN
4. After voting + timelock, anyone can `execute(proposalId)`

## Layout

```
src/AddEthPoolsProposal.sol      # proposal (solc 0.5.11)
src/FeeEnforcedTornado_eth.sol   # fee-enforcing pool used by all five denominations
src/classic/TornadoCash_eth.sol  # verified classic mixer source (Tornado base + Hasher)
src/interfaces/                  # InstanceRegistry ABI
test/AddEthPoolsProposal.t.sol
test/FeeEnforcedTornado_eth.t.sol
test/utils/ProposalFixture.sol   # shared fork + governance execution
```
