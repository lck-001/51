# audio_service 0.18.19 compatibility patch

Original source: https://pub.dev/packages/audio_service/versions/0.18.19 . Original MIT LICENSE and runtime platform sources are retained. `UPSTREAM.json` records original per-file SHA256 and the published archive hash; this patched source must not be described as the untouched upstream archive.

Exactly one upstream file is changed: Android `AudioService.stop()` invokes existing `exitForegroundState()` before its existing deactivation/stopSelf calls. A service with a live MediaBrowser binding can remain alive after stopSelf; the observed test run had inactive/NONE media state and startRequested=false but retained foreground ownership. Exiting foreground there also releases the existing wake lock; onDestroy remains idempotent via its held check.

This leaves ordinary Pause with androidStopForegroundOnPause=false unchanged, retaining a legally started host for target36 background resume. It does not fake playing, add a media engine, request focus, grant permissions, or change Apple/web behavior. The app still verifies real native state, and confirmed native playback stop/callback drain precedes background host retirement.

Remove the path override only after an upstream version contains an equivalent fix and the same runtime matrix passes. Do not edit the shared pub cache. This is an isolated validation dependency override, not release approval.
