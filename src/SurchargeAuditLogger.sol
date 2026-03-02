// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

interface IERC1155 {
    function balanceOf(address account, uint256 id) external view returns (uint256);
}

interface ICappedLMSR {
    function funding() external view returns (uint256);
    function lossUsed() external view returns (uint256);
    function fee() external view returns (uint64);
}

contract SurchargeAuditLogger {
    struct PoolSnapshot {
        uint256 yesBalance;
        uint256 noBalance;
        uint256 funding;
        uint256 lossUsed;
        uint64 fee;
    }

    struct BillingInfo {
        uint256 billedSurcharge;
        uint16 billedBps;
        uint8 direction; // 0 = buy, 1 = sell
        uint8 outcome;   // 0 = yes, 1 = no
    }

    event SurchargeAudit(
        address indexed pool,
        address indexed trader,
        PoolSnapshot snapshot,
        BillingInfo billing,
        bytes32 rulesHash
    );

    function log(
        address pool,
        address trader,
        address ctf,
        uint256 yesId,
        uint256 noId,
        BillingInfo calldata billing,
        bytes32 rulesHash
    ) external {
        PoolSnapshot memory snap = PoolSnapshot({
            yesBalance: IERC1155(ctf).balanceOf(pool, yesId),
            noBalance: IERC1155(ctf).balanceOf(pool, noId),
            funding: ICappedLMSR(pool).funding(),
            lossUsed: ICappedLMSR(pool).lossUsed(),
            fee: ICappedLMSR(pool).fee()
        });

        emit SurchargeAudit(pool, trader, snap, billing, rulesHash);
    }
}
