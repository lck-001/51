# learning_core

Fixed confirmed material → immutable learning version/sentence anchors →
version-bound local progress. This is a single-device, single-writer File
Adapter experiment, not PostgreSQL authority, a user-authentication system,
LLM/TTS/Speech integration or a finished learning interface.

It never creates a Player, dispatches Play, opens windows, uses a microphone,
calls a provider or reads user documents. Verification uses synthetic temporary
files and actual hand-built PCM WAV bytes, not fabricated TTS/assessment results.

## Public Interface and trust

Open with `FileLearningStore.open(root: Directory(...), materials: materialStore)`.
The owner is inherited from the trusted `material_core.MaterialStore`, not a
body parameter. As with material_core, this assumes the application already
validated identity; choosing a trusted owner is not account authentication.

`createVersion(materialVersionId:, sentences:, textProvenance:, media:)` reads
the actual confirmed `MaterialVersion` through material_core; a mutable draft,
another owner's ID or an unknown ID cannot serve as the source. Learning ID,
unit ID, sentence IDs and media-version ID are newly generated opaque IDs.
English/translation input and source binding are immutable after creation.
`readVersion(id)` and `listVersions(materialId: ...)` do not change old versions.
A changed material or authored translation must create a new learning version;
there is no automatic sentence mapping or progress-percentage migration.

`createVersion` continues to accept `manual` and `synthetic` only. Its reference
is a short opaque identifier, not an OS path, signed URL or access token. It
rejects an external origin or an external snapshot attached to manual/synthetic.
External text enters through the reviewed candidate confirmation below, with
declarations explicitly unverified; it is not provider-backed execution evidence,
an AI-generated certification, copyright proof or professional score.

## M19-B1 text learning candidates

The same `FileLearningStore` also implements `LearningCandidateStore`:

```dart
receiveCandidate(sender: ..., input: ...) // private delivery receipt only
readCandidate(candidateId)
listCandidates()
reviseCandidate(candidateId: ..., expectedRevision: ..., sentences: ...)
confirmCandidate(candidateId: ..., expectedRevision: ...) // fixed LearningVersion
rejectCandidate(candidateId: ..., expectedRevision: ...)
```

The App's restricted transport must authenticate the local capability and scopes;
Core is not a verifier. Owner is inherited from its MaterialStore. Sender's
`integrationId` is a stable logical connector ID, never a rotating token/session
ID. `(owner,integrationId,deliveryId)` is persistent semantic-content idempotency:
same content replays the original receipt; changed content conflicts. The first
submission/time/raw transport hash and original `SourceDeclaration` never change
when a token rotates or the user edits text. Transport credentials/paths are not
stored. A local-capability context requires the actual transport body SHA; a
controlled-test context cannot be described as an official assistant identity.

Input references an existing confirmed material ID/version and the SHA256 of its
exact UTF-8 **text**, not its original document artifact. Core reads the actual
MaterialStore version to check owner, IDs and hash; it never guesses Python/Dart
ID mappings. Strings are not normalized, unpaired surrogates and forbidden
controls are rejected before hashing, and sizes use actual UTF-8 bytes.

Candidates remain pendingReview and absent from `listVersions` until the owner
confirms. Original input plus latest correction are retained; intermediate full
text revisions are not an unlimited history. Revision increments on correction
only. Confirm/reject are terminal without changing that fixed text revision;
same-revision confirm returns the identical edition, same-revision reject is
idempotent, stale revision conflicts, and the other terminal action is denied.

Candidate state, `(candidateId,fixed revision)` confirmation link and the new
version are committed in **one** learning snapshot. No public `createVersion`
call is nested in the Store queue; a private record builder is shared. Forward
and backward links, source binding, text and external provenance are validated
on load/commit. A process can die after creating the edition but before sending
its transport acknowledgement; the next confirmation reads that same edition,
not a second version. Confirmation does not select a page, change playback or
dispatch Play.

