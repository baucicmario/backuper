#!/usr/bin/env python3
"""
webui.py — Minimal HTTP server for backuper.
"""
import os, subprocess, threading, time, json, stat, tarfile, io
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

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
        else:                       self.send_error(404)



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
        
        # 1. Save the file
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

        # 2. Inspect and Process
        try:
            is_bundle = False
            if tarfile.is_tarfile(target_path):
                with tarfile.open(target_path, "r:gz") as tar:
                    members = tar.getmembers()
                    # Check if there are multiple top-level directories (Download All)
                    top_levels = set()
                    for m in members:
                        # Extract the top-level directory name
                        parts = m.name.split('/')
                        if parts and parts[0]:
                            top_levels.add(parts[0])
                    
                    if len(top_levels) > 1:
                        is_bundle = True
                        # Extract to split_stacks
                        tar.extractall(path=split_dir)
                
                if is_bundle:
                    # Remove the original archive after successful extraction
                    os.remove(target_path)
                    self._json({"ok": True, "message": f"Extracted bundle: {filename}"})
                else:
                    self._json({"ok": True, "message": f"Saved individual archive: {filename}"})
            else:
                # Not a tar, treat as regular file
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
        raw = params.get("flags","")
        extra = [f for f in raw.split() if f.startswith("--")] if raw else []
        with _lock:
            if _job["running"]: self.send_error(409,"Already running"); return
        threading.Thread(target=_run_backup, args=(extra,), daemon=True).start()
        self.send_response(200)
        self.send_header("Content-Type","text/event-stream")
        self.send_header("Cache-Control","no-cache")
        self.send_header("X-Accel-Buffering","no")
        self.end_headers()
        sent = 0
        try:
            while True:
                with _lock:
                    new = _job["log"][sent:]
                    running = _job["running"]
                    code = _job["exit_code"]
                for line in new:
                    self.wfile.write(f"event: line\ndata: {json.dumps(line)}\n\n".encode())
                    sent += 1
                self.wfile.flush()
                if not running and code is not None:
                    self.wfile.write(f"event: done\ndata: {code}\n\n".encode())
                    self.wfile.flush()
                    break
                time.sleep(0.15)
        except (BrokenPipeError, ConnectionResetError):
            pass

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
        for root, dirs, files in os.walk(split_dir if os.path.isdir(split_dir) else backup_dir):
            for fname in sorted(files):
                if fname.endswith(".tar.gz"):
                    fpath = os.path.join(root, fname)
                    try:
                        size = os.path.getsize(fpath)
                        mtime = os.path.getmtime(fpath)
                    except OSError:
                        continue
                    # relative path used as download key
                    rel = os.path.relpath(fpath, backup_dir)
                    results.append({"name": fname, "rel": rel, "size": size, "mtime": mtime})
            break  # only top-level of split_stacks
        self._json({"archives": results, "backup_dir": backup_dir})

    def _download_file(self, rel_encoded):
        from urllib.parse import unquote
        rel = unquote(rel_encoded)
        with _config_lock:
            backup_dir = _config["backup_dir"]
        # Security: ensure path stays inside backup_dir
        split_dir = os.path.join(backup_dir, "split_stacks")
        full = os.path.realpath(os.path.join(split_dir, rel))
        if not full.startswith(os.path.realpath(backup_dir)):
            self.send_error(403, "Forbidden"); return
        if not os.path.isfile(full):
            self.send_error(404, "Not found"); return
        fname = os.path.basename(full)
        size = os.path.getsize(full)
        self.send_response(200)
        self.send_header("Content-Type", "application/gzip")
        self.send_header("Content-Disposition", f'attachment; filename="{fname}"')
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
        archives = []
        for fname in sorted(os.listdir(base)):
            if fname.endswith(".tar.gz"):
                archives.append(os.path.join(base, fname))
        if not archives:
            self.send_error(404, "No archives found"); return

        ts = time.strftime("%Y%m%d_%H%M%S", time.localtime())
        bundle_name = f"backuper_all_{ts}.tar.gz"

        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode="w:gz") as tar:
            for fpath in archives:
                tar.add(fpath, arcname=os.path.basename(fpath))
        data = buf.getvalue()

        self.send_response(200)
        self.send_header("Content-Type", "application/gzip")
        self.send_header("Content-Disposition", f'attachment; filename="{bundle_name}"')
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

if __name__ == "__main__":
    if not os.path.isfile(BACKUP_SH):
        print(f"WARNING: backup.sh not found at {BACKUP_SH}")
    else:
        print(f"backup.sh found: {BACKUP_SH}")
    import socket
    server = HTTPServer((HOST, PORT), Handler)
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
