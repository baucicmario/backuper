#!/usr/bin/env bash
# phase-2/01-backup-immich.sh — Backup Immich database and library
# Performs a PostgreSQL dump and copies the upload library directory.
# Results are saved to dated backup folders in BACKUP_ROOT.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

# Require sudo for Docker access
require_sudo

# ── Load detection state from phase 00 ──────────────────────────────────────
STATE_FILE="${STATE_FILE:-/tmp/immich_detected.env}"
[ -f "$STATE_FILE" ] || die "Detection state not found: $STATE_FILE"

# Load variables from detection state
# shellcheck source=/dev/null
source "$STATE_FILE"

# ── Validate all required variables are present ────────────────────────────
: "${IMMICH_COMPOSE_FILE:?Missing IMMICH_COMPOSE_FILE in $STATE_FILE}"
: "${IMMICH_ENV_FILE:?Missing IMMICH_ENV_FILE in $STATE_FILE}"
: "${IMMICH_SERVICE:?Missing IMMICH_SERVICE in $STATE_FILE}"
: "${POSTGRES_SERVICE:?Missing POSTGRES_SERVICE in $STATE_FILE}"

# ── Setup backup directories ──────────────────────────────────────────────
BACKUP_ROOT="${BACKUP_ROOT:-$CENTRAL_BACKUP_DIR/immich_backups}"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"  # Timestamp-based backup ID
BACKUP_DIR="$BACKUP_ROOT/$RUN_ID"

mkdir -p "$BACKUP_DIR"
# Load Immich environment variables (may contain POSTGRES_PASSWORD, etc.)
load_env "$IMMICH_ENV_FILE"

# ── Helper: check if docker is accessible without sudo ─────────────────────
docker_ok() {
  docker info >/dev/null 2>&1
}

# ── Helper: run docker, with fallback to docker group or sudo ───────────────
docker_run() {
  if docker_ok; then
    docker "$@"
  elif command -v sg >/dev/null 2>&1 && sg docker -c "docker info" >/dev/null 2>&1; then
    sg docker -c "docker $*"
  else
    $SUDO docker "$@"
  fi
}

# ── Helper: run docker compose, with fallback to docker group or sudo ─────
compose_run() {
  if docker_ok; then
    docker compose "$@"
  elif command -v sg >/dev/null 2>&1 && sg docker -c "docker info" >/dev/null 2>&1; then
    # sg (set group) allows running command as docker group without full sudo
    sg docker -c "docker compose $*"
  else
    $SUDO docker compose "$@"
  fi
}

# ── Helper: copy directory with fallback to cp for filesystems that don't support metadata ──
smart_copy() {
  local src="$1"
  local dst="$2"
  local stderr_file
  stderr_file="$(mktemp)"

  mkdir -p "$dst"

  # Try rsync first to preserve timestamps and hardlinks
  if rsync -rltD \
      --no-perms --no-owner --no-group \
      --omit-dir-times \
      "$src"/ "$dst"/ 2>"$stderr_file"; then
    rm -f "$stderr_file"
    return 0
  fi

  if grep -qE 'failed to set times|Operation not permitted|some files/attrs were not transferred' "$stderr_file"; then
    info "  (metadata not supported by destination filesystem — retrying without preserve)"
    rm -rf "$dst"
    mkdir -p "$dst"
    if cp -r "$src"/. "$dst" 2>"$stderr_file"; then
      ok "Copied to $dst (data only — metadata skipped)"
      rm -f "$stderr_file"
      return 0
    fi
  fi

  cat "$stderr_file" >&2
  rm -f "$stderr_file"
  return 1
}

# ── Show backup configuration ─────────────────────────────────────────────
bold "📦 Immich Backup"
line
info "  Immich compose  : $IMMICH_COMPOSE_FILE"
info "  Immich service  : $IMMICH_SERVICE"
info "  Postgres compose: $IMMICH_COMPOSE_FILE"
info "  Postgres service: $POSTGRES_SERVICE"
info "  Backup target   : $BACKUP_DIR"
line

info "Creating backup directory: $BACKUP_DIR"
mkdir -p "$BACKUP_DIR"

