# Phase 1 — Stack Extraction & Backup

Phase 1 is the core backup engine of the backuper repo. It reads every stack managed by Dockge, splits each stack into individual service-level packages, copies all bind-mounted host data into those packages, and bakes a one-click `restore.sh` into every output folder so each service is self-contained and independently recoverable.

---

## How It Fits Into the Repo

```
backuper/
├── phase0.sh          ← run first: installs deps, Docker, Dockge
├── phase1.sh          ← run this for backups  (calls phase-1/orchestrator.sh)
├── phase2.sh          ← run after: Immich-specific database + media backup
├── lib/
│   ├── common.sh      ← shared logging, env loading, pkg helpers
│   └── run_phase.sh   ← generic phase runner (discovers + executes *.sh in order)
└── phase-1/           ← everything described in this document
```

`phase1.sh` at the repo root sources `lib/run_phase.sh` and calls `phase-1/orchestrator.sh`, forwarding `--output $CENTRAL_BACKUP_DIR/split_stacks` automatically. The `CENTRAL_BACKUP_DIR` variable defaults to `<repo_root>/backups` unless overridden.

---

## Directory Layout

```
phase-1/
├── orchestrator.sh              ← the only entry point you run
└── tasks/
    ├── 01-discover-stacks.sh    ← find all valid Dockge stack folders
    ├── 02-extract-services.sh   ← list every service in a compose file
    ├── 03-create-service-compose.sh  ← build a standalone compose for one service
    ├── 04-extract-env.sh        ← filter .env down to only used variables
    ├── 05-write-metadata.sh     ← write .stack-meta provenance file
    ├── 06-copy-bind-mounts.sh   ← copy host-side bind mount directories
    ├── 07-write-restore.sh      ← generate restore.sh inside the output folder
    ├── 08-copy-dir.sh           ← low-level copy helper with fallback chain
    └── known-config-mounts.txt  ← list of mount names that are always copied
```

Task scripts live in `tasks/` and are never run directly. Only `orchestrator.sh` calls them.

---

## Running Phase 1

```bash
# Standard run — from the repo root
./phase1.sh

# All flags are forwarded through phase1.sh to orchestrator.sh:
./phase1.sh --copy-all      # copy all bind mounts without prompting
./phase1.sh --reject-all    # skip all bind mounts (config files only)
./phase1.sh --dry-run       # print what would happen, write nothing

# Run orchestrator directly (supports --force flag)
./phase-1/orchestrator.sh --force --reject-all
./phase-1/orchestrator.sh --stacks-dir /opt/stacks --output /mnt/backup/split_stacks
```

### All Available Flags

| Flag | Description |
|------|-------------|
| `--stacks-dir <path>` | Dockge stacks directory. Default: `/opt/stacks` |
| `--output <path>` | Where to write backup folders. Default: `<repo>/backups/split_stacks` |
| `--dry-run` | Print actions without writing anything |
| `--force` | Overwrite existing output folders |
| `--copy-all` | Copy every bind mount without prompting |
| `--reject-all` | Skip all bind mounts (only copies compose + env + metadata) |

---

## Execution Flow

The orchestrator runs four clearly labelled steps. Each step delegates to one or more task scripts — there is no logic hidden inside functions.

```
STEP 1  01-discover-stacks.sh
        └─ scan /opt/stacks, print every folder that has a compose.yaml

STEP 2  For each stack × each service:
        ├─ 02-extract-services.sh      parse compose, list service names
        ├─ 03-create-service-compose.sh  write standalone docker-compose.yml
        ├─ 04-extract-env.sh           write filtered .env
        ├─ 05-write-metadata.sh        write .stack-meta
        └─ 07-write-restore.sh         generate restore.sh

STEP 3  For each output folder:
        └─ 06-copy-bind-mounts.sh      copy host bind-mount directories
               └─ 08-copy-dir.sh       (called per-mount, handles edge cases)

STEP 4  Print summary
```

Steps 2 and 3 are separated intentionally. All compose/env/metadata files are written first so that step 3 can read them when resolving environment variable paths in volume definitions.

---

## Task Scripts — What Each One Does

### `01-discover-stacks.sh`
**Input:** `<stacks_dir>`  
**Output:** one absolute path per line to stdout

Walks `<stacks_dir>` one level deep. Prints any subfolder that contains a `compose.yaml`. Folders without a compose file are silently skipped. Output is sorted alphabetically.

```bash
# Example output
/opt/stacks/immich
/opt/stacks/players
/opt/stacks/qbittorrentvpn
```

---

### `02-extract-services.sh`
**Input:** `<compose_file>`  
**Output:** one service name per line to stdout

Parses the `services:` block of a compose file using `yq` and prints each key. If the compose has no services block it prints a warning to stderr and exits cleanly.

```bash
# Example output for /opt/stacks/players/compose.yaml
jellyfin
jellyplex-watched
```

---

