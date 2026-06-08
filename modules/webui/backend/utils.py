import os
import stat

def ls_dir(path):
    """
    Lists subdirectories within a given path, filtering for accessibility and type.
    """
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

def fmt_size(bytes):
    """
    Converts byte counts to human-readable string formats (B, KB, MB, GB).
    """
    if bytes < 1024: return f"{bytes}B"
    if bytes < 1048576: return f"{bytes/1024:.1f}KB"
    if bytes < 1073741824: return f"{bytes/1048576:.1f}MB"
    return f"{bytes/1073741824:.2f}GB"
