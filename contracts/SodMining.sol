// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {SodMiningCore} from './SodMiningCore.sol';

/// @notice Independent SOD business implementation for a Transparent Proxy.
contract SodMining is SodMiningCore {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(
        address usdt_, address gpc_, address wbnb_, address router_, address oracle_,
        address operationWallet_, address technicalWallet_, address referralRoot_, address businessOwner_
    ) external initializer {
        __SodMiningCore_init(
            usdt_, gpc_, wbnb_, router_, oracle_, operationWallet_, technicalWallet_, referralRoot_, businessOwner_
        );
    }
}
