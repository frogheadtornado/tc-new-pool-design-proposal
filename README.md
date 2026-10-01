# Add ETH Pools — Tornado Cash Governance Proposal

Tornado Cash governance proposal that adds 0.01, 0.03, 0.3, 3 and 30 ETH anonymity pools, and makes the DAO protocol fee on the 3 and 30 ETH pools impossible to bypass. This repo contains the on-chain proposal, the new pool contract and mainnet-fork tests (Foundry).

## Summary

- Adds five new ETH pools to Tornado Cash: 0.01, 0.03, 0.3, 3 and 30 ETH. Together with the live 0.1, 1, 10 and 100 ETH pools, the denominations become `0.01 — 0.03 — 0.1 — 0.3 — 1 — 3 — 10 — 30 — 100` ETH.
- The 0.01, 0.03 and 0.3 ETH pools are the classic, unmodified Tornado contract and charge no fee.
- The 3 and 30 ETH pools charge the DAO a 0.3% protocol fee on **every** withdrawal, whatever path the user takes:
  - Withdrawals through a registered relayer pay it in TORN, burned from the relayer's stake.
  - Every other withdrawal (direct call, self-relay, unregistered relayer) pays 0.3% + a 0.3% premium = 0.6% in ETH, sent to the DAO (Governance contract) in the same transaction.
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

As a result, the DAO only gets paid when users choose to use a registered relayer. A fee pool deployed with the classic contract would have the same gap.

## How this proposal solves it

The 3 and 30 ETH pools use a new contract, `FeeEnforcedTornado_eth`, that charges the fee **inside the pool**. Every withdrawal, whatever path it takes, ends in `pool.withdraw()`, so the fee cannot be skipped by avoiding the Router or the RelayerRegistry.

On each withdrawal the pool decides whether the fee has already been paid in TORN:

```solidity
bool viaRegisteredRelayer =
    _relayer != address(0) &&
    msg.sender == RelayerRegistry.tornadoRouter() &&
    RelayerRegistry.workers(_relayer) == _relayer;
```

These three conditions are exactly the case where `burn` cannot skip the fee:

- `msg.sender` is the Router, so `burn` has run in this same transaction.
- `_relayer` is a registered relayer master (and not `0`), so `burn` cannot take the "custom relayer" branch: it requires the Router's caller to be a worker of `_relayer` and burns 0.3% from its stake, or reverts if the stake is too low.
- `_relayer` is part of the zero-knowledge proof, so nobody can change it after the user signs the withdrawal.

If all three hold, the fee was paid in TORN and the pool charges nothing extra. In every other case, the pool keeps 0.6% of the denomination itself and sends it to Governance. Every bypass therefore ends up paying:

| Attempt to avoid the fee | Result |
| --- | --- |
| Call the pool directly | Pool charges 0.6% in ETH |
| Call the pool directly naming a registered relayer | Pool charges 0.6% in ETH (no Router, so no stake was burned) |
| Unregistered relayer through the Router | `burn` burns nothing, pool charges 0.6% in ETH |
| `_relayer = 0` through the Router | `burn` burns nothing, pool charges 0.6% in ETH |
| Unregistered sender naming a registered relayer through the Router | `burn` reverts ("Only custom relayer") |
| Registered relayer without enough stake | `burn` reverts |
| Registered relayer through the Router | 0.3% burned in TORN, no ETH fee |

Design choices that keep this safe for users:

