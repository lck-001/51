# material_core

M16 file-backed **single-device, single-writer private cache/draft Adapter**.
This is a real FileIO module, not PostgreSQL, a multi-process transaction engine,
account authentication, a parser, an AI generator or a production storage choice.
It does not open a window, record, play media, contact a service or use user files.

## Public Interface

`FileMaterialStore.open(root: Directory(...), trustedOwnerId: validatedOwner)`
binds an instance to an identity already validated by its owning application.
Choosing another `trustedOwnerId` is not login: an untrusted request must never be
allowed to choose it. No service-side multi-tenant security claim is made.

- `createDraft(title:, text:, artifacts:)` saves pasted text and registered blobs.
- `readDraft(id)`, `listDrafts()` read only the bound owner's partition.
- `updateDraft(materialId:, expectedRevision:, title:, text:, artifacts:)`
  requires the current edit revision, then increments it; stale writes fail.
- `confirmVersion(materialId:, expectedRevision:)` creates an immutable snapshot.
  Re-confirming the same edit revision returns the same version. It does not
  increment the draft revision. `readVersion` and `listVersions` keep old content.
- `importArtifact(Uint8List)` stores uninterpreted bytes in a new blob, copying
  the caller's input first. `readArtifact(ArtifactRef)` checks registration,
  owner, byte length and SHA-256; the Interface exposes no filesystem path.
- `FileMaterialStore` also implements `IdempotentArtifactStore`:
  `registerArtifactOnce(operationKey:, expectedSha256:, bytes:)` binds one trusted
  application-derived, lowercase 64-hex key to one artifact. It bounds input
  before copying, recomputes the complete digest, and compares actual persisted
  bytes on replay. Identical bytes return the original reference; different bytes
  conflict. `findArtifactRegistration(key)` is read-only and verifies the blob.
  The Store validates key syntax, not the caller's business authorization.
  The App must derive the key from an unambiguous versioned domain plus trusted
  owner/integration/delivery identity, excluding media hash and temporary grants.
  Limits for **new registrations** are 2MiB per artifact, 128 retained operations
  and 64MiB of actual artifact-directory files, including legacy imports,
  orphans and incomplete/unknown files. These are not a global Store disk quota;
  legacy import retains its existing semantics. No operation eviction/GC exists.
- `recoveryReport` describes startup recovery or degradation; `close()` drains
  already queued operations and rejects subsequent operations.

Only the File Adapter resolves paths. Identifiers are random 128-bit lowercase
hex; owner text (including slashes) is hashed for path isolation. Unknown foreign
draft/version IDs return `notFound`; a foreign artifact reference is denied.
ID traversal is rejected, expected directories/files may not be symlinks, and
public errors contain enum codes and optional opaque IDs, not raw OS exceptions.
This is not an OS sandbox: a privileged local user can access plaintext cache
files, replace their content, or race filesystem operations. Checksums detect
accidental corruption; they are not signatures or proof against that user.

## Persistence and documented recovery layout

Within the configured private root, the owner partition is
`sha256(utf8('owner:' + trustedOwnerId))`. It contains:

- `manifest.json`: committed index with drafts, immutable versions and blob refs;
- `manifest.bak`: the previous validated commit, not a full history/remote backup;
- `manifest.next`, `manifest.bak.next`: staged candidates;
- `manifest.recovery.next`: staged repair from a validated backup;
- `store.marker`: `material_core:2`, a one-way schema boundary;
- `registration.hold`, `registration.hold.next`: persistent recovery fencing;
- `artifacts/<random32hex>.blob`: immutable private bytes; `.next` is incomplete.

The JSON envelope is `{schema: 2, payload: {...}, sha256: ...}`; the digest covers
the UTF-8 `jsonEncode(payload)` representation. Payload includes bound owner,
sequence, draft/version records, artifact IDs/hashes and `artifactOperations`;
operation bindings and registered refs commit in the same snapshot. No caller paths.
Schema, IDs, references, version uniqueness and dates are checked before use.

Writes produce a same-directory staged file, flush, re-read/validate, then rename.
Before committing a new index, the previous index is safely written as backup.
Memory changes only after the committed rename. A failed index write blocks
further writes and persists a recovery hold; reopen never silently clears that
hold. Failure is not empty-library success.
File flush plus rename is **not a proven power-loss guarantee**: directory fsync,
filesystem/platform durability and multi-process locking have not been verified.

| Disk state | Observable behavior |
| --- | --- |
| Truly fresh empty partition | Explicit `initialized` report and committed empty index |
| Valid primary + staged candidate | Keep primary; report `pendingWrite`, never promote candidate |
| Missing/corrupt primary + valid backup | Persist hold before restore; report `recoveredFromBackup`/`backupUsed` and `registrationHold` |
| Neither committed snapshot valid, or only `.next` remains | `corruptStore`, never silently reset an existing library |
| Missing/changed registered blob | Degraded recovery issue; reading those bytes fails explicitly |
| Orphan blob/incomplete blob write | Report orphan/pending; do not invent a draft or automatically delete it |

Fallback may roll back the most recent successful commit; recovery reporting must
remain visible to the caller. It does not promise every latest revision survives.
Hold rejects all snapshot-changing calls and operation queries with `recoveryHold`;
available historical reads still verify integrity. An absent key in an older backup
is never reported as proof that an operation did not happen. No automatic hold
release API is provided. If hold cannot be persisted, recovery fails before restore.

Schema1 migration validates the primary and legacy marker, writes schema2 backup
first, then schema2 primary, then marker2. A normal legacy first initialization
has a primary and marker1 but no backup; it migrates without hold when no fault or
migration residue exists. A corrupt/unreadable/non-file backup is not absence.
Interrupted migration resumes only when old fields and sequence are identical and
operation mappings empty. Unknown/missing markers or inconsistent schema boundaries
hold rather than downgrade. Both schema2 copies reject old schema1 readers, but a
previously resident noncooperating old writer cannot be stopped by a marker: stop
old instances before upgrading and retain the App's single-writer lock boundary.
Startup currently checks all registered blob hashes using streaming IO. This is
an intentionally bounded cache proof; large libraries need a separately reviewed
validation/index strategy. Import/read use byte buffers and are not a large-video
streaming uploader. No retention deletion or automatic garbage collector is added.

## Verification

Dependency is pinned to `crypto: 3.0.8`; retain `pubspec.lock`. Use the approved
existing SDK/cache and `dart pub get --offline`; no system PATH/tool changes.

```console
dart analyze
dart run test/file_store_regression.dart
dart run test/registration_regression.dart
```

The independent regression uses synthetic owners, bytes and temporary directories,
including a separate Dart process for reopen. It does not prove production auth,
PostgreSQL concurrency, cross-process writers, power-loss durability, four-platform
UI, backend/Speech/LLM services, cloud synchronization, or user acceptance.
Registration regressions additionally hard-stop only owned `dartvm.exe` children,
after their reported PID matches `Process.pid`, at real rename checkpoints for
migration, blob-before-index failure and commit/ACK gaps. These are process-crash
tests, not a claim about filesystem power-loss durability.
