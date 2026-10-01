// SPDX-License-Identifier: MIT
pragma solidity ^0.5.8;
pragma experimental ABIEncoderV2;

import "./FeeEnforcedTornado_eth.sol";
import "./interfaces/IInstanceRegistry.sol";

/**
 * @notice Tornado Cash governance proposal: deploy 0.01, 0.03, 0.3, 3, and 30 ETH
 *         anonymity pools and register them with the InstanceRegistry (Router reads it).
 * @dev Governance.execute() delegatecalls `executeProposal()`. No proposal storage —
 *      constants only. Pools are `FeeEnforcedTornado_eth`, compiled with solc 0.5.11 and the
 *      Hasher linked to the shared MiMC library. Operator is address(0).
 *      Each pool has two fees:
 *      - protocol fee: paid on every withdrawal. Registered relayers pay it as burned TORN
 *        stake (the same value is set as the registry `protocolFeePercentage`); every other
 *        withdrawal pays it in ETH.
 *      - premium: paid in ETH on top of the protocol fee by withdrawals that do not use a
 *        registered relayer.
 *      0.01, 0.03, 0.3 ETH: protocol fee 0, premium 0.3%.
 *      3, 30 ETH: protocol fee 0.3%, premium 0.3%.
 */
contract AddEthPoolsProposal {
    address public constant INSTANCE_REGISTRY = 0xB20c66C4DE72433F3cE747b58B86830c459CA911;
    address public constant VERIFIER = 0xce172ce1F20EC0B3728c9965470eaf994A03557A;
    uint32 public constant MERKLE_TREE_HEIGHT = 20;
    uint32 public constant PROTOCOL_FEE_PERCENTAGE = 30;
    uint32 public constant DIRECT_WITHDRAW_PREMIUM_PERCENTAGE = 30;

    event PoolAdded(address indexed instance, uint256 denomination);

    function executeProposal() external {
        _add(0.01 ether, 0, DIRECT_WITHDRAW_PREMIUM_PERCENTAGE);
        _add(0.03 ether, 0, DIRECT_WITHDRAW_PREMIUM_PERCENTAGE);
        _add(0.3 ether, 0, DIRECT_WITHDRAW_PREMIUM_PERCENTAGE);
        _add(3 ether, PROTOCOL_FEE_PERCENTAGE, DIRECT_WITHDRAW_PREMIUM_PERCENTAGE);
        _add(30 ether, PROTOCOL_FEE_PERCENTAGE, DIRECT_WITHDRAW_PREMIUM_PERCENTAGE);
    }

    function _add(uint256 denomination, uint32 protocolFeePercentage, uint32 premiumPercentage) internal {
        address instance = address(
            new FeeEnforcedTornado_eth(
                IVerifier(VERIFIER),
                denomination,
                MERKLE_TREE_HEIGHT,
                address(0),
                protocolFeePercentage,
                premiumPercentage
            )
        );

        IInstanceRegistry.Instance memory cfg = IInstanceRegistry.Instance({
            isERC20: false,
            token: IERC20Minimal(address(0)),
            state: IInstanceRegistry.InstanceState.ENABLED,
            uniswapPoolSwappingFee: 0,
            protocolFeePercentage: protocolFeePercentage
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
