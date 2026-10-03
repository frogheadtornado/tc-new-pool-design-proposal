// SPDX-License-Identifier: MIT

// New implementation for the TornadoStakingRewards proxy (0x5B3f656C80E8ddb9ec01Dd9018815576E9238c29).
// It is the verified source of the live implementation (0x9c97be37840f0e754bb7aDB1b16fD0954A2BA248)
// plus rewards in other assets: ETH, and the tokens Governance adds. Every addition is marked
// "Asset rewards"; the only changed original lines are the constructor signature and the
// `ratioConstant` assignment. Storage slots 0-3 keep the live layout and the additions use slots 4-10.

pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeMath } from "@openzeppelin/contracts/math/SafeMath.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/Initializable.sol";
// Asset rewards
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { EnsResolve } from "torn-token/contracts/ENS.sol";

interface ITornadoVault {
    function withdrawTorn(address recipient, uint256 amount) external;
}

interface ITornadoGovernance {
    function lockedBalance(address account) external view returns (uint256);

    function userVault() external view returns (ITornadoVault);
}

/**
 * @notice This is the staking contract of the governance staking upgrade.
 *         This contract should hold the staked funds which are received upon relayer registration,
 *         and properly attribute rewards to addresses without security issues.
 * @dev CONTRACT RISKS:
 *      - Relayer staked TORN at risk if contract is compromised.
 *
 */
