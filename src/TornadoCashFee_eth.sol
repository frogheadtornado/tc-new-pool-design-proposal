// SPDX-License-Identifier: MIT
pragma solidity ^0.5.8;

import "./classic/TornadoCash_eth.sol";

/**
 * @notice Classic ETH Tornado pool that cannot be withdrawn from without paying the DAO.
 *         - Withdrawals sent through the TornadoRouter by a registered relayer pay the protocol
 *           fee as burned TORN stake (RelayerRegistry.burn), so the pool charges nothing extra.
 *         - Any other withdrawal (direct call, self-relay, "custom relayer" through the Router)
 *           pays `protocolFeePercentage + directWithdrawPremiumPercentage` of the denomination in ETH,
 *           sent to Governance in the same transaction. If that transfer fails, the fee accrues
 *           in the pool instead and anyone can sweep it to Governance later.
 * @dev Inherits the verified classic `Tornado` base unchanged; only `_processWithdraw` differs
 *      from `TornadoCash_eth`. Governance can change `protocolFeePercentage` up to the hard cap
 *      `MAX_PROTOCOL_FEE_PERCENTAGE` and `directWithdrawPremiumPercentage` up to
 *      `MAX_DIRECT_WITHDRAW_PREMIUM_PERCENTAGE`; registry and fee recipient are fixed at deploy.
 */
