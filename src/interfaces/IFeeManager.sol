// SPDX-License-Identifier: MIT
pragma solidity ^0.5.8;

import "./IInstanceRegistry.sol";

/**
 * @dev The FeeManager turns a pool's registry `protocolFeePercentage` into the TORN amount burned
 *      from a relayer's stake, and caches it per pool.
 */
interface IFeeManager {
    function updateFee(ITornadoInstance _instance) external;
}
