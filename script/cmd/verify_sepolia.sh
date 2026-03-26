#!/usr/bin/env bash

set -eo pipefail

CHAIN_ID=11155111
NETWORK_CONFIG_PATH="./config/networks/${CHAIN_ID}.json"
OUTPUT_PATH="./script/output/${CHAIN_ID}.json"

# Load environment variables
set -a
source .env.development
set +a

if [[ -z "${ETHERSCAN_API_KEY:-}" ]]; then
  echo "ERROR: ETHERSCAN_API_KEY is not set"
  exit 1
fi

# Read deployed addresses from output
CTF_ADDRESS=$(jq -r '.ctf // empty' "$OUTPUT_PATH")
ADAPTER_ADDRESS=$(jq -r '.umaAdapter // empty' "$OUTPUT_PATH")
FIXED_MATH_LIB_ADDRESS=$(jq -r '.fixedMathLib // empty' "$OUTPUT_PATH")
CAPPED_LMSR_FACTORY_ADDRESS=$(jq -r '.cappedLmsrFactory // empty' "$OUTPUT_PATH")
WHITELIST_FACTORY_ADDRESS=$(jq -r '.whitelistFactory // empty' "$OUTPUT_PATH")
PLATFORM_REGISTRY_ADDRESS=$(jq -r '.platformRegistry // empty' "$OUTPUT_PATH")
FINDER_ADDRESS=$(jq -r '.uma.finder // empty' "$NETWORK_CONFIG_PATH")
OO_ADDRESS=$(jq -r '.uma.optimisticOracleV2 // empty' "$NETWORK_CONFIG_PATH")

FIXED_MATH_LIB_PATH="node_modules/@gnosis.pm/util-contracts/contracts/Fixed192x64Math.sol:Fixed192x64Math"

echo "Verifying contracts on chain ${CHAIN_ID}..."
echo "  ConditionalTokens:              ${CTF_ADDRESS}"
echo "  UmaCtfAdapterDemo:              ${ADAPTER_ADDRESS}"
echo "  Fixed192x64Math:                ${FIXED_MATH_LIB_ADDRESS}"
echo "  CappedLMSRDeterministicFactory: ${CAPPED_LMSR_FACTORY_ADDRESS}"
echo "  WhitelistFactory:               ${WHITELIST_FACTORY_ADDRESS}"
echo "  PlatformRegistry (proxy):       ${PLATFORM_REGISTRY_ADDRESS}"

# --- UmaCtfAdapterDemo ---
echo ""
echo "--- Verifying UmaCtfAdapterDemo ---"
CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(address,address,address)" "$CTF_ADDRESS" "$FINDER_ADDRESS" "$OO_ADDRESS")

FOUNDRY_PROFILE=default
forge verify-contract \
  --chain-id "$CHAIN_ID" \
  --compiler-version "0.8.15" \
  --constructor-args "$CONSTRUCTOR_ARGS" \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  "$ADAPTER_ADDRESS" \
  --root "lib/taya-uma-ctf-adapter" \
  --watch \
  "src/UmaCtfAdapterDemo.sol:UmaCtfAdapterDemo"

# --- ConditionalTokens ---
echo ""
echo "--- Verifying ConditionalTokens ---"
FOUNDRY_PROFILE=ctf \
FOUNDRY_LIBS='["lib"]' \
FOUNDRY_ALLOW_PATHS='["lib","../lib","../../lib","../node_modules"]' \
FOUNDRY_REMAPPINGS='["openzeppelin-solidity/=node_modules/openzeppelin-solidity/"]' \
forge verify-contract \
  --chain-id "$CHAIN_ID" \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  --compiler-version "v0.5.10+commit.5a6ea5b1" \
  --num-of-optimizations 200 \
  --evm-version "petersburg" \
  --watch \
  "$CTF_ADDRESS" \
  "lib/taya-conditional-tokens-contracts/contracts/ConditionalTokens.sol:ConditionalTokens"

