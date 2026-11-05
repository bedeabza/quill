# Deleting a recording

Validated November 5, 2026.

## Behavior

- **Delete…** in a recording row's right-click menu or the detail header's
  actions menu (…), below **Show in Finder** and **Regenerate…**, or Delete (⌫)
  on the selected row, asks first. The alert is a sheet on the
  Quill window, titled `Delete “<title>”?`, with the recording's date, time
  range and duration, and says that all of its files (audio, transcripts,
  cached ElevenLabs responses, backups) move to the Trash and can be put back.
  **Cancel** is the default: Return and Escape cancel; **Delete** is marked
  destructive.
- The whole recording folder moves to the Trash with `FileManager.trashItem`.
  Nothing is removed permanently.
- Quill refuses, with a `Can’t Delete “<title>”` alert, the recording in
  progress, and one queued, transcribing, regenerating or post-processing in the
  app. The queue check and the move run in one non-suspending call on the
  transcription actor, so no job can be queued in between. The move holds
  `.postprocess.lock`, the lock that CLI transcription, regeneration, cleanup and
  the speaker label/refresh commands take, so a command already running refuses
  the delete, and one starting during the move fails to lock the recording.
- Afterwards the next row is selected, or the previous one when the deleted row
  was last; deleting a row other than the selected one keeps the selection. A
  folder scan that started before the delete is discarded so the row does not
  come back.
- Voice fingerprints learned from the recording stay in voice memory.
- Not added: ⌘⌫. The list does not pass ⌘⌫ to SwiftUI's key handlers, and an
  Edit-menu item with that shortcut would change ⌘⌫ in the search field.

## Verification

- `swift test`: 236 tests, 11 skipped, 0 failures. New tests in
  `RecordingsLibraryTests`: the folder moves whole (backups and cached responses
  included) while the processing lock is held, and a held lock refuses it; the
  recording in progress, a processing and a queued recording are refused by the
  model and the coordinator and nothing moves; the next or previous row is
  selected and a stale scan does not bring the row back. Tests use a stand-in
  Trash folder, never `~/.Trash`.
- Packaged app (`sh tools/deploy-app.sh`), on throwaway copies of a 25 s
  recording (`cp -c`, retitled "Quill delete test A/B/C"): the right-click menu
  showed **Show in Finder** and **Delete…**; the alert named the copy with its
  date and time; Escape, Return and clicking **Cancel** kept the folder;
  **Delete** after right-click (A, B) and after ⌫ (C) moved each folder to
  `~/.Trash` with every file, and after ⌫ the next row was selected.
- An earlier build presented the alert as a free-standing window when a
  right-click left Quill inactive; it now activates Quill and attaches the sheet
  to the Quill window.

## Needs live validation

- The refusal alert for a recording in progress and for one queued or being
  transcribed, in the packaged app.
- **Put Back** from the Finder Trash restores the folder to `~/Recordings`, and
  it reappears in the list.
