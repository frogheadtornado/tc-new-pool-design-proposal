// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {ProposalFixture, ITornadoInstance, IGovernance, IERC20} from "./utils/ProposalFixture.sol";

interface IVerifier {
    function verifyProof(bytes memory proof, uint256[6] memory input) external returns (bool);
}

interface IStakingRewards {
    function ratioConstant() external view returns (uint256);
    function accumulatedRewardPerTorn() external view returns (uint256);
    function checkReward(address account) external view returns (uint256);
    function getReward() external;
    function addBurnRewards(uint256 amount) external;
    function addEthRewards() external payable;
    function checkEthReward(address account) external view returns (uint256);
    function getEthReward() external;
    function accumulatedRewardRateOnLastUpdate(address account) external view returns (uint256);
    function MAX_REWARD_TOKENS() external view returns (uint256);
    function addRewardToken(address token) external;
    function getRewardTokens() external view returns (address[] memory);
    function isRewardToken(address token) external view returns (bool);
    function addTokenRewards(address token) external;
    function tokenRewardsHeld(address token) external view returns (uint256);
    function checkTokenReward(address token, address account) external view returns (uint256);
    function getTokenReward(address token) external;
    function accumulatedAssetRewardPerTorn(address asset) external view returns (uint256);
    function checkpointCount(address account) external view returns (uint256);
    function getEthRewardUpTo(uint256 checkpoints) external;
    function getTokenRewardUpTo(address token, uint256 checkpoints) external;
}

interface IGovernanceLocks {
    function canWithdrawAfter(address account) external view returns (uint256);
    function torn() external view returns (address);
}

interface ITorn {
    function allowance(address owner, address spender) external view returns (uint256);
    function paused() external view returns (bool);
}

/// @dev A locker that is a contract. With `reenter` set it claims again while it is being paid.
contract ContractLocker {
    IStakingRewards private immutable _staking;
    bool private immutable _reenter;
    uint256 public reentered;

    constructor(IStakingRewards staking, bool reenter) {
        _staking = staking;
        _reenter = reenter;
    }

    function lock(IGovernance gov, IERC20 torn, uint256 amount) external {
        torn.approve(address(gov), amount);
        gov.lockWithApproval(amount);
    }

    function claim() external {
        _staking.getEthReward();
    }

    receive() external payable {
        if (_reenter && reentered == 0) {
            reentered = 1;
            _staking.getEthReward();
        }
    }
}

/// @dev A locker contract with no way to receive ETH.
contract NoEthLocker {
    function lock(IGovernance gov, IERC20 torn, uint256 amount) external {
        torn.approve(address(gov), amount);
        gov.lockWithApproval(amount);
    }

    function claim(IStakingRewards staking) external {
        staking.getEthReward();
    }
}

/// @dev A plain token.
contract PlainToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external virtual returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev A token that keeps 1% of every transfer, as USDT can be set to do.
contract FeeToken is PlainToken {
    function transfer(address to, uint256 amount) external override returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount - amount / 100;
        return true;
    }
}

/// @dev A token that can be frozen. From then on every call to it reverts.
contract FreezableToken {
    mapping(address => uint256) private _balances;
    bool public frozen;

    function mint(address to, uint256 amount) external {
        _balances[to] += amount;
    }

    function freeze() external {
        frozen = true;
    }

    function balanceOf(address account) external view returns (uint256) {
        require(!frozen, "frozen");
        return _balances[account];
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(!frozen, "frozen");
        _balances[msg.sender] -= amount;
        _balances[to] += amount;
        return true;
    }
}

/// @dev A locker that picks how much gas its lock or unlock gets. Before that, in the same
///      transaction, it reads or writes everything Governance uses once the reward update is over
///      (its own locked balance cannot be written without a reward update). Storage that was already
///      touched is cheaper, so as little gas as possible is needed there: the cheapest way to try to
///      change a locked balance while the reward update fails.
contract GasPickingLocker {
    IGovernance private immutable _gov;
    IERC20 private immutable _torn;

    constructor(IGovernance gov, IERC20 torn) {
        _gov = gov;
        _torn = torn;
        torn.approve(address(gov), type(uint256).max);
    }

    function lock(uint256 amount) external {
        _gov.lockWithApproval(amount);
    }

    function lockWithGas(uint256 amount, uint256 gasLimit) external returns (bool done) {
        _touchAhead();
        (done,) = address(_gov).call{gas: gasLimit}(abi.encodeCall(IGovernance.lockWithApproval, (amount)));
    }

    function unlockWithGas(uint256 amount, uint256 gasLimit) external returns (bool done) {
        _touchAhead();
        (done,) = address(_gov).call{gas: gasLimit}(abi.encodeCall(IGovernance.unlock, (amount)));
    }

    function _touchAhead() private {
        address vault = _gov.userVault();
        require(vault.code.length > 0, "no vault");
        _gov.lockedBalance(address(this));
        IGovernanceLocks(address(_gov)).canWithdrawAfter(address(this));
        IGovernanceLocks(address(_gov)).torn();
        ITorn(address(_torn)).paused();
        // Writes: the TORN balances of this contract and of the vault, and the allowance of Governance.
        _torn.transfer(vault, 1);
        _torn.approve(address(_gov), type(uint256).max - 1);
    }
}

/**
 * @dev Mainnet-fork tests for the new TornadoStakingRewards implementation: ETH, and tokens added by
 *      Governance, are split among TORN lockers the way TORN rewards are, and the existing TORN
 *      rewards keep working.
 *      Governance, its vault, TORN, the RelayerRegistry and the Router are the live contracts. The
 *      staking proxy is upgraded the way the staking proposal does it: a new implementation is deployed
 *      and Governance calls `upgradeTo` (`_upgradeStaking()` in the fixture).
 */
