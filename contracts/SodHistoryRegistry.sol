// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {Initializable} from '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import {Ownable2StepUpgradeable} from '@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol';

/// @notice Latest 30 purchase, reward, expiry and referral power changes, newest first.
contract SodHistoryRegistry is Initializable, Ownable2StepUpgradeable {
    uint8 public constant HISTORY_LIMIT = 30;
    uint8 public constant POWER_HISTORY_ORDER = 1;
    uint8 public constant POWER_HISTORY_WITHDRAW = 2;
    uint8 public constant POWER_HISTORY_EXPIRED = 3;
    uint8 public constant POWER_HISTORY_REFERRAL = 5;
    struct HistoryRecord { uint256 amount; uint64 timestamp; uint8 kind; }
    struct HistoryMeta { uint8 next; uint8 count; }
    address public writer;
    uint64 public trackingStartedAt;
    mapping(address => HistoryMeta) private _meta;
    mapping(address => mapping(uint8 => uint256)) private _records;
    uint256[47] private __gap;
    event WriterSet(address indexed writer);
    error ZeroAddress();
    error UnauthorizedWriter();
    error InvalidHistoryKind();
    error HistoryAmountOverflow();
    error InvalidHistoryTimestamp();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(address writer_, address businessOwner_) external initializer {
        if (writer_ == address(0) || businessOwner_ == address(0)) revert ZeroAddress();
        __Ownable2Step_init();
        writer = writer_;
        trackingStartedAt = uint64(block.timestamp);
        _transferOwnership(businessOwner_);
        emit WriterSet(writer_);
    }

    function appendPower(address account, uint256 amount, uint8 kind) external {
        if (msg.sender != writer) revert UnauthorizedWriter();
        if (account == address(0)) revert ZeroAddress();
        if (kind != 1 && kind != 2 && kind != 3 && kind != 5) revert InvalidHistoryKind();
        if (amount > type(uint192).max) revert HistoryAmountOverflow();
        if (block.timestamp > type(uint40).max) revert InvalidHistoryTimestamp();
        HistoryMeta storage meta = _meta[account];
        _records[account][meta.next] = amount | (block.timestamp << 192) | (uint256(kind) << 232);
        meta.next = uint8((uint256(meta.next) + 1) % HISTORY_LIMIT);
        if (meta.count < HISTORY_LIMIT) meta.count++;
    }

    function powerHistory(address account, uint256 offset, uint256 limit)
        external view returns (HistoryRecord[] memory records, uint256 total)
    {
        HistoryMeta memory meta = _meta[account];
        total = meta.count;
        if (offset >= total || limit == 0) return (new HistoryRecord[](0), total);
        uint256 length = Math.min(limit, total - offset);
        records = new HistoryRecord[](length);
        for (uint256 i; i < length; ++i) {
            uint8 index = uint8((uint256(meta.next) + HISTORY_LIMIT - 1 - offset - i) % HISTORY_LIMIT);
            uint256 packed = _records[account][index];
            records[i] = HistoryRecord(uint192(packed), uint64(uint40(packed >> 192)), uint8(packed >> 232));
        }
    }
}
