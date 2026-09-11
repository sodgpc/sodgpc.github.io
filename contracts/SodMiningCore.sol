// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {Initializable} from '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import {Ownable2StepUpgradeable} from '@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol';
import {PausableUpgradeable} from '@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol';
import {ReentrancyGuardUpgradeable} from '@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol';
import {IGpcPriceOracle} from './interfaces/IGpcPriceOracle.sol';
import {IPancakeFactory} from './interfaces/IPancakeFactory.sol';
import {IPancakePair} from './interfaces/IPancakePair.sol';
import {IPancakeRouterV2} from './interfaces/IPancakeRouterV2.sol';
import {ISodAutoWithdrawService} from './interfaces/ISodAutoWithdrawService.sol';
import {ISodHistoryRegistry} from './interfaces/ISodHistoryRegistry.sol';

/**
 * @title SodMiningCore
 * @notice Fixed product purchases, GPC rewards and 30-level community accounting.
 * @dev All project addresses are provided explicitly to the initializer.
 */
abstract contract SodMiningCore is
    Initializable,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    IERC20Metadata
{
    using SafeERC20 for IERC20;

    uint256 public constant ORDER_USDT = 700 ether;
    uint256 public constant POWER_PER_ORDER = 1_000 ether;
    uint256 public constant DIRECT_REWARD = 35 ether;
    uint256 public constant OPERATION_SHARE = 265 ether;
    uint256 public constant USDT_TO_GPC = 400 ether;
    uint256 public constant BPS = 10_000;
    uint256 public constant FIXED_DAILY_RATE_BPS = 35;
    uint256 public constant COMMUNITY_RATE_BPS = 1_000;
    uint256 public constant MAX_DAILY_RATE_BPS = 70;
    uint256 public constant WITHDRAW_FEE_BPS = 500;
    uint256 public constant MAX_WITHDRAW_POOL_BPS = 100;
    uint256 public constant MAX_GLOBAL_DAILY_WITHDRAW_POOL_BPS = 200;
    uint256 public constant SWAP_SLIPPAGE_BPS = 200;
    uint256 public constant SPOT_TWAP_MAX_DEVIATION_BPS = 100;
    uint256 public constant ORDER_COOLDOWN = 1 minutes;
    uint256 public constant WITHDRAW_COOLDOWN = 24 hours;
    uint256 public constant INACTIVITY_PERIOD = 180 days;
    uint256 public constant MAX_DEADLINE_WINDOW = 1 minutes;
    uint256 public constant MAX_REFERRAL_DEPTH = 30;
    uint256 private constant MAX_AUTO_EXPIRE_BATCH = 20;
    uint8 private constant POWER_HISTORY_ORDER = 1;
    uint8 private constant POWER_HISTORY_WITHDRAW = 2;
    uint8 private constant POWER_HISTORY_EXPIRED = 3;
    uint8 private constant POWER_HISTORY_REFERRAL = 5;
    string public constant override name = 'SOD POWER';
    string public constant override symbol = 'SODP';
    uint8 public constant override decimals = 18;

    struct UserInfo {
        uint256 power;
        uint256 totalPowerPurchased;
        // Reserved zero value preserves the six-field account shape used by the DApp.
        uint256 legacyReserved;
        uint64 lastOrderAt;
        uint64 nextWithdrawAt;
        uint64 inactivityStartedAt;
    }

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

    struct DailyCommunityEarnings {
        uint192 rewardUsdt;
        uint64 day;
    }

    struct DailyRewardEarnings {
        uint64 day;
        uint256 grossGpc;
        uint256 staticRewardUsdt;
        uint256 communityRewardUsdt;
    }

    IERC20 public usdt;
    IERC20 public gpc;
    IERC20 public wbnb;
    IPancakeRouterV2 public router;
    IGpcPriceOracle public oracle;
    IPancakePair public gpcWbnbPair;
    IPancakePair public wbnbUsdtPair;
    address public operationWallet;
    address public technicalWallet;
    address public referralRoot;

    uint256 public totalPower;
    uint256 public miningPoolGpc;

    mapping(address => UserInfo) public users;
    mapping(address => address) public parentOf;
    mapping(address => uint8) public referralDepth;
    mapping(address => address[]) private _directReferrals;

    // Each direct child represents one complete referral branch below a leader.
    mapping(address => uint256) public teamPower;
    mapping(address => mapping(address => uint256)) public branchPower;

    // Per-leader max-heaps keep the largest branch query O(1), including after power burns.
    mapping(address => address[]) private _branchHeaps;
    mapping(address => mapping(address => uint256)) private _heapIndexPlusOne;

    uint256 public withdrawWindowStartedAt;
    uint256 public withdrawWindowPoolBase;
    uint256 public withdrawnGpcInWindow;

    // Min-heap ordered by the user's next 180-day inactivity expiry. New orders
    // register automatically; withdrawals move the user to their new expiry.
    address[] private _expiryHeap;
    mapping(address => uint256) private _expiryHeapIndexPlusOne;

    // Bound referral nodes are permanent and counted independently of power.
    mapping(address => uint256) public teamNodeCount;
    mapping(address => bool) private _teamNodeAccounted;

    // One packed slot per user. Day boundaries use UTC+8 to match the DApp's
    // displayed "today" and the project's primary operating timezone.
    mapping(address => DailyCommunityEarnings) public dailyCommunityEarnings;

    ISodHistoryRegistry public historyRegistry;

    // ERC20-compatible approvals are exposed for wallet and explorer compatibility.
    // Mining power itself stays non-transferable so referral accounting, withdrawal
    // cooldowns and inactivity expiry cannot be bypassed by moving balances.
    mapping(address => mapping(address => uint256)) private _powerAllowances;

    // Withdrawals settle into the same daily totals. The DApp
    // reads this state directly instead of scanning RPC event history.
    mapping(address => DailyRewardEarnings) public dailyRewardEarnings;

    // Legacy per-user authorization storage is retained for proxy layout and ABI
    // compatibility. It no longer authorizes withdrawals.
    mapping(address => address) public autoWithdrawDelegate;

    // The single protocol service allowed to settle rewards on behalf of users.
    // Users cannot replace or revoke this owner-managed authorization.
    address public autoWithdrawService;

    // Reserved storage slots for future implementation upgrades.
    uint256[38] private __gap;

    event ReferralBound(address indexed user, address indexed parent, uint256 depth);
    event OrderPlaced(
        address indexed user,
        address indexed parent,
        address indexed directRewardRecipient,
        uint256 gpcBought,
        uint256 gpcAddedToPool
    );
    event Withdrawn(
        address indexed user,
        uint256 staticRewardUsdt,
        uint256 communityRewardUsdt,
        uint256 powerBurned,
        uint256 grossGpc,
        uint256 feeGpc,
        uint256 netGpc,
        uint256 gpcPrice
    );
    event PowerExpired(address indexed user, uint256 powerBurned, uint256 timestamp);
    event ExpiryUserRegistered(address indexed user, uint256 expiresAt);
    event ExpiryBatchProcessed(uint256 checked, uint256 expired, uint256 nextExpiryAt);
    event TeamNodeAccounted(address indexed user, address indexed parent);
    event HistoryTrackingInitialized(address indexed registry);
    event AutoWithdrawDelegateSet(address indexed account, address indexed previousDelegate, address indexed newDelegate);
    event AutoWithdrawServiceInitialized(address indexed service);

    error ZeroAddress();
    error AlreadyBound();
    error ParentNotBound();
    error ReferralDepthExceeded();
    error ReferralRequired();
    error OrderCooldownActive();
    error InvalidDeadline();
    error UnsupportedUsdtTransfer();
    error OraclePriceInvalid();
    error PairNotFound();
    error InvalidPair();
    error EmptyPair();
    error SpotTwapDeviationTooHigh(address asset, uint256 spotPrice, uint256 twapPrice);
    error SwapOutputTooLow();
    error NoPower();
    error WithdrawCooldownActive();
    error NoReward();
    error WithdrawExceedsPoolLimit();
    error GlobalWithdrawLimitExceeded();
    error ProtectedToken();
    error CommunityRewardOverflow();
    error PowerNonTransferable();

    error InvalidTokenDecimals();
    error InvalidHistoryWriter();
    error HistoryNotReady();
    error ExpiryMaintenanceRequired();
    error UnauthorizedAutoWithdrawDelegate();
    error UnauthorizedAutoWithdrawService();
    error InvalidAutoWithdrawService();
    error LegacyAutoWithdrawControlDisabled();
    error NoAutoWithdrawCredits();

    function __SodMiningCore_init(
        address usdt_, address gpc_, address wbnb_, address router_, address oracle_,
        address operationWallet_, address technicalWallet_, address referralRoot_, address businessOwner_
    ) internal onlyInitializing {
        if (usdt_ == address(0) || gpc_ == address(0) || wbnb_ == address(0) ||
            router_ == address(0) || oracle_ == address(0) || operationWallet_ == address(0) ||
            technicalWallet_ == address(0) || referralRoot_ == address(0) || businessOwner_ == address(0)
        ) revert ZeroAddress();
        if (IERC20Metadata(usdt_).decimals() != 18 || IERC20Metadata(gpc_).decimals() != 18 ||
            IERC20Metadata(wbnb_).decimals() != 18) revert InvalidTokenDecimals();
        __Ownable2Step_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        usdt = IERC20(usdt_);
        gpc = IERC20(gpc_);
        wbnb = IERC20(wbnb_);
        router = IPancakeRouterV2(router_);
        oracle = IGpcPriceOracle(oracle_);
        operationWallet = operationWallet_;
        technicalWallet = technicalWallet_;
        referralRoot = referralRoot_;
        address factory = IPancakeRouterV2(router_).factory();
        address gpcPair = IPancakeFactory(factory).getPair(gpc_, wbnb_);
        address usdtPair = IPancakeFactory(factory).getPair(wbnb_, usdt_);
        if (gpcPair == address(0) || usdtPair == address(0)) revert PairNotFound();
        gpcWbnbPair = IPancakePair(gpcPair);
        wbnbUsdtPair = IPancakePair(usdtPair);
        _validatePair(gpcWbnbPair, gpc_, wbnb_);
        _validatePair(wbnbUsdtPair, wbnb_, usdt_);
        parentOf[referralRoot_] = address(this);
        usdt.safeApprove(router_, type(uint256).max);
        _transferOwnership(businessOwner_);
    }

    /// @notice Attaches the independent, fixed-writer history proxy once.
    function initializeHistoryTracking(address registry) external reinitializer(2) onlyOwner {
        if (registry == address(0) || registry.code.length == 0) revert ZeroAddress();
        if (ISodHistoryRegistry(registry).writer() != address(this)) revert InvalidHistoryWriter();
        historyRegistry = ISodHistoryRegistry(registry);
        emit HistoryTrackingInitialized(registry);
    }

    function totalSupply() external view override returns (uint256) {
        return totalPower;
    }

    /**
     * @notice ERC20-compatible balance view backed by the user's current mining power.
     */
    function balanceOf(address account) external view override returns (uint256) {
        return users[account].power;
    }

    function allowance(address account, address spender) external view override returns (uint256) {
        return _powerAllowances[account][spender];
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        if (spender == address(0)) revert ZeroAddress();
        _powerAllowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address, uint256) external pure override returns (bool) {
        revert PowerNonTransferable();
    }

    function transferFrom(address, address, uint256) external pure override returns (bool) {
        revert PowerNonTransferable();
    }

    function bindReferral(address parent) external whenNotPaused {
        if (parent == address(0) || parent == msg.sender) revert ZeroAddress();
        if (parentOf[msg.sender] != address(0)) revert AlreadyBound();
        if (parentOf[parent] == address(0)) revert ParentNotBound();

        uint256 depth = uint256(referralDepth[parent]) + 1;
        if (depth > MAX_REFERRAL_DEPTH) revert ReferralDepthExceeded();

        parentOf[msg.sender] = parent;
        referralDepth[msg.sender] = uint8(depth);
        _directReferrals[parent].push(msg.sender);
        _accountTeamNode(msg.sender);

        emit ReferralBound(msg.sender, parent, depth);
    }

    /// @notice Places one product order; approval and payment are separate transactions.
    function placeOrder(uint256 deadline, uint256 userMinGpcOut) external nonReentrant whenNotPaused {
        if (address(historyRegistry) == address(0)) revert HistoryNotReady();
        address account = msg.sender;
        address parent = parentOf[account];
        bool isRootOrder = parent == address(this);
        if (!isRootOrder && parent == address(0)) revert ReferralRequired();
        if (deadline < block.timestamp || deadline > block.timestamp + MAX_DEADLINE_WINDOW) {
            revert InvalidDeadline();
        }
        UserInfo storage user = users[account];
        if (user.lastOrderAt != 0 && block.timestamp < uint256(user.lastOrderAt) + ORDER_COOLDOWN) {
            revert OrderCooldownActive();
        }
        _expireIfNeeded(account);
        _expireAncestors(account);
        user.lastOrderAt = uint64(block.timestamp);
        uint256 beforeUsdt = usdt.balanceOf(address(this));
        usdt.safeTransferFrom(account, address(this), ORDER_USDT);
        if (usdt.balanceOf(address(this)) - beforeUsdt != ORDER_USDT) revert UnsupportedUsdtTransfer();
        address rewardRecipient = operationWallet;
        if (!isRootOrder && users[parent].power >= DIRECT_REWARD) {
            _decreasePower(parent, DIRECT_REWARD);
            _appendPowerHistory(parent, DIRECT_REWARD, POWER_HISTORY_REFERRAL);
            _refreshRewardSchedule(parent);
            rewardRecipient = parent;
        }
        usdt.safeTransfer(rewardRecipient, DIRECT_REWARD);
        usdt.safeTransfer(operationWallet, OPERATION_SHARE);
        uint256 gpcBought = _executeProtectedSwap(deadline, userMinGpcOut);
        miningPoolGpc += gpcBought;
        _increasePower(account, POWER_PER_ORDER);
        user.totalPowerPurchased += POWER_PER_ORDER;
        _appendPowerHistory(account, POWER_PER_ORDER, POWER_HISTORY_ORDER);
        user.nextWithdrawAt = uint64(block.timestamp + WITHDRAW_COOLDOWN);
        if (user.inactivityStartedAt == 0) user.inactivityStartedAt = uint64(block.timestamp);
        _upsertExpiryUser(account);
        emit OrderPlaced(account, parent, rewardRecipient, gpcBought, gpcBought);
    }

    /// @notice Manual settlement remains available and never consumes an automatic credit.
    /// @dev A manual settlement only advances the normal reward schedule; queued credits remain active.
    function withdraw() external nonReentrant whenNotPaused { _withdraw(msg.sender); }

    /// @notice Permanently bind the one protocol service authorized to settle automatic withdrawals.
    /// @dev Version 2 is already reserved by initializeHistoryTracking.
    function initializeAutoWithdrawService(address service) external reinitializer(3) onlyOwner {
        if (service == address(0) || service.code.length == 0) revert InvalidAutoWithdrawService();
        try ISodAutoWithdrawService(service).mining() returns (address boundMining) {
            if (boundMining != address(this)) revert InvalidAutoWithdrawService();
        } catch {
            revert InvalidAutoWithdrawService();
        }
        autoWithdrawService = service;
        emit AutoWithdrawServiceInitialized(service);
    }

    /// @notice Retained only so existing integrations receive an explicit migration error.
    function setAutoWithdrawDelegate(address) external pure {
        revert LegacyAutoWithdrawControlDisabled();
    }

    /// @notice Protocol settlement pays the beneficiary and technical wallet exactly as withdraw().
    function withdrawFor(address beneficiary) external nonReentrant whenNotPaused returns (uint256 netGpc) {
        if (msg.sender != autoWithdrawService) revert UnauthorizedAutoWithdrawService();
        if (ISodAutoWithdrawService(msg.sender).balanceOf(beneficiary) == 0) revert NoAutoWithdrawCredits();
        return _withdraw(beneficiary);
    }

    function _withdraw(address account) internal returns (uint256 netGpc) {
        RewardQuote memory quote = _prepareRewardSettlement(account);
        if (quote.grossGpc == 0) return 0;

        uint256 feeGpc = Math.mulDiv(quote.grossGpc, WITHDRAW_FEE_BPS, BPS);
        netGpc = quote.grossGpc - feeGpc;
        _consumeRewardPower(account, quote);
        _refreshRewardSchedule(account);
        miningPoolGpc -= quote.grossGpc;

        gpc.safeTransfer(account, netGpc);
        gpc.safeTransfer(technicalWallet, feeGpc);

        emit Withdrawn(
            account,
            quote.staticRewardUsdt,
            quote.communityRewardUsdt,
            quote.totalRewardUsdt,
            quote.grossGpc,
            feeGpc,
            netGpc,
            quote.gpcPrice
        );
    }

    function _prepareRewardSettlement(address account) internal returns (RewardQuote memory quote) {
        _expireAncestors(account);
        if (_expireIfNeeded(account)) return quote;

        UserInfo storage user = users[account];
        if (user.power == 0) revert NoPower();
        if (block.timestamp < user.nextWithdrawAt) revert WithdrawCooldownActive();

        quote = _quoteRewards(account);
        if (quote.totalRewardUsdt == 0 || quote.grossGpc == 0) revert NoReward();
        _validateSpotAgainstTwap(quote.gpcPrice, oracle.bnbPrice());
        if (quote.grossGpc * BPS > miningPoolGpc * MAX_WITHDRAW_POOL_BPS) {
            revert WithdrawExceedsPoolLimit();
        }
        _consumeGlobalWithdrawCapacity(quote.grossGpc);
    }

    function _consumeRewardPower(address account, RewardQuote memory quote) internal {
        UserInfo storage user = users[account];
        _recordRewardEarnings(account, quote);
        user.nextWithdrawAt = uint64(block.timestamp + WITHDRAW_COOLDOWN);
        user.inactivityStartedAt = uint64(block.timestamp);
        _decreasePower(account, quote.totalRewardUsdt);
        _appendPowerHistory(account, quote.totalRewardUsdt, POWER_HISTORY_WITHDRAW);
    }

    function _refreshRewardSchedule(address account) internal {
        UserInfo storage user = users[account];
        if (user.power == 0) {
            user.nextWithdrawAt = 0;
            user.inactivityStartedAt = 0;
            _removeExpiryUser(account);
        } else {
            _upsertExpiryUser(account);
        }
    }

    function communityClaimedToday(address account) external view returns (uint256) {
        DailyCommunityEarnings memory earnings = dailyCommunityEarnings[account];
        return earnings.day == _currentDay() ? uint256(earnings.rewardUsdt) : 0;
    }

    function rewardsClaimedToday(address account)
        external
        view
        returns (uint256 grossGpc, uint256 staticRewardUsdt, uint256 communityRewardUsdt)
    {
        DailyRewardEarnings memory earnings = dailyRewardEarnings[account];
        if (earnings.day != _currentDay()) return (0, 0, 0);
        return (earnings.grossGpc, earnings.staticRewardUsdt, earnings.communityRewardUsdt);
    }

    /**
     * @notice Burns due inactive power without requiring the caller to know any user address.
     * @dev The min-heap makes this O(due users), capped to keep keeper gas bounded.
     */
    function expireDueUsers() external whenNotPaused returns (uint256 expired) {
        uint256 checked;
        while (checked < MAX_AUTO_EXPIRE_BATCH && _expiryHeap.length != 0) {
            address account = _expiryHeap[0];
            if (!_isExpired(account)) break;
            _expireIfNeeded(account);
            unchecked {
                ++checked;
                ++expired;
            }
        }
        emit ExpiryBatchProcessed(checked, expired, nextExpiryAt());
    }

    function nextExpiryAt() public view returns (uint256) {
        if (_expiryHeap.length == 0) return 0;
        return uint256(users[_expiryHeap[0]].inactivityStartedAt) + INACTIVITY_PERIOD;
    }

    function quoteRewards(address account) external view returns (RewardQuote memory) {
        if (_isExpired(account)) return RewardQuote(0, 0, 0, 0, 0, 0, 0, 0, false);
        return _quoteRewards(account);
    }

    function communityPower(address account)
        public
        view
        returns (uint256 total, uint256 largestBranchPower, uint256 smallArea, uint256 effectiveSmallArea)
    {
        total = teamPower[account];
        address[] storage heap = _branchHeaps[account];
        if (heap.length != 0) largestBranchPower = branchPower[account][heap[0]];
        smallArea = total - largestBranchPower;

        uint256 tenTimesPersonal = users[account].power * 10;
        effectiveSmallArea = Math.min(smallArea, tenTimesPersonal);
    }

    function directReferralCount(address account) external view returns (uint256) {
        return _directReferrals[account].length;
    }

    function directReferralAt(address account, uint256 index) external view returns (address) {
        return _directReferrals[account][index];
    }

    function largestBranch(address account) external view returns (address branch, uint256 power) {
        address[] storage heap = _branchHeaps[account];
        if (heap.length != 0) {
            branch = heap[0];
            power = branchPower[account][branch];
        }
    }

    function _spotPrices() internal view returns (uint256 gpcUsdtPrice, uint256 wbnbUsdtPrice) {
        uint256 gpcWbnbPrice = _pairPrice(gpcWbnbPair, address(gpc), address(wbnb));
        wbnbUsdtPrice = _pairPrice(wbnbUsdtPair, address(wbnb), address(usdt));
        gpcUsdtPrice = Math.mulDiv(gpcWbnbPrice, wbnbUsdtPrice, 1 ether);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function rescueUnsupportedToken(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (token == address(usdt) || token == address(gpc) || token == address(wbnb)) {
            revert ProtectedToken();
        }
        IERC20(token).safeTransfer(to, amount);
    }

    function _consumeGlobalWithdrawCapacity(uint256 grossGpc) internal {
        if (
            withdrawWindowStartedAt == 0 ||
            block.timestamp >= withdrawWindowStartedAt + WITHDRAW_COOLDOWN
        ) {
            withdrawWindowStartedAt = block.timestamp;
            withdrawWindowPoolBase = miningPoolGpc;
            withdrawnGpcInWindow = 0;
        }

        uint256 windowLimit = Math.mulDiv(
            withdrawWindowPoolBase,
            MAX_GLOBAL_DAILY_WITHDRAW_POOL_BPS,
            BPS
        );
        if (withdrawnGpcInWindow + grossGpc > windowLimit) {
            revert GlobalWithdrawLimitExceeded();
        }
        withdrawnGpcInWindow += grossGpc;
    }

    function _executeProtectedSwap(uint256 deadline, uint256 userMinGpcOut) internal returns (uint256 gpcBought) {
        uint256 gpcPrice = oracle.price();
        uint256 bnbPrice = oracle.bnbPrice();
        if (gpcPrice == 0 || bnbPrice == 0) revert OraclePriceInvalid();
        _validateSpotAgainstTwap(gpcPrice, bnbPrice);
        uint256 minGpc = Math.mulDiv(USDT_TO_GPC, 1 ether, gpcPrice);
        minGpc = Math.max(userMinGpcOut, Math.mulDiv(minGpc, BPS - SWAP_SLIPPAGE_BPS, BPS));
        address[] memory path = new address[](3);
        path[0] = address(usdt);
        path[1] = address(wbnb);
        path[2] = address(gpc);
        uint256 beforeGpc = gpc.balanceOf(address(this));
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            USDT_TO_GPC, minGpc, path, address(this), deadline
        );
        gpcBought = gpc.balanceOf(address(this)) - beforeGpc;
        if (gpcBought < minGpc) revert SwapOutputTooLow();
    }

    function _validateSpotAgainstTwap(uint256 gpcTwap, uint256 bnbTwap) internal view {
        (uint256 gpcSpot, uint256 bnbSpot) = _spotPrices();
        if (!_withinDeviation(gpcSpot, gpcTwap, SPOT_TWAP_MAX_DEVIATION_BPS)) {
            revert SpotTwapDeviationTooHigh(address(gpc), gpcSpot, gpcTwap);
        }
        if (!_withinDeviation(bnbSpot, bnbTwap, SPOT_TWAP_MAX_DEVIATION_BPS)) {
            revert SpotTwapDeviationTooHigh(address(wbnb), bnbSpot, bnbTwap);
        }
    }

    function _withinDeviation(uint256 spot, uint256 twap, uint256 maxDeviationBps)
        internal
        pure
        returns (bool)
    {
        if (spot == 0 || twap == 0) return false;
        uint256 difference = spot > twap ? spot - twap : twap - spot;
        return Math.mulDiv(difference, BPS, twap) <= maxDeviationBps;
    }

    function _pairPrice(IPancakePair pair, address base, address quote) internal view returns (uint256) {
        (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();
        if (reserve0 == 0 || reserve1 == 0) revert EmptyPair();

        address token0 = pair.token0();
        address token1 = pair.token1();
        if (token0 == base && token1 == quote) {
            return Math.mulDiv(uint256(reserve1), 1 ether, uint256(reserve0));
        }
        if (token0 == quote && token1 == base) {
            return Math.mulDiv(uint256(reserve0), 1 ether, uint256(reserve1));
        }
        revert InvalidPair();
    }

    function _validatePair(IPancakePair pair, address tokenA, address tokenB) internal view {
        address token0 = pair.token0();
        address token1 = pair.token1();
        if (!((token0 == tokenA && token1 == tokenB) || (token0 == tokenB && token1 == tokenA))) {
            revert InvalidPair();
        }
    }

    function _quoteRewards(address account) internal view returns (RewardQuote memory quote) {
        uint256 personalPower = users[account].power;
        if (personalPower == 0 || _isExpired(account)) return quote;
        // Stored branch power is a valid reward snapshot only after all due accounts
        // have been expired. Keep maintenance separate so a rejected claim cannot
        // roll back expiry batches or pay rewards from stale descendant power.
        uint256 dueAt = nextExpiryAt();
        if (dueAt != 0 && dueAt <= block.timestamp) revert ExpiryMaintenanceRequired();
        if (miningPoolGpc == 0) return quote;
        quote.gpcPrice = oracle.price();
        if (quote.gpcPrice == 0) revert OraclePriceInvalid();
        quote.poolValueUsdt = Math.mulDiv(miningPoolGpc, quote.gpcPrice, 1 ether);
        (, , quote.smallAreaPower, quote.effectiveSmallAreaPower) = communityPower(account);
        quote.staticRewardUsdt = Math.mulDiv(personalPower, FIXED_DAILY_RATE_BPS, BPS);
        quote.communityRewardUsdt = Math.mulDiv(
            Math.mulDiv(quote.effectiveSmallAreaPower, FIXED_DAILY_RATE_BPS, BPS), COMMUNITY_RATE_BPS, BPS
        );
        uint256 cap = Math.min(quote.staticRewardUsdt * 2, personalPower);
        // Preserve static earnings and only trim the community tail at the cap.
        quote.communityRewardUsdt = Math.min(quote.communityRewardUsdt, cap - quote.staticRewardUsdt);
        quote.totalRewardUsdt = quote.staticRewardUsdt + quote.communityRewardUsdt;
        quote.grossGpc = Math.mulDiv(quote.totalRewardUsdt, 1 ether, quote.gpcPrice);
    }

    /// @dev Clear expired upstream personal power before adding or settling branch power.
    function _expireAncestors(address account) internal {
        address ancestor = parentOf[account];
        for (uint256 level; level < MAX_REFERRAL_DEPTH; ++level) {
            if (ancestor == address(0) || ancestor == address(this)) break;
            _expireIfNeeded(ancestor);
            ancestor = parentOf[ancestor];
        }
    }

    function _appendPowerHistory(address account, uint256 amount, uint8 kind) internal {
        ISodHistoryRegistry registry = historyRegistry;
        if (address(registry) != address(0)) registry.appendPower(account, amount, kind);
    }

    function _recordRewardEarnings(address account, RewardQuote memory quote) internal {
        uint64 currentDay = _currentDay();
        if (quote.communityRewardUsdt != 0) {
            DailyCommunityEarnings storage community = dailyCommunityEarnings[account];
            uint256 updatedCommunity = community.day == currentDay
                ? uint256(community.rewardUsdt) + quote.communityRewardUsdt
                : quote.communityRewardUsdt;
            if (updatedCommunity > type(uint192).max) revert CommunityRewardOverflow();
            community.rewardUsdt = uint192(updatedCommunity);
            community.day = currentDay;
        }

        DailyRewardEarnings storage earnings = dailyRewardEarnings[account];
        if (earnings.day != currentDay) {
            earnings.day = currentDay;
            earnings.grossGpc = quote.grossGpc;
            earnings.staticRewardUsdt = quote.staticRewardUsdt;
            earnings.communityRewardUsdt = quote.communityRewardUsdt;
        } else {
            earnings.grossGpc += quote.grossGpc;
            earnings.staticRewardUsdt += quote.staticRewardUsdt;
            earnings.communityRewardUsdt += quote.communityRewardUsdt;
        }
    }

    function _currentDay() internal view returns (uint64) {
        return uint64((block.timestamp + 8 hours) / 1 days);
    }

    function _increasePower(address account, uint256 amount) internal {
        users[account].power += amount;
        totalPower += amount;
        _updateAncestorBranches(account, amount, true);
        emit Transfer(address(0), account, amount);
    }

    function _decreasePower(address account, uint256 amount) internal {
        users[account].power -= amount;
        totalPower -= amount;
        _updateAncestorBranches(account, amount, false);
        emit Transfer(account, address(0), amount);
    }

    function _updateAncestorBranches(address account, uint256 amount, bool increase) internal {
        address branch = account;
        address ancestor = parentOf[account];

        for (uint256 level; level < MAX_REFERRAL_DEPTH; ++level) {
            if (ancestor == address(0) || ancestor == address(this)) break;

            uint256 oldBranchPower = branchPower[ancestor][branch];
            uint256 newBranchPower;
            if (increase) {
                newBranchPower = oldBranchPower + amount;
                teamPower[ancestor] += amount;
            } else {
                newBranchPower = oldBranchPower - amount;
                teamPower[ancestor] -= amount;
            }
            _setBranchPower(ancestor, branch, newBranchPower);

            branch = ancestor;
            ancestor = parentOf[ancestor];
        }
    }

    function _accountTeamNode(address account) internal {
        if (_teamNodeAccounted[account]) return;

        address ancestor = parentOf[account];
        if (ancestor == address(0) || ancestor == address(this)) return;
        _teamNodeAccounted[account] = true;

        for (uint256 level; level < MAX_REFERRAL_DEPTH; ++level) {
            if (ancestor == address(0) || ancestor == address(this)) break;
            teamNodeCount[ancestor] += 1;
            ancestor = parentOf[ancestor];
        }

        emit TeamNodeAccounted(account, parentOf[account]);
    }

    function _isExpired(address account) internal view returns (bool) {
        UserInfo storage user = users[account];
        return user.power != 0 && user.inactivityStartedAt != 0 &&
            block.timestamp >= uint256(user.inactivityStartedAt) + INACTIVITY_PERIOD;
    }

    function _expireIfNeeded(address account) internal returns (bool expired) {
        if (!_isExpired(account)) return false;

        UserInfo storage user = users[account];
        uint256 expiredPower = user.power;
        _decreasePower(account, expiredPower);
        _appendPowerHistory(account, expiredPower, POWER_HISTORY_EXPIRED);
        user.nextWithdrawAt = 0;
        user.inactivityStartedAt = 0;
        _removeExpiryUser(account);

        emit PowerExpired(account, expiredPower, block.timestamp);
        return true;
    }

    function _upsertExpiryUser(address account) internal {
        uint256 indexPlusOne = _expiryHeapIndexPlusOne[account];
        if (indexPlusOne == 0) {
            _expiryHeap.push(account);
            uint256 index = _expiryHeap.length - 1;
            _expiryHeapIndexPlusOne[account] = index + 1;
            _siftExpiryUp(index);
            emit ExpiryUserRegistered(
                account,
                uint256(users[account].inactivityStartedAt) + INACTIVITY_PERIOD
            );
            return;
        }
        _rebalanceExpiry(indexPlusOne - 1);
    }

    function _removeExpiryUser(address account) internal {
        uint256 indexPlusOne = _expiryHeapIndexPlusOne[account];
        if (indexPlusOne == 0) return;

        uint256 index = indexPlusOne - 1;
        uint256 lastIndex = _expiryHeap.length - 1;
        if (index != lastIndex) {
            address moved = _expiryHeap[lastIndex];
            _expiryHeap[index] = moved;
            _expiryHeapIndexPlusOne[moved] = index + 1;
        }
        _expiryHeap.pop();
        delete _expiryHeapIndexPlusOne[account];

        if (index < _expiryHeap.length) _rebalanceExpiry(index);
    }

    function _rebalanceExpiry(uint256 index) internal {
        if (index != 0) {
            uint256 parentIndex = (index - 1) / 2;
            if (_expiryHigherPriority(_expiryHeap[index], _expiryHeap[parentIndex])) {
                _siftExpiryUp(index);
                return;
            }
        }
        _siftExpiryDown(index);
    }

    function _siftExpiryUp(uint256 index) internal {
        while (index != 0) {
            uint256 parentIndex = (index - 1) / 2;
            if (!_expiryHigherPriority(_expiryHeap[index], _expiryHeap[parentIndex])) break;
            _swapExpiryEntries(index, parentIndex);
            index = parentIndex;
        }
    }

    function _siftExpiryDown(uint256 index) internal {
        while (true) {
            uint256 left = index * 2 + 1;
            if (left >= _expiryHeap.length) break;
            uint256 right = left + 1;
            uint256 best = left;
            if (
                right < _expiryHeap.length &&
                _expiryHigherPriority(_expiryHeap[right], _expiryHeap[left])
            ) best = right;
            if (!_expiryHigherPriority(_expiryHeap[best], _expiryHeap[index])) break;
            _swapExpiryEntries(index, best);
            index = best;
        }
    }

    function _swapExpiryEntries(uint256 a, uint256 b) internal {
        address accountA = _expiryHeap[a];
        address accountB = _expiryHeap[b];
        _expiryHeap[a] = accountB;
        _expiryHeap[b] = accountA;
        _expiryHeapIndexPlusOne[accountA] = b + 1;
        _expiryHeapIndexPlusOne[accountB] = a + 1;
    }

    function _expiryHigherPriority(address a, address b) internal view returns (bool) {
        uint64 aStartedAt = users[a].inactivityStartedAt;
        uint64 bStartedAt = users[b].inactivityStartedAt;
        if (aStartedAt != bStartedAt) return aStartedAt < bStartedAt;
        return uint160(a) < uint160(b);
    }

    function _setBranchPower(address leader, address branch, uint256 newPower) internal {
        uint256 indexPlusOne = _heapIndexPlusOne[leader][branch];
        branchPower[leader][branch] = newPower;

        if (indexPlusOne == 0) {
            if (newPower == 0) return;
            _branchHeaps[leader].push(branch);
            uint256 newIndex = _branchHeaps[leader].length - 1;
            _heapIndexPlusOne[leader][branch] = newIndex + 1;
            _siftUp(leader, newIndex);
            return;
        }

        uint256 index = indexPlusOne - 1;
        if (newPower == 0) {
            _removeHeapEntry(leader, index);
        } else {
            _rebalance(leader, index);
        }
    }

    function _removeHeapEntry(address leader, uint256 index) internal {
        address[] storage heap = _branchHeaps[leader];
        uint256 lastIndex = heap.length - 1;
        address removed = heap[index];

        if (index != lastIndex) {
            address moved = heap[lastIndex];
            heap[index] = moved;
            _heapIndexPlusOne[leader][moved] = index + 1;
        }
        heap.pop();
        delete _heapIndexPlusOne[leader][removed];

        if (index < heap.length) _rebalance(leader, index);
    }

    function _rebalance(address leader, uint256 index) internal {
        if (index != 0) {
            uint256 parentIndex = (index - 1) / 2;
            if (_higherPriority(leader, _branchHeaps[leader][index], _branchHeaps[leader][parentIndex])) {
                _siftUp(leader, index);
                return;
            }
        }
        _siftDown(leader, index);
    }

    function _siftUp(address leader, uint256 index) internal {
        address[] storage heap = _branchHeaps[leader];
        while (index != 0) {
            uint256 parentIndex = (index - 1) / 2;
            if (!_higherPriority(leader, heap[index], heap[parentIndex])) break;
            _swapHeapEntries(leader, index, parentIndex);
            index = parentIndex;
        }
    }

    function _siftDown(address leader, uint256 index) internal {
        address[] storage heap = _branchHeaps[leader];
        while (true) {
            uint256 left = index * 2 + 1;
            if (left >= heap.length) break;
            uint256 right = left + 1;
            uint256 best = left;
            if (right < heap.length && _higherPriority(leader, heap[right], heap[left])) best = right;
            if (!_higherPriority(leader, heap[best], heap[index])) break;
            _swapHeapEntries(leader, index, best);
            index = best;
        }
    }

    function _swapHeapEntries(address leader, uint256 a, uint256 b) internal {
        address[] storage heap = _branchHeaps[leader];
        address branchA = heap[a];
        address branchB = heap[b];
        heap[a] = branchB;
        heap[b] = branchA;
        _heapIndexPlusOne[leader][branchA] = b + 1;
        _heapIndexPlusOne[leader][branchB] = a + 1;
    }

    function _higherPriority(address leader, address a, address b) internal view returns (bool) {
        uint256 aPower = branchPower[leader][a];
        uint256 bPower = branchPower[leader][b];
        if (aPower != bPower) return aPower > bPower;
        return uint160(a) < uint160(b);
    }
}
