// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import { TornadoStakingRewards } from "./TornadoStakingRewards.sol";

/// @dev The staking proxy's own functions. Only its admin, Governance, can call them.
interface IStakingRewardsProxy {
    function implementation() external returns (address);

    function upgradeTo(address newImplementation) external;
}

/**
 * @notice Tornado Cash governance proposal, to be voted after the one that adds the 0.01 ETH pool:
 *         upgrade TornadoStakingRewards so that it can share among TORN lockers the fees that the new
 *         pools pay in ETH (and, later, in tokens added by Governance).
 * @dev Governance.execute() delegatecalls `executeProposal()`. No proposal storage — constants only.
 *      The new implementation is deployed here, when the proposal is executed: it does not exist
 *      before. It is built with the values of the implementation it replaces, read from the live
 *      contract: the scale of the TORN rewards already accumulated (`ratioConstant`) must not change,
 *      and a wrong address would break relayer burns.
 */
contract StakingUpgradeProposal {
    address public constant STAKING_REWARDS = 0x5B3f656C80E8ddb9ec01Dd9018815576E9238c29;
    // The implementation the new one was derived from. Its storage layout is the one extended.
    address public constant LIVE_STAKING_IMPLEMENTATION = 0x9c97be37840f0e754bb7aDB1b16fD0954A2BA248;

    function executeProposal() external {
        IStakingRewardsProxy proxy = IStakingRewardsProxy(STAKING_REWARDS);
        require(proxy.implementation() == LIVE_STAKING_IMPLEMENTATION, "Unexpected staking implementation");

        TornadoStakingRewards live = TornadoStakingRewards(STAKING_REWARDS);
        TornadoStakingRewards implementation = new TornadoStakingRewards(
            address(live.Governance()),
            address(live.torn()),
            live.relayerRegistry(),
            live.ratioConstant()
        );

        proxy.upgradeTo(address(implementation));
    }
}
