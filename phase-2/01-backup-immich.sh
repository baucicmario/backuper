#!/usr/bin/env bash
# phase-2/01-backup-immich.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

# ── Detect docker command (sudo if needed) ────────────────────────────────────
if docker info >/dev/null 2>&1; then
  DOCKER="docker"
else
  DOCKER="sudo docker"
fi

# ── Args / state ──────────────────────────
STATE_FILE="${1:-/tmp/immich_detected.env}"
[ -f "$STATE_FILE" ] || die "State file not found: $STATE_FILE  (run 00-detect-immich.sh first)"
# shellcheck source=/dev/null
source "$STATE_FILE"

: "${ORIGINAL_COMPOSE:?State file missing ORIGINAL_COMPOSE}"
: "${IMMICH_SERVICE:?State file missing IMMICH_SERVICE}"
: "${POSTGRES_SERVICE:?State file missing POSTGRES_SERVICE}"
POSTGRES_COMPOSE="${POSTGRES_COMPOSE:-$ORIGINAL_COMPOSE}"

# ── Config ────────────────────────────────
# AFTER — $BACKUP_ROOT set by phase2.sh takes priority; CENTRAL_BACKUP_DIR is second; local path is last resort
BACKUP_ROOT="${BACKUP_ROOT:-${CENTRAL_BACKUP_DIR:+$CENTRAL_BACKUP_DIR/immich_backups}}"
BACKUP_ROOT="${BACKUP_ROOT:-$SCRIPT_DIR/immich_backups}"
PGUSER="${PGUSER:-postgres}"
PGDATABASE="${PGDATABASE:-immich}"
TIMESTAMP="$(date -u +"%Y%m%dT%H%M%SZ")"
BACKUP_DIR="$BACKUP_ROOT/$TIMESTAMP"

# ── Pre-flight ────────────────────────────
require_cmd yq
require_cmd docker

[ -f "$ORIGINAL_COMPOSE" ] || die "Immich compose file not found: $ORIGINAL_COMPOSE"
[ -f "$POSTGRES_COMPOSE" ] || die "Postgres compose file not found: $POSTGRES_COMPOSE"

# ── Helper: get container id for a service ────────────────────────────────────
container_id_for_service() {
  local compose_file="$1"
  local svc="$2"
  local cid=""

  # Try 1: project name from compose file
  local project
  project="$(yq -r '.name // ""' "$compose_file" 2>/dev/null || true)"
  if [ -n "$project" ]; then
    cid="$($DOCKER compose -f "$compose_file" -p "$project" ps -q "$svc" 2>/dev/null | head -n1 || true)"
  fi

  # Try 2: infer project from directory name
  if [ -z "$cid" ]; then
    cid="$($DOCKER compose -f "$compose_file" ps -q "$svc" 2>/dev/null | head -n1 || true)"
  fi

  # Try 3: match by compose service label (works across project name mismatches)
  if [ -z "$cid" ]; then
    cid="$($DOCKER ps -q --filter "label=com.docker.compose.service=$svc" 2>/dev/null | head -n1 || true)"
  fi

  # Try 4: match by container_name field in compose file
  if [ -z "$cid" ]; then
    local container_name
    container_name="$(yq -r ".services.\"${svc}\".container_name // \"\"" "$compose_file" 2>/dev/null || true)"
    if [ -n "$container_name" ]; then
      cid="$($DOCKER ps -q --filter "name=^${container_name}$" 2>/dev/null | head -n1 || true)"
    fi
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

# Stage 1: bind-mount whose container path contains "upload"
while IFS= read -r vol_entry; do
  [ -z "$vol_entry" ] && continue
  host_part="$(echo "$vol_entry" | cut -d: -f1)"
  container_part="$(echo "$vol_entry" | cut -d: -f2)"
  if echo "$container_part" | grep -q "upload"; then
    expanded="$(eval echo "$host_part" 2>/dev/null || echo "$host_part")"
    if [[ "$expanded" == /* ]] || [[ "$expanded" == ./* ]] || [[ "$expanded" == ~* ]]; then
      UPLOAD_HOST_PATH="$(eval echo "$expanded")"
      info "Found upload bind-mount in compose: $UPLOAD_HOST_PATH"
      break
    fi
  fi
done < <(yq -r ".services.\"${IMMICH_SERVICE}\".volumes[]" "$ORIGINAL_COMPOSE" 2>/dev/null || true)

# Stage 2: named volume — inspect running container
if [ -z "$UPLOAD_HOST_PATH" ]; then
  info "Bind-mount not found — checking running container for named volume mount..."
  IMMICH_CID="$(container_id_for_service "$ORIGINAL_COMPOSE" "$IMMICH_SERVICE")"
  if [ -n "$IMMICH_CID" ]; then
    UPLOAD_HOST_PATH="$(
      $DOCKER inspect "$IMMICH_CID" \
        --format '{{range .Mounts}}{{if contains .Destination "upload"}}{{.Source}}{{end}}{{end}}' \
        2>/dev/null | head -n1 || true
    )"
    [ -n "$UPLOAD_HOST_PATH" ] && info "Resolved via docker inspect: $UPLOAD_HOST_PATH"
  else
    warn "Immich container not running — cannot resolve named volume via container inspect."
  fi
fi

# Stage 3: named volume — docker volume inspect (works even if container stopped)
if [ -z "$UPLOAD_HOST_PATH" ]; then
  info "Trying docker volume inspect..."
  while IFS= read -r vol_entry; do
    [ -z "$vol_entry" ] && continue
    vol_name="$(echo "$vol_entry" | cut -d: -f1)"
    container_part="$(echo "$vol_entry" | cut -d: -f2)"
    if echo "$container_part" | grep -q "upload"; then
      project="$(yq -r '.name // ""' "$ORIGINAL_COMPOSE" 2>/dev/null || true)"
      for candidate in "${project:+${project}_${vol_name}}" "$vol_name"; do
        [ -z "$candidate" ] && continue
        resolved="$($DOCKER volume inspect "$candidate" --format '{{.Mountpoint}}' 2>/dev/null || true)"
        if [ -n "$resolved" ] && [ -d "$resolved" ]; then
          UPLOAD_HOST_PATH="$resolved"
          info "Resolved named volume '$candidate' → $UPLOAD_HOST_PATH"
          break 2
        fi
      done
    fi
  done < <(yq -r ".services.\"${IMMICH_SERVICE}\".volumes[]" "$ORIGINAL_COMPOSE" 2>/dev/null || true)
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

$DOCKER exec "$POSTGRES_CID" pg_dumpall -U "$PGUSER" | gzip > "$DB_DUMP"

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

cat > "$MANIFEST" << 'RESTORE_EOF'
# Immich Restore Guide
RESTORE_EOF

cat >> "$MANIFEST" << RESTORE
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

### 2. Restore the upload library
\`\`\`bash
rsync -a "$BACKUP_DIR/library/" "/your/new/upload/path/"
\`\`\`

### 3. Start Postgres only
\`\`\`bash
docker compose up -d $POSTGRES_SERVICE
sleep 10
\`\`\`

### 4. Restore the database
\`\`\`bash
docker compose exec $POSTGRES_SERVICE psql -U $PGUSER -c "DROP DATABASE IF EXISTS $PGDATABASE;"
docker compose exec $POSTGRES_SERVICE psql -U $PGUSER -c "CREATE DATABASE $PGDATABASE;"
zcat "$BACKUP_DIR/immich_db.sql.gz" | docker compose exec -T $POSTGRES_SERVICE psql -U $PGUSER
\`\`\`

### 5. Start all services
\`\`\`bash
docker compose up -d
\`\`\`
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
