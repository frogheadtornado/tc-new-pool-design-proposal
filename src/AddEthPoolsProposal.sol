// SPDX-License-Identifier: MIT
pragma solidity ^0.5.8;
pragma experimental ABIEncoderV2;

import "./FeeEnforcedTornado_eth.sol";
import "./interfaces/IFeeManager.sol";
import "./interfaces/IInstanceRegistry.sol";

/**
 * @notice Tornado Cash governance proposal: deploy a 0.01 ETH anonymity pool with the DAO fee
 *         enforced inside the pool, and register it with the InstanceRegistry (Router reads it).
 *         Other denominations follow in a later proposal.
 * @dev Governance.execute() delegatecalls `executeProposal()`. No proposal storage —
 *      constants only. The pool is `FeeEnforcedTornado_eth`, compiled with solc 0.5.11 and the
 *      Hasher linked to the shared MiMC library. Operator is address(0). It is deployed here, when
 *      the proposal is executed: it does not exist before.
 *      The pool has two fees:
 *      - protocol fee: paid on every withdrawal. Registered relayers pay it as burned TORN
 *        stake (the same value is set as the registry `protocolFeePercentage`); every other
 *        withdrawal pays it in ETH.
 *      - premium: paid in ETH on top of the protocol fee by withdrawals that do not use a
 *        registered relayer.
 *      It starts with protocol fee 0.3% and premium 0.3%. They are initial values. Governance can
 *      change both afterwards (`setProtocolFeePercentage`, `setDirectWithdrawPremiumPercentage`),
 *      and the TORN side through the InstanceRegistry.
 *      The ETH fees are for the TORN lockers. The staking contract cannot take ETH until a later
 *      proposal upgrades it; until then the pool keeps them, and anyone can forward them afterwards
 *      with `sweepProtocolFees()`. This proposal does not touch the staking contract.
 */
contract AddEthPoolsProposal {
    address public constant INSTANCE_REGISTRY = 0xB20c66C4DE72433F3cE747b58B86830c459CA911;
    address public constant FEE_MANAGER = 0x5f6c97C6AD7bdd0AE7E0Dd4ca33A4ED3fDabD4D7;
    address public constant VERIFIER = 0xce172ce1F20EC0B3728c9965470eaf994A03557A;
    uint32 public constant MERKLE_TREE_HEIGHT = 20;
    uint256 public constant DENOMINATION = 0.01 ether;
    // Initial fees of the pool, divided by 10000: 30 = 0.3%.
    uint32 public constant PROTOCOL_FEE_PERCENTAGE = 30;
    uint32 public constant DIRECT_WITHDRAW_PREMIUM_PERCENTAGE = 30;

    event PoolAdded(address indexed instance, uint256 denomination);

    function executeProposal() external {
        address instance = address(
            new FeeEnforcedTornado_eth(
                IVerifier(VERIFIER),
                DENOMINATION,
                MERKLE_TREE_HEIGHT,
                address(0),
                PROTOCOL_FEE_PERCENTAGE,
                DIRECT_WITHDRAW_PREMIUM_PERCENTAGE
            )
        );

        IInstanceRegistry.Instance memory cfg = IInstanceRegistry.Instance({
            isERC20: false,
            token: IERC20Minimal(address(0)),
            state: IInstanceRegistry.InstanceState.ENABLED,
            uniswapPoolSwappingFee: 0,
            protocolFeePercentage: PROTOCOL_FEE_PERCENTAGE
        });

        IInstanceRegistry(INSTANCE_REGISTRY)
            .updateInstance(IInstanceRegistry.Tornado({addr: ITornadoInstance(instance), instance: cfg}));

        (,, IInstanceRegistry.InstanceState state,,) =
            IInstanceRegistry(INSTANCE_REGISTRY).instances(ITornadoInstance(instance));
        require(state == IInstanceRegistry.InstanceState.ENABLED, "Pool not registered");

        // The FeeManager caches each pool's TORN fee, and anyone can make it cache 0 for a pool that
        // is not registered yet. Refresh it now that the pool has its protocol fee.
        IFeeManager(FEE_MANAGER).updateFee(ITornadoInstance(instance));

        emit PoolAdded(instance, DENOMINATION);
    }
}
