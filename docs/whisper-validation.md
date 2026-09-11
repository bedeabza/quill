# Whisper.cpp validation

Historical validation for the removed Whisper implementation. The replacement
is covered in [ElevenLabs validation](elevenlabs-validation.md).

Validated on September 11, 2026, on Apple silicon with macOS 15 as the build minimum.

- Pinned whisper.cpp v1.9.4 source archive passed SHA-256 verification.
- Built a standalone runtime with embedded Metal shaders and `GGML_NATIVE=OFF`.
  `otool -L` confirmed that its dependencies are all macOS system libraries.
- Downloaded the unquantized `ggml-large-v3-turbo.bin` model. Both the source
  download and Quill's actual `transcription prepare` command verified its
  official SHA-256. The model is cached for the installed app.
- Full Swift suite: 84 tests, 76 passed, 8 optional tests skipped, no failures.
- Explicit Whisper suite with the runtime and model: 7 passed, no skips.
  Real inference recognized English, Romanian with diacritics, then English
  again, preserving word timestamps across engine reuse.
- Coordinator regressions verified switching Parakeet to Whisper and back,
  releasing the previous engine, recording provenance, retaining track offsets,
  and keeping all-track failures pending without a fallback transcript.
- Configuration tests verified persistence, preservation of unrelated settings
  and the disabled flag, and refusal to overwrite malformed JSON.
- Release build and signed app packaging passed. Installed at
  `/Users/dragos/Applications/Quill.app` and verified its signature, running
  LaunchAgent, runtime discovery, cached model, and existing recording permissions.
- The installed app transcribed a disposable English microphone track and a
  Romanian system track with `--engine whisper_cpp --offline --no-speakers`.
  Verified schema v2, engine/model provenance, original languages, source labels,
  track offsets, and no cloud cleanup or archive publication for the preview.
- Parakeet remains selected. Existing cleanup and archive settings are preserved.
- The live menu check remains unverified because the Mac was locked. Menu
  construction and action wiring compile; configuration and job switching are
  covered by the tests above. No live meeting or speaker-diarization benchmark
  was performed for Whisper in this run.

The prior app is retained under
`~/Library/Application Support/Quill/Backups/20260911-122003-whisper/Quill.app`.
Source changes are on `feature/whisper-cpp`; pre-existing local edits are retained.
