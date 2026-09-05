#!/usr/bin/env python3
"""Install the quill command while preserving the app's macOS bundle identity."""
import argparse
import datetime
import os
import shlex
import shutil
import tempfile
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=Path.home() / "Applications/Quill.app")
    args = parser.parse_args()
    executable = args.app.resolve() / "Contents/MacOS/quill"
    if not executable.is_file() or not os.access(executable, os.X_OK):
        parser.error("Install Quill.app first.")
    target = Path.home() / ".local/bin/quill"
    target.parent.mkdir(parents=True, exist_ok=True)
    # A symlink leaves Bundle.main pointing at the CLI directory on macOS.
    content = "#!/bin/sh\nexec " + shlex.quote(str(executable)) + ' "$@"\n'
    if target.is_file() and not target.is_symlink() and target.read_bytes() == content.encode():
        print(f"Already installed: {target}")
        return
    if target.exists() or target.is_symlink():
        stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
        backup = Path.home() / "Library/Application Support/Quill/Backups" / stamp
        backup.mkdir(parents=True)
        shutil.copy2(target, backup / "quill-command", follow_symlinks=False)
    descriptor, name = tempfile.mkstemp(prefix=".quill-cli-", dir=target.parent)
    try:
        with os.fdopen(descriptor, "w") as handle:
            handle.write(content)
        os.chmod(name, 0o755)
        os.replace(name, target)
    finally:
        if os.path.exists(name):
            os.unlink(name)
    print(f"Installed {target} -> {executable}")


if __name__ == "__main__":
    main()
