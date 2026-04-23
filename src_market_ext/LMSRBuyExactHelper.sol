pragma solidity ^0.5.1;

import {Fixed192x64Math} from "@gnosis.pm/util-contracts/contracts/Fixed192x64Math.sol";
import {CappedLMSRMarketMaker} from "./CappedLMSRMarketMaker.sol";

interface IConditionalTokensBalanceOf {
    function balanceOf(address owner, uint256 id) external view returns (uint256);
}

/// @title LMSRBuyExactHelper
/// @notice Stateless helper that, given a target collateral amount, computes the maximal
///         outcome-token amount `q` such that the on-chain LMSR cost satisfies
///         `cost(q) + fee(q) <= collateralIn`, then executes the trade via
///         `tradeWithSurcharge(..., coverCollateral=false)`.
/// @dev    Binary markets only (`atomicOutcomeSlotCount == 2`). Designed to be DELEGATECALLed
///         from a smart account so the pool sees the calling account as `msg.sender`
///         (and uses the account's collateral allowance).
contract LMSRBuyExactHelper {
    /// @dev Fixed-point scale used by Fixed192x64Math (2^64).
    uint256 internal constant ONE_FP = 0x10000000000000000;
    /// @dev Matches MarketMaker.FEE_RANGE.
    uint64 internal constant FEE_RANGE = 10 ** 18;
    /// @dev Upper bound on post-correction decrement iterations.
    uint256 internal constant MAX_CORRECTION_ITERATIONS = 5;

    /// @notice Compute the exact outcome-token amount for a given `collateralIn`.
    /// @return outcomeTokens  Maximal q such that cost(q) + fee(q) <= collateralIn.
    ///                        Returns 0 if no positive solution exists for the inputs.
    function calcBuyExactCollateral(
        address pool,
        uint256 yesBalance,
        uint256 noBalance,
        uint8 outcomeIndex,
        uint256 collateralIn,
        uint64 surchargeRate
    ) public view returns (uint256 outcomeTokens) {
        require(outcomeIndex < 2, "binary only");
        require(collateralIn > 0, "collateralIn zero");
        require(CappedLMSRMarketMaker(pool).atomicOutcomeSlotCount() == 2, "not binary market");

        uint64 totalFee = _totalFee(pool, surchargeRate);
        uint256 netCostTarget = collateralIn * uint256(FEE_RANGE) / (uint256(FEE_RANGE) + uint256(totalFee));
        if (netCostTarget == 0) return 0;

        uint256 qInitial = _closedFormQ(
            CappedLMSRMarketMaker(pool).funding(),
            (outcomeIndex == 0) ? yesBalance : noBalance,
            (outcomeIndex == 0) ? noBalance : yesBalance,
            netCostTarget
        );
        if (qInitial == 0) return 0;

        return _postCorrect(pool, outcomeIndex, qInitial, collateralIn, totalFee);
    }

    /// @notice Execute an exact-collateral buy. Designed for DELEGATECALL from a smart account;
    ///         the caller (the account whose context this runs in) must have approved
    ///         `collateralIn` of the pool's collateralToken to the pool.
    ///
    ///         coverCollateral=true  → user spends EXACTLY `collateralIn`; the residual
    ///           `collateralIn - (cost+fee)` is pulled into the pool as a dust fee (bounded by
    ///           Fixed192x64Math rounding, ~funding·2^-60 wei). Retail UX: "I said $10, I spent $10".
    ///         coverCollateral=false → user spends only `cost+fee` (≤ `collateralIn`); residual
    ///           stays with the caller. Power-user / API flow.
    function buyExactCollateral(
        address pool,
        uint256 yesPositionId,
        uint256 noPositionId,
        uint8 outcomeIndex,
        uint256 collateralIn,
        uint256 minOutcomeTokens,
        uint64 surchargeRate,
        bool coverCollateral
    ) external returns (uint256 outcomeTokens) {
        IConditionalTokensBalanceOf ctf = IConditionalTokensBalanceOf(address(CappedLMSRMarketMaker(pool).pmSystem()));

        outcomeTokens = calcBuyExactCollateral(
            pool,
            ctf.balanceOf(pool, yesPositionId),
            ctf.balanceOf(pool, noPositionId),
            outcomeIndex,
            collateralIn,
            surchargeRate
        );
        require(outcomeTokens > 0, "no feasible q");
        require(outcomeTokens >= minOutcomeTokens, "slippage");

        int256[] memory amounts = new int256[](2);
        amounts[outcomeIndex] = int256(outcomeTokens);
        CappedLMSRMarketMaker(pool).tradeWithSurcharge(amounts, int256(collateralIn), surchargeRate, coverCollateral);
    }

    // --- internals --------------------------------------------------------

    function _totalFee(address pool, uint64 surchargeRate) internal view returns (uint64) {
        uint64 baseFee = CappedLMSRMarketMaker(pool).fee();
        require(uint256(baseFee) + uint256(surchargeRate) <= uint256(FEE_RANGE), "fee overflow");
        return baseFee + surchargeRate;
    }

    /// @dev Closed-form inverse of the binary LMSR cost function.
    ///      Returns the largest q such that the *real-valued* cost(q) <= netCostTarget
    ///      (rounded conservatively so the Solidity-integer q never exceeds the true solution).
    ///
    ///  Binary LMSR, log2N = ONE_FP:
    ///    netCost(q) = funding * log2( 2^((q - B_self)/funding) + 2^(-B_other/funding) )
    ///    q = B_self + funding * log2( 2^(netCostTarget/funding) - 2^(-B_other/funding) )
    ///
    ///  Rounding modes ensure computed q <= true q:
    ///   - sTarget uses LowerBound  (sTarget <= true 2^(C/b))
    ///   - expOther uses UpperBound (expOther >= true 2^(-B_other/b))
    ///   ⇒ expSelf = sTarget - expOther <= true expSelf
    ///   - binaryLog uses LowerBound (log2 <= true log2)
    ///   - final `funding * log2Self / ONE_FP` uses floor-toward-minus-infinity
    function _closedFormQ(uint256 funding, uint256 bSelf, uint256 bOther, uint256 netCostTarget)
        internal
        pure
        returns (uint256)
    {
        require(funding > 0, "funding zero");

        uint256 expSelf;
        {
            int256 sTargetArg = int256(netCostTarget) * int256(ONE_FP) / int256(funding);
            uint256 sTarget = Fixed192x64Math.pow2(sTargetArg, Fixed192x64Math.EstimationMode.LowerBound);

            int256 otherArg = -int256(bOther) * int256(ONE_FP) / int256(funding);
            uint256 expOther = Fixed192x64Math.pow2(otherArg, Fixed192x64Math.EstimationMode.UpperBound);

            if (sTarget <= expOther) return 0;
            expSelf = sTarget - expOther;
        }

        int256 log2Self = Fixed192x64Math.binaryLog(expSelf, Fixed192x64Math.EstimationMode.LowerBound);

        int256 prod = int256(funding) * log2Self;
        int256 qInt;
        if (prod >= 0 || prod % int256(ONE_FP) == 0) {
            qInt = prod / int256(ONE_FP);
        } else {
            qInt = prod / int256(ONE_FP) - 1; // floor toward -inf
        }
        qInt = qInt + int256(bSelf);
        if (qInt <= 0) return 0;
        return uint256(qInt);
    }

    /// @dev Defensively verify the algorithm's q against actual `calcNetCost` (which uses
    ///      UpperBound rounding — the same estimate `trade()` gates on). If over, decrement
    ///      by ≈ (overshoot / marginalPrice); converges in 1-2 iterations.
    function _postCorrect(address pool, uint8 outcomeIndex, uint256 qInitial, uint256 collateralIn, uint64 totalFee)
        internal
        view
        returns (uint256)
    {
        int256[] memory amounts = new int256[](2);
        uint256 q = qInitial;
        amounts[outcomeIndex] = int256(q);
        for (uint256 i = 0; i <= MAX_CORRECTION_ITERATIONS; i++) {
            (bool done, uint256 newQ) = _correctOnce(pool, amounts, outcomeIndex, q, collateralIn, totalFee);
            if (done) return newQ;
            q = newQ;
            amounts[outcomeIndex] = int256(q);
        }
        revert("correction did not converge");
    }

    /// @dev One step of post-correction. Returns (done, q):
    ///      done=true  → q is the final answer (invariant holds; may be 0 for infeasible)
    ///      done=false → loop again with the new q
    function _correctOnce(
        address pool,
        int256[] memory amounts,
        uint8 outcomeIndex,
        uint256 q,
        uint256 collateralIn,
        uint64 totalFee
    ) internal view returns (bool done, uint256 newQ) {
        int256 cost = CappedLMSRMarketMaker(pool).calcNetCost(amounts);
        if (cost <= 0) return (true, 0);
        uint256 totalCost = uint256(cost) + uint256(cost) * uint256(totalFee) / uint256(FEE_RANGE);
        if (totalCost <= collateralIn) return (true, q);

        uint256 dq = _estimateDecrement(pool, outcomeIndex, totalCost - collateralIn, totalFee);
        if (dq >= q) return (true, 0);
        return (false, q - dq);
    }

    function _estimateDecrement(address pool, uint8 outcomeIndex, uint256 overshoot, uint64 totalFee)
        internal
        view
        returns (uint256)
    {
        uint256 priceFP = CappedLMSRMarketMaker(pool).calcMarginalPrice(outcomeIndex);
        if (priceFP == 0) priceFP = 1;
        // overshoot collateral → tokens: dq = overshoot * ONE_FP / priceFP, then scale down by (1+fee).
        uint256 dq = overshoot * ONE_FP / priceFP;
        dq = dq * uint256(FEE_RANGE) / (uint256(FEE_RANGE) + uint256(totalFee));
        return dq + 2; // safety margin for rounding in the estimate
    }
}
