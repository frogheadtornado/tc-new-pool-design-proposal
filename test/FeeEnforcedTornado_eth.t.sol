// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {
    ProposalFixture,
    IRelayerRegistry,
    ITornadoInstance,
    IFeeEnforcedTornado,
    IFeeManager
} from "./utils/ProposalFixture.sol";

interface IVerifier {
    function verifyProof(bytes memory proof, uint256[6] memory input) external returns (bool);
}

interface IStakingRewards {
    function checkEthReward(address account) external view returns (uint256);
    function getEthReward() external;
}

/// @dev Pays the staking contract the way the pool does: a call with a fixed gas allowance.
contract CappedPayer {
    function pay(address staking, uint256 gasAllowance) external payable returns (bool paid) {
        (paid,) = staking.call{value: msg.value, gas: gasAllowance}(abi.encodeWithSignature("addEthRewards()"));
    }
}

/// @dev A hostile fee receiver. It refuses a payment while the pool has nothing accrued, so the first
///      fee stays in the pool. From then on it answers every payment by sweeping the pool, and accepts
///      the payment that the sweep sends.
contract SweepingReceiver {
    bytes32 private constant _SWEEPING = keccak256("SweepingReceiver.sweeping");

    function addEthRewards() external payable {
        bytes32 slot = _SWEEPING;
        uint256 sweeping;
        assembly {
            sweeping := sload(slot)
        }
        if (sweeping != 0) return;

        IFeeEnforcedTornado pool = IFeeEnforcedTornado(msg.sender);
        require(pool.accruedProtocolFees() > 0, "refused");
        assembly {
            sstore(slot, 1)
        }
        pool.sweepProtocolFees();
        assembly {
            sstore(slot, 0)
        }
    }
}

/// @dev A hostile fee receiver that owns a note and tries to withdraw it inside the fee payment of
///      someone else's withdrawal.
contract WithdrawingReceiver {
    bytes32 private constant _NULLIFIER = keccak256("WithdrawingReceiver.nullifier");

    function arm(bytes32 nullifier) external {
        bytes32 slot = _NULLIFIER;
        assembly {
            sstore(slot, nullifier)
        }
    }

    function addEthRewards() external payable {
        bytes32 slot = _NULLIFIER;
        bytes32 nullifier;
        assembly {
            nullifier := sload(slot)
            sstore(slot, 0)
        }
        if (nullifier == bytes32(0)) return;

        IFeeEnforcedTornado pool = IFeeEnforcedTornado(msg.sender);
        (bool withdrawn,) = address(pool)
            .call(
                abi.encodeWithSelector(
                    pool.withdraw.selector,
                    "",
                    pool.getLastRoot(),
                    nullifier,
                    payable(address(this)),
                    payable(address(0)),
                    0,
                    pool.directWithdrawFee()
                )
            );
        withdrawn;
    }

    receive() external payable {}
}

