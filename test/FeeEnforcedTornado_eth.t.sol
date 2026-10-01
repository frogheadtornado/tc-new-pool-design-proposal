// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ProposalFixture, IRelayerRegistry, ITornadoInstance, IFeeEnforcedTornado} from "./utils/ProposalFixture.sol";

interface IVerifier {
    function verifyProof(bytes memory proof, uint256[6] memory input) external returns (bool);
}

/// @dev Governance proposal (delegatecalled by Governance) that changes a fee pool's fee and premium.
contract SetFeesProposal {
    IFeeEnforcedTornado public immutable pool;
    uint256 public immutable feePercentage;
    uint256 public immutable premiumPercentage;

    constructor(IFeeEnforcedTornado _pool, uint256 _feePercentage, uint256 _premiumPercentage) {
        pool = _pool;
        feePercentage = _feePercentage;
        premiumPercentage = _premiumPercentage;
    }

    function executeProposal() external {
        pool.setProtocolFeePercentage(feePercentage);
        pool.setDirectWithdrawPremiumPercentage(premiumPercentage);
    }
}

/**
 * @dev Mainnet-fork tests for the protocol fee on the 3 and 30 ETH pools, after executing the
 *      proposal through live governance. The SNARK verifier is mocked to accept any proof;
 *      Router, RelayerRegistry.burn, FeeManager and Governance are the live contracts.
 *
 *      Fee rules under test (3 and 30 ETH pools; 0.01, 0.03 and 0.3 ETH are covered separately):
 *        - Router + registered relayer master → TORN stake burned, no ETH fee.
 *        - Anything else → 0.3% fee + 0.3% premium = 0.6% of the denomination paid in ETH to Governance in the
 *          same transaction, or accrued in the pool (sweepable) if Governance cannot receive it.
 */