This first slice is text-only. Its input type has no media; a wire decoder must
reject the presence of a media field with unsupportedMedia, even if null. It must
not silently drop supplied media. A confirmed candidate is partial/readable with
audio_missing; external origin stores the provider's self-declaration separately
from the actual transport record and the owner's correction/confirmation.
B2 media candidates use the separate capability below; the B1 input remains
text-only. There is no fake narration, timing, score or automatically public content.

`LearningCandidateLimits`: 128 bilingual sentences, combined text 100KiB,
declaration 8KiB, 32 pending candidates, and 32MiB actual serialized UTF-8 candidate
records retained across all states. The latter counts original plus latest text;
rejection frees a pending slot but does not delete history or bypass total size.
The transport also needs its own bounded byte stream/deadline/concurrency before
JSON parsing. Candidate metadata caps are not a total disk/large-file throughput
or production multi-user quota guarantee; backups and learning versions are
separate retained data.

## Observable readiness

Readiness is recomputed against the fixed source and actual registered bytes,
not accepted from a caller's boolean or a persisted `ready` field:

| State | Local structural meaning |
| --- | --- |
| pending | No nonblank English sentences have been provided |
| partial | Some English exists, but source/audio/format/complete timing requirements are missing or invalid |
| ready | Every English sentence is nonblank, confirmed source exists, registered audio verifies, supported PCM WAV is structurally valid, and every sentence has a valid time anchor |

Issues explain `english_missing`, `audio_missing`, `media_unavailable`,
`media_unverified`, `timing_invalid` or `material_source_unavailable`.
Missing/changed blobs are not ready merely because metadata references them.
`ready` is only this local English/audio structure, not proven translation
quality, naturalness, language classification, valid pedagogy, speech scoring,
human listening, all-platform decoding or AI generation. Translations may be
empty; that does not mean a bilingual translation service has run or succeeded.

The first verifier deliberately handles RIFF/WAVE PCM format1 with checked
container/chunk sizes, sample/byte rate, block alignment and bit depth. Actual
duration is derived from byte count/rate. Other codecs and malformed containers
remain partial; there is no claim of decoding all formats or hearing the audio.
Timings use sentence index and milliseconds: one per sentence, nonnegative,
end after start, no overlap and within the verified duration. Gaps are allowed.
Invalid timing yields partial and no usable position anchors, not invented ones.
Buffer-based audio reads and whole-cache startup verification are not large-file
streaming or performance-qualified behavior; that requires later Adapter work.

## Playback descriptor and paused checkpoints

- `openPlayback(learningVersionId)` requires current structural readiness and
  returns `LearningPlaybackSession`, not a real player command. It invalidates
  the instance's older session, including when a new open attempt cannot finish.
- The returned `PlaybackItem` has owner, learning ID as `itemId`, media-version
  ID as `itemRevision`, and audio kind. `mediaArtifactFor(item)` verifies all
  these fields and readiness, returning an opaque material_core `ArtifactRef`.
  Filesystem/SDK resolution belongs to the private platform Adapter.
- `saveProgress(session:, expectedRevision:, sentenceId:, position:)` checks
  active session, full owner/material/material-version/learning/media binding,
  anchor and position. A first checkpoint requires revision0; successful writes
  return1,2,…; stale revisions/session callbacks cannot overwrite later state.
- Position must lie within the chosen sentence and verified media duration.
  Persistence uses integer milliseconds; no seek/visual/decoder completion is
  inferred from this write.
- `restoreProgress(id)` returns null if that version has no checkpoint. Existing
  checkpoints are returned only while source/media remain structurally ready;
  missing content causes explicit notReady, never a playable fake result.
- A restored checkpoint/session's `resumeIntent` is always
  `PlaybackIntent.paused`. Sessions are memory-only and do not survive reopen.
  No caller can save playing intent through this Interface; cold restoration
  never dispatches Play or revives a prior session.

