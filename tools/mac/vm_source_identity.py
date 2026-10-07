"""Identify the actual working sources used by a pre-commit native VM gate."""
import hashlib
import os
from pathlib import Path
import subprocess


def source_identity():
    root = Path(subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip())
    names = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=root)
    tree = hashlib.sha256()
    count = 0
    for name in sorted(set(names.split(b"\0")) - {b""}):
        path = root / os.fsdecode(name)
        if path.is_symlink():
            kind, data = b"symlink", os.fsencode(os.readlink(path))
        elif path.is_file():
            kind = b"executable" if path.stat().st_mode & 0o111 else b"file"
            data = path.read_bytes()
        else:
            continue
        tree.update(name + b"\0" + kind + b"\0" + str(len(data)).encode() + b"\0" + data)
        count += 1
    diff = subprocess.check_output(["git", "diff", "--binary", "HEAD"], cwd=root)
    return {"tree_sha256": tree.hexdigest(), "files": count,
            "diff_head_binary_sha256": hashlib.sha256(diff).hexdigest(),
            "tree_algorithm": "sha256 of sorted tracked and nonignored untracked files: path NUL kind NUL decimal byte length NUL content; deleted files absent; symlinks hash link text"}
