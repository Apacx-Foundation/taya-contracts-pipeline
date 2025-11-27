## UMA Network Config

This directory stores UMA contract addresses for each supported network. When you
need to update values such as `IFinder` or `OptimisticOracleV2`, reference UMA's
official network manifest:

- Sepolia (chain `11155111`): https://raw.githubusercontent.com/UMAprotocol/protocol/master/packages/core/networks/11155111.json
- Polygon (chain `137`): https://raw.githubusercontent.com/UMAprotocol/protocol/master/packages/core/networks/137.json

That JSON file is maintained by UMA and lists the canonical addresses (e.g.
`Finder`, `OptimisticOracle`, `OptimisticOracleV2`, `AddressWhitelist`). Copy the
relevant entries into the corresponding `uma.json` file here to keep our config
in sync with upstream deployments.

For other networks, replace the chain ID in the URL above with the target
network's chain ID and update the matching subdirectory.
