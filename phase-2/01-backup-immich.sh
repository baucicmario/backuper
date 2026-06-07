#!/usr/bin/env bash
# phase-2/01-backup-immich.sh
# Stops Immich, dumps the Postgres database, restarts Immich.
# Usage: ./01-backup-immich.sh [state_file]
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

STATE_FILE="${1:-/tmp/immich_detected.env}"

[ -f "$STATE_FILE" ] \
  || die "State file not found: $STATE_FILE. Run 00-detect-immich.sh first."

# ── Load state ────────────────────────────
source "$STATE_FILE"

# ── Config ────────────────────────────────
SPLIT_DIR="$(dirname "$ORIGINAL_COMPOSE")/split_composers"
TARGET_DIR="$SPLIT_DIR/immich"
mkdir -p "$TARGET_DIR"

TIMESTAMP="$(date +"%Y%m%d-%H%M%S")"
BACKUP_FILE="$TARGET_DIR/immich-db-$TIMESTAMP.sql.gz"

# ── Pre-flight checks ─────────────────────
require_cmd yq
require_cmd docker

# ── Load env (for DB creds) ───────────────
load_env "$(dirname "$ORIGINAL_COMPOSE")/.env"

# ── Read DB settings from compose ─────────
DB_NAME="$(yq -r ".services.\"$POSTGRES_SERVICE\".environment.POSTGRES_DB // \"immich\"" "$ORIGINAL_COMPOSE")"
DB_USER="$(yq -r ".services.\"$POSTGRES_SERVICE\".environment.POSTGRES_USER // \"postgres\"" "$ORIGINAL_COMPOSE")"

# Expand any env var references (e.g. ${POSTGRES_DB})
DB_NAME="$(eval echo "$DB_NAME")"
DB_USER="$(eval echo "$DB_USER")"

info "Database: $DB_NAME"
info "User:     $DB_USER"
line

# ── Cleanup trap — always restart Immich ──
cleanup() {
  info "Restarting Immich ($IMMICH_SERVICE)..."
  docker compose -f "$ORIGINAL_COMPOSE" start "$IMMICH_SERVICE" >/dev/null 2>&1 || true
  ok "Immich restarted."
}
trap cleanup EXIT

# ── Stop Immich ───────────────────────────
info "Stopping Immich: $IMMICH_SERVICE"
docker compose -f "$ORIGINAL_COMPOSE" stop "$IMMICH_SERVICE"
sleep 5

# ── Dump database ─────────────────────────
info "Creating backup: $BACKUP_FILE"

docker compose -f "$ORIGINAL_COMPOSE" exec -T "$POSTGRES_SERVICE" \
  pg_dump \
  --clean \
  --if-exists \
  --dbname="$DB_NAME" \
  --username="$DB_USER" \
| gzip > "$BACKUP_FILE"

ok "Backup created: $BACKUP_FILE"