The application's Playback Interface remains responsible for actual engine state,
focus, interruption, capture blocking and approved explicit user Play. Neither a
checkpoint nor an opaque item is evidence that audio played or reached a frame.

## B2 structure-only media candidates

`FileLearningStore` additionally implements `LearningMediaCandidateStore` with
`receiveMediaCandidate(sender:, input: LearningMediaCandidateInput(text:, media:))`.
Existing candidate read/revise/confirm/reject methods are reused; existing Store
interfaces gain no required methods. Candidate/version/media views add optional
media review/details fields. This does not expose an upload or transport endpoint.

V2 uses the same `(owner,integration,delivery)` namespace as B1. Changed content or
switching B1/v2 under that key conflicts. Semantic payload hashing excludes random
artifact IDs, transient grants and receipt times; equal actual bytes registered
under another ref replay the original candidate without replacing its audit ref.
The actual immutable source text and exact ordered English JSON array are hashed
independently, and registered bytes are read through MaterialStore before trust.

External PCM policy requires canonical RIFF/WAVE PCM16 mono 16kHz, one fmt/data,
exact lengths, at most 2MiB and at most 960000 samples (60 seconds). Ordered unique
sentence timings must be nonoverlapping and within actual sample duration.
Legacy manual/synthetic PCM retains its prior broader policy. Declarations and
8KiB combined audio/timing statements are unverified; no speech/quality/alignment
inference follows from a WAV container or synthetic fixture. Ready is structural.

Original media/ref/English binding/declarations/timings remain immutable audit.
Translation-only edits retain matching media. Any exact English/ordering/count
change records sticky invalidation at that revision. Reverting English does not
reattach audio; a new media delivery/candidate is required. Matched confirmation
rechecks actual source/media/format/timings and refuses missing/corrupt media.
Invalidated confirmation may create an explicitly text-only partial edition even
when the old blob is unavailable, retaining its ref and diagnostic audit; valid
source/revision/audit and both Store recovery gates still apply. Text provenance
and media.provenance.external share the complete text confirmation context,
including its text declaration. Audio declaration is separately preserved in
originalMedia and externalDetails and validated against those fields.

A fixed candidate revision and its new immutable edition commit together, including
media provenance/ref/timings when matched. Replays reuse the edition; a new media
candidate never overwrites a prior partial edition, sentence IDs or checkpoint.
No page selection, progress copying or Player is invoked.

`inspectExternalCandidateMedia(bytes:, timings:, sentenceCount:)` exposes the same
strict pure container/timing preflight used by receive and matched confirmation.
It bounds bytes/count/list before parsing or hashing and returns immutable actual
SHA256, byte length and display duration. Timing limits use actual sample/byte
arithmetic; display milliseconds do not relax the 60-second or end bounds. It
performs no IO, registration, source lookup or speech/alignment assessment.

`LearningMediaCandidateStore.findDeliveryReceipt(sender:, deliveryId:,
inputVersion:, expectedPayloadSha256:)` directly checks the existing trusted-owner
delivery map and immutable submission. Versions1/2 share a namespace; version or
semantic-hash mismatch conflicts, only an absent key returns null. Existing
pending/confirmed/rejected candidates return the same neutral replayed receipt.
This reads no source/blob/list, changes no snapshot/sequence/audit and adds no
index. Closed/hold/write-uncertainty and Material media gates precede early
returns. The receipt proves delivery existence, not current media availability;
actual submission still revalidates source and bytes.

## File/recovery contract for independent tests