# --- Fixed192x64Math ---
echo ""
echo "--- Verifying Fixed192x64Math ---"
FOUNDRY_PROFILE=market \
FOUNDRY_LIBS='["lib","node_modules"]' \
FOUNDRY_ALLOW_PATHS='["lib","../lib","../../lib", "../node_modules"]' \
FOUNDRY_REMAPPINGS='["openzeppelin-solidity/=node_modules/openzeppelin-solidity/", "util-contracts/=node_modules/@gnosis.pm/util-contracts/"]' \
forge verify-contract \
  --chain-id "$CHAIN_ID" \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  --compiler-version "v0.5.10+commit.5a6ea5b1" \
  --num-of-optimizations 200 \
  --evm-version "petersburg" \
  --watch \
  "$FIXED_MATH_LIB_ADDRESS" \
  "node_modules/@gnosis.pm/util-contracts/contracts/Fixed192x64Math.sol:Fixed192x64Math"

# --- CappedLMSRDeterministicFactory ---
echo ""
echo "--- Verifying CappedLMSRDeterministicFactory ---"
FOUNDRY_PROFILE=market_ext \
FOUNDRY_LIBS='["lib","node_modules"]' \
FOUNDRY_ALLOW_PATHS='["lib","../lib","../../lib", "../node_modules"]' \
FOUNDRY_REMAPPINGS='["market-makers/=lib/taya-conditional-tokens-market-makers/contracts/", "openzeppelin-solidity/=node_modules/openzeppelin-solidity/", "conditional-tokens-contracts/=lib/taya-conditional-tokens-contracts/contracts/", "util-contracts/=node_modules/@gnosis.pm/util-contracts/", "canonical-weth/=node_modules/canonical-weth/"]' \
forge verify-contract \
  --chain-id "$CHAIN_ID" \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  --compiler-version "v0.5.10+commit.5a6ea5b1" \
  --num-of-optimizations 200 \
  --evm-version "petersburg" \
  --libraries "${FIXED_MATH_LIB_PATH}:${FIXED_MATH_LIB_ADDRESS}" \
  --watch \
  "$CAPPED_LMSR_FACTORY_ADDRESS" \
  "src_market_ext/CappedLMSRDeterministicFactory.sol:CappedLMSRDeterministicFactory"

# --- WhitelistFactory ---
echo ""
echo "--- Verifying WhitelistFactory ---"
FOUNDRY_PROFILE=market_ext \
FOUNDRY_LIBS='["lib","node_modules"]' \
FOUNDRY_ALLOW_PATHS='["lib","../lib","../../lib", "../node_modules"]' \
FOUNDRY_REMAPPINGS='["market-makers/=lib/taya-conditional-tokens-market-makers/contracts/", "openzeppelin-solidity/=node_modules/openzeppelin-solidity/"]' \
forge verify-contract \
  --chain-id "$CHAIN_ID" \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  --compiler-version "v0.5.10+commit.5a6ea5b1" \
  --num-of-optimizations 200 \
  --evm-version "petersburg" \
  --watch \
  "$WHITELIST_FACTORY_ADDRESS" \
  "src_market_ext/WhitelistFactory.sol:WhitelistFactory"

# --- PlatformRegistry (UUPS proxy) ---
echo ""
echo "--- Verifying PlatformRegistry + PlatformUser ---"
REGISTRY_IMPL=$(cast implementation "$PLATFORM_REGISTRY_ADDRESS" --rpc-url "$SEPOLIA_RPC_URL")
WALLET_BEACON=$(cast call "$PLATFORM_REGISTRY_ADDRESS" "walletBeacon()(address)" --rpc-url "$SEPOLIA_RPC_URL")
WALLET_IMPL=$(cast call "$WALLET_BEACON" "implementation()(address)" --rpc-url "$SEPOLIA_RPC_URL")

echo "  PlatformRegistry impl:          ${REGISTRY_IMPL}"
echo "  PlatformUser impl:              ${WALLET_IMPL}"

FOUNDRY_PROFILE=default
forge verify-contract \
  --chain-id "$CHAIN_ID" \
  --compiler-version "0.8.15" \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  --watch \
  "$REGISTRY_IMPL" \
  "src/PlatformRegistry.sol:PlatformRegistry"

FOUNDRY_PROFILE=default
forge verify-contract \
  --chain-id "$CHAIN_ID" \
  --compiler-version "0.8.15" \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  --watch \
  "$WALLET_IMPL" \
  "src/PlatformUser.sol:PlatformUser"

echo ""
echo "Verification complete."
