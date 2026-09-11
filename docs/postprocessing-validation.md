# Optional harness post-processing

Validated on 2026-09-10 with Codex CLI 0.153.0 and Claude Code 2.1.267.

Both harnesses are installed and signed in on this Mac. Quill's status command
detects both without extracting credentials, and the automatic setting remains
off. The integration uses the normal CLI sign-ins, not direct provider API keys
or desktop chat-window automation. Cloud processing is explicit in the menu,
command help, configuration documentation, and status output.

The Swift suite ran 75 tests: 70 passed, 5 optional audio/window tests skipped.
This includes replay of captured Meet/Teams states and 14 new post-processing
tests for default-off behavior, missing harnesses, provider selection, restricted
invocation, literal input handling, timeouts, exact backups, idempotency,
concurrent transcript edits, oversized input, invalid output, and protection of
timestamps, speaker labels, numbers, and negations.

Separate real canaries ran through both signed-in harnesses using synthetic
English/Romanian transcript text only. Both corrected the same two misspellings,
preserved Romanian text, numeric statements, negation, segment metadata, and the
instruction-like text embedded in the transcript. Both proposed a speaker name
from an explicit introduction; neither changed the canonical speaker label.
Exact original JSON/Markdown backups and correction reports were verified.
No customer recording or transcript was submitted by these tests.

Automatic corrections are still model output, and character/number checks do
not prove semantic equivalence. The first version skips input over 300 KB or
5,000 segments and does not automatically retry failed or interrupted optional
runs. Speaker suggestions are review-only. Standalone `postprocess run` does not
invoke the archive hook; automatic cleanup runs before the existing hook.

References: [Codex non-interactive mode](https://learn.chatgpt.com/docs/non-interactive-mode)
and [Claude Code programmatic use](https://code.claude.com/docs/en/headless).
The installed CLI help was also checked for the precise isolation and saved-auth
flags. In particular, Claude `--safe-mode` preserves subscription login, whereas
`--bare` would require API credentials and is intentionally not used.
