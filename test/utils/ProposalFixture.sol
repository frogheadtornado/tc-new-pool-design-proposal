// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

interface IERC20 {
    function totalSupply() external view returns (uint256);
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
    function unlock(uint256 amount) external;
    function lockedBalance(address account) external view returns (uint256);
    function userVault() external view returns (address);
    function propose(address target, string memory description) external returns (uint256);
    function castVote(uint256 proposalId, bool support) external;
    function execute(uint256 proposalId) external;
    function state(uint256 proposalId) external view returns (uint8);
}

interface ITornadoInstance {
    function denomination() external view returns (uint256);
    function deposit(bytes32 commitment) external payable;
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
    function STAKING_REWARDS() external view returns (address);
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
    function REGISTRY_CALL_GAS() external view returns (uint256);
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

    struct Instance {
        bool isERC20;
        address token;
        InstanceState state;
        uint24 uniswapPoolSwappingFee;
        uint32 protocolFeePercentage;
    }

    struct Tornado {
        address addr;
        Instance instance;
    }

    function updateInstance(Tornado calldata tornado) external;
}

interface IRelayerRegistry {
    function tornadoRouter() external view returns (address);
    function workers(address) external view returns (address);
    function getRelayerBalance(address relayer) external view returns (uint256);
    function registerWorker(address relayer, address worker) external;
    function nullifyBalance(address relayer) external;
}

/// @dev What Governance delegatecalls on a proposal contract.
interface IProposal {
    function executeProposal() external;
}

/// @dev The staking proxy's own function, callable by its admin only: Governance.
interface IStakingProxy {
    function upgradeTo(address newImplementation) external;
}

