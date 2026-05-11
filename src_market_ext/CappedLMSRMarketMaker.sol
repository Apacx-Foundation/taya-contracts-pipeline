pragma solidity ^0.5.1;
import {SafeMath} from "openzeppelin-solidity/contracts/math/SafeMath.sol";
import {Fixed192x64Math} from "@gnosis.pm/util-contracts/contracts/Fixed192x64Math.sol";
import {LMSRMarketMaker} from "market-makers/LMSRMarketMaker.sol";
import {LMSRBuyExactMath} from "./LMSRBuyExactMath.sol";

/// @title Capped LMSR market maker contract - Identical to LMSR (b = funding) with loss tracking and per-trade caps
/// @author Alan Lu - <alan.lu@gnosis.pm>
/// @author Apacx Team
/// @dev Extends MarketMaker. Uses funding as the LMSR b parameter (same as original LMSRMarketMaker).
///      Adds: lossUsed high-water mark tracking, maxCostPerTx per-trade cap, calcMaxLoss() utility,
///      and a native `buyExactCollateral` entry point that inverts the LMSR cost function via
///      the pure `LMSRBuyExactMath` library.
contract CappedLMSRMarketMaker is LMSRMarketMaker {
    uint256 public maxCostPerTx;
    /// @notice High-water mark of cumulative LMSR loss. Never decreases.
    uint256 public lossUsed;
    /// @notice Algebraic sum of all outcomeTokenNetCost values (fee-stripped) from trades
    int256 public cumulativeNetCost;

    event LossUpdated(uint256 lossUsed);
    event MaxCostPerTxChanged(uint256 maxCostPerTx);
    event SurchargedTrade(address indexed trader, uint64 surcharge, uint256 coverFee);

    function changeMaxCostPerTx(uint256 _maxCostPerTx) 
        public 
        onlyOwner 
        atStage(Stage.Paused) 
    {
        maxCostPerTx = _maxCostPerTx;
        emit MaxCostPerTxChanged(maxCostPerTx);
    }

    function _afterTrade(int netCost, uint64 totalFee) internal {
        int outcomeTokenCost = (netCost * int(FEE_RANGE)) / int(FEE_RANGE + totalFee);
        
        // Per-trade cap
        if (maxCostPerTx > 0 && outcomeTokenCost > 0) {
            require(
                uint256(outcomeTokenCost) <= maxCostPerTx, "trade cost exceeds maxCostPerTx"
            );
        }
        // Accumulate net cost from this trade
        cumulativeNetCost = cumulativeNetCost + outcomeTokenCost;

        // lossUsed = max(cumulativeNetCost, lossUsed)
        if (cumulativeNetCost > 0) {
            uint256 uCost = uint256(cumulativeNetCost);
            if (uCost > lossUsed) {
                lossUsed = uCost;
                emit LossUpdated(lossUsed);
            }
        }
    }

    /// @dev Override trade to enforce maxCostPerTx cap and track cumulative loss.
    /// Since calcNetCost([0,...]) ≈ 0 (b = funding keeps balances symmetric), we use
    /// cumulativeNetCost directly as the loss metric — it tracks actual collateral flow.
    function trade(int[] memory outcomeTokenAmounts, int collateralLimit) 
        public 
        returns (int netCost) 
    {
        // Execute the actual trade
        netCost = super.trade(outcomeTokenAmounts, collateralLimit);
        _afterTrade(netCost, fee);
    }

    function tradeWithSurcharge(int[] memory outcomeTokenAmounts, int collateralLimit, uint64 surcharge, bool coverCollateral)
        public
        returns (int netCost)
    {
        uint64 baseFee = fee;
        uint64 totalFee = baseFee + surcharge;
        require(surcharge <= totalFee && totalFee <= FEE_RANGE, "surcharge overflow");

        // Execute the actual trade
        fee = totalFee;
        netCost = super.trade(outcomeTokenAmounts, collateralLimit);
        fee = baseFee;

        uint256 coverFee = 0;
        if (coverCollateral && netCost > 0 && collateralLimit > netCost) {
            coverFee = uint256(collateralLimit - netCost);
            require(collateralToken.transferFrom(msg.sender, address(this), coverFee));
        }

        _afterTrade(netCost, totalFee);
        emit SurchargedTrade(msg.sender, surcharge, coverFee);
    }

    // ---------------------------------------------------------------
    // Buy-exact-collateral (APA-455)
    //
    // Native entry point letting a caller specify exact collateral spend instead of
    // token quantity. Math lives in the pure `LMSRBuyExactMath` library; the pool
    // owns only state reads + the convergence loop that depends on `calcNetCost` /
    // `calcMarginalPrice`. Internal jump to `tradeWithSurcharge` preserves
    // `msg.sender`, so the caller's pool collateral approval is what gets pulled —
    // no DELEGATECALL plumbing.
    //
    // coverCollateral=true  → caller spends EXACTLY `collateralIn`; the residual
    //   `collateralIn - (cost+fee)` is pulled in as a dust fee (bounded by
    //   Fixed192x64Math rounding, ~funding·2^-60 wei).
    // coverCollateral=false → caller spends only `cost+fee` (≤ `collateralIn`);
    //   residual stays with the caller.
    // ---------------------------------------------------------------

    function calcBuyExactCollateral(uint8 outcomeIndex, uint256 collateralIn, uint64 surchargeRate)
        public
        view
        returns (uint256 outcomeTokens)
    {
        require(outcomeIndex < 2, "binary only");
        require(collateralIn > 0, "collateralIn zero");
        require(atomicOutcomeSlotCount == 2, "not binary market");

        uint64 totalFee = LMSRBuyExactMath.totalFee(fee, surchargeRate);
        uint256 netCostTarget = LMSRBuyExactMath.netCostTargetFromCollateralIn(collateralIn, totalFee);
        if (netCostTarget == 0) return 0;

        uint256 yesBalance = pmSystem.balanceOf(address(this), generateAtomicPositionId(0));
        uint256 noBalance = pmSystem.balanceOf(address(this), generateAtomicPositionId(1));

        uint256 qInitial = LMSRBuyExactMath.closedFormQ(
            funding,
            (outcomeIndex == 0) ? yesBalance : noBalance,
            (outcomeIndex == 0) ? noBalance : yesBalance,
            netCostTarget
        );
        if (qInitial == 0) return 0;

        return _postCorrect(outcomeIndex, qInitial, collateralIn, totalFee);
    }

    function buyExactCollateral(
        uint8 outcomeIndex,
        uint256 collateralIn,
        uint256 minOutcomeTokens,
        uint64 surchargeRate,
        bool coverCollateral
    ) external returns (uint256 outcomeTokens) {
        outcomeTokens = calcBuyExactCollateral(outcomeIndex, collateralIn, surchargeRate);
        require(outcomeTokens > 0, "no feasible q");
        require(outcomeTokens >= minOutcomeTokens, "slippage");
        // Guard the uint256→int256 cast: a value ≥ 2^255 would wrap negative and flip
        // this buy into a sell. Unreachable with realistic LMSR funding (log-bounded q),
        // but the check is cheap and prevents undefined behaviour on pathological input.
        require(outcomeTokens < (uint256(1) << 255), "outcomeTokens overflow");
        require(collateralIn < (uint256(1) << 255), "collateralIn overflow");

        int256[] memory amounts = new int256[](2);
        amounts[outcomeIndex] = int256(outcomeTokens);
        // Internal jump to tradeWithSurcharge preserves msg.sender; the caller's
        // pool collateral approval is what gets pulled by `super.trade(...)`.
        tradeWithSurcharge(amounts, int256(collateralIn), surchargeRate, coverCollateral);
    }

    /// @dev Convergence loop. Verify the closed-form q against the pool's actual
    ///      `calcNetCost` (which uses UpperBound rounding — the same estimate `trade()`
    ///      gates on). If over, decrement by ≈ (overshoot / marginalPrice) using the
    ///      pure helper; converges in 1–2 iterations. Bounded by the lib's
    ///      `MAX_CORRECTION_ITERATIONS` so pathological input reverts cleanly.
    function _postCorrect(uint8 outcomeIndex, uint256 qInitial, uint256 collateralIn, uint64 totalFee)
        internal
        view
        returns (uint256)
    {
        int256[] memory amounts = new int256[](2);
        uint256 q = qInitial;
        amounts[outcomeIndex] = int256(q);
        for (uint256 i = 0; i <= LMSRBuyExactMath.maxCorrectionIterations(); i++) {
            int256 cost = calcNetCost(amounts);
            if (cost <= 0) return 0;
            uint256 totalCost = uint256(cost) + uint256(cost) * uint256(totalFee) / uint256(FEE_RANGE);
            if (totalCost <= collateralIn) return q;

            uint256 dq = LMSRBuyExactMath.estimateDecrement(
                calcMarginalPrice(outcomeIndex),
                totalCost - collateralIn,
                totalFee
            );
            if (dq >= q) return 0;
            q = q - dq;
            amounts[outcomeIndex] = int256(q);
        }
        revert("correction did not converge");
    }
}