contract TornadoCashFee_eth is Tornado {
    address public constant RELAYER_REGISTRY = 0x58E8dCC13BE9780fC42E8723D8EaD4CF46943dF2;
    address payable public constant GOVERNANCE = 0x5efda50f22d34F262c29268506C5Fa42cB56A1Ce;
    // Same scale as FeeManager.PROTOCOL_FEE_DIVIDER and the registry's protocolFeePercentage: 30 = 0.3%.
    uint256 public constant PROTOCOL_FEE_DIVIDER = 10000;
    // Hard caps so that a compromised Governance cannot drain deposits through the fee.
    // Worst case for a direct withdrawal: 100 + 400 = 500 = 5%.
    uint256 public constant MAX_PROTOCOL_FEE_PERCENTAGE = 100;
    uint256 public constant MAX_DIRECT_WITHDRAW_PREMIUM_PERCENTAGE = 400;
    // Gas forwarded to Governance with each fee payment. Governance needs ~5.3k to accept ETH;
    // the cap stops a broken or malicious receiver from making withdrawals run out of gas.
    uint256 public constant FEE_TRANSFER_GAS = 50000;

    uint256 public protocolFeePercentage;
    uint256 public directWithdrawPremiumPercentage;
    uint256 public accruedProtocolFees;

    event ProtocolFeeCharged(address indexed relayer, uint256 amount, bool paidToGovernance);
    event ProtocolFeesSwept(uint256 amount);
    event ProtocolFeeUpdated(uint256 oldFeePercentage, uint256 newFeePercentage);
    event DirectWithdrawPremiumUpdated(uint256 oldPremiumPercentage, uint256 newPremiumPercentage);

    modifier onlyGovernance() {
        require(msg.sender == GOVERNANCE, "Only governance");
        _;
    }

    constructor(
        IVerifier _verifier,
        uint256 _denomination,
        uint32 _merkleTreeHeight,
        address _operator,
        uint256 _protocolFeePercentage,
        uint256 _directWithdrawPremiumPercentage
    ) public Tornado(_verifier, _denomination, _merkleTreeHeight, _operator) {
        require(_protocolFeePercentage <= MAX_PROTOCOL_FEE_PERCENTAGE, "Fee above cap");
        require(_directWithdrawPremiumPercentage <= MAX_DIRECT_WITHDRAW_PREMIUM_PERCENTAGE, "Premium above cap");
        protocolFeePercentage = _protocolFeePercentage;
        directWithdrawPremiumPercentage = _directWithdrawPremiumPercentage;
    }

    /**
     * @notice Fee charged in ETH on withdrawals that do not go through a registered relayer:
     *         protocol fee + premium, in PROTOCOL_FEE_DIVIDER units (30 + 30 = 60 = 0.6%).
     */
    function directWithdrawFeePercentage() public view returns (uint256) {
        return protocolFeePercentage + directWithdrawPremiumPercentage;
    }

    /**
     * @notice Fee in wei charged in ETH on withdrawals that do not go through a registered relayer.
     */
    function directWithdrawFee() public view returns (uint256) {
        return denomination * directWithdrawFeePercentage() / PROTOCOL_FEE_DIVIDER;
    }

    /**
     * @notice Change the protocol fee. Keep it in sync with the InstanceRegistry's
     *         `protocolFeePercentage`, which sets the TORN burned on registered-relayer withdrawals.
     */
    function setProtocolFeePercentage(uint256 _protocolFeePercentage) external onlyGovernance {
        require(_protocolFeePercentage <= MAX_PROTOCOL_FEE_PERCENTAGE, "Fee above cap");
        emit ProtocolFeeUpdated(protocolFeePercentage, _protocolFeePercentage);
        protocolFeePercentage = _protocolFeePercentage;
    }

    /**
     * @notice Change the premium added to the protocol fee on withdrawals that do not go
     *         through a registered relayer.
     */
    function setDirectWithdrawPremiumPercentage(uint256 _directWithdrawPremiumPercentage) external onlyGovernance {
        require(_directWithdrawPremiumPercentage <= MAX_DIRECT_WITHDRAW_PREMIUM_PERCENTAGE, "Premium above cap");
        emit DirectWithdrawPremiumUpdated(directWithdrawPremiumPercentage, _directWithdrawPremiumPercentage);
        directWithdrawPremiumPercentage = _directWithdrawPremiumPercentage;
    }

    function _processDeposit() internal {
        require(msg.value == denomination, "Please send `mixDenomination` ETH along with transaction");
    }

    function _processWithdraw(address payable _recipient, address payable _relayer, uint256 _fee, uint256 _refund)
        internal
    {
        // sanity checks
        require(msg.value == 0, "Message value is supposed to be zero for ETH instance");
        require(_refund == 0, "Refund value is supposed to be zero for ETH instance");

        uint256 protocolFee = isRegisteredRelayerWithdrawal(msg.sender, _relayer) ? 0 : directWithdrawFee();
        // _fee <= denomination and protocolFee <= denomination are already enforced, so the sum cannot overflow
        require(_fee + protocolFee <= denomination, "Fees exceed transfer value");
        if (protocolFee > 0) {
            bool paid = _payGovernance(protocolFee);
            if (!paid) {
                accruedProtocolFees += protocolFee;
            }
            emit ProtocolFeeCharged(_relayer, protocolFee, paid);
        }

        (bool success,) = _recipient.call.value(denomination - _fee - protocolFee)("");
        require(success, "payment to _recipient did not go thru");
        if (_fee > 0) {
            (success,) = _relayer.call.value(_fee)("");
            require(success, "payment to _relayer did not go thru");
        }
    }

    /**
     * @notice True when the withdrawal comes through the current TornadoRouter on behalf of a
     *         registered relayer master. In that case the Router has already called
     *         RelayerRegistry.burn, which requires the Router's caller to be a worker of
     *         `_relayer` and burns the protocol fee from its stake.
     * @dev `_relayer == 0` is rejected: workers(0) == 0, and burn lets an unregistered caller
     *      through without burning when the named relayer is unregistered.
     *      Registry calls are low-level so that a broken or upgraded registry can never block
     *      withdrawals; it only means the direct-withdrawal fee is charged.
     */
    function isRegisteredRelayerWithdrawal(address _caller, address _relayer) public view returns (bool) {
        if (_relayer == address(0)) return false;
        (bool ok, address router) = _registryAddressCall(abi.encodeWithSignature("tornadoRouter()"));
        if (!ok || router != _caller) return false;
        (bool okMaster, address master) = _registryAddressCall(abi.encodeWithSignature("workers(address)", _relayer));
        return okMaster && master == _relayer;
    }

    /**
     * @dev Send fees that could not be paid during withdrawal to Governance. Callable by anyone.
     */
    function sweepProtocolFees() external nonReentrant {
        uint256 amount = accruedProtocolFees;
        require(amount > 0, "Nothing to sweep");
        accruedProtocolFees = 0;
        (bool success,) = GOVERNANCE.call.value(amount)("");
        require(success, "payment to GOVERNANCE did not go thru");
        emit ProtocolFeesSwept(amount);
    }

    /**
     * @dev Pays Governance without ever reverting the withdrawal. Uses a raw call with capped
     *      gas and no return data copy, so the receiver can neither consume all the gas nor
     *      return a large payload that makes the copy run out of gas.
     */
    function _payGovernance(uint256 _amount) internal returns (bool paid) {
        address payable receiver = GOVERNANCE;
        uint256 gasLimit = FEE_TRANSFER_GAS;
        assembly {
            paid := call(gasLimit, receiver, _amount, 0, 0, 0, 0)
        }
    }

    function _registryAddressCall(bytes memory _data) internal view returns (bool, address) {
        (bool ok, bytes memory ret) = RELAYER_REGISTRY.staticcall(_data);
        if (!ok || ret.length < 32) return (false, address(0));
        return (true, abi.decode(ret, (address)));
    }
}
