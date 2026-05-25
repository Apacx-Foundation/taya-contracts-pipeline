pragma solidity ^0.5.1;

import {Fixed192x64Math} from "@gnosis.pm/util-contracts/contracts/Fixed192x64Math.sol";
import {SafeMath} from "openzeppelin-solidity/contracts/math/SafeMath.sol";
import {SignedSafeMath} from "@gnosis.pm/util-contracts/contracts/SignedSafeMath.sol";
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
    using SafeMath for uint256;
    using SignedSafeMath for int256;

    uint256 internal constant ONE_FP = 0x10000000000000000;
    int256 internal constant EXP_LIMIT = 3394200909562557497344;
    uint64 internal constant FEE_RANGE = 10 ** 18;
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
        uint256 netCostTarget = collateralIn.mul(uint256(FEE_RANGE)) / (uint256(FEE_RANGE) + uint256(totalFee));
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

    /// @dev Pure binary LMSR raw-cost calculation matching `LMSRMarketMaker.calcNetCost`.
    ///      Does not include market fees. Positive values are collateral owed by the buyer;
    ///      negative values are collateral owed by the pool.
    function calcNetCost(uint256 funding, uint256 yesBalance, uint256 noBalance, int256 yesAmount, int256 noAmount)
        internal
        pure
        returns (int256 netCost)
    {
        require(funding > 0, "funding zero");
        require(funding < (uint256(1) << 255), "funding overflow");
        require(yesBalance < (uint256(1) << 255), "yesBalance overflow");
        require(noBalance < (uint256(1) << 255), "noBalance overflow");

        int256 log2N = Fixed192x64Math.binaryLog(2 * ONE_FP, Fixed192x64Math.EstimationMode.UpperBound);
        int256 yesExpNum = yesAmount.sub(int256(yesBalance));
        int256 noExpNum = noAmount.sub(int256(noBalance));

        int256 offset = (yesExpNum >= noExpNum) ? yesExpNum : noExpNum;
        offset = offset.mul(log2N) / int256(funding);
        offset = offset.sub(EXP_LIMIT);

        uint256 yesTerm = Fixed192x64Math.pow2(
            (yesExpNum.mul(log2N) / int256(funding)).sub(offset), Fixed192x64Math.EstimationMode.UpperBound
        );
        uint256 noTerm = Fixed192x64Math.pow2(
            (noExpNum.mul(log2N) / int256(funding)).sub(offset), Fixed192x64Math.EstimationMode.UpperBound
        );

        netCost = Fixed192x64Math.binaryLog(yesTerm.add(noTerm), Fixed192x64Math.EstimationMode.UpperBound);
        netCost = netCost.add(offset);
        netCost = (netCost.mul(int256(ONE_FP)) / log2N).mul(int256(funding));

        if (netCost <= 0 || netCost / int256(ONE_FP) * int256(ONE_FP) == netCost) {
            netCost /= int256(ONE_FP);
        } else {
            netCost = netCost / int256(ONE_FP) + 1;
        }
    }

    /// @notice Pure binary LMSR cost including market fee.
    /// @dev `totalFee` should be base fee plus surcharge, denominated by `FEE_RANGE`.
    function calcNetCost(
        uint256 funding,
        uint256 yesBalance,
        uint256 noBalance,
        int256 yesAmount,
        int256 noAmount,
        uint64 totalFee
    ) public pure returns (int256 netCostWithFee) {
        require(totalFee <= FEE_RANGE, "fee overflow");
        int256 rawCost = calcNetCost(funding, yesBalance, noBalance, yesAmount, noAmount);
        // Fees are always added to raw cost; for sells this reduces the user's payout.
        uint256 feeAmount = rawCost < 0
            ? uint256(-rawCost).mul(uint256(totalFee)) / uint256(FEE_RANGE)
            : uint256(rawCost).mul(uint256(totalFee)) / uint256(FEE_RANGE);
        return rawCost.add(int256(feeAmount));
    }

    /// @notice Execute an exact-collateral buy. Designed for DELEGATECALL from a smart account;
    ///         the caller (the account whose context this runs in) must have approved
    ///         `collateralIn` of the pool's collateralToken to the pool.
    ///
    ///         coverCollateral=true  → user spends EXACTLY `collateralIn`; the residual
    ///           `collateralIn - (cost+fee)` is pulled into the pool as a dust fee, bounded
    ///           by `_estimateDecrement`'s per-iteration cap:
    ///             dust ≤ collateralIn/2000 + 2·ε(f)·(1+φ) + 1 wei
    ///           where ε(f) = 1024 + funding/2^60. ≤ 0.05% of the trade for any
    ///           collateralIn ≫ ε(f). Retail UX: "I said $10, I spent $10".
    ///         coverCollateral=false → user spends only `cost+fee` (≤ `collateralIn`); residual
    ///           (same bound as above) stays with the caller. Power-user / API flow.
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
        // uint256→int256 cast guards: a value ≥ 2^255 would wrap negative and flip the buy into a sell.
        require(outcomeTokens < (uint256(1) << 255), "outcomeTokens overflow");
        require(collateralIn < (uint256(1) << 255), "collateralIn overflow");

        int256[] memory amounts = new int256[](2);
        amounts[outcomeIndex] = int256(outcomeTokens);
        CappedLMSRMarketMaker(pool).tradeWithSurcharge(amounts, int256(collateralIn), surchargeRate, coverCollateral);
    }

    // --- internals --------------------------------------------------------

    function _totalFee(address pool, uint64 surchargeRate) internal view returns (uint64) {
        uint64 baseFee = CappedLMSRMarketMaker(pool).fee();
        uint256 combined = uint256(baseFee).add(uint256(surchargeRate));
        require(combined <= uint256(FEE_RANGE), "fee overflow");
        return uint64(combined);
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
        uint256 uCost = uint256(cost);
        uint256 totalCost = uCost.add(uCost.mul(uint256(totalFee)) / uint256(FEE_RANGE));
        if (totalCost <= collateralIn) return (true, q);

        uint256 dq = _estimateDecrement(pool, outcomeIndex, totalCost - collateralIn, totalFee, collateralIn);
        if (dq >= q) return (true, 0);
        return (false, q - dq);
    }

    /// @dev Token decrement for one post-correction step. Per-iteration cost
    ///      movement is capped at `collateralIn / DUST_DIVISOR` collateral wei
    ///      so the algorithm's terminal `T̃(q)` lands at most one cap-width
    ///      below the budget. That gives a provable upper bound on the dust
    ///      (`leftover = collateralIn − T̃(q) ≤ collateralIn / DUST_DIVISOR ·
    ///      (1 + φ) + 2 · ε(f) · (1 + φ) + 1 wei`), bounded relative to the
    ///      trade size rather than the pool — auditors can derive it directly
    ///      from this function and `_postCorrect`.
    ///
    ///      Without the cap, an extreme balance imbalance can let `priceFP`
    ///      degenerate near 1 and Newton's `Δq` blow up, over-decrementing q
    ///      well below q* and leaving large dust.
    ///
    ///      DUST_DIVISOR = 2000. Provable dust:
    ///        leftover ≤ collateralIn/2000 + 2·ε(f)·(1+φ) + 1 wei.
    ///      For collateralIn ≫ ε(f), this is ≤ 0.05% of the trade. Convergence
    ///      in MAX_CORRECTION_ITERATIONS iterations requires
    ///      collateralIn ≥ DUST_DIVISOR·(ε(f)·(1+φ)+1)/5, i.e. ~720·ε(f)·(1+φ)
    ///      at K=2000. Holds across the fuzz parameter space (smallest case:
    ///      funding=10^9, C=10^6, φ=80% ⇒ ~737k bound, fuzz uses C=10^6).
    function _estimateDecrement(
        address pool,
        uint8 outcomeIndex,
        uint256 overshoot,
        uint64 totalFee,
        uint256 collateralIn
    ) internal view returns (uint256) {
        uint256 priceFP = CappedLMSRMarketMaker(pool).calcMarginalPrice(outcomeIndex);
        if (priceFP == 0) priceFP = 1;
        uint256 plateauCollateral = uint256(1024).add(CappedLMSRMarketMaker(pool).funding() >> 60);
        uint256 dq = overshoot.add(plateauCollateral).mul(ONE_FP) / priceFP;
        uint256 dqCap = collateralIn.mul(ONE_FP) / priceFP / 2000;
        if (dq > dqCap) dq = dqCap;
        return dq.mul(uint256(FEE_RANGE)) / (uint256(FEE_RANGE) + uint256(totalFee));
    }
}
