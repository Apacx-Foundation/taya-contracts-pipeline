pragma solidity ^0.5.1;

import {Fixed192x64Math} from "@gnosis.pm/util-contracts/contracts/Fixed192x64Math.sol";

/// @title LMSRBuyExactMath
/// @notice Pure library: closed-form inverse of the binary LMSR cost function plus the
///         post-correction primitives used to keep the integer-arithmetic answer
///         conservative against the on-chain `calcNetCost`.
/// @dev    All functions are `internal pure`. Callers pass pool state in by value
///         (funding, balances, fee, marginal price) — the library never reads storage
///         and never makes external calls. The convergence loop itself stays on the
///         caller (it has to read `calcNetCost`/`calcMarginalPrice` from the pool),
///         but every piece of math the loop needs is exposed here as a pure helper.
library LMSRBuyExactMath {
    /// @dev Fixed-point scale used by Fixed192x64Math (2^64).
    uint256 internal constant ONE_FP = 0x10000000000000000;
    /// @dev Mirrors MarketMaker.FEE_RANGE so the library is self-contained for fee math.
    uint64 internal constant FEE_RANGE = 10 ** 18;
    /// @dev Upper bound on post-correction decrement iterations. Empirically converges
    ///      in 1–2 steps; the cap exists so a pathological input reverts instead of
    ///      spinning forever. Exposed via `maxCorrectionIterations()` because
    ///      Solidity 0.5 does not allow external reads of library internal constants.
    uint256 internal constant MAX_CORRECTION_ITERATIONS = 5;

    function maxCorrectionIterations() internal pure returns (uint256) {
        return MAX_CORRECTION_ITERATIONS;
    }

    /// @notice Combined fee = base + surcharge, with overflow + range checks matching
    ///         the on-chain `tradeWithSurcharge` invariant.
    function totalFee(uint64 baseFee, uint64 surcharge) internal pure returns (uint64) {
        require(uint256(baseFee) + uint256(surcharge) <= uint256(FEE_RANGE), "fee overflow");
        return baseFee + surcharge;
    }

    /// @notice Strip the fee out of a target collateral spend to get the LMSR-side
    ///         cost target: `collateralIn = netCost * (1 + totalFee/FEE_RANGE)`.
    function netCostTargetFromCollateralIn(uint256 collateralIn, uint64 _totalFee)
        internal
        pure
        returns (uint256)
    {
        return collateralIn * uint256(FEE_RANGE) / (uint256(FEE_RANGE) + uint256(_totalFee));
    }

    /// @notice Closed-form inverse of the binary LMSR cost function.
    ///         Returns the largest integer q such that the *real-valued* cost(q) ≤
    ///         `netCostTarget` (rounded conservatively so the Solidity-integer q never
    ///         exceeds the true solution).
    ///
    ///  Binary LMSR, log2N = ONE_FP:
    ///    netCost(q) = funding * log2( 2^((q - B_self)/funding) + 2^(-B_other/funding) )
    ///    q = B_self + funding * log2( 2^(netCostTarget/funding) - 2^(-B_other/funding) )
    ///
    ///  Rounding modes ensure computed q ≤ true q:
    ///   - sTarget uses LowerBound  (sTarget ≤ true 2^(C/b))
    ///   - expOther uses UpperBound (expOther ≥ true 2^(-B_other/b))
    ///   ⇒ expSelf = sTarget - expOther ≤ true expSelf
    ///   - binaryLog uses LowerBound (log2 ≤ true log2)
    ///   - final `funding * log2Self / ONE_FP` uses floor-toward-minus-infinity.
    function closedFormQ(uint256 funding, uint256 bSelf, uint256 bOther, uint256 netCostTarget)
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

    /// @notice Convert a collateral overshoot (cost+fee − collateralIn) back into a
    ///         token decrement using the local marginal price, scaled down by (1+fee).
    ///         Caller passes the marginal price in fixed-point form (`Fixed192x64Math`
    ///         convention; same value the pool's `calcMarginalPrice` returns).
    function estimateDecrement(uint256 marginalPriceFP, uint256 overshoot, uint64 _totalFee)
        internal
        pure
        returns (uint256)
    {
        uint256 priceFP = marginalPriceFP == 0 ? 1 : marginalPriceFP;
        // overshoot collateral → tokens: dq = overshoot * ONE_FP / priceFP, then scale
        // down by (1 + fee). The +2 is a safety margin for rounding inside the estimate.
        uint256 dq = overshoot * ONE_FP / priceFP;
        dq = dq * uint256(FEE_RANGE) / (uint256(FEE_RANGE) + uint256(_totalFee));
        return dq + 2;
    }
}
