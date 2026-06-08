#!/usr/bin/env bash
# phase1.sh — DEPRECATED shim. Use backup.sh instead.
# This file exists for backward compatibility and will be removed in a future version.
exec "$(dirname "$0")/backup.sh" "$@"
