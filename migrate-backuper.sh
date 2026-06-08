#!/usr/bin/env bash
# =============================================================================
# migrate-backuper.sh — Option B restructure for the backuper project
# Run from the repository root: bash migrate-backuper.sh
# Idempotent: safe to run multiple times.
# =============================================================================
set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; BLUE="\e[36m"
BOLD="\e[1m"; RESET="\e[0m"
info()  { echo -e "${BLUE}  ▸ $*${RESET}"; }
ok()    { echo -e "${GREEN}  ✔ $*${RESET}"; }
warn()  { echo -e "${YELLOW}  ⚠  $*${RESET}"; }
die()   { echo -e "${RED}  ✖ $*${RESET}" >&2; exit 1; }
header(){ echo; echo -e "${BOLD}${BLUE}══ $* ══${RESET}"; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

echo
echo -e "${BOLD}${GREEN}backuper → Option B migration${RESET}"
echo -e "Working in: ${YELLOW}${REPO_ROOT}${RESET}"
echo

# =============================================================================
# STEP 1 — Verify we are in the right directory
# =============================================================================
header "STEP 1 — Pre-flight check"

[[ -f "phase1.sh" || -f "backup.sh" ]] \
  || die "Cannot find phase1.sh or backup.sh. Run this script from the repo root."
[[ -f "lib/common.sh" ]] \
  || die "Cannot find lib/common.sh. Are you in the right directory?"

ok "Repo root confirmed: $REPO_ROOT"

# =============================================================================
# STEP 2 — Create new directory structure
# =============================================================================
header "STEP 2 — Create directories"

for d in bin modules/setup modules/backup/steps modules/backup/data \
          docs tests deprecated/immich-backuper/steps; do
  mkdir -p "$d"
  ok "mkdir -p $d"
done

# =============================================================================
# STEP 3 — Rename lib/run_phase.sh → lib/runner.sh
# =============================================================================
header "STEP 3 — Rename lib/run_phase.sh → lib/runner.sh"

if [[ -f "lib/run_phase.sh" && ! -f "lib/runner.sh" ]]; then
  cp "lib/run_phase.sh" "lib/runner.sh"
  ok "Copied lib/run_phase.sh → lib/runner.sh"
elif [[ -f "lib/runner.sh" ]]; then
  ok "lib/runner.sh already exists — skipping"
else
  die "lib/run_phase.sh not found"
fi

# Fix the self-source inside runner.sh (SCRIPT_LIB path stays the same; just
# update any internal reference to "run_phase" comment strings)
sed -i 's|# lib/run_phase\.sh|# lib/runner.sh|g' "lib/runner.sh" 2>/dev/null || true

# =============================================================================
# STEP 4 — Move modules/setup (was "phase-0-dependency installer")
# =============================================================================
header "STEP 4 — Move setup scripts → modules/setup/"

OLD_SETUP=""
if   [[ -d "phase-0-dependency installer" ]]; then OLD_SETUP="phase-0-dependency installer"
elif [[ -d "phase-0-setup"               ]]; then OLD_SETUP="phase-0-setup"
elif [[ -d "phase-0"                     ]]; then OLD_SETUP="phase-0"
else
  warn "Could not find a phase-0 directory — skipping setup module move"
fi

if [[ -n "$OLD_SETUP" ]]; then
  for f in "${OLD_SETUP}"/*.sh; do
    [[ -f "$f" ]] || continue
    fname="$(basename "$f")"
    if [[ ! -f "modules/setup/$fname" ]]; then
      cp "$f" "modules/setup/$fname"
      ok "Copied $f → modules/setup/$fname"
    else
      ok "modules/setup/$fname already exists — skipping"
    fi
  done
fi

# Fix source paths inside modules/setup scripts:
# was: source "$SCRIPT_DIR/../lib/common.sh"
# now: source "$SCRIPT_DIR/../../lib/common.sh"
for f in modules/setup/*.sh; do
  [[ -f "$f" ]] || continue
  sed -i \
    's|source "\$SCRIPT_DIR/\.\./lib/common\.sh"|source "$SCRIPT_DIR/../../lib/common.sh"|g' \
    "$f"
  sed -i \
    "s|source \"\\\$SCRIPT_DIR/../lib/common.sh\"|source \"\\\$SCRIPT_DIR/../../lib/common.sh\"|g" \
    "$f" 2>/dev/null || true
  ok "Fixed source paths in $f"
done

# =============================================================================
# STEP 5 — Move modules/backup (was "phase-1-backupers")
# =============================================================================
header "STEP 5 — Move backup scripts → modules/backup/"

OLD_BACKUP=""
if   [[ -d "phase-1-backupers" ]]; then OLD_BACKUP="phase-1-backupers"
elif [[ -d "phase-1"           ]]; then OLD_BACKUP="phase-1"
else
  warn "Could not find a phase-1 directory — skipping backup module move"
fi

if [[ -n "$OLD_BACKUP" ]]; then
  # orchestrator.sh → modules/backup/run.sh
  if [[ -f "$OLD_BACKUP/orchestrator.sh" && ! -f "modules/backup/run.sh" ]]; then
    cp "$OLD_BACKUP/orchestrator.sh" "modules/backup/run.sh"
    ok "Copied $OLD_BACKUP/orchestrator.sh → modules/backup/run.sh"
  elif [[ -f "modules/backup/run.sh" ]]; then
    ok "modules/backup/run.sh already exists — skipping"
  fi

  # tasks/*.sh → modules/backup/steps/*.sh
  if [[ -d "$OLD_BACKUP/tasks" ]]; then
    for f in "$OLD_BACKUP/tasks"/*.sh; do
      [[ -f "$f" ]] || continue
      fname="$(basename "$f")"
      if [[ ! -f "modules/backup/steps/$fname" ]]; then
        cp "$f" "modules/backup/steps/$fname"
        ok "Copied $f → modules/backup/steps/$fname"
      else
        ok "modules/backup/steps/$fname already exists — skipping"
      fi
    done

    # known-config-mounts.txt → modules/backup/data/
    if [[ -f "$OLD_BACKUP/tasks/known-config-mounts.txt" && \
          ! -f "modules/backup/data/known-config-mounts.txt" ]]; then
      cp "$OLD_BACKUP/tasks/known-config-mounts.txt" \
         "modules/backup/data/known-config-mounts.txt"
      ok "Copied known-config-mounts.txt → modules/backup/data/"
    else
      ok "modules/backup/data/known-config-mounts.txt already exists — skipping"
    fi
  fi

  # Promote README.md → docs/backup.md
  if [[ -f "$OLD_BACKUP/README.md" && ! -f "docs/backup.md" ]]; then
    cp "$OLD_BACKUP/README.md" "docs/backup.md"
    ok "Promoted $OLD_BACKUP/README.md → docs/backup.md"
  fi
fi

# Fix source paths inside modules/backup/run.sh
# was: source "$SCRIPT_DIR/../lib/common.sh"  (orchestrator was one level deep)
# now: source "$SCRIPT_DIR/../../lib/common.sh" (now two levels deep)
if [[ -f "modules/backup/run.sh" ]]; then
  sed -i \
    's|source "\$SCRIPT_DIR/\.\./lib/common\.sh"|source "$SCRIPT_DIR/../../lib/common.sh"|g' \
    "modules/backup/run.sh"
  # Fix the tasks directory variable: T= or TASKS_DIR= → S= pointing to steps/
  sed -i \
    's|T="\$SCRIPT_DIR/tasks"|S="$SCRIPT_DIR/steps"|g' \
    "modules/backup/run.sh"
  sed -i \
    's|TASKS_DIR="\$SCRIPT_DIR/tasks"|STEPS_DIR="$SCRIPT_DIR/steps"|g' \
    "modules/backup/run.sh"
  # Also fix any bare T= or $T/ references that remain
  sed -i \
    's|"\$T/|"$S/|g' \
    "modules/backup/run.sh"
  sed -i \
    's|\$T/|$S/|g' \
    "modules/backup/run.sh"
  ok "Fixed source + steps paths in modules/backup/run.sh"
fi

# Fix source paths inside modules/backup/steps/*.sh
# was: source "$SCRIPT_DIR/../../lib/common.sh"   (tasks/ was 2 dirs up from lib)
# now: same depth — steps/ is still 2 dirs up from lib — NO change needed
# BUT some tasks sourced via "../../../lib/common.sh" if nested differently; normalise all:
for f in modules/backup/steps/*.sh; do
  [[ -f "$f" ]] || continue
  # Normalise any ../../../lib or ../../lib to the correct ../../lib
  sed -i \
    's|source "\$SCRIPT_DIR/\.\./\.\./\.\./lib/common\.sh"|source "$SCRIPT_DIR/../../lib/common.sh"|g' \
    "$f"
  ok "Verified source path in $f"
done

# Fix known-config-mounts.txt path inside 06-copy-bind-mounts.sh
BINDBIND="modules/backup/steps/06-copy-bind-mounts.sh"
if [[ -f "$BINDBIND" ]]; then
  # was: KNOWN_LIST="$SCRIPT_DIR/known-config-mounts.txt"
  # now: KNOWN_LIST="$SCRIPT_DIR/../data/known-config-mounts.txt"
  sed -i \
    's|KNOWN_LIST="\$SCRIPT_DIR/known-config-mounts\.txt"|KNOWN_LIST="$SCRIPT_DIR/../data/known-config-mounts.txt"|g' \
    "$BINDBIND"
  # Also catch the variant where it might be written without quotes around var
  sed -i \
    's|KNOWNLIST="\$SCRIPT_DIR/known-config-mounts\.txt"|KNOWNLIST="$SCRIPT_DIR/../data/known-config-mounts.txt"|g' \
    "$BINDBIND"
  ok "Fixed known-config-mounts.txt path in 06-copy-bind-mounts.sh"
fi

# =============================================================================
# STEP 6 — Move deprecated immich backuper
# =============================================================================
header "STEP 6 — Move deprecated immich backuper → deprecated/immich-backuper/"

OLD_DEPR=""
if   [[ -d "phase-2--DEPRECIATED-immich-backuper" ]]; then
  OLD_DEPR="phase-2--DEPRECIATED-immich-backuper"
elif [[ -d "phase-2--DEPRECATED-immich-backuper" ]]; then
  OLD_DEPR="phase-2--DEPRECATED-immich-backuper"
elif [[ -d "phase-2" ]]; then
  OLD_DEPR="phase-2"
fi

if [[ -n "$OLD_DEPR" ]]; then
  # orchestrator.sh → deprecated/immich-backuper/run.sh
  if [[ -f "$OLD_DEPR/orchestrator.sh" && \
        ! -f "deprecated/immich-backuper/run.sh" ]]; then
    cp "$OLD_DEPR/orchestrator.sh" "deprecated/immich-backuper/run.sh"
    ok "Copied $OLD_DEPR/orchestrator.sh → deprecated/immich-backuper/run.sh"
  fi

  # tasks/*.sh → deprecated/immich-backuper/steps/
  if [[ -d "$OLD_DEPR/tasks" ]]; then
    for f in "$OLD_DEPR/tasks"/*.sh; do
      [[ -f "$f" ]] || continue
      fname="$(basename "$f")"
      if [[ ! -f "deprecated/immich-backuper/steps/$fname" ]]; then
        cp "$f" "deprecated/immich-backuper/steps/$fname"
        ok "Copied $f → deprecated/immich-backuper/steps/$fname"
      fi
    done
  fi

  # Fix source paths in deprecated/immich-backuper/run.sh
  # orchestrator was at phase-2/orchestrator.sh → ../../lib (2 levels up)
  # now at deprecated/immich-backuper/run.sh → ../../../lib (3 levels up)
  if [[ -f "deprecated/immich-backuper/run.sh" ]]; then
    sed -i \
      's|source "\$SCRIPT_DIR/\.\./lib/common\.sh"|source "$SCRIPT_DIR/../../../lib/common.sh"|g' \
      "deprecated/immich-backuper/run.sh"
    sed -i \
      's|source "\$SCRIPT_DIR/\.\./\.\./lib/common\.sh"|source "$SCRIPT_DIR/../../../lib/common.sh"|g' \
      "deprecated/immich-backuper/run.sh"
    sed -i \
      's|T="\$SCRIPT_DIR/tasks"|S="$SCRIPT_DIR/steps"|g' \
      "deprecated/immich-backuper/run.sh"
    sed -i \
      's|"\$T/|"$S/|g' \
      "deprecated/immich-backuper/run.sh"
    ok "Fixed paths in deprecated/immich-backuper/run.sh"
  fi

  # Fix source paths in deprecated/immich-backuper/steps/*.sh
  # steps was tasks/ at depth: phase-2/tasks/XX.sh → ../../lib (2 levels up... wait same depth)
  # now at deprecated/immich-backuper/steps/XX.sh → ../../../.. lib would be 4 levels; 
  # original tasks sourced ../../lib (correct from phase-2/tasks), 
  # new location is deprecated/immich-backuper/steps → need ../../../lib
  for f in deprecated/immich-backuper/steps/*.sh; do
    [[ -f "$f" ]] || continue
    sed -i \
      's|source "\$SCRIPT_DIR/\.\./\.\./lib/common\.sh"|source "$SCRIPT_DIR/../../../lib/common.sh"|g' \
      "$f"
    sed -i \
      's|source "\$SCRIPT_DIR/\.\./lib/common\.sh"|source "$SCRIPT_DIR/../../../lib/common.sh"|g' \
      "$f"
    ok "Fixed source paths in $f"
  done
else
  warn "No phase-2 directory found — skipping deprecated module move"
fi

# =============================================================================
# STEP 7 — Create setup.sh and backup.sh root entrypoints
# =============================================================================
header "STEP 7 — Create root entrypoints: setup.sh, backup.sh"

# setup.sh
if [[ ! -f "setup.sh" ]]; then
cat > "setup.sh" << 'EOF'
#!/usr/bin/env bash
# setup.sh — Public entrypoint: provision a fresh host with all dependencies.
# Installs: core utils, yq, Docker, Cockpit, Dockge
# Usage: ./setup.sh [--dry-run] [--exclude <script>]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/runner.sh"

run_phase "$SCRIPT_DIR/modules/setup" "setup" "$@"
EOF
  chmod +x "setup.sh"
  ok "Created setup.sh"
else
  # Update existing phase0.sh content to point to new paths
  sed -i \
    's|source "\$SCRIPT_DIR/lib/run_phase\.sh"|source "$SCRIPT_DIR/lib/runner.sh"|g' \
    "setup.sh"
  sed -i \
    's|run_phase "\$SCRIPT_DIR/phase-0[^"]*"|run_phase "$SCRIPT_DIR/modules/setup"|g' \
    "setup.sh"
  ok "setup.sh already exists — updated internal paths"
fi

# backup.sh
if [[ ! -f "backup.sh" ]]; then
cat > "backup.sh" << 'EOF'
#!/usr/bin/env bash
# backup.sh — Public entrypoint: backup all Dockge-managed Docker Compose stacks.
# Usage: ./backup.sh [--dry-run] [--force] [--copy-all] [--reject-all]
#        ./backup.sh [--stacks-dir /opt/stacks] [--output /mnt/backup]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

exec "$SCRIPT_DIR/modules/backup/run.sh" "$@"
EOF
  chmod +x "backup.sh"
  ok "Created backup.sh"
else
  sed -i \
    's|source "\$SCRIPT_DIR/lib/run_phase\.sh"|source "$SCRIPT_DIR/lib/common.sh"|g' \
    "backup.sh"
  ok "backup.sh already exists — updated internal paths"
fi

# =============================================================================
# STEP 8 — Create bin/ canonical commands
# =============================================================================
header "STEP 8 — Create bin/ canonical commands"

cat > "bin/setup" << 'EOF'
#!/usr/bin/env bash
# bin/setup — Canonical setup command.
# Thin wrapper around modules/setup; use setup.sh at repo root for convenience.
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/lib/runner.sh"
run_phase "$SCRIPT_DIR/modules/setup" "setup" "$@"
EOF
chmod +x "bin/setup"
ok "Created bin/setup"

cat > "bin/backup" << 'EOF'
#!/usr/bin/env bash
# bin/backup — Canonical backup command.
# Thin wrapper around modules/backup/run.sh; use backup.sh at repo root for convenience.
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
exec "$SCRIPT_DIR/modules/backup/run.sh" "$@"
EOF
chmod +x "bin/backup"
ok "Created bin/backup"

# =============================================================================
# STEP 9 — Create backward-compat shims for phase0.sh / phase1.sh / phase2.sh
# =============================================================================
header "STEP 9 — Backward-compat shims for old phase*.sh entrypoints"

# Only create shims if the originals were named phase0.sh etc (not if they
# were already renamed to setup.sh/backup.sh by the user)
for old_name in phase0.sh phase1.sh phase2.sh; do
  if [[ -f "$old_name" ]]; then
    # Check if it's already a shim
    if grep -q "exec.*setup\.sh\|exec.*backup\.sh\|DEPRECATED\|deprecated" \
       "$old_name" 2>/dev/null; then
      ok "$old_name is already a shim — skipping"
      continue
    fi
    # Back it up before overwriting
    cp "$old_name" "${old_name}.bak"
    warn "Backed up $old_name → ${old_name}.bak"
  fi
done

cat > "phase0.sh" << 'EOF'
#!/usr/bin/env bash
# phase0.sh — DEPRECATED shim. Use setup.sh instead.
# This file exists for backward compatibility and will be removed in a future version.
exec "$(dirname "$0")/setup.sh" "$@"
EOF
chmod +x "phase0.sh"
ok "Created phase0.sh shim → setup.sh"

cat > "phase1.sh" << 'EOF'
#!/usr/bin/env bash
# phase1.sh — DEPRECATED shim. Use backup.sh instead.
# This file exists for backward compatibility and will be removed in a future version.
exec "$(dirname "$0")/backup.sh" "$@"
EOF
chmod +x "phase1.sh"
ok "Created phase1.sh shim → backup.sh"

# phase2.sh: was already broken (called non-existent path); replace with notice
cat > "phase2.sh" << 'EOF'
#!/usr/bin/env bash
# phase2.sh — REMOVED.
# The Immich-specific backup module has been deprecated.
# Immich services are fully handled by the generic backup pipeline.
# Use: ./backup.sh
# The old code is preserved for reference in: deprecated/immich-backuper/
echo "phase2.sh has been removed. Immich is handled by backup.sh." >&2
echo "Reference code is in: deprecated/immich-backuper/" >&2
exit 1
EOF
chmod +x "phase2.sh"
ok "Created phase2.sh exit-with-notice stub"

# =============================================================================
# STEP 10 — Create documentation stubs
# =============================================================================
header "STEP 10 — Create documentation files"

# ── README.md ──────────────────────────────────────────────────────────────
if [[ ! -f "README.md" ]]; then
cat > "README.md" << 'EOF'
# backuper

Backup and restore Dockge-managed Docker Compose stacks — service by service,
with self-contained restore scripts baked into every output folder.

---

## What it does

1. **Setup** (`setup.sh`) — Installs all system dependencies on a fresh Linux host:
   core utilities, `yq`, Docker Engine, Cockpit, and Dockge.

2. **Backup** (`backup.sh`) — Reads every stack managed by Dockge, splits each
   multi-service compose file into isolated service packages, copies bind-mounted
   host data, and generates a self-contained `restore.sh` inside every output folder.

Each backup package contains:
- `docker-compose.yml` — single-service compose
- `.env` — only the variables this service uses
- `.stack-meta` — provenance (stack name, timestamp, original paths)
- `restore.sh` — one-click restore script
- `<mount>/` — copied bind-mount directories

---

## Requirements

- Linux (Debian/Ubuntu recommended; also supports Fedora, Arch, Alpine)
- Bash 4.2+
- `yq` v4, `jq`, `docker` with Compose plugin (installed by `setup.sh`)

---

## Quick start

```bash
# 1. Clone
git clone https://github.com/yourname/backuper.git
cd backuper

# 2. (First time) Install dependencies
./setup.sh

# 3. Run a backup
./backup.sh

# 4. Restore a service
cd backups/split_stacks/players__jellyfin
sudo ./restore.sh
```

---

## Commands

| Command | Description |
|---------|-------------|
| `./setup.sh` | Provision a fresh host (run once) |
| `./backup.sh` | Backup all Dockge stacks |
| `./backup.sh --dry-run` | Show what would happen, write nothing |
| `./backup.sh --copy-all` | Copy all bind mounts without prompting |
| `./backup.sh --reject-all` | Skip all bind mounts (config only) |
| `./backup.sh --force` | Overwrite existing output folders |
| `./backup.sh --stacks-dir <path>` | Override Dockge stacks directory |
| `./backup.sh --output <path>` | Override backup output directory |

---

## Configuration

Copy `.env.example` to `.env` and adjust as needed:

```bash
cp .env.example .env
```

See `.env.example` for all supported variables.

---

## Project layout

```
backuper/
├── setup.sh              ← entrypoint: provision host
├── backup.sh             ← entrypoint: run backup
├── bin/                  ← canonical commands (setup, backup)
├── lib/                  ← shared library (common.sh, runner.sh)
├── modules/
│   ├── setup/            ← dependency installation scripts
│   └── backup/           ← backup engine (run.sh + steps/ + data/)
├── docs/                 ← documentation
├── tests/                ← test scripts
└── deprecated/           ← archived modules (do not use)
```

---

## Contributing

See [docs/contributing.md](docs/contributing.md).
EOF
  ok "Created README.md"
else
  ok "README.md already exists — skipping"
fi

# ── .env.example ───────────────────────────────────────────────────────────
if [[ ! -f ".env.example" ]]; then
cat > ".env.example" << 'EOF'
# backuper configuration
# Copy this file to .env and adjust values as needed.
# Variables here are loaded automatically by lib/common.sh.

# ── Backup output directory ────────────────────────────────────────────────
# Where backup packages are written.
# Default: <repo_root>/backups
#
# CENTRAL_BACKUP_DIR=/mnt/backup/backuper

# ── Dockge stacks directory ────────────────────────────────────────────────
# The directory where Dockge stores its compose stacks.
# Default: /opt/stacks
#
# DOCKGE_STACKS_DIR=/opt/stacks

# ── Bind-mount copy mode ───────────────────────────────────────────────────
# Controls how bind-mounted host directories are handled during backup.
#   prompt     — ask for each large mount (default)
#   copy-all   — copy every mount without asking
#   reject-all — skip all mounts (config files only)
#
# MOUNT_MODE=prompt
EOF
  ok "Created .env.example"
else
  ok ".env.example already exists — skipping"
fi

# ── docs/restore.md ────────────────────────────────────────────────────────
if [[ ! -f "docs/restore.md" ]]; then
cat > "docs/restore.md" << 'EOF'
# Restore Guide

Each backup package produced by `backup.sh` is fully self-contained.
Restoring a service requires no knowledge of the original system layout.

## Restore a single service

```bash
cd backups/split_stacks/players__jellyfin
sudo ./restore.sh
```

## Override the stacks directory

If restoring to a different machine where Dockge stacks live elsewhere:

```bash
DOCKGE_STACKS_DIR=/mnt/new-server/stacks sudo ./restore.sh
```

## Restore a full multi-service stack

Run each service's `restore.sh` independently. All scripts target the
same `compose.yaml` and each one merges its piece. Order does not matter.

```bash
sudo ./qbittorrentvpn__radarr/restore.sh
sudo ./qbittorrentvpn__sonarr/restore.sh
sudo ./qbittorrentvpn__bazarr/restore.sh

cd /opt/stacks/qbittorrentvpn && docker compose up -d
```

## What restore.sh does

1. Creates `$DOCKGE_STACKS_DIR/<stack>/` if it does not exist
2. Creates a bare `compose.yaml` if the file does not exist
3. Merges the service block into `compose.yaml` (skips if already present)
4. Merges network definitions (skips existing)
5. Merges volume definitions (skips existing)
6. Merges `.env` variables (appends missing keys, skips existing)
7. Restores bind-mount data back to original host paths

All merge operations are append-only and duplicate-safe.

---

For full details see [docs/backup.md](backup.md).
EOF
  ok "Created docs/restore.md"
fi

# ── docs/setup.md ──────────────────────────────────────────────────────────
if [[ ! -f "docs/setup.md" ]]; then
cat > "docs/setup.md" << 'EOF'
# Setup Guide

`setup.sh` provisions a fresh Linux host with everything backuper needs.
Run it once on a new machine. It is safe to re-run — each script checks
whether its target is already installed before doing anything.

## Usage

```bash
./setup.sh                        # install everything
./setup.sh --dry-run              # show what would happen
./setup.sh --exclude 03-cockpit-install.sh  # skip Cockpit
```

## What gets installed

| Script | Installs |
|--------|----------|
| `00-install-deps.sh` | curl, wget, jq, whiptail, Docker Compose plugin |
| `01-install-yq.sh` | yq v4 binary to /usr/local/bin |
| `03-cockpit-install.sh` | Cockpit web console + selected modules (interactive TUI) |
| `04-install-docker.sh` | Docker Engine + Compose plugin, adds user to docker group |
| `05-install-dockge.sh` | Dockge container manager via Docker Compose |

## Supported distributions

apt (Debian/Ubuntu), dnf (Fedora), yum (RHEL/CentOS), pacman (Arch), apk (Alpine).
EOF
  ok "Created docs/setup.md"
fi

# ── docs/contributing.md ───────────────────────────────────────────────────
if [[ ! -f "docs/contributing.md" ]]; then
cat > "docs/contributing.md" << 'EOF'
# Contributing

## Guardrails — rules for every new file

1. **New public commands go in `bin/` only.**
   If a user is meant to run it, it gets a `bin/` entry. Do not add more
   root-level `*.sh` entrypoints beyond `setup.sh` and `backup.sh`.

2. **New shared functions go in `lib/common.sh`.**
   If the same logic appears in two scripts, it belongs in `lib/`.
   Never duplicate logging, pkg-manager detection, or Docker helpers
   inside a step script.

3. **New pipeline steps go in `modules/<module>/steps/` with a number prefix.**
   The number controls execution order. Leave gaps (01, 03, 05) so new
   steps can be inserted without renumbering existing ones. Steps must
   accept explicit positional arguments — not rely on unset globals.

4. **Data files go in `modules/<module>/data/`.**
   `.txt`, `.yaml`, `.json` lookup or config files must not live alongside
   executable `.sh` files.

5. **New backup domains get their own module under `modules/`.**
   Don't add "phase N" — add `modules/database/`, `modules/volumes/`, etc.
   Each module gets `run.sh` + `steps/` + `data/`.

6. **Deprecated code goes in `deprecated/<name>/` with a `README.md`**
   explaining why it is deprecated and what supersedes it. Never delete
   deprecated code without a release note.

7. **Never put spaces in directory or file names.**
   The shell quoting cost is never worth it.

8. **Misspellings in directory names are bugs, not style.**
   Check spelling before committing any new path.

9. **Every `source` path uses `SCRIPT_DIR` resolution.**
   Always resolve: `SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"`
   Never hardcode relative paths like `source ../../lib/common.sh`.

10. **`lib/` files are sourced, never executed directly.**
    Files in `lib/` have no standalone execution path. They are always
    loaded via `source`.

## Code style

- `set -euo pipefail` at the top of every script
- Use `info`, `ok`, `warn`, `die` from `lib/common.sh` for all output
- Use `require_cmd <name>` to assert a dependency exists
- Prefer `[[ ]]` over `[ ]` for conditionals
- Quote every variable: `"$VAR"`, not `$VAR`
EOF
  ok "Created docs/contributing.md"
fi

# ── deprecated/immich-backuper/README.md ───────────────────────────────────
if [[ ! -f "deprecated/immich-backuper/README.md" ]]; then
cat > "deprecated/immich-backuper/README.md" << 'EOF'
# DEPRECATED: Immich Backuper

> **Do not use this module for new deployments.**

This module was superseded by the generic backup pipeline in `modules/backup/`.
Immich services (immich-server, immich-microservices, postgres, redis) are
fully handled by `backup.sh` as of the Option B restructure — no special-casing
needed.

The root-level `phase2.sh` has been replaced with an exit-with-notice stub.
Use `./backup.sh` instead.

This directory is preserved for historical reference only and will be removed
in a future major version.

## What it did

1. Auto-detected the Immich compose stack under `/opt/stacks`
2. Dumped the PostgreSQL database via `pg_dumpall`
3. Wrote a manifest of backed-up files
4. Consolidated everything into a single output folder
5. Generated a restore script

All of this is now handled generically by `modules/backup/` for every
Docker Compose service, including Immich.
EOF
  ok "Created deprecated/immich-backuper/README.md"
fi

# ── tests/.gitkeep ─────────────────────────────────────────────────────────
touch "tests/.gitkeep"
ok "Created tests/.gitkeep"

# =============================================================================
# STEP 11 — Ensure all scripts are executable
# =============================================================================
header "STEP 11 — Set executable bits"

find modules/ deprecated/ bin/ lib/ -name "*.sh" -exec chmod +x {} \;
chmod +x bin/setup bin/backup setup.sh backup.sh phase0.sh phase1.sh phase2.sh
ok "chmod +x applied to all scripts"

# =============================================================================
# STEP 12 — Verification
# =============================================================================
header "STEP 12 — Verification"

PASS=0; FAIL=0
check() {
  local label="$1" path="$2" kind="${3:-f}"
  if [[ "$kind" == "f" && -f "$path" ]]; then
    ok "$label → $path"
    ((PASS++)) || true
  elif [[ "$kind" == "d" && -d "$path" ]]; then
    ok "$label → $path"
    ((PASS++)) || true
  elif [[ "$kind" == "x" && -x "$path" ]]; then
    ok "$label → $path (executable)"
    ((PASS++)) || true
  else
    warn "MISSING: $label → $path"
    ((FAIL++)) || true
  fi
}

check "setup.sh entrypoint"                 "setup.sh"                          x
check "backup.sh entrypoint"                "backup.sh"                         x
check "bin/setup"                           "bin/setup"                         x
check "bin/backup"                          "bin/backup"                        x
check "lib/common.sh"                       "lib/common.sh"                     f
check "lib/runner.sh"                       "lib/runner.sh"                     f
check "modules/setup dir"                   "modules/setup"                     d
check "modules/backup/run.sh"               "modules/backup/run.sh"             f
check "modules/backup/steps dir"            "modules/backup/steps"              d
check "modules/backup/data dir"             "modules/backup/data"               d
check "known-config-mounts.txt"             "modules/backup/data/known-config-mounts.txt" f
check "step 01-discover-stacks.sh"          "modules/backup/steps/01-discover-stacks.sh" f
check "step 06-copy-bind-mounts.sh"         "modules/backup/steps/06-copy-bind-mounts.sh" f
check "docs/backup.md"                      "docs/backup.md"                    f
check "docs/restore.md"                     "docs/restore.md"                   f
check "docs/setup.md"                       "docs/setup.md"                     f
check "docs/contributing.md"               "docs/contributing.md"              f
check "deprecated/immich-backuper/README.md" "deprecated/immich-backuper/README.md" f
check "deprecated/immich-backuper/run.sh"   "deprecated/immich-backuper/run.sh" f
check "README.md"                           "README.md"                         f
check ".env.example"                        ".env.example"                      f
check "tests/.gitkeep"                      "tests/.gitkeep"                    f
check "phase0.sh shim"                      "phase0.sh"                         f
check "phase1.sh shim"                      "phase1.sh"                         f

# Verify old messy dirs are no longer the canonical home
echo
if [[ -d "phase-0-dependency installer" ]]; then
  warn "Old dir 'phase-0-dependency installer' still exists (original preserved — safe to delete manually)"
fi
if [[ -d "phase-1-backupers" ]]; then
  warn "Old dir 'phase-1-backupers' still exists (original preserved — safe to delete manually)"
fi
if [[ -d "phase-2--DEPRECIATED-immich-backuper" ]]; then
  warn "Old dir 'phase-2--DEPRECIATED-immich-backuper' still exists (original preserved — safe to delete manually)"
fi

# Spot-check a critical source path fix
if [[ -f "modules/setup/00-install-deps.sh" ]]; then
  if grep -q '../../lib/common.sh' "modules/setup/00-install-deps.sh"; then
    ok "Source path fix confirmed in modules/setup/00-install-deps.sh"
    ((PASS++)) || true
  else
    warn "Source path may not be fixed in modules/setup/00-install-deps.sh — check manually"
    ((FAIL++)) || true
  fi
fi

if [[ -f "modules/backup/steps/06-copy-bind-mounts.sh" ]]; then
  if grep -q '../data/known-config-mounts.txt' \
     "modules/backup/steps/06-copy-bind-mounts.sh"; then
    ok "known-config-mounts.txt path fix confirmed in 06-copy-bind-mounts.sh"
    ((PASS++)) || true
  else
    warn "known-config-mounts.txt path may not be fixed in 06-copy-bind-mounts.sh — check manually"
    ((FAIL++)) || true
  fi
fi

# =============================================================================
# Final summary
# =============================================================================
echo
echo -e "${BOLD}══════════════════════════════════════════${RESET}"
if [[ $FAIL -eq 0 ]]; then
  echo -e "${BOLD}${GREEN}  Migration complete! ${PASS} checks passed.${RESET}"
else
  echo -e "${BOLD}${YELLOW}  Migration done with warnings.${RESET}"
  echo -e "  ${GREEN}Passed: $PASS${RESET}  ${YELLOW}Warnings: $FAIL${RESET}"
  echo -e "  Review the warnings above before committing."
fi
echo -e "${BOLD}══════════════════════════════════════════${RESET}"
echo
echo -e "  Old directories (originals) are ${YELLOW}preserved${RESET} — delete them when happy:"
echo -e "    ${YELLOW}rm -rf 'phase-0-dependency installer' phase-1-backupers \\"${RESET}
echo -e "    ${YELLOW}    phase-2--DEPRECIATED-immich-backuper lib/run_phase.sh${RESET}"
echo -e "    ${YELLOW}    phase0.sh.bak phase1.sh.bak phase2.sh.bak${RESET}"
echo

