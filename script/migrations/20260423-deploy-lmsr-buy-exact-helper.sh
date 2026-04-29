#!/usr/bin/env bash
#
# Deploy LMSRBuyExactHelper.
#
# - Links the market_ext artifacts against the on-chain Fixed192x64Math address
#   (recorded in script/output/<chainId>.json during initial chain bootstrap).
# - Deploys the helper with `forge create --libraries`.
# - Records the address back into script/output/<chainId>.json as `LMSRBuyExactHelper`.
# - Writes a forge-style run-latest.json so run_migration.sh picks up the tx hash.
# - If ETHERSCAN_API_KEY is set, submits source for Etherscan verification.
#
# Invoked by script/cmd/run_migration.sh with args: <chain_id> <rpc_url> <private_key>
#
set -eo pipefail

CHAIN_ID="${1:?missing chain_id}"
RPC_URL="${2:?missing rpc_url}"
PRIVATE_KEY="${3:?missing private_key}"

OUTPUT_PATH="./script/output/${CHAIN_ID}.json"
FIXED_MATH_LIB_PATH="node_modules/@gnosis.pm/util-contracts/contracts/Fixed192x64Math.sol:Fixed192x64Math"
HELPER_CONTRACT_PATH="src_market_ext/LMSRBuyExactHelper.sol:LMSRBuyExactHelper"
MIGRATION_NAME="$(basename "$0" .sh)"

# --- Read linked-lib address -------------------------------------------------
FIXED_MATH_LIB_ADDRESS=$(jq -r '.fixedMathLib // empty' "$OUTPUT_PATH")
if [[ -z "$FIXED_MATH_LIB_ADDRESS" || "$FIXED_MATH_LIB_ADDRESS" == "null" ]]; then
  echo "ERROR: fixedMathLib not found in $OUTPUT_PATH"
  echo "       Deploy it first via deploy_{sepolia,polygon}.sh."
  exit 1
fi

# --- Link market_ext artifacts ----------------------------------------------
echo "  Linking market_ext against Fixed192x64Math at $FIXED_MATH_LIB_ADDRESS"
FOUNDRY_PROFILE=market_ext forge build --force --silent \
  --libraries "${FIXED_MATH_LIB_PATH}:${FIXED_MATH_LIB_ADDRESS}"

# --- Deploy ------------------------------------------------------------------
DEPLOY_LOG=$(mktemp)
trap 'rm -f "$DEPLOY_LOG"' EXIT

echo "  Deploying LMSRBuyExactHelper..."
FOUNDRY_PROFILE=market_ext forge create \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  --libraries "${FIXED_MATH_LIB_PATH}:${FIXED_MATH_LIB_ADDRESS}" \
  "$HELPER_CONTRACT_PATH" | tee "$DEPLOY_LOG"

HELPER_ADDRESS=$(grep "Deployed to:" "$DEPLOY_LOG" | sed 's/.*Deployed to: //' | tr -d '[:space:]')
TX_HASH=$(grep "Transaction hash:" "$DEPLOY_LOG" | sed 's/.*Transaction hash: //' | tr -d '[:space:]')

if [[ -z "$HELPER_ADDRESS" || "$HELPER_ADDRESS" != 0x* ]]; then
  echo "ERROR: failed to parse deployed address from forge output"
  exit 1
fi
echo "  LMSRBuyExactHelper deployed at: $HELPER_ADDRESS"

# --- Record address ----------------------------------------------------------
jq --arg addr "$HELPER_ADDRESS" '. + {LMSRBuyExactHelper: $addr}' "$OUTPUT_PATH" > "${OUTPUT_PATH}.tmp"
mv "${OUTPUT_PATH}.tmp" "$OUTPUT_PATH"
echo "  Updated $OUTPUT_PATH"

# Forge-style broadcast file so run_migration.sh's tx-hash extractor finds it
if [[ -n "$TX_HASH" ]]; then
  BROADCAST_DIR="./broadcast/${MIGRATION_NAME}.sh/${CHAIN_ID}"
  mkdir -p "$BROADCAST_DIR"
  jq -n --arg hash "$TX_HASH" '{transactions: [{hash: $hash}]}' > "${BROADCAST_DIR}/run-latest.json"
fi

# --- Verify (optional) -------------------------------------------------------
if [[ -z "${ETHERSCAN_API_KEY:-}" ]]; then
  echo "  Skipping Etherscan verification (ETHERSCAN_API_KEY not set)"
  exit 0
fi

echo "  Submitting source to Etherscan for verification..."
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
  "$HELPER_ADDRESS" \
  "$HELPER_CONTRACT_PATH"

echo "  ✓ Verification submitted"