### `03-create-service-compose.sh`
**Input:** `<compose_file> <service> <output_dir> <dry_run> <force>`  
**Output:** folder basename to stdout (fd3), all logging to stderr

Creates `<output_dir>/<stack>__<service>/docker-compose.yml` containing only the named service, plus any networks and named volumes that service references.

**Network handling:** Detects whether the service's network list uses sequence style (`- media_network`) or map style (`media_network: {aliases: [...]}`). If a network definition exists in the source compose it is copied exactly. If it is missing (implicitly created by Docker), `driver: bridge` is written as a safe default so `docker compose` never rejects the output file.

**Volume handling:** Named volumes (e.g. `pgdata`) are copied from the source if defined, or written as `null` so Docker creates them on first start. Bind mounts (`/path/on/host:/path/in/container`) are left as-is in the compose — their data is handled by `06-copy-bind-mounts.sh` later.

**Prints the folder name to fd3**, not stdout, because the orchestrator redirects stdout to stderr for all task scripts and only reads fd3 for the return value.

---

### `04-extract-env.sh`
**Input:** `<out_dir> <env_file>`  
**Output:** `<out_dir>/.env`

Scans the already-written `docker-compose.yml` in `<out_dir>` for every `${VAR}` or `$VAR` reference, then filters the stack's `.env` to only the matching keys. Comments directly above a matched key are preserved. Variables that exist in the `.env` but are not referenced by this service are dropped.

This means each service's `.env` is self-contained — it has exactly what it needs and nothing from unrelated services.

---

### `05-write-metadata.sh`
**Input:** `<out_dir> <stack_dir> <service>`  
**Output:** `<out_dir>/.stack-meta`

Writes a plain key=value provenance file:

```
SOURCE_STACK=players
SOURCE_FILE=/opt/stacks/players/compose.yaml
SOURCE_ENV=/opt/stacks/players/.env
SERVICE_NAME=jellyfin
EXTRACTED_AT=2026-06-08T00:15:00Z
```

This file is read by `06-copy-bind-mounts.sh` to resolve the original stack directory (needed for relative paths in volumes), and by `07-write-restore.sh` to know where to restore back to.

---

### `06-copy-bind-mounts.sh`
**Input:** `<service_dir> [prompt|copy-all|reject-all]`

Reads the service's `docker-compose.yml`, expands environment variables in volume paths (loading both the service `.env` and the original stack `.env`), and copies each bind-mounted host directory into the output folder.

**Decision logic per mount:**

| Priority | Condition | Action |
|----------|-----------|--------|
| 1 | Mount name is in `known-config-mounts.txt` | Always copy |
| 2 | `--copy-all` flag | Always copy |
| 3 | `--reject-all` flag | Always skip |
| 4 | Mount is under 50 MB | Always copy |
| 5 | None of the above | Prompt `[y/N]` |

**Destination naming:** The container-side path basename is used as the folder name inside the output dir (e.g. `/config` → `config/`). If that name already exists, the service name is prepended to avoid collisions (e.g. `jellyfin__config/`).

**Copy fallback chain** (handled by `08-copy-dir.sh`):
1. `cp -a` — full archive with metadata
2. `cp -r` — data only (NTFS/WSL destinations that reject metadata)
3. `sudo cp -r` — permission-denied files owned by containers

---

### `07-write-restore.sh`
**Input:** `<service_dir> <dockge_stacks_dir>`  
**Output:** `<service_dir>/restore.sh` (executable)

Generates a fully self-contained `restore.sh` script **inside the output folder**. The generated script is baked with the stack name, service name, and original stacks directory at generation time — no arguments needed when running it later.

The generated `restore.sh` performs these steps when executed:

1. Create `$DOCKGE_STACKS_DIR/<SOURCE_STACK>/` if it does not exist
2. Create `compose.yaml` with a bare `services:` header if the file does not exist
3. Merge the service block into `compose.yaml` — skips if already present
4. Merge top-level network definitions — skips existing ones
5. Merge top-level volume definitions — skips existing ones
6. Merge `.env` variables into the stack `.env` — appends missing keys, skips existing ones
7. Restore bind-mount data back to original host paths using `cp -rf` (brute-force overwrite)

Steps 3–6 are append-only and duplicate-safe. Running multiple `restore.sh` scripts from the same stack in any order rebuilds the full stack incrementally without overwriting or duplicating anything.

---

### `08-copy-dir.sh`
**Input:** `<src> <dst>`

Low-level copy utility used by `06-copy-bind-mounts.sh`. Tries three copy strategies in order and always exits 0 — failures are warnings, never fatal:

1. `cp -a` — preserves all metadata
2. `cp -r` — data only, for NTFS/WSL destinations
3. `sudo cp -r` — for container-owned files with restrictive permissions

---

### `known-config-mounts.txt`

