// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/**
 * @dev Test helper, used by the end-to-end walkthrough (e2e/src/phase1.js) on a mainnet fork: a
 *      Governance proposal that changes the fees of one fee-enforced pool the complete way, so that
 *      both withdrawal paths follow the new protocol fee:
 *      - the pool's `protocolFeePercentage` and `directWithdrawPremiumPercentage` (the ETH fee);
 *      - the InstanceRegistry's `protocolFeePercentage` for the pool (the TORN burned on relayer
 *        withdrawals), re-registering the instance unchanged otherwise;
 *      - the FeeManager's cached TORN fee for the pool.
 *      Governance delegatecalls `executeProposal()`, so everything it needs is in immutables.
 *      It is not part of the proposal under review and is not meant for mainnet as is.
 */
interface IFeeEnforcedPool {
    function setProtocolFeePercentage(uint256 protocolFeePercentage) external;
    function setDirectWithdrawPremiumPercentage(uint256 premiumPercentage) external;
}

interface IInstanceRegistryFees {
    struct Instance {
        bool isERC20;
        address token;
        uint8 state;
        uint24 uniswapPoolSwappingFee;
        uint32 protocolFeePercentage;
    }

    struct Tornado {
        address addr;
        Instance instance;
    }

    function instances(address instance)
        external
        view
        returns (bool isERC20, address token, uint8 state, uint24 uniswapPoolSwappingFee, uint32 protocolFeePercentage);

    function updateInstance(Tornado calldata tornado) external;
}

interface IFeeManagerFees {
    function updateFee(address instance) external;
}

contract FeeChangeProposal {
    address public constant INSTANCE_REGISTRY = 0xB20c66C4DE72433F3cE747b58B86830c459CA911;
    address public constant FEE_MANAGER = 0x5f6c97C6AD7bdd0AE7E0Dd4ca33A4ED3fDabD4D7;

    address public immutable pool;
    uint256 public immutable protocolFeePercentage;
    uint256 public immutable premiumPercentage;

    constructor(address _pool, uint256 _protocolFeePercentage, uint256 _premiumPercentage) {
        pool = _pool;
        protocolFeePercentage = _protocolFeePercentage;
        premiumPercentage = _premiumPercentage;
    }

    function executeProposal() external {
        IFeeEnforcedPool(pool).setProtocolFeePercentage(protocolFeePercentage);
        IFeeEnforcedPool(pool).setDirectWithdrawPremiumPercentage(premiumPercentage);

        (bool isERC20, address token, uint8 state, uint24 uniswapPoolSwappingFee,) =
            IInstanceRegistryFees(INSTANCE_REGISTRY).instances(pool);
        IInstanceRegistryFees(INSTANCE_REGISTRY).updateInstance(
            IInstanceRegistryFees.Tornado({
                addr: pool,
                instance: IInstanceRegistryFees.Instance({
                    isERC20: isERC20,
                    token: token,
                    state: state,
                    uniswapPoolSwappingFee: uniswapPoolSwappingFee,
                    protocolFeePercentage: uint32(protocolFeePercentage)
                })
            })
        );
        IFeeManagerFees(FEE_MANAGER).updateFee(pool);
    }
}
