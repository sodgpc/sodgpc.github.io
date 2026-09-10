// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {SodRollingSixHourOracle} from './SodRollingSixHourOracle.sol';

/// @notice Configurable rolling Oracle deployed behind its own Transparent Proxy.
contract SodOracle is SodRollingSixHourOracle {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(address router_, address gpc_, address wbnb_, address usdt_) external initializer {
        __SodSixHourOracle_init(router_, gpc_, wbnb_, usdt_);
        _initializeRolling();
    }
}
