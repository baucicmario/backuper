#!/usr/bin/env bash
# tasks/01-detect-immich.sh
# Detect the Immich Docker Compose stack and write all discovered paths/service
# names into $STATE_FILE so downstream tasks have a single source of truth.
#
# Inputs (env):
#   STATE_FILE            — path to the temp file to write (required, set by orchestrator)
#   IMMICH_COMPOSE_FILE   — override: skip auto-detection, use this compose file directly
#   IMMICH_ENV_FILE       — override: explicit .env path (defaults to compose-file's dir/.env)
#   DOCKGE_STACKS_DIR     — where to search for stacks (default: /opt/stacks)
#
# Outputs (written to $STATE_FILE):
#   IMMICH_COMPOSE_FILE, IMMICH_ENV_FILE, IMMICH_SERVICE, POSTGRES_SERVICE, IMMICH_DETECTED_AT
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../../lib/common.sh"

require_cmd yq

STATE_FILE="${STATE_FILE:?STATE_FILE must be set by the orchestrator}"
: > "$STATE_FILE" || die "Cannot write state file: $STATE_FILE"

DOCKGE_STACKS_DIR="${DOCKGE_STACKS_DIR:-/opt/stacks}"

compose_file=""
env_file=""

# ── Locate compose file ───────────────────────────────────────────────────────
if [[ -n "${IMMICH_COMPOSE_FILE:-}" ]]; then
  [[ -f "$IMMICH_COMPOSE_FILE" ]] || die "Compose file not found: $IMMICH_COMPOSE_FILE"
  compose_file="$IMMICH_COMPOSE_FILE"
  env_file="${IMMICH_ENV_FILE:-$(dirname "$compose_file")/.env}"
  info "Using provided compose file: $compose_file"
else
  # Auto-detect: look for an 'immich' folder under the stacks directory
  for candidate_dir in \
    "$DOCKGE_STACKS_DIR/immich" \
    "$DOCKGE_STACKS_DIR/Immich" \
    "$DOCKGE_STACKS_DIR/IMMICH"
  do
    if [[ -f "$candidate_dir/compose.yaml" ]]; then
      compose_file="$candidate_dir/compose.yaml"
      env_file="$candidate_dir/.env"
      info "Auto-detected Immich stack: $compose_file"
      break
    elif [[ -f "$candidate_dir/docker-compose.yml" ]]; then
      compose_file="$candidate_dir/docker-compose.yml"
      env_file="$candidate_dir/.env"
      info "Auto-detected Immich stack: $compose_file"
      break
    fi
  done

  [[ -n "$compose_file" ]] || die \
    "Could not find Immich compose file under $DOCKGE_STACKS_DIR/immich. " \
    "Set IMMICH_COMPOSE_FILE to specify the path explicitly."
fi

# ── Load .env so service-name patterns can reference variables ────────────────
[[ -f "$env_file" ]] && load_env "$env_file" || warn "No .env found at $env_file — continuing without it"

# ── Identify the immich-server service ───────────────────────────────────────
immich_service="$(
  yq '.services | keys | .[]' "$compose_file" 2>/dev/null \
    | grep -E '^immich-server$|^immich$|^immich_server$' \
    | head -n1 \
  || true
)"
[[ -n "$immich_service" ]] || die \
  "Could not find an Immich server service in $compose_file. " \
  "Expected a service named 'immich', 'immich-server', or 'immich_server'."

# ── Identify the Postgres service ────────────────────────────────────────────
postgres_service="$(
  yq '.services | keys | .[]' "$compose_file" 2>/dev/null \
    | grep -E '^database$|^postgres$|^postgresql$|^db$|^immich-postgres$|^immich_postgres$' \
    | head -n1 \
  || true
)"
[[ -n "$postgres_service" ]] || die \
  "Could not find a Postgres service in $compose_file. " \
  "Expected a service named 'database', 'postgres', 'db', or similar."

# ── Write state ───────────────────────────────────────────────────────────────
{
  printf 'IMMICH_COMPOSE_FILE=%q\n' "$compose_file"
  printf 'IMMICH_ENV_FILE=%q\n'     "$env_file"
  printf 'IMMICH_SERVICE=%q\n'      "$immich_service"
  printf 'POSTGRES_SERVICE=%q\n'    "$postgres_service"
  printf 'IMMICH_DETECTED_AT=%q\n'  "$(date -u +%Y%m%dT%H%M%SZ)"
} > "$STATE_FILE"

ok "Immich detected:   $immich_service  ($compose_file)"
ok "Postgres detected: $postgres_service"
ok "State saved →  $STATE_FILE"
