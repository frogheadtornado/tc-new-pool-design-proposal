// SPDX-License-Identifier: MIT
pragma solidity ^0.5.8;
pragma experimental ABIEncoderV2;

import "./FeeEnforcedTornado_eth.sol";
import "./interfaces/IInstanceRegistry.sol";

/**
 * @notice Tornado Cash governance proposal: deploy 0.01, 0.03, 0.3, 3, and 30 ETH
 *         anonymity pools and register them with the InstanceRegistry (Router reads it).
 * @dev Governance.execute() delegatecalls `executeProposal()`. No proposal storage —
 *      constants only. Pools are compiled with solc 0.5.11 and the Hasher linked to the
 *      shared MiMC library. Operator is address(0).
 *      All pools are `FeeEnforcedTornado_eth`:
 *      - 0.01, 0.03, 0.3 ETH: registered relayers pay nothing (registry fee 0); every other
 *        withdrawal pays the protocol fee in ETH, with no premium.
 *      - 3, 30 ETH: `FeeEnforcedTornado_eth`. Registered relayers pay the protocol fee as
 *        burned TORN stake (registry `protocolFeePercentage`); every other withdrawal pays the
 *        protocol fee plus a premium in ETH.
 */
contract AddEthPoolsProposal {
    address public constant INSTANCE_REGISTRY = 0xB20c66C4DE72433F3cE747b58B86830c459CA911;
    address public constant VERIFIER = 0xce172ce1F20EC0B3728c9965470eaf994A03557A;
    uint32 public constant MERKLE_TREE_HEIGHT = 20;
    uint32 public constant PROTOCOL_FEE_PERCENTAGE = 30;
    uint32 public constant DIRECT_WITHDRAW_PREMIUM_PERCENTAGE = 30;

    event PoolAdded(address indexed instance, uint256 denomination);

    function executeProposal() external {
        _addFeeEnforced(0.01 ether, 0, 0);
        _addFeeEnforced(0.03 ether, 0, 0);
        _addFeeEnforced(0.3 ether, 0, 0);
        _addFeeEnforced(3 ether, PROTOCOL_FEE_PERCENTAGE, DIRECT_WITHDRAW_PREMIUM_PERCENTAGE);
        _addFeeEnforced(30 ether, PROTOCOL_FEE_PERCENTAGE, DIRECT_WITHDRAW_PREMIUM_PERCENTAGE);
    }

    /**
     * @param relayerFeePercentage registry `protocolFeePercentage`: TORN burned on registered-relayer withdrawals.
     * @param premiumPercentage added to `PROTOCOL_FEE_PERCENTAGE` on every other withdrawal.
     */
    function _addFeeEnforced(uint256 denomination, uint32 relayerFeePercentage, uint32 premiumPercentage) internal {
        address instance = address(
            new FeeEnforcedTornado_eth(
                IVerifier(VERIFIER),
                denomination,
                MERKLE_TREE_HEIGHT,
                address(0),
                PROTOCOL_FEE_PERCENTAGE,
                premiumPercentage
            )
        );
        _register(instance, denomination, relayerFeePercentage);
    }

    function _register(address instance, uint256 denomination, uint32 relayerFeePercentage) internal {
        IInstanceRegistry.Instance memory cfg = IInstanceRegistry.Instance({
            isERC20: false,
            token: IERC20Minimal(address(0)),
            state: IInstanceRegistry.InstanceState.ENABLED,
            uniswapPoolSwappingFee: 0,
            protocolFeePercentage: relayerFeePercentage
        });

        IInstanceRegistry(INSTANCE_REGISTRY)
            .updateInstance(IInstanceRegistry.Tornado({addr: ITornadoInstance(instance), instance: cfg}));

        assert(ITornadoInstance(instance).denomination() == denomination);

        (,, IInstanceRegistry.InstanceState state,,) =
            IInstanceRegistry(INSTANCE_REGISTRY).instances(ITornadoInstance(instance));
        assert(state == IInstanceRegistry.InstanceState.ENABLED);

        emit PoolAdded(instance, denomination);
    }
}
