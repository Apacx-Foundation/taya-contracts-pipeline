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
}
