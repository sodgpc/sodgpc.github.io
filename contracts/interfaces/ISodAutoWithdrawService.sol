// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/// @notice Minimal binding and credit checks required by the Mining contract.
interface ISodAutoWithdrawService {
    function mining() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
}
