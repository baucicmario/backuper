#!/usr/bin/env bash
# phase-2/01-backup-immich.sh
# Backs up Immich data using the state written by 00-detect-immich.sh.
#
# What it does:
#   1. Loads the state file (ORIGINAL_COMPOSE, IMMICH_SERVICE,
#      POSTGRES_SERVICE, POSTGRES_COMPOSE)
#   2. Finds the upload/library volume path from the Immich compose file
#   3. Dumps the Postgres database with pg_dumpall
#   4. Copies the upload library from the host mount
#   5. Copies compose files + .env + .stack-meta
#   6. Writes a restore manifest
#
# Usage:
#   bash 01-backup-immich.sh [STATE_FILE]
#   STATE_FILE defaults to /tmp/immich_detected.env
#
# Env overrides (optional):
#   BACKUP_ROOT   — where to create the timestamped backup dir
#                   (default: <script-dir>/immich_backups)
#   PGUSER        — Postgres super-user inside the container (default: postgres)
#   PGDATABASE    — Postgres database to dump               (default: immich)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

# ── Args / state ──────────────────────────
STATE_FILE="${1:-/tmp/immich_detected.env}"

[ -f "$STATE_FILE" ] \
  || die "State file not found: $STATE_FILE  (run 00-detect-immich.sh first)"

# shellcheck source=/dev/null
source "$STATE_FILE"

: "${ORIGINAL_COMPOSE:?State file missing ORIGINAL_COMPOSE}"
: "${IMMICH_SERVICE:?State file missing IMMICH_SERVICE}"
: "${POSTGRES_SERVICE:?State file missing POSTGRES_SERVICE}"
POSTGRES_COMPOSE="${POSTGRES_COMPOSE:-$ORIGINAL_COMPOSE}"

# ── Config ────────────────────────────────
# Place the backup folder next to this script (phase-2/immich_backups/)
# so it is always on the same filesystem as the project.
BACKUP_ROOT="${BACKUP_ROOT:-$SCRIPT_DIR/immich_backups}"
PGUSER="${PGUSER:-postgres}"
PGDATABASE="${PGDATABASE:-immich}"
TIMESTAMP="$(date -u +"%Y%m%dT%H%M%SZ")"
BACKUP_DIR="$BACKUP_ROOT/$TIMESTAMP"

# ── Pre-flight ────────────────────────────
require_cmd yq
require_cmd docker

[ -f "$ORIGINAL_COMPOSE" ] \
  || die "Immich compose file not found: $ORIGINAL_COMPOSE"

[ -f "$POSTGRES_COMPOSE" ] \
  || die "Postgres compose file not found: $POSTGRES_COMPOSE"

# ── Helper: get container id for a service ────────────────────────────────────
container_id_for_service() {
  local compose_file="$1"
  local svc="$2"
  local project
  project="$(yq -r '.name // ""' "$compose_file" 2>/dev/null || true)"

  local cid
  if [ -n "$project" ]; then
    cid="$(docker compose -f "$compose_file" -p "$project" ps -q "$svc" 2>/dev/null | head -n1 || true)"
  else
    cid="$(docker compose -f "$compose_file" ps -q "$svc" 2>/dev/null | head -n1 || true)"
  fi
  echo "$cid"
}

bold "${GREEN}📦 Immich Backup${RESET}"
line
info "  Immich compose  : $ORIGINAL_COMPOSE"
info "  Immich service  : $IMMICH_SERVICE"
info "  Postgres compose: $POSTGRES_COMPOSE"
info "  Postgres service: $POSTGRES_SERVICE"
info "  Backup target   : $BACKUP_DIR"
line

# ── Locate the upload/library volume mount ────────────────────────────────────
load_env "$(dirname "$ORIGINAL_COMPOSE")/.env"

UPLOAD_HOST_PATH=""

while IFS= read -r vol_entry; do
  [ -z "$vol_entry" ] && continue
  host_part="$(echo "$vol_entry" | cut -d: -f1)"
  container_part="$(echo "$vol_entry" | cut -d: -f2)"
  if echo "$container_part" | grep -q "upload"; then
    UPLOAD_HOST_PATH="$(eval echo "$host_part")"
    break
  fi
