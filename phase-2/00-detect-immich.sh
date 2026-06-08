#!/usr/bin/env bash
# phase-2/00-detect-immich.sh — Detect Immich installation
# Locates the Immich Docker Compose setup and identifies key service names.
# Saves detection results to STATE_FILE for use by other phase-2 scripts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

# Ensure yq is available for YAML parsing
require_cmd yq

# ── State file for sharing detection results between scripts ────────────────
STATE_FILE="${STATE_FILE:-/tmp/immich_detected.env}"
# Clear/create empty state file before writing
: > "$STATE_FILE" || die "Cannot write state file: $STATE_FILE"

# ── Variables for detected paths ──────────────────────────────────────────
compose_file=""
env_file=""

# ── Helper function to find compose file in a directory ──────────────────
detect_stack() {
  local stack_dir="$1"
  # Try compose.yaml first (newer standard), fallback to docker-compose.yml
  local candidate="$stack_dir/compose.yaml"
  [ -f "$candidate" ] || candidate="$stack_dir/docker-compose.yml"
  [ -f "$candidate" ] || return 1
  compose_file="$candidate"
  env_file="$stack_dir/.env"
  return 0
}

# ── Detection logic: check environment variables first, then try default location ──
if [ -n "${IMMICH_COMPOSE_FILE:-}" ]; then
  # Environment variable takes precedence
  compose_file="$IMMICH_COMPOSE_FILE"
  env_file="${IMMICH_ENV_FILE:-$(dirname "$compose_file")/.env}"
else
  # Try the standard Dockge location
  if detect_stack "/opt/stacks/immich"; then
    info "Falling back to live Dockge stack: $compose_file"
  else
    die "Could not detect Immich compose file."
  fi
fi

# Load environment variables that might be referenced
load_env "$env_file"

# ── Identify key service names (Immich server and database) ────────────────
# Different Immich setups use different service naming conventions
immich_service="$(yq '.services | keys | .[]' "$compose_file" | grep -E '^immich-server$|^immich$' | head -n1 || true)"
postgres_service="$(yq '.services | keys | .[]' "$compose_file" | grep -E '^database$|^postgres$' | head -n1 || true)"

# Validate that required services exist
[ -n "$immich_service" ] || die "Immich service not found in compose file: $compose_file"
[ -n "$postgres_service" ] || die "Postgres service not found in compose file: $compose_file"

# ── Write detection results to STATE_FILE for other scripts ─────────────────
# Using printf %q for proper shell escaping
{
  printf 'IMMICH_COMPOSE_FILE=%q\n' "$compose_file"
  printf 'IMMICH_ENV_FILE=%q\n' "$env_file"
  printf 'IMMICH_SERVICE=%q\n' "$immich_service"
  printf 'POSTGRES_SERVICE=%q\n' "$postgres_service"
  printf 'IMMICH_DETECTED_AT=%q\n' "$(date -u +%Y%m%dT%H%M%SZ)"
} > "$STATE_FILE"

# ── Summary ───────────────────────────────────────────────────────────────
ok "Immich detected:   $immich_service  ($compose_file)"
ok "Postgres detected: $postgres_service  ($compose_file)"
ok "State saved to $STATE_FILE"