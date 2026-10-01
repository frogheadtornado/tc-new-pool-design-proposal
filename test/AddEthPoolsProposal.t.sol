// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ProposalFixture, IInstanceRegistry, ITornadoInstance, IFeeEnforcedTornado} from "./utils/ProposalFixture.sol";

/**
 * @dev Mainnet-fork E2E: spoof a large TORN holder, run propose → vote → execute
 *      with time warps matching live governance delays, then deposit via TornadoRouter
 *      into each newly registered ETH pool.
 *
 * @dev Bytecode gate (test-only): every pool is `FeeEnforcedTornado_eth`, so each pool's
 *      runtime code must equal the compiled artifact of `src/FeeEnforcedTornado_eth.sol`.
 *      Runtime = [EVM body || solc CBOR metadata || uint16 metaLen]; we compare the EVM body
 *      so the check does not depend on the metadata hash.
 */
contract AddEthPoolsProposalTest is ProposalFixture {
    /// @dev Metadata-stripped runtime of the compiled FeeEnforcedTornado_eth artifact.
    bytes private _artifactEvmBody;

    function setUp() external {
        _forkAndDeployProposal();
        _artifactEvmBody = _stripMetadata(vm.getDeployedCode("FeeEnforcedTornado_eth.sol:FeeEnforcedTornado_eth"));
        assertTrue(_artifactEvmBody.length > 0, "artifact EVM body empty");
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

        // 0.01, 0.03, 0.3 ETH: protocol fee 0, so registered relayers pay nothing and direct
        // withdrawals pay only the 0.3% premium.
        // 3, 30 ETH: protocol fee 0.3% (TORN for registered relayers), direct withdrawals pay 0.3% + 0.3% premium.
        _assertPool(pool001, _DENOM_001, 0);
        _assertPool(pool003, _DENOM_003, 0);
        _assertPool(pool03, _DENOM_03, 0);
        _assertPool(pool3, _DENOM_3, 30);
        _assertPool(pool30, _DENOM_30, 30);

        // --- Router deposits into every new instance ---
        address depositor = makeAddr("depositor");
        _depositViaRouter(depositor, pool001, _DENOM_001, "c-0.01");
        _depositViaRouter(depositor, pool003, _DENOM_003, "c-0.03");
        _depositViaRouter(depositor, pool03, _DENOM_03, "c-0.3");
        _depositViaRouter(depositor, pool3, _DENOM_3, "c-3");
        _depositViaRouter(depositor, pool30, _DENOM_30, "c-30");
    }

    function _assertPool(address pool, uint256 denomination, uint32 fee) internal view {
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
        assertEq(protocolFee, fee, "registry fee (TORN burned on registered-relayer withdrawals)");

        IFeeEnforcedTornado feePool = IFeeEnforcedTornado(pool);
        assertEq(feePool.protocolFeePercentage(), fee, "pool protocol fee == registry fee");
        assertEq(feePool.directWithdrawPremiumPercentage(), 30, "premium");
        assertEq(feePool.directWithdrawFeePercentage(), fee + 30, "direct withdraw fee");
        assertEq(feePool.accruedProtocolFees(), 0, "accrued fees");
        assertEq(feePool.RELAYER_REGISTRY(), _RELAYER_REGISTRY, "relayer registry");
        assertEq(feePool.GOVERNANCE(), _GOVERNANCE, "fee recipient");

        assertEq(_stripMetadata(pool.code), _artifactEvmBody, "pool code != FeeEnforcedTornado_eth artifact");
    }

    /// @dev Drop solc CBOR metadata trailer (last 2 bytes = big-endian metadata length).
    function _stripMetadata(bytes memory code) internal pure returns (bytes memory) {
        require(code.length >= 2, "code too short");
        uint256 metaLen = (uint256(uint8(code[code.length - 2])) << 8) + uint256(uint8(code[code.length - 1]));
        require(code.length >= metaLen + 2, "metadata length");
        uint256 keep = code.length - metaLen - 2;
        bytes memory out = new bytes(keep);
        for (uint256 i = 0; i < keep; i++) {
            out[i] = code[i];
        }
        return out;
    }
}
