// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IGovernance {
    function EXECUTION_DELAY() external view returns (uint256);
    function QUORUM_VOTES() external view returns (uint256);
    function VOTING_DELAY() external view returns (uint256);
    function VOTING_PERIOD() external view returns (uint256);
    function lockWithApproval(uint256 amount) external;
    function lockedBalance(address account) external view returns (uint256);
    function propose(address target, string memory description) external returns (uint256);
    function castVote(uint256 proposalId, bool support) external;
    function execute(uint256 proposalId) external;
    function state(uint256 proposalId) external view returns (uint8);
}

interface ITornadoInstance {
    function denomination() external view returns (uint256);
    function commitments(bytes32) external view returns (bool);
    function verifier() external view returns (address);
    function levels() external view returns (uint32);
    function operator() external view returns (address);
    function getLastRoot() external view returns (bytes32);
    function isSpent(bytes32 nullifierHash) external view returns (bool);
    function withdraw(
        bytes calldata proof,
        bytes32 root,
        bytes32 nullifierHash,
        address payable recipient,
        address payable relayer,
        uint256 fee,
        uint256 refund
    ) external payable;
}

interface IFeeEnforcedTornado is ITornadoInstance {
    function RELAYER_REGISTRY() external view returns (address);
    function GOVERNANCE() external view returns (address);
    function MAX_PROTOCOL_FEE_PERCENTAGE() external view returns (uint256);
    function protocolFeePercentage() external view returns (uint256);
    function directWithdrawPremiumPercentage() external view returns (uint256);
    function directWithdrawFeePercentage() external view returns (uint256);
    function directWithdrawFee() external view returns (uint256);
    function setProtocolFeePercentage(uint256 protocolFeePercentage) external;
    function MAX_DIRECT_WITHDRAW_PREMIUM_PERCENTAGE() external view returns (uint256);
    function setDirectWithdrawPremiumPercentage(uint256 premiumPercentage) external;
    function accruedProtocolFees() external view returns (uint256);
    function isRegisteredRelayerWithdrawal(address caller, address relayer) external view returns (bool);
    function sweepProtocolFees() external;
    function FEE_TRANSFER_GAS() external view returns (uint256);
}

interface IInstanceRegistry {
    enum InstanceState {
        DISABLED,
        ENABLED
    }

    function instances(address)
        external
        view
        returns (
            bool isERC20,
            address token,
            InstanceState state,
            uint24 uniswapPoolSwappingFee,
            uint32 protocolFeePercentage
        );

    function getAllInstanceAddresses() external view returns (address[] memory);
}

interface IRelayerRegistry {
    function tornadoRouter() external view returns (address);
    function workers(address) external view returns (address);
    function getRelayerBalance(address relayer) external view returns (uint256);
    function registerWorker(address relayer, address worker) external;
    function nullifyBalance(address relayer) external;
}

interface ITornadoRouter {
    function deposit(address _tornado, bytes32 _commitment, bytes calldata _encryptedNote) external payable;
    function withdraw(
        address _tornado,
        bytes calldata _proof,
        bytes32 _root,
        bytes32 _nullifierHash,
        address payable _recipient,
        address payable _relayer,
        uint256 _fee,
        uint256 _refund
    ) external payable;
}

/**
 * @dev Mainnet-fork fixture: spoof a large TORN holder and run the live governance cycle
 *      (propose → vote → execute) for `AddEthPoolsProposal`.
 */
