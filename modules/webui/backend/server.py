import os
import json
import threading
import time
import tarfile
import io
import shutil
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
import socketserver

from . import state, tasks, utils

# Use ThreadingHTTPServer to handle multiple concurrent requests
class ThreadingHTTPServer(socketserver.ThreadingMixIn, HTTPServer):
    daemon_threads = True
    block_on_close = False

SCRIPT_DIR = os.path.dirname(os.path.realpath(__file__))
WEBUI_DIR = os.path.normpath(os.path.join(SCRIPT_DIR, ".."))
STATIC_DIR = os.path.join(WEBUI_DIR, "static")
TEMPLATES_DIR = os.path.join(WEBUI_DIR, "templates")

HOST = os.environ.get("WEBUI_HOST", "0.0.0.0")
PORT = int(os.environ.get("WEBUI_PORT", "8099"))
SECRET = os.environ.get("WEBUI_SECRET", "")

class Handler(BaseHTTPRequestHandler):
    """
    HTTP Request Handler for the Backuper Web UI.
    """
    def log_message(self, fmt, *args):
        # Optional: Log messages to stdout for debugging
        print(f"[{self.address_string()}] {fmt % args}")

    def _check_secret(self):
        """
        Validates the request token against the WEBUI_SECRET environment variable.
        """
        if not SECRET: return True
        token = self.headers.get("X-Backuper-Token", "")
        if not token:
            qs = urlparse(self.path).query
            token = dict(p.split("=", 1) for p in qs.split("&") if "=" in p).get("token", "")
        return token == SECRET

    def _send_json(self, data, status=200):
        """
        Sends a JSON response with the appropriate headers.
        """
        b = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", len(b))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        """
        Handles GET requests for static assets, status, and API endpoints.
        """
        p = urlparse(self.path).path
        
        # Route mapping
        if p in ("/", "/index.html"): 
            self._serve_template("index.html")
        elif p == "/stream":
            self._sse()
        elif p == "/status":
            with state.job_lock:
                self._send_json({k: state.job[k] for k in ("running", "exit_code", "started")})
        elif p == "/api/restore-status":
            with state.restore_lock:
                self._send_json(state.restore_job)
        elif p == "/api/discover-containers":
            self._discover_containers()
        elif p == "/config":
            with state.config_lock:
                self._send_json(dict(state.config))
        elif p == "/ls":
            qs = parse_qs(urlparse(self.path).query)
            path = qs.get("path", ["/"])[0]
            result, err = utils.ls_dir(path)
            self._send_json({"error": err} if err else result)
        elif p == "/archives":
            self._list_archives()
        elif p == "/download-all":
            self._download_all()
        elif p.startswith("/static/"):
            self._serve_static(p)
        elif p.startswith("/download/"):
            self._download_file(p[len("/download/"):])
        else:
            self.send_error(404)

    def do_POST(self):
        """
        Handles POST requests for starting jobs and updating configuration.
        """
        p = urlparse(self.path).path
        if p == "/run":
            self._start_run()
        elif p == "/config":
            self._set_config()
        elif p == "/upload":
            self._handle_upload()
        elif p == "/api/restore":
            self._handle_batch_restore()
        elif p == "/api/respond":
            self._handle_prompt_response()
        elif p == "/api/abort":
            self._handle_abort()
        else:
            self.send_error(404)

    def _serve_template(self, name):
        """
        Serves an HTML template from the templates directory.
        """
        path = os.path.join(TEMPLATES_DIR, name)
        if not os.path.exists(path):
            self.send_error(404)
            return
        with open(path, "rb") as f:
            b = f.read()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", len(b))
        self.end_headers()
        self.wfile.write(b)

    def _serve_static(self, path):
        """
        Serves static assets with appropriate MIME types.
        """
        # Strip /static/ prefix
        rel_path = path[len("/static/"):].replace("/", os.sep)
        full_path = os.path.join(STATIC_DIR, rel_path)
        
        # Prevent path traversal attacks
        if not os.path.realpath(full_path).startswith(os.path.realpath(STATIC_DIR)):
            self.send_error(403)
            return

        if not os.path.exists(full_path):
            self.send_error(404)
            return

        mime = "text/plain"
        if full_path.endswith(".css"): mime = "text/css"
        elif full_path.endswith(".js"): mime = "application/javascript"
        elif full_path.endswith(".svg"): mime = "image/svg+xml"

        with open(full_path, "rb") as f:
            b = f.read()
        self.send_response(200)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", len(b))
        self.end_headers()
        self.wfile.write(b)

    def _sse(self):
        """
        Provides a Server-Sent Events stream for logs and status updates.
        """
        if not self._check_secret():
            self.send_error(403)
            return
        
        qs = urlparse(self.path).query
        params = parse_qs(qs)
        mode = params.get("mode", ["run"])[0]
        
        if mode == "run":
            raw = params.get("flags", [""])[0]
            extra = raw.split() if raw else []
            with state.job_lock:
                with state.restore_lock:
                    if state.job["running"] or state.restore_job["running"]:
                        self.send_error(409, "Process already running")
                        return
                    state.job["running"] = True
            threading.Thread(target=tasks.run_backup, args=(extra,), daemon=True).start()

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("X-Accel-Buffering", "no")
        self.end_headers()

        sent_log = 0
        last_status_json = ""
        last_heartbeat = time.time()
        last_prompt = None
        
        try:
            while True:
                now = time.time()
                with state.job_lock:
                    new_logs = state.job["log"][sent_log:]
                    prompt = state.job.get("prompt")
                    
                for line in new_logs:
                    self.wfile.write(f"event: log\ndata: {json.dumps(line)}\n\n".encode())
                    sent_log += 1
                
                if prompt != last_prompt:
                    if prompt is not None:
                        self.wfile.write(f"event: prompt\ndata: {json.dumps(prompt)}\n\n".encode())
                    last_prompt = prompt
                
                if mode == "run":
                    with state.job_lock:
                        # Exclude log and prompt from status payload to save bandwidth
                        status_dict = {k: v for k, v in state.job.items() if k not in ("log", "prompt")}
                        status_json = json.dumps(status_dict)
                else:
                    with state.restore_lock:
                        status_json = json.dumps(state.restore_job)
                        
                if status_json != last_status_json:
                    self.wfile.write(f"event: status\ndata: {status_json}\n\n".encode())
                    last_status_json = status_json
                
                if now - last_heartbeat > 15:
                    self.wfile.write(b": heartbeat\n\n")
                    last_heartbeat = now
                
                self.wfile.flush()
                
                with state.job_lock:
                    with state.restore_lock:
                        still_running = state.job["running"] or state.restore_job["running"]
                        has_more_logs = (len(state.job["log"]) > sent_log)
                
                if not still_running and not has_more_logs:
                    self.wfile.write(f"event: status\ndata: {status_json}\n\n".encode())
                    self.wfile.write(f"event: done\ndata: 0\n\n".encode())
                    self.wfile.flush()
                    break
                time.sleep(0.3)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _start_run(self):
        """
        Initiates a backup run.
        """
        if not self._check_secret(): self.send_error(403); return
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode() if length else "{}"
        try:
            data = json.loads(body)
        except Exception:
            data = {}
        extra = [f for f in data.get("flags", []) if f.startswith("--")]
        with state.job_lock:
            if state.job["running"]:
                self.send_error(409)
                return
            state.job["running"] = True
        threading.Thread(target=tasks.run_backup, args=(extra,), daemon=True).start()
        self._send_json({"status": "started"}, 202)

    def _discover_containers(self):
        """
        Discovers all available backupable containers (services within stacks).
        """
        if not self._check_secret(): self.send_error(403); return
        with state.config_lock:
            stacks_dir = state.config.get("stacks_dir", "/opt/stacks")
            
        import subprocess
        script_discover = os.path.normpath(os.path.join(SCRIPT_DIR, "..", "..", "backup", "steps", "01-discover-stacks.sh"))
        script_extract = os.path.normpath(os.path.join(SCRIPT_DIR, "..", "..", "backup", "steps", "02-extract-services.sh"))
        
        try:
            output = subprocess.check_output(["bash", script_discover, stacks_dir], text=True, stderr=subprocess.STDOUT)
            stacks = [line.strip() for line in output.split("\n") if line.strip()]
            
            results = []
            for stack_path in stacks:
                compose_file = os.path.join(stack_path, "compose.yaml")
                if os.path.isfile(compose_file):
                    srv_out = subprocess.check_output(["bash", script_extract, compose_file], text=True, stderr=subprocess.STDOUT)
                    services = [line.strip() for line in srv_out.split("\n") if line.strip()]
                    stack_name = os.path.basename(stack_path)
                    for srv in services:
                        results.append({
                            "path": f"{stack_path}:{srv}",
                            "name": f"{stack_name} / {srv}"
                        })
            
            self._send_json({"ok": True, "containers": results})
        except Exception as e:
            self._send_json({"ok": False, "error": str(e)}, 500)

    def _set_config(self):
        """
        Updates the global configuration state.
        """
        if not self._check_secret(): self.send_error(403); return
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode() if length else "{}"
        try:
            data = json.loads(body)
        except Exception:
            self._send_json({"ok": False, "error": "Invalid JSON"}, 400)
            return
        with state.config_lock:
            if "backup_dir" in data: state.config["backup_dir"] = data["backup_dir"]
            if "stacks_dir" in data: state.config["stacks_dir"] = data["stacks_dir"]
        self._send_json({"ok": True})

    def _handle_upload(self):
        """
        Handles archive uploads and extracts them into the backup directory.
        """
        if not self._check_secret(): self.send_error(403); return
        qs = parse_qs(urlparse(self.path).query)
        filename = qs.get("filename", ["uploaded_archive.tar.gz"])[0]
        filename = os.path.basename(filename)
        length = int(self.headers.get("Content-Length", 0))
        if length == 0:
            self._send_json({"ok": False, "error": "Empty file received"}, 400)
            return
        
        with state.config_lock:
            backup_dir = state.config["backup_dir"]
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
            self._send_json({"ok": False, "error": f"Failed to save file: {str(e)}"}, 500)
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
                    self._send_json({"ok": True, "message": f"Extracted bundle: {filename}"})
                else:
                    self._send_json({"ok": True, "message": f"Saved individual archive: {filename}"})
            else:
                self._send_json({"ok": True, "message": f"Saved file: {filename}"})
        except Exception as e:
            self._send_json({"ok": False, "error": f"Processing failed: {str(e)}"}, 500)

    def _handle_batch_restore(self):
        """
        Initiates a batch restoration process for selected archives.
        """
        if not self._check_secret(): self.send_error(403); return
        length = int(self.headers.get("Content-Length", 0))
        data = json.loads(self.rfile.read(length).decode()) if length else {}
        selected = data.get("archives", [])
        
        with state.config_lock:
            backup_dir = state.config["backup_dir"]
        split_dir = os.path.join(backup_dir, "split_stacks")
        
        if not selected:
            if os.path.isdir(split_dir):
                selected = [f for f in sorted(os.listdir(split_dir)) if f.endswith(".tar.gz")]
            else:
                selected = []
        
        if not selected:
            self._send_json({"ok": False, "error": "No archives to restore"}, 400)
            return
            
        with state.job_lock:
            state.job["log"] = []
            
        with state.restore_lock:
            if state.restore_job["running"]:
                self._send_json({"ok": False, "error": "Restore already in progress"}, 409)
                return
            state.restore_job.update({
                "running": True, 
                "restore_id": int(time.time()), 
                "progress": 0, 
                "total": len(selected), 
                "current": "Preparing...", 
                "phase": "starting", 
                "sub_progress": 0, 
                "sub_total": 0,
                "sub_current_file": "", 
                "results": [], 
                "exit_code": None
            })
            
        threading.Thread(target=tasks.run_restore, args=(selected, backup_dir, split_dir), daemon=True).start()
        self._send_json({"ok": True, "message": "Restore started"})

    def _handle_prompt_response(self):
        """
        Handles user responses to interactive prompts from the backup process.
        """
        if not self._check_secret(): self.send_error(403); return
        length = int(self.headers.get("Content-Length", 0))
        try:
            data = json.loads(self.rfile.read(length).decode())
            answer = data.get("answer", "n")
        except Exception:
            self._send_json({"ok": False, "error": "Invalid JSON"}, 400)
            return
            
        with state.job_lock:
            proc = state.active_process
            prompt = state.job.get("prompt")
            if proc and proc.stdin and prompt:
                try:
                    proc.stdin.write(f"{answer}\n")
                    proc.stdin.flush()
                    state.job["prompt"] = None
                    self._send_json({"ok": True})
                except Exception as e:
                    self._send_json({"ok": False, "error": str(e)}, 500)
            else:
                self._send_json({"ok": False, "error": "No active prompt"}, 400)

    def _handle_abort(self):
        """
        Aborts any currently running backup or restore process.
        """
        if not self._check_secret(): self.send_error(403); return
        aborted = False
        with state.job_lock:
            if getattr(state, "active_process", None):
                try:
                    state.active_process.terminate()
                    aborted = True
                except Exception:
                    pass
            state.job["running"] = False
        with state.restore_lock:
            if getattr(state, "restore_active_process", None):
                try:
                    state.restore_active_process.terminate()
                    aborted = True
                except Exception:
                    pass
            state.restore_job["running"] = False
            state.restore_job["phase"] = "complete"
            state.restore_job["current"] = "Aborted"
        self._send_json({"ok": True, "aborted": aborted})

    def _list_archives(self):
        """
        Lists available archives in the backup directory.
        """
        with state.config_lock:
            backup_dir = state.config["backup_dir"]
        split_dir = os.path.join(backup_dir, "split_stacks")
        results = []
        base = split_dir if os.path.isdir(split_dir) else backup_dir
        if os.path.isdir(base):
            for fname in sorted(os.listdir(base)):
                if fname.endswith(".tar.gz"):
                    fpath = os.path.join(base, fname)
                    try:
                        size = os.path.getsize(fpath)
                        mtime = os.path.getmtime(fpath)
                        rel = os.path.relpath(fpath, backup_dir)
                        results.append({"name": fname, "rel": rel, "size": size, "mtime": mtime})
                    except OSError: continue
        self._send_json({"archives": results, "backup_dir": backup_dir})

    def _download_file(self, rel_encoded):
        """
        Serves a file for download.
        """
        from urllib.parse import unquote
        rel = unquote(rel_encoded)
        with state.config_lock:
            backup_dir = state.config["backup_dir"]
        split_dir = os.path.join(backup_dir, "split_stacks")
        full = os.path.realpath(os.path.join(split_dir, rel))
        
        if not full.startswith(os.path.realpath(backup_dir)):
            self.send_error(403)
            return
        if not os.path.isfile(full):
            self.send_error(404)
            return
            
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
                try:
                    self.wfile.write(chunk)
                except (BrokenPipeError, ConnectionResetError):
                    break

    def _download_all(self):
        """
        Streams all archives as a single tar.gz for download.
        Uses streaming to avoid buffering large files in memory.
        """
        with state.config_lock:
            backup_dir = state.config["backup_dir"]
        split_dir = os.path.join(backup_dir, "split_stacks")
        base = split_dir if os.path.isdir(split_dir) else backup_dir
        
        if not os.path.isdir(base):
            self.send_error(404, "No archives found")
            return
            
        archives = sorted([os.path.join(base, f) for f in os.listdir(base) if f.endswith(".tar.gz")])
        if not archives:
            self.send_error(404)
            return
        
        ts = time.strftime("%Y%m%d_%H%M%S")
        self.send_response(200)
        self.send_header("Content-Type", "application/gzip")
        self.send_header("Content-Disposition", f'attachment; filename="backuper_all_{ts}.tar.gz"')
        # Don't send Content-Length for streaming - compression ratio is variable
        self.send_header("Transfer-Encoding", "chunked")
        self.send_header("X-Accel-Buffering", "no")
        self.end_headers()
        
        try:
            with tarfile.open(fileobj=self.wfile, mode="w|gz") as tar:
                for f in archives:
                    tar.add(f, arcname=os.path.basename(f))
        except (BrokenPipeError, ConnectionResetError):
            pass


def start_server():
    import socket

    """
    Starts the HTTP server and handles the request loop.
    """
    
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    if HOST == "0.0.0.0":
        ips = []
        try:
            for info in socket.getaddrinfo(socket.gethostname(), None):
                ip = info[4][0]
                if ":" not in ip and ip != "127.0.0.1":
                    ips.append(ip)
            ips = sorted(set(ips))
        except Exception:
            pass
        # Also try the UDP trick to find the default-route IP
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.connect(("8.8.8.8", 80))
            default_ip = s.getsockname()[0]
            s.close()
            if default_ip not in ips:
                ips.insert(0, default_ip)
        except Exception:
            pass
        all_ips = ips if ips else ["0.0.0.0"]
        print("┌─ Backuper Web UI ──────────────────────────")
        for ip in all_ips:
            print(f"│  http://{ip}:{PORT}")
        print("└────────────────────────────────────────────")
    else:
        print(f"Backuper Web UI  →  http://{HOST}:{PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
