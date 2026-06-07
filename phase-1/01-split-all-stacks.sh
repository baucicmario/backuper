#!/usr/bin/env bash
# phase-1/01-split-all-stacks.sh
# Discover all Dockge stacks and split every service into its own self-contained
# output folder, embedding provenance metadata for later restore.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

# ── Dependency checks ─────────────────────
require_cmd yq
require_cmd realpath

# ── Defaults ──────────────────────────────
DOCKGE_STACKS_DIR="${DOCKGE_STACKS_DIR:-/opt/stacks}"
OUTPUT_DIR="$SCRIPT_DIR/split_stacks"
DRY_RUN=false
FORCE=false

SCRIPT_ABS="$(realpath "$0")"
EXTRACTED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# ── Argument parsing ──────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stacks-dir)
      shift
      [[ -n "${1:-}" ]] || die "--stacks-dir requires a path argument"
      DOCKGE_STACKS_DIR="$1"
      ;;
    --output)
      shift
      [[ -n "${1:-}" ]] || die "--output requires a path argument"
      OUTPUT_DIR="$1"
      ;;
    --dry-run)
      DRY_RUN=true
      ;;
    --force)
      FORCE=true
      ;;
    --help|-h)
      cat <<USAGE
Usage: $(basename "$0") [OPTIONS] [OUTPUT_DIR]

Discover all Dockge stacks and split every service into its own output folder.

Options:
  --stacks-dir <path>   Override DOCKGE_STACKS_DIR (default: /opt/stacks)
  --output <path>       Override OUTPUT_DIR (default: ./split_stacks)
  --dry-run             Print what would be created without writing anything
  --force               Overwrite existing output folders (default: skip)
  -h, --help            Show this help and exit

Positional:
  OUTPUT_DIR            First positional argument overrides output directory

Environment:
  DOCKGE_STACKS_DIR     Override the stacks directory (same as --stacks-dir)
USAGE
      exit 0
      ;;
    -*)
      die "Unknown flag: $1 — run with --help for usage"
      ;;
    *)
      # First positional arg overrides OUTPUT_DIR
      OUTPUT_DIR="$1"
      ;;
  esac
  shift
done

# ── Validate stacks dir ───────────────────
[[ -d "$DOCKGE_STACKS_DIR" ]] \
  || die "DOCKGE_STACKS_DIR does not exist or is not a directory: $DOCKGE_STACKS_DIR"

# ── Summary header ────────────────────────
echo
info "🗂  Dockge Stack Splitter"
line
info "  Stacks directory : $DOCKGE_STACKS_DIR"
info "  Output directory : $OUTPUT_DIR"
info "  Dry-run          : $DRY_RUN"
info "  Force overwrite  : $FORCE"
line

# ── Counters ──────────────────────────────
STACKS_SCANNED=0
SERVICES_EXTRACTED=0
WARNINGS=0

# ── Helper: sanitize a name for use as a directory component ──
# Replaces characters that are invalid in directory names with _
sanitize_dirname() {
  local raw="$1"
  # Replace / and any other problematic chars; keep alphanumerics, dashes, dots, underscores
  printf '%s' "$raw" | tr -s '/' '_' | sed 's/[^A-Za-z0-9._-]/_/g'
}

# ── Helper: emit a line only in dry-run ──
dry_info() {
  [[ "$DRY_RUN" == true ]] && info "(dry-run) $*"
}

