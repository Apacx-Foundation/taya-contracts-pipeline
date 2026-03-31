#!/usr/bin/env bash
#
# Usage: ./script/cmd/run_migration.sh <chain_id> [migration_name]
#
#   chain_id        — 137 (polygon) or 11155111 (sepolia)
#   migration_name  — optional, run only this migration (e.g. "20260331-migrate-admin")
#                     if omitted, runs all pending migrations in order
#
# Migration scripts live in script/migrations/<name>.s.sol
# Execution history is tracked in script/migrations/history/<chain_id>.json
#
set -eo pipefail

CHAIN_ID="${1:?Usage: run_migration.sh <chain_id> [migration_name]}"
MIGRATION_NAME="${2:-}"

MIGRATIONS_DIR="./script/migrations"
HISTORY_FILE="${MIGRATIONS_DIR}/history/${CHAIN_ID}.json"
OUTPUT_PATH="./script/output/${CHAIN_ID}.json"

# RPC URL env var per chain
case "$CHAIN_ID" in
  137)       RPC_URL_VAR="POLYGON_RPC_URL" ;;
  11155111)  RPC_URL_VAR="SEPOLIA_RPC_URL" ;;
  *)
    echo "ERROR: Unknown chain ID: $CHAIN_ID"
    exit 1
    ;;
esac

# Load env
set -a
source .env.development
set +a

RPC_URL="${!RPC_URL_VAR}"
if [[ -z "$RPC_URL" ]]; then
  echo "ERROR: $RPC_URL_VAR is not set"
  exit 1
fi

if [[ -z "${PRIVATE_KEY:-}" ]]; then
  echo "ERROR: PRIVATE_KEY is not set"
  exit 1
fi

# Ensure history file exists
if [[ ! -f "$HISTORY_FILE" ]]; then
  mkdir -p "$(dirname "$HISTORY_FILE")"
  echo '{"migrations":[]}' > "$HISTORY_FILE"
fi

# Get list of already-executed migrations
executed=$(jq -r '.migrations[].name' "$HISTORY_FILE")

# Collect migration scripts to run
if [[ -n "$MIGRATION_NAME" ]]; then
  # Single migration mode
  script_file="${MIGRATIONS_DIR}/${MIGRATION_NAME}.s.sol"
  if [[ ! -f "$script_file" ]]; then
    echo "ERROR: Migration not found: $script_file"
    exit 1
  fi
  if echo "$executed" | grep -qx "$MIGRATION_NAME"; then
    echo "Migration '$MIGRATION_NAME' already executed on chain $CHAIN_ID"
    echo "  To re-run, remove its entry from $HISTORY_FILE"
    exit 0
  fi
  pending=("$MIGRATION_NAME")
else
  # All pending migrations (sorted by filename = timestamp order)
  pending=()
  for f in "$MIGRATIONS_DIR"/*.s.sol; do
    [[ -f "$f" ]] || continue
    name=$(basename "$f" .s.sol)
    if ! echo "$executed" | grep -qx "$name"; then
      pending+=("$name")
    fi
  done
fi

if [[ ${#pending[@]} -eq 0 ]]; then
  echo "No pending migrations for chain $CHAIN_ID"
  exit 0
fi

echo "=== Migrations to run on chain $CHAIN_ID ==="
for name in "${pending[@]}"; do
  echo "  - $name"
done
echo ""

# Build once before running migrations
forge build

for name in "${pending[@]}"; do
  script_file="${MIGRATIONS_DIR}/${name}.s.sol"
  echo "--- Running: $name ---"

  forge script "$script_file" \
    --rpc-url "$RPC_URL" \
    --broadcast \
    --private-key "$PRIVATE_KEY"

  # Extract tx hashes from forge broadcast receipts
  broadcast_file="./broadcast/${name}.s.sol/${CHAIN_ID}/run-latest.json"
  tx_hashes="[]"
  if [[ -f "$broadcast_file" ]]; then
    tx_hashes=$(jq '[.transactions[].hash // empty]' "$broadcast_file")
    echo "  Tx hashes:"
    echo "$tx_hashes" | jq -r '.[] | "    " + .'
  else
    echo "  WARNING: No broadcast file found at $broadcast_file"
  fi

  # Record in history
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  jq --arg name "$name" --arg ts "$timestamp" --arg chain "$CHAIN_ID" --argjson txs "$tx_hashes" \
    '.migrations += [{"name": $name, "chainId": $chain, "executedAt": $ts, "txHashes": $txs}]' \
    "$HISTORY_FILE" > "${HISTORY_FILE}.tmp" && mv "${HISTORY_FILE}.tmp" "$HISTORY_FILE"

  echo "  Recorded in $HISTORY_FILE"
  echo ""
done

echo "=== All migrations complete ==="
