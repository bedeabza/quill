# S3 transcript archive

Implemented November 17, 2026.

## Configuration and behavior

- Fresh installations have automatic uploads disabled and empty bucket, region
  and folder fields. Both manual and automatic uploads require a valid, explicitly
  configured destination. Previously saved settings remain unchanged.
- Quill → Transcription → S3 transcript archive configures automatic upload,
  bucket, AWS region, assigned folder and access key ID. Save S3 Settings commits
  the form. A secret must be saved before automatic uploads can be enabled.
  The secret is stored as a macOS Keychain item under
  `com.bedeabza.quill.s3`, indexed by access key ID. Changing the ID cannot reuse
  another account's secret. Config JSON contains only non-secret settings.
- Successful automatic transcriptions and regenerations enqueue uploads after
  processing finishes. A failed transcription never enqueues an upload. S3
  failure is separate from transcription status and never restores or removes a
  successful local transcript. The upload worker prepares the configured title
  before freezing the document. A title-provider failure uses the local fallback.
- CLI transcription also uploads when configured, except disposable `--output`
  previews and `--offline` runs. It waits for the initial upload attempt before
  exiting. Persisted failures remain retryable in the app.
- Applying saved speaker names queues a new revision. Unsaved drafts do not
  upload. Other saved changes are detected by the browser as Changes not uploaded;
  Sync Now sends those changes. Enabling the feature does not upload all
  historical recordings. An old meeting can be uploaded explicitly.

## Document and destination

- One UTF-8 `.md` document is uploaded for each saved meeting revision. The named
  JSON transcript is preferred, otherwise the original is used. Audio, credential
  files and voice embeddings are never selected for upload.
- YAML front matter uses JSON flow values to safely represent Unicode, quotes,
  multiline strings, nested objects and arrays. It includes the displayed title,
  recording ID, the complete `meta.json` object (dates, duration, offsets, local
  speaker, microphone gaps and audio filenames), transcript-level metadata
  (engine, model, creation time, schema, variant and participant roster), speaker
  identities, and available participants, speaker-mapping, postprocessing and
  speaker-refresh metadata. The body contains saved wording, speaker names and
  timestamps. Existing local transcript files are not rewritten by export.
- Keys have the assigned prefix followed by UTC date/time, a bounded title slug
  and a UUID, ending in `.md`. Corrections get a fresh key. Identical successful
  source revisions are not queued again automatically; an explicit Sync Now
  request always creates a fresh copy. No bucket-root uploads are allowed.
- Requests use HTTPS, signed payloads, SHA-256 checksums, AWS Signature V4 and
  signed `If-None-Match: *`. They require object-write permission in the assigned
  prefix, not bucket listing, object reads or ACL modification. The IAM policy
  remains the authority for which folder the credential may write.
- Redirects are refused rather than forwarding the signed body to another host.
  Response bodies, authorization headers and secrets are not logged or shown.
  HTTP 412 is not reported as success: a previous attempt may have succeeded,
  but without read permission it cannot be confirmed. Sync Now chooses a
  fresh key. Existing objects are never overwritten.

## Durable status and retries

- Each discussion has a separate `s3-sync.json` permission record. Block S3 Sync
  saves a persistent block, removes queued work and pending corrections, cancels
  retries, and attempts to cancel an active request. The list, toolbar and detail
  show S3 sync blocked even if an older revision was uploaded successfully.
  Blocking never deletes S3 objects or the saved receipt.
- Sync Now always requests a fresh immutable copy. Unblock & Sync Now explicitly
  clears the block and sends the discussion, including when automatic sync is
  disabled. The request's manual intent persists through retries and restart;
  it does not change the global automatic-sync setting. Allow Automatic Sync
  permits future completions without reviving revoked jobs.
- Permission generations prevent a revoked request from inheriting later
  permission after an unblock. The worker checks permission after title
  preparation and immediately before network access. A separate short control
  lock serializes permission/outbox changes across processes. Unreadable sync
  preferences fail closed. A request already sent may still have completed.
- `s3-upload.json` records destination, key, source signature, payload hash,
  attempts, receipt time, errors and earlier successful locations.
  `.s3-upload.md` is the immutable retry payload, written owner-only. Jobs persist
  before network access. Retries use the same key and bytes, even if a transcript
  has since changed. The UI indicates when the saved transcript is newer than
  the uploaded snapshot.
- The toolbar, recording row and detail header show not uploaded, waiting,
  uploading, uploaded, changed or failed. Details show the destination, receipt
  time, explanation and Sync Now action. Transient failures retry after
  bounded delays while the app is running; startup and settings save resume only
  persisted jobs. Disabling automatic uploads pauses automatic jobs; explicit manual requests
  still run and retry. Blocking a discussion stops both. An already
  in-flight request may finish. Pending jobs never silently move to another
  bucket/folder after settings edits; an explicit upload is required.
- Separate upload/process locks prevent competing writers from changing a
  snapshot during preparation, duplicate concurrent uploads and deleting a
  recording while its upload is active.

## Validation

- Version 1.6.2 adds nine isolated sync-control regression methods. All 118
  targeted regression methods passed in the standalone runner. They cover
  persistent blocks, fresh forced copies, manual retries with automatic sync
  off, revoked retry recovery, queued work and correction cancellation, active
  request cancellation, another process changing permission, malformed
  preferences, validation before unblocking, and the recording controls.
  Allowed and blocked UI states were rendered and visually checked. The new
  checks use temporary recordings, synthetic credentials and injected transport.
  Results: `.build/sync-controls-test-results.log`.
- Debug and release builds; signed app packaged with the developer’s existing signing
  certificate. Strict verification and certificate requirement checked.
- 72 regression methods passed in a standalone runner against production objects, covering the AWS public
  signature vector, Unicode URI encoding, signed no-overwrite headers, prefix
  confinement, named Markdown/metadata, source immutability, success receipts,
  deduplication, revision filenames, restart with identical bytes/key, 412
  ambiguity, disabled/missing-key paths, historical recordings, changed
  destinations, processing locks, secret/config separation, and completion-only
  enqueueing with independent S3 failure status.
- The existing microphone/Zoom, title, naming, export, library and full-window
  layout regressions are included. Full `swift test` remains unavailable because
  this Mac's Command Line Tools do not include XCTest; the standalone runner is
  not a full-suite/CI pass claim.
- Settings and uploaded/failed meeting states rendered with synthetic data.
  Validation artifacts and runner are in `.build/integration-validation/`;
  regression results are in `.build/s3-test-results.log`.
- No real AWS secret was provided. No request was made to the production bucket;
  live IAM permission and upload confirmation remain unverified until the user
  saves the secret and uploads a meeting. Tests use synthetic credentials and
  injected transport. The installed app and real recordings were not replaced,
  restarted or modified.

Protocol references: [AWS PutObject](https://docs.aws.amazon.com/AmazonS3/latest/API/API_PutObject.html)
for conditional writes and [AWS Signature V4](https://docs.aws.amazon.com/AmazonS3/latest/developerguide/sig-v4-header-based-auth.html)
for signing and the published reference vector.
