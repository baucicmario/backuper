#!/usr/bin/env bash
# phase0.sh — DEPRECATED shim. Use setup.sh instead.
# This file exists for backward compatibility and will be removed in a future version.
exec "$(dirname "$0")/setup.sh" "$@"
