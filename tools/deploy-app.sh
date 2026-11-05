#!/bin/sh
# Build, package and install Quill to ~/Applications/Quill.app, then restart it.
#
# Signs with the "Quill Local Signing" identity when the login keychain has it
# (package-app.py warns and signs ad hoc otherwise); never creates one. Refuses
# to quit a Quill that is recording. Usage: sh tools/deploy-app.sh
set -eu

repo=$(cd "$(dirname "$0")/.." && pwd)
dest="$HOME/Applications/Quill.app"
bundle_id=com.bedeabza.quill
# Any running Quill app, from ~/Applications or a build folder; not the quill CLI.
app_pattern='Quill\.app/Contents/MacOS/quill'

running() { pgrep -f "$app_pattern" || true; }

cd "$repo"
swift build -c release
python3 tools/package-app.py --output "$repo/.build/Quill.app"

pids=$(running)
if [ -n "$pids" ]; then
    # A recording keeps its mic.caf and system.caf open; quitting would end it.
    if lsof -p "$(echo $pids | tr ' ' ,)" 2>/dev/null | grep -q '\.caf$'; then
        echo "error: Quill is recording; not quitting it. Deploy again when the recording has stopped." >&2
        exit 1
    fi
    echo "Quitting Quill ($pids)…"
    osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
    waited=0
    while [ -n "$(running)" ] && [ $waited -lt 15 ]; do sleep 1; waited=$((waited + 1)); done
    if [ -n "$(running)" ]; then
        echo "Quill did not quit within 15 s; terminating it."
        kill $(running) 2>/dev/null || true
        sleep 3
        [ -z "$(running)" ] || kill -9 $(running) 2>/dev/null || true
    fi
fi

mkdir -p "$(dirname "$dest")"
rm -rf "$dest"
ditto "$repo/.build/Quill.app" "$dest"
codesign --verify --strict "$dest"
echo "Installed $dest"

open "$dest"
sleep 5
pid=$(pgrep -f "$dest/Contents/MacOS/quill" || true)
if [ -z "$pid" ]; then
    echo "error: Quill is not running 5 s after launch; see Console for crash reports." >&2
    exit 1
fi
echo "Quill is running (pid $pid)."
