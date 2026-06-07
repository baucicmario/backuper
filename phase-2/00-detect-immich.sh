#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

require_cmd yq

STATE_FILE="${STATE_FILE:-/tmp/immich_detected.env}"
: > "$STATE_FILE" || die "Cannot write state file: $STATE_FILE"

compose_file=""
env_file=""

detect_stack() {
  local stack_dir="$1"
  local candidate="$stack_dir/compose.yaml"
  [ -f "$candidate" ] || candidate="$stack_dir/docker-compose.yml"
  [ -f "$candidate" ] || return 1
  compose_file="$candidate"
  env_file="$stack_dir/.env"
  return 0
}

if [ -n "${IMMICH_COMPOSE_FILE:-}" ]; then
  compose_file="$IMMICH_COMPOSE_FILE"
  env_file="${IMMICH_ENV_FILE:-$(dirname "$compose_file")/.env}"
else
  if detect_stack "/opt/stacks/immich"; then
    info "Falling back to live Dockge stack: $compose_file"
  else
    die "Could not detect Immich compose file."
  fi
fi

load_env "$env_file"

immich_service="$(yq '.services | keys | .[]' "$compose_file" | grep -E '^immich-server$|^immich$' | head -n1 || true)"
postgres_service="$(yq '.services | keys | .[]' "$compose_file" | grep -E '^database$|^postgres$' | head -n1 || true)"

[ -n "$immich_service" ] || die "Immich service not found in compose file: $compose_file"
[ -n "$postgres_service" ] || die "Postgres service not found in compose file: $compose_file"

{
  printf 'IMMICH_COMPOSE_FILE=%q\n' "$compose_file"
  printf 'IMMICH_ENV_FILE=%q\n' "$env_file"
  printf 'IMMICH_SERVICE=%q\n' "$immich_service"
  printf 'POSTGRES_SERVICE=%q\n' "$postgres_service"
  printf 'IMMICH_DETECTED_AT=%q\n' "$(date -u +%Y%m%dT%H%M%SZ)"
} > "$STATE_FILE"

ok "Immich detected:   $immich_service  ($compose_file)"
ok "Postgres detected: $postgres_service  ($compose_file)"
ok "State saved to $STATE_FILE"