# Quill window, slim menu and ElevenLabs key file

Replaces the Recordings browser and the Permissions & readiness window
([recordings-browser-validation.md](recordings-browser-validation.md),
[permissions-checker-validation.md](permissions-checker-validation.md)).

## Behavior

### Menu

The menu-bar menu holds only: a status line (**Idle** or **● Recording · 12:34**);
a transcription line while something is transcribing, such as **Transcribing
<folder> · 1 queued**; **Start/Stop Recording** (⌘R); **Keep Recording After
Meeting Ends** (only while recording); the meeting detection status line; the
**Automatic Meeting Recording** toggle; **Allow meeting detection…** or **Allow
Zoom speaker names…** when that permission is missing, which opens the window at
Permissions; **Open Quill…** (⌘O); and **Quit Quill** (⌘Q).

Removed from the menu: Transcription engine, ElevenLabs API key…, Remove
ElevenLabs API key, Transcript cleanup (cloud), Meeting titles, Remember speaker
voices, Recordings…, Permissions & readiness… and Open recordings folder.
Their functions now live in the Quill window.

### Quill window

**Open Quill…** opens one window. Its sidebar lists **Recordings**, then a
Settings group: **Transcription**, **Meetings**, **Permissions**, **General**.

**Recordings**

- The list is grouped by day: Today, Yesterday, then dates; days from another
  year show the year. The month/day tree of the old browser is gone.
- Toolbar search matches title, original title, folder name and participants.
- Each row shows title, time, duration and participants, plus a status tag:
  **Transcribing**, **Queued**, **Failed** or **Not transcribed**. Ready rows
  show no tag. Queued, transcribing and failed messages appear in a banner.
- The detail pane shows the title with **Generate Title** / **Refresh Title**,
  date and time, participants, the **Original / With names** switch (With names
  only when a verified named transcript exists), and the transcript as speaker
  turns with timestamps.
- Toolbar: **Show in Finder** and **Regenerate…**. The sheet chooses the engine
  for this run only; the default does not change. **Request a new ElevenLabs
  transcript** appears for ElevenLabs only. The sheet keeps the notes "One
  aligned recording with echo reduction is sent to ElevenLabs. Matching
  responses are reused; a new upload may be billed." and "Previous transcripts
  are backed up before regeneration." Regeneration otherwise behaves as before:
  serial queue, backups, rollback on failure, no cleanup or archive hook.
- A footer folder menu browses another folder and returns to the default.
- Automatic titles are queued only for recordings visible in the list. They
  follow the title mode and send transcript excerpts only in AI modes, as before.

**Transcription**

- Default engine: Parakeet v3 (on this Mac) or ElevenLabs Scribe v2 (in the
  cloud). Choosing ElevenLabs without a saved key is refused with "Save an
  ElevenLabs API key first." The choice applies to the next transcription;
  there is no silent fallback.
- ElevenLabs API key, entered inline: status **Saved** / **Not set**, **Save**,
  **Remove**.
- Transcript cleanup: Off / Automatic / Codex (ChatGPT account) / Claude Code.
- Meeting titles: Local titles / Automatic AI / Codex / Claude Code.

**Meetings**: the Automatic meeting recording toggle with its live status, an
explanation of Keep Recording After Meeting Ends (a one-off action in the menu
while recording), and Remember speaker voices.

**Permissions**

- The same checks as before: Microphone, Accessibility, Screen Recording, System
  audio (not verifiable until recording), Recordings folder, Transcription
  readiness, Notifications.
- A button appears only when there is something to do. **Check Again** is
  available.
- The sidebar shows a badge counting the items that need attention.
- The old per-recording "Selected recording" check and the **Authorize key**
  button are gone.
- Refreshing records nothing, uploads nothing and prompts for nothing.

**General**: the recordings folder with **Show in Finder**, **Open config
file**, the version, and **Quit Quill**.

### ElevenLabs key file

- The key is stored in `~/Library/Application Support/Quill/elevenlabs-key`, a
  plain file only your user account can read (mode 0600, inside a 0700 folder),
  excluded from Time Machine backups. It is not encrypted: other processes
  running as your user can read it, like most CLI credentials.
- No Keychain and no system dialogs. The app, `quill transcription key set`,
  `set --stdin`, `remove` and the engine all use the same file.
- Quill refuses to read the file if other accounts can access it or if it is
  not a regular file, and asks for the key to be saved again.
- No migration from Keychain: after updating, paste the key once in Quill →
  Transcription. The old Keychain item "Quill: ElevenLabs API key" (service
  `com.bedeabza.quill.elevenlabs`) is no longer read and may be deleted in
  Keychain Access.
- `quill transcription status` reports `credential_storage` as the file path.
- Startup checks include the key, since reading it never prompts.

### Signing and build look

- `python3 tools/package-app.py --create-signing-identity` creates, once, a
  self-signed code-signing identity "Quill Local Signing" in the login keychain
  (`--keychain PATH` chooses another). Later runs reuse it automatically when
  `--signing-identity` / `QUILL_SIGNING_IDENTITY` is not set, so the designated
  requirement (identifier plus certificate leaf) stays the same across rebuilds
  and the Accessibility and Screen Recording grants are kept.
- Without the identity, packaging signs ad hoc and warns that rebuilds lose
  macOS permissions. The Developer ID option is unchanged.
- The first build signed with the new identity needs Accessibility and Screen
  Recording granted once more; removing old Quill entries in System Settings
  first is advised. macOS may ask once for the login password when codesign
  first uses the key (choose Always Allow).
- `Package.swift` passes `-platform_version macos 15.0 26.0` to the linker, so
  binaries record SDK 26 (current macOS look) while still requiring macOS 15.

## Validation

### Automated

- Unit tests cover day sections (Today/Yesterday, newest first, year shown for
  other years) and search by title, participant and folder name
  (`RecordingsModelTests`); status mapping for every case and the queued/
  transcribing/failed messages (`RecordingsModelTests`); merging consecutive
  speaker segments into transcript turns (`RecordingsLibraryTests`); the
  permissions attention count, which excludes the unverifiable system audio row
  (`PermissionsModelTests`); key file permissions 0600/0700, backup exclusion
  and refusal of a 0644 file without changing it (`ElevenLabsKeyStoreTests`);
  and settings key state plus refusal of ElevenLabs without a saved key
  (`SettingsModelTests`).
- Packaging, including `--create-signing-identity` and automatic reuse of the
  identity, was verified only against a temporary keychain, never the login
  keychain.
- `otool -l` on the built binary shows minos 15.0 and sdk 26.0.

### Live checks still needed on the packaged app

- Open the window from the menu with **Open Quill…** and ⌘O.
- Paste the ElevenLabs key in Quill → Transcription and confirm no dialog
  appears.
- Regenerate a recording with Parakeet from the sheet.
- The menu while a meeting is detected: status line, toggle, Keep Recording
  After Meeting Ends while recording, and the Allow… item when a permission is
  missing.
- The permissions buttons, Check Again and the sidebar badge.
- Create the signing identity in the login keychain and confirm the
  Accessibility and Screen Recording grants survive a rebuild.
- Light and dark mode.
