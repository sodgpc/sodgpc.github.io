// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;
interface ISodHistoryRegistry {
    function writer() external view returns (address);
    function appendPower(address account, uint256 amount, uint8 kind) external;
}