# ── Process a single stack ────────────────
process_stack() {
  local stack_dir="$1"
  local stack_name
  stack_name="$(basename "$stack_dir")"
  local compose_file="$stack_dir/compose.yaml"
  local env_file="$stack_dir/.env"

  STACKS_SCANNED=$((STACKS_SCANNED + 1))

  echo
  line
  info "Stack: $stack_name"

  # ── Validate compose.yaml presence ───────
  if [[ ! -f "$compose_file" ]]; then
    warn "[$stack_name] No compose.yaml found — skipping"
    WARNINGS=$((WARNINGS + 1))
    return 0
  fi

  # ── Validate services block via yq ───────
  local services_raw
  if ! services_raw="$(yq '.services | keys | .[]' "$compose_file" 2>&1)"; then
    warn "[$stack_name] yq failed to parse compose.yaml — $services_raw"
    WARNINGS=$((WARNINGS + 1))
    return 0
  fi

  if [[ -z "$services_raw" || "$services_raw" == "null" ]]; then
    warn "[$stack_name] compose.yaml has no services block or services is empty — skipping"
    WARNINGS=$((WARNINGS + 1))
    return 0
  fi

  local source_env_abs=""
  [[ -f "$env_file" ]] && source_env_abs="$(realpath "$env_file")"

  # ── Iterate services ──────────────────────
  local service
  while IFS= read -r service; do
    [[ -z "$service" ]] && continue

    local safe_service
    safe_service="$(sanitize_dirname "$service")"

    local out_folder="$OUTPUT_DIR/${stack_name}__${safe_service}"

    # ── Collision / force check ───────────────
    if [[ -d "$out_folder" ]]; then
      if [[ "$FORCE" == false ]]; then
        warn "[$stack_name/$service] Output folder already exists, skipping: $out_folder"
        WARNINGS=$((WARNINGS + 1))
        continue
      else
        warn "[$stack_name/$service] Output folder exists — overwriting (--force)"
        WARNINGS=$((WARNINGS + 1))
      fi
    fi

    info "  → Extracting service: $service"

    if [[ "$DRY_RUN" == true ]]; then
      dry_info "Would create: $out_folder/"
      dry_info "Would write : $out_folder/docker-compose.yml"
      dry_info "Would write : $out_folder/.stack-meta"
      [[ -f "$env_file" ]] && dry_info "Would write : $out_folder/.env"
      SERVICES_EXTRACTED=$((SERVICES_EXTRACTED + 1))
      continue
    fi

    mkdir -p "$out_folder"

    # ────────────────────────────────────────
    # 1. Build docker-compose.yml
    # ────────────────────────────────────────
    local out_compose="$out_folder/docker-compose.yml"

    # Start with only this service's definition
    yq -n ".services.\"${service}\" = load(\"${compose_file}\").services.\"${service}\"" \
      > "$out_compose"

    # Collect networks this service references
    local svc_networks
    svc_networks="$(yq ".services.\"${service}\".networks | keys | .[]" "$compose_file" 2>/dev/null || true)"

    if [[ -n "$svc_networks" ]]; then
      while IFS= read -r net; do
        [[ -z "$net" || "$net" == "null" ]] && continue
        # Check whether a top-level networks entry exists for this name
        local net_def
        net_def="$(yq ".networks.\"${net}\"" "$compose_file" 2>/dev/null || true)"
        if [[ -n "$net_def" && "$net_def" != "null" ]]; then
          # Merge into output compose
          yq -i ".networks.\"${net}\" = load(\"${compose_file}\").networks.\"${net}\"" "$out_compose"
        else
          # The service references a network with no top-level definition (external or implicit).
          # Write a null placeholder so the service reference is valid.
          yq -i ".networks.\"${net}\" = null" "$out_compose"
        fi
      done <<< "$svc_networks"
    fi

    # Collect named volumes this service mounts
    # Volumes may be listed as "volname:/path" strings or mapping keys
    local svc_volumes_raw
    svc_volumes_raw="$(yq ".services.\"${service}\".volumes[]" "$compose_file" 2>/dev/null || true)"

    if [[ -n "$svc_volumes_raw" ]]; then
      while IFS= read -r vol_entry; do
        [[ -z "$vol_entry" || "$vol_entry" == "null" ]] && continue

        # Extract the source part (before first colon), skip bind mounts (start with / . ~)
        local vol_src
        vol_src="$(printf '%s' "$vol_entry" | cut -d: -f1)"

        # Skip host/bind mounts
        [[ "$vol_src" =~ ^[/\.~] ]] && continue

        # It is a named volume — check for a top-level definition
        local vol_def
        vol_def="$(yq ".volumes.\"${vol_src}\"" "$compose_file" 2>/dev/null || true)"
        if [[ -n "$vol_def" && "$vol_def" != "null" ]]; then
          yq -i ".volumes.\"${vol_src}\" = load(\"${compose_file}\").volumes.\"${vol_src}\"" "$out_compose"
        else
          # Named volume referenced but no top-level entry — write null placeholder
          yq -i ".volumes.\"${vol_src}\" = null" "$out_compose"
        fi
      done <<< "$svc_volumes_raw"
    fi

    # ────────────────────────────────────────
    # 2. Build .env (only if source .env exists)
    # ────────────────────────────────────────
    if [[ -f "$env_file" ]]; then
      local out_env="$out_folder/.env"

      # Extract all variable names referenced in the service's compose block.
      # Match both ${VAR} and $VAR patterns (but not $$ escapes).
      local used_vars
      used_vars="$(grep -oE '\$\{[A-Za-z0-9_]+\}|\$[A-Za-z0-9_]+' "$out_compose" \
        | grep -v '^\$\$' \
        | sed 's/[${}]//g' \
        | sort -u || true)"

      # Start with an empty file
      > "$out_env"

      if [[ -z "$used_vars" ]]; then
        echo "# No variables from .env are referenced by this service." >> "$out_env"
      else
        local matched_count=0

        # Read the source .env line by line, preserving comment blocks above matched vars
        local pending_comments=()
        local comments_flushed=false

        while IFS= read -r env_line || [[ -n "$env_line" ]]; do
          # Accumulate comment lines
          if [[ "$env_line" =~ ^[[:space:]]*# ]]; then
            pending_comments+=("$env_line")
            continue
          fi

          # Blank lines reset the pending comment block
          if [[ -z "${env_line// /}" ]]; then
            pending_comments=()
            continue
          fi

          # Check if this assignment line matches a used variable
          local env_key
          env_key="$(printf '%s' "$env_line" | cut -d= -f1 | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"

          local var_matched=false
          for var in $used_vars; do
            if [[ "$env_key" == "$var" ]]; then
              var_matched=true
              break
            fi
          done

          if [[ "$var_matched" == true ]]; then
            # Flush the pending comment block first
            for comment_line in "${pending_comments[@]}"; do
              printf '%s\n' "$comment_line" >> "$out_env"
            done
            printf '%s\n' "$env_line" >> "$out_env"
            matched_count=$((matched_count + 1))
          fi

          # Always reset pending comments after a non-comment, non-blank line
          pending_comments=()

        done < "$env_file"

        if [[ $matched_count -eq 0 ]]; then
          # .env existed but nothing matched — leave file with explanatory comment
          > "$out_env"
          echo "# Source .env exists but no variables from it are referenced by this service." >> "$out_env"
        fi
      fi
    fi

    # ────────────────────────────────────────
    # 3. Write .stack-meta
    # ────────────────────────────────────────
    local out_meta="$out_folder/.stack-meta"
    local source_compose_abs
    source_compose_abs="$(realpath "$compose_file")"

    cat > "$out_meta" <<META
SOURCE_STACK=${stack_name}
SOURCE_FILE=${source_compose_abs}
SOURCE_ENV=${source_env_abs}
SERVICE_NAME=${service}
EXTRACTED_AT=${EXTRACTED_AT}
EXTRACTED_BY=${SCRIPT_ABS}
META

    ok "  ✔ $out_folder"
    SERVICES_EXTRACTED=$((SERVICES_EXTRACTED + 1))

  done <<< "$services_raw"
}

# ── Discover and process all stacks ───────
mapfile -t STACK_DIRS < <(find "$DOCKGE_STACKS_DIR" -mindepth 1 -maxdepth 1 -type d | sort)

if [[ ${#STACK_DIRS[@]} -eq 0 ]]; then
  warn "No stack directories found in $DOCKGE_STACKS_DIR"
fi

for stack_dir in "${STACK_DIRS[@]}"; do
  process_stack "$stack_dir"
done

# ── Summary ───────────────────────────────
echo
line
bold "📊 Summary"
info "  Stacks scanned     : $STACKS_SCANNED"
info "  Services extracted : $SERVICES_EXTRACTED"
[[ $WARNINGS -gt 0 ]] \
  && warn "  Warnings           : $WARNINGS" \
  || info "  Warnings           : $WARNINGS"
line

[[ "$DRY_RUN" == true ]] \
  && ok "Dry-run complete — no files were written." \
  || ok "Done."