done < <(yq -r ".services.\"${IMMICH_SERVICE}\".volumes[]" "$ORIGINAL_COMPOSE" 2>/dev/null || true)

if [ -z "$UPLOAD_HOST_PATH" ]; then
  IMMICH_CID="$(container_id_for_service "$ORIGINAL_COMPOSE" "$IMMICH_SERVICE")"
  if [ -n "$IMMICH_CID" ]; then
    UPLOAD_HOST_PATH="$(
      docker inspect "$IMMICH_CID" \
        --format '{{range .Mounts}}{{if contains .Destination "upload"}}{{.Source}}{{end}}{{end}}' \
        2>/dev/null | head -n1 || true
    )"
  fi
fi

if [ -z "$UPLOAD_HOST_PATH" ]; then
  warn "Could not automatically locate the Immich upload volume."
  warn "Set UPLOAD_HOST_PATH manually and re-run, or check the volumes in your compose file."
else
  info "Upload library host path: $UPLOAD_HOST_PATH"
fi

# ── Create backup directory ───────────────
info "Creating backup directory: $BACKUP_DIR"
mkdir -p "$BACKUP_DIR"

# ── Step 1: Postgres dump ─────────────────
line
bold "Step 1 — Postgres database dump"

POSTGRES_CID="$(container_id_for_service "$POSTGRES_COMPOSE" "$POSTGRES_SERVICE")"
[ -n "$POSTGRES_CID" ] \
  || die "Postgres container ($POSTGRES_SERVICE) is not running. Start the stack first."

DB_DUMP="$BACKUP_DIR/immich_db.sql.gz"
info "Dumping from container $POSTGRES_CID (user: $PGUSER)..."

docker exec "$POSTGRES_CID" pg_dumpall -U "$PGUSER" \
  | gzip > "$DB_DUMP"

ok "Database dump saved: $DB_DUMP  ($(du -sh "$DB_DUMP" | cut -f1))"

# ── Step 2: Copy upload library ───────────
line
bold "Step 2 — Copy upload library"

if [ -n "$UPLOAD_HOST_PATH" ] && [ -d "$UPLOAD_HOST_PATH" ]; then
  LIBRARY_DEST="$BACKUP_DIR/library"
  info "Copying: $UPLOAD_HOST_PATH → $LIBRARY_DEST"
  mkdir -p "$LIBRARY_DEST"

  if command -v rsync >/dev/null 2>&1; then
    rsync -a --info=progress2 "$UPLOAD_HOST_PATH/" "$LIBRARY_DEST/"
  else
    cp -a "$UPLOAD_HOST_PATH/." "$LIBRARY_DEST/"
  fi
  ok "Library copied: $LIBRARY_DEST  ($(du -sh "$LIBRARY_DEST" | cut -f1))"
else
  warn "Skipping library copy — upload host path not found or not a directory."
  warn "Manually copy your Immich upload volume to: $BACKUP_DIR/library"
fi

# ── Step 3: Copy compose configs ──────────
line
bold "Step 3 — Copy compose configuration"

cp "$ORIGINAL_COMPOSE" "$BACKUP_DIR/docker-compose.yml"
ok "Copied Immich compose → docker-compose.yml"

if [ "$POSTGRES_COMPOSE" != "$ORIGINAL_COMPOSE" ]; then
  cp "$POSTGRES_COMPOSE" "$BACKUP_DIR/docker-compose.database.yml"
  ok "Copied Postgres compose → docker-compose.database.yml"
fi

ENV_SRC="$(dirname "$ORIGINAL_COMPOSE")/.env"
if [ -f "$ENV_SRC" ]; then
  cp "$ENV_SRC" "$BACKUP_DIR/.env"
  ok "Copied .env"
else
  warn "No .env found alongside the Immich compose file — skipping."
fi

