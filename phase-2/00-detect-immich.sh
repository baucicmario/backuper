#!/usr/bin/env bash

set -euo pipefail

# =========================================
# CONFIG
# =========================================

ORIGINAL_COMPOSE="./docker-compose.yml"
STATE_FILE="/tmp/immich_detected.env"
BACKUP_SCRIPT="./01-immich-backup.sh"

# =========================================
# CHECK DEPENDENCIES
# =========================================

command -v yq >/dev/null 2>&1 || {
    echo "yq not found"
    exit 1
}

command -v docker >/dev/null 2>&1 || {
    echo "docker not found"
    exit 1
}

# =========================================
# LOAD ENV (optional)
# =========================================

if [ -f ./.env ]; then
    set -a
    source ./.env
    set +a
fi

# =========================================
# FIND IMMICH SERVICE
# =========================================

IMMICH_SERVICE=""
POSTGRES_SERVICE=""

while read -r svc; do
    image=$(yq -r ".services.\"$svc\".image // \"\"" "$ORIGINAL_COMPOSE")

    if echo "$image" | grep -qi "immich-server"; then
        IMMICH_SERVICE="$svc"
    fi

    if echo "$image" | grep -Eqi "postgres|pgvecto|pgvector"; then
        POSTGRES_SERVICE="$svc"
    fi

done < <(yq '.services | keys | .[]' "$ORIGINAL_COMPOSE")

# =========================================
# VALIDATE
# =========================================

if [ -z "$IMMICH_SERVICE" ]; then
    echo "No Immich detected"
    exit 0
fi

if [ -z "$POSTGRES_SERVICE" ]; then
    echo "No Postgres detected"
    exit 1
fi

echo "Immich detected: $IMMICH_SERVICE"
echo "Postgres detected: $POSTGRES_SERVICE"

# =========================================
# WRITE STATE FILE
# =========================================

cat > "$STATE_FILE" <<EOF
ORIGINAL_COMPOSE=$ORIGINAL_COMPOSE
IMMICH_SERVICE=$IMMICH_SERVICE
POSTGRES_SERVICE=$POSTGRES_SERVICE
EOF

echo "State saved to $STATE_FILE"

# =========================================
# AUTO-RUN BACKUP
# =========================================

echo "Triggering backup..."

bash "$BACKUP_SCRIPT" "$STATE_FILE"