contract TornadoStakingRewardsTest is ProposalFixture {
    /// @dev Live registered relayer master (workers[master] == master) with ample stake.
    address private constant _RELAYER_MASTER = 0x4750BCfcC340AA4B31be7e71fa072716d28c29C5;
    /// @dev Rounding: the reward index and the per-account share each round down once.
    uint256 private constant _ROUNDING = 2;
    /// @dev The largest TORN locker on mainnet when this was written (306,474 TORN locked).
    address private constant _REAL_LOCKER = 0x9C42EBDf0fA6fA0274aEEBf981613Dfa9c99BFF8;

    address private constant _DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    /// @dev 6 decimals, and `transfer` returns nothing.
    address private constant _USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    /// @dev `MAX_REWARD_TOKENS` of the new implementation (checked by testRewardTokenListIsCapped).
    uint256 private constant _MAX_REWARD_TOKENS = 4;
    /// @dev EIP-1967 implementation slot of the staking proxy.
    bytes32 private constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    event RewardUpdateSuccessful(address indexed account);

    IStakingRewards private constant _staking = IStakingRewards(_STAKING);

    address private _vault;
    address private _alice;
    address private _bob;
    address private _carol;
    address private _payer;

    function setUp() external {
        _fork();
        _vault = _gov.userVault();
        _alice = _freshAccount("alice");
        _bob = _freshAccount("bob");
        _carol = _freshAccount("carol");
        _payer = _freshAccount("payer");
    }

    // --- ETH rewards ---

    function testEthFeeIsSplitInProportionToLockedTorn() external {
        _upgradeStaking();
        _lock(_alice, 1_000 ether);
        _lock(_bob, 3_000 ether);
        uint256 totalLocked = _torn.balanceOf(_vault);

        _payEthRewards(1 ether);

        assertApproxEqAbs(_staking.checkEthReward(_alice), 1 ether * 1_000 ether / totalLocked, _ROUNDING, "alice");
        assertApproxEqAbs(_staking.checkEthReward(_bob), 1 ether * 3_000 ether / totalLocked, _ROUNDING, "bob");
        assertEq(_STAKING.balance, 1 ether, "staking holds the ETH until it is claimed");
    }

    function testThreeLockersShareFeesByStake() external {
        // With the vault emptied first, the three lockers below stand for the whole locked supply:
        // 10%, 30% and 60% of 10,000 TORN. (The index divides by the vault's TORN, so the accounts
        // really locked on mainnet are left out of this model.)
        _upgradeStaking();
        deal(_TORN, _vault, 0);
        _lock(_alice, 1_000 ether);
        _lock(_bob, 3_000 ether);
        _lock(_carol, 6_000 ether);

        _payEthRewards(1 ether);
        _payEthRewards(2 ether);

        assertApproxEqAbs(_staking.checkEthReward(_alice), 0.3 ether, 2 * _ROUNDING, "10% of 3 ETH");
        assertApproxEqAbs(_staking.checkEthReward(_bob), 0.9 ether, 2 * _ROUNDING, "30% of 3 ETH");
        assertApproxEqAbs(_staking.checkEthReward(_carol), 1.8 ether, 2 * _ROUNDING, "60% of 3 ETH");

        _claimEth(_alice);
        _claimEth(_bob);
        _claimEth(_carol);
        uint256 claimed = _alice.balance + _bob.balance + _carol.balance;
        assertLe(claimed, 3 ether, "the lockers together never claim more ETH than was paid in");
        assertEq(_STAKING.balance, 3 ether - claimed, "only rounding dust is left");
        assertLe(_STAKING.balance, 6 * _ROUNDING, "dust is a few wei");
    }

    function testLockerJoiningLaterEarnsNothingFromEarlierFees() external {
        _upgradeStaking();
        _lock(_alice, 1_000 ether);
        _payEthRewards(1 ether);

        _lock(_bob, 3_000 ether);
        assertEq(_staking.checkEthReward(_bob), 0, "bob locked after the fee was paid");

        uint256 totalLocked = _torn.balanceOf(_vault);
        _payEthRewards(2 ether);
        assertApproxEqAbs(
            _staking.checkEthReward(_bob), 2 ether * 3_000 ether / totalLocked, _ROUNDING, "later fee only"
        );
    }

    function testLockingMoreDoesNotRepriceEarlierFees() external {
        _upgradeStaking();
        _lock(_alice, 1_000 ether);
        uint256 totalLocked = _torn.balanceOf(_vault);
        _payEthRewards(1 ether);

        _lock(_alice, 9_000 ether);

        assertEq(_gov.lockedBalance(_alice), 10_000 ether, "alice now locks ten times more");
        assertApproxEqAbs(
            _staking.checkEthReward(_alice),
            1 ether * 1_000 ether / totalLocked,
            _ROUNDING,
            "the earlier fee is still shared on the 1,000 TORN locked when it arrived"
        );
    }

    function testUnlockingKeepsEthEarnedSoFar() external {
        _upgradeStaking();
        _lock(_alice, 1_000 ether);
        uint256 totalLocked = _torn.balanceOf(_vault);
        _payEthRewards(1 ether);
        uint256 earned = 1 ether * 1_000 ether / totalLocked;

        vm.prank(_alice);
        _gov.unlock(1_000 ether);
        _payEthRewards(1 ether);

        assertApproxEqAbs(_staking.checkEthReward(_alice), earned, _ROUNDING, "kept, and nothing new once unlocked");
        _claimEth(_alice);
        assertApproxEqAbs(_alice.balance, earned, _ROUNDING, "still claimable after unlocking");
        uint256 paid = _alice.balance;
        _claimEth(_alice);
        assertEq(_alice.balance, paid, "a second claim pays nothing");
    }

    function testGetEthRewardPaysTheCallerOnce() external {
        _upgradeStaking();
        _lock(_alice, 1_000 ether);
        _lock(_bob, 3_000 ether);
        uint256 totalLocked = _torn.balanceOf(_vault);
        _payEthRewards(1 ether);
        uint256 aliceShare = 1 ether * 1_000 ether / totalLocked;

        _claimEth(_alice);
        assertApproxEqAbs(_alice.balance, aliceShare, _ROUNDING, "alice paid");
        assertEq(_staking.checkEthReward(_alice), 0, "nothing left for alice");

        _claimEth(_alice);
        assertApproxEqAbs(_alice.balance, aliceShare, _ROUNDING, "a second claim pays nothing");
        assertApproxEqAbs(
            _staking.checkEthReward(_bob), 1 ether * 3_000 ether / totalLocked, _ROUNDING, "bob's share untouched"
        );
    }

    /// forge-config: default.fuzz.runs = 24
    function testFuzzLockersNeverClaimMoreThanWasPaidIn(uint256 seed) external {
        // Random locks, unlocks, payments and claims by three lockers who stand for the whole locked
        // supply (vault emptied first, as above).
        _upgradeStaking();
        deal(_TORN, _vault, 0);
        address[3] memory lockers = [_alice, _bob, _carol];
        uint256 paid;
        // What each locker is owed, worked out here on its own: its share of each fee when it arrived.
        uint256[3] memory owed;

        for (uint256 step = 0; step < 16; step++) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            address locker = lockers[seed % 3];
            uint256 action = (seed >> 8) % 4;
            if (action == 0) {
                _lock(locker, 1 ether + (seed >> 16) % 5_000 ether);
            } else if (action == 1) {
                uint256 locked = _gov.lockedBalance(locker);
                if (locked > 0) {
                    vm.prank(locker);
                    _gov.unlock(1 + (seed >> 16) % locked);
                }
            } else if (action == 2) {
                uint256 total = _torn.balanceOf(_vault);
                if (total > 0) {
                    uint256 fee = 1 + (seed >> 16) % 3 ether;
                    _payEthRewards(fee);
                    paid += fee;
                    for (uint256 i = 0; i < 3; i++) {
                        owed[i] += fee * _gov.lockedBalance(lockers[i]) / total;
                    }
                }
            } else {
                _claimEth(locker);
            }
        }
        for (uint256 i = 0; i < 3; i++) {
            assertApproxEqAbs(
                lockers[i].balance + _staking.checkEthReward(lockers[i]),
                owed[i],
                64,
                "a locker's ETH is not what it earned"
            );
        }

        uint256 claimed = _alice.balance + _bob.balance + _carol.balance;
        uint256 claimable =
            _staking.checkEthReward(_alice) + _staking.checkEthReward(_bob) + _staking.checkEthReward(_carol);
        assertEq(_STAKING.balance, paid - claimed, "staking holds exactly what is not claimed yet");
        assertLe(claimed + claimable, paid, "claimed plus claimable never exceeds what was paid in");
        assertLe(paid - claimed - claimable, 100, "and only rounding dust is left over");
    }

    function testClaimingAgainWhileBeingPaidPaysOnce() external {
        _upgradeStaking();
        ContractLocker locker = new ContractLocker(_staking, true);
        deal(_TORN, address(locker), 1_000 ether);
        locker.lock(_gov, _torn, 1_000 ether);
        uint256 totalLocked = _torn.balanceOf(_vault);
        _payEthRewards(1 ether);

        locker.claim();

        assertEq(locker.reentered(), 1, "the locker did call back");
        assertApproxEqAbs(address(locker).balance, 1 ether * 1_000 ether / totalLocked, _ROUNDING, "paid once");
        assertEq(_staking.checkEthReward(address(locker)), 0, "nothing left to claim");
    }

    function testLockerThatCannotReceiveEthCannotClaim() external {
        // A known limit: getEthReward pays the caller, so a contract with no payable entry point
        // cannot collect. Its share stays recorded.
        _upgradeStaking();
        NoEthLocker locker = new NoEthLocker();
        deal(_TORN, address(locker), 1_000 ether);
        locker.lock(_gov, _torn, 1_000 ether);
        uint256 totalLocked = _torn.balanceOf(_vault);
        _payEthRewards(1 ether);

        vm.expectRevert(bytes("ETH transfer failed"));
        locker.claim(_staking);

        assertApproxEqAbs(
            _staking.checkEthReward(address(locker)), 1 ether * 1_000 ether / totalLocked, _ROUNDING, "still recorded"
        );
    }

    function testPlainEthTransferIsRejected() external {
        // ETH that arrives without addEthRewards() would never be credited to lockers.
        _upgradeStaking();
        deal(_payer, 1 ether);
        vm.prank(_payer);
        (bool accepted,) = _STAKING.call{value: 1 ether}("");
        assertFalse(accepted, "plain transfer accepted");
    }

    function testAddEthRewardsRevertsWhenNoTornIsLocked() external {
        // The payer keeps its ETH (a pool then accrues the fee and retries later) instead of
        // paying into an index nobody can claim from.
        _upgradeStaking();
        deal(_TORN, _vault, 0);
        deal(_payer, 1 ether);
        vm.prank(_payer);
        vm.expectRevert(bytes("SafeMath: division by zero"));
        _staking.addEthRewards{value: 1 ether}();
    }

    // --- Token rewards ---

    function testOnlyGovernanceAddsRewardTokens() external {
        _upgradeStaking();
        assertEq(_staking.getRewardTokens().length, 0, "the upgrade adds no reward token");

        vm.expectRevert(bytes("only governance"));
        _staking.addRewardToken(_DAI);

        vm.prank(_GOVERNANCE);
        _staking.addRewardToken(_DAI);

        address[] memory tokens = _staking.getRewardTokens();
        assertEq(tokens.length, 1, "one reward token");
        assertEq(tokens[0], _DAI, "DAI");
        assertTrue(_staking.isRewardToken(_DAI), "DAI is a reward token");
    }

    function testTornCannotBeARewardToken() external {
        // The TORN held by the staking contract is the relayers' stake and the lockers' TORN rewards.
        // As a reward token all of it would be shared out again.
        _upgradeStaking();
        vm.prank(_GOVERNANCE);
        vm.expectRevert(bytes("TORN has its own rewards"));
        _staking.addRewardToken(_TORN);
    }

    function testRewardTokenMustBeAContract() external {
        _upgradeStaking();
        vm.startPrank(_GOVERNANCE);
        vm.expectRevert(bytes("reward token is not a contract"));
        _staking.addRewardToken(address(0));
        vm.expectRevert(bytes("reward token is not a contract"));
        _staking.addRewardToken(_alice);
        vm.stopPrank();
    }

    function testRewardTokenCannotBeAddedTwice() external {
        _upgradeStaking();
        vm.startPrank(_GOVERNANCE);
        _staking.addRewardToken(_DAI);
        vm.expectRevert(bytes("reward token already added"));
        _staking.addRewardToken(_DAI);
        vm.stopPrank();
    }

    function testRewardTokenListIsCapped() external {
        // A lock or unlock notes down the state of every asset in one storage word, which has room
        // for ETH and this many tokens.
        _upgradeStaking();
        uint256 max = _staking.MAX_REWARD_TOKENS();
        assertEq(max, _MAX_REWARD_TOKENS, "ETH and four tokens fit in a checkpoint");
        vm.startPrank(_GOVERNANCE);
        for (uint256 i = 0; i < max; i++) {
            _staking.addRewardToken(address(new PlainToken()));
        }
        address oneTooMany = address(new PlainToken());
        vm.expectRevert(bytes("too many reward tokens"));
        _staking.addRewardToken(oneTooMany);
        vm.stopPrank();
        assertEq(_staking.getRewardTokens().length, max, "list is full");
    }

    function testTokenFeeIsSplitInProportionToLockedTorn() external {
        _upgradeStaking();
        _addRewardToken(_DAI);
        _lock(_alice, 1_000 ether);
        _lock(_bob, 3_000 ether);
        uint256 totalLocked = _torn.balanceOf(_vault);

        _payTokenRewards(_DAI, 1_000 ether);

        assertApproxEqAbs(
            _staking.checkTokenReward(_DAI, _alice), 1_000 ether * 1_000 ether / totalLocked, _ROUNDING, "alice"
        );
        assertApproxEqAbs(
            _staking.checkTokenReward(_DAI, _bob), 1_000 ether * 3_000 ether / totalLocked, _ROUNDING, "bob"
        );
        assertEq(IERC20(_DAI).balanceOf(_STAKING), 1_000 ether, "staking holds the DAI until it is claimed");
        assertEq(_staking.checkEthReward(_alice), 0, "a fee in DAI pays no ETH");
        assertEq(_staking.checkReward(_alice), 0, "and no TORN");
    }

    function testTokenRewardIsPaidInTheTokenOnce() external {
        _upgradeStaking();
        _addRewardToken(_DAI);
        _lock(_alice, 1_000 ether);
        _lock(_bob, 3_000 ether);
        uint256 totalLocked = _torn.balanceOf(_vault);
        _payTokenRewards(_DAI, 1_000 ether);
        uint256 aliceShare = 1_000 ether * 1_000 ether / totalLocked;

        _claimToken(_DAI, _alice);
        assertApproxEqAbs(IERC20(_DAI).balanceOf(_alice), aliceShare, _ROUNDING, "alice paid in DAI");
        assertEq(_staking.checkTokenReward(_DAI, _alice), 0, "nothing left for alice");

        _claimToken(_DAI, _alice);
        assertApproxEqAbs(IERC20(_DAI).balanceOf(_alice), aliceShare, _ROUNDING, "a second claim pays nothing");
        assertApproxEqAbs(
            _staking.checkTokenReward(_DAI, _bob),
            1_000 ether * 3_000 ether / totalLocked,
            _ROUNDING,
            "bob's share untouched"
        );
    }

    function testUsdtRewardsArePaidAndClaimed() external {
        // USDT has 6 decimals and its `transfer` returns nothing.
        _upgradeStaking();
        _addRewardToken(_USDT);
        _lock(_alice, 1_000 ether);
        uint256 totalLocked = _torn.balanceOf(_vault);

        _payTokenRewards(_USDT, 500e6);

        uint256 aliceShare = 500e6 * 1_000 ether / totalLocked;
        assertGt(aliceShare, 0, "the share is not rounded away");
        assertApproxEqAbs(_staking.checkTokenReward(_USDT, _alice), aliceShare, _ROUNDING, "alice's USDT");
        _claimToken(_USDT, _alice);
        assertApproxEqAbs(IERC20(_USDT).balanceOf(_alice), aliceShare, _ROUNDING, "alice paid in USDT");
        assertEq(
            IERC20(_USDT).balanceOf(_STAKING), 500e6 - IERC20(_USDT).balanceOf(_alice), "the rest stays for the others"
        );
    }

    function testLockerJoiningLaterEarnsNothingFromEarlierTokenFees() external {
        _upgradeStaking();
        _addRewardToken(_DAI);
        _lock(_alice, 1_000 ether);
        _payTokenRewards(_DAI, 1_000 ether);

        _lock(_bob, 3_000 ether);
        assertEq(_staking.checkTokenReward(_DAI, _bob), 0, "bob locked after the fee was paid");

        uint256 totalLocked = _torn.balanceOf(_vault);
        _payTokenRewards(_DAI, 2_000 ether);
        assertApproxEqAbs(
            _staking.checkTokenReward(_DAI, _bob), 2_000 ether * 3_000 ether / totalLocked, _ROUNDING, "later fee only"
        );
    }

    function testLockingMoreDoesNotRepriceEarlierTokenFees() external {
        _upgradeStaking();
        _addRewardToken(_DAI);
        _addRewardToken(_USDT);
        _lock(_alice, 1_000 ether);
        uint256 totalLocked = _torn.balanceOf(_vault);
        _payTokenRewards(_DAI, 1_000 ether);
        _payTokenRewards(_USDT, 500e6);

        _lock(_alice, 9_000 ether);

        assertEq(_gov.lockedBalance(_alice), 10_000 ether, "alice now locks ten times more");
        assertApproxEqAbs(
            _staking.checkTokenReward(_DAI, _alice),
            1_000 ether * 1_000 ether / totalLocked,
            _ROUNDING,
            "the earlier DAI fee is still shared on the 1,000 TORN locked when it arrived"
        );
        assertApproxEqAbs(
            _staking.checkTokenReward(_USDT, _alice), 500e6 * 1_000 ether / totalLocked, _ROUNDING, "and so is the USDT"
        );
    }

    function testUnlockingKeepsTokensEarnedSoFar() external {
        _upgradeStaking();
        _addRewardToken(_DAI);
        _lock(_alice, 1_000 ether);
        uint256 totalLocked = _torn.balanceOf(_vault);
        _payTokenRewards(_DAI, 1_000 ether);
        uint256 earned = 1_000 ether * 1_000 ether / totalLocked;

        vm.prank(_alice);
        _gov.unlock(1_000 ether);
        _payTokenRewards(_DAI, 1_000 ether);

        assertApproxEqAbs(
            _staking.checkTokenReward(_DAI, _alice), earned, _ROUNDING, "kept, and nothing new once unlocked"
        );
        _claimToken(_DAI, _alice);
        assertApproxEqAbs(IERC20(_DAI).balanceOf(_alice), earned, _ROUNDING, "still claimable after unlocking");
    }

    function testTokensAreSharedOnlyOnce() external {
        _upgradeStaking();
        _addRewardToken(_DAI);
        _lock(_alice, 1_000 ether);
        _payTokenRewards(_DAI, 1_000 ether);
        uint256 shared = _staking.checkTokenReward(_DAI, _alice);

        _staking.addTokenRewards(_DAI);
        _staking.addTokenRewards(_DAI);

        assertEq(_staking.checkTokenReward(_DAI, _alice), shared, "telling it again shares nothing more");
        assertEq(_staking.tokenRewardsHeld(_DAI), 1_000 ether, "all the DAI held is accounted for");
    }

    function testTokensSentWithoutTellingAreSharedByTheNextCall() external {
        // The staking contract shares what it holds beyond what it already shared, whoever sent it
        // and whoever makes the call.
        _upgradeStaking();
        _addRewardToken(_DAI);
        _lock(_alice, 1_000 ether);
        uint256 totalLocked = _torn.balanceOf(_vault);

        deal(_DAI, _payer, 1_000 ether);
        _transferToken(_DAI, _payer, _STAKING, 1_000 ether);
        assertEq(_staking.checkTokenReward(_DAI, _alice), 0, "not shared yet");

        vm.prank(_carol);
        _staking.addTokenRewards(_DAI);
        assertApproxEqAbs(
            _staking.checkTokenReward(_DAI, _alice), 1_000 ether * 1_000 ether / totalLocked, _ROUNDING, "shared"
        );
    }

    function testTokensSentWhileNoTornIsLockedAreSharedLater() external {
        _upgradeStaking();
        _addRewardToken(_DAI);
        deal(_TORN, _vault, 0);
        deal(_DAI, _payer, 1_000 ether);
        _transferToken(_DAI, _payer, _STAKING, 1_000 ether);

        vm.expectRevert(bytes("SafeMath: division by zero"));
        _staking.addTokenRewards(_DAI);

        _lock(_alice, 1_000 ether);
        _staking.addTokenRewards(_DAI);
        assertApproxEqAbs(_staking.checkTokenReward(_DAI, _alice), 1_000 ether, _ROUNDING, "the only locker gets it");
    }

    function testTokensHeldBeforeTheTokenWasAddedAreShared() external {
        _upgradeStaking();
        _lock(_alice, 1_000 ether);
        uint256 totalLocked = _torn.balanceOf(_vault);
        deal(_DAI, _STAKING, 1_000 ether);

        vm.prank(_GOVERNANCE);
        _staking.addRewardToken(_DAI);
        _staking.addTokenRewards(_DAI);

        assertApproxEqAbs(
            _staking.checkTokenReward(_DAI, _alice), 1_000 ether * 1_000 ether / totalLocked, _ROUNDING, "shared"
        );
    }

    function testTokenThatIsNotARewardTokenIsRejected() external {
        _upgradeStaking();
        _lock(_alice, 1_000 ether);
        deal(_DAI, _STAKING, 1_000 ether);

        vm.expectRevert(bytes("not a reward token"));
        _staking.addTokenRewards(_DAI);

        vm.prank(_alice);
        vm.expectRevert(bytes("not a reward token"));
        _staking.getTokenReward(_DAI);

        // ETH is not claimed through the token functions either.
        vm.prank(_alice);
        vm.expectRevert(bytes("not a reward token"));
        _staking.getTokenReward(address(0));
    }

    function testEachAssetIsAccountedOnItsOwn() external {
        _upgradeStaking();
        _addRewardToken(_DAI);
        _addRewardToken(_USDT);
        _lock(_alice, 1_000 ether);
        uint256 totalLocked = _torn.balanceOf(_vault);

        _payEthRewards(1 ether);
        _payTokenRewards(_DAI, 1_000 ether);
        _payTokenRewards(_USDT, 500e6);
        vm.prank(_RELAYER_REGISTRY);
        _staking.addBurnRewards(500 ether);

        uint256 eth = 1 ether * 1_000 ether / totalLocked;
        uint256 dai = 1_000 ether * 1_000 ether / totalLocked;
        uint256 usdt = 500e6 * 1_000 ether / totalLocked;
        uint256 torn = 500 ether * 1_000 ether / totalLocked;
        assertApproxEqAbs(_staking.checkEthReward(_alice), eth, _ROUNDING, "ETH");
        assertApproxEqAbs(_staking.checkTokenReward(_DAI, _alice), dai, _ROUNDING, "DAI");
        assertApproxEqAbs(_staking.checkTokenReward(_USDT, _alice), usdt, _ROUNDING, "USDT");
        assertApproxEqAbs(_staking.checkReward(_alice), torn, _ROUNDING, "TORN");

        // Claiming one leaves the others as they were.
        _claimToken(_DAI, _alice);
        assertApproxEqAbs(IERC20(_DAI).balanceOf(_alice), dai, _ROUNDING, "DAI claimed");
        assertEq(_alice.balance, 0, "no ETH sent");
        assertApproxEqAbs(_staking.checkEthReward(_alice), eth, _ROUNDING, "ETH still claimable");
        assertApproxEqAbs(_staking.checkTokenReward(_USDT, _alice), usdt, _ROUNDING, "USDT still claimable");
        assertApproxEqAbs(_staking.checkReward(_alice), torn, _ROUNDING, "TORN still claimable");

        _claimEth(_alice);
        _claimToken(_USDT, _alice);
        vm.prank(_alice);
        _staking.getReward();
        assertApproxEqAbs(_alice.balance, eth, _ROUNDING, "ETH claimed");
        assertApproxEqAbs(IERC20(_USDT).balanceOf(_alice), usdt, _ROUNDING, "USDT claimed");
        assertApproxEqAbs(_torn.balanceOf(_alice), torn, _ROUNDING, "TORN claimed");
    }

    function testTokenWithATransferFeeIsSharedByWhatArrives() external {
        // Sharing the amount that was sent, instead of the amount that arrived, would promise the
        // lockers more than the staking contract holds.
        _upgradeStaking();
        deal(_TORN, _vault, 0);
        FeeToken token = new FeeToken();
        vm.prank(_GOVERNANCE);
        _staking.addRewardToken(address(token));
        _lock(_alice, 1_000 ether);
        _lock(_bob, 3_000 ether);

        token.mint(_payer, 1_000 ether);
        _transferToken(address(token), _payer, _STAKING, 1_000 ether);
        _staking.addTokenRewards(address(token));

        assertEq(token.balanceOf(_STAKING), 990 ether, "1% was kept by the token");
        assertApproxEqAbs(_staking.checkTokenReward(address(token), _alice), 247.5 ether, _ROUNDING, "25% of 990");
        assertApproxEqAbs(_staking.checkTokenReward(address(token), _bob), 742.5 ether, _ROUNDING, "75% of 990");

        _claimToken(address(token), _alice);
        _claimToken(address(token), _bob);
        assertLe(token.balanceOf(_STAKING), 2 * _ROUNDING, "both were paid in full: only dust is left");
    }

    function testBrokenTokenDoesNotStopLockingOrOtherRewards() external {
        // A reward token can stop working: paused, or the staking contract blocked by its issuer.
        // Locking, unlocking and every other reward must go on. Only that token cannot be claimed.
        _upgradeStaking();
        _addRewardToken(_DAI);
        FreezableToken broken = new FreezableToken();
        vm.prank(_GOVERNANCE);
        _staking.addRewardToken(address(broken));
        _lock(_alice, 1_000 ether);
        uint256 totalLocked = _torn.balanceOf(_vault);
        _payEthRewards(1 ether);
        _payTokenRewards(_DAI, 1_000 ether);
        broken.mint(_STAKING, 1_000 ether);
        _staking.addTokenRewards(address(broken));

        broken.freeze();

        deal(_TORN, _alice, 1_000 ether);
        vm.startPrank(_alice);
        _torn.approve(_GOVERNANCE, 1_000 ether);
        vm.expectEmit(true, false, false, false, _GOVERNANCE);
        emit RewardUpdateSuccessful(_alice);
        _gov.lockWithApproval(1_000 ether);
        vm.expectEmit(true, false, false, false, _GOVERNANCE);
        emit RewardUpdateSuccessful(_alice);
        _gov.unlock(2_000 ether);
        vm.stopPrank();

        _claimEth(_alice);
        _claimToken(_DAI, _alice);
        assertApproxEqAbs(_alice.balance, 1 ether * 1_000 ether / totalLocked, _ROUNDING, "ETH claimed");
        assertApproxEqAbs(
            IERC20(_DAI).balanceOf(_alice), 1_000 ether * 1_000 ether / totalLocked, _ROUNDING, "DAI claimed"
        );

        vm.prank(_alice);
        vm.expectRevert(bytes("frozen"));
        _staking.getTokenReward(address(broken));
        assertApproxEqAbs(
            _staking.checkTokenReward(address(broken), _alice),
            1_000 ether * 1_000 ether / totalLocked,
            _ROUNDING,
            "the share in the broken token stays recorded"
        );
    }

    /// forge-config: default.fuzz.runs = 24
    function testFuzzLockersNeverClaimMoreTokensThanWerePaidIn(uint256 seed) external {
        // As the ETH fuzz test above, with fees in DAI. Some fees are sent without telling the
        // staking contract, which then shares them with the next fee.
        _upgradeStaking();
        _addRewardToken(_DAI);
        deal(_TORN, _vault, 0);
        address[3] memory lockers = [_alice, _bob, _carol];
        uint256 paid;

        for (uint256 step = 0; step < 16; step++) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            address locker = lockers[seed % 3];
            uint256 action = (seed >> 8) % 5;
            if (action == 0) {
                _lock(locker, 1 ether + (seed >> 16) % 5_000 ether);
            } else if (action == 1) {
                uint256 locked = _gov.lockedBalance(locker);
                if (locked > 0) {
                    vm.prank(locker);
                    _gov.unlock(1 + (seed >> 16) % locked);
                }
            } else if (action == 2) {
                if (_torn.balanceOf(_vault) > 0) {
                    uint256 fee = 1 + (seed >> 16) % 3_000 ether;
                    _payTokenRewards(_DAI, fee);
                    paid += fee;
                }
            } else if (action == 3) {
                uint256 fee = 1 + (seed >> 16) % 3_000 ether;
                deal(_DAI, _payer, fee);
                _transferToken(_DAI, _payer, _STAKING, fee);
                paid += fee;
            } else {
                _claimToken(_DAI, locker);
            }
        }
        if (_torn.balanceOf(_vault) > 0) {
            _staking.addTokenRewards(_DAI);
        }

        IERC20 dai = IERC20(_DAI);
        uint256 claimed = dai.balanceOf(_alice) + dai.balanceOf(_bob) + dai.balanceOf(_carol);
        uint256 claimable = _staking.checkTokenReward(_DAI, _alice) + _staking.checkTokenReward(_DAI, _bob)
            + _staking.checkTokenReward(_DAI, _carol);
        assertEq(dai.balanceOf(_STAKING), paid - claimed, "staking holds exactly what is not claimed yet");
        assertLe(claimed + claimable, paid, "claimed plus claimable never exceeds what was paid in");
        if (_torn.balanceOf(_vault) > 0) {
            assertLe(paid - claimed - claimable, 100, "and only rounding dust is left over");
            assertEq(_staking.tokenRewardsHeld(_DAI), paid - claimed, "all of it is accounted for");
        }
    }

    function testLargestRewardIndexAndLargestLockerStillFit() external {
        // The index of an asset is kept within 128 bits and a checkpoint keeps a locked balance in 88.
        // The largest index is refused beyond that, and all the TORN there is fits.
        _upgradeStaking();
        deal(_TORN, _vault, 0);
        uint256 allTorn = _torn.totalSupply();
        _lock(_alice, allTorn);
        uint256 most = uint256(type(uint128).max) * allTorn / _staking.ratioConstant();

        deal(_payer, most + 1 ether);
        vm.prank(_payer);
        vm.expectRevert(bytes("reward per torn too large"));
        _staking.addEthRewards{value: most + 1 ether}();

        _payEthRewards(most);
        assertApproxEqAbs(_staking.checkEthReward(_alice), most, _ROUNDING, "the only locker earns all of it");

        // Noted down on a change of balance, then claimed: nothing is cut off on the way.
        vm.prank(_alice);
        _gov.unlock(allTorn);
        assertApproxEqAbs(_staking.checkEthReward(_alice), most, _ROUNDING, "still all of it after unlocking");
        _claimEth(_alice);
        assertApproxEqAbs(_alice.balance, most, _ROUNDING, "claimed in full");
    }

    // --- Rewards are worked out when they are claimed, from checkpoints taken on each lock and unlock ---

    function testRewardsAcrossManyBalanceChangesAreWhatEachBalanceEarned() external {
        // Alice changes her locked balance between fees, in ETH and in DAI, and claims at the end.
        // What she is owed is, for each fee, her share of the TORN locked when it arrived.
        _upgradeStaking();
        _addRewardToken(_DAI);
        deal(_TORN, _vault, 0);
        _lock(_bob, 10_000 ether);
        uint256 expectedEth;
        uint256 expectedDai;
        uint256[6] memory aliceLocks = [uint256(1_000 ether), 3_000 ether, 500 ether, 0, 7_000 ether, 2_000 ether];

        for (uint256 i = 0; i < aliceLocks.length; i++) {
            _setLocked(_alice, aliceLocks[i]);
            uint256 total = _torn.balanceOf(_vault);
            _payEthRewards(1 ether);
            expectedEth += 1 ether * aliceLocks[i] / total;
            if (i % 2 == 0) {
                _payTokenRewards(_DAI, 1_000 ether);
                expectedDai += 1_000 ether * aliceLocks[i] / total;
            }
        }

        assertEq(_staking.checkpointCount(_alice), aliceLocks.length, "one checkpoint for each change after a fee");
        assertApproxEqAbs(_staking.checkEthReward(_alice), expectedEth, 16, "ETH owed");
        assertApproxEqAbs(_staking.checkTokenReward(_DAI, _alice), expectedDai, 16, "DAI owed");
        _claimEth(_alice);
        _claimToken(_DAI, _alice);
        assertApproxEqAbs(_alice.balance, expectedEth, 16, "ETH claimed");
        assertApproxEqAbs(IERC20(_DAI).balanceOf(_alice), expectedDai, 16, "DAI claimed");
        assertEq(_staking.checkEthReward(_alice), 0, "nothing left in ETH");
        assertEq(_staking.checkTokenReward(_DAI, _alice), 0, "nothing left in DAI");

        // Bob never moved after his lock, which is his only checkpoint, and he is owed the rest.
        assertEq(_staking.checkpointCount(_bob), 1, "bob's only checkpoint is his lock");
        assertApproxEqAbs(_staking.checkEthReward(_bob), 6 ether - expectedEth, 16, "the rest of the ETH is bob's");
    }

    function testNoCheckpointIsTakenWhenNothingWasPaidInSinceTheLastOne() external {
        _upgradeStaking();
        _lock(_alice, 1_000 ether);
        assertEq(_staking.checkpointCount(_alice), 1, "the first lock");

        _lock(_alice, 1_000 ether);
        vm.prank(_alice);
        _gov.unlock(500 ether);
        assertEq(_staking.checkpointCount(_alice), 1, "no fee in between: nothing new to note down");

        uint256 totalLocked = _torn.balanceOf(_vault);
        _payEthRewards(1 ether);
        _lock(_alice, 1_000 ether);
        assertEq(_staking.checkpointCount(_alice), 2, "a fee came in: the next change is noted down");
        assertApproxEqAbs(
            _staking.checkEthReward(_alice),
            1 ether * 1_500 ether / totalLocked,
            _ROUNDING,
            "on the 1,500 TORN locked then"
        );
    }

    function testTokenAddedLaterIsSharedOnTheTornLockedWhenItIsPaid() external {
        // Checkpoints taken before a token was added must not make its rewards look older than they are.
        _upgradeStaking();
        _lock(_alice, 1_000 ether);
        _payEthRewards(1 ether);
        _lock(_alice, 9_000 ether);
        _payEthRewards(1 ether);
        _lock(_bob, 5_000 ether);

        _addRewardToken(_DAI);
        uint256 totalLocked = _torn.balanceOf(_vault);
        _payTokenRewards(_DAI, 1_000 ether);

        assertApproxEqAbs(
            _staking.checkTokenReward(_DAI, _alice),
            1_000 ether * 10_000 ether / totalLocked,
            _ROUNDING,
            "alice's share is on the 10,000 TORN she has locked now"
        );
        assertApproxEqAbs(
            _staking.checkTokenReward(_DAI, _bob),
            1_000 ether * 5_000 ether / totalLocked,
            _ROUNDING,
            "and bob's on his"
        );
    }

    function testRewardsCanBeClaimedAFewCheckpointsAtATime() external {
        // An account with very many checkpoints could need more gas than a transaction has to go
        // through all of them. It can claim in several steps.
        _upgradeStaking();
        _addRewardToken(_DAI);
        for (uint256 i = 0; i < 5; i++) {
            _lock(_alice, 1_000 ether);
            _payEthRewards(1 ether);
            _payTokenRewards(_DAI, 1_000 ether);
        }
        uint256 owedEth = _staking.checkEthReward(_alice);
        uint256 owedDai = _staking.checkTokenReward(_DAI, _alice);
        assertEq(_staking.checkpointCount(_alice), 5, "five checkpoints");

        vm.startPrank(_alice);
        _staking.getEthRewardUpTo(2);
        uint256 firstStep = _alice.balance;
        assertGt(firstStep, 0, "part of it");
        assertLt(firstStep, owedEth, "not all of it");
        assertApproxEqAbs(_staking.checkEthReward(_alice), owedEth - firstStep, _ROUNDING, "the rest is still owed");
        _staking.getEthRewardUpTo(2);
        _staking.getEthRewardUpTo(2);
        _staking.getTokenRewardUpTo(_DAI, 3);
        _staking.getTokenRewardUpTo(_DAI, 3);
        vm.stopPrank();

        assertApproxEqAbs(_alice.balance, owedEth, 8, "all the ETH after three steps");
        assertApproxEqAbs(IERC20(_DAI).balanceOf(_alice), owedDai, 8, "all the DAI after two steps");
        assertEq(_staking.checkEthReward(_alice), 0, "nothing left in ETH");
        assertEq(_staking.checkTokenReward(_DAI, _alice), 0, "nothing left in DAI");
    }

    /// forge-config: default.fuzz.runs = 32
    function testFuzzEveryAssetIsOwedWhatEachBalanceEarned(uint256 seed) external {
        // Random locks, unlocks, fees and claims, among the lockers really on mainnet. What each of
        // three lockers is owed in each asset is worked out here on its own: its share of each fee
        // when it arrived. The cases mixed in:
        // - alice locked before the upgrade and has no checkpoint; bob and carol lock after it;
        // - ETH is paid before anybody has a checkpoint;
        // - every asset is used: ETH, DAI and tokens added at random moments, up to the maximum;
        // - fees and locks of zero;
        // - claims in one go and limited to 0, 1 or 2 checkpoints.
        _lock(_alice, 2_000 ether);
        _upgradeStaking();
        _payEthRewards(1 ether);
        address[3] memory lockers = [_alice, _bob, _carol];
        uint256 maxTokens = _staking.MAX_REWARD_TOKENS();
        address[] memory assets = new address[](maxTokens + 1);
        uint256 added;
        uint256[][] memory owed = new uint256[][](maxTokens + 1);
        for (uint256 a = 0; a <= maxTokens; a++) {
            owed[a] = new uint256[](3);
        }
        owed[0][0] = 1 ether * 2_000 ether / _torn.balanceOf(_vault);

        for (uint256 step = 0; step < 36; step++) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            address locker = lockers[seed % 3];
            uint256 asset = (seed >> 4) % (added + 1);
            uint256 action = (seed >> 8) % 8;
            if (action == 0) {
                _lock(locker, (seed >> 16) % 4 == 0 ? 0 : 1 ether + (seed >> 20) % 5_000 ether);
            } else if (action == 1) {
                uint256 locked = _gov.lockedBalance(locker);
                vm.prank(locker);
                _gov.unlock(locked == 0 ? 0 : (seed >> 16) % (locked + 1));
            } else if (action <= 4) {
                uint256 fee = (seed >> 16) % 5 == 0 ? 0 : 1 + (seed >> 20) % 3 ether;
                uint256 total = _torn.balanceOf(_vault);
                if (asset == 0) {
                    _payEthRewards(fee);
                } else if (assets[asset] == _DAI) {
                    _payTokenRewards(_DAI, fee);
                } else {
                    PlainToken(assets[asset]).mint(_STAKING, fee);
                    _staking.addTokenRewards(assets[asset]);
                }
                for (uint256 i = 0; i < 3; i++) {
                    owed[asset][i] += fee * _gov.lockedBalance(lockers[i]) / total;
                }
            } else if (action <= 6) {
                uint256 limit = (seed >> 16) % 4;
                if (limit == 3) limit = type(uint256).max;
                vm.prank(locker);
                if (asset == 0) _staking.getEthRewardUpTo(limit);
                else _staking.getTokenRewardUpTo(assets[asset], limit);
            } else if (added < maxTokens) {
                added++;
                if (added == 1) {
                    _addRewardToken(_DAI);
                    assets[added] = _DAI;
                } else {
                    assets[added] = address(new PlainToken());
                    vm.prank(_GOVERNANCE);
                    _staking.addRewardToken(assets[added]);
                }
            }
        }

        for (uint256 a = 0; a <= added; a++) {
            for (uint256 i = 0; i < 3; i++) {
                uint256 received = a == 0 ? lockers[i].balance : IERC20(assets[a]).balanceOf(lockers[i]);
                uint256 claimable =
                    a == 0 ? _staking.checkEthReward(lockers[i]) : _staking.checkTokenReward(assets[a], lockers[i]);
                assertApproxEqAbs(received + claimable, owed[a][i], 256, "a locker is not owed what it earned");
            }
        }
    }

    // --- The limits of what a checkpoint can hold ---

    function testAnAssetAtItsLastVersionCannotBePaidInAndTheOthersGoOn() external {
        // Each asset has 2**30 - 1 versions. The latest versions are written straight into storage
        // here (`assetVersions`, slot 4: 30 bits for each asset, then one "noted down" bit for each).
        _lock(_alice, 4_000 ether);
        _upgradeStaking();
        PlainToken first = new PlainToken();
        PlainToken second = new PlainToken();
        vm.startPrank(_GOVERNANCE);
        _staking.addRewardToken(address(first));
        _staking.addRewardToken(address(second));
        vm.stopPrank();
        uint256 last = 2 ** 30 - 1;
        // ETH at its last version but one, the first token at its last, the second at 5; all noted down.
        vm.store(_STAKING, bytes32(uint256(4)), bytes32((last - 1) | (last << 30) | (5 << 60) | (uint256(31) << 150)));

        _payEthRewards(1 ether);
        uint256 word = uint256(vm.load(_STAKING, bytes32(uint256(4))));
        assertEq(word & last, last, "ETH at its last version");
        assertEq((word >> 30) & last, last, "the first token is untouched: nothing carried over");
        assertEq((word >> 60) & last, 5, "so is the second");
        assertEq(word >> 150, 30, "only the bit of ETH is off");

        // No checkpoint since: the last version can still be raised.
        _payEthRewards(1 ether);

        // A checkpoint by anyone, and from then on ETH cannot be paid in. Nor the first token.
        _lock(_bob, 100 ether);
        deal(_payer, 1 ether);
        vm.prank(_payer);
        vm.expectRevert(bytes("too many versions"));
        _staking.addEthRewards{value: 1 ether}();
        first.mint(_STAKING, 1 ether);
        vm.expectRevert(bytes("too many versions"));
        _staking.addTokenRewards(address(first));

        // The second token, locks, unlocks and claims are not affected.
        second.mint(_STAKING, 500 ether);
        _staking.addTokenRewards(address(second));
        vm.expectEmit(true, false, false, false, _GOVERNANCE);
        emit RewardUpdateSuccessful(_alice);
        vm.prank(_alice);
        _gov.unlock(1_000 ether);
        _claimEth(_alice);
        _claimToken(address(second), _alice);
        assertGt(_alice.balance, 0, "ETH earned before the limit is paid");
        assertGt(second.balanceOf(_alice), 0, "and so is the second token");
    }

    function testAnAccountThatUsesUpItsCheckpointsStopsEarningInAssets() external {
        // An account has 2**22 - 1 checkpoints. Its count is written straight into storage here (the
        // top 22 bits of its first checkpoint, `checkpoints[account][0]` in slot 6), together with the
        // checkpoint it has claimed ETH up to (`claimedUpTo[ETH][account]` in slot 7).
        _upgradeStaking();
        _lock(_alice, 1_000 ether);
        _payEthRewards(1 ether);
        uint256 owedBefore = _staking.checkEthReward(_alice);
        assertGt(owedBefore, 0, "alice earns ETH");
        uint256 most = 2 ** 22 - 1;
        bytes32 firstCheckpoint = keccak256(abi.encode(uint256(0), keccak256(abi.encode(_alice, uint256(6)))));
        uint256 word = uint256(vm.load(_STAKING, firstCheckpoint));
        vm.store(_STAKING, firstCheckpoint, bytes32((word & (2 ** 234 - 1)) | ((most - 1) << 234)));
        vm.store(
            _STAKING, keccak256(abi.encode(_alice, keccak256(abi.encode(address(0), uint256(7))))), bytes32(most - 1)
        );
        assertEq(_staking.checkpointCount(_alice), most - 1, "one checkpoint short of the most");
        assertEq(_staking.checkEthReward(_alice), owedBefore, "same rewards with the count moved up");

        _lock(_alice, 1_000 ether);
        assertEq(_staking.checkpointCount(_alice), most, "the last checkpoint");
        _payEthRewards(1 ether);
        // The reward update itself still goes through: Governance reports it as done.
        deal(_TORN, _alice, 1_000 ether);
        vm.startPrank(_alice);
        _torn.approve(_GOVERNANCE, 1_000 ether);
        vm.expectEmit(true, false, false, false, _GOVERNANCE);
        emit RewardUpdateSuccessful(_alice);
        _gov.lockWithApproval(1_000 ether);
        vm.stopPrank();
        assertEq(_staking.checkpointCount(_alice), most, "no new checkpoint, and the count does not start again");
        _payEthRewards(1 ether);

        assertEq(_staking.checkEthReward(_alice), owedBefore, "nothing earned after the last checkpoint");
        _claimEth(_alice);
        assertEq(_alice.balance, owedBefore, "what was earned before it is paid");
    }

    // --- A lock or unlock cannot go through without the reward update ---
    // --- A lock or unlock cannot go through without the reward update ---

    function testRewardUpdateCannotBeSkippedByChoosingTheGas() external {
        // Governance wraps the reward update in try/catch: a lock or unlock goes on even if the update
        // runs out of gas, and the rewards of that account are then worked out on a wrong balance
        // (too high after a lock, which takes from the other lockers). A call that runs out of gas
        // leaves its caller 1/64 of the gas, here twice over: in Governance and in the staking proxy.
        // So skipping the update only works if about 1/32 of the update's gas is enough to finish the
        // lock or unlock, that is, if the update is very expensive.
        //
        // Measured here for the most expensive update there can be against the cheapest lock and unlock
        // there can be. The most expensive update is the first one of an account that locked before
        // the staking contract existed and has not moved since: nothing is noted down for it yet, in
        // TORN or in the assets, and fees have arrived in every asset.
        // Skipping the update takes more than 3.5 times the gas of a whole lock or unlock, with ETH
        // only and with every reward token added: the update takes one checkpoint for all the assets,
        // so its cost does not depend on how many there are.
        (uint256 unlockAlone, uint256 lockAlone) = _assertUpdateCannotBeSkipped(0, true, 7);
        (uint256 unlockWithAll, uint256 lockWithAll) = _assertUpdateCannotBeSkipped(_MAX_REWARD_TOKENS, true, 7);
        assertApproxEqRel(unlockWithAll, unlockAlone, 0.01e18, "an unlock costs the same with every reward token");
        assertApproxEqRel(lockWithAll, lockAlone, 0.01e18, "a lock costs the same with every reward token");

        // Once only, the first checkpoint anybody takes after the upgrade also writes `assetVersions`
        // for the first time. If that account is one of those, it is still more than 3 times.
        _assertUpdateCannotBeSkipped(0, false, 6);
    }

    /// @param tokens how many reward tokens the staking contract has
    /// @param someoneMovedBefore whether another account has locked since the upgrade
    /// @param halves a lock or unlock without the update must take at least `halves`/2 times the gas
    ///        of a whole lock or unlock with it
    /// @return unlockGas least gas for an unlock with the reward update
    /// @return lockGas least gas for a lock with the reward update
    function _assertUpdateCannotBeSkipped(uint256 tokens, bool someoneMovedBefore, uint256 halves)
        internal
        returns (uint256 unlockGas, uint256 lockGas)
    {
        uint256 start = vm.snapshotState();
        GasPickingLocker locker = _lockerFromBeforeTheStakingContract(tokens, someoneMovedBefore);

        for (uint256 lock = 0; lock < 2; lock++) {
            // Least gas with which the lock or unlock completes and the rewards are updated.
            uint256 withUpdate = _leastGas(locker, lock == 1, true);
            // With less, nothing happens at all: there is no amount of gas in between with which the
            // balance changes and the rewards are not updated.
            uint256[5] memory less =
                [withUpdate - 100, withUpdate - 2_000, withUpdate * 31 / 32, withUpdate * 9 / 10, withUpdate / 2];
            for (uint256 i = 0; i < less.length; i++) {
                (bool done,) = _lockOrUnlock(locker, lock == 1, less[i]);
                assertFalse(done, "balance changed without enough gas for the reward update");
            }

            // Least gas with which it would complete if the update used up whatever gas it is given:
            // the implementation behind the staking proxy is replaced by code that does just that.
            uint256 beforeEtch = vm.snapshotState();
            vm.etch(address(uint160(uint256(vm.load(_STAKING, _IMPLEMENTATION_SLOT)))), hex"fe");
            uint256 withoutUpdate = _leastGas(locker, lock == 1, false);
            vm.revertToState(beforeEtch);

            assertGe(2 * withoutUpdate, halves * withUpdate, "the reward update costs too much gas");
            if (lock == 1) lockGas = withUpdate;
            else unlockGas = withUpdate;
        }
        vm.revertToState(start);
    }

    /// @dev A locker whose next reward update writes the most storage it ever will. It locked while the
    ///      staking contract was the one live today, and stands for an account that locked before the
    ///      staking contract existed (May 2023) and has not moved since: nothing is noted down for it,
    ///      in TORN or in the assets. The staking contract is then upgraded and fees are paid in TORN,
    ///      in ETH and in each of `tokens` reward tokens. With `someoneMovedBefore`, another account
    ///      took a checkpoint first and fees were paid again, as is the case from the first lock or
    ///      unlock after the upgrade on.
    function _lockerFromBeforeTheStakingContract(uint256 tokens, bool someoneMovedBefore)
        internal
        returns (GasPickingLocker locker)
    {
        locker = new GasPickingLocker(_gov, _torn);
        deal(_TORN, address(locker), 2_000 ether);
        locker.lock(1_000 ether);
        // `accumulatedRewardRateOnLastUpdate[locker]`, in slot 2 of the staking contract, back to zero.
        vm.store(_STAKING, keccak256(abi.encode(address(locker), uint256(2))), bytes32(0));

        _upgradeStaking();
        PlainToken[] memory rewardTokens = new PlainToken[](tokens);
        for (uint256 i = 0; i < tokens; i++) {
            rewardTokens[i] = new PlainToken();
            vm.prank(_GOVERNANCE);
            _staking.addRewardToken(address(rewardTokens[i]));
        }
        for (uint256 round = 0; round < (someoneMovedBefore ? 2 : 1); round++) {
            if (round == 1) _lock(_alice, 1_000 ether);
            vm.prank(_RELAYER_REGISTRY);
            _staking.addBurnRewards(500 ether);
            _payEthRewards(1 ether);
            for (uint256 i = 0; i < tokens; i++) {
                rewardTokens[i].mint(_STAKING, 1_000 ether);
                _staking.addTokenRewards(address(rewardTokens[i]));
            }
        }
        assertEq(_staking.checkpointCount(address(locker)), 0, "the locker has a checkpoint");
        assertEq(_staking.accumulatedRewardRateOnLastUpdate(address(locker)), 0, "TORN rate still noted down");
    }

    /// @dev A lock (or unlock) of 1 TORN by `locker`, with `gasLimit` for the call to Governance.
    ///      The state is put back afterwards.
    /// @return done whether the locked balance changed
    /// @return updated whether Governance reported the reward update as done
    function _lockOrUnlock(GasPickingLocker locker, bool lock, uint256 gasLimit)
        internal
        returns (bool done, bool updated)
    {
        uint256 snapshot = vm.snapshotState();
        vm.recordLogs();
        done = lock ? locker.lockWithGas(1 ether, gasLimit) : locker.unlockWithGas(1 ether, gasLimit);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == _GOVERNANCE && logs[i].topics[0] == RewardUpdateSuccessful.selector) {
                updated = true;
            }
        }
        vm.revertToState(snapshot);
    }

    /// @dev Binary search for the least gas with which the locked balance changes, with or without
    ///      the reward update.
    function _leastGas(GasPickingLocker locker, bool lock, bool withUpdate) internal returns (uint256 enough) {
        uint256 tooLittle = 10_000;
        enough = 4_000_000;
        (bool done, bool updated) = _lockOrUnlock(locker, lock, enough);
        assertTrue(done && updated == withUpdate, "unexpected result with plenty of gas");
        while (enough - tooLittle > 50) {
            uint256 middle = (tooLittle + enough) / 2;
            (done, updated) = _lockOrUnlock(locker, lock, middle);
            if (done && updated == withUpdate) {
                enough = middle;
            } else {
                tooLittle = middle;
            }
        }
    }

    // --- Existing TORN rewards are unaffected by the upgrade ---

    function testUpgradePreservesPendingTornRewards() external {
        _lock(_alice, 1_000 ether);
        uint256 totalLocked = _torn.balanceOf(_vault);
        vm.prank(_RELAYER_REGISTRY);
        _staking.addBurnRewards(500 ether);
        uint256 pending = _staking.checkReward(_alice);
        assertApproxEqAbs(pending, 500 ether * 1_000 ether / totalLocked, _ROUNDING, "pending before the upgrade");
        uint256 ratioBefore = _staking.ratioConstant();
        uint256 indexBefore = _staking.accumulatedRewardPerTorn();

        _upgradeStaking();

        assertEq(_staking.ratioConstant(), ratioBefore, "reward scale");
        assertEq(_staking.accumulatedRewardPerTorn(), indexBefore, "TORN reward index");
        assertEq(_staking.checkReward(_alice), pending, "pending after the upgrade");
        vm.prank(_alice);
        _staking.getReward();
        assertEq(_torn.balanceOf(_alice), pending, "claim pays the same TORN");
    }

    function testRealLockerKeepsItsPendingTornAndEarnsEthAfterUpgrade() external {
        uint256 locked = _gov.lockedBalance(_REAL_LOCKER);
        if (locked == 0) {
            vm.skip(true); // it has unlocked since this was written
        }
        uint256 pending = _staking.checkReward(_REAL_LOCKER);

        _upgradeStaking();

        assertEq(_staking.checkReward(_REAL_LOCKER), pending, "pending TORN unchanged by the upgrade");
        assertEq(_staking.checkEthReward(_REAL_LOCKER), 0, "no ETH before any fee is paid");
        uint256 tornBefore = _torn.balanceOf(_REAL_LOCKER);
        vm.prank(_REAL_LOCKER);
        _staking.getReward();
        assertEq(_torn.balanceOf(_REAL_LOCKER) - tornBefore, pending, "TORN claim pays it");

        uint256 totalLocked = _torn.balanceOf(_vault);
        _payEthRewards(1 ether);
        assertApproxEqAbs(
            _staking.checkEthReward(_REAL_LOCKER), 1 ether * locked / totalLocked, _ROUNDING, "earns ETH from new fees"
        );
    }

    function testTornBurnRewardsStillAccrueAfterUpgrade() external {
        _upgradeStaking();
        _lock(_alice, 1_000 ether);
        uint256 totalLocked = _torn.balanceOf(_vault);

        vm.prank(_RELAYER_REGISTRY);
        _staking.addBurnRewards(500 ether);

        uint256 expected = 500 ether * 1_000 ether / totalLocked;
        assertApproxEqAbs(_staking.checkReward(_alice), expected, _ROUNDING, "TORN reward");
        assertEq(_staking.checkEthReward(_alice), 0, "a TORN burn pays no ETH");
        vm.prank(_alice);
        _staking.getReward();
        assertApproxEqAbs(_torn.balanceOf(_alice), expected, _ROUNDING, "TORN claimed");
    }

    function testGovernanceRewardHookSucceedsAfterUpgrade() external {
        // Governance wraps the hook in try/catch: a revert inside it would not stop lock/unlock,
        // it would silently skip the reward update.
        _upgradeStaking();
        deal(_TORN, _alice, 1_000 ether);
        vm.startPrank(_alice);
        _torn.approve(_GOVERNANCE, 1_000 ether);

        vm.expectEmit(true, false, false, false, _GOVERNANCE);
        emit RewardUpdateSuccessful(_alice);
        _gov.lockWithApproval(1_000 ether);

        vm.expectEmit(true, false, false, false, _GOVERNANCE);
        emit RewardUpdateSuccessful(_alice);
        _gov.unlock(1_000 ether);
        vm.stopPrank();
    }

    function testRelayedWithdrawalStillBurnsStakeAfterUpgrade() external {
        // RelayerRegistry.burn calls the staking contract on every registered-relayer withdrawal,
        // with no try/catch: if the new implementation reverted there, relayers would stop.
        _upgradeStaking();
        vm.mockCall(_VERIFIER, abi.encodeWithSelector(IVerifier.verifyProof.selector), abi.encode(true));
        address worker = makeAddr("worker");
        vm.prank(_RELAYER_MASTER);
        _relayerRegistry.registerWorker(_RELAYER_MASTER, worker);
        _depositViaRouter(makeAddr("depositor"), _LEGACY_1_ETH_POOL, 1 ether, "legacy-note");
        bytes32 root = ITornadoInstance(_LEGACY_1_ETH_POOL).getLastRoot();

        uint256 stakeBefore = _relayerRegistry.getRelayerBalance(_RELAYER_MASTER);
        uint256 indexBefore = _staking.accumulatedRewardPerTorn();
        vm.prank(worker);
        _router.withdraw(
            _LEGACY_1_ETH_POOL,
            "",
            root,
            bytes32(uint256(0xabc123)),
            payable(makeAddr("recipient")),
            payable(_RELAYER_MASTER),
            0.01 ether,
            0
        );

        assertLt(_relayerRegistry.getRelayerBalance(_RELAYER_MASTER), stakeBefore, "relayer stake burned");
        assertGt(_staking.accumulatedRewardPerTorn(), indexBefore, "burn credited to lockers");
    }

    // --- Helpers ---

    /// @dev An account with no code. The keys behind forge's usual labels ("alice", "bob") are public,
    ///      and on mainnet those accounts carry EIP-7702 delegation code, which cannot receive ETH
    ///      under the EVM version these tests run with.
    function _freshAccount(string memory name) internal returns (address account) {
        account = makeAddr(string.concat("tornado-staking-rewards-test/", name));
        assertEq(account.code.length, 0, "test account has code on mainnet");
    }

    /// @dev Lock `amount` more TORN in Governance for `account`.
    function _lock(address account, uint256 amount) internal {
        deal(_TORN, account, amount);
        vm.startPrank(account);
        assertTrue(_torn.approve(_GOVERNANCE, amount));
        _gov.lockWithApproval(amount);
        vm.stopPrank();
    }

    /// @dev Lock or unlock so that `account` has exactly `amount` locked.
    function _setLocked(address account, uint256 amount) internal {
        uint256 locked = _gov.lockedBalance(account);
        if (amount > locked) {
            _lock(account, amount - locked);
        } else if (amount < locked) {
            vm.prank(account);
            _gov.unlock(locked - amount);
        }
    }

    function _payEthRewards(uint256 amount) internal {
        deal(_payer, amount);
        vm.prank(_payer);
        _staking.addEthRewards{value: amount}();
    }

    function _claimEth(address account) internal {
        vm.prank(account);
        _staking.getEthReward();
    }

    /// @dev What a future proposal does to let a token pay rewards. Any amount of the token the
    ///      staking contract happens to hold on mainnet is removed first, to keep the numbers exact.
    function _addRewardToken(address token) internal {
        deal(token, _STAKING, 0);
        vm.prank(_GOVERNANCE);
        _staking.addRewardToken(token);
    }

    /// @dev Tokens such as USDT return nothing from `transfer`, so the result is not decoded.
    function _transferToken(address token, address from, address to, uint256 amount) internal {
        vm.prank(from);
        (bool sent,) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        assertTrue(sent, "token transfer failed");
    }

    /// @dev What a pool does with a fee in a token: send it to the staking contract, then tell it.
    function _payTokenRewards(address token, uint256 amount) internal {
        deal(token, _payer, amount);
        _transferToken(token, _payer, _STAKING, amount);
        _staking.addTokenRewards(token);
    }

    function _claimToken(address token, address account) internal {
        vm.prank(account);
        _staking.getTokenReward(token);
    }
}