Within the private configured root, the partition is
`sha256(utf8('learning-owner:' + materials.trustedOwnerId))`. It contains
`learning.json`, `learning.bak`, `learning.next`, `learning.bak.next`, possible
`learning.recovery.next`, and `store.marker`. This namespace is separate from
material_core even when both receive the same root.
Current envelope is schema3. Readers accept schemas1/2 and retain the original
manual/synthetic/external text records and paused checkpoints. V2 candidates carry
inputVersion2, originalMedia and optional first-invalidation metadata. Old B1
records default to inputVersion1 when absent and are not expanded during migration;
explicit1 also remains text-only. Actual complete candidate records still count
against the existing 32MiB/32-pending quota; no allowance or eviction is added.

Migration archives the original validated schema1/2 snapshot, then writes backup3,
primary3 and marker3. A genuine first initialization may lack a backup; a corrupt,
unreadable or non-file backup is never treated as absent. Interrupted migration
resumes only with a validated original archive and equivalent projected snapshots.
The schema boundary is one-way and inconsistent/unknown marker states hold. Legacy
archives are diagnostic evidence, never automatic fallback after the boundary.

This is **new readers of old data**, not a downgrade compatibility claim. Old
binaries reopening completed schema3 cannot read primary or backup. An old
writer already running in memory may ignore new protocols, so upgrades require
the old learning instance to end first. The owning App must enforce its root OS
lock for cooperating new processes; this FileStore itself remains single-writer
and does not close another application or the user's recording program.

The digest covers UTF-8 `jsonEncode(payload)`. Schema/IDs/provenance/reference
relations and paused checkpoint intent are validated on reopen.

Same-directory staged write → flush → re-read/check → rename; the previous
validated snapshot is written as backup. Memory advances only after commit.
Write uncertainty persists a recovery hold. Before any older-backup restoration,
a hold must be durably written; failure to fence means recovery fails without
rewriting the damaged primary. Fallback may lose a recent delivery/confirmation,
so it cannot silently return an absent operation as a new one. The independent
learning.recovery.hold file (or incomplete .next) survives restart; no automatic
release/rebuild/clear path exists. All snapshot writes, terminal/replay shortcuts,
candidate queries and new playback admission reject recoveryHold. Verifiable
historical version/checkpoint reads remain available and never dispatch Play.
Both Material/Learning gates are rechecked immediately before a V2 persistent
action; an already-entered commit may finish. This is not a cross-Store transaction
or a claim that a later hold cancels an in-flight write.
An existing corrupt store or only a staged candidate never becomes empty success.
Staged files are not promoted as committed progress. Missing media/source is
reported as degraded where detected and checked again on version reads.
`recoveryReport` is a startup/recovery report, not a continuously updated health
monitor; a later read's readiness reflects later missing media independently.

Opaque IDs, owner partitioning and symlink checks do not form an OS sandbox or
encryption. Cache text is private plaintext for the application; checksums are
not MACs against a privileged filesystem user. File flush/rename does not prove
directory-fsync/power-loss durability, cross-process exclusion or distributed
transactions. `close()` closes this store, not the caller-owned MaterialStore.

## Background checks

Dependencies are exact cached `crypto:3.0.8` plus local material_core/playback_core;
retain `pubspec.lock`. Use the already approved SDK/cache; no installation,
global PATH change or dependency update is required.

```console
dart pub get --offline
dart analyze
dart run test/learning_store_regression.dart
dart run test/candidate_local_regression.dart
dart run test/candidate_independent.dart
dart run test/media_candidate_regression.dart
dart run test/media_seams_regression.dart
```

Independent tests use temporary FileIO and a separate Dart process for paused
restore. They do not open audio/UI or prove PostgreSQL, real users/authentication,
true speech quality, provider outputs, devices or product acceptance.

The existing learning-version/checkpoint suite was rerun unchanged: 25/25.
The supplemental candidate suite actually passed 4/4, including reopen-confirm
uniqueness, source declarations, capability rotation, Unicode/UTF-8 limits and
pending quota. Candidate confirmation acknowledgement-gap and migration evidence
come from the independent suite's final report; they are not inferred from the
in-process supplemental checks. No transport, assistant connection or audible
learning acceptance is claimed by these Core tests.
