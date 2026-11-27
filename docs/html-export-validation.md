# Discussion HTML export

Implemented November 9, 2026.

## Behavior

- Export HTML is available in the Recordings toolbar, a recording's context menu
  and the detail actions menu. It is disabled without a completed transcript.
- Export captures the displayed title and transcript, preferring the named copy
  just as the preview does, and overlays current speaker-name drafts. The save
  dialog explicitly says unsaved names are included. Exporting another recording
  never consumes the selected recording's drafts. Content is frozen before the
  native save dialog opens; Cancel leaves no export and releases the action.
- The self-contained UTF-8 HTML includes meeting timing/time zone, recorded
  participants, names, stable per-voice colours, timestamps and speaker links.
  It has responsive and print styles with no remote assets or scripts. Markdown
  fallback is exported as literal text, not interpreted as HTML.
- All title/name/participant/transcript content is HTML-escaped. Fragment links
  use generated turn indices, and a restrictive content policy prevents external
  resource loads. Same-name voices retain separate targets and colours.
- Suggested filenames include the local date/time and a portable title, bounded
  by both character and UTF-8 byte length. Writes are atomic and require an HTML
  extension, so the export writer refuses an original JSON/audio destination.
- Export uses no transcription service, AI request, voice model or credential.
  Original/named transcripts, title sidecars, metadata and audio remain intact.

## Validation

- Debug/release builds and signed app packaging; Quill Local Signing is reused.
- 50 production-linked regression methods passed through the standalone runner,
  including the existing full-window/sidebar regression and five export cases:
  updated title/names, Unicode and escaped HTML, timestamps, distinct same-name
  voices, Unknown drafts, literal Markdown, unavailable content, portable names,
  atomic UTF-8 writing, JSON destination refusal, immutable snapshots, modified
  named wording, cross-recording draft isolation and unchanged transcript files.
- The host lacks XCTest, so this is not a full `swift test`/CI pass claim.
- A synthetic Romanian discussion with saved names plus an unsaved name was
  exported and loaded from disk in an isolated WebKit browser. DOM checks cover
  the updated name, UTF-8, speaker targets and escaped script-like text. Desktop
  and narrow-screen layouts were rendered and inspected.
- The native save dialog was opened through the real export action and cancelled;
  filename/contents notice and action cleanup were checked. No recording was
  modified, and the installed app was not replaced or restarted.

The HTML exports text and meeting metadata; original audio remains in its
recording folder. Export is independent of Apply Names: save names there as well
if the recording itself should retain the edits.