for meta_src in \
    "$(dirname "$ORIGINAL_COMPOSE")/.stack-meta" \
    "$(dirname "$POSTGRES_COMPOSE")/.stack-meta"; do
  [ -f "$meta_src" ] || continue
  dest_name=".stack-meta"
  [ "$meta_src" = "$(dirname "$POSTGRES_COMPOSE")/.stack-meta" ] \
    && [ "$POSTGRES_COMPOSE" != "$ORIGINAL_COMPOSE" ] \
    && dest_name=".stack-meta.database"
  cp "$meta_src" "$BACKUP_DIR/$dest_name"
  ok "Copied $(basename "$meta_src") → $dest_name"
done

# ── Step 4: Write restore manifest ────────
line
bold "Step 4 — Write restore manifest"

MANIFEST="$BACKUP_DIR/RESTORE.md"
IMMICH_IMAGE="$(yq -r ".services.\"${IMMICH_SERVICE}\".image // \"ghcr.io/immich-app/immich-server:release\"" "$ORIGINAL_COMPOSE")"
POSTGRES_IMAGE="$(yq -r ".services.\"${POSTGRES_SERVICE}\".image // \"tensorchord/pgvecto-rs:pg14-v0.2.0\"" "$POSTGRES_COMPOSE")"

cat > "$MANIFEST" <<RESTORE
# Immich Restore Guide
Generated: $(date -u)
Backup dir: $BACKUP_DIR

## Contents
| File | Description |
|---|---|
| \`docker-compose.yml\` | Immich service compose file |
| \`docker-compose.database.yml\` | Postgres compose file (only if split from Immich) |
| \`.env\` | Environment variables (if present) |
| \`.stack-meta\` | Phase-1 provenance metadata (if present) |
| \`immich_db.sql.gz\` | Full Postgres dump (pg_dumpall) |
| \`library/\` | Immich upload library (photos/videos) |

## Images at backup time
- Immich server : \`$IMMICH_IMAGE\`
- Postgres       : \`$POSTGRES_IMAGE\`

## Restore steps

### 1. Prepare the destination
Copy \`docker-compose.yml\` (and \`docker-compose.database.yml\` if present)
plus \`.env\` into your target stack directory, e.g. \`/opt/stacks/immich/\`.
Edit \`.env\` if volume paths differ on the new host.

### 2. Restore the upload library
\`\`\`bash
DEST="/your/new/upload/path"   # wherever your compose maps /usr/src/app/upload
rsync -a "${BACKUP_DIR}/library/" "\$DEST/"
\`\`\`

### 3. Start Postgres only
\`\`\`bash
cd /opt/stacks/immich
docker compose up -d $POSTGRES_SERVICE
sleep 10
\`\`\`

### 4. Restore the database
\`\`\`bash
docker compose exec $POSTGRES_SERVICE \
  psql -U $PGUSER -c "DROP DATABASE IF EXISTS $PGDATABASE;"
docker compose exec $POSTGRES_SERVICE \
  psql -U $PGUSER -c "CREATE DATABASE $PGDATABASE;"

zcat "${BACKUP_DIR}/immich_db.sql.gz" | \
  docker compose exec -T $POSTGRES_SERVICE psql -U $PGUSER
\`\`\`

### 5. Start all services
\`\`\`bash
docker compose up -d
\`\`\`

### 6. Verify
Open Immich in the browser and confirm your library is visible.
Run *Administration → Jobs → Regenerate Thumbnails* if previews are missing.

## Notes
- pg_dumpall dumps ALL databases + roles; the restore above replays everything.
- Immich versions must match between backup and restore; pin image tags in compose.
- If the database was split into a separate stack by phase-1, bring up
  \`docker-compose.database.yml\` first before the main compose.
RESTORE

ok "Restore manifest written: $MANIFEST"

# ── Summary ───────────────────────────────
echo
line
bold "${GREEN}🎉 Immich Backup Complete${RESET}"
info "  Location : $BACKUP_DIR"
info "  DB dump  : $DB_DUMP"
[ -d "${BACKUP_DIR}/library" ] \
  && info "  Library  : $BACKUP_DIR/library  ($(du -sh "$BACKUP_DIR/library" | cut -f1))" \
  || warn "  Library  : NOT backed up (upload path not resolved)"
info "  Manifest : $MANIFEST"
line
ok "Done. Total backup size: $(du -sh "$BACKUP_DIR" | cut -f1)"