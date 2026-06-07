#!/usr/bin/env bash
# phase-2/00-detect-immich.sh
# Detects Immich and Postgres services in a compose file,
# writes a state file, then triggers the backup script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

# ── Config ────────────────────────────────
ORIGINAL_COMPOSE="${1:-./docker-compose.yml}"
STATE_FILE="/tmp/immich_detected.env"
BACKUP_SCRIPT="$SCRIPT_DIR/01-backup-immich.sh"

# ── Pre-flight checks ─────────────────────
require_cmd yq
require_cmd docker

[ -f "$ORIGINAL_COMPOSE" ] \
  || die "Compose file not found: $ORIGINAL_COMPOSE"

[ -f "$BACKUP_SCRIPT" ] \
  || die "Backup script not found: $BACKUP_SCRIPT"

# ── Load env (optional) ───────────────────
load_env "$(dirname "$ORIGINAL_COMPOSE")/.env"

# ── Find Immich + Postgres services ───────
IMMICH_SERVICE=""
POSTGRES_SERVICE=""

while read -r svc; do
  image="$(yq -r ".services.\"$svc\".image // \"\"" "$ORIGINAL_COMPOSE")"

  if echo "$image" | grep -qi "immich-server"; then
    IMMICH_SERVICE="$svc"
  fi

  if echo "$image" | grep -Eqi "postgres|pgvecto|pgvector"; then
    POSTGRES_SERVICE="$svc"
  fi

done < <(yq '.services | keys | .[]' "$ORIGINAL_COMPOSE")

# ── Validate findings ─────────────────────
if [ -z "$IMMICH_SERVICE" ]; then
  info "No Immich service detected in $ORIGINAL_COMPOSE — nothing to do."
  exit 0
fi

[ -n "$POSTGRES_SERVICE" ] \
  || die "Immich detected but no Postgres service found. Cannot proceed."

ok "Immich detected:   $IMMICH_SERVICE"
ok "Postgres detected: $POSTGRES_SERVICE"

# ── Write state file ──────────────────────
cat > "$STATE_FILE" <<EOF
ORIGINAL_COMPOSE=$ORIGINAL_COMPOSE
IMMICH_SERVICE=$IMMICH_SERVICE
POSTGRES_SERVICE=$POSTGRES_SERVICE
EOF

ok "State saved to $STATE_FILE"

# ── Trigger backup ────────────────────────
info "Triggering backup..."
bash "$BACKUP_SCRIPT" "$STATE_FILE"