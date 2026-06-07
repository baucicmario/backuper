#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

require_sudo

STATE_FILE="${STATE_FILE:-/tmp/immich_detected.env}"
[ -f "$STATE_FILE" ] || die "Detection state not found: $STATE_FILE"

# shellcheck source=/dev/null
source "$STATE_FILE"

: "${IMMICH_COMPOSE_FILE:?Missing IMMICH_COMPOSE_FILE in $STATE_FILE}"
: "${IMMICH_ENV_FILE:?Missing IMMICH_ENV_FILE in $STATE_FILE}"
: "${IMMICH_SERVICE:?Missing IMMICH_SERVICE in $STATE_FILE}"
: "${POSTGRES_SERVICE:?Missing POSTGRES_SERVICE in $STATE_FILE}"

BACKUP_ROOT="${BACKUP_ROOT:-$CENTRAL_BACKUP_DIR/immich_backups}"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
BACKUP_DIR="$BACKUP_ROOT/$RUN_ID"

mkdir -p "$BACKUP_DIR"
load_env "$IMMICH_ENV_FILE"

docker_ok() {
  docker info >/dev/null 2>&1
}

docker_run() {
  if docker_ok; then
    docker "$@"
  elif command -v sg >/dev/null 2>&1 && sg docker -c "docker info" >/dev/null 2>&1; then
    sg docker -c "docker $*"
  else
    $SUDO docker "$@"
  fi
}

compose_run() {
  if docker_ok; then
    docker compose "$@"
  elif command -v sg >/dev/null 2>&1 && sg docker -c "docker info" >/dev/null 2>&1; then
    sg docker -c "docker compose $*"
  else
    $SUDO docker compose "$@"
  fi
}

smart_copy() {
  local src="$1"
  local dst="$2"
  local stderr_file
  stderr_file="$(mktemp)"

  mkdir -p "$dst"

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

info "Step 1 — Postgres database dump"
db_dump="$BACKUP_DIR/immich_db.sql.gz"
db_log="$BACKUP_DIR/pg_dump.stderr.log"

container_id="$(compose_run -f "$IMMICH_COMPOSE_FILE" ps -q "$POSTGRES_SERVICE")"
[ -n "$container_id" ] || die "Could not resolve Postgres container id for service '$POSTGRES_SERVICE'"

info "Dumping from container $container_id (user: postgres)..."

DB_CANDIDATES=()
[ -n "${DB_DATABASE_NAME:-}" ] && DB_CANDIDATES+=("$DB_DATABASE_NAME")
[ -n "${POSTGRES_DB:-}" ] && DB_CANDIDATES+=("$POSTGRES_DB")
DB_CANDIDATES+=("immich" "postgres")

dump_ok=false
used_db=""

for db_name in "${DB_CANDIDATES[@]}"; do
  [ -n "$db_name" ] || continue
  : > "$db_log"

  if docker_run exec "$container_id" sh -lc \
    "PGPASSWORD=\"\$POSTGRES_PASSWORD\" pg_dump -U postgres --clean --if-exists --no-owner --no-privileges \"$db_name\"" \
    2>"$db_log" | gzip > "$db_dump"; then
    dump_ok=true
    used_db="$db_name"
    break
  fi

  rm -f "$db_dump"
done

if [ "$dump_ok" != true ]; then
  error "Database dump failed. See: $db_log"
  [ -s "$db_log" ] && sed 's/^/  /' "$db_log" >&2
  exit 1
fi

ok "Database dump saved: $db_dump  ($(du -h "$db_dump" | awk '{print $1}'))"
info "Database used: $used_db"

info "Step 2 — Copy upload library"

upload_src="${UPLOAD_LOCATION:-}"
if [ -z "$upload_src" ]; then
  upload_src="$(yq -r '.services["'"$IMMICH_SERVICE"'"].volumes[]? | select(type == "!!str")' "$IMMICH_COMPOSE_FILE" \
    | awk -F: '$1 ~ /^\// {print $1; exit}')"
fi

[ -n "$upload_src" ] || die "Could not determine upload source path."
[ -d "$upload_src" ] || die "Upload source path is not a directory: $upload_src"

upload_dst="$BACKUP_DIR/library"
info "Copying: $upload_src → $upload_dst"
smart_copy "$upload_src" "$upload_dst" || die "Failed to copy upload library"

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