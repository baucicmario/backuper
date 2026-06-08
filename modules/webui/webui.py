#!/usr/bin/env python3
"""
webui.py — Entry point for the Backuper Web UI.
"""
import os
from backend import state, server, tasks

# Initialize global configuration from environment variables
SCRIPT_DIR = os.path.dirname(os.path.realpath(__file__))
with state.config_lock:
    state.config["backup_dir"] = os.environ.get(
        "CENTRAL_BACKUP_DIR",
        os.path.normpath(os.path.join(SCRIPT_DIR, "..", "..", "backups"))
    )
    state.config["stacks_dir"] = os.environ.get("DOCKGE_STACKS_DIR", "/opt/stacks")

if __name__ == "__main__":
    # Check if the backup script is where it should be
    if not os.path.isfile(tasks.BACKUP_SH):
        print(f"WARNING: backup.sh not found at {tasks.BACKUP_SH}")
    else:
        print(f"backup.sh found: {tasks.BACKUP_SH}")
    
    # Start the web server
    server.start_server()
