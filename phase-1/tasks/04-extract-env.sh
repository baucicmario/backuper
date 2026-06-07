#!/usr/bin/env bash
# tasks/04-extract-env.sh
# Filter the stack .env down to only the variables this service's compose references.
# Usage: 04-extract-env.sh <out_dir> <env_file>
set -euo pipefail

OUT_DIR="${1:?Usage: $0 <out_dir> <env_file>}"
ENV_FILE="${2:?}"

out_env="$OUT_DIR/.env"
out_compose="$OUT_DIR/docker-compose.yml"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "# No .env file found for this stack." > "$out_env"
  exit 0
fi

out_compose="$OUT_DIR/docker-compose.yml"

used_vars="$(grep -oE '\$\{[A-Za-z0-9_]+\}|\$[A-Za-z0-9_]+' "$out_compose" \
  | grep -v '^\$\$' \
  | sed 's/[${}]//g' \
  | sort -u || true)"

> "$out_env"

if [[ -z "$used_vars" ]]; then
  echo "# No variables from .env are referenced by this service." >> "$out_env"
  exit 0
fi

matched_count=0
pending_comments=()

while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" =~ ^[[:space:]]*# ]]; then
    pending_comments+=("$line")
    continue
  fi

  if [[ -z "${line// /}" ]]; then
    pending_comments=()
    continue
  fi

  env_key="$(printf '%s' "$line" | cut -d= -f1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

  var_matched=false
  for var in $used_vars; do
    [[ "$env_key" == "$var" ]] && { var_matched=true; break; }
  done

  if [[ "$var_matched" == true ]]; then
    for comment_line in "${pending_comments[@]}"; do
      printf '%s\n' "$comment_line" >> "$out_env"
    done
    printf '%s\n' "$line" >> "$out_env"
    matched_count=$((matched_count + 1))
  fi

  pending_comments=()
done < "$ENV_FILE"

if [[ $matched_count -eq 0 ]]; then
  > "$out_env"
  echo "# Source .env exists but no variables from it are referenced by this service." >> "$out_env"
fi