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
FOUNDRY_PROFILE=market_ext forge build --force --silent
forge build --force

# Deploy Fixed192x64Math library first (required by LMSRMarketMaker)
echo "Deploying Fixed192x64Math library..."
FIXED_MATH_LIB_PATH="node_modules/@gnosis.pm/util-contracts/contracts/Fixed192x64Math.sol:Fixed192x64Math"
# forge create outputs "Deployed to: 0x..." which we can parse
FIXED_MATH_DEPLOY_OUTPUT=$(FOUNDRY_PROFILE=market forge create \
  --rpc-url "$POLYGON_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  "node_modules/@gnosis.pm/util-contracts/contracts/Fixed192x64Math.sol:Fixed192x64Math" 2>&1)
FIXED_MATH_LIB_ADDRESS=$(echo "$FIXED_MATH_DEPLOY_OUTPUT" | grep "Deployed to:" | sed 's/.*Deployed to: //')
echo "Fixed192x64Math deployed at: $FIXED_MATH_LIB_ADDRESS"

if [[ -z "$FIXED_MATH_LIB_ADDRESS" || "$FIXED_MATH_LIB_ADDRESS" != 0x* ]]; then
  echo "ERROR: Failed to deploy Fixed192x64Math library"
  echo "$FIXED_MATH_DEPLOY_OUTPUT"
  exit 1
fi

# Rebuild market profile with the library linked so vm.deployCode can use linked artifacts
echo "Rebuilding market contracts with library linked..."
FOUNDRY_PROFILE=market forge build --force \
  --libraries "${FIXED_MATH_LIB_PATH}:${FIXED_MATH_LIB_ADDRESS}"

echo "Rebuilding market_ext contracts with library linked..."
FOUNDRY_PROFILE=market_ext forge build --force \
  --libraries "${FIXED_MATH_LIB_PATH}:${FIXED_MATH_LIB_ADDRESS}"

FOUNDRY_PROFILE=default
forge script ./script/DeployAdapter.s.sol \
  --rpc-url "$POLYGON_RPC_URL" \
  --broadcast \
  --private-key="$PRIVATE_KEY" \
  --isolate

# Inject fixedMathLib into output JSON (deployed via forge create, not forge script)
jq --arg addr "$FIXED_MATH_LIB_ADDRESS" '. + {fixedMathLib: $addr}' "$OUTPUT_PATH" > "${OUTPUT_PATH}.tmp" && mv "${OUTPUT_PATH}.tmp" "$OUTPUT_PATH"

CTF_ADDRESS=$(jq -r '.ctf' "$OUTPUT_PATH")
ADAPTER_ADDRESS=$(jq -r '.umaAdapter' "$OUTPUT_PATH")
ADAPTER_GATE_ADDRESS=$(jq -r '.umaAdapterGate' "$OUTPUT_PATH")
FPMM_FACTORY_ADDRESS=$(jq -r '.fpmmFactory' "$OUTPUT_PATH")
CAPPED_LMSR_FACTORY_ADDRESS=$(jq -r '.cappedLmsrFactory' "$OUTPUT_PATH")
WHITELIST_ADDRESS=$(jq -r '.whitelist' "$OUTPUT_PATH")
BETTING_TOKEN_ADDRESS=$(jq -r '.bettingToken' "$OUTPUT_PATH")
FINDER_ADDRESS=$(jq -r '.uma.finder' "$NETWORK_CONFIG_PATH")
OO_ADDRESS=$(jq -r '.uma.optimisticOracleV2' "$NETWORK_CONFIG_PATH")

echo "✓ Deployments"
echo "  ConditionalTokens:              ${CTF_ADDRESS}"
echo "  UmaCtfAdapter:              ${ADAPTER_ADDRESS}"
echo "  FPMMDeterministicFactory:       ${FPMM_FACTORY_ADDRESS}"
echo "  Fixed192x64Math:                ${FIXED_MATH_LIB_ADDRESS}"
echo "  CappedLMSRDeterministicFactory: ${CAPPED_LMSR_FACTORY_ADDRESS}"
echo "  WhitelistAccessControl:         ${WHITELIST_ADDRESS}"
echo "  BettingToken (proxy):           ${BETTING_TOKEN_ADDRESS}"

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
    "src/UmaCtfAdapter.sol:UmaCtfAdapter"
    
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

  # Verify BettingToken implementation
  BETTING_TOKEN_IMPL=$(cast implementation "$BETTING_TOKEN_ADDRESS" --rpc-url "$POLYGON_RPC_URL")
  FOUNDRY_PROFILE=default
  forge verify-contract \
    --chain-id "$CHAIN_ID" \
    --compiler-version "0.8.15" \
    --etherscan-api-key "$ETHERSCAN_API_KEY" \
    "$BETTING_TOKEN_IMPL" \
    --root "." \
    --watch \
    "src/BettingToken.sol:BettingToken"

  # Verify BettingToken proxy (ERC1967Proxy)
  PROXY_CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(address,bytes)" "$BETTING_TOKEN_IMPL" "$(cast calldata "initialize(string,string,address[])" "Betting Token" "BET" "[$(jq -r '.admins | join(",")' "$NETWORK_CONFIG_PATH")]")")
  FOUNDRY_PROFILE=default
  forge verify-contract \
    --chain-id "$CHAIN_ID" \
    --compiler-version "0.8.15" \
    --constructor-args "$PROXY_CONSTRUCTOR_ARGS" \
    --etherscan-api-key "$ETHERSCAN_API_KEY" \
    "$BETTING_TOKEN_ADDRESS" \
    --root "." \
    --watch \
    "lib/taya-uma-ctf-adapter/lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy"
else
  echo "⚠️  Skipping verification; ETHERSCAN_API_KEY is not set."
fi