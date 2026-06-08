#!/usr/bin/env bash
# phase-2/tasks/05-write-restore.sh
# Generate the master Immich restore.sh inside the consolidated immich/ folder.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

# shellcheck source=/dev/null
source "$STATE_FILE"

IMMICH_SERVICE="${IMMICH_SERVICE:?}"
POSTGRES_SERVICE="${POSTGRES_SERVICE:?}"
IMMICH_COMPOSE_FILE="${IMMICH_COMPOSE_FILE:?Missing IMMICH_COMPOSE_FILE in state file}"
IMMICH_ENV_FILE="${IMMICH_ENV_FILE:?Missing IMMICH_ENV_FILE in state file}"
DOCKGE_STACKS_DIR="${DOCKGE_STACKS_DIR:-/opt/stacks}"

IMMICH_OUT_NAME="${IMMICH_OUT_NAME:-immich}"

# ── Post-consolidation paths (not the pre-move BACKUPDIR from state) ──────────
CONSOLIDATED_DIR="$CENTRAL_BACKUP_DIR/split_stacks/$IMMICH_OUT_NAME"
DB_SERVICE_DIR="$CONSOLIDATED_DIR/$POSTGRES_SERVICE"
DBDUMPFILE="$DB_SERVICE_DIR/immich_db.sql.gz"

[[ -d "$CONSOLIDATED_DIR" ]] || die "Consolidated dir not found: $CONSOLIDATED_DIR — run 04-consolidate.sh first"
[[ -f "$DBDUMPFILE" ]]       || die "Database dump not found: $DBDUMPFILE — run 02-backup-database.sh first"

RESTORE_SCRIPT="$CONSOLIDATED_DIR/restore.sh"

bold "✍  Writing Immich master restore.sh"
line

# ── Collect per-service restore.sh scripts Phase 1 generated (now inside immich/) ──
mapfile -t SERVICE_RESTORE_SCRIPTS < <(
  find "$CONSOLIDATED_DIR" -mindepth 2 -maxdepth 2 -name restore.sh | sort
)

SERVICE_RESTORE_LINES=""
for s in "${SERVICE_RESTORE_SCRIPTS[@]}"; do
  rel="${s#"$CONSOLIDATED_DIR"/}"
  SERVICE_RESTORE_LINES+="  run_restore \"\$DIR/$rel\""$'\n'
done

# Baked-in values set at backup time
BACKED_UP_AT="${BACKED_UP_AT:-unknown}"

cat > "$RESTORE_SCRIPT" << RESTOREEOF
#!/usr/bin/env bash
# Immich Full Restore
# Baked-in values — set at backup time
set -euo pipefail

SELF_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
$(printf 'RED=\033[31m; GREEN=\033[32m; YELLOW=\033[33m; BLUE=\033[36m; BOLD=\033[1m; RESET=\033[0m')
line()  { echo -e "\${BLUE}------------------------------------------------------------\${RESET}"; }
info()  { echo -e "\${BLUE}  \$*\${RESET}"; }
ok()    { echo -e "\${GREEN}✅ \$*\${RESET}"; }
warn()  { echo -e "\${YELLOW}⚠️  \$*\${RESET}"; }
die()   { echo -e "\${RED}❌ \$*\${RESET}" >&2; exit 1; }
bold()  { echo -e "\${BOLD}\$*\${RESET}"; }

DOCKGE_STACKS_DIR="${DOCKGE_STACKS_DIR}"
STACK_DIR="\$DOCKGE_STACKS_DIR/immich"
STACK_COMPOSE="\$STACK_DIR/compose.yaml"
STACK_ENV="\$STACK_DIR/.env"
POSTGRES_SERVICE="${POSTGRES_SERVICE}"
IMMICH_SERVICE="${IMMICH_SERVICE}"
DIR="\$SELF_DIR"
DUMPFILE="\$DIR/${POSTGRES_SERVICE}/immich_db.sql.gz"
BACKED_UP_AT="${BACKED_UP_AT}"

bold "🔄 Immich Full Restore"
info "  Stack target  : \$STACK_DIR"
info "  DB dump       : \$DUMPFILE"
info "  Backed up at  : \$BACKED_UP_AT"
line

command -v docker >/dev/null 2>&1 || die "docker not found."
docker compose version >/dev/null 2>&1 || die "docker compose plugin not found."
[[ -f "\$DUMPFILE" ]] || die "Database dump not found: \$DUMPFILE"

SUDO=""
[[ "\$(id -u)" -ne 0 ]] && SUDO="sudo"

run_restore() {
  local script="\$1"
  if [[ -f "\$script" ]]; then
    info "  \$(basename "\$(dirname "\$script")")/restore.sh"
    bash "\$script" || warn "Non-zero exit from \$script — continuing"
  else
    warn "Not found, skipping: \$script"
  fi
}

NO_PULL=false
SKIP_SERVICE_RESTORES=false
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --no-pull)              NO_PULL=true ;;
    --skip-service-restores) SKIP_SERVICE_RESTORES=true ;;
    --help|-h)
      echo "Usage: sudo ./restore.sh [--no-pull] [--skip-service-restores]"
      echo "  --no-pull               Skip docker compose pull"
      echo "  --skip-service-restores Skip Phase-1 sub-restores if /opt/stacks/immich already rebuilt"
      exit 0 ;;
    *) die "Unknown flag: \$1" ;;
  esac
  shift
