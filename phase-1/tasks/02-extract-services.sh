#!/usr/bin/env bash
# tasks/02-extract-services.sh
# Parse a compose file and print one service name per line (stdout).
# Usage: 02-extract-services.sh <compose_file>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../../lib/common.sh"

require_cmd yq

COMPOSE_FILE="${1:?Usage: $0 <compose_file>}"
[[ -f "$COMPOSE_FILE" ]] || { echo "Error: compose file not found: $COMPOSE_FILE" >&2; exit 1; }

services="$(yq '.services | keys | .[]' "$COMPOSE_FILE" 2>/dev/null || true)"

if [[ -z "$services" || "$services" == "null" ]]; then
  echo "Warning: no services block in $COMPOSE_FILE" >&2
  exit 0
fi

echo "$services"