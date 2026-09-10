// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {Initializable} from '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import {IGpcPriceOracle} from './interfaces/IGpcPriceOracle.sol';
import {IPancakeFactory} from './interfaces/IPancakeFactory.sol';
import {IPancakePair} from './interfaces/IPancakePair.sol';
import {IPancakeRouterV2} from './interfaces/IPancakeRouterV2.sol';

/**
 * @title SodSixHourOracle
 * @notice Manipulation-resistant GPC/USDT and WBNB/USDT TWAP built from Pancake V2 cumulatives.
 * @dev Call update() at least every 6-12 hours. The first price is available six hours after deployment.
 */
abstract contract SodSixHourOracle is Initializable, IGpcPriceOracle {
    uint256 private constant Q112 = 2 ** 112;
    uint256 public constant PERIOD = 6 hours;
    uint256 public constant MAX_STALENESS = 12 hours;
    uint256 public constant MAX_OBSERVATION_PERIOD = 12 hours;

    address public gpc;
    address public wbnb;
    address public usdt;
    IPancakePair public gpcWbnbPair;
    IPancakePair public wbnbUsdtPair;
    bool internal _gpcUsesPrice0;
    bool internal _wbnbUsesPrice0;

    uint256 public lastGpcWbnbCumulative;
    uint256 public lastWbnbUsdtCumulative;
    uint32 public lastObservationTimestamp;
    uint256 public lastUpdatedAt;
    uint256 internal _gpcPrice;
    uint256 internal _bnbPrice;

    // Reserved storage slots for future oracle upgrades.
    uint256[40] private __gap;

    event OracleUpdated(
        uint256 indexed timestamp,
        uint256 observationPeriod,
        uint256 gpcPrice,
        uint256 bnbPrice
    );
    event ObservationReset(uint256 indexed timestamp, uint256 elapsed);

    error ZeroAddress();
    error PairNotFound();
    error InvalidPair();
    error ObservationTooYoung();
    error PriceUnavailable();
    error PriceStale();
    error EmptyReserves();

    function __SodSixHourOracle_init(address router_, address gpc_, address wbnb_, address usdt_)
        internal
        onlyInitializing
    {
        if (router_ == address(0) || gpc_ == address(0) || wbnb_ == address(0) || usdt_ == address(0)) {
            revert ZeroAddress();
        }
        gpc = gpc_;
        wbnb = wbnb_;
        usdt = usdt_;

        address factory = IPancakeRouterV2(router_).factory();
        address gpcPair = IPancakeFactory(factory).getPair(gpc_, wbnb_);
        address usdtPair = IPancakeFactory(factory).getPair(wbnb_, usdt_);
        if (gpcPair == address(0) || usdtPair == address(0)) revert PairNotFound();

        gpcWbnbPair = IPancakePair(gpcPair);
        wbnbUsdtPair = IPancakePair(usdtPair);

        address gpcToken0 = IPancakePair(gpcPair).token0();
        address gpcToken1 = IPancakePair(gpcPair).token1();
        if (!((gpcToken0 == gpc_ && gpcToken1 == wbnb_) || (gpcToken0 == wbnb_ && gpcToken1 == gpc_))) {
            revert InvalidPair();
        }
        _gpcUsesPrice0 = gpcToken0 == gpc_; // WBNB per GPC

        address usdtToken0 = IPancakePair(usdtPair).token0();
        address usdtToken1 = IPancakePair(usdtPair).token1();
        if (!((usdtToken0 == wbnb_ && usdtToken1 == usdt_) || (usdtToken0 == usdt_ && usdtToken1 == wbnb_))) {
            revert InvalidPair();
        }
        _wbnbUsesPrice0 = usdtToken0 == wbnb_; // USDT per WBNB

        (lastGpcWbnbCumulative, lastObservationTimestamp) = _currentCumulative(
            IPancakePair(gpcPair),
            _gpcUsesPrice0
        );
        (lastWbnbUsdtCumulative, ) = _currentCumulative(IPancakePair(usdtPair), _wbnbUsesPrice0);
    }

    /**
     * @notice Finalizes a TWAP over the elapsed interval. Anyone may keep the oracle updated.
     */
    function update() external virtual {
        (uint256 currentGpcCumulative, uint32 currentTimestamp) = _currentCumulative(
            gpcWbnbPair,
            _gpcUsesPrice0
        );
        (uint256 currentWbnbCumulative, ) = _currentCumulative(wbnbUsdtPair, _wbnbUsesPrice0);

        uint32 elapsed;
        unchecked {
            elapsed = currentTimestamp - lastObservationTimestamp;
        }
        if (elapsed < PERIOD) revert ObservationTooYoung();
        if (elapsed > MAX_OBSERVATION_PERIOD) {
            lastGpcWbnbCumulative = currentGpcCumulative;
            lastWbnbUsdtCumulative = currentWbnbCumulative;
            lastObservationTimestamp = currentTimestamp;
            lastUpdatedAt = 0;
            _gpcPrice = 0;
            _bnbPrice = 0;
            emit ObservationReset(block.timestamp, elapsed);
            return;
        }

        uint256 averageGpcWbnbX112;
        uint256 averageWbnbUsdtX112;
        unchecked {
            // Pancake cumulative values intentionally wrap at 2^256.
            averageGpcWbnbX112 = (currentGpcCumulative - lastGpcWbnbCumulative) / elapsed;
            averageWbnbUsdtX112 = (currentWbnbCumulative - lastWbnbUsdtCumulative) / elapsed;
        }

        uint256 gpcInWbnb = Math.mulDiv(averageGpcWbnbX112, 1 ether, Q112);
        uint256 wbnbInUsdt = Math.mulDiv(averageWbnbUsdtX112, 1 ether, Q112);
        uint256 gpcInUsdt = Math.mulDiv(gpcInWbnb, wbnbInUsdt, 1 ether);
        if (gpcInUsdt == 0 || wbnbInUsdt == 0) revert PriceUnavailable();

        lastGpcWbnbCumulative = currentGpcCumulative;
        lastWbnbUsdtCumulative = currentWbnbCumulative;
        lastObservationTimestamp = currentTimestamp;
        lastUpdatedAt = block.timestamp;
        _gpcPrice = gpcInUsdt;
        _bnbPrice = wbnbInUsdt;

        emit OracleUpdated(block.timestamp, elapsed, gpcInUsdt, wbnbInUsdt);
    }

    function price() external view virtual returns (uint256) {
        _requireFresh();
        return _gpcPrice;
    }

    function bnbPrice() external view virtual returns (uint256) {
        _requireFresh();
        return _bnbPrice;
    }

    function isReady() external view virtual returns (bool) {
        return lastUpdatedAt != 0 && block.timestamp <= lastUpdatedAt + MAX_STALENESS;
    }

    function nextUpdateAt() external view virtual returns (uint256) {
        return uint256(lastObservationTimestamp) + PERIOD;
    }

    function _requireFresh() internal view virtual {
        if (lastUpdatedAt == 0) revert PriceUnavailable();
        if (block.timestamp > lastUpdatedAt + MAX_STALENESS) revert PriceStale();
    }

    function _currentCumulative(IPancakePair pair, bool usePrice0)
        internal
        view
        virtual
        returns (uint256 cumulative, uint32 blockTimestamp)
    {
        cumulative = usePrice0 ? pair.price0CumulativeLast() : pair.price1CumulativeLast();
        (uint112 reserve0, uint112 reserve1, uint32 pairTimestamp) = pair.getReserves();
        if (reserve0 == 0 || reserve1 == 0) revert EmptyReserves();

        blockTimestamp = uint32(block.timestamp % 2 ** 32);
        if (blockTimestamp != pairTimestamp) {
            uint32 elapsed;
            unchecked {
                elapsed = blockTimestamp - pairTimestamp;
            }
            uint256 encodedPrice = usePrice0
                ? (uint256(reserve1) << 112) / reserve0
                : (uint256(reserve0) << 112) / reserve1;
            unchecked {
                cumulative += encodedPrice * elapsed;
            }
        }
    }
}
