# learning_playback

Learning/media → verified private playback copy → injected Playback Interface →
same-version paused checkpoint coordination. No media_kit dependency, Player,
GUI, microphone, sound output, provider, database or production startup is created.
App-owned Engine/System Adapters remain outside this package.

## Compose the existing modules

`FilePlayableCache(root:, materials:, learning:)` requires matching trusted
owners. Pass its `resolveForEngine(item)` only to the private Engine Adapter;
the resulting file URI must not enter learning DTOs, OS metadata, logs or traces.
`prepare(item)` returns only opaque item/binding/artifact references.

Preparation revalidates learning readiness and the actual material blob, then
copies those bytes under the configured app-private cache root. The partition is
`sha256(utf8('learning-playback:' + owner))`; the immutable destination is
`<learningVersionId>-<mediaVersionId>.wav`. A same-directory `.next` is flushed,
re-read/checked and renamed. Existing cache bytes are length/hash checked and
reused, not blindly trusted or automatically repaired after corruption.
Missing/changed original bytes fail even if a formerly valid cache still exists.
Neither path copies into the original artifact nor publishes its private title.

This is a bounded, single-writer file Adapter. Byte-buffer copies and hashing do
not prove large-media throughput, cross-process exclusion, encryption, an OS
sandbox or power-loss durability. Application cache retention/repair is later
reviewed work; there is no automatic deletion of private source assets.

`LearningPlaybackCoordinator(learning:, playback:, mediaCache:,
readinessTimeout: ...)` composes the injected Interfaces. It does not manufacture
native facts, release SDK hardware or claim real sound from fake Adapter tests.

## Open/restore contract

1. `open(learningVersionId, restorePosition:true)` selects an actual fixed
   learning version/session, prepares its media, and obtains its exact checkpoint.
2. It dispatches **Open only**, never Play. Accepted Open is merely a command
   receipt; phase stays opening/awaitingLoad until the matching session reports
   loaded paused/playing/ended actual state, positive duration, no error and
   duration consistent with verified WAV (within250ms). Duration alone is not load.
3. Only after load, an existing same-binding checkpoint may trigger Seek. Ready
   restoration additionally needs matching seek token, no pendingSeek, actual
   position confirmation and position within the Core's250ms settlement tolerance.
   The snapshot's actual position, never the requested target, is saved.
4. Explicit Pause/Stop/Seek/Play or another session invalidates the older restore
   intent. Canceled restore cannot write default load position0 over the saved
   checkpoint. Subsequent **actual playing** or a confirmed manual Seek may
   unlock new progress; command acceptance alone cannot do so.
5. Timeout returns `pending`, not ready, and does not claim cancellation or start
   sound. A late load does not restart a timed-out automatic restore. Retry is an
   explicit `open`; stale preparation/load/seek completions cannot switch the new
   selected material or attach its label to an old item.

`LearningOpenResult` distinguishes ready/pending/superseded/rejected.
`current`/`snapshots` expose phase, full binding, accepted session token, last
acknowledged checkpoint revision, restoration flag and stable error code.
Ready means this coordination/load stage, **not actual playing**, human listening,
generated English quality, professional scoring, native release or full product.

## Explicit commands and persistence

`dispatch(command)` uses the existing Playback Interface. Open must go through
`open()`; Play/Seek require ready/loaded scope. Pause and Stop remain explicit
actions. System commands still follow the injected PlaybackController/OS Adapter,
not a second direct Engine call path.

Observed real snapshots are checkpointed asynchronously and serially. Owner,
material/source-learning/media binding, active learning session, playback item,
native session/generation and latest command epoch are checked. Pending Seek,
loading, idle reset, invalid anchor, unavailable engine and stale events cannot
write a new version's progress. Equal positions do not need duplicate commits.
`flushProgress()` requires a ready, real loaded/no-pending state; it waits for
queued writes and surfaces checkpoint failure. It is not “save the seek target”.
Only acknowledged revisions are durable; not every frame/event is promised a
write. Stop/close/supersession can discard stale queued observations rather than
write them into a different context.

External checkpoint revision/session conflicts block further automatic writes;
there is no blind retry/merge that overwrites another accepted position. Core
seek failure or unavailable engine produces failed phase plus a stable error
(seek_unconfirmed/playback_unconfirmed/engine_unavailable), not raw engine errors.

`close()` invalidates this coordinator, detaches listeners and drains outstanding
bookkeeping. It does **not** dispose app-owned Playback, MaterialStore,
LearningStore, System/Engine Adapters or prove sensors/native resources stopped.
The app's reviewed Stop/idle/native-release/host lifecycle remains responsible.
Ordinary page unsubscribe must not destroy global playback.

## Background verification

Dependencies are cached exact `crypto:3.0.8` and local material_core,
learning_core/playback_core. Retain lockfile; use approved SDK/cache offline:

```console
dart pub get --offline
dart analyze
dart run test/coordinator_regression.dart
```

Independent tests use actual temporary material/learning/cache files, a separate
Dart process for cache recovery, the real PlaybackController and controlled
Engine/System Adapters. No Player, speaker, microphone, host UI, original user
file, cloud/provider or device permission is used. These tests prove scoped
coordination/IO, not audible playback, hardware cleanup, four-end/native/lockscreen
behavior or production acceptance. See test/README.md for actual results.
