#!/usr/bin/env bash
#
# Deploy DelegatecallExecutor.
#
# Storage-free ERC-7579 executor module (default profile, solc 0.8.15) — no external
# library linkage required. Deploys via `forge create`, records address as
# `delegatecallExecutor` in script/output/<chainId>.json, then verifies on Etherscan
# if ETHERSCAN_API_KEY is set.
#
# Invoked by script/cmd/run_migration.sh with args: <chain_id> <rpc_url> <private_key>
#
set -eo pipefail

CHAIN_ID="${1:?missing chain_id}"
RPC_URL="${2:?missing rpc_url}"
PRIVATE_KEY="${3:?missing private_key}"

OUTPUT_PATH="./script/output/${CHAIN_ID}.json"
EXECUTOR_CONTRACT_PATH="src/DelegatecallExecutor.sol:DelegatecallExecutor"
MIGRATION_NAME="$(basename "$0" .sh)"

# --- Deploy ------------------------------------------------------------------
DEPLOY_LOG=$(mktemp)
trap 'rm -f "$DEPLOY_LOG"' EXIT

echo "  Deploying DelegatecallExecutor..."
forge create \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  "$EXECUTOR_CONTRACT_PATH" | tee "$DEPLOY_LOG"

EXECUTOR_ADDRESS=$(grep "Deployed to:" "$DEPLOY_LOG" | sed 's/.*Deployed to: //' | tr -d '[:space:]')
TX_HASH=$(grep "Transaction hash:" "$DEPLOY_LOG" | sed 's/.*Transaction hash: //' | tr -d '[:space:]')

if [[ -z "$EXECUTOR_ADDRESS" || "$EXECUTOR_ADDRESS" != 0x* ]]; then
  echo "ERROR: failed to parse deployed address from forge output"
  exit 1
fi
echo "  DelegatecallExecutor deployed at: $EXECUTOR_ADDRESS"

# --- Record address ----------------------------------------------------------
jq --arg addr "$EXECUTOR_ADDRESS" '. + {delegatecallExecutor: $addr}' "$OUTPUT_PATH" > "${OUTPUT_PATH}.tmp"
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
forge verify-contract \
  --chain-id "$CHAIN_ID" \
  --compiler-version "0.8.15" \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  --watch \
  "$EXECUTOR_ADDRESS" \
  --root "." \
  "$EXECUTOR_CONTRACT_PATH"

echo "  ✓ Verification submitted"