/// @dev A hostile fee receiver that tries to run a deposit inside the fee payment.
contract DepositingReceiver {
    function addEthRewards() external payable {
        IFeeEnforcedTornado pool = IFeeEnforcedTornado(msg.sender);
        (bool deposited,) = address(pool).call{value: pool.denomination()}(
            abi.encodeWithSignature("deposit(bytes32)", bytes32(uint256(0xdead)))
        );
        deposited;
    }
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
 * @dev Mainnet-fork tests for the fee-enforcing pool, after executing the proposal through live
 *      governance. The proposal adds the 0.01 ETH pool; the fixture registers the same pool code for
 *      0.03, 0.3, 3 and 30 ETH so that the contract is tested at larger amounts too. The SNARK verifier is mocked to accept any proof;
 *      Router, RelayerRegistry.burn, FeeManager, Governance and the staking proxy (running the new
 *      implementation after the proposal) are the live contracts.
 *
 *      Fee rules under test, the same on every pool (most tests use the 3 and 30 ETH pools):
 *        - Router + registered relayer master → TORN stake burned, no ETH fee.
 *        - Anything else → 0.3% fee + 0.3% premium = 0.6% of the denomination paid in ETH to the TORN lockers
 *          (TornadoStakingRewards) in the same transaction, or accrued in the pool (sweepable) if the staking
 *          contract cannot take it.
 */
contract FeeEnforcedTornadoEthTest is ProposalFixture {
    /// @dev Live registered relayer master (workers[master] == master) with ample stake.
    address private constant _RELAYER_MASTER = 0x4750BCfcC340AA4B31be7e71fa072716d28c29C5;
    uint256 private constant _RELAYER_FEE = 0.01 ether;
    /// @dev PUSH1 0 PUSH1 0 REVERT: a receiver that always reverts.
    bytes private constant _REVERTING_CODE = hex"60006000fd";
    /// @dev JUMPDEST PUSH1 0 JUMP: a receiver that loops until it runs out of gas.
    bytes private constant _GAS_BURNING_CODE = hex"5b600056";
    /// @dev PUSH3 0x100000 PUSH1 0 RETURN: returns 1 MiB of zeros (a "return bomb").
    bytes private constant _RETURN_BOMB_CODE = hex"62100000" hex"6000" hex"f3";

    event ProtocolFeeCharged(address indexed relayer, uint256 amount, bool paidToStaking);

    address private _worker;
    address private _recipient;
    address private _depositor;
    uint256 private _noteCount;
    uint256 private _stakingBalanceBefore;
    bytes private _stakingCode;

    function setUp() external {
        // The state after both proposals: the pool exists and the staking contract takes ETH. The
        // state in between, with the pool live and the staking contract not upgraded yet, has its own
        // tests below.
        _forkAndDeployProposal();
        _passAndExecuteProposal();
        _upgradeStaking();
        _addLargerPoolsAsGovernance();

        vm.mockCall(_VERIFIER, abi.encodeWithSelector(IVerifier.verifyProof.selector), abi.encode(true));

        assertEq(_relayerRegistry.workers(_RELAYER_MASTER), _RELAYER_MASTER, "fixture relayer not registered");
        assertGt(_relayerRegistry.getRelayerBalance(_RELAYER_MASTER), 0, "fixture relayer has no stake");

        _worker = makeAddr("worker");
        vm.prank(_RELAYER_MASTER);
        _relayerRegistry.registerWorker(_RELAYER_MASTER, _worker);

        _recipient = makeAddr("recipient");
        _depositor = makeAddr("depositor");
        _stakingBalanceBefore = _STAKING.balance;
        _stakingCode = _STAKING.code;
    }

    // --- Registered relayer through the Router: fee paid in TORN only ---

    function testRegisteredRelayerViaRouterPaysTornNotEth() external {
        _assertRegisteredRelayerPaysTorn(_pool3, _RELAYER_FEE);
    }

    function testRegisteredRelayerViaRouterPaysTornNotEth30() external {
        _assertRegisteredRelayerPaysTorn(_pool30, _RELAYER_FEE);
    }

    function testRegisteredRelayerWithdrawalPaysTheDaoOnce() external {
        // A relayer charging the user 0.4% of 3 ETH. The DAO is paid once: 0.3% in TORN from the
        // relayer's stake, at the same rate as on the live 1 ETH pool. The pool takes no ETH on top.
        (bytes32 root, bytes32 nullifier) = _deposit(_pool3);
        uint256 stakeBefore = _relayerRegistry.getRelayerBalance(_RELAYER_MASTER);
        uint256 relayerEthBefore = _RELAYER_MASTER.balance;
        uint256 tornBurnedPerEth = IFeeManager(_FEE_MANAGER).calculatePoolFee(_LEGACY_1_ETH_POOL);

        vm.prank(_worker);
        _router.withdraw(
            address(_pool3), "", root, nullifier, payable(_recipient), payable(_RELAYER_MASTER), 0.012 ether, 0
        );

        assertEq(_recipient.balance, 2.988 ether, "the user pays the relayer's 0.4% and nothing else");
        assertEq(_RELAYER_MASTER.balance, relayerEthBefore + 0.012 ether, "the relayer keeps its whole fee");
        assertEq(_STAKING.balance, _stakingBalanceBefore, "no ETH fee from the pool");
        assertEq(_pool3.accruedProtocolFees(), 0, "and none held back");
        assertApproxEqAbs(
            stakeBefore - _relayerRegistry.getRelayerBalance(_RELAYER_MASTER),
            3 * tornBurnedPerEth,
            3,
            "0.3% in TORN from the relayer's stake"
        );
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
            address(_pool3), "", root, nullifier, payable(_recipient), payable(customRelayer), _RELAYER_FEE, 0.018 ether
        );

        _assertEthFeeCharged(_pool3, customRelayer, _RELAYER_FEE);
        assertEq(_relayerRegistry.getRelayerBalance(_RELAYER_MASTER), stakeBefore, "no stake burned");
    }

    function testZeroRelayerViaRouterPaysEthFee() external {
        // burn() lets an unregistered caller through without burning when _relayer == 0.
        (bytes32 root, bytes32 nullifier) = _deposit(_pool3);
        vm.prank(_recipient);
        _router.withdraw(address(_pool3), "", root, nullifier, payable(_recipient), payable(address(0)), 0, 0.018 ether);

        _assertEthFeeCharged(_pool3, address(0), 0);
    }

    // --- The note owner states in the proof the most the pool may charge (the `_refund` input) ---

    function testRelayedProofCannotBeSubmittedStraightToThePool() external {
        // A proof made for a registered relayer accepts no pool fee. Sent to the pool without the
        // Router, by the relayer (which would keep its fee and burn no stake) or by anyone who saw
        // it in the mempool, it would otherwise be charged to the note owner.
        (bytes32 root, bytes32 nullifier) = _deposit(_pool3);

        vm.prank(_worker);
        vm.expectRevert(bytes("Protocol fee above what the note owner accepted"));
        _pool3.withdraw("", root, nullifier, payable(_recipient), payable(_RELAYER_MASTER), _RELAYER_FEE, 0);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(bytes("Protocol fee above what the note owner accepted"));
        _pool3.withdraw("", root, nullifier, payable(_recipient), payable(_RELAYER_MASTER), _RELAYER_FEE, 0);

        // The path the owner agreed to still works, and pays what was agreed.
        vm.prank(_worker);
        _router.withdraw(
            address(_pool3), "", root, nullifier, payable(_recipient), payable(_RELAYER_MASTER), _RELAYER_FEE, 0
        );
        assertEq(_recipient.balance, _DENOM_3 - _RELAYER_FEE, "denomination - relayer fee");
    }

    function testDirectWithdrawalChargesNoMoreThanTheNoteOwnerAccepted() external {
        (bytes32 root, bytes32 nullifier) = _deposit(_pool3);

        vm.prank(_recipient);
        vm.expectRevert(bytes("Protocol fee above what the note owner accepted"));
        _pool3.withdraw("", root, nullifier, payable(_recipient), payable(address(0)), 0, 0.018 ether - 1);

        // Accepting more than the fee does not make the pool charge more.
        vm.prank(_recipient);
        _pool3.withdraw("", root, nullifier, payable(_recipient), payable(address(0)), 0, 1 ether);
        assertEq(_recipient.balance, _DENOM_3 - 0.018 ether, "charged the fee, not the maximum");
        assertEq(_STAKING.balance, _stakingBalanceBefore + 0.018 ether, "fee paid to staking");
    }

    function testFeeRaisedAfterTheProofWasMadeIsNotCharged() external {
        // The proof was made when the fee was 0.6%. Governance then raises it: the old proof is
        // refused instead of costing its owner more, who can make a new one.
        (bytes32 root, bytes32 nullifier) = _deposit(_pool3);
        vm.prank(_GOVERNANCE);
        _pool3.setDirectWithdrawPremiumPercentage(400);

        vm.prank(_recipient);
        vm.expectRevert(bytes("Protocol fee above what the note owner accepted"));
        _pool3.withdraw("", root, nullifier, payable(_recipient), payable(address(0)), 0, 0.018 ether);

        vm.prank(_recipient);
        _pool3.withdraw("", root, nullifier, payable(_recipient), payable(address(0)), 0, 0.129 ether);
        assertEq(_recipient.balance, _DENOM_3 - 0.129 ether, "0.3% + 4% of 3 ETH, accepted this time");
    }

    function testDirectSelfWithdrawPaysEthFee() external {
        (bytes32 root, bytes32 nullifier) = _deposit(_pool30);
        vm.prank(_recipient);
        _pool30.withdraw("", root, nullifier, payable(_recipient), payable(address(0)), 0, 0.18 ether);

        _assertEthFeeCharged(_pool30, address(0), 0);
    }

    function testRelayerFeePlusProtocolFeeAboveDenominationReverts() external {
        (bytes32 root, bytes32 nullifier) = _deposit(_pool3);
        uint256 tooHighRelayerFee = _DENOM_3 - _directFee(_pool3) + 1;
        vm.prank(_recipient);
        vm.expectRevert(bytes("Fees exceed transfer value"));
        _pool3.withdraw("", root, nullifier, payable(_recipient), payable(_recipient), tooHighRelayerFee, 0.018 ether);
    }

    // A broken or malicious RelayerRegistry must never lock funds: it only means the ETH fee applies.
    // These withdrawals name a non-zero relayer so that the pool actually reads the registry.

    function testRevertingRegistryStillAllowsWithdrawal() external {
        (bytes32 root, bytes32 nullifier) = _deposit(_pool3);
        vm.etch(_RELAYER_REGISTRY, _REVERTING_CODE);
        _withdrawDirectNamingRelayer(_pool3, root, nullifier, 10_000_000);

        _assertEthFeeCharged(_pool3, _RELAYER_MASTER, 0);
    }

    function testReturnBombRegistryStillAllowsWithdrawal() external {
        // A 1 MiB reply costs the registry ~2.2M gas to build, and the pool about the same to copy.
        // Uncapped, with a 3M budget the registry gets ~2.9M, builds the reply, and leaves the pool
        // ~0.75M: the copy runs out of gas. A real attacker sizes the reply to the gas it receives,
        // so no budget is safe. Capped, the registry runs out of gas and nothing is copied.
        (bytes32 root, bytes32 nullifier) = _deposit(_pool3);
        vm.etch(_RELAYER_REGISTRY, _RETURN_BOMB_CODE);
        _withdrawDirectNamingRelayer(_pool3, root, nullifier, 3_000_000);

        _assertEthFeeCharged(_pool3, _RELAYER_MASTER, 0);
    }

    function testGasBurningRegistryStillAllowsWithdrawal() external {
        // Uncapped, the loop would take 63/64 of the 1M gas and leave too little to finish.
        (bytes32 root, bytes32 nullifier) = _deposit(_pool3);
        vm.etch(_RELAYER_REGISTRY, _GAS_BURNING_CODE);
        _withdrawDirectNamingRelayer(_pool3, root, nullifier, 1_000_000);

        _assertEthFeeCharged(_pool3, _RELAYER_MASTER, 0);
    }

    function testRegistryReadsUseLittleGas() external view {
        assertEq(_pool3.REGISTRY_CALL_GAS(), 50_000, "cap");
        uint256 gasBefore = gasleft();
        assertTrue(_pool3.isRegisteredRelayerWithdrawal(_ROUTER, _RELAYER_MASTER), "registered");
        assertLt(gasBefore - gasleft(), 50_000, "both reads fit well under one cap");
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
        _pool3.withdraw("", root, nullifier, payable(_recipient), payable(address(0)), 0, 0.045 ether);

        assertEq(_STAKING.balance, _stakingBalanceBefore + 0.045 ether, "1.5% of 3 ETH paid to staking");
        assertEq(_pool3.accruedProtocolFees(), 0, "nothing accrued");
        assertEq(_recipient.balance, _DENOM_3 - 0.045 ether, "recipient");
    }

    function testZeroFeeStillChargesPremium() external {
        vm.prank(_GOVERNANCE);
        _pool3.setProtocolFeePercentage(0);

        (bytes32 root, bytes32 nullifier) = _deposit(_pool3);
        vm.prank(_recipient);
        _pool3.withdraw("", root, nullifier, payable(_recipient), payable(address(0)), 0, 0.009 ether);

        assertEq(_STAKING.balance, _stakingBalanceBefore + 0.009 ether, "0.3% premium of 3 ETH");
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
        assertEq(_STAKING.balance, _stakingBalanceBefore, "staking unchanged");
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

    // --- Fee payment to the TORN lockers (TornadoStakingRewards) ---

    function testDirectWithdrawFeeIsCreditedToTornLockers() external {
        // The fixture's voter locked 100% of quorum and nothing else changed since, so its share of
        // the 0.18 ETH fee (0.6% of 30 ETH) follows from the TORN held by the Governance vault.
        address voter = makeAddr("voter");
        uint256 locked = _gov.lockedBalance(voter);
        uint256 totalLocked = _torn.balanceOf(_gov.userVault());
        (bytes32 root, bytes32 nullifier) = _deposit(_pool30);

        vm.prank(_recipient);
        _pool30.withdraw("", root, nullifier, payable(_recipient), payable(address(0)), 0, 0.18 ether);

        assertApproxEqAbs(
            IStakingRewards(_STAKING).checkEthReward(voter), 0.18 ether * locked / totalLocked, 2, "voter's share"
        );
        vm.prank(voter);
        IStakingRewards(_STAKING).getEthReward();
        assertApproxEqAbs(voter.balance, 0.18 ether * locked / totalLocked, 2, "claimed in ETH");
    }

    function testDirectWithdrawPaysStakingInSameTransaction() external {
        (bytes32 root, bytes32 nullifier) = _deposit(_pool3);
        vm.expectEmit(true, false, false, true, address(_pool3));
        emit ProtocolFeeCharged(address(0), _directFee(_pool3), true);
        vm.prank(_recipient);
        _pool3.withdraw("", root, nullifier, payable(_recipient), payable(address(0)), 0, 0.018 ether);

        assertEq(_STAKING.balance, _stakingBalanceBefore + _directFee(_pool3), "paid immediately");
        assertEq(_pool3.accruedProtocolFees(), 0, "nothing accrued");
        assertEq(address(_pool3).balance, 0, "nothing left in pool");
    }

    function testRevertingStakingStillAllowsWithdrawal() external {
        vm.etch(_STAKING, _REVERTING_CODE);
        (bytes32 root, bytes32 nullifier) = _deposit(_pool3);
        vm.expectEmit(true, false, false, true, address(_pool3));
        emit ProtocolFeeCharged(address(0), _directFee(_pool3), false);
        vm.prank(_recipient);
        _pool3.withdraw("", root, nullifier, payable(_recipient), payable(address(0)), 0, 0.018 ether);

        _assertFeeAccrued(_pool3);
    }

    function testGasBurningStakingStillAllowsWithdrawal() external {
        // With a fixed gas budget, an uncapped call would hand 63/64 of it to the loop and the
        // withdrawal would run out of gas. FEE_TRANSFER_GAS keeps the rest for the withdrawal.
        vm.etch(_STAKING, _GAS_BURNING_CODE);
        (bytes32 root, bytes32 nullifier) = _deposit(_pool3);
        vm.prank(_recipient);
        _pool3.withdraw{gas: 500_000}("", root, nullifier, payable(_recipient), payable(address(0)), 0, 0.018 ether);

        _assertFeeAccrued(_pool3);
    }

    // The pool's reentrancy guard does not stop a nested call: it reverts the OUTER call when a
    // nested guarded call succeeded. A fee receiver must not be able to use that to block withdrawals.

    function testFeeReceiverSweepingThePoolCannotBlockWithdrawals() external {
        vm.etch(_STAKING, address(new SweepingReceiver()).code);
        (bytes32 root, bytes32 nullifier) = _deposit(_pool3);
        vm.prank(_recipient);
        _pool3.withdraw("", root, nullifier, payable(_recipient), payable(address(0)), 0, 0.018 ether);
        assertEq(_pool3.accruedProtocolFees(), 0.018 ether, "first fee refused by the receiver and kept");

        (root, nullifier) = _deposit(_pool3);
        vm.prank(_recipient);
        _pool3.withdraw("", root, nullifier, payable(_recipient), payable(address(0)), 0, 0.018 ether);

        assertTrue(_pool3.isSpent(nullifier), "second withdrawal went through");
        assertEq(_recipient.balance, 2 * (_DENOM_3 - 0.018 ether), "recipient paid both times");
        assertEq(address(_pool3).balance, 0, "pool holds nothing it should not");
    }

    function testFeeReceiverCannotCompleteAWithdrawalInsideTheFeePayment() external {
        // With the proof check mocked, as here, a withdrawal is cheap enough to fit in the gas the
        // pool forwards with the fee. Deposits and withdrawals are refused while the fee is being
        // paid, whatever they cost.
        vm.etch(_STAKING, address(new WithdrawingReceiver()).code);
        (, bytes32 receiverNullifier) = _deposit(_pool3);
        (bytes32 root, bytes32 nullifier) = _deposit(_pool3);
        WithdrawingReceiver(payable(_STAKING)).arm(receiverNullifier);

        vm.prank(_recipient);
        _pool3.withdraw("", root, nullifier, payable(_recipient), payable(address(0)), 0, 0.018 ether);

        assertTrue(_pool3.isSpent(nullifier), "the user's withdrawal went through");
        assertFalse(_pool3.isSpent(receiverNullifier), "the nested withdrawal did not");
        assertEq(_recipient.balance, _DENOM_3 - 0.018 ether, "recipient paid");
    }

    function testFeeReceiverCannotRunADepositInsideTheFeePayment() external {
        // A deposit is behind the same guard and would revert the outer withdrawal if it completed.
        vm.etch(_STAKING, address(new DepositingReceiver()).code);
        deal(_STAKING, _DENOM_3);
        (bytes32 root, bytes32 nullifier) = _deposit(_pool3);

        vm.prank(_recipient);
        _pool3.withdraw("", root, nullifier, payable(_recipient), payable(address(0)), 0, 0.018 ether);

        assertTrue(_pool3.isSpent(nullifier), "withdrawal went through");
        assertFalse(_pool3.commitments(bytes32(uint256(0xdead))), "the nested deposit ran out of gas");
        assertEq(_recipient.balance, _DENOM_3 - 0.018 ether, "recipient paid");
    }

    function testReturnBombStakingStillAllowsWithdrawal() external {
        // A 1 MiB reply costs more gas than the payment forwards, and the pool copies none of it.
        vm.etch(_STAKING, _RETURN_BOMB_CODE);
        (bytes32 root, bytes32 nullifier) = _deposit(_pool3);
        vm.prank(_recipient);
        _pool3.withdraw{gas: 3_000_000}("", root, nullifier, payable(_recipient), payable(address(0)), 0, 0.018 ether);

        _assertFeeAccrued(_pool3);
    }

    function testRelayerFeeCachedAsZeroBeforeRegistrationIsRefreshed() external {
        // FeeManager.updateFee is open to anyone and caches the TORN fee for two days. For a pool that
        // is not registered yet that fee is 0, so caching it right before the proposal executes would
        // make registered-relayer withdrawals free until someone refreshed it.
        _forkAndDeployProposal();
        uint256 proposalId = _pass(_proposal, _DESCRIPTION);
        _pool001 = IFeeEnforcedTornado(_nextContractOfGovernance());
        IFeeManager(_FEE_MANAGER).updateFee(address(_pool001));
        _gov.execute(proposalId);
        assertGt(address(_pool001).code.length, 0, "the pool is where it was expected");

        vm.mockCall(_VERIFIER, abi.encodeWithSelector(IVerifier.verifyProof.selector), abi.encode(true));
        (bytes32 root, bytes32 nullifier) = _deposit(_pool001);
        uint256 stakeBefore = _relayerRegistry.getRelayerBalance(_RELAYER_MASTER);
        uint256 tornBurnedPerEth = IFeeManager(_FEE_MANAGER).calculatePoolFee(_LEGACY_1_ETH_POOL);
        vm.prank(_RELAYER_MASTER);
        _router.withdraw(
            address(_pool001), "", root, nullifier, payable(_recipient), payable(_RELAYER_MASTER), 0.00004 ether, 0
        );

        assertApproxEqAbs(
            stakeBefore - _relayerRegistry.getRelayerBalance(_RELAYER_MASTER),
            tornBurnedPerEth / 100,
            3,
            "0.3% of 0.01 ETH in TORN from the relayer's stake"
        );
    }

    function testFeePaymentSucceedsWithHalfItsGasAllowance() external {
        // If the payment ever needed more gas than the pool forwards, fees would stop reaching the
        // lockers directly and pile up in the pool. The first payment is the expensive one: it
        // writes the ETH reward index for the first time.
        CappedPayer payer = new CappedPayer();
        deal(address(this), 0.018 ether);

        bool paid = payer.pay{value: 0.018 ether}(_STAKING, _pool3.FEE_TRANSFER_GAS() / 2);

        assertTrue(paid, "the payment needs more than half of the gas the pool forwards");
    }

    function testFeePaymentAfterALockSucceedsWithHalfItsGasAllowance() external {
        // The most expensive payment: the first one after somebody locked or unlocked. That lock took a
        // checkpoint, so the payment has to start a new version of the ETH reward index.
        CappedPayer payer = new CappedPayer();
        deal(address(this), 0.036 ether);
        assertTrue(payer.pay{value: 0.018 ether}(_STAKING, _pool3.FEE_TRANSFER_GAS() / 2), "first payment");
        address locker = makeAddr("fee-enforced-tornado-test/locker");
        deal(_TORN, locker, 1_000 ether);
        vm.startPrank(locker);
        _torn.approve(_GOVERNANCE, 1_000 ether);
        _gov.lockWithApproval(1_000 ether);
        vm.stopPrank();

        bool paid = payer.pay{value: 0.018 ether}(_STAKING, _pool3.FEE_TRANSFER_GAS() / 2);

        assertTrue(paid, "the payment needs more than half of the gas the pool forwards");
    }

    // --- Between the two proposals: the pool is live and the staking contract is not upgraded yet ---

    function testFeesChargedBeforeTheStakingUpgradeWaitInThePoolAndAreSweptAfter() external {
        // The staking contract still runs the old implementation, which rejects ETH. The pool keeps
        // the fee and the withdrawal goes through. Once the staking contract is upgraded, anyone can
        // forward what the pool kept.
        _forkAndDeployProposal();
        _passAndExecuteProposal();
        vm.mockCall(_VERIFIER, abi.encodeWithSelector(IVerifier.verifyProof.selector), abi.encode(true));
        (bytes32 root, bytes32 nullifier) = _deposit(_pool001);
        uint256 recipientBefore = _recipient.balance;

        vm.prank(_recipient);
        _pool001.withdraw("", root, nullifier, payable(_recipient), payable(address(0)), 0, 0.00006 ether);

        assertEq(_recipient.balance - recipientBefore, _DENOM_001 - 0.00006 ether, "recipient paid, fee deducted");
        assertEq(_pool001.accruedProtocolFees(), 0.00006 ether, "fee kept in the pool");
        assertEq(_STAKING.balance, 0, "staking not paid yet");

        // Nothing can be forwarded while the staking contract rejects ETH, and nothing is lost by trying.
        vm.expectRevert(bytes("payment to STAKING_REWARDS did not go thru"));
        _pool001.sweepProtocolFees();
        assertEq(_pool001.accruedProtocolFees(), 0.00006 ether, "still in the pool");

        _upgradeStaking();
        vm.prank(makeAddr("anyone"));
        _pool001.sweepProtocolFees();

        assertEq(_STAKING.balance, 0.00006 ether, "fee reaches the staking contract after the upgrade");
        assertEq(_pool001.accruedProtocolFees(), 0, "nothing left in the pool");
        assertGt(IStakingRewards(_STAKING).checkEthReward(makeAddr("voter")), 0, "and is credited to lockers");
    }

    function testRegisteredRelayerWithdrawalWorksBeforeTheStakingUpgrade() external {
        // Relayed withdrawals do not need the staking upgrade: the DAO is paid in TORN burned from the
        // relayer's stake, which the staking contract shares as it does today.
        _forkAndDeployProposal();
        _passAndExecuteProposal();
        vm.mockCall(_VERIFIER, abi.encodeWithSelector(IVerifier.verifyProof.selector), abi.encode(true));
        (bytes32 root, bytes32 nullifier) = _deposit(_pool001);
        uint256 stakeBefore = _relayerRegistry.getRelayerBalance(_RELAYER_MASTER);
        uint256 recipientBefore = _recipient.balance;

        vm.prank(_RELAYER_MASTER);
        _router.withdraw(
            address(_pool001), "", root, nullifier, payable(_recipient), payable(_RELAYER_MASTER), 0.00004 ether, 0
        );

        assertLt(_relayerRegistry.getRelayerBalance(_RELAYER_MASTER), stakeBefore, "relayer stake burned");
        assertEq(_recipient.balance - recipientBefore, _DENOM_001 - 0.00004 ether, "user pays the relayer only");
        assertEq(_pool001.accruedProtocolFees(), 0, "the pool takes no ETH fee");
    }

    // --- Sweep (fallback when the staking contract could not take the fee) ---

    function testAnyoneCanSweepAccruedFeesToStaking() external {
        vm.etch(_STAKING, _REVERTING_CODE);
        for (uint256 i = 0; i < 2; i++) {
            (bytes32 root, bytes32 nullifier) = _deposit(_pool3);
            vm.prank(_recipient);
            _pool3.withdraw("", root, nullifier, payable(_recipient), payable(address(0)), 0, 0.018 ether);
        }
        uint256 accrued = _pool3.accruedProtocolFees();
        assertEq(accrued, 2 * _directFee(_pool3), "accrued");

        vm.expectRevert(bytes("payment to STAKING_REWARDS did not go thru"));
        _pool3.sweepProtocolFees();

        vm.etch(_STAKING, _stakingCode);
        uint256 poolBefore = address(_pool3).balance;
        vm.prank(makeAddr("anyone"));
        _pool3.sweepProtocolFees();

        assertEq(_STAKING.balance, _stakingBalanceBefore + accrued, "staking received fees");
        assertEq(address(_pool3).balance, poolBefore - accrued, "pool paid fees");
        assertEq(_pool3.accruedProtocolFees(), 0, "accrued reset");

        vm.expectRevert(bytes("Nothing to sweep"));
        _pool3.sweepProtocolFees();
    }

    function testSweepNeverTouchesDepositorFunds() external {
        // Pool keeps exactly one denomination per unspent note after a sweep.
        vm.etch(_STAKING, _REVERTING_CODE);
        _deposit(_pool3);
        (bytes32 root, bytes32 nullifier) = _deposit(_pool3);
        vm.prank(_recipient);
        _pool3.withdraw("", root, nullifier, payable(_recipient), payable(address(0)), 0, 0.018 ether);

        vm.etch(_STAKING, _stakingCode);
        _pool3.sweepProtocolFees();

        assertEq(address(_pool3).balance, _DENOM_3, "one unspent note left");
    }

    // --- Every pool charges the same rates ---

    function testEveryPoolChargesTheSameRates() external view {
        IFeeEnforcedTornado[5] memory pools = [_pool001, _pool003, _pool03, _pool3, _pool30];
        for (uint256 i = 0; i < pools.length; i++) {
            assertEq(pools[i].protocolFeePercentage(), 30, "0.3% protocol fee");
            assertEq(pools[i].directWithdrawPremiumPercentage(), 30, "0.3% premium");
            (,,,, uint32 registryFee) = _registry.instances(address(pools[i]));
            assertEq(registryFee, 30, "registered relayers burn 0.3% in TORN");
        }
        assertEq(_pool001.directWithdrawFee(), 0.00006 ether, "0.6% of 0.01 ETH");
        assertEq(_pool003.directWithdrawFee(), 0.00018 ether, "0.6% of 0.03 ETH");
        assertEq(_pool03.directWithdrawFee(), 0.0018 ether, "0.6% of 0.3 ETH");
        assertEq(_pool3.directWithdrawFee(), 0.018 ether, "0.6% of 3 ETH");
        assertEq(_pool30.directWithdrawFee(), 0.18 ether, "0.6% of 30 ETH");
    }

    function testSmallPoolDirectWithdrawPaysEthFee() external {
        (bytes32 root, bytes32 nullifier) = _deposit(_pool001);
        vm.prank(_recipient);
        _pool001.withdraw("", root, nullifier, payable(_recipient), payable(address(0)), 0, 0.00006 ether);

        _assertEthFeeCharged(_pool001, address(0), 0);
        assertEq(_recipient.balance, 0.00994 ether, "0.01 ETH - 0.6%");
    }

    function testSmallPoolCustomRelayerViaRouterPaysEthFee() external {
        address customRelayer = makeAddr("customRelayer");
        uint256 relayerFee = 0.0003 ether;
        (bytes32 root, bytes32 nullifier) = _deposit(_pool003);
        vm.prank(customRelayer);
        _router.withdraw(
            address(_pool003),
            "",
            root,
            nullifier,
            payable(_recipient),
            payable(customRelayer),
            relayerFee,
            0.00018 ether
        );

        _assertEthFeeCharged(_pool003, customRelayer, relayerFee);
    }

    function testSmallPoolRegisteredRelayerPaysTornNotEth() external {
        _assertRegisteredRelayerPaysTorn(_pool001, 0.00004 ether);
    }

    function testMidPoolRegisteredRelayerPaysTornNotEth() external {
        _assertRegisteredRelayerPaysTorn(_pool03, 0.0012 ether);
    }

    // --- Helpers ---

    /// @dev Direct withdrawal (no Router) naming a relayer, with a fixed gas budget.
    function _withdrawDirectNamingRelayer(IFeeEnforcedTornado pool, bytes32 root, bytes32 nullifier, uint256 gas)
        internal
    {
        vm.prank(_recipient);
        pool.withdraw{gas: gas}("", root, nullifier, payable(_recipient), payable(_RELAYER_MASTER), 0, 0.018 ether);
    }

    function _assertRegisteredRelayerPaysTorn(IFeeEnforcedTornado pool, uint256 relayerFee) internal {
        (bytes32 root, bytes32 nullifier) = _deposit(pool);
        assertTrue(pool.isRegisteredRelayerWithdrawal(_ROUTER, _RELAYER_MASTER), "router + master");

        uint256 stakeBefore = _relayerRegistry.getRelayerBalance(_RELAYER_MASTER);
        uint256 relayerEthBefore = _RELAYER_MASTER.balance;

        vm.prank(_worker);
        _router.withdraw(
            address(pool), "", root, nullifier, payable(_recipient), payable(_RELAYER_MASTER), relayerFee, 0
        );

        assertTrue(pool.isSpent(nullifier), "spent");
        assertEq(_recipient.balance, pool.denomination() - relayerFee, "recipient: denomination - relayer fee");
        assertEq(_RELAYER_MASTER.balance, relayerEthBefore + relayerFee, "relayer fee paid");
        assertEq(pool.accruedProtocolFees(), 0, "no ETH protocol fee accrued");
        assertEq(_STAKING.balance, _stakingBalanceBefore, "no ETH protocol fee paid");
        assertLt(_relayerRegistry.getRelayerBalance(_RELAYER_MASTER), stakeBefore, "TORN stake burned");
    }

    function _assertEthFeeCharged(IFeeEnforcedTornado pool, address relayer, uint256 relayerFee) internal view {
        uint256 protocolFee = _directFee(pool);
        assertEq(protocolFee, pool.directWithdrawFee(), "directWithdrawFee getter");
        assertEq(_STAKING.balance, _stakingBalanceBefore + protocolFee, "ETH protocol fee paid to staking");
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
        assertEq(_STAKING.balance, _stakingBalanceBefore, "staking not paid");
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
