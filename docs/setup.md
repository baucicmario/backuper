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
