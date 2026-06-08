import os
import subprocess
import time
import tarfile
import shutil
from . import state

# Path to the backup execution script
SCRIPT_DIR = os.path.dirname(os.path.realpath(__file__))
BACKUP_SH = os.path.normpath(os.path.join(SCRIPT_DIR, "..", "..", "..", "backup.sh"))

def run_backup(extra_args):
    """
    Executes the backup process as a background subprocess.
    """
    with state.config_lock:
        env_overrides = {
            "CENTRAL_BACKUP_DIR": state.config["backup_dir"],
            "DOCKGE_STACKS_DIR":  state.config["stacks_dir"],
        }
    
    with state.job_lock:
        state.job.update({
            "running": True, 
            "log": [], 
            "exit_code": None,
            "started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        })
    
    cmd = ["bash", BACKUP_SH] + extra_args
    env = {**os.environ, "TERM": "xterm-256color", **env_overrides}
    
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, bufsize=1, env=env)
        for line in proc.stdout:
            with state.job_lock:
                state.job["log"].append(line.rstrip("\n"))
        proc.wait()
        with state.job_lock:
            state.job["exit_code"] = proc.returncode
    except Exception as e:
        with state.job_lock:
            state.job["log"].append(f"ERROR: {e}")
            state.job["exit_code"] = 1
    finally:
        with state.job_lock:
            state.job["running"] = False


class ProgressWrapper:
    """
    Wraps a file object to track read progress for status reporting.
    """
    def __init__(self, fileobj):
        self.fileobj = fileobj
        self.pos = 0

    def read(self, size=-1):
        chunk = self.fileobj.read(size)
        if chunk:
            self.pos += len(chunk)
            with state.restore_lock:
                state.restore_job["sub_progress"] = self.pos
        return chunk
    
    def tell(self): return self.pos
    def seek(self, offset, whence=0): return self.fileobj.seek(offset, whence)
    def close(self): return self.fileobj.close()


def run_restore(selected, backup_dir, split_dir):
    """
    Executes a batch restoration of selected archives.
    """
    total = len(selected)
    
    with state.job_lock:
        state.job["log"].append(f"[DEBUG] Starting batch restore of {total} archives")
    
    results = []
    for i, filename in enumerate(selected):
        path = os.path.join(split_dir, filename)
        if not os.path.exists(path): 
            results.append(f"Error: {filename} not found")
            continue

        compressed_size = os.path.getsize(path)
        with state.restore_lock:
            state.restore_job.update({
                "current": filename, 
                "progress": i, 
                "phase": "extracting",
                "sub_progress": 0, 
                "sub_total": max(1, compressed_size),
                "sub_current_file": "Opening archive..."
            })
        
        with state.job_lock:
            state.job["log"].append(f"[DEBUG] Extracting {filename} ({compressed_size / (1024*1024):.1f}MB)")
            
        try:
            folder_name = filename.replace(".tar.gz", "")
            target_folder = os.path.join(split_dir, folder_name)
            os.makedirs(target_folder, exist_ok=True)
            
            with open(path, "rb") as f_raw:
                f_wrapped = ProgressWrapper(f_raw)
                with tarfile.open(fileobj=f_wrapped, mode="r:gz") as tar:
                    def track_progress(members):
                        for member in members:
                            with state.restore_lock:
                                state.restore_job["sub_current_file"] = member.name
                            yield member
                    tar.extractall(path=target_folder, members=track_progress(tar))
            
            with state.job_lock:
                state.job["log"].append(f"[DEBUG] Extraction of {filename} complete")
                
            os.remove(path)
            
            restore_script = None
            if os.path.exists(os.path.join(target_folder, "restore.sh")):
                restore_script = os.path.join(target_folder, "restore.sh")
            else:
                for root, dirs, files in os.walk(target_folder):
                    if "restore.sh" in files:
                        restore_script = os.path.join(root, "restore.sh")
                        break
            
            if restore_script:
                with state.restore_lock:
                    state.restore_job.update({
                        "phase": "restoring", 
                        "sub_progress": 0, 
                        "sub_total": 1,
                        "sub_current_file": "Executing restore.sh..."
                    })
                
                with state.job_lock:
                    state.job["log"].append(f"[DEBUG] Running restore script: {restore_script}")
                
                os.chmod(restore_script, 0o755)
                proc = subprocess.Popen(["bash", restore_script], 
                                        cwd=os.path.dirname(restore_script),
                                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, 
                                        text=True, bufsize=1)
                for line in proc.stdout:
                    l = line.rstrip("\n")
                    with state.job_lock: state.job["log"].append(l)
                proc.wait()
                with state.restore_lock: state.restore_job["sub_progress"] = 1
                results.append(f"Restored {folder_name}")
            else:
                results.append(f"Warning: No restore.sh for {folder_name}")

            # CLEANUP: Delete the folder we just restored
            if os.path.isdir(target_folder):
                with state.job_lock:
                    state.job["log"].append(f"[DEBUG] Cleaning up folder: {target_folder}")
                shutil.rmtree(target_folder)

        except Exception as e:
            with state.job_lock:
                state.job["log"].append(f"[DEBUG] Error restoring {filename}: {str(e)}")
            results.append(f"Error restoring {filename}: {str(e)}")

    with state.restore_lock:
        state.restore_job.update({
            "running": False, "progress": total, "current": "Done",
            "phase": "complete", "results": results, "exit_code": 0
        })
    
    with state.job_lock:
        state.job["log"].append("[DEBUG] Batch restore process finished")
