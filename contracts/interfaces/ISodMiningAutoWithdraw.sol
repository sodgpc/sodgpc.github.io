// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

interface ISodMiningAutoWithdraw {
    struct RewardQuote {
        uint256 staticRewardUsdt;
        uint256 communityRewardUsdt;
        uint256 totalRewardUsdt;
        uint256 grossGpc;
        uint256 gpcPrice;
        uint256 poolValueUsdt;
        uint256 smallAreaPower;
        uint256 effectiveSmallAreaPower;
        bool poolLimitedMode;
    }

    function name() external view returns (string memory);
    function usdt() external view returns (address);
    function gpc() external view returns (address);
    function ORDER_USDT() external view returns (uint256);
    function POWER_PER_ORDER() external view returns (uint256);
    function autoWithdrawDelegate(address account) external view returns (address);
    function paused() external view returns (bool);
    function historyRegistry() external view returns (address);
    function users(address account) external view returns (
        uint256 power, uint256 totalPowerPurchased, uint256 legacyReserved,
        uint64 lastOrderAt, uint64 nextWithdrawAt, uint64 inactivityStartedAt
    );
    function quoteRewards(address account) external view returns (RewardQuote memory);
    function miningPoolGpc() external view returns (uint256);
    function withdrawWindowStartedAt() external view returns (uint256);
    function withdrawWindowPoolBase() external view returns (uint256);
    function withdrawnGpcInWindow() external view returns (uint256);
    function withdrawFor(address beneficiary) external returns (uint256 netGpc);
}
