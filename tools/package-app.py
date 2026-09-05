#!/usr/bin/env python3
"""Package the built Quill executable as a signed, native macOS application."""
import argparse
import os
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path


def main():
    repo = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=repo / ".build/release/quill")
    parser.add_argument("--output", type=Path, default=repo / ".build/Quill.app")
    args = parser.parse_args()
    if not args.binary.is_file():
        parser.error("Build Quill first: swift build -c release")
    if args.output.suffix != ".app":
        parser.error("The output must end in .app")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".quill-package-", dir=args.output.parent) as staging:
        app = Path(staging) / "Quill.app"
        executable = app / "Contents/MacOS/quill"
        resources = app / "Contents/Resources"
        executable.parent.mkdir(parents=True)
        resources.mkdir()
        shutil.copy2(args.binary, executable)
        executable.chmod(0o755)
        info = plistlib.loads((repo / "Sources/quill/Info.plist").read_bytes())
        info["CFBundleIconFile"] = "AppIcon"
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        icons = Path(staging) / "AppIcon.iconset"
        subprocess.run(["xcrun", "swift", str(repo / "tools/make-icon.swift"), str(icons)], check=True)
        subprocess.run(["iconutil", "-c", "icns", str(icons), "-o", str(resources / "AppIcon.icns")], check=True)
        subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
        subprocess.run(["codesign", "--verify", "--strict", str(app)], check=True)
        previous = Path(staging) / "previous.app"
        if args.output.exists():
            os.rename(args.output, previous)
        try:
            os.rename(app, args.output)
        except OSError:
            if previous.exists():
                os.rename(previous, args.output)
            raise
    print(args.output)


if __name__ == "__main__":
    main()
