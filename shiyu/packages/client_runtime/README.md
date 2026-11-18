# client_runtime

Thin app-owned assembly of the actual MaterialStore, LearningStore,
LearningPlaybackCoordinator, Playback Interface and ShiyuClientShell Widget.
This is not another domain service, persistence layer, player or native host.

## Ownership and composition

`ShiyuClientRuntime.attach(materials:, learning:, playback:, coordinator:)`
requires the app's already constructed matching-owner stores and playback chain.
The Engine/System Adapters and private cache resolver remain app-owned. Attach
creates only subscriptions and a `ValueNotifier`, no window, native Player,
speaker, microphone, provider, server or synthetic learning content.

`createShell(onLookupWord:..., onPractice:...)` returns the actual reviewed
`ShiyuClientShell` with these stores, `playbackView` and operational callbacks
already wired. Place it inside the app's normal themed widget tree. Dictionary
and practice callbacks remain optional, explicitly provided capabilities; missing
services are not replaced by fake translations, pronunciations or scores.

The Widget receives no Engine, native SDK, cache file URI or coordinator object.
Normal widget unmount must not dispose global playback. `detach()` invalidates
pending bridge work and removes listeners/notifier only; the app remains
responsible for reviewed Stop/idle/native release/host shutdown and closing its
own stores/coordinator after UI teardown. Detach is not a claim hardware stopped.

## Atomic observed view

`playbackView` is a read-only `ValueListenable<ClientPlaybackView>`. Publishing
requires the requested and coordinator full binding to match, the owner and
learning/media item to match, and the actual PlaybackSnapshot token to equal the
coordinator token (including generation and command epoch).
The bridge synchronously reads both current observations instead of attaching a
new label to an older event's callback payload. A selected row, accepted command,
unconfirmed restoration, failed coordinator, missing source or unavailable engine
does not manufacture a ready/playing view. An active snapshot remains its actual
paused/playing/buffering state; ready phase does not mean sound is playing.

## Callbacks

- `openLearning(expectedVersion)` checks the real store's version/binding, calls
  coordinator Open+confirmed restore, and never Play. Pending/rejected opens
  produce stable `ClientRuntimeException` codes. A newer selection invalidates
  older completion; no old callback publishes the new selection's label.
- `command(expectedVersion, command, expectedToken: observedToken)` preflights
  full binding and the exact observed token. The shell callback supplies its
  atomic view token at action time. Open commands must use `openLearning`;
  Play/Seek require a healthy ready coordinator. Pause/Stop can still target a
  matching context to protect playback when readiness failed.
- After dispatch, a superseded selection/session cannot return a receipt as if
  it belonged to the new UI. Receipt accepted is still not an actual engine fact.
- All actual operations go through the coordinator's Playback Interface; no
  direct Engine call or duplicate player ownership is introduced.

This preflight supplements the shell's selection/input/lookup epoch checks and
PlaybackController's native callback scope checks, rather than replacing them.
Caller-provided expected versions/tokens are context guards, not authentication.

## Background verification

Dependencies are the existing Flutter SDK and local packages. Offline resolution
reuses the approved cache; retain `pubspec.lock`. The first Flutter tool attempt
could not write global telemetry state; using per-process analytics suppression
resolved that without changing global settings or granting broader filesystem
write access. No dependency installation or upgrade was performed.

Use the existing SDK, process-only PUB_CACHE/analytics flags as appropriate:

```console
flutter --suppress-analytics pub get --offline
flutter --suppress-analytics analyze --no-pub
flutter --suppress-analytics test --no-pub
```

Tests must use real temporary material/learning/cache IO and controlled
Engine/System Adapters, with the actual Widget returned by `createShell`.
Headless Widget/Interface evidence is not an interactive Windows/Android build,
audible playback, device/lockscreen/camera test, real identity/cloud/Speech
integration or user acceptance. No existing probe, live recording session,
client_shell source or prototype layout is changed by this package.

Implementation smoke: one temporary Flutter-test case actually composed real
temporary stores/cache, the actual `createShell` callbacks and controlled Engine/
System Adapters. It observed Open-not-Play, delayed actual readiness, explicit
Play acceptance versus actual playing, actual-position checkpoint and old-token
rejection. It passed1/1. This case used `--no-test-assets` because it does not
pump/paint the Widget; it is callback assembly evidence, not UI render evidence.
An initial normal asset build failed in the shader compiler on the current
non-ASCII SDK/cache path before running the test. That failure is retained as
an environment limitation; no shader/source/dependency was modified to hide it.
Temporary smoke files/processes were cleaned. Independent persistent package
tests and actual rendered/native app evidence remain Root/QA work.

## Independent persistent QA — 2026-11-18

`test/runtime_integration_test.dart` was actually run with the existing SDK and
locked dependencies, using `flutter --suppress-analytics test --no-pub
--no-test-assets --reporter expanded`: **9/9 passed, exit 0**. Whole-package
`flutter --suppress-analytics analyze --no-pub` returned **No issues found**.

These cases construct real temporary FileMaterialStore/FileLearningStore/cache,
the actual coordinator and PlaybackController, independent controlled Engine/
System Adapters, and the actual `createShell()` Widget. They invoke that Widget's
operational callbacks without pumping or painting it, verifying:

- Open waits for a real adapter observation; accepted Open never auto-Plays.
- Explicit Play acceptance does not fabricate playing; observed 2100ms progress
  is saved and read back through the real learning store.
- Old version events/commands and an old command epoch cannot control or relabel
  the selected learning version.
- Detach invalidates callbacks and late completions without stopping playback or
  closing the externally owned stores/core.
- Stop reset observations preserve the prior checkpoint; fresh explicit Play
  followed by actual playing/progress resumes saving (2100ms then 2800ms readback).

The first test run was 5/6: the late-detach test initially assumed zero lifetime
Stop calls, although Core Open itself retires the preceding pipeline. The final
test compares the actual Stop count immediately before detach against the count
after detach/late load. This preserves the intended no-additional-Stop assertion;
no production code or command behavior was changed to pass it.

A later directed Stop/replay case initially failed with `notReady`: Stop disabled
checkpointing but actual replay never enabled it again. The coordinator owner
fixed checkpoint protection so Stop/old observations do not save reset position,
while a fresh playing intent plus observed playing re-enables recording progress.
The unchanged regression then passed. This is a real logic defect found and fixed,
distinct from the earlier test setup assumption.

Further native-contract review found that the native engine reports `idle` after
Stop, whereas that first replay test used the alternate `paused` observation.
An additional native-like controlled idle case actually failed (fresh Play was
rejected). The coordinator now narrowly admits fresh replay of the same verified,
healthy stopped-idle session; it still waits for actual playing/progress before
saving. The unchanged idle regression passed, preserving 2100ms across Stop and
then reading back actual 2900ms. A negative case also confirms arbitrary idle
without Stop cannot Play and stopped idle cannot Seek. These are controlled
native-contract observations, not execution of media_kit or proof of native replay.

This is persistent callback/IO integration evidence, not a rendered app, native
decoder, audible playback, cloud translation/Speech result or user acceptance.
No host window/input/audio, cloud call, device access or dependency upgrade was
used. To avoid restricted global tool-state writes, only the test processes set
`CI=true` and point `APPDATA`/`LOCALAPPDATA` at a task-owned temporary directory.
Initial sandbox tool-state failures occurred before test execution and are not
counted as code/test passes. The synthetic fixtures are original PCM silence and
supplied text; they are not speech synthesis or generated translations.