contract TornadoStakingRewards is Initializable, EnsResolve {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    /// @notice 1e25
    uint256 public immutable ratioConstant;
    ITornadoGovernance public immutable Governance;
    IERC20 public immutable torn;
    address public immutable relayerRegistry;

    /// @notice the sum torn_burned_i/locked_amount_i*coefficient where i is incremented at each burn
    uint256 public accumulatedRewardPerTorn;
    /// @notice notes down accumulatedRewardPerTorn for an address on a lock/unlock/claim
    mapping(address => uint256) public accumulatedRewardRateOnLastUpdate;
    /// @notice notes down how much an account may claim
    mapping(address => uint256) public accumulatedRewards;

    // Asset rewards: rewards in ETH and in tokens added by Governance, shared among the lockers like the
    // TORN rewards above: each payment raises the asset's "reward per TORN", and a locker is owed the
    // rise times its locked TORN. They are worked out when they are claimed. On a lock or unlock only
    // a checkpoint is taken, one storage word for all the assets, so that a lock or unlock costs the
    // same whatever the number of assets.
    /// @notice ETH is accounted under this address
    address public constant ETH = address(0);
    /// @notice the most tokens that can pay rewards: a checkpoint has room for ETH and this many tokens
    uint256 public constant MAX_REWARD_TOKENS = 5;

    // The reward per TORN of an asset is kept in numbered versions. Payments raise the latest one. Once
    // a checkpoint notes a version down, that version is never written again and the next payment
    // starts a new one, so it keeps the value the reward per TORN had when the checkpoint was taken.
    //
    // A checkpoint is one word:
    //   bits   0-143  the version of each asset, 24 bits each (asset 0 is ETH, 1 to 5 the tokens)
    //   bits 144-231  the TORN the account had locked until then
    //   bits 232-255  in the first checkpoint of an account only: how many checkpoints it has
    // assetVersions is one word:
    //   bits   0-143  the latest version of each asset, 24 bits each
    //   bits 144-149  for each asset, whether a checkpoint notes its latest version down
    uint256 private constant VERSION_BITS = 24;
    uint256 private constant VERSION_MAX = 2**24 - 1;
    uint256 private constant VERSIONS_MASK = 2**144 - 1;
    uint256 private constant BALANCE_SHIFT = 144;
    uint256 private constant BALANCE_MAX = 2**88 - 1;
    uint256 private constant COUNT_SHIFT = 232;
    uint256 private constant COUNT_MAX = 2**24 - 1;
    uint256 private constant NOTED_SHIFT = 144;
    uint256 private constant ALL_NOTED = (2**6 - 1) << 144;

    /// @notice the latest version of each asset, and whether a checkpoint notes it down
    uint256 private assetVersions;
    /// @notice asset => version => the sum asset_added_i/locked_amount_i*coefficient where i is incremented
    ///         at each payment, as it was when the version was last written. It is kept within 128 bits.
    mapping(address => mapping(uint256 => uint256)) private assetRewardPerTornAt;
    /// @notice account => number => checkpoint, taken on a lock or unlock
    mapping(address => mapping(uint256 => uint256)) private checkpoints;
    /// @notice asset => account => up to where the account has claimed: the reward per TORN reached
    ///         (from bit 24 up) and the next checkpoint to use (bits 0-23)
    mapping(address => mapping(address => uint256)) private claimedUpTo;
    /// @notice the tokens that pay rewards, in the order Governance added them
    address[] public rewardTokens;
    /// @notice token => its number among the assets, from 1; 0 if it does not pay rewards
    mapping(address => uint256) public rewardTokenNumber;
    /// @notice token => how much of it held here is already shared among the lockers and not claimed yet
    mapping(address => uint256) public tokenRewardsHeld;

    event RewardsUpdated(address indexed account, uint256 rewards);
    event RewardsClaimed(address indexed account, uint256 rewardsClaimed);
    // Asset rewards
    event RewardTokenAdded(address indexed token);
    event AssetRewardsAdded(address indexed asset, address indexed sender, uint256 rewards);
    event AssetRewardsClaimed(address indexed asset, address indexed account, uint256 rewardsClaimed);

    modifier onlyGovernance() {
        require(msg.sender == address(Governance), "only governance");
        _;
    }

    // Minor code change here we won't resolve the registry by ENS
    // Asset rewards: `_ratioConstant` must be the live implementation's value. The live code set it to the
    // TORN total supply at its own deployment; TORN is burnable, so recomputing it now would change the
    // scale of the accumulatedRewardPerTorn already stored in the proxy.
    constructor(address governanceAddress, address tornAddress, address _relayerRegistry, uint256 _ratioConstant)
        public
    {
        Governance = ITornadoGovernance(governanceAddress);
        torn = IERC20(tornAddress);
        relayerRegistry = _relayerRegistry;
        ratioConstant = _ratioConstant;
    }

    /**
     * @notice This function should safely send a user his rewards.
     * @dev IMPORTANT FUNCTION:
     *      We know that rewards are going to be updated every time someone locks or unlocks
     *      so we know that this function can't be used to falsely increase the amount of
     *      lockedTorn by locking in governance and subsequently calling it.
     *      - set rewards to 0 greedily
     */
    function getReward() external {
        uint256 rewards = _updateReward(msg.sender, Governance.lockedBalance(msg.sender));
        rewards = rewards.add(accumulatedRewards[msg.sender]);
        accumulatedRewards[msg.sender] = 0;
        torn.safeTransfer(msg.sender, rewards);
        emit RewardsClaimed(msg.sender, rewards);
    }

    /**
     * @notice This function should increment the proper amount of rewards per torn for the contract
     * @dev IMPORTANT FUNCTION:
     *      - calculation must not overflow with extreme values
     *        (amount <= 1e25) * 1e25 / (balance of vault <= 1e25) -> (extreme values)
     * @param amount amount to add to the rewards
     */
    function addBurnRewards(uint256 amount) external {
        require(msg.sender == address(Governance) || msg.sender == relayerRegistry, "unauthorized");
        accumulatedRewardPerTorn = accumulatedRewardPerTorn.add(
            amount.mul(ratioConstant).div(torn.balanceOf(address(Governance.userVault())))
        );
    }

    /**
     * @notice This function should allow governance to properly update the accumulated rewards rate for an account
     * @param account address of account to update data for
     * @param amountLockedBeforehand the balance locked beforehand in the governance contract
     *
     */
    function updateRewardsOnLockedBalanceChange(address account, uint256 amountLockedBeforehand)
        external
        onlyGovernance
    {
        uint256 claimed = _updateReward(account, amountLockedBeforehand);
        accumulatedRewards[account] = accumulatedRewards[account].add(claimed);

        // Asset rewards: a checkpoint with the same before-hand balance as the TORN rewards
        _takeCheckpoint(account, amountLockedBeforehand);
    }

    /**
     * @notice This function should allow governance to directly set accumulated rewards amount for an account
     * @dev IMPORTANT FUNCTION:
     *      Do NOT use to update rewards in normal cases, see `updateRewardsOnLockedBalanceChange` function
     *      for this purposes. This function should be used only for fix bugs with rewards.
     *      You need to replenish Staking contract with TORN, if you increase staker rewards
     *      amount with this function, or withdraw TORN from Staking contract, if staker rewards decreased.
     * @param account address of account to set rewards amount
     * @param amount expected account accumulated rewards balance
     *
     */
    function setReward(address account, uint256 amount) external onlyGovernance {
        accumulatedRewards[account] = amount;
    }

    /**
     * @notice This function should allow governance rescue tokens from the staking rewards contract
     *
     */
    function withdrawTorn(uint256 amount) external onlyGovernance {
        if (amount == type(uint256).max) amount = torn.balanceOf(address(this));
        torn.safeTransfer(address(Governance), amount);
    }

    /**
     * @notice This function should calculated the proper amount of rewards attributed to user since the last update
     * @dev IMPORTANT FUNCTION:
     *      - calculation must not overflow with extreme values
     *        (accumulatedReward <= 1e25) * (lockedBeforehand <= 1e25) / 1e25
     *      - result may go to 0, since this implies on 1 TORN locked => accumulatedReward <= 1e7, meaning a very small reward
     * @param account address of account to calculate rewards for
     * @param amountLockedBeforehand the balance locked beforehand in the governance contract
     * @return claimed the rewards attributed to user since the last update
     */
    function _updateReward(address account, uint256 amountLockedBeforehand)
        private
        returns (uint256 claimed)
    {
        if (amountLockedBeforehand != 0) {
            claimed = (accumulatedRewardPerTorn.sub(accumulatedRewardRateOnLastUpdate[account])).mul(
                amountLockedBeforehand
            ).div(ratioConstant);
        }
        accumulatedRewardRateOnLastUpdate[account] = accumulatedRewardPerTorn;
        emit RewardsUpdated(account, claimed);
    }

    /**
     * @notice This function should show a user his rewards.
     * @param account address of account to calculate rewards for
     */
    function checkReward(address account) external view returns (uint256 rewards) {
        uint256 amountLocked = Governance.lockedBalance(account);
        if (amountLocked != 0) {
            rewards = (accumulatedRewardPerTorn.sub(accumulatedRewardRateOnLastUpdate[account])).mul(
                amountLocked
            ).div(ratioConstant);
        }
        rewards = rewards.add(accumulatedRewards[account]);
    }

    // -------------------------------------------------------------------------
    // Asset rewards
    // -------------------------------------------------------------------------

    /**
     * @notice This function should allow governance to let a token pay rewards. Pools that take their fee
     *         in the token can then pay it in through addTokenRewards.
     * @dev IMPORTANT FUNCTION:
     *      - a token cannot be taken off the list: lockers may still have rewards in it
     *      - only plain tokens should be added. This contract shares whatever balance of the token it
     *        holds, so a token whose balances change by themselves (rebasing) would break its accounting
     *      - TORN is refused. It has its own rewards (getReward), and the TORN held here is the relayers'
     *        stake and those rewards
     * @param token address of the token to add
     */
    function addRewardToken(address token) external onlyGovernance {
        require(token != address(torn), "TORN has its own rewards");
        require(Address.isContract(token), "reward token is not a contract");
        require(rewardTokenNumber[token] == 0, "reward token already added");
        require(rewardTokens.length < MAX_REWARD_TOKENS, "too many reward tokens");
        rewardTokens.push(token);
        uint256 number = rewardTokens.length;
        rewardTokenNumber[token] = number;
        // Checkpoints taken so far have version 0 for this token, which must stay at no rewards: the
        // first payment starts version 1.
        assetVersions = assetVersions | (1 << (NOTED_SHIFT + number));
        emit RewardTokenAdded(token);
    }

    /**
     * @notice This function should return the tokens that pay rewards.
     */
    function getRewardTokens() external view returns (address[] memory) {
        return rewardTokens;
    }

    /**
     * @notice This function should tell whether a token pays rewards.
     */
    function isRewardToken(address token) public view returns (bool) {
        return rewardTokenNumber[token] != 0;
    }

    /**
     * @notice This function should return how many checkpoints an account has.
     */
    function checkpointCount(address account) external view returns (uint256) {
        return checkpoints[account][0] >> COUNT_SHIFT;
    }

    /**
     * @notice This function should return the sum asset_added_i/locked_amount_i*coefficient of an asset
     * @param asset ETH or a reward token
     */
    function accumulatedAssetRewardPerTorn(address asset) external view returns (uint256) {
        return assetRewardPerTornAt[asset][_version(assetVersions, rewardTokenNumber[asset])];
    }

    /**
     * @notice This function should add the ETH sent with the call to the rewards of the TORN lockers.
     *         It is the ETH counterpart of addBurnRewards and is called by the fee-enforced pools on each
     *         withdrawal that pays its fee in ETH.
     * @dev IMPORTANT FUNCTION:
     *      - callable by anyone: the caller can only give ETH to the lockers
     *      - reverts when no TORN is locked (division by zero), so the caller keeps its ETH
     */
    function addEthRewards() external payable {
        _addAssetRewards(ETH, 0, msg.value);
    }

    /**
     * @notice This function should add to the rewards of the TORN lockers the amount of a reward token
     *         that reached this contract since the last call. A pool pays a fee by sending the token
     *         here and then calling this.
     * @dev IMPORTANT FUNCTION:
     *      - callable by anyone: it can only share out tokens this contract already holds
     *      - shares what arrived, not what was sent, so a token that keeps part of each transfer cannot
     *        leave this contract owing more than it holds
     *      - reverts when no TORN is locked (division by zero): the tokens stay here and are shared by
     *        the first call made once TORN is locked again
     * @param token address of the reward token
     */
    function addTokenRewards(address token) external {
        uint256 number = rewardTokenNumber[token];
        require(number != 0, "not a reward token");
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 amount = balance.sub(tokenRewardsHeld[token]);
        if (amount == 0) return;
        tokenRewardsHeld[token] = balance;
        _addAssetRewards(token, number, amount);
    }

    /**
     * @notice This function should safely send a user his ETH rewards. It is the ETH counterpart of
     *         getReward, which stays TORN only.
     * @dev IMPORTANT FUNCTION:
     *      - notes the claim down before the ETH is sent
     */
    function getEthReward() external {
        getEthRewardUpTo(uint256(-1));
    }

    /**
     * @notice This function should send a user the ETH rewards worked out from a limited number of his
     *         checkpoints, for an account with so many that getEthReward would run out of gas. Calling
     *         it again goes on from there.
     * @param maxCheckpoints the most checkpoints to go through
     */
    function getEthRewardUpTo(uint256 maxCheckpoints) public {
        uint256 rewards = _claimAssetReward(ETH, 0, maxCheckpoints);
        (bool success, ) = msg.sender.call{ value: rewards }("");
        require(success, "ETH transfer failed");
    }

    /**
     * @notice This function should safely send a user his rewards in a reward token.
     * @dev IMPORTANT FUNCTION:
     *      - notes the claim down before the token is sent
     * @param token address of the reward token
     */
    function getTokenReward(address token) external {
        getTokenRewardUpTo(token, uint256(-1));
    }

    /**
     * @notice This function should send a user the rewards in a reward token worked out from a limited
     *         number of his checkpoints. See getEthRewardUpTo.
     * @param token address of the reward token
     * @param maxCheckpoints the most checkpoints to go through
     */
    function getTokenRewardUpTo(address token, uint256 maxCheckpoints) public {
        uint256 number = rewardTokenNumber[token];
        require(number != 0, "not a reward token");
        uint256 rewards = _claimAssetReward(token, number, maxCheckpoints);
        tokenRewardsHeld[token] = tokenRewardsHeld[token].sub(rewards);
        if (rewards != 0) IERC20(token).safeTransfer(msg.sender, rewards);
    }

    /**
     * @notice This function should show a user his ETH rewards.
     * @param account address of account to calculate ETH rewards for
     */
    function checkEthReward(address account) external view returns (uint256 rewards) {
        (rewards, ) = _assetRewardsOf(ETH, 0, account, uint256(-1));
    }

    /**
     * @notice This function should show a user his rewards in a reward token.
     * @param token address of the reward token
     * @param account address of account to calculate rewards for
     */
    function checkTokenReward(address token, address account) external view returns (uint256 rewards) {
        uint256 number = rewardTokenNumber[token];
        if (number != 0) (rewards, ) = _assetRewardsOf(token, number, account, uint256(-1));
    }

    /**
     * @notice This function should increment the proper amount of rewards per torn for an asset
     * @dev Asset counterpart of addBurnRewards
     *      - the result must fit in 128 bits. No real amount gets near that: it takes more than 3e13
     *        ETH, or as many whole tokens of 18 decimals, per TORN locked
     *      - if a checkpoint notes the latest version down, the new value goes into a new version
     * @param asset ETH or the reward token paid in
     * @param number the number of the asset: 0 for ETH, rewardTokenNumber for a token
     * @param amount amount to add to the rewards
     */
    function _addAssetRewards(
        address asset,
        uint256 number,
        uint256 amount
    ) private {
        uint256 versions = assetVersions;
        uint256 version = _version(versions, number);
        uint256 rewardPerTorn = assetRewardPerTornAt[asset][version].add(
            amount.mul(ratioConstant).div(torn.balanceOf(address(Governance.userVault())))
        );
        require(rewardPerTorn <= uint128(-1), "reward per torn too large");

        uint256 noted = 1 << (NOTED_SHIFT + number);
        if (versions & noted != 0) {
            require(version < VERSION_MAX, "too many versions");
            version = version + 1;
            // one more in the asset's 24 bits, which cannot carry into the next asset's, and the bit off
            assetVersions = (versions ^ noted) + (1 << (number * VERSION_BITS));
        }
        assetRewardPerTornAt[asset][version] = rewardPerTorn;
        emit AssetRewardsAdded(asset, msg.sender, amount);
    }

    /**
     * @notice This function should take a checkpoint of an account before its locked balance changes:
     *         the balance it had locked until now and the latest version of every asset.
     * @dev IMPORTANT FUNCTION:
     *      - it must not revert, and it must stay cheap: Governance goes on with the lock or unlock
     *        even if updateRewardsOnLockedBalanceChange fails, and the rewards of the account would then
     *        be worked out on a wrong balance. It calls no other contract and writes at most three
     *        storage words, whatever the number of assets
     *      - nothing is written if nothing was paid in, in any asset, since the account's last checkpoint
     * @param account address of account to take the checkpoint of
     * @param amountLockedBeforehand the balance locked beforehand in the governance contract
     */
    function _takeCheckpoint(address account, uint256 amountLockedBeforehand) private {
        uint256 versions = assetVersions;
        uint256 first = checkpoints[account][0];
        uint256 count = first >> COUNT_SHIFT;
        if (count != 0) {
            uint256 last = count == 1 ? first : checkpoints[account][count - 1];
            if ((last ^ versions) & VERSIONS_MASK == 0) return;
            // No room for another one: the account stops earning in assets (see _assetRewardsOf).
            if (count == COUNT_MAX) return;
        }
        if (versions & ALL_NOTED != ALL_NOTED) assetVersions = versions | ALL_NOTED;

        // The locked balance always fits in 88 bits: there are fewer than 2**84 units of TORN.
        if (amountLockedBeforehand > BALANCE_MAX) amountLockedBeforehand = BALANCE_MAX;
        uint256 checkpoint = (versions & VERSIONS_MASK) | (amountLockedBeforehand << BALANCE_SHIFT);
        if (count == 0) {
            checkpoints[account][0] = checkpoint | (1 << COUNT_SHIFT);
        } else {
            checkpoints[account][count] = checkpoint;
            checkpoints[account][0] = first + (1 << COUNT_SHIFT);
        }
    }

    /**
     * @notice This function should calculated the rewards in an asset attributed to an account since its
     *         last claim: for each stretch between two checkpoints, the rise of the reward per TORN
     *         times the TORN it had locked, and the same for the stretch since the last checkpoint
     *         with the TORN it has locked now.
     * @dev Asset counterpart of the calculation in _updateReward and checkReward
     * @param asset ETH or the reward token to calculate rewards in
     * @param number the number of the asset: 0 for ETH, rewardTokenNumber for a token
     * @param account address of account to calculate rewards for
     * @param maxCheckpoints the most checkpoints to go through
     * @return rewards the rewards attributed to the account
     * @return claimed what to note down in claimedUpTo if they are paid
     */
    function _assetRewardsOf(
        address asset,
        uint256 number,
        address account,
        uint256 maxCheckpoints
    ) private view returns (uint256 rewards, uint256 claimed) {
        claimed = claimedUpTo[asset][account];
        uint256 next = claimed & COUNT_MAX;
        uint256 rewardPerTorn = claimed >> VERSION_BITS;
        uint256 first = checkpoints[account][0];
        uint256 count = first >> COUNT_SHIFT;
        uint256 end = count - next > maxCheckpoints ? next + maxCheckpoints : count;

        for (; next < end; next++) {
            uint256 checkpoint = next == 0 ? first : checkpoints[account][next];
            uint256 rewardPerTornThen = assetRewardPerTornAt[asset][_version(checkpoint, number)];
            uint256 amountLocked = (checkpoint >> BALANCE_SHIFT) & BALANCE_MAX;
            rewards = rewards.add((rewardPerTornThen.sub(rewardPerTorn)).mul(amountLocked).div(ratioConstant));
            rewardPerTorn = rewardPerTornThen;
        }
        // An account that has used up its checkpoints earns nothing since the last one: a change of its
        // balance could no longer be noted down.
        if (next == count && count != COUNT_MAX) {
            uint256 rewardPerTornNow = assetRewardPerTornAt[asset][_version(assetVersions, number)];
            rewards = rewards.add(
                (rewardPerTornNow.sub(rewardPerTorn)).mul(Governance.lockedBalance(account)).div(ratioConstant)
            );
            rewardPerTorn = rewardPerTornNow;
        }
        claimed = (rewardPerTorn << VERSION_BITS) | next;
    }

    /**
     * @notice This function should take the rewards of the caller in an asset, for them to be sent
     * @dev - notes the claim down greedily
     * @return rewards the amount to send to the caller
     */
    function _claimAssetReward(
        address asset,
        uint256 number,
        uint256 maxCheckpoints
    ) private returns (uint256 rewards) {
        uint256 claimed;
        (rewards, claimed) = _assetRewardsOf(asset, number, msg.sender, maxCheckpoints);
        claimedUpTo[asset][msg.sender] = claimed;
        emit AssetRewardsClaimed(asset, msg.sender, rewards);
    }

    /// @dev The version of an asset in a checkpoint or in assetVersions
    function _version(uint256 word, uint256 number) private pure returns (uint256) {
        return (word >> (number * VERSION_BITS)) & VERSION_MAX;
    }
}
