#!/usr/bin/env bash
# phase-2/00-detect-immich.sh
# Detects Immich and Postgres services in a compose file,
# writes a state file, then triggers the backup script.
#
# Auto-discovery order (first match wins):
#   1. Explicit path passed as $1
#   2. IMMICH_COMPOSE env var
#   3. phase-1 split_stacks output — any folder whose name contains "immich"
#      that has a docker-compose.yml referencing immich-server
#   4. /opt/stacks/immich/compose.yaml  (live Dockge stack)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

# ── Config ────────────────────────────────
STATE_FILE="/tmp/immich_detected.env"
BACKUP_SCRIPT="$SCRIPT_DIR/01-backup-immich.sh"

# ── Pre-flight checks ─────────────────────
require_cmd yq
require_cmd docker

[ -f "$BACKUP_SCRIPT" ] \
  || die "Backup script not found: $BACKUP_SCRIPT"

# ── Locate the compose file ───────────────
ORIGINAL_COMPOSE=""

# 1. Explicit CLI argument
if [ -n "${1:-}" ]; then
  ORIGINAL_COMPOSE="$1"
  info "Using compose file from argument: $ORIGINAL_COMPOSE"

# 2. Env var override
elif [ -n "${IMMICH_COMPOSE:-}" ]; then
  ORIGINAL_COMPOSE="$IMMICH_COMPOSE"
  info "Using compose file from IMMICH_COMPOSE env: $ORIGINAL_COMPOSE"

# 3. Auto-discover from phase-1 split_stacks output
else
  SPLIT_DIR="$SCRIPT_DIR/../phase-1/split_stacks"
  if [ -d "$SPLIT_DIR" ]; then
    info "Scanning phase-1 split_stacks for Immich..."
    while IFS= read -r candidate; do
      if grep -qi "immich-server" "$candidate" 2>/dev/null; then
        ORIGINAL_COMPOSE="$(realpath "$candidate")"
        ok "Found Immich compose in split_stacks: $ORIGINAL_COMPOSE"
        break
      fi
    done < <(find "$SPLIT_DIR" -mindepth 2 -maxdepth 2 -name "docker-compose.yml" | sort)
  fi

  # 4. Fall back to live Dockge stack
  if [ -z "$ORIGINAL_COMPOSE" ]; then
    for candidate in \
        /opt/stacks/immich/compose.yaml \
        /opt/stacks/immich/docker-compose.yml; do
      if [ -f "$candidate" ]; then
        ORIGINAL_COMPOSE="$candidate"
        info "Falling back to live Dockge stack: $ORIGINAL_COMPOSE"
        break
      fi
    done
  fi
fi

[ -n "$ORIGINAL_COMPOSE" ] \
  || die "Could not find an Immich compose file. Pass the path as an argument or set IMMICH_COMPOSE."

[ -f "$ORIGINAL_COMPOSE" ] \
  || die "Compose file not found: $ORIGINAL_COMPOSE"

# ── Load env (optional) ───────────────────
load_env "$(dirname "$ORIGINAL_COMPOSE")/.env"

# ── Find Immich + Postgres services ───────
IMMICH_SERVICE=""
POSTGRES_SERVICE=""
POSTGRES_COMPOSE=""

while IFS= read -r svc; do
  image="$(yq -r ".services.\"$svc\".image // \"\"" "$ORIGINAL_COMPOSE")"

  if echo "$image" | grep -qi "immich-server"; then
    IMMICH_SERVICE="$svc"
  fi

  if echo "$image" | grep -Eqi "postgres|pgvecto|pgvector"; then
    POSTGRES_SERVICE="$svc"
    POSTGRES_COMPOSE="$ORIGINAL_COMPOSE"
  fi

done < <(yq '.services | keys | .[]' "$ORIGINAL_COMPOSE")

# ── Postgres may live in a sibling split-stack folder ─────────────────────────
if [ -z "$POSTGRES_SERVICE" ]; then
  warn "Postgres not found in $ORIGINAL_COMPOSE — searching sibling split_stacks..."
  SPLIT_DIR="$SCRIPT_DIR/../phase-1/split_stacks"
  if [ -d "$SPLIT_DIR" ]; then
    while IFS= read -r candidate; do
      [ "$candidate" = "$ORIGINAL_COMPOSE" ] && continue
      if grep -Eqi "postgres|pgvecto|pgvector" "$candidate" 2>/dev/null; then
        while IFS= read -r svc; do
          image="$(yq -r ".services.\"$svc\".image // \"\"" "$candidate")"
          if echo "$image" | grep -Eqi "postgres|pgvecto|pgvector"; then
            POSTGRES_SERVICE="$svc"
            POSTGRES_COMPOSE="$(realpath "$candidate")"
            break 2
          fi
        done < <(yq '.services | keys | .[]' "$candidate")
      fi
    done < <(find "$SPLIT_DIR" -mindepth 2 -maxdepth 2 -name "docker-compose.yml" | sort)
  fi
fi

# ── Validate findings ─────────────────────
if [ -z "$IMMICH_SERVICE" ]; then
  info "No Immich service detected in $ORIGINAL_COMPOSE — nothing to do."
  exit 0
fi

[ -n "$POSTGRES_SERVICE" ] \
  || die "Immich detected but no Postgres service found in any compose file. Cannot proceed."

ok "Immich detected:   $IMMICH_SERVICE  ($ORIGINAL_COMPOSE)"
ok "Postgres detected: $POSTGRES_SERVICE  ($POSTGRES_COMPOSE)"

# ── Write state file ──────────────────────
cat > "$STATE_FILE" <<ENVEOF
ORIGINAL_COMPOSE=$ORIGINAL_COMPOSE
IMMICH_SERVICE=$IMMICH_SERVICE
POSTGRES_SERVICE=$POSTGRES_SERVICE
POSTGRES_COMPOSE=$POSTGRES_COMPOSE
ENVEOF

ok "State saved to $STATE_FILE"