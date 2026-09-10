// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Address} from '@openzeppelin/contracts/utils/Address.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {ERC20Upgradeable} from '@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol';
import {Initializable} from '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import {Ownable2StepUpgradeable} from '@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol';
import {ReentrancyGuardUpgradeable} from '@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol';
import {ISodMiningAutoWithdraw} from './interfaces/ISodMiningAutoWithdraw.sol';

/// @notice Prepaid, non-transferable credits for explicitly authorized SOD withdrawals.
/// @dev Mining is fixed at initialization. Only a positive successful settlement consumes a credit.
contract SodAutoWithdraw is Initializable, Ownable2StepUpgradeable, ReentrancyGuardUpgradeable, ERC20Upgradeable {
    using Address for address payable;

    uint256 public constant VERSION = 1;
    uint256 public constant CREDIT_PRICE = 0.0005 ether;
    uint256 public constant EXECUTION_DELAY = 10 minutes;
    uint256 public constant WITHDRAW_COOLDOWN = 24 hours;
    uint256 public constant INACTIVITY_PERIOD = 180 days;
    uint256 public constant MAX_PAGE_SIZE = 200;
    uint256 private constant BPS = 10_000;

    ISodMiningAutoWithdraw public mining;
    address payable public executor;
    address[] private _allUsers;
    mapping(address => bool) public isRegistered;

    event CreditsPurchased(address indexed payer, address indexed beneficiary, uint256 credits, uint256 paidBnb, uint256 executorBnb);
    event CreditsGranted(address indexed beneficiary, uint256 credits);
    event AutoWithdrawalExecuted(address indexed beneficiary, address indexed executor, uint256 netGpc, uint256 remainingCredits);
    event ExecutorUpdated(address indexed previousExecutor, address indexed newExecutor);

    error ZeroAddress();
    error InvalidMining();
    error InvalidExecutor();
    error InvalidCredits();
    error IncorrectPayment();
    error DirectPaymentDisabled();
    error MiningNotReady();
    error TransfersDisabled();
    error OnlyExecutor();
    error AutoWithdrawalNotReady();
    error NoNetReward();
    error PageTooLarge();

    modifier onlyExecutor() {
        if (msg.sender != executor) revert OnlyExecutor();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(address miningAddress, address payable initialExecutor, address governanceOwner) external initializer {
        if (miningAddress == address(0) || initialExecutor == address(0) || governanceOwner == address(0)) revert ZeroAddress();
        if (initialExecutor == address(this)) revert InvalidExecutor();
        if (miningAddress.code.length == 0) revert InvalidMining();
        ISodMiningAutoWithdraw candidate = ISodMiningAutoWithdraw(miningAddress);
        // These checks also work before the Mining proxy receives its delegate upgrade.
        if (keccak256(bytes(candidate.name())) != keccak256(bytes('SOD POWER')) ||
            candidate.ORDER_USDT() != 700 ether || candidate.POWER_PER_ORDER() != 1_000 ether ||
            candidate.usdt().code.length == 0 || candidate.gpc().code.length == 0) revert InvalidMining();
        __Ownable2Step_init();
        __ReentrancyGuard_init();
        __ERC20_init('SOD Auto Withdraw Credits', 'SODAWC');
        mining = candidate;
        executor = initialExecutor;
        _transferOwnership(governanceOwner);
    }

    receive() external payable { revert DirectPaymentDisabled(); }
    fallback() external payable { revert DirectPaymentDisabled(); }
    function decimals() public pure override returns (uint8) { return 0; }

    /// @notice An existing credit balance does not authorize withdrawals.
    function buyCredits(uint256 credits) external payable nonReentrant returns (uint256) {
        return _purchase(msg.sender, msg.sender, credits);
    }

    function buyFor(address beneficiary, uint256 credits) external payable nonReentrant returns (uint256) {
        return _purchase(msg.sender, beneficiary, credits);
    }

    function grantCredits(address beneficiary, uint256 credits) external onlyOwner {
        if (beneficiary == address(0)) revert ZeroAddress();
        if (credits == 0) revert InvalidCredits();
        _mint(beneficiary, credits);
        _register(beneficiary);
        emit CreditsGranted(beneficiary, credits);
    }

    /// @notice Prevent paid purchases until Mining supports delegation and can operate.
    function isMiningReady() public view returns (bool) {
        try mining.autoWithdrawDelegate(address(this)) returns (address) {} catch { return false; }
        try mining.paused() returns (bool isPaused) { if (isPaused) return false; } catch { return false; }
        try mining.historyRegistry() returns (address registry) { return registry != address(0); } catch { return false; }
    }

    /// @notice Advisory eligibility. Execution still validates prices and all Mining guards atomically.
    function checkAuto(address beneficiary) public view returns (bool) {
        if (balanceOf(beneficiary) == 0 || !isMiningReady()) return false;
        try mining.autoWithdrawDelegate(beneficiary) returns (address delegate) {
            if (delegate != address(this)) return false;
        } catch { return false; }

        try mining.users(beneficiary) returns (uint256 power, uint256, uint256, uint64, uint64 nextWithdrawAt, uint64 inactivityStartedAt) {
            if (power == 0 || nextWithdrawAt == 0 || inactivityStartedAt == 0 ||
                block.timestamp >= uint256(inactivityStartedAt) + INACTIVITY_PERIOD ||
                block.timestamp < uint256(nextWithdrawAt) + EXECUTION_DELAY) return false;
        } catch { return false; }

        try mining.quoteRewards(beneficiary) returns (ISodMiningAutoWithdraw.RewardQuote memory quote) {
            if (quote.totalRewardUsdt == 0 || quote.grossGpc == 0) return false;
            return _hasPoolCapacity(quote.grossGpc);
        } catch { return false; }
    }

    function _hasPoolCapacity(uint256 grossGpc) private view returns (bool) {
        uint256 pool;
        uint256 startedAt;
        try mining.miningPoolGpc() returns (uint256 value) { pool = value; } catch { return false; }
        if (grossGpc > Math.mulDiv(pool, 100, BPS)) return false;
        try mining.withdrawWindowStartedAt() returns (uint256 value) { startedAt = value; } catch { return false; }
        uint256 base = pool;
        uint256 used;
        if (startedAt != 0 && block.timestamp < startedAt + WITHDRAW_COOLDOWN) {
            try mining.withdrawWindowPoolBase() returns (uint256 value) { base = value; } catch { return false; }
            try mining.withdrawnGpcInWindow() returns (uint256 value) { used = value; } catch { return false; }
        }
        uint256 capacity = Math.mulDiv(base, 200, BPS);
        return used <= capacity && grossGpc <= capacity - used;
    }

    function execute(address beneficiary) external onlyExecutor nonReentrant returns (uint256 netGpc) {
        if (!checkAuto(beneficiary)) revert AutoWithdrawalNotReady();
        netGpc = mining.withdrawFor(beneficiary);
        if (netGpc == 0) revert NoNetReward();
        _burn(beneficiary, 1);
        emit AutoWithdrawalExecuted(beneficiary, msg.sender, netGpc, balanceOf(beneficiary));
    }

    /// @notice Scan at most limit registered users. nextOffset advances across ineligible users too.
    function getAutoUserPage(uint256 offset, uint256 limit) external view
        returns (address[] memory eligibleUsers, uint256 nextOffset, uint256 totalUsers)
    {
        if (limit > MAX_PAGE_SIZE) revert PageTooLarge();
        totalUsers = _allUsers.length;
        if (offset >= totalUsers) return (new address[](0), totalUsers, totalUsers);
        if (limit == 0) return (new address[](0), offset, totalUsers);
        uint256 end = offset + limit;
        if (end > totalUsers) end = totalUsers;
        address[] memory matches = new address[](end - offset);
        uint256 count;
        for (uint256 i = offset; i < end; ++i) {
            address account = _allUsers[i];
            if (checkAuto(account)) matches[count++] = account;
        }
        eligibleUsers = new address[](count);
        for (uint256 i; i < count; ++i) eligibleUsers[i] = matches[i];
        nextOffset = end;
    }

    function getAllUserCount() external view returns (uint256) { return _allUsers.length; }
    function userAt(uint256 index) external view returns (address) { return _allUsers[index]; }

    function setExecutor(address payable newExecutor) external onlyOwner {
        if (newExecutor == address(0)) revert ZeroAddress();
        if (newExecutor == address(this)) revert InvalidExecutor();
        address previousExecutor = executor;
        executor = newExecutor;
        emit ExecutorUpdated(previousExecutor, newExecutor);
    }

    function _purchase(address payer, address beneficiary, uint256 credits) private returns (uint256) {
        if (beneficiary == address(0)) revert ZeroAddress();
        if (credits == 0) revert InvalidCredits();
        if (msg.value != credits * CREDIT_PRICE) revert IncorrectPayment();
        if (!isMiningReady()) revert MiningNotReady();
        _mint(beneficiary, credits);
        _register(beneficiary);
        executor.sendValue(msg.value);
        emit CreditsPurchased(payer, beneficiary, credits, msg.value, msg.value);
        return credits;
    }

    function _register(address beneficiary) private {
        if (isRegistered[beneficiary]) return;
        isRegistered[beneficiary] = true;
        _allUsers.push(beneficiary);
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
        super._beforeTokenTransfer(from, to, amount);
        if (from != address(0) && to != address(0)) revert TransfersDisabled();
    }

    uint256[44] private __gap;
}
