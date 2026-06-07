#!/usr/bin/env bash
# phase-1/01-split-compose.sh
# Splits a multi-service docker-compose.yml into one file per service,
# extracting only the relevant .env variables for each.
# Usage: ./01-split-compose.sh [compose_file] [env_file]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

COMPOSE_INPUT="${1:-docker-compose.yml}"
ENV_INPUT="${2:-.env}"
OUTPUT_DIR="split_composers"

# ── Resolve absolute paths ────────────────
COMPOSE_FILE="$(readlink -f "$COMPOSE_INPUT")"
ENV_FILE="$(readlink -f "$ENV_INPUT" 2>/dev/null || echo "")"

# ── Pre-flight checks ─────────────────────
require_cmd yq

[ -f "$COMPOSE_FILE" ] \
  || die "Compose file '$COMPOSE_INPUT' (resolved to '$COMPOSE_FILE') not found."

mkdir -p "$OUTPUT_DIR"

# ── Extract service names ─────────────────
info "Analyzing $COMPOSE_FILE..."
SERVICES=$(yq '.services | keys | .[]' "$COMPOSE_FILE")

[ -n "$SERVICES" ] && [ "$SERVICES" != "null" ] \
  || die "No services found in $COMPOSE_FILE."

# ── Process each service ──────────────────
for service in $SERVICES; do
  line
  info "Processing service: $service"

  TARGET_DIR="$OUTPUT_DIR/$service"
  TARGET_COMPOSE="$TARGET_DIR/docker-compose.yml"
  TARGET_ENV="$TARGET_DIR/.env"

  mkdir -p "$TARGET_DIR"

  # Extract individual service block wrapped in 'services:'
  yq -n ".services.\"$service\" = load(\"$COMPOSE_FILE\").services.\"$service\"" > "$TARGET_COMPOSE"

  # Handle .env variables
  if [ -n "$ENV_FILE" ] && [ -f "$ENV_FILE" ]; then
    USED_VARS=$(grep -oE '\$[{]?[A-Za-z0-9_]+' "$TARGET_COMPOSE" | sed 's/[${}]//g' | sort -u)

    if [ -n "$USED_VARS" ]; then
      > "$TARGET_ENV"
      VARS_FOUND=0

      for var in $USED_VARS; do
        if grep -E "^${var}=" "$ENV_FILE" >> "$TARGET_ENV"; then
          VARS_FOUND=$((VARS_FOUND + 1))
        fi
      done

      if [ "$VARS_FOUND" -gt 0 ]; then
        ok "Created .env ($VARS_FOUND variables extracted)"
      else
        rm "$TARGET_ENV"
        warn "No matching variables found in $ENV_FILE for $service."
      fi
    else
      info "No variables required by $service."
    fi
  else
    warn "Source env file not found or not provided: $ENV_INPUT"
  fi

  ok "Saved to $TARGET_COMPOSE"
done

line
ok "Done! All services split into '$OUTPUT_DIR'."