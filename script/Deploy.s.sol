// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";

/**
 * @notice Deploys the only thing that has to exist before the vote: the proposal,
 *         `AddEthPoolsProposal`, which is the contract to pass to Governance.propose.
 *
 *         The 0.01 ETH pool is NOT deployed here. The proposal deploys it when Governance executes it.
 *
 *         forge script script/Deploy.s.sol --rpc-url $ETH_RPC_URL --broadcast
 */
contract Deploy is Script {
    function run() external returns (address proposal) {
        vm.startBroadcast();
        proposal = deploy();
        vm.stopBroadcast();

        console.log("AddEthPoolsProposal", proposal);
    }

    function deploy() public returns (address proposal) {
        proposal = deployCode("AddEthPoolsProposal.sol:AddEthPoolsProposal");
    }
}
