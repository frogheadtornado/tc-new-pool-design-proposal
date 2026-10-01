// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ProposalFixture, IInstanceRegistry, ITornadoInstance, ITornadoFeeInstance} from "./utils/ProposalFixture.sol";

/**
 * @dev Mainnet-fork E2E: spoof a large TORN holder, run propose → vote → execute
 *      with time warps matching live governance delays, then deposit via TornadoRouter
 *      into each newly registered ETH pool.
 *
 * @dev Bytecode gate (test-only): `extcodehash` = keccak256(runtime). Runtime =
 *      [EVM body || solc CBOR metadata || uint16 metaLen]. We strip the metadata
 *      trailer and require the EVM body to equal the live 1 ETH pool byte-for-byte.
 *      Full extcodehash still differs (native solc 22be8592 vs emscripten c082d0b4).
 *      Only the no-fee pools (<= 1 ETH) are classic; 3 and 30 ETH are `TornadoCashFee_eth`.
 */
contract AddEthPoolsProposalTest is ProposalFixture {
    /// @dev Metadata-stripped runtime of live 1 ETH (the EVM body inside extcodehash).
    bytes private _live1EthEvmBody;

    function setUp() external {
        _forkAndDeployProposal();
        assertTrue(_LIVE_1_ETH.code.length > 0, "live 1 ETH code empty");
        _live1EthEvmBody = _evmBodyOfExtcode(_LIVE_1_ETH);
        assertTrue(_live1EthEvmBody.length > 0, "live 1 ETH EVM body empty");
    }

    function testGovernanceVoteExecuteAndRouterDeposits() external {
        assertEq(vm.activeFork(), _forkId);
        assertTrue(_proposal.code.length > 0, "proposal not deployed");

        uint256 addressesBefore = _passAndExecuteProposal();

        // --- Five new pools registered ---
        address[] memory all = _registry.getAllInstanceAddresses();
        assertEq(all.length, addressesBefore + 5);

        address pool001 = _findNewPool(all, addressesBefore, _DENOM_001);
        address pool003 = _findNewPool(all, addressesBefore, _DENOM_003);
        address pool03 = _findNewPool(all, addressesBefore, _DENOM_03);
        address pool3 = _findNewPool(all, addressesBefore, _DENOM_3);
        address pool30 = _findNewPool(all, addressesBefore, _DENOM_30);

        _assertEthPool(pool001, _DENOM_001);
        _assertEthPool(pool003, _DENOM_003);
        _assertEthPool(pool03, _DENOM_03);
        _assertEthPool(pool3, _DENOM_3);
        _assertEthPool(pool30, _DENOM_30);

        // Bytecode match vs live 1 ETH for the no-fee pools (see _assertExtcodeEvmBodyMatchesLive1Eth).
        // We strip the solc CBOR metadata trailer first: full extcodehash differs slightly
        // because Foundry's native 0.5.11 metadata != historical emscripten c082d0b4 metadata,
        // while the EVM body is identical.
        _assertExtcodeEvmBodyMatchesLive1Eth(pool001);
        _assertExtcodeEvmBodyMatchesLive1Eth(pool003);
        _assertExtcodeEvmBodyMatchesLive1Eth(pool03);

        // Fee pools run TornadoCashFee_eth: different code, direct withdrawals pay the 0.3% fee + 0.3% premium.
        _assertFeePool(pool3);
        _assertFeePool(pool30);

        // --- Router deposits into every new instance ---
        address depositor = makeAddr("depositor");
        _depositViaRouter(depositor, pool001, _DENOM_001, "c-0.01");
        _depositViaRouter(depositor, pool003, _DENOM_003, "c-0.03");
        _depositViaRouter(depositor, pool03, _DENOM_03, "c-0.3");
        _depositViaRouter(depositor, pool3, _DENOM_3, "c-3");
        _depositViaRouter(depositor, pool30, _DENOM_30, "c-30");
    }

    function _assertEthPool(address pool, uint256 denomination) internal view {
        assertEq(ITornadoInstance(pool).denomination(), denomination);
        assertEq(ITornadoInstance(pool).verifier(), _VERIFIER, "verifier");
        assertEq(ITornadoInstance(pool).levels(), uint32(20), "levels");
        assertEq(ITornadoInstance(pool).operator(), address(0), "operator");

        (bool isERC20, address token, IInstanceRegistry.InstanceState state, uint24 uniswapFee, uint32 protocolFee) =
            _registry.instances(pool);
        assertFalse(isERC20);
        assertEq(token, address(0));
        assertTrue(state == IInstanceRegistry.InstanceState.ENABLED);
        assertEq(uniswapFee, uint24(0));
        assertEq(protocolFee, denomination > 1 ether ? uint32(30) : uint32(0));
    }

    function _assertFeePool(address pool) internal view {
        ITornadoFeeInstance feePool = ITornadoFeeInstance(pool);
        assertEq(feePool.protocolFeePercentage(), 30, "protocol fee");
        assertEq(feePool.directWithdrawPremiumPercentage(), 30, "premium");
        assertEq(feePool.directWithdrawFeePercentage(), 60, "direct withdraw fee");
        assertEq(feePool.accruedProtocolFees(), 0, "accrued fees");
        assertEq(feePool.RELAYER_REGISTRY(), _RELAYER_REGISTRY, "relayer registry");
        assertEq(feePool.GOVERNANCE(), _GOVERNANCE, "fee recipient");
        assertTrue(keccak256(_evmBodyOfExtcode(pool)) != keccak256(_live1EthEvmBody), "fee pool must differ");
    }

    /**
     * @dev Assert the EVM body embedded in `extcodehash(pool)` matches live 1 ETH.
     *      `extcodehash` = keccak256(runtime); runtime = EVM body || CBOR metadata || len.
     *      We compare the stripped EVM body bytes (not full codehash).
     */
    function _assertExtcodeEvmBodyMatchesLive1Eth(address pool) internal view {
        bytes memory poolBody = _evmBodyOfExtcode(pool);
        // Stripping: compare EVM body only — full extcodehash differs by slight solc
        // metadata inconsistencies (CBOR trailer); the executable bytecode must match.
        assertEq(poolBody, _live1EthEvmBody, "extcode EVM body != live 1 ETH");
        // Sanity: full hashes differ only because of the metadata trailer we stripped.
        assertTrue(pool.codehash != _LIVE_1_ETH.codehash, "expected full extcodehash to differ (metadata)");
        assertEq(
            keccak256(abi.encodePacked(poolBody, _metadataTrailer(pool.code))),
            pool.codehash,
            "pool extcodehash != keccak(body||metadata)"
        );
    }

    /// @dev EVM body of `extcodehash` input: runtime with solc CBOR metadata trailer removed.
    function _evmBodyOfExtcode(address account) internal view returns (bytes memory) {
        return _stripMetadata(account.code);
    }

    /// @dev Drop solc CBOR metadata trailer (last 2 bytes = big-endian metadata length).
    function _stripMetadata(bytes memory code) internal pure returns (bytes memory) {
        (uint256 keep,) = _splitRuntime(code);
        bytes memory out = new bytes(keep);
        for (uint256 i = 0; i < keep; i++) {
            out[i] = code[i];
        }
        return out;
    }

    function _metadataTrailer(bytes memory code) internal pure returns (bytes memory) {
        (uint256 keep, uint256 metaLen) = _splitRuntime(code);
        bytes memory out = new bytes(metaLen + 2);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = code[keep + i];
        }
        return out;
    }

    function _splitRuntime(bytes memory code) internal pure returns (uint256 keep, uint256 metaLen) {
        require(code.length >= 2, "code too short");
        metaLen = (uint256(uint8(code[code.length - 2])) << 8) + uint256(uint8(code[code.length - 1]));
        require(code.length >= metaLen + 2, "metadata length");
        keep = code.length - metaLen - 2;
    }
}
