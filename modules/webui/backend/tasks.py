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
            "started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "prompt": None
        })
        state.active_process = None
    
    cmd = ["bash", BACKUP_SH] + extra_args
    env = {**os.environ, "TERM": "xterm-256color", "NONINTERACTIVE": "1", **env_overrides}
    
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                stdin=subprocess.PIPE, text=True, bufsize=1, env=env)
        with state.job_lock:
            state.active_process = proc

        buf = ""
        while True:
            char = proc.stdout.read(1)
            if not char:
                if buf:
                    with state.job_lock:
                        state.job["log"].append(buf.rstrip("\n"))
                break
            buf += char
            if char == '\n':
                with state.job_lock:
                    state.job["log"].append(buf.rstrip("\n"))
                buf = ""
            elif buf.endswith("[y/N] "):
                with state.job_lock:
                    context = state.job["log"][-3:] if len(state.job["log"]) >= 3 else []
                    prompt_data = {
                        "text": buf.strip(),
                        "context": context
                    }
                    state.job["prompt"] = prompt_data
                    state.job["log"].append(buf)
                buf = ""

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
            state.active_process = None




def run_restore(selected, backup_dir, split_dir):
    """
    Executes a batch restoration of selected archives using the Bash CLI.
    """
    import re
    total = len(selected)
    
    with state.job_lock:
        state.job["log"].append(f"[DEBUG] Starting batch restore of {total} archives via Bash")
    
    with state.restore_lock:
        state.restore_job.update({
            "current": "Initializing...", 
            "progress": 0, 
            "phase": "starting",
            "sub_progress": 0, 
            "sub_total": 100,
            "sub_current_file": "Initializing..."
        })
        
    # Isolate only the selected archives in split_dir
    os.makedirs(split_dir, exist_ok=True)
    to_restore = []
    for f in selected:
        p_split = os.path.join(split_dir, f)
        p_backup = os.path.join(backup_dir, f)
        if os.path.exists(p_split):
            to_restore.append(p_split)
        elif os.path.exists(p_backup):
            try:
                os.link(p_backup, p_split)
            except Exception:
                shutil.copy2(p_backup, p_split)
            to_restore.append(p_split)
            
    # Delete anything in split_dir that is not selected
    for fname in os.listdir(split_dir):
        p = os.path.join(split_dir, fname)
        if p not in to_restore:
            try:
                if os.path.isfile(p) or os.path.islink(p): os.remove(p)
                elif os.path.isdir(p): shutil.rmtree(p)
            except Exception: pass
        
    cmd = ["bash", os.path.normpath(os.path.join(SCRIPT_DIR, "..", "..", "..", "restore.sh")), 
           split_dir, "--select-all", "--work-dir", split_dir, "--no-prompts"]
           
    env = {**os.environ, "TERM": "xterm-256color", "NONINTERACTIVE": "1"}
           
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, 
                                stdin=subprocess.PIPE, text=True, bufsize=1, env=env)
                                
        re_archive = re.compile(r"Archive (\d+) of (\d+)")
        re_extracting = re.compile(r"Extracting:\s+(.+)")
        re_pv = re.compile(r"(\d+)%")
        
        results = []
        buf = ""
        
        while True:
            char = proc.stdout.read(1)
            if not char:
                if buf:
                    with state.job_lock: state.job["log"].append(buf.rstrip("\r\n"))
                break
                
            buf += char
            
            if char == '\n' or char == '\r':
                line = buf.rstrip("\r\n")
                buf = ""
                if not line: continue
                
                m_pv = re_pv.search(line)
                is_pv = bool(m_pv) or "MiB/s" in line or "ETA" in line
                
                if not is_pv:
                    with state.job_lock:
                        state.job["log"].append(line)
                        
                with state.restore_lock:
                    m_arch = re_archive.search(line)
                    if m_arch:
                        state.restore_job["progress"] = int(m_arch.group(1)) - 1
                        state.restore_job["phase"] = "extracting"
                        state.restore_job["sub_progress"] = 0
                        state.restore_job["sub_total"] = 100
                        continue
                        
                    m_ext = re_extracting.search(line)
                    if m_ext:
                        state.restore_job["sub_current_file"] = m_ext.group(1).strip()
                        state.restore_job["phase"] = "extracting"
                        continue
                        
                    if "Running restore script" in line:
                        state.restore_job["phase"] = "restoring"
                        state.restore_job["sub_progress"] = 50
                        state.restore_job["sub_current_file"] = "Executing restore.sh"
                        continue
                        
                    if "✔" in line or "restored:" in line.lower():
                        results.append(line.replace("✔", "").strip())
                    elif "✖" in line or "failed:" in line.lower():
                        results.append("Error: " + line.replace("✖", "").strip())
                        
                    if is_pv and m_pv:
                        state.restore_job["sub_progress"] = int(m_pv.group(1))

        proc.wait()
        with state.restore_lock:
            state.restore_job.update({
                "running": False, "progress": total, "current": "Done",
                "phase": "complete", "results": results, "exit_code": proc.returncode
            })
            
    except Exception as e:
        with state.job_lock:
            state.job["log"].append(f"[DEBUG] Error during batch restore: {str(e)}")
        with state.restore_lock:
            state.restore_job.update({
                "running": False, "progress": total, "current": "Error",
                "phase": "complete", "results": [f"Fatal Error: {str(e)}"], "exit_code": 1
            })
