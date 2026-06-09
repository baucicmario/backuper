# "Download All" Pure Bash Architecture Refactor

## Background

The "Download All" feature in the WebUI currently generates a single `.tar.gz` bundle containing all individual service archives on the fly. It streams this bundle directly to the HTTP client using a chunked transfer encoding response.

This is implemented in `server.py` (`_download_all`) using Python's `tarfile` module (`mode="w|gz"`).

While this implementation provides an excellent user experience by avoiding disk buffering and memory overhead, it represents a departure from the architectural goal of having the Bash layer act as the sole executor for all backup and archive operations.

## Goal

Consolidate the "Download All" archive generation logic into the Bash backend (`modules/backup/` or a new `modules/download/` script) to achieve pure architectural separation, **without** sacrificing the existing streaming characteristics, performance, or memory efficiency.

## Challenges & Constraints

1.  **No Disk Buffering:** The current implementation never writes the final mega-bundle to disk. A pure Bash solution must also avoid creating a temporary on-disk mega-bundle, as this could consume significant disk space and delay the start of the download for the user.
2.  **Streaming Pipeline:** The Bash script must output a valid `.tar.gz` stream to `stdout`, which the Python backend can then read and immediately write to the HTTP response stream.
3.  **Tar Compatibility:** The `tar` command in Bash must be able to append existing `.tar.gz` files into a single outer `.tar.gz` archive on the fly via a pipeline. Wait, nesting `.tar.gz` files inside an uncompressed `.tar` stream, which is *then* gzipped, is computationally wasteful if we compress already-compressed files. The current Python implementation adds `.tar.gz` files into an outer `.tar.gz`.

## Proposed Solution (Complex Implementation)

### 1. Bash Streaming Script (`create_bundle_stream.sh`)

Create a new Bash script dedicated to streaming a generated archive to `stdout`.

```bash
#!/usr/bin/env bash
# modules/backup/create_bundle_stream.sh
set -euo pipefail

BACKUP_DIR="${1:?Usage: $0 <backup_dir>}"
SPLIT_DIR="$BACKUP_DIR/split_stacks"

# We stream an uncompressed tar archive containing the individual .tar.gz files.
# The HTTP response might not need to double-gzip if we just send a .tar containing .tar.gz files.
# If we MUST send a .tar.gz, we pipe it through gzip.
# However, Python's tarfile is currently compressing the outer layer too.

cd "$SPLIT_DIR"
# Find all archives and stream them to stdout as a tar archive
find . -maxdepth 1 -name "*.tar.gz" -print0 | tar -cvf - --null -T - | gzip -c
```

*Note on double compression:* Gzipping a `.tar` of `.tar.gz` files is highly inefficient. We might want to just stream an uncompressed `.tar` file containing the `.tar.gz` files, which provides the exact same functionality (bundling) without CPU overhead.

### 2. Python Backend Adaptation

Modify `server.py` to execute this Bash script as a subprocess and pipe its `stdout` directly to the HTTP response.

```python
    def _download_all_bash(self):
        with state.config_lock:
            backup_dir = state.config["backup_dir"]
        
        # ... validation ...

        ts = time.strftime("%Y%m%d_%H%M%S")
        self.send_response(200)
        self.send_header("Content-Type", "application/gzip")
        self.send_header("Content-Disposition", f'attachment; filename="backuper_all_{ts}.tar.gz"')
        self.send_header("Transfer-Encoding", "chunked")
        self.send_header("X-Accel-Buffering", "no")
        self.end_headers()
        
        cmd = ["bash", "modules/backup/create_bundle_stream.sh", backup_dir]
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE)
        
        try:
            while True:
                chunk = proc.stdout.read(65536)
                if not chunk:
                    break
                self.wfile.write(chunk)
        except (BrokenPipeError, ConnectionResetError):
            proc.kill()
        finally:
            proc.wait()
```

## Acceptance Criteria

*   The Python `tarfile` logic is completely removed from `server.py`.
*   A Bash script handles the selection and streaming of the `.tar.gz` archives.
*   The download starts immediately without a noticeable delay (no disk buffering).
*   The downloaded file is a valid archive containing the individual service backups.
*   The CPU and memory usage of the WebUI container does not increase during the download.
