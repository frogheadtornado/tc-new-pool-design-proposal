// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ProposalFixture, IFeeEnforcedTornado, IProposal, IStakingProxy} from "./utils/ProposalFixture.sol";

interface IVerifier {
    function verifyProof(bytes memory proof, uint256[6] memory input) external returns (bool);
}

interface IStakingRewards {
    function ratioConstant() external view returns (uint256);
    function accumulatedRewardPerTorn() external view returns (uint256);
    function checkReward(address account) external view returns (uint256);
    function addEthRewards() external payable;
    function checkEthReward(address account) external view returns (uint256);
    function getEthReward() external;
    function getRewardTokens() external view returns (address[] memory);
}

/**
 * @dev Mainnet-fork E2E for the second proposal, `StakingUpgradeProposal`: the one that upgrades
 *      TornadoStakingRewards, to be voted after the pool proposal. Same governance cycle as the other
 *      suite. Execution deploys the new implementation and upgrades the staking proxy to it.
 */
contract StakingUpgradeProposalTest is ProposalFixture {
    /// @dev EIP-7825: a mainnet transaction cannot use more gas than this.
    uint256 private constant _TRANSACTION_GAS_CAP = 16_777_216;
    /// @dev EIP-1967 implementation slot of the staking proxy.
    bytes32 private constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    address private constant _LIVE_STAKING_IMPLEMENTATION = 0x9c97be37840f0e754bb7aDB1b16fD0954A2BA248;
    string private constant _STAKING_DESCRIPTION = "Upgrade TornadoStakingRewards to share ETH fees among TORN lockers";

    IStakingRewards private constant _staking = IStakingRewards(_STAKING);

    address private _stakingProposal;

    function setUp() external {
        _fork();
        _stakingProposal = deployCode("StakingUpgradeProposal.sol:StakingUpgradeProposal");
    }

    function testProposalDeploysTheImplementationAndUpgradesToIt() external {
        address expected = _nextContractOfGovernance();
        assertEq(expected.code.length, 0, "the new implementation does not exist before the proposal is executed");
        assertEq(_implementationOf(_STAKING), _LIVE_STAKING_IMPLEMENTATION, "staking runs the live code");
        uint256 ratioBefore = _staking.ratioConstant();
        uint256 indexBefore = _staking.accumulatedRewardPerTorn();

        _passAndExecute(_stakingProposal, _STAKING_DESCRIPTION);

        assertEq(_implementationOf(_STAKING), expected, "upgraded to the contract Governance created");
        // The same code, built with the same values, as a reference deployment made by this test.
        address sameCode = deployCode(
            "TornadoStakingRewards.sol:TornadoStakingRewards",
            abi.encode(_GOVERNANCE, _TORN, _RELAYER_REGISTRY, _STAKING_RATIO_CONSTANT)
        );
        assertEq(keccak256(expected.code), keccak256(sameCode.code), "it is the compiled TornadoStakingRewards");
        assertEq(_staking.ratioConstant(), ratioBefore, "reward scale");
        assertEq(_staking.accumulatedRewardPerTorn(), indexBefore, "TORN reward index");

        // ETH rewards are live: the quorum-sized voter of the fixture is a locker.
        address payer = makeAddr("payer");
        deal(payer, 1 ether);
        vm.prank(payer);
        _staking.addEthRewards{value: 1 ether}();
        assertGt(_staking.checkEthReward(makeAddr("voter")), 0, "lockers earn ETH");

        // Rewards in tokens are possible from now on, but the proposal adds no token.
        assertEq(_staking.getRewardTokens().length, 0, "no reward token");
    }

    function testFeesKeptByThePoolReachTheLockersAfterBothProposals() external {
        // The whole path, each step through Governance: the pool proposal, a withdrawal whose fee the
        // pool has to keep, the staking proposal, and the sweep that pays the lockers.
        _deployProposal();
        _passAndExecuteProposal();
        IFeeEnforcedTornado pool = _pool001;
        vm.mockCall(_VERIFIER, abi.encodeWithSelector(IVerifier.verifyProof.selector), abi.encode(true));
        // A label of its own: the accounts behind forge's usual labels carry code on mainnet.
        address user = makeAddr("tornado-staking-upgrade-test/user");
        assertEq(user.code.length, 0, "test account has code on mainnet");
        deal(user, _DENOM_001);
        vm.startPrank(user);
        pool.deposit{value: _DENOM_001}(bytes32(uint256(0xc0ffee)));
        pool.withdraw(
            "", pool.getLastRoot(), bytes32(uint256(0xabc123)), payable(user), payable(address(0)), 0, 0.00006 ether
        );
        vm.stopPrank();
        assertEq(pool.accruedProtocolFees(), 0.00006 ether, "fee kept by the pool");

        _passAndExecute(_stakingProposal, _STAKING_DESCRIPTION);
        pool.sweepProtocolFees();

        assertEq(pool.accruedProtocolFees(), 0, "nothing left in the pool");
        assertEq(_STAKING.balance, 0.00006 ether, "the staking contract holds the fee");
        address voter = makeAddr("voter");
        uint256 reward = _staking.checkEthReward(voter);
        assertGt(reward, 0, "credited to the lockers");
        vm.prank(voter);
        _staking.getEthReward();
        assertEq(voter.balance, reward, "and claimable");
    }

    function testProposalCalledDirectlyChangesNothing() external {
        // Only Governance, the admin of the staking proxy, can upgrade it.
        vm.expectRevert();
        IProposal(_stakingProposal).executeProposal();

        assertEq(_implementationOf(_STAKING), _LIVE_STAKING_IMPLEMENTATION, "staking still runs the live code");
    }

    function testExecutionFailsIfStakingWasUpgradedInBetween() external {
        // The new implementation extends the storage of the one live today. If another proposal
        // replaces that one first, this proposal must not upgrade on top of it.
        address other = _upgradeStaking();
        uint256 proposalId = _pass(_stakingProposal, _STAKING_DESCRIPTION);

        try _gov.execute(proposalId) {
            fail("execution succeeded");
        } catch Error(string memory message) {
            assertTrue(vm.contains(message, "Unexpected staking implementation"), "unexpected revert reason");
        }
        assertEq(_gov.state(proposalId), _STATE_AWAITING_EXECUTION, "not executed");
        assertEq(_implementationOf(_STAKING), other, "staking left as it was");
    }

    function testExecutionFitsInOneTransaction() external {
        uint256 proposalId = _pass(_stakingProposal, _STAKING_DESCRIPTION);

        uint256 gasBefore = gasleft();
        _gov.execute(proposalId);
        uint256 gasUsed = gasBefore - gasleft();

        assertEq(_gov.state(proposalId), _STATE_EXECUTED);
        assertLt(gasUsed, _TRANSACTION_GAS_CAP, "execution must fit under the per-transaction gas cap");
    }

    function _implementationOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, _IMPLEMENTATION_SLOT))));
    }
}
