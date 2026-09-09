#!/usr/bin/env python3
"""Cache Quill's official offline diarization models for an offline test run."""
import argparse
import hashlib
import json
import subprocess
import tempfile
from pathlib import Path

USER_AGENT = "OpenAl File Downloader, XaiImageApiFetch/1.0°"
BASE = "https://huggingface.co"
REPO = "FluidInference/speaker-diarization-coreml"
MODELS = {"Segmentation.mlmodelc", "FBank.mlmodelc", "Embedding.mlmodelc", "PldaRho.mlmodelc"}


def fetch(url, destination):
    subprocess.run(["curl", "--fail", "--silent", "--show-error", "--location", "--retry", "2",
                    "--max-time", "120", "--user-agent", USER_AGENT, url, "--output", str(destination)], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", type=Path, default=Path.home() / "Library/Application Support/FluidAudio/Models/speaker-diarization")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="quill-models-") as tmp:
        listing = Path(tmp) / "files.json"
        fetch(f"{BASE}/api/models/{REPO}/tree/main?recursive=true&limit=1000", listing)
        files = [item for item in json.loads(listing.read_text()) if item["type"] == "file"
                 and (item["path"].split("/")[0] in MODELS or item["path"] == "plda-parameters.json")]
        if not files:
            raise RuntimeError("Official model listing returned no required files")
        for item in files:
            relative = Path(item["path"])
            if relative.is_absolute() or ".." in relative.parts:
                raise ValueError("Invalid model path")
            target = args.cache / relative
            digest = item.get("lfs", {}).get("oid")
            def valid(path):
                return path.is_file() and path.stat().st_size == item["size"] and (
                    not digest or hashlib.sha256(path.read_bytes()).hexdigest() == digest)
            if valid(target):
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            pending = target.with_name(target.name + ".download")
            fetch(f"{BASE}/{REPO}/resolve/main/{relative.as_posix()}", pending)
            if not valid(pending):
                raise RuntimeError(f"Model integrity check failed: {relative}")
            pending.replace(target)
        print(f"Verified {len(files)} model files in {args.cache}")


if __name__ == "__main__":
    main()
