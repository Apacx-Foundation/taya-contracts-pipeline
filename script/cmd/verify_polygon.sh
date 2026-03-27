#!/usr/bin/env bash

set -eo pipefail

CHAIN_ID=137
NETWORK_CONFIG_PATH="./config/networks/${CHAIN_ID}.json"
OUTPUT_PATH="./script/output/${CHAIN_ID}.json"
RPC_URL_VAR="POLYGON_RPC_URL"

# Load environment variables
set -a
source .env.development
set +a

RPC_URL="${!RPC_URL_VAR}"

if [[ -z "${ETHERSCAN_API_KEY:-}" ]]; then
  echo "ERROR: ETHERSCAN_API_KEY is not set"
  exit 1
fi

FIXED_MATH_LIB_PATH="node_modules/@gnosis.pm/util-contracts/contracts/Fixed192x64Math.sol:Fixed192x64Math"

# Read addresses from deployment output
CTF_ADDRESS=$(jq -r '.ctf' "$OUTPUT_PATH")
FIXED_MATH_LIB_ADDRESS=$(jq -r '.fixedMathLib' "$OUTPUT_PATH")
ADAPTER_ADDRESS=$(jq -r '.umaAdapter' "$OUTPUT_PATH")
ADAPTER_GATE_ADDRESS=$(jq -r '.umaAdapterGate' "$OUTPUT_PATH")
FPMM_FACTORY_ADDRESS=$(jq -r '.fpmmFactory' "$OUTPUT_PATH")
CAPPED_LMSR_FACTORY_ADDRESS=$(jq -r '.cappedLmsrFactory' "$OUTPUT_PATH")
WHITELIST_ADDRESS=$(jq -r '.whitelist' "$OUTPUT_PATH")
BETTING_TOKEN_PROXY=$(jq -r '.bettingToken' "$OUTPUT_PATH")
FINDER_ADDRESS=$(jq -r '.uma.finder' "$NETWORK_CONFIG_PATH")
OO_ADDRESS=$(jq -r '.uma.optimisticOracleV2' "$NETWORK_CONFIG_PATH")

# Resolve BettingToken implementation address from proxy
BETTING_TOKEN_IMPL=$(cast implementation "$BETTING_TOKEN_PROXY" --rpc-url "$RPC_URL")

echo "Verifying contracts on chain ${CHAIN_ID}..."
echo "  BettingToken proxy: ${BETTING_TOKEN_PROXY}"
echo "  BettingToken impl:  ${BETTING_TOKEN_IMPL}"

# --- UmaCtfAdapterDemo ---
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

# --- UmaCtfAdapterGate ---
FOUNDRY_PROFILE=default
forge verify-contract \
  --chain-id "$CHAIN_ID" \
  --compiler-version "0.8.15" \
  --constructor-args "$(cast abi-encode "constructor(address)" "$ADAPTER_ADDRESS")" \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  "$ADAPTER_GATE_ADDRESS" \
  --root "." \
  --watch \
  "src/UmaCtfAdapterGate.sol:UmaCtfAdapterGate"

# --- ConditionalTokens ---
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

# --- FPMMDeterministicFactory ---
FOUNDRY_PROFILE=market \
FOUNDRY_LIBS='["lib","node_modules"]' \
FOUNDRY_ALLOW_PATHS='["lib","../lib","../../lib", "../node_modules"]' \
FOUNDRY_REMAPPINGS='["openzeppelin-solidity/=node_modules/openzeppelin-solidity/", "conditional-tokens-contracts/=lib/taya-conditional-tokens-contracts", "util-contracts/=node_modules/@gnosis.pm/util-contracts/", "canonical-weth/=node_modules/canonical-weth/"]' \
forge verify-contract \
  --chain-id "$CHAIN_ID" \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  --compiler-version "v0.5.10+commit.5a6ea5b1" \
  --num-of-optimizations 200 \
  --evm-version "petersburg" \
  --watch \
  "$FPMM_FACTORY_ADDRESS" \
  "lib/taya-conditional-tokens-market-makers/contracts/FPMMDeterministicFactory.sol:FPMMDeterministicFactory"

# --- Fixed192x64Math ---
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

# --- WhitelistAccessControl ---
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
  "$WHITELIST_ADDRESS" \
  "src_market_ext/WhitelistAccessControl.sol:WhitelistAccessControl"

# --- BettingToken (verify implementation, not proxy) ---
FOUNDRY_PROFILE=default
forge verify-contract \
  --chain-id "$CHAIN_ID" \
  --compiler-version "0.8.15" \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  "$BETTING_TOKEN_IMPL" \
  --root "." \
  --watch \
  "src/BettingToken.sol:BettingToken"

echo "✓ All verifications submitted"
