#!/usr/bin/env python3
"""
webui.py — Minimal HTTP server for backuper.
"""
import os, subprocess, threading, time, json, stat, tarfile, io
import threading
import time
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
import socketserver

# Use ThreadingHTTPServer to handle multiple concurrent requests (e.g. SSE + Polling)
class ThreadingHTTPServer(socketserver.ThreadingMixIn, HTTPServer):
    daemon_threads = True
    # Optimization: avoid waiting for threads to finish on shutdown
    block_on_close = False

SCRIPT_DIR = os.path.dirname(os.path.realpath(__file__))
BACKUP_SH  = os.path.join(SCRIPT_DIR, "..", "..", "backup.sh")
PAGE_FILE  = os.path.join(SCRIPT_DIR, "page.html")
HOST       = os.environ.get("WEBUI_HOST", "0.0.0.0")
PORT       = int(os.environ.get("WEBUI_PORT", "8099"))
SECRET     = os.environ.get("WEBUI_SECRET", "")

_config_lock = threading.Lock()
_config = {
    "backup_dir": os.environ.get("CENTRAL_BACKUP_DIR",
                  os.path.normpath(os.path.join(SCRIPT_DIR, "..", "..", "backups"))),
    "stacks_dir": os.environ.get("DOCKGE_STACKS_DIR", "/opt/stacks"),
}

_lock = threading.Lock()
_job  = {"running": False, "log": [], "exit_code": None, "started": None}

