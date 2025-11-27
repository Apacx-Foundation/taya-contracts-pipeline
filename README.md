## Taya Contracts Pipeline

This package contains the Foundry-based tooling we use to compile, deploy and
verify the on-chain components that power the Taya conditional tokens +
UMA adapter stack. It bundles the “legacy” Gnosis Conditional Tokens contracts, plus a set of scripted deploy
flows for Sepolia and Polygon.

### Features

- **Dual-compilation**: `ctf` profile builds the 0.5.10 ConditionalTokens
  tree out of `lib/taya-conditional-tokens-contracts`, while the default profile
  builds the 0.8.x adapter contracts.
- **One-click deployment**: `script/cmd/deploy_sepolia.sh` (and
  `deploy_polygon.sh`) compile both sets of contracts, deploy ConditionalTokens
  - UMA adapter, write their addresses into `config/networks/<chain>.json` and
    trigger Etherscan verification.
- **Submodule managed deps**: `lib/taya-conditional-tokens-contracts`,
  `lib/taya-conditional-tokens-market-makers`, `lib/taya-uma-ctf-adapter`,
  `lib/openzeppelin-contracts@v2.3.0` and `lib/forge-std` are proper git
  submodules so we can pin upstream commits. Bringing in the market-maker repo
  lets us ship the deterministic FPMM factory alongside the CT + UMA stack.

### Local Requirements

**Install Foundry (`foundry=v1.4.4-stable`)**

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
forge --version    # should show forge Version: 1.4.4-stable (or newer)
```

### Getting Started

1. **Install dependencies**
   ```bash
   git submodule update --init --recursive
   pnpm install
   ```
2. **Create `.env.development`**
   ```env
   SEPOLIA_RPC_URL=...
   POLYGON_RPC_URL=...
   PRIVATE_KEY=0x...
   ETHERSCAN_API_KEY=...
   POLYGONSCAN_API_KEY=...
   ```
   Keep this file out of git (it’s ignored by `.gitignore`).
3. **Build everything**
   ```bash
   cd apps/contracts-pipeline
   forge clean
   FOUNDRY_PROFILE=ctf forge build --force      # legacy CT contracts
   FOUNDRY_PROFILE=market forge build --force   # FPMM factory + markets
   forge build --force                          # UMA adapter + helpers
   ```

### Deployment Workflows

#### Sepolia (CTF + UMA demo)

```bash
./script/cmd/deploy_sepolia.sh
```

This script will:

- run `forge build` for the `ctf`, `market`, and default profiles
- deploy `ConditionalTokens`, `FPMMDeterministicFactory`, and `UmaCtfAdapterDemo` (Demo contract with 10 second `SAFETY_PERIOD` for QA purposes)
- update `config/networks/11155111.json` with `ctf`, `fpmmFactory`, and adapter
- verify all three contracts (adapter uses `--root lib/taya-uma-ctf-adapter`,
  CT + FPMM reuse their submodule sources with the
  `openzeppelin-solidity/=lib/openzeppelin-contracts@v2.3.0/` remap)

#### Polygon (mainnet-style)

```bash
./script/cmd/deploy_polygon.sh
```

Same flow as above but targeting the Polygon RPC + Polygonscan key. Adjust
`config/networks/137.json` before running. The factory is deployed/verified on
Polygon as well so you can spin up FPMMs against mainnet CT deployments. Default `UmaCtfAdapter` is deployed with 1hr `SAFETY_PERIOD` as well.

### Fixed Product Market Maker Factory

The `market` Foundry profile compiles the contracts from
`lib/taya-conditional-tokens-market-makers` into `out_market/`.

- **Build only the factory stack**
  ```bash
  FOUNDRY_PROFILE=market forge build --force
  ```
- **Scripted deployment**
  Both `script/DeployAdapter.s.sol` and `script/DeployAdapterDemo.s.sol`
  broadcast `ConditionalTokens`, `FPMMDeterministicFactory`, and the UMA adapter
  in one go, then write the resulting addresses to
  `script/output/<chainId>.json`. You can run them directly (instead of the
  shell wrappers) if you need a custom RPC:
  ```bash
  forge script script/DeployAdapter.s.sol \
    --rpc-url $RPC_URL \
    --private-key $PRIVATE_KEY \
    --broadcast --verify
  ```

### Useful Commands

| Task                     | Command                                          |
| ------------------------ | ------------------------------------------------ |
| Build adapters           | `forge build`                                    |
| Build conditional tokens | `FOUNDRY_PROFILE=ctf forge build`                |
| Build FPMM factory       | `FOUNDRY_PROFILE=market forge build`             |
| Run unit tests           | `forge test -vvv`                                |
| Format                   | `forge fmt`                                      |
| Local node               | `anvil`                                          |
| Custom scripts           | `forge script script/DeployAdapter.s.sol --help` |

### Notes

- For verification of legacy 0.5.x contracts, avoid `--flatten`: use the
  original submodule sources with the proper remappings/allow paths instead.
