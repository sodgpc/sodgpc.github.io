// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {SodSixHourOracle} from './SodSixHourOracle.sol';
import {IPancakePair} from './interfaces/IPancakePair.sol';

/**
 * @title SodRollingSixHourOracle
 * @notice A live trailing six-hour Pancake V2 TWAP backed by five-minute cumulative observations.
 * @dev A keeper records one point every five minutes. price() and bnbPrice() append the current
 *      Pancake cumulative values in memory, so each read ends at the current block rather than
 *      holding the most recent keeper price until the next observation.
 */
abstract contract SodRollingSixHourOracle is SodSixHourOracle {
    uint256 public constant OBSERVATION_INTERVAL = 5 minutes;
    // Observations separated from the live chain by more than this threshold belong to an expired
    // segment. Expired segments are never interpolated into a current TWAP; reads fall back to spot
    // and the next keeper update starts a clean rolling window.
    uint256 public constant MAX_PRICE_AGE = 30 minutes;
    uint16 public constant MAX_OBSERVATIONS = 74;
    uint8 public constant MODE_SPOT = 0;
    uint8 public constant MODE_PARTIAL_TWAP = 1;
    uint8 public constant MODE_FULL_TWAP = 2;

    struct RollingObservation {
        uint32 timestamp;
        uint256 gpcWbnbCumulative;
        uint256 wbnbUsdtCumulative;
    }

    RollingObservation[] private _rollingObservations;
    uint16 private _rollingNextIndex;
    bool public rollingInitialized;
    uint256[47] private __gap;

    event RollingObservationRecorded(uint256 indexed timestamp, uint256 count);
    event RollingOracleInitialized(uint256 indexed timestamp);
    event RollingObservationsReset(uint256 indexed timestamp, uint256 discardedCount);

    error RollingAlreadyInitialized();
    error RollingNotInitialized();

    function _initializeRolling() internal onlyInitializing {
        if (rollingInitialized) revert RollingAlreadyInitialized();
        rollingInitialized = true;

        (uint256 currentGpcCumulative, uint32 currentTimestamp) = _currentCumulative(
            gpcWbnbPair,
            _gpcUsesPrice0
        );
        (uint256 currentWbnbCumulative, ) = _currentCumulative(wbnbUsdtPair, _wbnbUsesPrice0);
        lastGpcWbnbCumulative = currentGpcCumulative;
        lastWbnbUsdtCumulative = currentWbnbCumulative;
        lastObservationTimestamp = currentTimestamp;
        _rollingObservations.push(
            RollingObservation({
                timestamp: currentTimestamp,
                gpcWbnbCumulative: currentGpcCumulative,
                wbnbUsdtCumulative: currentWbnbCumulative
            })
        );
        _rollingNextIndex = 1;
        lastUpdatedAt = block.timestamp;
        (_gpcPrice, _bnbPrice) = _spotPrices();
        emit RollingOracleInitialized(currentTimestamp);
    }

    function update() external override {
        if (!rollingInitialized) revert RollingNotInitialized();

        (uint256 currentGpcCumulative, uint32 currentTimestamp) = _currentCumulative(
            gpcWbnbPair,
            _gpcUsesPrice0
        );
        (uint256 currentWbnbCumulative, ) = _currentCumulative(wbnbUsdtPair, _wbnbUsesPrice0);

        uint32 elapsed;
        unchecked {
            elapsed = currentTimestamp - lastObservationTimestamp;
        }
        if (elapsed < OBSERVATION_INTERVAL) revert ObservationTooYoung();

        if (elapsed > MAX_PRICE_AGE) {
            _resetRollingObservations(currentTimestamp, currentGpcCumulative, currentWbnbCumulative);
            emit OracleUpdated(block.timestamp, 0, _gpcPrice, _bnbPrice);
            return;
        }

        _storeObservation(currentTimestamp, currentGpcCumulative, currentWbnbCumulative);
        lastGpcWbnbCumulative = currentGpcCumulative;
        lastWbnbUsdtCumulative = currentWbnbCumulative;
        lastObservationTimestamp = currentTimestamp;

        (uint256 gpcInUsdt, uint256 wbnbInUsdt, uint256 windowSeconds, ) = _pricesWithFallback(
            currentGpcCumulative,
            currentWbnbCumulative,
            currentTimestamp
        );

        lastUpdatedAt = block.timestamp;
        _gpcPrice = gpcInUsdt;
        _bnbPrice = wbnbInUsdt;
        emit OracleUpdated(block.timestamp, windowSeconds, gpcInUsdt, wbnbInUsdt);
    }

    function price() external view override returns (uint256) {
        _requireFresh();
        (uint256 liveGpcPrice, ) = _livePrices();
        return liveGpcPrice;
    }

    function bnbPrice() external view override returns (uint256) {
        _requireFresh();
        (, uint256 liveBnbPrice) = _livePrices();
        return liveBnbPrice;
    }

    function isReady() external view override returns (bool) {
        return rollingInitialized;
    }

    function nextUpdateAt() external view override returns (uint256) {
        return uint256(lastObservationTimestamp) + OBSERVATION_INTERVAL;
    }

    function observationCount() external view returns (uint256) {
        return _rollingObservations.length;
    }

    function priceStatus() external view returns (uint8 mode, uint256 windowSeconds) {
        _requireFresh();
        (, , windowSeconds, mode) = _livePricesWithStatus();
    }

    function observationAt(uint256 position)
        external
        view
        returns (uint32 timestamp, uint256 gpcWbnbCumulative, uint256 wbnbUsdtCumulative)
    {
        RollingObservation storage observation = _observationByPosition(position);
        return (
            observation.timestamp,
            observation.gpcWbnbCumulative,
            observation.wbnbUsdtCumulative
        );
    }

    function _requireFresh() internal view override {
        if (!rollingInitialized) revert PriceUnavailable();
    }

    function _livePrices() private view returns (uint256 gpcInUsdt, uint256 wbnbInUsdt) {
        (gpcInUsdt, wbnbInUsdt, , ) = _livePricesWithStatus();
    }

    function _livePricesWithStatus()
        private
        view
        returns (uint256 gpcInUsdt, uint256 wbnbInUsdt, uint256 windowSeconds, uint8 mode)
    {
        (uint256 currentGpcCumulative, uint32 currentTimestamp) = _currentCumulative(
            gpcWbnbPair,
            _gpcUsesPrice0
        );
        (uint256 currentWbnbCumulative, ) = _currentCumulative(wbnbUsdtPair, _wbnbUsesPrice0);
        return _pricesWithFallback(currentGpcCumulative, currentWbnbCumulative, currentTimestamp);
    }

    function _pricesWithFallback(
        uint256 currentGpcCumulative,
        uint256 currentWbnbCumulative,
        uint32 currentTimestamp
    ) private view returns (uint256 gpcInUsdt, uint256 wbnbInUsdt, uint256 windowSeconds, uint8 mode) {
        uint256 count = _rollingObservations.length;
        if (count == 0) {
            (gpcInUsdt, wbnbInUsdt) = _spotPrices();
            return (gpcInUsdt, wbnbInUsdt, 0, MODE_SPOT);
        }

        RollingObservation storage newestObservation = _observationByPosition(count - 1);
        uint32 newestAge;
        unchecked {
            newestAge = currentTimestamp - newestObservation.timestamp;
        }
        if (newestAge > MAX_PRICE_AGE) {
            (gpcInUsdt, wbnbInUsdt) = _spotPrices();
            return (gpcInUsdt, wbnbInUsdt, 0, MODE_SPOT);
        }

        if (uint256(currentTimestamp) >= PERIOD) {
            uint32 targetTimestamp = uint32(uint256(currentTimestamp) - PERIOD);
            (bool available, uint256 targetGpcCumulative, uint256 targetWbnbCumulative) =
                _cumulativesAt(targetTimestamp);
            if (available) {
                (gpcInUsdt, wbnbInUsdt) = _pricesFromCumulatives(
                    currentGpcCumulative,
                    currentWbnbCumulative,
                    targetGpcCumulative,
                    targetWbnbCumulative,
                    PERIOD
                );
                return (gpcInUsdt, wbnbInUsdt, PERIOD, MODE_FULL_TWAP);
            }
        }

        RollingObservation storage fallbackObservation = _observationByPosition(0);
        if (count > 1 && uint256(currentTimestamp) >= PERIOD) {
            uint32 targetTimestamp = uint32(uint256(currentTimestamp) - PERIOD);
            RollingObservation storage newest = _observationByPosition(count - 1);
            // After a prolonged keeper outage every stored point can be older than the desired
            // six-hour boundary. Use the newest point so the fallback covers the shortest and
            // most recent available cumulative-price window instead of an unnecessarily old one.
            if (newest.timestamp < targetTimestamp) fallbackObservation = newest;
        }
        uint256 availableWindow = uint256(currentTimestamp) - uint256(fallbackObservation.timestamp);
        if (availableWindow != 0) {
            (gpcInUsdt, wbnbInUsdt) = _pricesFromCumulatives(
                currentGpcCumulative,
                currentWbnbCumulative,
                fallbackObservation.gpcWbnbCumulative,
                fallbackObservation.wbnbUsdtCumulative,
                availableWindow
            );
            return (gpcInUsdt, wbnbInUsdt, availableWindow, MODE_PARTIAL_TWAP);
        }

        (gpcInUsdt, wbnbInUsdt) = _spotPrices();
        return (gpcInUsdt, wbnbInUsdt, 0, MODE_SPOT);
    }

    function _pricesFromCumulatives(
        uint256 currentGpcCumulative,
        uint256 currentWbnbCumulative,
        uint256 targetGpcCumulative,
        uint256 targetWbnbCumulative,
        uint256 windowSeconds
    ) private pure returns (uint256 gpcInUsdt, uint256 wbnbInUsdt) {
        uint256 averageGpcWbnbX112;
        uint256 averageWbnbUsdtX112;
        unchecked {
            averageGpcWbnbX112 = (currentGpcCumulative - targetGpcCumulative) / windowSeconds;
            averageWbnbUsdtX112 = (currentWbnbCumulative - targetWbnbCumulative) / windowSeconds;
        }

        uint256 gpcInWbnb = Math.mulDiv(averageGpcWbnbX112, 1 ether, Q112_VALUE());
        wbnbInUsdt = Math.mulDiv(averageWbnbUsdtX112, 1 ether, Q112_VALUE());
        gpcInUsdt = Math.mulDiv(gpcInWbnb, wbnbInUsdt, 1 ether);
        if (gpcInUsdt == 0 || wbnbInUsdt == 0) revert PriceUnavailable();
    }

    function _spotPrices() private view returns (uint256 gpcInUsdt, uint256 wbnbInUsdt) {
        uint256 gpcInWbnbX112 = _spotPriceX112(gpcWbnbPair, _gpcUsesPrice0);
        uint256 wbnbInUsdtX112 = _spotPriceX112(wbnbUsdtPair, _wbnbUsesPrice0);
        uint256 gpcInWbnb = Math.mulDiv(gpcInWbnbX112, 1 ether, Q112_VALUE());
        wbnbInUsdt = Math.mulDiv(wbnbInUsdtX112, 1 ether, Q112_VALUE());
        gpcInUsdt = Math.mulDiv(gpcInWbnb, wbnbInUsdt, 1 ether);
        if (gpcInUsdt == 0 || wbnbInUsdt == 0) revert PriceUnavailable();
    }

    function _spotPriceX112(IPancakePair pair, bool usePrice0) private view returns (uint256) {
        (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();
        if (reserve0 == 0 || reserve1 == 0) revert EmptyReserves();
        return usePrice0
            ? (uint256(reserve1) << 112) / reserve0
            : (uint256(reserve0) << 112) / reserve1;
    }

    function _storeObservation(
        uint32 timestamp,
        uint256 gpcCumulative,
        uint256 wbnbCumulative
    ) private {
        RollingObservation memory nextObservation = RollingObservation({
            timestamp: timestamp,
            gpcWbnbCumulative: gpcCumulative,
            wbnbUsdtCumulative: wbnbCumulative
        });

        if (_rollingObservations.length < MAX_OBSERVATIONS) {
            _rollingObservations.push(nextObservation);
            _rollingNextIndex = uint16(_rollingObservations.length % MAX_OBSERVATIONS);
        } else {
            _rollingObservations[_rollingNextIndex] = nextObservation;
            _rollingNextIndex = uint16((uint256(_rollingNextIndex) + 1) % MAX_OBSERVATIONS);
        }
        emit RollingObservationRecorded(timestamp, _rollingObservations.length);
    }

    function _resetRollingObservations(
        uint32 timestamp,
        uint256 gpcCumulative,
        uint256 wbnbCumulative
    ) private {
        uint256 discardedCount = _rollingObservations.length;
        delete _rollingObservations;
        _rollingNextIndex = 0;
        _storeObservation(timestamp, gpcCumulative, wbnbCumulative);

        lastGpcWbnbCumulative = gpcCumulative;
        lastWbnbUsdtCumulative = wbnbCumulative;
        lastObservationTimestamp = timestamp;
        lastUpdatedAt = block.timestamp;
        (_gpcPrice, _bnbPrice) = _spotPrices();
        emit RollingObservationsReset(timestamp, discardedCount);
    }

    function _cumulativesAt(uint32 targetTimestamp)
        private
        view
        returns (bool available, uint256 gpcCumulative, uint256 wbnbCumulative)
    {
        uint256 count = _rollingObservations.length;
        if (count < 2) return (false, 0, 0);

        RollingObservation storage oldest = _observationByPosition(0);
        RollingObservation storage newest = _observationByPosition(count - 1);
        if (oldest.timestamp > targetTimestamp || newest.timestamp < targetTimestamp) {
            return (false, 0, 0);
        }

        uint256 low;
        uint256 high = count - 1;
        while (low < high) {
            uint256 middle = (low + high) / 2;
            if (_observationByPosition(middle).timestamp < targetTimestamp) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }

        RollingObservation storage upper = _observationByPosition(low);
        if (upper.timestamp == targetTimestamp) {
            return (true, upper.gpcWbnbCumulative, upper.wbnbUsdtCumulative);
        }
        if (low == 0) return (false, 0, 0);

        RollingObservation storage lower = _observationByPosition(low - 1);
        uint256 interval = uint256(upper.timestamp) - uint256(lower.timestamp);
        uint256 offset = uint256(targetTimestamp) - uint256(lower.timestamp);
        uint256 gpcDelta;
        uint256 wbnbDelta;
        unchecked {
            gpcDelta = upper.gpcWbnbCumulative - lower.gpcWbnbCumulative;
            wbnbDelta = upper.wbnbUsdtCumulative - lower.wbnbUsdtCumulative;
            gpcCumulative = lower.gpcWbnbCumulative + Math.mulDiv(gpcDelta, offset, interval);
            wbnbCumulative = lower.wbnbUsdtCumulative + Math.mulDiv(wbnbDelta, offset, interval);
        }
        return (true, gpcCumulative, wbnbCumulative);
    }

    function _observationByPosition(uint256 position) private view returns (RollingObservation storage) {
        uint256 count = _rollingObservations.length;
        if (count < MAX_OBSERVATIONS) return _rollingObservations[position];
        return _rollingObservations[(uint256(_rollingNextIndex) + position) % MAX_OBSERVATIONS];
    }

    function Q112_VALUE() private pure returns (uint256) {
        return 2 ** 112;
    }
}