interface IFeeManager {
    function calculatePoolFee(address instance) external view returns (uint160);
    function updateFee(address instance) external;
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
 * @dev Mainnet-fork fixture: deploy the only thing that must exist before the vote, the proposal
 *      contract `AddEthPoolsProposal`, then spoof a large TORN holder and run the live governance
 *      cycle (propose → vote → execute). Execution deploys the 0.01 ETH pool.
 *      The staking contract is upgraded by a later proposal; `_upgradeStaking()` puts a fork in the
 *      state that proposal leaves.
 */
abstract contract ProposalFixture is Test {
    address internal constant _TORN = 0x77777FeDdddFfC19Ff86DB637967013e6C6A116C;
    address internal constant _GOVERNANCE = 0x5efda50f22d34F262c29268506C5Fa42cB56A1Ce;
    address internal constant _INSTANCE_REGISTRY = 0xB20c66C4DE72433F3cE747b58B86830c459CA911;
    address internal constant _RELAYER_REGISTRY = 0x58E8dCC13BE9780fC42E8723D8EaD4CF46943dF2;
    address internal constant _ROUTER = 0xd90e2f925DA726b50C4Ed8D0Fb90Ad053324F31b;
    address internal constant _VERIFIER = 0xce172ce1F20EC0B3728c9965470eaf994A03557A;
    address internal constant _STAKING = 0x5B3f656C80E8ddb9ec01Dd9018815576E9238c29;
    address internal constant _FEE_MANAGER = 0x5f6c97C6AD7bdd0AE7E0Dd4ca33A4ED3fDabD4D7;
    address internal constant _LEGACY_1_ETH_POOL = 0x47CE0C6eD5B0Ce3d3A51fdb1C52DC66a7c3c2936;

    /// @dev `ratioConstant` of the live staking implementation; the new one must be built with it.
    uint256 internal constant _STAKING_RATIO_CONSTANT = 9999997526814999108992673;

    // Governance ProposalState enum (live contract).
    uint8 internal constant _STATE_AWAITING_EXECUTION = 4;
    uint8 internal constant _STATE_EXECUTED = 5;

    uint256 internal constant _DENOM_001 = 0.01 ether;
    uint256 internal constant _DENOM_003 = 0.03 ether;
    uint256 internal constant _DENOM_03 = 0.3 ether;
    uint256 internal constant _DENOM_3 = 3 ether;
    uint256 internal constant _DENOM_30 = 30 ether;

    string internal constant _DESCRIPTION = "Add a 0.01 ETH pool with enforced fees";

    // BN254 scalar field — Tornado commitments must be field elements.
    uint256 internal constant _FIELD_SIZE =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

    IGovernance internal constant _gov = IGovernance(_GOVERNANCE);
    IInstanceRegistry internal constant _registry = IInstanceRegistry(_INSTANCE_REGISTRY);
    IRelayerRegistry internal constant _relayerRegistry = IRelayerRegistry(_RELAYER_REGISTRY);
    ITornadoRouter internal constant _router = ITornadoRouter(_ROUTER);
    IERC20 internal constant _torn = IERC20(_TORN);

    uint256 internal _forkId;
    /// @dev `AddEthPoolsProposal`, the contract passed to Governance.propose.
    address internal _proposal;
    IFeeEnforcedTornado internal _pool001;
    IFeeEnforcedTornado internal _pool003;
    IFeeEnforcedTornado internal _pool03;
    IFeeEnforcedTornado internal _pool3;
    IFeeEnforcedTornado internal _pool30;

    /// @dev Forks the latest block, or `FORK_BLOCK` when set (needs an archive RPC). Pin a block from
    ///      before the proposal's execution to run the suite once it has been executed on mainnet.
    function _fork() internal {
        string memory rpc = vm.envOr("ETH_RPC_URL", string("https://ethereum-rpc.publicnode.com"));
        uint256 blockNumber = vm.envOr("FORK_BLOCK", uint256(0));
        _forkId = blockNumber == 0 ? vm.createSelectFork(rpc) : vm.createSelectFork(rpc, blockNumber);
    }

    function _forkAndDeployProposal() internal {
        _fork();
        _deployProposal();
    }

    /// @dev The proposal: one contract. Nothing else exists before the vote: the proposal deploys the
    ///      pool when it is executed.
    function _deployProposal() internal {
        _proposal = deployCode("AddEthPoolsProposal.sol:AddEthPoolsProposal");
    }

    /// @dev Where the next contract created by Governance goes. The proposal runs as Governance, so
    ///      this is the pool's address if nothing else is created by Governance before.
    function _nextContractOfGovernance() internal view returns (address) {
        return vm.computeCreateAddress(_GOVERNANCE, vm.getNonce(_GOVERNANCE));
    }

    /// @dev What the later staking proposal does, without the vote: deploy the new implementation with
    ///      the values of the live one, and upgrade the proxy as Governance.
    function _upgradeStaking() internal returns (address implementation) {
        implementation = deployCode(
            "TornadoStakingRewards.sol:TornadoStakingRewards",
            abi.encode(_GOVERNANCE, _TORN, _RELAYER_REGISTRY, _STAKING_RATIO_CONSTANT)
        );
        vm.prank(_GOVERNANCE);
        IStakingProxy(_STAKING).upgradeTo(implementation);
    }

    /// @dev The proposal adds only the 0.01 ETH pool. To test the pool contract at larger amounts too,
    ///      this deploys the same code for 0.03, 0.3, 3 and 30 ETH and registers it the way a later
    ///      proposal would: as Governance, with the same fees, refreshing the TORN fee.
    function _addLargerPoolsAsGovernance() internal {
        _pool003 = _deployPool(_DENOM_003);
        _pool03 = _deployPool(_DENOM_03);
        _pool3 = _deployPool(_DENOM_3);
        _pool30 = _deployPool(_DENOM_30);
        IFeeEnforcedTornado[4] memory larger = [_pool003, _pool03, _pool3, _pool30];
        for (uint256 i = 0; i < larger.length; i++) {
            vm.prank(_GOVERNANCE);
            _registry.updateInstance(
                IInstanceRegistry.Tornado({
                    addr: address(larger[i]),
                    instance: IInstanceRegistry.Instance({
                        isERC20: false,
                        token: address(0),
                        state: IInstanceRegistry.InstanceState.ENABLED,
                        uniswapPoolSwappingFee: 0,
                        protocolFeePercentage: 30
                    })
                })
            );
            IFeeManager(_FEE_MANAGER).updateFee(address(larger[i]));
        }
    }

    /// @dev A pool deployed by the test itself (the proposal deploys only the 0.01 ETH one). Every pool
    ///      starts with a 0.3% protocol fee and a 0.3% premium.
    function _deployPool(uint256 denomination) internal returns (IFeeEnforcedTornado) {
        return IFeeEnforcedTornado(
            deployCode(
                "FeeEnforcedTornado_eth.sol:FeeEnforcedTornado_eth",
                abi.encode(_VERIFIER, denomination, uint32(20), address(0), uint256(30), uint256(30))
            )
        );
    }

    /// @dev Runs propose → vote → execute for `AddEthPoolsProposal`. The pool it deploys is the
    ///      instance it adds to the registry.
    function _passAndExecuteProposal() internal {
        uint256 instancesBefore = _registry.getAllInstanceAddresses().length;
        _passAndExecute(_proposal, _DESCRIPTION);
        address[] memory instances = _registry.getAllInstanceAddresses();
        assertEq(instances.length, instancesBefore + 1, "the proposal adds one instance");
        _pool001 = IFeeEnforcedTornado(instances[instancesBefore]);
    }

    /// @dev Live governance cycle for any proposal contract, voted by a spoofed quorum-sized TORN holder.
    function _passAndExecute(address proposal, string memory description) internal {
        uint256 proposalId = _pass(proposal, description);
        _gov.execute(proposalId);
        assertEq(_gov.state(proposalId), _STATE_EXECUTED);
    }

    /// @dev propose → vote → wait out the timelock: leaves the proposal ready for anyone to execute.
    function _pass(address proposal, string memory description) internal returns (uint256 proposalId) {
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
        proposalId = _gov.propose(proposal, description);

        // --- Fast-forward past voting delay, cast FOR vote ---
        vm.warp(block.timestamp + _gov.VOTING_DELAY() + 1);
        _gov.castVote(proposalId, true);

        // --- Fast-forward past voting period + execution timelock ---
        vm.warp(block.timestamp + _gov.VOTING_PERIOD() + _gov.EXECUTION_DELAY() + 1);
        assertEq(_gov.state(proposalId), _STATE_AWAITING_EXECUTION);
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
}