- **Withdrawals never depend on relayers or Governance.** Users can always withdraw directly; they just pay the ETH fee. If the RelayerRegistry or Governance ever breaks, withdrawals keep working (see [Protocol fee details](#protocol-fee-details-3-and-30-eth)).
- **The premium rewards using registered relayers.** Paying 0.6% directly instead of 0.3% through a relayer makes relayers the cheaper option, which also protects privacy: withdrawing directly requires funding the withdrawing address with gas.
- **The DAO controls the fee, within limits.** Governance can change the fee and the premium on each pool, capped at 1% and 4%, so even a compromised Governance cannot drain deposits through the fee.
- **Minimal new code.** `FeeEnforcedTornado_eth` reuses the verified classic `Tornado` base unchanged; only `_processWithdraw` differs. The circuit and verifier are the same as the live pools. The 0.01, 0.03 and 0.3 ETH pools are bytecode-identical to the live 1 ETH pool.

The live 1, 10 and 100 ETH pools are already deployed and cannot be changed, so they keep the gap; this proposal only covers the pools it creates.

## How it works

### What the proposal does

`AddEthPoolsProposal.executeProposal()` is delegatecalled by Tornado Governance after the vote passes. For each denomination it:

1. Deploys a new pool (merkle height 20, `operator = address(0)`, the shared verifier, and the MiMC `Hasher` library at the same address as the live 1/10/100 ETH pools):
   - 0.01, 0.03, 0.3 ETH: classic `TornadoCash_eth`.
   - 3, 30 ETH: `FeeEnforcedTornado_eth` with `protocolFeePercentage = 30` and `directWithdrawPremiumPercentage = 30`.
2. Registers it as `ENABLED` in the [InstanceRegistry](https://etherscan.io/address/0xB20c66C4DE72433F3cE747b58B86830c459CA911) so the [Tornado Router](https://etherscan.io/address/0xd90e2f925DA726b50C4Ed8D0Fb90Ad053324F31b) can route deposits and withdrawals. The registry `protocolFeePercentage` is `30` (0.3%) for the 3 and 30 ETH pools and `0` for the rest.

Fees use the same scale as the live FeeManager: values are divided by `10000`, so `30` = 0.3%.

### How a withdrawal is charged (3 and 30 ETH pools)

- **Registered relayer through the Router:** the Router calls `burn`, which burns 0.3% (in TORN, at the Uniswap TWAP price) from the relayer's stake. The pool pays `denomination - relayerFee` to the user and `relayerFee` to the relayer.
- **Any other path:** the pool keeps `protocolFeePercentage + directWithdrawPremiumPercentage` (0.6%) of the denomination, sends it to Governance in the same transaction, and pays the rest to the user (minus any relayer fee).

Example with a 30 ETH note:

| Path | User receives | Relayer | DAO |
| --- | --- | --- | --- |
| Registered relayer charging X ETH | 30 − X ETH | X ETH, pays gas and ~0.09 ETH worth of TORN from its stake | ~0.09 ETH worth of TORN, distributed to TORN lockers |
| Direct withdrawal | 29.82 ETH, pays own gas | — | 0.18 ETH to Governance |

## Protocol fee details (3 and 30 ETH)

- "Registered" = `msg.sender == RelayerRegistry.tornadoRouter()` and `RelayerRegistry.workers(_relayer) == _relayer` and `_relayer != 0`. Together these force `burn` to require the Router's caller to be a worker of `_relayer` and to burn its stake.
- The ETH fee is `protocolFeePercentage` (30) + `directWithdrawPremiumPercentage` (30), both in basis points (divided by `PROTOCOL_FEE_DIVIDER` = 10000). Read them with `protocolFeePercentage()`, `directWithdrawPremiumPercentage()`, `directWithdrawFeePercentage()` (the sum, 60 = 0.6%) and `directWithdrawFee()` (amount in wei).
- Governance can change the fee with `setProtocolFeePercentage()`, up to the hard cap `MAX_PROTOCOL_FEE_PERCENTAGE` = 100 (1%), and the premium with `setDirectWithdrawPremiumPercentage()`, up to `MAX_DIRECT_WITHDRAW_PREMIUM_PERCENTAGE` = 400 (4%). The worst case is therefore 5% on direct withdrawals, so a compromised Governance cannot drain deposits through the fee. When changing the fee, also update the InstanceRegistry `protocolFeePercentage` so the TORN burned on relayer withdrawals stays in line. The registry address is fixed at deploy.
- The ETH fee is sent to Governance during the withdrawal with a gas-capped call (`FEE_TRANSFER_GAS` = 50k; Governance needs ~5.3k). If Governance cannot receive it (reverts, runs out of gas, broken upgrade), the withdrawal still succeeds and the fee accrues in the pool. Anyone can later send accrued fees to Governance with `sweepProtocolFees()`. The event `ProtocolFeeCharged(relayer, amount, paidToGovernance)` records which happened.
- The premium is independent of the fee: setting the fee to 0 still charges the premium. To make direct withdrawals free, set both to 0.
- Registry reads use `staticcall`: if the registry ever reverts, withdrawals still work and pay the ETH fee. Funds never depend on relayers or Governance to exit.
- `FeeEnforcedTornado_eth` reuses the verified classic `Tornado` base unchanged; only `_processWithdraw` differs. The circuit and verifier are unchanged.

## Using the ETH fees

Governance (`0x5efda50f22d34F262c29268506C5Fa42cB56A1Ce`) only receives the ETH: its `receive()` is empty and it has no logic to distribute it. The ETH stays there until a governance proposal moves it. Only TORN is distributed automatically: relayer stake burned on registered-relayer withdrawals goes to [TornadoStakingRewards](https://etherscan.io/address/0x5B3f656C80E8ddb9ec01Dd9018815576E9238c29) (`addBurnRewards`), and TORN lockers claim it with `getReward()`. TornadoStakingRewards does not handle ETH, so the fees must not be sent there directly.

The DAO can choose, and change its choice at any time by proposal, between:

1. **Distribute to TORN lockers.** A periodic proposal swaps the accumulated ETH for TORN (e.g. on Uniswap), transfers the TORN to TornadoStakingRewards and calls `addBurnRewards(amount)`. Governance is allowed to call it (`msg.sender == Governance || msg.sender == relayerRegistry`). The ETH then reaches lockers exactly like the relayer fee, pro rata to locked TORN. No code change is needed; each distribution needs a vote. The TORN must be transferred before `addBurnRewards`, which only updates the reward rate.
2. **Keep it as treasury.** Leave the ETH in Governance and spend it through proposals: grants for community contributors, security reviews and audits, relayer or infrastructure support, etc. This also needs no code change.

Both options can be combined, for example by distributing part of the fees and keeping the rest.

## Compiler (bytecode match)

The no-fee pools (0.01, 0.03, 0.3 ETH) are compiled like mainnet [1 ETH](https://etherscan.io/address/0x47CE0C6eD5B0Ce3d3A51fdb1C52DC66a7c3c2936) / 10 / 100:

| Setting | Value |
| --- | --- |
| Contract | `TornadoCash_eth` |
| solc | `0.5.11` (optimizer **200** runs, **petersburg**) |
| Hasher library | `0x83584f83f26aF4eDDA9CBe8C730bc87C364b28fe` |

The fork test asserts each no-fee pool’s **metadata-stripped** runtime bytecode equals the live 1 ETH pool (opcode-identical). Full `extcodehash` still differs by the solc CBOR trailer: mainnet was verified with emscripten `0.5.11+commit.c082d0b4`, while Foundry uses the native binary `0.5.11+commit.22be8592`. That gate is **test-only** (not in `executeProposal()`). The 3 and 30 ETH pools are new code (`FeeEnforcedTornado_eth`) and need their own review. The 0.1 ETH pool is a close sibling (`TornadoCash_Eth_01`) with a different codehash.

## Addresses

| Role | Address |
| --- | --- |
| Governance | `0x5efda50f22d34F262c29268506C5Fa42cB56A1Ce` |
| InstanceRegistry | `0xB20c66C4DE72433F3cE747b58B86830c459CA911` |
| TornadoRouter | `0xd90e2f925DA726b50C4Ed8D0Fb90Ad053324F31b` |
| Verifier | `0xce172ce1F20EC0B3728c9965470eaf994A03557A` |
| Hasher | `0x83584f83f26aF4eDDA9CBe8C730bc87C364b28fe` |
| RelayerRegistry | `0x58E8dCC13BE9780fC42E8723D8EaD4CF46943dF2` |
| Live 1 ETH (codehash ref) | `0x47CE0C6eD5B0Ce3d3A51fdb1C52DC66a7c3c2936` |

## Develop

```bash
forge install
forge build
ETH_RPC_URL=https://ethereum-rpc.publicnode.com forge test -vvv
```

The fork test spoofs a quorum-sized TORN holder (`deal`), runs the live governance cycle (`propose` → warp voting delay → `castVote` → warp voting period + execution delay → `execute`), asserts all five pools are `ENABLED` and opcode-match live 1 ETH, then deposits into each via the Tornado Router.

`test/FeeEnforcedTornado_eth.t.sol` executes the proposal the same way, mocks the SNARK verifier, and withdraws from the fee pools through every path: registered relayer via Router (TORN burned, no ETH fee), relayer without stake (reverts), unregistered sender naming a registered relayer (reverts), custom relayer via Router, `_relayer = 0`, direct call naming a registered relayer, direct self-withdraw, fees above denomination, a reverting registry, immediate fee payment to Governance, a reverting or gas-burning Governance (withdrawal still succeeds, fee accrues), the sweep of accrued fees, and fee changes (getters, a real governance proposal changing fee and premium, premium added to the fee, zero fee still charging the premium, both caps, non-governance callers). The registered-relayer cases use the live relayer `0x4750…29C5`.

## Governance submission

1. Deploy `AddEthPoolsProposal` (no constructor args)
2. Verify source on Etherscan
3. Call `Governance.propose(proposalAddress, "Add 0.01, 0.03, 0.3, 3, and 30 ETH Tornado Cash anonymity pools")` with ≥ proposal threshold locked TORN
4. After voting + timelock, anyone can `execute(proposalId)`

## Layout

```
src/AddEthPoolsProposal.sol   # proposal (solc 0.5.11)
src/FeeEnforcedTornado_eth.sol    # fee-enforcing pool for 3/30 ETH
src/classic/TornadoCash_eth.sol  # verified classic mixer template
src/interfaces/               # InstanceRegistry ABI
test/AddEthPoolsProposal.t.sol
test/FeeEnforcedTornado_eth.t.sol
test/utils/ProposalFixture.sol  # shared fork + governance execution
```