abstract contract ProposalFixture is Test {
    address internal constant _TORN = 0x77777FeDdddFfC19Ff86DB637967013e6C6A116C;
    address internal constant _GOVERNANCE = 0x5efda50f22d34F262c29268506C5Fa42cB56A1Ce;
    address internal constant _INSTANCE_REGISTRY = 0xB20c66C4DE72433F3cE747b58B86830c459CA911;
    address internal constant _RELAYER_REGISTRY = 0x58E8dCC13BE9780fC42E8723D8EaD4CF46943dF2;
    address internal constant _ROUTER = 0xd90e2f925DA726b50C4Ed8D0Fb90Ad053324F31b;
    address internal constant _VERIFIER = 0xce172ce1F20EC0B3728c9965470eaf994A03557A;

    // Governance ProposalState enum (live contract).
    uint8 internal constant _STATE_AWAITING_EXECUTION = 4;
    uint8 internal constant _STATE_EXECUTED = 5;

    uint256 internal constant _DENOM_001 = 0.01 ether;
    uint256 internal constant _DENOM_003 = 0.03 ether;
    uint256 internal constant _DENOM_03 = 0.3 ether;
    uint256 internal constant _DENOM_3 = 3 ether;
    uint256 internal constant _DENOM_30 = 30 ether;

    // BN254 scalar field — Tornado commitments must be field elements.
    uint256 internal constant _FIELD_SIZE =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

    IGovernance internal constant _gov = IGovernance(_GOVERNANCE);
    IInstanceRegistry internal constant _registry = IInstanceRegistry(_INSTANCE_REGISTRY);
    IRelayerRegistry internal constant _relayerRegistry = IRelayerRegistry(_RELAYER_REGISTRY);
    ITornadoRouter internal constant _router = ITornadoRouter(_ROUTER);
    IERC20 internal constant _torn = IERC20(_TORN);

    uint256 internal _forkId;
    address internal _proposal;

    function _forkAndDeployProposal() internal {
        string memory rpc = vm.envOr("ETH_RPC_URL", string("https://ethereum-rpc.publicnode.com"));
        _forkId = vm.createSelectFork(rpc);
        _proposal = deployCode("AddEthPoolsProposal.sol:AddEthPoolsProposal");
    }

    /// @dev Runs propose → vote → execute and returns the number of registry instances before execution.
    function _passAndExecuteProposal() internal returns (uint256 addressesBefore) {
        addressesBefore = _registry.getAllInstanceAddresses().length;
        _passAndExecute(_proposal, "Add 0.01, 0.03, 0.3, 3, and 30 ETH Tornado Cash anonymity pools");
    }

    /// @dev Live governance cycle for any proposal contract, voted by a spoofed quorum-sized TORN holder.
    function _passAndExecute(address proposal, string memory description) internal {
        // --- Spoof a large TORN holder with enough locked power for quorum ---
        address voter = makeAddr("voter");
        uint256 lockAmount = _gov.QUORUM_VOTES();
        if (_gov.lockedBalance(voter) < lockAmount) {
            deal(_TORN, voter, lockAmount);
            vm.startPrank(voter);
            assertTrue(_torn.approve(_GOVERNANCE, lockAmount));
            _gov.lockWithApproval(lockAmount);
            vm.stopPrank();
        }
        assertGe(_gov.lockedBalance(voter), lockAmount);

        vm.startPrank(voter);
        // --- Propose ---
        uint256 proposalId = _gov.propose(proposal, description);

        // --- Fast-forward past voting delay, cast FOR vote ---
        vm.warp(block.timestamp + _gov.VOTING_DELAY() + 1);
        _gov.castVote(proposalId, true);

        // --- Fast-forward past voting period + execution timelock ---
        vm.warp(block.timestamp + _gov.VOTING_PERIOD() + _gov.EXECUTION_DELAY() + 1);
        assertEq(_gov.state(proposalId), _STATE_AWAITING_EXECUTION);

        _gov.execute(proposalId);
        assertEq(_gov.state(proposalId), _STATE_EXECUTED);
        vm.stopPrank();
    }

    function _depositViaRouter(address depositor, address pool, uint256 denomination, string memory tag)
        internal
        returns (bytes32 commitment)
    {
        commitment = bytes32(uint256(keccak256(bytes(tag))) % _FIELD_SIZE);
        deal(depositor, denomination);

        uint256 balBefore = pool.balance;
        vm.prank(depositor);
        _router.deposit{value: denomination}(pool, commitment, "");

        assertEq(pool.balance, balBefore + denomination, "pool balance");
        assertTrue(ITornadoInstance(pool).commitments(commitment), "commitment missing");
    }

    function _findNewPool(address[] memory all, uint256 startIndex, uint256 denomination)
        internal
        view
        returns (address)
    {
        for (uint256 i = startIndex; i < all.length; i++) {
            if (ITornadoInstance(all[i]).denomination() == denomination) {
                return all[i];
            }
        }
        revert("pool not found");
    }
}
