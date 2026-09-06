#!/bin/sh
# Run the real multilingual engine with disposable macOS speech fixtures.
# Requires downloaded v3 models and the Samantha / Ioana system voices.
set -eu
cd "$(dirname "$0")/.."
audio_dir=$(mktemp -d "${TMPDIR:-/tmp}/quill-language-test.XXXXXX")
trap 'rm -rf "$audio_dir"' EXIT
say -v Samantha -o "$audio_dir/en.aiff" 'Good morning. Tomorrow we will discuss the project budget and plan the next meeting.'
say -v Ioana -o "$audio_dir/ro.aiff" 'Bună dimineața. Mâine vom discuta despre bugetul proiectului și vom planifica următoarea ședință.'
QUILL_TEST_AUDIO_DIR="$audio_dir" swift test --skip-update --filter ParakeetEngineTests