# ═══════════════════════════════════════════════════════════════════════════
# STEP 1 — Dump PostgreSQL database
# ═══════════════════════════════════════════════════════════════════════════
info "Step 1 — Postgres database dump"
db_dump="$BACKUP_DIR/immich_db.sql.gz"  # Output path for compressed dump
db_log="$BACKUP_DIR/pg_dump.stderr.log"  # Log errors during dump

# Get the running container ID for the Postgres service
container_id="$(compose_run -f "$IMMICH_COMPOSE_FILE" ps -q "$POSTGRES_SERVICE")"
[ -n "$container_id" ] || die "Could not resolve Postgres container id for service '$POSTGRES_SERVICE'"

info "Dumping from container $container_id (user: postgres)..."

# Try multiple database name candidates (different configs use different names)
DB_CANDIDATES=()
[ -n "${DB_DATABASE_NAME:-}" ] && DB_CANDIDATES+=("$DB_DATABASE_NAME")
[ -n "${POSTGRES_DB:-}" ] && DB_CANDIDATES+=("$POSTGRES_DB")
DB_CANDIDATES+=("immich" "postgres")  # Most common names

# Try each database name until one succeeds
dump_ok=false
used_db=""

for db_name in "${DB_CANDIDATES[@]}"; do
  [ -n "$db_name" ] || continue
  : > "$db_log"  # Clear error log for this attempt

  # Execute pg_dump inside the container with the POSTGRES_PASSWORD environment variable
  if docker_run exec "$container_id" sh -lc \
    "PGPASSWORD=\"\$POSTGRES_PASSWORD\" pg_dump -U postgres --clean --if-exists --no-owner --no-privileges \"$db_name\"" \
    2>"$db_log" | gzip > "$db_dump"; then
    dump_ok=true
    used_db="$db_name"
    break  # Success! Use this database
  fi

  rm -f "$db_dump"  # Clean up failed attempt
done

# Verify dump succeeded
if [ "$dump_ok" != true ]; then
  error "Database dump failed. See: $db_log"
  [ -s "$db_log" ] && sed 's/^/  /' "$db_log" >&2
  exit 1
fi

# Success!
ok "Database dump saved: $db_dump  ($(du -h "$db_dump" | awk '{print $1}'))"
info "Database used: $used_db"

# ═══════════════════════════════════════════════════════════════════════════
# STEP 2 — Copy Immich upload library
# ═══════════════════════════════════════════════════════════════════════════
info "Step 2 — Copy upload library"

# First check if UPLOAD_LOCATION is set in environment, otherwise find it in compose
upload_src="${UPLOAD_LOCATION:-}"
if [ -z "$upload_src" ]; then
  # Parse the Immich service volumes to find the upload directory (usually the first bind mount)
  upload_src="$(yq -r '.services["'"$IMMICH_SERVICE"'"].volumes[]? | select(type == "!!str")' "$IMMICH_COMPOSE_FILE" \
    | awk -F: '$1 ~ /^\// {print $1; exit}')"
fi

# Validate paths
[ -n "$upload_src" ] || die "Could not determine upload source path."
[ -d "$upload_src" ] || die "Upload source path is not a directory: $upload_src"

# Copy the library (use smart_copy to handle filesystem differences)
upload_dst="$BACKUP_DIR/library"
info "Copying: $upload_src → $upload_dst"
smart_copy "$upload_src" "$upload_dst" || die "Failed to copy upload library"

# ═══════════════════════════════════════════════════════════════════════════
# STEP 3 — Create manifest file for future reference
# ═══════════════════════════════════════════════════════════════════════════
info "Step 3 — Write manifest"
cat > "$BACKUP_DIR/manifest.env" <<EOF
RUN_ID=$RUN_ID
IMMICH_COMPOSE_FILE=$IMMICH_COMPOSE_FILE
IMMICH_ENV_FILE=$IMMICH_ENV_FILE
IMMICH_SERVICE=$IMMICH_SERVICE
POSTGRES_SERVICE=$POSTGRES_SERVICE
UPLOAD_SOURCE=$upload_src
BACKUP_DIR=$BACKUP_DIR
DATABASE_USED=$used_db
EOF

ok "Manifest saved: $BACKUP_DIR/manifest.env"
ok "Backup complete."