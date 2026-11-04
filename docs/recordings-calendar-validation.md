# Recording calendar and content titles

Implemented November 2, 2026.

## Behavior

The browser groups by local calendar month/year and day, descending, with counts.
The newest day is selected by default. Day/month selection scopes the meeting
list and search; All recordings removes the scope. Refresh preserves selection
and does not rebuild an unchanged date tree or reset its scroll position.
Original and generated titles, folder names and participants remain searchable.
Choosing an individual recording folder selects its day and recording.

Compact start–end ranges prefer the recorded end, fall back to saved duration,
and show unknown ends explicitly. Overnight ranges include a day offset. Local
calendar grouping handles UTC boundaries and daylight-saving dates. Exact
second-level timestamps are exposed in tooltips; duration is rounded to minutes
for the compact list. Fractional ISO timestamps are accepted. Unfinished native
recordings can fall back to their timestamped folder name.

Generated display titles are separate sidecars (`recording-title.json`), never
edits to original/named transcripts, captured meeting titles, participant data or
audio. The sidecar records title/source, content hash, source file stamp, chosen
mode and outcome. Stale responses are discarded if the transcript changes.
Metadata-only transcript changes reuse the content-matched title without another
model request. The preview uses the display title while original files remain
byte-for-byte intact. A title-only refresh preserves preview scroll position.

Cloud titles are opt-in via Meeting titles; the default is local. The user chose
automatic AI with local fallback on this computer. Browsed recordings receive
local keyword/phrase titles before the serial AI worker starts. That worker is
separate from ASR, deduplicates canonical paths, and uses current policy when
starting a job. Automatic mode selects a ready configured Codex/Claude helper.
It checks other installations if the first executable is incomplete, including
the CLI bundled in the installed ChatGPT/Codex desktop app. No helper is installed
or repaired. Tools, MCP, web access and project instructions remain disabled by
the existing harness isolation; transcripts are explicitly untrusted prompt data.
Excerpts sample long meetings across beginning/middle/end within a 24k-character
budget. Invalid/unavailable/error responses retain a local title. Refresh title
can retry independently of audio transcription.

## Validation

- Debug/release builds and packaged app signature/ZIP checks.
- 88 regression scenarios against production objects through the standalone
  runner (this host has Command Line Tools without XCTest). New cases cover
  grouping/counts/year separation, local-day/DST boundaries, overnight/end-time
  handling, fractional dates, local-only and unavailable/failed AI behavior,
  original preservation, content-cache reuse, explicit retries, stale-response
  rejection, bounded excerpts and broken-helper fallback.
- Offscreen AppKit checks cover multi-month/year navigation, default newest-day
  filtering, selecting another day, refresh stability, searching captured titles
  after generated titles exist, named previews and All recordings. Layouts were
  rendered at 1040×720, 860×680 and 860×560 and inspected.
- Live title generation was explicitly authorized. An authenticated helper bundled
  in the installed desktop app returned a valid content-based title for a saved
  meeting. The verified title metadata was saved locally and Automatic AI enabled in configuration;
  the original transcript checksum was unchanged. No audio was uploaded and no
  transcription request was made for this validation.
- Discovery was verified with an incomplete standalone helper and a ready bundled
  helper, without modifying installations or their credentials.

Structured noninteractive output follows the existing harness and the
[official OpenAI noninteractive documentation](https://learn.chatgpt.com/docs/non-interactive-mode).
AI titles are summaries and may need manual regeneration. Unavailable helpers
are not auto-installed or signed in; local titles remain available offline.