_restore_lock = threading.Lock()
_restore_job = {
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


def _run_backup(extra_args):
    with _config_lock:
        env_overrides = {
            "CENTRAL_BACKUP_DIR": _config["backup_dir"],
            "DOCKGE_STACKS_DIR":  _config["stacks_dir"],
        }
    with _lock:
        _job.update({"running": True, "log": [], "exit_code": None,
                     "started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())})
    cmd = ["bash", BACKUP_SH] + extra_args
    env = {**os.environ, "TERM": "xterm-256color", **env_overrides}
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, bufsize=1, env=env)
        for line in proc.stdout:
            with _lock:
                _job["log"].append(line.rstrip("\n"))
        proc.wait()
        with _lock:
            _job["exit_code"] = proc.returncode
    except Exception as e:
        with _lock:
            _job["log"].append(f"ERROR: {e}")
            _job["exit_code"] = 1
    finally:
        with _lock:
            _job["running"] = False


class ProgressWrapper:
    def __init__(self, fileobj):
        self.fileobj = fileobj
        self.pos = 0
        self.last_report = 0
    def read(self, size=-1):
        chunk = self.fileobj.read(size)
        if chunk:
            self.pos += len(chunk)
            with _restore_lock:
                _restore_job["sub_progress"] = self.pos
            
            # Debug: Report to UI log every 5MB
            if self.pos - self.last_report > 5 * 1024 * 1024:
                self.last_report = self.pos
                with _lock:
                    _job["log"].append(f"[DEBUG] Extraction Progress: {self.pos / (1024*1024):.1f}MB")
        return chunk
    def tell(self): return self.pos
    def seek(self, offset, whence=0): return self.fileobj.seek(offset, whence)
    def close(self): return self.fileobj.close()


def _run_restore(selected, backup_dir, split_dir):
    total = len(selected)
    
    with _lock:
        _job["log"].append(f"[DEBUG] Starting batch restore of {total} archives")
    
    results = []
    for i, filename in enumerate(selected):
        path = os.path.join(split_dir, filename)
        if not os.path.exists(path): 
            results.append(f"Error: {filename} not found")
            continue

        compressed_size = os.path.getsize(path)
        with _restore_lock:
            _restore_job.update({
                "current": filename, 
                "progress": i, 
                "phase": "extracting",
                "sub_progress": 0, 
                "sub_total": max(1, compressed_size),
                "sub_current_file": "Opening archive..."
            })
        
        with _lock:
            _job["log"].append(f"[DEBUG] Extracting {filename} ({compressed_size / (1024*1024):.1f}MB)")
            
        try:
            folder_name = filename.replace(".tar.gz", "")
            target_folder = os.path.join(split_dir, folder_name)
            os.makedirs(target_folder, exist_ok=True)
            
            with open(path, "rb") as f_raw:
                f_wrapped = ProgressWrapper(f_raw)
                with tarfile.open(fileobj=f_wrapped, mode="r:gz") as tar:
                    def track_progress(members):
                        for member in members:
                            with _restore_lock:
                                _restore_job["sub_current_file"] = member.name
                                # f_wrapped.tell() will be updated during the actual read inside extractall
                            yield member

                    # Use the community-suggested generator approach
                    tar.extractall(path=target_folder, members=track_progress(tar))
            
            with _lock:
                _job["log"].append(f"[DEBUG] Extraction of {filename} complete")
                
            os.remove(path)
            
            # Find and run restore.sh
            restore_script = None
            if os.path.exists(os.path.join(target_folder, "restore.sh")):
                restore_script = os.path.join(target_folder, "restore.sh")
            else:
                for root, dirs, files in os.walk(target_folder):
                    if "restore.sh" in files:
                        restore_script = os.path.join(root, "restore.sh")
                        break
            
            if restore_script:
                with _restore_lock:
                    _restore_job.update({
                        "phase": "restoring", 
                        "sub_progress": 0, 
                        "sub_total": 1,
                        "sub_current_file": "Executing restore.sh..."
                    })
                
                with _lock:
                    _job["log"].append(f"[DEBUG] Running restore script: {restore_script}")
                
                os.chmod(restore_script, 0o755)
                proc = subprocess.Popen(["bash", restore_script], 
                                        cwd=os.path.dirname(restore_script),
                                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, 
                                        text=True, bufsize=1)
                for line in proc.stdout:
                    l = line.rstrip("\n")
                    # CRITICAL: Buffer FIRST, then print.
                    with _lock: 
                        _job["log"].append(l)
                    print(f"[{folder_name}] {l}")
                proc.wait()
                with _restore_lock: 
                    _restore_job["sub_progress"] = 1
                results.append(f"Restored {folder_name}")
            else:
                results.append(f"Warning: No restore.sh for {folder_name}")
        except Exception as e:
            with _lock:
                _job["log"].append(f"[DEBUG] Error restoring {filename}: {str(e)}")
            results.append(f"Error restoring {filename}: {str(e)}")

    with _restore_lock:
        _restore_job.update({
            "running": False, "progress": total, "current": "Done",
            "phase": "complete", "results": results, "exit_code": 0
        })
    
    with _lock:
        _job["log"].append("[DEBUG] Batch restore process finished")


def _ls_dir(path):
    path = os.path.realpath(path)
    if not os.path.isdir(path):
        return None, "Not a directory"
    entries = []
    try:
        for name in sorted(os.listdir(path)):
            full = os.path.join(path, name)
            try:
                if stat.S_ISDIR(os.stat(full).st_mode):
                    entries.append({"name": name, "path": full})
            except PermissionError:
                pass
    except PermissionError:
        return None, "Permission denied"
    return {"path": path, "parent": os.path.dirname(path), "entries": entries}, None


def _load_page():
    """Load HTML page from file at startup."""
    try:
        with open(PAGE_FILE, "r", encoding="utf-8") as f:
            return f.read()
    except Exception as e:
        print(f"ERROR: Could not load {PAGE_FILE}: {e}")
        return "<h1>Error loading page</h1>"


_page_content = _load_page()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(f"[{self.address_string()}] {fmt % args}")

    def _check_secret(self):
        if not SECRET: return True
        token = self.headers.get("X-Backuper-Token","")
        if not token:
            qs = urlparse(self.path).query
            token = dict(p.split("=",1) for p in qs.split("&") if "=" in p).get("token","")
        return token == SECRET

    def do_GET(self):
        p = urlparse(self.path).path
        if p in ("/","/index.html"): self._page()
        elif p == "/stream":         self._sse()
        elif p == "/status":         self._json_status()
        elif p == "/api/restore-status": self._json_restore_status()
        elif p == "/config":         self._get_config()
        elif p == "/ls":             self._ls()
        elif p == "/archives":         self._list_archives()
        elif p == "/download-all": self._download_all()
        elif p == "/style.css":  self._static("style.css", "text/css")
        elif p == "/app.js":     self._static("app.js",    "application/javascript")
        elif p.startswith("/download/"): self._download_file(p[len("/download/"):])
        else:                        self.send_error(404)

    def do_POST(self):
        p = urlparse(self.path).path
        if p == "/run":    self._start_run()
        elif p == "/config":      self._set_config()
        elif p == "/upload":      self._handle_upload()
        elif p == "/api/restore": self._handle_batch_restore()
        else:                       self.send_error(404)

    def _handle_batch_restore(self):
        if not self._check_secret(): self.send_error(403); return
        
        length = int(self.headers.get("Content-Length", 0))
        data = json.loads(self.rfile.read(length).decode()) if length else {}
        selected = data.get("archives", [])
        
        backup_dir = _config["backup_dir"]
        split_dir = os.path.join(backup_dir, "split_stacks")
        
        if not selected:
            if os.path.isdir(split_dir):
                selected = [f for f in os.listdir(split_dir) if f.endswith(".tar.gz")]
            else:
                selected = []

        if not selected:
            self._json({"ok": False, "error": "No archives to restore"}, 400)
            return

        with _restore_lock:
            if _restore_job["running"]:
                self._json({"ok": False, "error": "Restore already in progress"}, 409)
                return
            _restore_job.update({
                "running": True, "restore_id": int(time.time()), "progress": 0, "total": len(selected), 
                "current": "Preparing...", "phase": "starting", "sub_progress": 0, "sub_total": 0,
                "sub_current_file": "", "results": [], "exit_code": None
            })

        threading.Thread(target=_run_restore, args=(selected, backup_dir, split_dir), daemon=True).start()
        self._json({"ok": True, "message": "Restore started"})

    def _page(self):
        b = _page_content.encode()
        self.send_response(200)
        self.send_header("Content-Type","text/html; charset=utf-8")
        self.send_header("Content-Length", len(b))
        self.end_headers(); self.wfile.write(b)

    def _json(self, data, status=200):
        b = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type","application/json")
        self.send_header("Content-Length", len(b))
        self.end_headers(); self.wfile.write(b)

    def _json_status(self):
        with _lock:
            self._json({k: _job[k] for k in ("running","exit_code","started")})

    def _json_restore_status(self):
        with _restore_lock:
            self._json(_restore_job)

    def _get_config(self):
        with _config_lock:
            self._json(dict(_config))

    def _set_config(self):
        if not self._check_secret(): self.send_error(403); return
        length = int(self.headers.get("Content-Length",0))
        body = self.rfile.read(length).decode() if length else "{}"
        try: data = json.loads(body)
        except Exception: self._json({"ok":False,"error":"Invalid JSON"},400); return
        with _config_lock:
            if "backup_dir" in data: _config["backup_dir"] = data["backup_dir"]
            if "stacks_dir" in data: _config["stacks_dir"] = data["stacks_dir"]
        self._json({"ok": True})


    def _handle_upload(self):
        if not self._check_secret(): self.send_error(403); return
        qs = parse_qs(urlparse(self.path).query)
        filename = qs.get("filename", ["uploaded_archive.tar.gz"])[0]
        filename = os.path.basename(filename)
        
        length = int(self.headers.get("Content-Length", 0))
        if length == 0:
            self._json({"ok": False, "error": "Empty file received"}, 400)
            return
            
        with _config_lock:
            backup_dir = _config["backup_dir"]
            
        split_dir = os.path.join(backup_dir, "split_stacks")
        os.makedirs(split_dir, exist_ok=True)
        target_path = os.path.join(split_dir, filename)
        
        try:
            with open(target_path, 'wb') as f:
                bytes_read = 0
                while bytes_read < length:
                    chunk_size = min(65536, length - bytes_read)
                    chunk = self.rfile.read(chunk_size)
                    if not chunk: break
                    f.write(chunk)
                    bytes_read += len(chunk)
        except Exception as e:
            self._json({"ok": False, "error": f"Failed to save file: {str(e)}"}, 500)
            return

        try:
            is_bundle = False
            if tarfile.is_tarfile(target_path):
                with tarfile.open(target_path, "r:gz") as tar:
                    members = tar.getmembers()
                    top_levels = set()
                    for m in members:
                        parts = m.name.split('/')
                        if parts and parts[0]:
                            top_levels.add(parts[0])
                    
                    if len(top_levels) > 1:
                        is_bundle = True
                        tar.extractall(path=split_dir)
                
                if is_bundle:
                    os.remove(target_path)
                    self._json({"ok": True, "message": f"Extracted bundle: {filename}"})
                else:
                    self._json({"ok": True, "message": f"Saved individual archive: {filename}"})
            else:
                self._json({"ok": True, "message": f"Saved file: {filename}"})
        except Exception as e:
            self._json({"ok": False, "error": f"Processing failed: {str(e)}"}, 500)

    def _ls(self):
        qs = parse_qs(urlparse(self.path).query)
        path = qs.get("path", ["/"])[0]
        result, err = _ls_dir(path)
        self._json({"error": err} if err else result)

    def _sse(self):
        if not self._check_secret(): self.send_error(403); return
        qs = urlparse(self.path).query
        params = dict(p.split("=",1) for p in qs.split("&") if "=" in p)
        mode = params.get("mode", "run")
        
        if mode == "run":
            raw = params.get("flags","")
            extra = [f for f in raw.split() if f.startswith("--")] if raw else []
            with _lock:
                if _job["running"] or _restore_job["running"]: 
                    self.send_error(409,"Process already running"); return
            threading.Thread(target=_run_backup, args=(extra,), daemon=True).start()
        
        self.send_response(200)
        self.send_header("Content-Type","text/event-stream")
        self.send_header("Cache-Control","no-cache")
        self.send_header("X-Accel-Buffering","no")
        self.end_headers()
        
        sent_log = 0
        last_status_json = ""
        last_heartbeat = time.time()
        
        try:
            while True:
                now = time.time()
                # 1. Send all new log lines
                with _lock:
                    new_logs = _job["log"][sent_log:]
                for line in new_logs:
                    self.wfile.write(f"event: line\ndata: {json.dumps(line)}\n\n".encode())
                    sent_log += 1
                
                # 2. Send status update
                with _restore_lock:
                    status = dict(_restore_job)
                status_json = json.dumps(status)
                if status_json != last_status_json:
                    self.wfile.write(f"event: status\ndata: {status_json}\n\n".encode())
                    last_status_json = status_json
                
                # 3. Heartbeat to keep connection alive
                if now - last_heartbeat > 15:
                    self.wfile.write(b": heartbeat\n\n")
                    last_heartbeat = now

                self.wfile.flush()
                
                # 4. Check for completion
                with _lock:
                    with _restore_lock:
                        still_running = _job["running"] or _restore_job["running"]
                        has_more_logs = (len(_job["log"]) > sent_log)
                
                if not still_running and not has_more_logs:
                    # Send final status one last time to be sure
                    self.wfile.write(f"event: status\ndata: {status_json}\n\n".encode())
                    self.wfile.write(f"event: done\ndata: 0\n\n".encode())
                    self.wfile.flush()
                    break
                time.sleep(0.3)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _static(self, name, mime):
        path = os.path.join(SCRIPT_DIR, name)
        if not os.path.exists(path): self.send_error(404); return
        with open(path, "rb") as f: b = f.read()
        self.send_response(200)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", len(b))
        self.end_headers(); self.wfile.write(b)

    def _start_run(self):
        if not self._check_secret(): self.send_error(403); return
        length = int(self.headers.get("Content-Length",0))
        body = self.rfile.read(length).decode() if length else "{}"
        try: data = json.loads(body)
        except Exception: data = {}
        extra = [f for f in data.get("flags",[]) if f.startswith("--")]
        with _lock:
            if _job["running"]: self.send_error(409); return
        threading.Thread(target=_run_backup, args=(extra,), daemon=True).start()
        self._json({"status":"started"}, 202)

    def _list_archives(self):
        with _config_lock:
            backup_dir = _config["backup_dir"]
        split_dir = os.path.join(backup_dir, "split_stacks")
        results = []
        base = split_dir if os.path.isdir(split_dir) else backup_dir
        for fname in sorted(os.listdir(base)):
            if fname.endswith(".tar.gz"):
                fpath = os.path.join(base, fname)
                try:
                    size = os.path.getsize(fpath)
                    mtime = os.path.getmtime(fpath)
                    rel = os.path.relpath(fpath, backup_dir)
                    results.append({"name": fname, "rel": rel, "size": size, "mtime": mtime})
                except OSError: continue
        self._json({"archives": results, "backup_dir": backup_dir})

    def _download_file(self, rel_encoded):
        from urllib.parse import unquote
        rel = unquote(rel_encoded)
        with _config_lock:
            backup_dir = _config["backup_dir"]
        split_dir = os.path.join(backup_dir, "split_stacks")
        full = os.path.realpath(os.path.join(split_dir, rel))
        if not full.startswith(os.path.realpath(backup_dir)):
            self.send_error(403); return
        if not os.path.isfile(full):
            self.send_error(404); return
        size = os.path.getsize(full)
        self.send_response(200)
        self.send_header("Content-Type", "application/gzip")
        self.send_header("Content-Disposition", f'attachment; filename="{os.path.basename(full)}"')
        self.send_header("Content-Length", str(size))
        self.end_headers()
        with open(full, "rb") as f:
            while True:
                chunk = f.read(65536)
                if not chunk: break
                try: self.wfile.write(chunk)
                except (BrokenPipeError, ConnectionResetError): break

    def _download_all(self):
        with _config_lock:
            backup_dir = _config["backup_dir"]
        split_dir = os.path.join(backup_dir, "split_stacks")
        base = split_dir if os.path.isdir(split_dir) else backup_dir
        archives = [os.path.join(base, f) for f in os.listdir(base) if f.endswith(".tar.gz")]
        if not archives: self.send_error(404); return
        ts = time.strftime("%Y%m%d_%H%M%S")
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode="w:gz") as tar:
            for f in archives: tar.add(f, arcname=os.path.basename(f))
        data = buf.getvalue()
        self.send_response(200)
        self.send_header("Content-Type", "application/gzip")
        self.send_header("Content-Disposition", f'attachment; filename="backuper_all_{ts}.tar.gz"')
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

if __name__ == "__main__":
    if not os.path.isfile(BACKUP_SH):
        print(f"WARNING: backup.sh not found at {BACKUP_SH}")
    else:
        print(f"backup.sh found: {BACKUP_SH}")
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print("┌─ Backuper Web UI ──────────────────────────")
    print(f"│  http://{HOST}:{PORT}")
    print("└────────────────────────────────────────────")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
