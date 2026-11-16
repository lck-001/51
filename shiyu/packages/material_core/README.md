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
- `store.marker`: detects loss of an initialized empty index;
- `artifacts/<random32hex>.blob`: immutable private bytes; `.next` is incomplete.

The JSON envelope is `{schema: 1, payload: {...}, sha256: ...}`; the digest covers
the UTF-8 `jsonEncode(payload)` representation. Payload includes bound owner,
sequence, draft/version records and artifact IDs/hashes; no caller paths.
Schema, IDs, references, version uniqueness and dates are checked before use.

Writes produce a same-directory staged file, flush, re-read/validate, then rename.
Before committing a new index, the previous index is safely written as backup.
Memory changes only after the committed rename. A failed index write blocks
further writes on that instance until reopen; failure is not empty-library success.
File flush plus rename is **not a proven power-loss guarantee**: directory fsync,
filesystem/platform durability and multi-process locking have not been verified.

| Disk state | Observable behavior |
| --- | --- |
| Truly fresh empty partition | Explicit `initialized` report and committed empty index |
| Valid primary + staged candidate | Keep primary; report `pendingWrite`, never promote candidate |
| Missing/corrupt primary + valid backup | Restore backup; report `recoveredFromBackup`/`backupUsed` |
| Neither committed snapshot valid, or only `.next` remains | `corruptStore`, never silently reset an existing library |
| Missing/changed registered blob | Degraded recovery issue; reading those bytes fails explicitly |
| Orphan blob/incomplete blob write | Report orphan/pending; do not invent a draft or automatically delete it |

Fallback may roll back the most recent successful commit; recovery reporting must
remain visible to the caller. It does not promise every latest revision survives.
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
```

The independent regression uses synthetic owners, bytes and temporary directories,
including a separate Dart process for reopen. It does not prove production auth,
PostgreSQL concurrency, cross-process writers, power-loss durability, four-platform
UI, backend/Speech/LLM services, cloud synchronization, or user acceptance.
