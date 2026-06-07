#!/usr/bin/env bash

set -Eeuo pipefail

STATE_FILE="${1:-/tmp/immich_detected.env}"

if [ ! -f "$STATE_FILE" ]; then
    echo "Missing state file"
    exit 1
fi

# =========================================
# LOAD STATE
# =========================================

source "$STATE_FILE"

SPLIT_DIR="./split_composers"

TARGET_DIR="$SPLIT_DIR/immich"
mkdir -p "$TARGET_DIR"

TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
BACKUP_FILE="$TARGET_DIR/immich-db-$TIMESTAMP.sql.gz"

# =========================================
# LOAD ENV (for DB creds)
# =========================================

if [ -f ./.env ]; then
    set -a
    source ./.env
    set +a
fi

# =========================================
# GET DB SETTINGS
# =========================================

DB_NAME=$(yq -r \
".services.\"$POSTGRES_SERVICE\".environment.POSTGRES_DB // \"immich\"" \
"$ORIGINAL_COMPOSE")

DB_USER=$(yq -r \
".services.\"$POSTGRES_SERVICE\".environment.POSTGRES_USER // \"postgres\"" \
"$ORIGINAL_COMPOSE")

DB_NAME=$(eval echo "$DB_NAME")
DB_USER=$(eval echo "$DB_USER")

echo "DB: $DB_NAME"
echo "USER: $DB_USER"

# =========================================
# CLEAN EXIT SAFETY (always restart Immich)
# =========================================

cleanup() {
    echo "Restarting Immich..."
    docker compose -f "$ORIGINAL_COMPOSE" start "$IMMICH_SERVICE" >/dev/null 2>&1 || true
    echo "Immich restarted."
}

trap cleanup EXIT

# =========================================
# STOP IMMICH
# =========================================

echo "Stopping Immich: $IMMICH_SERVICE"

docker compose -f "$ORIGINAL_COMPOSE" stop "$IMMICH_SERVICE"

# wait until stopped
sleep 5

# =========================================
# BACKUP DATABASE
# =========================================

echo "Creating backup..."

docker compose -f "$ORIGINAL_COMPOSE" exec -T "$POSTGRES_SERVICE" \
    pg_dump \
    --clean \
    --if-exists \
    --dbname="$DB_NAME" \
    --username="$DB_USER" \
| gzip > "$BACKUP_FILE"

echo "Backup created: $BACKUP_FILE"