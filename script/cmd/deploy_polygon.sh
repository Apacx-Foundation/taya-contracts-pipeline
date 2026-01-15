#!/usr/bin/env bash

set -eo pipefail

CHAIN_ID=137
NETWORK_CONFIG_PATH="./config/networks/${CHAIN_ID}.json"
OUTPUT_PATH="./script/output/${CHAIN_ID}.json"

# Load environment variables
set -a
source .env.development
set +a

forge clean
FOUNDRY_PROFILE=ctf forge build --force
FOUNDRY_PROFILE=market forge build --force --silent
forge build --force

FOUNDRY_PROFILE=default
forge script ./script/DeployAdapterDemo.s.sol \
  --rpc-url "$POLYGON_RPC_URL" \
  --broadcast \
  --private-key="$PRIVATE_KEY" \
  --isolate 

CTF_ADDRESS=$(jq -r '.ctf' "$OUTPUT_PATH")
ADAPTER_ADDRESS=$(jq -r '.umaAdapter' "$OUTPUT_PATH")
FPMM_FACTORY_ADDRESS=$(jq -r '.fpmmFactory' "$OUTPUT_PATH")
FINDER_ADDRESS=$(jq -r '.uma.finder' "$NETWORK_CONFIG_PATH")
OO_ADDRESS=$(jq -r '.uma.optimisticOracleV2' "$NETWORK_CONFIG_PATH")

echo "✓ Deployments"
echo "  ConditionalTokens:      ${CTF_ADDRESS}"
echo "  UmaCtfAdapterDemo:      ${ADAPTER_ADDRESS}"
echo "  FPMMDeterministicFactory: ${FPMM_FACTORY_ADDRESS}"

if [[ -n "${ETHERSCAN_API_KEY:-}" ]]; then
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
else
  echo "⚠️  Skipping verification; ETHERSCAN_API_KEY is not set."
fi