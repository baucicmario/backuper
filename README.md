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

3. **Web UI** (`webui.py`) — A modern, responsive web interface for managing backups,
   monitoring job status, and performing batch restorations.

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
- Python 3.7+ (for Web UI)
- `yq` v4, `jq`, `docker` with Compose plugin (installed by `setup.sh`)

---

## Quick start

### CLI Usage
```bash
# 1. Clone
git clone https://github.com/yourname/backuper.git
cd backuper

# 2. (First time) Install dependencies
./setup.sh

# 3. Run backup
./backup.sh

# 4. Restore a service
cd backups/split_stacks/players__jellyfin
sudo ./restore.sh
```

### Web UI Usage
```bash
# 1. Start the Web UI
python3 modules/webui/webui.py

# 2. Access in browser
# http://localhost:8099
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
| `./backup.sh --archive` | Pack each service dir into a `.tar.gz` (keeps source folder) |
| `./backup.sh --archive-replace` | Pack each service dir into a `.tar.gz` and remove source folder |

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
│   ├── backup/           ← backup engine (run.sh + steps/ + data/)
│   └── webui/            ← web management interface
│       ├── webui.py      ← entrypoint
│       ├── backend/      ← modular python package (server, tasks, state)
│       ├── static/       ← frontend assets (css, js)
│       └── templates/    ← html templates
├── docs/                 ← documentation
├── tests/                ← test scripts
└── deprecated/           ← archived modules (do not use)
```

---

## Contributing

See [docs/contributing.md](docs/contributing.md).
