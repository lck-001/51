# App-owned playback validation

Isolated Flutter integration of the reviewed Playback Module, real media_kit Engine Adapter and Android/Windows system hosts. This is a technical validation app, not the complete learning product. The older media capture probe remains separate.

- `lib/main.dart`: explicit audio import/play/pause/seek/stop, generic system metadata and application-shell shutdown. Normal pages do not own the Player.
- `lib/playback/`: actual Native adapters. Engine intent/observation/seek evidence remain separate; unknown native operations do not claim resource release.
- `lib/background_regression.dart`: independent debug-only hidden/muted Windows regression, never attaches to an existing UI process. Requires `--background-regression --silent-validation --synthetic-fixture=<original-WAV>`; native `windowVisible/windowFocused/foreground` must all prove false before Play.
- `windows/runner/`: own HWND SMTC via GetForWindow, generation-scoped callbacks queued back to the Flutter UI thread. No global media-key injection or other applications' sessions.

```console
flutter pub get
flutter analyze --no-pub
flutter build apk --debug --no-pub --target-platform android-x64
flutter build windows --debug --no-pub -t lib/background_regression.dart
```

Run the hidden regression with the flags above and optionally `--report=<private-output.local.json>`. Its lifecycle inputs are **controlled test events**, not a real desktop lock/unlock result. It checks actual native playback facts and SMTC properties, but does not prove audible output, global media keys, hardware capture, or four-platform acceptance. No microphone/camera or ordinary notification permission is added by this probe.

The audio_service path override is a documented fixed-version compatibility patch. Keep its original MIT license and per-file upstream hashes in `../../third_party/audio_service`; only Android Stop differs. Do not edit the shared pub cache or call it the unchanged upstream archive.

media_kit1.2.6 schedules native destruction five seconds after dispose returns. The pinned Adapter keeps the loop/serial queue alive for six seconds before a background host destroys its cached engine. This is a version-specific timer drain, not a guarantee that every hardware/resource operation completed. Timeouts remain unknown and do not authorize concurrent cancellation or automatic playback.

Use only original synthetic fixtures in tests. Source code is versioned; SDKs, runtime receipts, credentials, audio and installable binaries remain local and ignored. Device-specific evidence is recorded separately from pure policy tests.
