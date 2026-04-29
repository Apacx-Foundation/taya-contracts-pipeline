#!/usr/bin/env bash
#
# Verify the BettingToken implementation deployed by
# 20260430-bettingtoken-role-manager.s.sol on the block explorer.
#
# Reads the impl address from the forge broadcast artefact produced by that
# migration (first CREATE transaction = the new impl). Safe to re-run if the
# first attempt timed out or the API was rate-limited.
#
# Invoked by script/cmd/run_migration.sh with args: <chain_id> <rpc_url> <private_key>
#
set -eo pipefail

CHAIN_ID="${1:?missing chain_id}"
RPC_URL="${2:?missing rpc_url}"   # unused — kept for run_migration.sh compat
PRIVATE_KEY="${3:?missing private_key}" # unused — kept for run_migration.sh compat

BROADCAST_FILE="./broadcast/20260430-bettingtoken-role-manager.s.sol/${CHAIN_ID}/run-latest.json"
CONTRACT_PATH="src/BettingToken.sol:BettingToken"

if [[ ! -f "$BROADCAST_FILE" ]]; then
  echo "ERROR: broadcast file not found: $BROADCAST_FILE"
  echo "  Run 20260430-bettingtoken-role-manager first."
  exit 1
fi

# First CREATE in the broadcast = the new BettingToken impl
IMPL_ADDRESS=$(jq -r '[.transactions[] | select(.transactionType == "CREATE")] | first | .contractAddress' "$BROADCAST_FILE")

if [[ -z "$IMPL_ADDRESS" || "$IMPL_ADDRESS" == "null" || "$IMPL_ADDRESS" != 0x* ]]; then
  echo "ERROR: could not parse impl address from $BROADCAST_FILE"
  exit 1
fi

echo "  BettingToken impl: $IMPL_ADDRESS"

if [[ -z "${ETHERSCAN_API_KEY:-}" ]]; then
  echo "  Skipping verification (ETHERSCAN_API_KEY not set)"
  exit 0
fi

echo "  Submitting source to block explorer for verification..."
forge verify-contract \
  --chain-id "$CHAIN_ID" \
  --compiler-version "0.8.15" \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  --num-of-optimizations 1000000 \
  --watch \
  "$IMPL_ADDRESS" \
  "$CONTRACT_PATH"

echo "  Verified: $IMPL_ADDRESS"