contract FeeEnforcedTornadoEthTest is ProposalFixture {
    /// @dev Live registered relayer master (workers[master] == master) with ample stake.
    address private constant _RELAYER_MASTER = 0x4750BCfcC340AA4B31be7e71fa072716d28c29C5;
    uint256 private constant _RELAYER_FEE = 0.01 ether;
    /// @dev PUSH1 0 PUSH1 0 REVERT: a receiver that always reverts.
    bytes private constant _REVERTING_CODE = hex"60006000fd";
    /// @dev JUMPDEST PUSH1 0 JUMP: a receiver that loops until it runs out of gas.
    bytes private constant _GAS_BURNING_CODE = hex"5b600056";

    event ProtocolFeeCharged(address indexed relayer, uint256 amount, bool paidToGovernance);

    IFeeEnforcedTornado private _pool3;
    IFeeEnforcedTornado private _pool30;
    IFeeEnforcedTornado private _pool001;
    IFeeEnforcedTornado private _pool003;
    IFeeEnforcedTornado private _pool03;

    address private _worker;
    address private _recipient;
    address private _depositor;
    uint256 private _noteCount;
    uint256 private _govBalanceBefore;
    bytes private _govCode;

    function setUp() external {
        _forkAndDeployProposal();
        uint256 before = _passAndExecuteProposal();
        address[] memory all = _registry.getAllInstanceAddresses();
        _pool3 = IFeeEnforcedTornado(_findNewPool(all, before, _DENOM_3));
        _pool30 = IFeeEnforcedTornado(_findNewPool(all, before, _DENOM_30));
        _pool03 = IFeeEnforcedTornado(_findNewPool(all, before, _DENOM_03));
        _pool001 = IFeeEnforcedTornado(_findNewPool(all, before, _DENOM_001));
        _pool003 = IFeeEnforcedTornado(_findNewPool(all, before, _DENOM_003));

        vm.mockCall(_VERIFIER, abi.encodeWithSelector(IVerifier.verifyProof.selector), abi.encode(true));

        assertEq(_relayerRegistry.workers(_RELAYER_MASTER), _RELAYER_MASTER, "fixture relayer not registered");
        assertGt(_relayerRegistry.getRelayerBalance(_RELAYER_MASTER), 0, "fixture relayer has no stake");

        _worker = makeAddr("worker");
        vm.prank(_RELAYER_MASTER);
        _relayerRegistry.registerWorker(_RELAYER_MASTER, _worker);

        _recipient = makeAddr("recipient");
        _depositor = makeAddr("depositor");
        _govBalanceBefore = _GOVERNANCE.balance;
        _govCode = _GOVERNANCE.code;
    }

    // --- Registered relayer through the Router: fee paid in TORN only ---

    function testRegisteredRelayerViaRouterPaysTornNotEth() external {
        _assertRegisteredRelayerPaysTorn(_pool3);
    }

    function testRegisteredRelayerViaRouterPaysTornNotEth30() external {
        _assertRegisteredRelayerPaysTorn(_pool30);
    }

    function testRegisteredRelayerWithoutStakeReverts() external {
        vm.prank(_GOVERNANCE);
        _relayerRegistry.nullifyBalance(_RELAYER_MASTER);

        (bytes32 root, bytes32 nullifier) = _deposit(_pool3);
        vm.prank(_worker);
        vm.expectRevert(bytes("SafeMath: subtraction overflow"));
        _router.withdraw(
            address(_pool3), "", root, nullifier, payable(_recipient), payable(_RELAYER_MASTER), _RELAYER_FEE, 0
        );
    }

    function testUnregisteredSenderNamingRegisteredRelayerViaRouterReverts() external {
        (bytes32 root, bytes32 nullifier) = _deposit(_pool3);
        vm.prank(makeAddr("impostor"));
        vm.expectRevert(bytes("Only custom relayer"));
        _router.withdraw(
            address(_pool3), "", root, nullifier, payable(_recipient), payable(_RELAYER_MASTER), _RELAYER_FEE, 0
        );
    }

    // --- Every other path pays the direct-withdrawal fee in ETH ---

    function testCustomRelayerViaRouterPaysEthFee() external {
        address customRelayer = makeAddr("customRelayer");
        (bytes32 root, bytes32 nullifier) = _deposit(_pool3);

        uint256 stakeBefore = _relayerRegistry.getRelayerBalance(_RELAYER_MASTER);
        vm.prank(customRelayer);
        _router.withdraw(
            address(_pool3), "", root, nullifier, payable(_recipient), payable(customRelayer), _RELAYER_FEE, 0
        );

        _assertEthFeeCharged(_pool3, customRelayer, _RELAYER_FEE);
        assertEq(_relayerRegistry.getRelayerBalance(_RELAYER_MASTER), stakeBefore, "no stake burned");
    }

    function testZeroRelayerViaRouterPaysEthFee() external {
        // burn() lets an unregistered caller through without burning when _relayer == 0.
        (bytes32 root, bytes32 nullifier) = _deposit(_pool3);
        vm.prank(_recipient);
        _router.withdraw(address(_pool3), "", root, nullifier, payable(_recipient), payable(address(0)), 0, 0);

        _assertEthFeeCharged(_pool3, address(0), 0);
    }

    function testDirectCallNamingRegisteredRelayerPaysEthFee() external {
        // A registered worker skipping the Router burns no stake, so it must pay the ETH fee.
        (bytes32 root, bytes32 nullifier) = _deposit(_pool3);

        uint256 stakeBefore = _relayerRegistry.getRelayerBalance(_RELAYER_MASTER);
        vm.prank(_worker);
        _pool3.withdraw("", root, nullifier, payable(_recipient), payable(_RELAYER_MASTER), _RELAYER_FEE, 0);

        _assertEthFeeCharged(_pool3, _RELAYER_MASTER, _RELAYER_FEE);
        assertEq(_relayerRegistry.getRelayerBalance(_RELAYER_MASTER), stakeBefore, "no stake burned");
    }

    function testDirectSelfWithdrawPaysEthFee() external {
        (bytes32 root, bytes32 nullifier) = _deposit(_pool30);
        vm.prank(_recipient);
        _pool30.withdraw("", root, nullifier, payable(_recipient), payable(address(0)), 0, 0);

        _assertEthFeeCharged(_pool30, address(0), 0);
    }

    function testRelayerFeePlusProtocolFeeAboveDenominationReverts() external {
        (bytes32 root, bytes32 nullifier) = _deposit(_pool3);
        uint256 tooHighRelayerFee = _DENOM_3 - _directFee(_pool3) + 1;
        vm.prank(_recipient);
        vm.expectRevert(bytes("Fees exceed transfer value"));
        _pool3.withdraw("", root, nullifier, payable(_recipient), payable(_recipient), tooHighRelayerFee, 0);
    }

    function testBrokenRegistryStillAllowsWithdrawalWithEthFee() external {
        // A reverting registry must never lock funds: it only means the ETH fee applies.
        vm.mockCallRevert(_RELAYER_REGISTRY, abi.encodeWithSelector(IRelayerRegistry.tornadoRouter.selector), "");
        (bytes32 root, bytes32 nullifier) = _deposit(_pool3);
        vm.prank(_recipient);
        _pool3.withdraw("", root, nullifier, payable(_recipient), payable(address(0)), 0, 0);

        _assertEthFeeCharged(_pool3, address(0), 0);
    }

    // --- Fee configuration ---

    function testFeeGetters() external view {
        assertEq(_pool3.protocolFeePercentage(), 30, "protocol fee");
        assertEq(_pool3.directWithdrawPremiumPercentage(), 30, "premium");
        assertEq(_pool3.directWithdrawFeePercentage(), 60, "direct fee percentage");
        assertEq(_pool3.directWithdrawFee(), 0.018 ether, "3 ETH direct fee");
        assertEq(_pool30.directWithdrawFee(), 0.18 ether, "30 ETH direct fee");
    }

    function testGovernanceProposalChangesFeeAndPremium() external {
        address proposal = address(new SetFeesProposal(_pool3, 50, 100));
        _passAndExecute(proposal, "Set 3 ETH pool protocol fee to 0.5% and direct withdrawal premium to 1%");

        assertEq(_pool3.protocolFeePercentage(), 50, "protocol fee");
        assertEq(_pool3.directWithdrawPremiumPercentage(), 100, "premium");
        assertEq(_pool3.directWithdrawFeePercentage(), 150, "0.5% + 1% = 1.5%");
        assertEq(_pool30.protocolFeePercentage(), 30, "other pool fee untouched");
        assertEq(_pool30.directWithdrawPremiumPercentage(), 30, "other pool premium untouched");

        (bytes32 root, bytes32 nullifier) = _deposit(_pool3);
        vm.prank(_recipient);
        _pool3.withdraw("", root, nullifier, payable(_recipient), payable(address(0)), 0, 0);

        assertEq(_GOVERNANCE.balance, _govBalanceBefore + 0.045 ether, "1.5% of 3 ETH paid to governance");
        assertEq(_pool3.accruedProtocolFees(), 0, "nothing accrued");
        assertEq(_recipient.balance, _DENOM_3 - 0.045 ether, "recipient");
    }

    function testZeroFeeStillChargesPremium() external {
        vm.prank(_GOVERNANCE);
        _pool3.setProtocolFeePercentage(0);

        (bytes32 root, bytes32 nullifier) = _deposit(_pool3);
        vm.prank(_recipient);
        _pool3.withdraw("", root, nullifier, payable(_recipient), payable(address(0)), 0, 0);

        assertEq(_GOVERNANCE.balance, _govBalanceBefore + 0.009 ether, "0.3% premium of 3 ETH");
        assertEq(_recipient.balance, _DENOM_3 - 0.009 ether, "recipient");
    }

    function testGovernanceCanMakeDirectWithdrawalsFree() external {
        vm.startPrank(_GOVERNANCE);
        _pool3.setProtocolFeePercentage(0);
        _pool3.setDirectWithdrawPremiumPercentage(0);
        vm.stopPrank();

        (bytes32 root, bytes32 nullifier) = _deposit(_pool3);
        vm.prank(_recipient);
        _pool3.withdraw("", root, nullifier, payable(_recipient), payable(address(0)), 0, 0);

        assertEq(_pool3.accruedProtocolFees(), 0, "no fee");
        assertEq(_GOVERNANCE.balance, _govBalanceBefore, "governance unchanged");
        assertEq(_recipient.balance, _DENOM_3, "full denomination");
    }

    function testOnlyGovernanceCanSetFee() external {
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(bytes("Only governance"));
        _pool3.setProtocolFeePercentage(0);
    }

    function testFeeCannotExceedCap() external {
        uint256 cap = _pool3.MAX_PROTOCOL_FEE_PERCENTAGE();
        vm.startPrank(_GOVERNANCE);
        _pool3.setProtocolFeePercentage(cap);
        vm.expectRevert(bytes("Fee above cap"));
        _pool3.setProtocolFeePercentage(cap + 1);
        vm.stopPrank();
        assertEq(_pool3.protocolFeePercentage(), cap, "cap kept");
    }

    function testPremiumIsAddedToFee() external {
        // Changing the fee does not scale the premium: the total is a plain sum.
        vm.prank(_GOVERNANCE);
        _pool3.setProtocolFeePercentage(50);
        assertEq(_pool3.directWithdrawPremiumPercentage(), 30, "premium unchanged");
        assertEq(_pool3.directWithdrawFeePercentage(), 80, "50 + 30");
        assertEq(_pool3.directWithdrawFee(), 0.024 ether, "0.8% of 3 ETH");
    }

    function testPremiumAcceptsZeroUpToCap() external {
        uint256 cap = _pool3.MAX_DIRECT_WITHDRAW_PREMIUM_PERCENTAGE();
        assertEq(cap, 400, "cap");
        vm.startPrank(_GOVERNANCE);
        _pool3.setDirectWithdrawPremiumPercentage(0);
        assertEq(_pool3.directWithdrawFeePercentage(), 30, "no premium: protocol fee only");
        _pool3.setDirectWithdrawPremiumPercentage(cap);
        assertEq(_pool3.directWithdrawFeePercentage(), 430, "30 + 400");
        vm.stopPrank();
    }

    function testPremiumAboveCapReverts() external {
        uint256 cap = _pool3.MAX_DIRECT_WITHDRAW_PREMIUM_PERCENTAGE();
        vm.prank(_GOVERNANCE);
        vm.expectRevert(bytes("Premium above cap"));
        _pool3.setDirectWithdrawPremiumPercentage(cap + 1);
        assertEq(_pool3.directWithdrawPremiumPercentage(), 30, "unchanged");
    }

    function testOnlyGovernanceCanSetPremium() external {
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(bytes("Only governance"));
        _pool3.setDirectWithdrawPremiumPercentage(0);
    }

    // --- Fee payment to Governance ---

    function testDirectWithdrawPaysGovernanceInSameTransaction() external {
        (bytes32 root, bytes32 nullifier) = _deposit(_pool3);
        vm.expectEmit(true, false, false, true, address(_pool3));
        emit ProtocolFeeCharged(address(0), _directFee(_pool3), true);
        vm.prank(_recipient);
        _pool3.withdraw("", root, nullifier, payable(_recipient), payable(address(0)), 0, 0);

        assertEq(_GOVERNANCE.balance, _govBalanceBefore + _directFee(_pool3), "paid immediately");
        assertEq(_pool3.accruedProtocolFees(), 0, "nothing accrued");
        assertEq(address(_pool3).balance, 0, "nothing left in pool");
    }

    function testRevertingGovernanceStillAllowsWithdrawal() external {
        vm.etch(_GOVERNANCE, _REVERTING_CODE);
        (bytes32 root, bytes32 nullifier) = _deposit(_pool3);
        vm.expectEmit(true, false, false, true, address(_pool3));
        emit ProtocolFeeCharged(address(0), _directFee(_pool3), false);
        vm.prank(_recipient);
        _pool3.withdraw("", root, nullifier, payable(_recipient), payable(address(0)), 0, 0);

        _assertFeeAccrued(_pool3);
    }

    function testGasBurningGovernanceStillAllowsWithdrawal() external {
        // With a fixed gas budget, an uncapped call would hand 63/64 of it to the loop and the
        // withdrawal would run out of gas. FEE_TRANSFER_GAS keeps the rest for the withdrawal.
        vm.etch(_GOVERNANCE, _GAS_BURNING_CODE);
        (bytes32 root, bytes32 nullifier) = _deposit(_pool3);
        vm.prank(_recipient);
        _pool3.withdraw{gas: 500_000}("", root, nullifier, payable(_recipient), payable(address(0)), 0, 0);

        _assertFeeAccrued(_pool3);
    }

    // --- Sweep (fallback when Governance could not receive the fee) ---

    function testAnyoneCanSweepAccruedFeesToGovernance() external {
        vm.etch(_GOVERNANCE, _REVERTING_CODE);
        for (uint256 i = 0; i < 2; i++) {
            (bytes32 root, bytes32 nullifier) = _deposit(_pool3);
            vm.prank(_recipient);
            _pool3.withdraw("", root, nullifier, payable(_recipient), payable(address(0)), 0, 0);
        }
        uint256 accrued = _pool3.accruedProtocolFees();
        assertEq(accrued, 2 * _directFee(_pool3), "accrued");

        vm.expectRevert(bytes("payment to GOVERNANCE did not go thru"));
        _pool3.sweepProtocolFees();

        vm.etch(_GOVERNANCE, _govCode);
        uint256 poolBefore = address(_pool3).balance;
        vm.prank(makeAddr("anyone"));
        _pool3.sweepProtocolFees();

        assertEq(_GOVERNANCE.balance, _govBalanceBefore + accrued, "governance received fees");
        assertEq(address(_pool3).balance, poolBefore - accrued, "pool paid fees");
        assertEq(_pool3.accruedProtocolFees(), 0, "accrued reset");

        vm.expectRevert(bytes("Nothing to sweep"));
        _pool3.sweepProtocolFees();
    }

    function testSweepNeverTouchesDepositorFunds() external {
        // Pool keeps exactly one denomination per unspent note after a sweep.
        vm.etch(_GOVERNANCE, _REVERTING_CODE);
        _deposit(_pool3);
        (bytes32 root, bytes32 nullifier) = _deposit(_pool3);
        vm.prank(_recipient);
        _pool3.withdraw("", root, nullifier, payable(_recipient), payable(address(0)), 0, 0);

        vm.etch(_GOVERNANCE, _govCode);
        _pool3.sweepProtocolFees();

        assertEq(address(_pool3).balance, _DENOM_3, "one unspent note left");
    }

    // --- 0.01, 0.03 and 0.3 ETH: free with a registered relayer, protocol fee otherwise ---

    function testSmallPoolsChargeProtocolFeeWithoutPremium() external view {
        IFeeEnforcedTornado[3] memory pools = [_pool001, _pool003, _pool03];
        for (uint256 i = 0; i < pools.length; i++) {
            IFeeEnforcedTornado pool = pools[i];
            assertEq(pool.protocolFeePercentage(), 30, "protocol fee");
            assertEq(pool.directWithdrawPremiumPercentage(), 0, "no premium");
            assertEq(pool.directWithdrawFeePercentage(), 30, "0.3%");
            (,,,, uint32 relayerFee) = _registry.instances(address(pool));
            assertEq(relayerFee, 0, "registered relayers pay nothing");
        }
        assertEq(_pool001.directWithdrawFee(), 0.00003 ether, "0.3% of 0.01 ETH");
        assertEq(_pool003.directWithdrawFee(), 0.00009 ether, "0.3% of 0.03 ETH");
        assertEq(_pool03.directWithdrawFee(), 0.0009 ether, "0.3% of 0.3 ETH");
    }

    function testSmallPoolDirectWithdrawPaysProtocolFee() external {
        (bytes32 root, bytes32 nullifier) = _deposit(_pool001);
        vm.prank(_recipient);
        _pool001.withdraw("", root, nullifier, payable(_recipient), payable(address(0)), 0, 0);

        _assertEthFeeCharged(_pool001, address(0), 0);
        assertEq(_recipient.balance, 0.00997 ether, "0.01 ETH - 0.3%");
    }

    function testSmallPoolCustomRelayerViaRouterPaysProtocolFee() external {
        address customRelayer = makeAddr("customRelayer");
        uint256 relayerFee = 0.0003 ether;
        (bytes32 root, bytes32 nullifier) = _deposit(_pool003);
        vm.prank(customRelayer);
        _router.withdraw(
            address(_pool003), "", root, nullifier, payable(_recipient), payable(customRelayer), relayerFee, 0
        );

        _assertEthFeeCharged(_pool003, customRelayer, relayerFee);
    }

    function testSmallPoolRegisteredRelayerPaysNothing() external {
        uint256 relayerFee = 0.0001 ether;
        (bytes32 root, bytes32 nullifier) = _deposit(_pool001);

        uint256 stakeBefore = _relayerRegistry.getRelayerBalance(_RELAYER_MASTER);
        uint256 relayerEthBefore = _RELAYER_MASTER.balance;
        vm.prank(_worker);
        _router.withdraw(
            address(_pool001), "", root, nullifier, payable(_recipient), payable(_RELAYER_MASTER), relayerFee, 0
        );

        assertEq(_recipient.balance, _DENOM_001 - relayerFee, "recipient: denomination - relayer fee");
        assertEq(_RELAYER_MASTER.balance, relayerEthBefore + relayerFee, "relayer fee paid");
        assertEq(_GOVERNANCE.balance, _govBalanceBefore, "no ETH protocol fee");
        assertEq(_pool001.accruedProtocolFees(), 0, "nothing accrued");
        assertEq(_relayerRegistry.getRelayerBalance(_RELAYER_MASTER), stakeBefore, "no TORN burned");
    }

    function testPoint3PoolDirectWithdrawPaysProtocolFee() external {
        (bytes32 root, bytes32 nullifier) = _deposit(_pool03);
        vm.prank(_recipient);
        _pool03.withdraw("", root, nullifier, payable(_recipient), payable(address(0)), 0, 0);

        _assertEthFeeCharged(_pool03, address(0), 0);
        assertEq(_recipient.balance, 0.2991 ether, "0.3 ETH - 0.3%");
    }

    function testPoint3PoolRegisteredRelayerPaysNothing() external {
        uint256 relayerFee = 0.001 ether;
        (bytes32 root, bytes32 nullifier) = _deposit(_pool03);

        uint256 stakeBefore = _relayerRegistry.getRelayerBalance(_RELAYER_MASTER);
        vm.prank(_worker);
        _router.withdraw(
            address(_pool03), "", root, nullifier, payable(_recipient), payable(_RELAYER_MASTER), relayerFee, 0
        );

        assertEq(_recipient.balance, _DENOM_03 - relayerFee, "recipient: denomination - relayer fee");
        assertEq(_GOVERNANCE.balance, _govBalanceBefore, "no ETH protocol fee");
        assertEq(_relayerRegistry.getRelayerBalance(_RELAYER_MASTER), stakeBefore, "no TORN burned");
    }

    // --- Helpers ---

    function _assertRegisteredRelayerPaysTorn(IFeeEnforcedTornado pool) internal {
        (bytes32 root, bytes32 nullifier) = _deposit(pool);
        assertTrue(pool.isRegisteredRelayerWithdrawal(_ROUTER, _RELAYER_MASTER), "router + master");

        uint256 stakeBefore = _relayerRegistry.getRelayerBalance(_RELAYER_MASTER);
        uint256 relayerEthBefore = _RELAYER_MASTER.balance;

        vm.prank(_worker);
        _router.withdraw(
            address(pool), "", root, nullifier, payable(_recipient), payable(_RELAYER_MASTER), _RELAYER_FEE, 0
        );

        assertTrue(pool.isSpent(nullifier), "spent");
        assertEq(_recipient.balance, pool.denomination() - _RELAYER_FEE, "recipient: denomination - relayer fee");
        assertEq(_RELAYER_MASTER.balance, relayerEthBefore + _RELAYER_FEE, "relayer fee paid");
        assertEq(pool.accruedProtocolFees(), 0, "no ETH protocol fee accrued");
        assertEq(_GOVERNANCE.balance, _govBalanceBefore, "no ETH protocol fee paid");
        assertLt(_relayerRegistry.getRelayerBalance(_RELAYER_MASTER), stakeBefore, "TORN stake burned");
    }

    function _assertEthFeeCharged(IFeeEnforcedTornado pool, address relayer, uint256 relayerFee) internal view {
        uint256 protocolFee = _directFee(pool);
        assertEq(protocolFee, pool.directWithdrawFee(), "directWithdrawFee getter");
        assertEq(_GOVERNANCE.balance, _govBalanceBefore + protocolFee, "ETH protocol fee paid to governance");
        assertEq(pool.accruedProtocolFees(), 0, "nothing accrued");
        if (relayer == _recipient || relayer == address(0)) {
            assertEq(_recipient.balance, pool.denomination() - protocolFee, "recipient");
        } else {
            assertEq(_recipient.balance, pool.denomination() - relayerFee - protocolFee, "recipient");
        }
        assertEq(address(pool).balance, 0, "nothing left in pool");
    }

    function _assertFeeAccrued(IFeeEnforcedTornado pool) internal view {
        uint256 protocolFee = _directFee(pool);
        assertEq(pool.accruedProtocolFees(), protocolFee, "fee accrued");
        assertEq(address(pool).balance, protocolFee, "fee kept in pool");
        assertEq(_GOVERNANCE.balance, _govBalanceBefore, "governance not paid");
        assertEq(_recipient.balance, pool.denomination() - protocolFee, "recipient still paid");
    }

    function _directFee(IFeeEnforcedTornado pool) internal view returns (uint256) {
        return pool.denomination() * pool.directWithdrawFeePercentage() / 10_000;
    }

    /// @dev Deposit one note via the Router; returns the current root and a fresh nullifier hash.
    function _deposit(ITornadoInstance pool) internal returns (bytes32 root, bytes32 nullifier) {
        _noteCount++;
        string memory tag = string(abi.encodePacked("note-", vm.toString(_noteCount)));
        _depositViaRouter(_depositor, address(pool), pool.denomination(), tag);
        root = pool.getLastRoot();
        nullifier = bytes32(uint256(keccak256(abi.encodePacked("nullifier-", tag))) % _FIELD_SIZE);
    }
}
