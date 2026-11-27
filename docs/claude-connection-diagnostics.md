# Claude connection diagnostics

Open **Quill → Transcription → Claude account → Connection Log…**, or use
**Connection Log…** in the connection sheet beside a failed recording title.
The Claude account section appears when the title or cleanup provider is Claude
or Automatic AI.

1. Retry **Sign In to Claude…** and complete the official Terminal/browser flow.
2. Return to Quill and press **Verify Connection**.
3. Open **Connection Log…**, press **Refresh**, then **Copy Log** to share it with support.

The log stays local until the user copies or shares it. **Show in Finder** reveals
`~/Library/Logs/Quill/claude-connection.log`. **Clear Log** removes its history and
pending login receipts. Quill does not automatically upload diagnostics.

## Reading the result

- `helperMissing`: install Claude Code, then retry; the desktop app alone does not supply this helper.
- `terminalFailed`: Quill could not prepare/open the login script; a numeric system code may be included.
- `terminalOpened`: Terminal accepted the script, not proof that browser authentication succeeded.
- `loginCompleted`: the interactive CLI login exited; `code=0` means the command succeeded. A missing completion can mean the flow is still pending or Terminal closed before it returned.
- `authStatus result=notLoggedIn`: the helper reports no authenticated account.
- `authStatus result=invalidResponse`: the helper's status output did not have the expected JSON shape.
- `capabilities result=unsupportedCLI`: this CLI lacks required isolation/structured-output options; update Claude Code and retry. Quill does not weaken isolation flags.
- `syntheticRequest`: a short fixed connection-check message was sent, without meeting content. Its result distinguishes authentication, account/quota, network, permission, invalid response, or unknown failure.
- `timeout`, `launchFailed`, `outputTooLarge`: the subprocess timed out, could not start (numeric OS code), or exceeded output bounds.
- `systemError`: a local Foundation/POSIX/OSStatus error; the numeric code is preserved without the error message or path.
- `connected`: the synthetic request returned a usable structured title.

Error categories inferred from CLI output are troubleshooting hints, not a proven
root cause. Unknown errors deliberately retain only the stage and exit code.
Multiple installed helpers are tried in the existing discovery order; `helperFound`
uses a candidate number rather than an identifying filesystem path. Interactive
login completion is timestamped when Quill next imports the numeric receipt.

## Privacy and retention

Only fixed event/category names, numeric codes, app/macOS versions and timestamps
are persisted. Raw stdout/stderr, tokens, OAuth URLs/codes, account/email details,
meeting content, environment values and executable paths are excluded. CLI output
is inspected only in memory for classification; the subprocess runner uses private
temporary files and removes them afterwards. Login output remains in Terminal;
Quill stores only the exit status, never a Terminal transcript.

The log file has mode `0600`, its newly created directory `0700`, and history is
bounded to 64 KB. At most ten pending login receipt files are retained. Logging
failure does not prevent sign-in, and the log window reports storage failures.

## Validation

Synthetic fixtures cover missing/logged-out helpers, malformed auth output,
unsupported CLI capabilities, successful structured responses, API error envelopes,
empty titles, authentication/quota/network classifications, launch/timeouts/output
bounds, private bounded persistence, clearing, shell quoting, login exit status,
malicious receipt text and storage failures. Sentinel secrets are asserted absent
from the log. No real account was signed in or sent a verification request.

Debug and release builds passed. All 150 targeted regression methods passed using
the standalone assertion runner, followed by all 13 Claude-specific methods after
the final auth-status handling change. The local Command Line Tools lack XCTest,
so this is not a full XCTest run. `git diff --check` passed.
