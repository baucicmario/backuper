#!/usr/bin/env bash
# tasks/02-backup-database.sh
# Run pg_dump inside the Postgres container and write a compressed SQL file.
#
# Inputs (env, all set by orchestrator):
#   STATE_FILE      — path to the state file written by 01-detect-immich.sh
#   BACKUP_ROOT     — root backup directory
#   RUN_ID          — timestamped run identifier (subfolder name)
#
# Outputs:
#   $BACKUP_ROOT/$RUN_ID/immich_db.sql.gz   — compressed database dump
#   $BACKUP_ROOT/$RUN_ID/pg_dump.stderr.log — pg_dump stderr (kept on failure)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

require_sudo

# ── Source state ──────────────────────────────────────────────────────────────
STATE_FILE="${STATE_FILE:?STATE_FILE must be set by the orchestrator}"
[[ -f "$STATE_FILE" ]] || die "Detection state not found: $STATE_FILE — run 01-detect-immich.sh first"
# shellcheck source=/dev/null
source "$STATE_FILE"

: "${IMMICH_COMPOSE_FILE:?Missing IMMICH_COMPOSE_FILE in state file}"
: "${IMMICH_ENV_FILE:?Missing IMMICH_ENV_FILE in state file}"
: "${POSTGRES_SERVICE:?Missing POSTGRES_SERVICE in state file}"

BACKUP_ROOT="${BACKUP_ROOT:?BACKUP_ROOT must be set by the orchestrator}"
RUN_ID="${RUN_ID:?RUN_ID must be set by the orchestrator}"
BACKUP_DIR="$CENTRAL_BACKUP_DIR/split_stacks/immich__${POSTGRES_SERVICE}"
[[ -d "$BACKUP_DIR" ]] || die "Phase 1 output not found: $BACKUP_DIR — run phase1.sh first"

load_env "$IMMICH_ENV_FILE"

# ── Docker helpers ────────────────────────────────────────────────────────────
docker_ok()    { docker info >/dev/null 2>&1; }
docker_run()   { docker_ok && docker "$@"         || $SUDO docker "$@"; }
compose_run()  { docker_ok && docker compose "$@" || $SUDO docker compose "$@"; }

# ── Resolve container id ──────────────────────────────────────────────────────
bold "🗄  Database Backup"
line
info "  Compose  : $IMMICH_COMPOSE_FILE"
info "  Service  : $POSTGRES_SERVICE"
info "  Target   : $BACKUP_DIR"
line

container_id="$(compose_run -f "$IMMICH_COMPOSE_FILE" ps -q "$POSTGRES_SERVICE" 2>/dev/null || true)"
[[ -n "$container_id" ]] || die \
  "Could not resolve container ID for service '$POSTGRES_SERVICE'. " \
  "Is the Immich stack running?"

info "Postgres container: $container_id"

# ── Build candidate database names ───────────────────────────────────────────
DB_CANDIDATES=()
[[ -n "${DB_DATABASE_NAME:-}" ]] && DB_CANDIDATES+=("$DB_DATABASE_NAME")
[[ -n "${POSTGRES_DB:-}"       ]] && DB_CANDIDATES+=("$POSTGRES_DB")
DB_CANDIDATES+=("immich" "postgres")

db_dump="$BACKUP_DIR/immich_db.sql.gz"
db_log="$BACKUP_DIR/pg_dump.stderr.log"
dump_ok=false
used_db=""

# ── Attempt dump with each candidate db name ─────────────────────────────────
for db_name in "${DB_CANDIDATES[@]}"; do
  [[ -n "$db_name" ]] || continue
  : > "$db_log"
  info "Trying database name: $db_name"

  if docker_run exec "$container_id" sh -lc \
    "PGPASSWORD=\"\$POSTGRES_PASSWORD\" pg_dump -U postgres --clean --if-exists --no-owner --no-privileges \"$db_name\"" \
    2>"$db_log" | gzip > "$db_dump"; then
    dump_ok=true
    used_db="$db_name"
    break
  fi

  rm -f "$db_dump"
done

if [[ "$dump_ok" != true ]]; then
  error "Database dump failed for all candidate names: ${DB_CANDIDATES[*]}"
  [[ -s "$db_log" ]] && sed 's/^/  /' "$db_log" >&2
  exit 1
fi

dump_size="$(du -h "$db_dump" | awk '{print $1}')"
ok "Database dump saved: $db_dump  ($dump_size)"
info "Database name used: $used_db"

# ── Export for downstream tasks ───────────────────────────────────────────────
# Append to state file so 04-write-manifest.sh can read them
{
  printf 'BACKUP_DIR=%q\n'      "$BACKUP_DIR"
  printf 'DATABASE_USED=%q\n'   "$used_db"
  printf 'DB_DUMP_FILE=%q\n'    "$db_dump"
  printf 'DB_DUMP_SIZE=%q\n'    "$dump_size"
} >> "$STATE_FILE"