done

# ── STEP 1: Restore service compose files and data ───────────────────────────
if [[ "\$SKIP_SERVICE_RESTORES" == true ]]; then
  warn "Skipping service restores (--skip-service-restores)"
else
  bold "STEP 1 — Restoring service compose files and data"
  line
${SERVICE_RESTORE_LINES}
  ok "All service restores complete."
  line
fi

[[ -f "\$STACK_COMPOSE" ]] || die "compose.yaml missing after service restores: \$STACK_COMPOSE"
[[ -f "\$STACK_ENV" ]]     || die ".env missing after service restores: \$STACK_ENV"

# ── STEP 2: Pull latest images ────────────────────────────────────────────────
if [[ "\$NO_PULL" == false ]]; then
  bold "STEP 2 — Pulling latest Immich images"
  line
  docker compose -f "\$STACK_COMPOSE" --env-file "\$STACK_ENV" pull
  ok "Images pulled."
  line
else
  info "Skipping image pull (--no-pull)"
fi

# ── STEP 3: Create containers (not started yet) ───────────────────────────────
bold "STEP 3 — Creating containers (not starting yet)"
line
warn "If Immich has already run since containers were last created, the DB restore"
warn "will fail with Postgres conflicts. Fix: find DB_DATA_LOCATION in \$STACK_ENV,"
warn "run: sudo rm -rf \$DB_DATA_LOCATION, then re-run this script."
line
docker compose -f "\$STACK_COMPOSE" --env-file "\$STACK_ENV" down -v 2>/dev/null || true
docker compose -f "\$STACK_COMPOSE" --env-file "\$STACK_ENV" create
ok "Containers created."
line

# ── STEP 4: Start Postgres and wait ──────────────────────────────────────────
bold "STEP 4 — Starting Postgres and waiting for it to be ready"
line
docker compose -f "\$STACK_COMPOSE" --env-file "\$STACK_ENV" start "\$POSTGRES_SERVICE"
container_id=\$(docker compose -f "\$STACK_COMPOSE" --env-file "\$STACK_ENV" ps -q "\$POSTGRES_SERVICE")
[[ -n "\$container_id" ]] || die "Could not find Postgres container after start."
info "Waiting for Postgres to accept connections..."
for i in \$(seq 1 30); do
  if docker exec "\$container_id" pg_isready -U postgres >/dev/null 2>&1; then
    ok "Postgres is ready (attempt \$i)."
    break
  fi
  [[ "\$i" -eq 30 ]] && die "Postgres did not become ready after 30 seconds."
  sleep 1
done
line

# ── STEP 5: Restore database ──────────────────────────────────────────────────
bold "STEP 5 — Restoring database from pg_dump"
line
info "  Source : \$DUMPFILE"
info "  Method : gunzip | sed (search_path fix) | psql --single-transaction"
line

db_name="immich"
ENV="\$STACK_ENV"
if [[ -f "\$ENV" ]]; then
  db=\$(grep -E '^(DB_DATABASE_NAME|POSTGRES_DB)=' "\$ENV" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"' || true)
  [[ -n "\$db" ]] && db_name="\$db"
fi
info "  Database name: \$db_name"

gunzip --stdout "\$DUMPFILE" \
  | sed 's/SELECT pg_catalog.set_config('\''search_path'\'', '\'''\''.*'\'', false)/SELECT pg_catalog.set_config('\''search_path'\'', '\''public, pg_catalog'\'', true)/g' \
  | docker exec -i "\$container_id" psql --dbname="\$db_name" --username=postgres \
      --single-transaction --set ON_ERROR_STOP=on
ok "Database restored."
line

# ── STEP 6: Start full stack ──────────────────────────────────────────────────
bold "STEP 6 — Starting full Immich stack"
line
docker compose -f "\$STACK_COMPOSE" --env-file "\$STACK_ENV" up -d
ok "Immich stack is up."
line

bold "🎉 Immich restore complete!"
echo
info "Next steps:"
info "  1. Open Immich in your browser and verify your library is intact"
info "  2. Missing thumbnails?        Jobs → Generate Thumbnails"
info "  3. Missing transcoded videos? Jobs → Video Transcoding"
echo
RESTOREEOF

chmod +x "$RESTORE_SCRIPT"
ok "Master restore.sh written: $RESTORE_SCRIPT"
info "  Baked values:"
info "    POSTGRES_SERVICE : $POSTGRES_SERVICE"
info "    IMMICH_SERVICE   : $IMMICH_SERVICE"
info "    DOCKGE_STACKS_DIR: $DOCKGE_STACKS_DIR"
info "    DB dump expected : $DB_SERVICE_DIR/immich_db.sql.gz"
info "  Embedded service restores:"
for s in "${SERVICE_RESTORE_SCRIPTS[@]}"; do
  info "    ${s#"$CONSOLIDATED_DIR"/}"
done