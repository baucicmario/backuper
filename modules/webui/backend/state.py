import threading
import os

# Global lock for configuration access
config_lock = threading.Lock()

# Application configuration state
config = {
    "backup_dir": "",
    "stacks_dir": "",
}

# Lock for managing the primary backup job state
job_lock = threading.Lock()

# Current status of the backup operation
job = {
    "running": False,
    "log": [],
    "exit_code": None,
    "started": None,
    "prompt": None
}

# The active subprocess for the backup/restore job (used for stdin interaction)
active_process = None

# Lock for managing the restoration job state
restore_lock = threading.Lock()

# Current status of the batch restoration process
restore_job = {
    "running": False, 
    "restore_id": 0,
    "progress": 0, 
    "total": 0, 
    "current": "", 
    "phase": "idle",
    "sub_progress": 0, 
    "sub_total": 0,
    "sub_current_file": "",
    "results": [], 
    "exit_code": None
}
