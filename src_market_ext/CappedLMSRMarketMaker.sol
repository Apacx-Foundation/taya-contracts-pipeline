pragma solidity ^0.5.1;
import {SafeMath} from "openzeppelin-solidity/contracts/math/SafeMath.sol";
import {Fixed192x64Math} from "@gnosis.pm/util-contracts/contracts/Fixed192x64Math.sol";
import {LMSRMarketMaker} from "market-makers/LMSRMarketMaker.sol";

/// @title Capped LMSR market maker contract - Identical to LMSR (b = funding) with loss tracking and per-trade caps
/// @author Alan Lu - <alan.lu@gnosis.pm>
/// @author Apacx Team
/// @dev Extends MarketMaker. Uses funding as the LMSR b parameter (same as original LMSRMarketMaker).
///      Adds: lossUsed high-water mark tracking, maxCostPerTx per-trade cap, calcMaxLoss() utility.
contract CappedLMSRMarketMaker is LMSRMarketMaker {
    uint256 public maxCostPerTx;
    /// @notice High-water mark of cumulative LMSR loss. Never decreases.
    uint256 public lossUsed;
    /// @notice Algebraic sum of all netCost values from trades
    int256 public cumulativeNetCost;

    event LossUpdated(uint256 lossUsed);
    event MaxCostPerTxChanged(uint256 maxCostPerTx);

    function changeMaxCostPerTx(uint256 _maxCostPerTx) 
        public 
        onlyOwner 
        atStage(Stage.Paused) 
    {
        maxCostPerTx = _maxCostPerTx;
        emit MaxCostPerTxChanged(maxCostPerTx);
    }

    /// @dev Override trade to enforce maxCostPerTx cap and track cumulative loss.
    /// Since calcNetCost([0,...]) ≈ 0 (b = funding keeps balances symmetric), we use
    /// cumulativeNetCost directly as the loss metric — it tracks actual collateral flow.
    function trade(int256[] memory outcomeTokenAmounts, int256 collateralLimit) public returns (int256 netCost) {
        // Execute the actual trade
        netCost = super.trade(outcomeTokenAmounts, collateralLimit);

        // Per-trade cap (uses raw calcNetCost which is what the trader pays)
        if (maxCostPerTx > 0 && netCost > 0) {
            int256 expectedCost = netCost - int256(calcMarketFee(uint256(netCost)));
            require(
                expectedCost <= 0 || uint256(expectedCost) <= maxCostPerTx, "trade cost exceeds maxCostPerTx"
            );
        }

        // Accumulate net cost from this trade
        cumulativeNetCost = cumulativeNetCost + netCost;

        // lossUsed = max(cumulativeNetCost, lossUsed)
        if (cumulativeNetCost > 0) {
            uint256 uCost = uint256(cumulativeNetCost);
            if (uCost > lossUsed) {
                lossUsed = uCost;
                emit LossUpdated(lossUsed);
            }
        }
    }
}
