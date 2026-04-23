#!/usr/bin/env bash
#
# Usage: ./script/cmd/run_migration.sh <chain_id> [migration_name]
#
#   chain_id        — 137 (polygon) or 11155111 (sepolia)
#   migration_name  — optional, run only this migration (e.g. "20260331-migrate-admin")
#                     if omitted, runs all pending migrations in order
#
# Migration scripts live in script/migrations/<name>.{s.sol,sh}:
#   - *.s.sol  → invoked via `forge script` (broadcast via --broadcast flag)
#   - *.sh     → invoked via `bash <file> <chain_id> <rpc_url> <private_key>`
#                Bash migrations are responsible for their own broadcasting (e.g. `forge
#                create --broadcast`). If they want tx-hash tracking in history, they can
#                write a forge-style run-latest.json to ./broadcast/<name>.sh/<chain_id>/.
#
# Execution history is tracked in script/migrations/history/<chain_id>.json
#
set -eo pipefail

CHAIN_ID="${1:?Usage: run_migration.sh <chain_id> [migration_name]}"
MIGRATION_NAME="${2:-}"

MIGRATIONS_DIR="./script/migrations"
HISTORY_FILE="${MIGRATIONS_DIR}/history/${CHAIN_ID}.json"

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

# Resolve a migration name to its on-disk script path and "kind" ("sol" or "sh").
# Echoes `<kind>\t<path>` on success; returns non-zero if not found.
resolve_migration() {
  local name="$1"
  if [[ -f "${MIGRATIONS_DIR}/${name}.s.sol" ]]; then
    echo -e "sol\t${MIGRATIONS_DIR}/${name}.s.sol"
    return 0
  fi
  if [[ -f "${MIGRATIONS_DIR}/${name}.sh" ]]; then
    echo -e "sh\t${MIGRATIONS_DIR}/${name}.sh"
    return 0
  fi
  return 1
}

# Get list of already-executed migrations
executed=$(jq -r '.migrations[].name' "$HISTORY_FILE")

# Collect migration scripts to run
if [[ -n "$MIGRATION_NAME" ]]; then
  # Single migration mode
  if ! resolve_migration "$MIGRATION_NAME" > /dev/null; then
    echo "ERROR: Migration not found: ${MIGRATIONS_DIR}/${MIGRATION_NAME}.{s.sol,sh}"
    exit 1
  fi
  if echo "$executed" | grep -qx "$MIGRATION_NAME"; then
    echo "Migration '$MIGRATION_NAME' already executed on chain $CHAIN_ID"
    echo "  To re-run, remove its entry from $HISTORY_FILE"
    exit 0
  fi
  pending=("$MIGRATION_NAME")
else
  # All pending migrations (both .s.sol and .sh; sorted by filename = timestamp order)
  candidate_names=()
  for f in "$MIGRATIONS_DIR"/*.s.sol "$MIGRATIONS_DIR"/*.sh; do
    [[ -f "$f" ]] || continue
    base=$(basename "$f")
    name="${base%.s.sol}"
    name="${name%.sh}"
    candidate_names+=("$name")
  done

  # Dedupe + sort (bash 3 compatible — no mapfile)
  pending=()
  if [[ ${#candidate_names[@]} -gt 0 ]]; then
    sorted_names=$(printf '%s\n' "${candidate_names[@]}" | sort -u)
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      if ! echo "$executed" | grep -qx "$name"; then
        pending+=("$name")
      fi
    done <<< "$sorted_names"
  fi
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
  read -r kind script_file <<<"$(resolve_migration "$name")"
  echo "--- Running: $name ($kind) ---"

  case "$kind" in
    sol)
      forge script "$script_file" \
        --rpc-url "$RPC_URL" \
        --broadcast \
        --private-key "$PRIVATE_KEY"
      broadcast_file="./broadcast/${name}.s.sol/${CHAIN_ID}/run-latest.json"
      ;;
    sh)
      bash "$script_file" "$CHAIN_ID" "$RPC_URL" "$PRIVATE_KEY"
      broadcast_file="./broadcast/${name}.sh/${CHAIN_ID}/run-latest.json"
      ;;
  esac

  # Extract tx hashes if the migration produced a forge-style broadcast file
  tx_hashes="[]"
  if [[ -f "$broadcast_file" ]]; then
    tx_hashes=$(jq '[.transactions[].hash // empty]' "$broadcast_file")
    echo "  Tx hashes:"
    echo "$tx_hashes" | jq -r '.[] | "    " + .'
  else
    echo "  (no broadcast file at $broadcast_file — tx hashes not recorded)"
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
