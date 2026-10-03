// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ProposalFixture, IInstanceRegistry, IFeeEnforcedTornado, IProposal} from "./utils/ProposalFixture.sol";
import {Deploy} from "../script/Deploy.s.sol";

/**
 * @dev Mainnet-fork E2E. The proposal, a single contract, is deployed first, as it would be before a
 *      real vote. Then a spoofed large TORN holder runs propose → vote → execute with time warps
 *      matching live governance delays. Execution deploys the 0.01 ETH pool and registers it.
 */
contract AddEthPoolsProposalTest is ProposalFixture {
    /// @dev EIP-7825: a mainnet transaction cannot use more gas than this.
    uint256 private constant _TRANSACTION_GAS_CAP = 16_777_216;
    /// @dev EIP-1967 implementation slot of the staking proxy.
    bytes32 private constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function setUp() external {
        _forkAndDeployProposal();
    }

    function testProposalDeploysAndRegistersThePool() external {
        uint256 instancesBefore = _registry.getAllInstanceAddresses().length;
        address expected = _nextContractOfGovernance();
        assertEq(expected.code.length, 0, "the pool does not exist before the proposal is executed");

        _passAndExecuteProposal();

        assertEq(address(_pool001), expected, "the pool is the contract Governance created");
        assertEq(
            keccak256(address(_pool001).code),
            keccak256(vm.getDeployedCode("FeeEnforcedTornado_eth.sol:FeeEnforcedTornado_eth")),
            "the deployed pool is the compiled FeeEnforcedTornado_eth"
        );
        assertEq(_registry.getAllInstanceAddresses().length, instancesBefore + 1, "one new instance");

        // Registered relayers pay 0.3% in TORN; any other withdrawal pays 0.3% + 0.3% in ETH.
        _assertPool(_pool001, _DENOM_001);

        _depositViaRouter(makeAddr("depositor"), address(_pool001), _DENOM_001, "c-0.01");
    }

    function testProposalDoesNotTouchTheStakingContract() external {
        // The staking contract is upgraded by a later proposal. This one leaves it as it is.
        bytes32 implementationBefore = vm.load(_STAKING, _IMPLEMENTATION_SLOT);
        bytes32 codeBefore = keccak256(_STAKING.code);

        _passAndExecuteProposal();

        assertEq(vm.load(_STAKING, _IMPLEMENTATION_SLOT), implementationBefore, "staking implementation");
        assertEq(keccak256(_STAKING.code), codeBefore, "staking proxy");
    }

    function testProposalCalledDirectlyAddsNothing() external {
        // The proposal is meant to be delegatecalled by Governance. Called directly it reverts: only
        // Governance can register a pool.
        uint256 instancesBefore = _registry.getAllInstanceAddresses().length;

        vm.expectRevert();
        IProposal(_proposal).executeProposal();

        assertEq(_registry.getAllInstanceAddresses().length, instancesBefore, "nothing registered");
    }

    function testDeployScriptDeploysOnlyTheProposal() external {
        // A fresh fork with nothing deployed: the script alone must leave the proposal executable, and
        // the proposal must be the one contract it deploys.
        _fork();
        uint256 instancesBefore = _registry.getAllInstanceAddresses().length;
        Deploy script = new Deploy();
        uint256 createdBefore = vm.getNonce(address(script));

        address deployed = script.deploy();
        assertEq(vm.getNonce(address(script)), createdBefore + 1, "the script deploys one contract");
        assertGt(deployed.code.length, 0, "the proposal");
        assertEq(_registry.getAllInstanceAddresses().length, instancesBefore, "no pool yet");

        address pool = _nextContractOfGovernance();
        _passAndExecute(deployed, _DESCRIPTION);
        address[] memory all = _registry.getAllInstanceAddresses();
        assertEq(all.length, instancesBefore + 1, "one new instance");
        assertEq(all[instancesBefore], pool, "the pool, deployed by the proposal");
        _assertPool(IFeeEnforcedTornado(pool), _DENOM_001);
    }

    function testExecutionFitsInOneTransaction() external {
        uint256 proposalId = _pass(_proposal, _DESCRIPTION);

        uint256 gasBefore = gasleft();
        _gov.execute(proposalId);
        uint256 gasUsed = gasBefore - gasleft();

        assertEq(_gov.state(proposalId), _STATE_EXECUTED);
        assertLt(gasUsed, _TRANSACTION_GAS_CAP, "execution must fit under the per-transaction gas cap");
    }

    function _assertPool(IFeeEnforcedTornado feePool, uint256 denomination) internal view {
        assertEq(feePool.denomination(), denomination);
        assertEq(feePool.verifier(), _VERIFIER, "verifier");
        assertEq(feePool.levels(), uint32(20), "levels");
        assertEq(feePool.operator(), address(0), "operator");

        (bool isERC20, address token, IInstanceRegistry.InstanceState state, uint24 uniswapFee, uint32 protocolFee) =
            _registry.instances(address(feePool));
        assertFalse(isERC20);
        assertEq(token, address(0));
        assertTrue(state == IInstanceRegistry.InstanceState.ENABLED);
        assertEq(uniswapFee, uint24(0));
        assertEq(protocolFee, 30, "registry fee: 0.3% in TORN on registered-relayer withdrawals");

        assertEq(feePool.protocolFeePercentage(), 30, "pool protocol fee == registry fee");
        assertEq(feePool.directWithdrawPremiumPercentage(), 30, "0.3% premium");
        assertEq(feePool.directWithdrawFeePercentage(), 60, "0.6% without a registered relayer");
        assertEq(feePool.accruedProtocolFees(), 0, "accrued fees");
        assertEq(feePool.RELAYER_REGISTRY(), _RELAYER_REGISTRY, "relayer registry");
        assertEq(feePool.GOVERNANCE(), _GOVERNANCE, "fee admin");
        assertEq(feePool.STAKING_REWARDS(), _STAKING, "fee recipient");
    }
}
