// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

interface IGpcPriceOracle {
    /// @notice Trailing six-hour TWAP, quoted as 18-decimal USDT per GPC.
    function price() external view returns (uint256);

    /// @notice Trailing six-hour TWAP, quoted as 18-decimal USDT per WBNB.
    function bnbPrice() external view returns (uint256);
}
