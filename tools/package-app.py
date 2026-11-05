#!/usr/bin/env python3
"""Package the built Quill executable as a signed, native macOS application."""
import argparse
import os
import plistlib
import secrets
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

LOCAL_IDENTITY = "Quill Local Signing"


def find_local_identity(keychain):
    """Return the SHA-1 of the local signing identity in the keychain, trusted or not."""
    listing = subprocess.run(["security", "find-identity", "-p", "codesigning", str(keychain)],
                             check=True, capture_output=True, text=True).stdout
    for line in listing.splitlines():
        fields = line.split()
        if len(fields) > 2 and fields[0].endswith(")") and f'"{LOCAL_IDENTITY}"' in line:
            return fields[1]
    return None


def create_local_identity(keychain):
    """Create a self-signed code-signing identity so every build keeps the same designated requirement."""
    with tempfile.TemporaryDirectory(prefix="quill-identity-") as work:
        key, cert, bundle = (Path(work) / name for name in ("key.pem", "cert.pem", "identity.p12"))
        password = secrets.token_hex(16)
        # Not the openssl on PATH: the system LibreSSL writes a PKCS#12 that `security import` accepts.
        subprocess.run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "3650",
                        "-subj", f"/CN={LOCAL_IDENTITY}", "-keyout", str(key), "-out", str(cert),
                        "-addext", "extendedKeyUsage=critical,codeSigning",
                        "-addext", "keyUsage=critical,digitalSignature",
                        "-addext", "basicConstraints=critical,CA:false"], check=True, capture_output=True)
        subprocess.run(["/usr/bin/openssl", "pkcs12", "-export", "-name", LOCAL_IDENTITY, "-inkey", str(key),
                        "-in", str(cert), "-out", str(bundle), "-passout", f"pass:{password}"], check=True)
        subprocess.run(["security", "import", str(bundle), "-k", str(keychain), "-P", password,
                        "-T", "/usr/bin/codesign"], check=True)


def main():
    repo = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=repo / ".build/release/quill")
    parser.add_argument("--output", type=Path, default=repo / ".build/Quill.app")
    parser.add_argument("--signing-identity", default=os.environ.get("QUILL_SIGNING_IDENTITY"),
                        help=f"Code-signing identity name or SHA-1, or - for ad hoc; defaults to \"{LOCAL_IDENTITY}\" when the keychain has it, else ad hoc.")
    parser.add_argument("--keychain", type=Path,
                        help="Keychain that holds the signing identity; defaults to the login keychain.")
    parser.add_argument("--create-signing-identity", action="store_true",
                        help=f"Create the self-signed \"{LOCAL_IDENTITY}\" identity in the keychain unless it exists, so rebuilds keep macOS permissions.")
    args = parser.parse_args()
    if not args.binary.is_file():
        parser.error("Build Quill first: swift build -c release")
    if args.output.suffix != ".app":
        parser.error("The output must end in .app")
    keychain = args.keychain or Path.home() / "Library/Keychains/login.keychain-db"
    if args.create_signing_identity and not find_local_identity(keychain):
        create_local_identity(keychain)
    identity, local = args.signing_identity, None
    if identity is None:
        local = find_local_identity(keychain)
        if local is None:
            print(f"warning: no \"{LOCAL_IDENTITY}\" identity in {keychain}; signing ad hoc, so rebuilds lose macOS "
                  "permissions. Run once with --create-signing-identity to fix this.", file=sys.stderr)
        identity = local or "-"
    sign = ["codesign", "--force", "--sign", identity]
    if identity != "-" and (args.keychain or local):
        sign += ["--keychain", str(keychain)]
    description = "ad hoc" if identity == "-" else f"{LOCAL_IDENTITY} ({local})" if local else identity
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".quill-package-", dir=args.output.parent) as staging:
        app = Path(staging) / "Quill.app"
        executable = app / "Contents/MacOS/quill"
        resources = app / "Contents/Resources"
        executable.parent.mkdir(parents=True)
        resources.mkdir()
        shutil.copy2(repo / "THIRD-PARTY-NOTICES.txt", resources / "THIRD-PARTY-NOTICES.txt")
        shutil.copy2(args.binary, executable)
        executable.chmod(0o755)
        info = plistlib.loads((repo / "Sources/quill/Info.plist").read_bytes())
        info["CFBundleIconFile"] = "AppIcon"
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        icons = Path(staging) / "AppIcon.iconset"
        subprocess.run(["xcrun", "swift", str(repo / "tools/make-icon.swift"), str(icons)], check=True)
        subprocess.run(["iconutil", "-c", "icns", str(icons), "-o", str(resources / "AppIcon.icns")], check=True)
        subprocess.run(sign + [str(app)], check=True)
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
    print(f"Signing identity: {description}")
    print(args.output)


if __name__ == "__main__":
    main()
