#!/usr/bin/env bash
# setup.sh — Public entrypoint: provision a fresh host with all dependencies.
# Installs: core utils, yq, Docker, Cockpit, Dockge
# Usage: ./setup.sh [--dry-run] [--exclude <script>]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/runner.sh"

run_phase "$SCRIPT_DIR/modules/setup" "setup" "$@"