A plain text list of container-side mount basenames that are always copied without prompting. One name per line, `#` comments allowed. Case-insensitive. Includes common names like `config`, `data`, `cache`, `appdata`, and well-known app-specific names (`grafana-data`, `vaultwarden-data`, etc.).

Add any custom mount names here to have them automatically included in every backup without being asked.

---

## Output Structure

After a successful run, the output directory looks like this:

```
backups/split_stacks/
├── players__jellyfin/
│   ├── docker-compose.yml    ← standalone compose for jellyfin only
│   ├── .env                  ← only CONTAINERS_ROOT, TV_STORAGE, etc. — nothing else
│   ├── .stack-meta           ← provenance: stack name, paths, timestamp
│   ├── restore.sh            ← one-click restore script (executable)
│   ├── config/               ← /mnt/int/_containers/Jellyfin-neo/config
│   └── cache/                ← /mnt/int/.tmps/Jellyfin-neo/cache
│
├── players__jellyplex-watched/
│   ├── docker-compose.yml
│   ├── .env
│   ├── .stack-meta
│   ├── restore.sh
│   └── config/               ← /mnt/int/_containers/jellyplex/config
│
├── qbittorrentvpn__radarr/
│   ├── docker-compose.yml
│   ├── .env
│   ├── .stack-meta
│   ├── restore.sh
│   └── config/               ← /mnt/int/_containers/mediarr/radarr/config
│
└── qbittorrentvpn__sonarr/
    ├── docker-compose.yml
    ├── .env
    ├── .stack-meta
    ├── restore.sh
    └── config/
```

### File Descriptions Per Output Folder

| File | What it contains |
|------|-----------------|
| `docker-compose.yml` | Single-service compose with networks and volumes merged from the source stack |
| `.env` | Only the variables this service references — nothing from other services |
| `.stack-meta` | Source stack name, original compose path, service name, extraction timestamp |
| `restore.sh` | Generated restore script — run with `sudo ./restore.sh` |
| `<mount_name>/` | Contents of a bind-mounted host directory |

---

## Restore Flow

Each output folder is a complete, self-contained unit. To restore a service:

```bash
cd backups/split_stacks/players__jellyfin
sudo ./restore.sh
```

### What restore.sh does

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Restoring: jellyfin → /opt/stacks/players
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Created new compose.yaml
  ✔ Merging service: jellyfin
  ✔ Merging network: media_network
  ✔ Appending env var: CONTAINERS_ROOT
  ✔ Appending env var: TV_STORAGE
  ✔ Appending env var: MOVIES_STORAGE
  Restoring bind-mount data...
  ✔ Restoring: ./config → /mnt/int/_containers/Jellyfin-neo/config
  ✔ Restoring: ./cache  → /mnt/int/.tmps/Jellyfin-neo/cache

✅ Restore complete: jellyfin
   Compose : /opt/stacks/players/compose.yaml
   Env     : /opt/stacks/players/.env

   Start with: cd /opt/stacks/players && docker compose up -d
```

### Restoring a full multi-service stack

When a stack had multiple services (e.g. `qbittorrentvpn` with 7 services), run each `restore.sh` independently. They all target the same `compose.yaml` and each one merges its piece. Order does not matter — duplicate-checking ensures nothing is written twice.

```bash
sudo ./qbittorrentvpn__radarr/restore.sh
sudo ./qbittorrentvpn__sonarr/restore.sh
sudo ./qbittorrentvpn__bazarr/restore.sh
# ... etc

cd /opt/stacks/qbittorrentvpn && docker compose up -d
```

### Overriding the stacks directory

If restoring to a different machine where stacks live elsewhere:

```bash
DOCKGE_STACKS_DIR=/mnt/new-server/stacks sudo ./restore.sh
```

---

## Notes on Design Decisions

**Why separate task scripts instead of one big script?**  
Each task has one job, one set of inputs, and one output. They can be tested in isolation, called from other scripts, or replaced without touching anything else. The orchestrator reads like a checklist — the complexity lives in the tasks, not the glue.

**Why is `03` printing to fd3?**  
The orchestrator captures the output folder name with `$(bash "$T/03...")`. If `03` also printed log messages to stdout they would be captured instead of going to the terminal. Redirecting stdout to stderr at the top of `03` and using fd3 for the actual return value keeps both behaviours clean.

**Why does `restore.sh` use `sudo ./restore.sh` instead of internal sudo?**  
`/opt/stacks` is owned by root on most systems. Running the whole script as root is simpler and more reliable than trying to selectively elevate. The script uses `cp -rf` so all data is overwritten unconditionally — this is a restore point, not a recovery merge.

**Why `driver: bridge` as the network default?**  
When a network is referenced by a service but has no top-level definition in the source compose, Docker creates it automatically at runtime. Omitting the top-level block entirely causes `docker compose` to reject the file with "undefined network" errors. Writing `driver: bridge` produces valid YAML that Docker accepts and behaves identically to the implicit default.
