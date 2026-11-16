import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:playback_core/playback_core.dart';

import 'playback/media_kit_engine.dart';
import 'playback/windows_playback_host.dart';

/// Separate debug entry, built with -t lib/background_regression.dart.
/// Native --background-regression MUST keep its own HWND and child unfocused
/// and hidden before this entry starts. Never attaches to an existing UI app.
Future<void> main(List<String> args) async {
  if (!kDebugMode ||
      !Platform.isWindows ||
      !args.contains('--background-regression') ||
      !args.contains('--silent-validation')) {
    stdout.writeln(
      jsonEncode({
        'schema': 'shiyu.windows.background-regression.v1',
        'passed': false,
        'failure': 'debug_windows_hidden_silent_flags_required',
        'playRequested': false,
      }),
    );
    exit(64);
  }
  final fixtureArg = args
      .where((a) => a.startsWith('--synthetic-fixture='))
      .toList();
  final reportArg = args.where((a) => a.startsWith('--report=')).toList();
  if (fixtureArg.length != 1 || reportArg.length > 1) {
    stdout.writeln(
      jsonEncode({
        'schema': 'shiyu.windows.background-regression.v1',
        'passed': false,
        'failure': 'exactly_one_synthetic_fixture_required',
        'playRequested': false,
      }),
    );
    exit(64);
  }
  try {
    WidgetsFlutterBinding.ensureInitialized();
    MediaKit.ensureInitialized();
  } catch (_) {
    final result = {
      'schema': 'shiyu.windows.background-regression.v1',
      'passed': false,
      'failure': 'binding_or_native_library_initialization_failed',
      'playRequested': false,
      'cleanupConfirmed': true,
    };
    if (reportArg.isNotEmpty) {
      try {
        final file = File(reportArg.single.substring('--report='.length));
        await file.parent.create(recursive: true);
        await file.writeAsString(jsonEncode(result), flush: true);
      } catch (_) {}
    }
    stdout.writeln('SHIYU_BACKGROUND_REGRESSION_RESULT ${jsonEncode(result)}');
    exit(1);
  }
  // There is no user-facing interface. Native hidden mode also suppresses the
  // usual first-frame Show/child SetFocus; a tiny tree only drives Flutter init.
  runApp(const SizedBox.shrink());
  var frameObserved = true;
  await WidgetsBinding.instance.endOfFrame.timeout(
    const Duration(seconds: 3),
    onTimeout: () {
      frameObserved = false;
    },
  );
  final runner = _BackgroundRegression(
    File(fixtureArg.single.substring('--synthetic-fixture='.length)),
    reportArg.isEmpty
        ? null
        : File(reportArg.single.substring('--report='.length)),
    frameObserved: frameObserved,
  );
  await runner.run();
}

final class _RegressionFailure implements Exception {
  const _RegressionFailure(this.code);
  final String code;
}

final class _BackgroundRegression {
  _BackgroundRegression(
    this.fixture,
    this.report, {
    required this.frameObserved,
  });
  final File fixture;
  final File? report;
  final bool frameObserved;
  final _elapsed = Stopwatch()..start();
  final _steps = <Map<String, Object?>>[];
  final _snapshots = <Map<String, Object?>>[];
  WindowsPlaybackHost? _host;
  MediaKitEngine? _engine;
  PlaybackController? _playback;
  StreamSubscription<PlaybackSnapshot>? _subscription;
  bool _playRequested = false, _closing = false, _unsafeBeforePlay = false;
  int? _originalLength;
  DateTime? _originalModified;
  String? _failure;
  bool _cleanupConfirmed = false;
  bool _nativeSmtcConfirmed = false;

  PlaybackController get playback => _playback!;
  WindowsPlaybackHost get host => _host!;
  MediaKitEngine get engine => _engine!;

  void _check(bool value, String code) {
    if (!value) throw _RegressionFailure(code);
  }

  void _record(String name, Map<String, Object?> evidence) {
    _steps.add({
      'step': name,
      'elapsedMs': _elapsed.elapsedMilliseconds,
      ...evidence,
    });
  }

  Map<String, Object?> _snapshot(PlaybackSnapshot s) => {
    'intent': s.intent.name,
    'actual': s.actual.name,
    'positionMs': s.position.inMilliseconds,
    'durationMs': s.duration?.inMilliseconds,
    'generation': s.generation,
    'commandEpoch': s.commandEpoch,
    'engineAvailable': s.engineAvailable,
    'hostReady': s.hostReady,
    'controlledForeground': s.foreground,
    'requiresFreshPlay': s.requiresFreshPlay,
    'pauseCauses': s.pauseCauses.map((c) => c.name).toList(),
    'pendingSeek': s.pendingSeek != null,
    'seekPositionApplied': s.seekPositionApplied,
    'seekFrameReady': s.seekFrameReady,
    'errorPresent': s.error != null,
  };

  Future<PlaybackSnapshot> _waitSnapshot(
    bool Function(PlaybackSnapshot) condition,
    String code, {
    Duration timeout = const Duration(seconds: 15),
    bool allowRecovery = false,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final current = playback.current;
      if (condition(current)) return current;
      if (!allowRecovery &&
          (!current.engineAvailable ||
              current.actual == PlaybackActual.failed)) {
        throw _RegressionFailure('${code}_engine_unconfirmed');
      }
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
    throw _RegressionFailure('${code}_timeout');
  }

  Future<Map<String, Object?>> _waitNative(
    bool Function(Map<String, Object?>) condition,
    String code,
  ) async {
    final deadline = DateTime.now().add(const Duration(seconds: 12));
    Map<String, Object?>? lastNative;
    while (DateTime.now().isBefore(deadline)) {
      final state = await host.diagnosticStatus();
      lastNative = state;
      if (condition(state)) return state;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (lastNative != null) _record('${code}_last_native', lastNative);
    throw _RegressionFailure('${code}_timeout');
  }

  void _hidden(Map<String, Object?> state) {
    _check(state['windowAlive'] == true, 'own_window_not_alive');
    _check(state['windowVisible'] == false, 'own_window_visibility_not_false');
    _check(state['windowFocused'] == false, 'own_window_focus_not_false');
    _check(state['nativeForeground'] == false, 'own_window_became_foreground');
  }

  Future<void> _dispatch(PlaybackCommand command, String code) async {
    _check(!_closing, 'commands_frozen');
    final result = await playback.dispatch(command);
    _check(result.status == CommandStatus.accepted, '${code}_not_accepted');
    _record(code, {
      'command': command.runtimeType.toString(),
      'accepted': true,
    });
  }

  Future<void> _validateFixture() async {
    _check(
      fixture.uri.pathSegments.last == 'english-playback-check.wav',
      'original_synthetic_fixture_name_required',
    );
    _check(await fixture.exists(), 'fixture_missing');
    final stat = await fixture.stat();
    _check(
      stat.size >= 44 && stat.size < 32 * 1024 * 1024,
      'fixture_size_invalid',
    );
    final input = await fixture.open();
    try {
      final header = await input.read(12);
      _check(
        header.length == 12 &&
            ascii.decode(header.sublist(0, 4)) == 'RIFF' &&
            ascii.decode(header.sublist(8, 12)) == 'WAVE',
        'fixture_not_riff_wave',
      );
    } finally {
      await input.close();
    }
    _originalLength = stat.size;
    _originalModified = stat.modified;
    _record('fixture', {
      'riffWave': true,
      'bytes': stat.size,
      'usesOriginalReadOnlyFile': true,
      'provenance': 'caller_supplied_synthetic_fixture',
    });
  }

  Future<void> run() async {
    try {
      await _validateFixture();
      _host = await WindowsPlaybackHost.create();
      final native = await host.diagnosticStatus();
      _hidden(native);
      _check(
        native['configured'] == true && native['supported'] == true,
        'real_smtc_not_supported',
      );
      _nativeSmtcConfirmed = true;
      _record('native_hidden_preflight', native);
      late final PlaybackController controller;
      _engine = MediaKitEngine(
        resolve: (item) {
          if (item.ownerId != 'background-regression' ||
              item.itemId != 'original-synthetic-wave' ||
              item.itemRevision != '1') {
            throw StateError('synthetic_scope_mismatch');
          }
          return fixture.uri.toString();
        },
        beforePlay: host.preparePlay,
        currentScope: () => controller.current.token,
        silentValidation: true,
      );
      controller = PlaybackController(engine: engine, system: host);
      _playback = controller;
      host.beforeWindowClose = engine.releaseNative;
      host.onClosingChanged = (closing) => _closing = closing;
      host.bind(controller);
      _subscription = controller.snapshots.listen((s) {
        if (!_playRequested && s.actual == PlaybackActual.playing) {
          _unsafeBeforePlay = true;
        }
        if (_snapshots.length >= 200) _snapshots.removeAt(0);
        _snapshots.add({
          'elapsedMs': _elapsed.elapsedMilliseconds,
          ..._snapshot(s),
        });
      });
      // These are deliberate software lifecycle inputs, not desktop actions.
      host.appForeground(true);
      _record('controlled_lifecycle', {
        'foreground': true,
        'realWindowActivation': false,
      });
      await _dispatch(
        const Open(
          PlaybackItem(
            ownerId: 'background-regression',
            itemId: 'original-synthetic-wave',
            itemRevision: '1',
            kind: MediaKind.audio,
          ),
        ),
        'open',
      );
      final loaded = await _waitSnapshot(
        (s) =>
            s.actual == PlaybackActual.paused &&
            s.duration != null &&
            s.duration! > const Duration(seconds: 12),
        'open_loaded_paused',
      );
      _check(
        loaded.intent == PlaybackIntent.paused && !_unsafeBeforePlay,
        'open_autoplay_observed',
      );
      _record('open_observed', {..._snapshot(loaded), 'noAutoplay': true});
      _hidden(await host.diagnosticStatus());
      _check(engine.silentValidation, 'per_player_silent_guard_not_enabled');
      _playRequested = true;
      await _dispatch(const Play(), 'play');
      await _waitSnapshot(
        (s) =>
            s.actual == PlaybackActual.playing &&
            s.intent == PlaybackIntent.playing,
        'play_observed',
      );
      await _waitSnapshot(
        (s) => s.position >= const Duration(milliseconds: 500),
        'native_position_advanced',
      );
      final publishedPlaying = await _waitNative(
        (s) =>
            s['enabled'] == true &&
            s['playbackStatus'] == 'playing' &&
            s['genericMetadata'] == true,
        'native_smtc_playing_generic',
      );
      _hidden(publishedPlaying);
      _record('real_sdk_and_smtc_playing', {
        ...publishedPlaying,
        'core': _snapshot(playback.current),
        'muteMechanism': 'per-player setVolume(0) awaited before native Play',
        'acousticAudibilityMeasurement': false,
      });
      _check(
        await host.backgroundHostReady(),
        'native_background_host_not_ready',
      );
      final beforeBackground = playback.current.position;
      host.appForeground(false);
      _record('controlled_lifecycle', {
        'foreground': false,
        'realWindowActivation': false,
      });
      await _waitSnapshot(
        (s) =>
            !s.foreground &&
            s.actual == PlaybackActual.playing &&
            s.position > beforeBackground + const Duration(milliseconds: 400),
        'controlled_background_continues',
      );
      await _dispatch(const Pause(), 'pause');
      final paused = await _waitSnapshot(
        (s) =>
            s.actual == PlaybackActual.paused &&
            s.intent == PlaybackIntent.paused,
        'pause_observed',
      );
      final pausedAt = paused.position;
      host.appForeground(true);
      _record('controlled_lifecycle', {
        'foreground': true,
        'realWindowActivation': false,
      });
      await Future<void>.delayed(const Duration(milliseconds: 600));
      _check(
        playback.current.intent == PlaybackIntent.paused &&
            playback.current.actual == PlaybackActual.paused &&
            (playback.current.position - pausedAt).abs() <=
                const Duration(milliseconds: 100),
        'controlled_foreground_auto_resumed_or_position_advanced',
      );
      final nativePaused = await _waitNative(
        (s) => s['playbackStatus'] == 'paused',
        'native_smtc_paused',
      );
      _hidden(nativePaused);
      _record('pause_preserved_across_controlled_lifecycle', {
        ...nativePaused,
        'core': _snapshot(playback.current),
      });
      await _dispatch(const Seek(Duration(seconds: 5)), 'seek');
      final sought = await _waitSnapshot(
        (s) =>
            s.pendingSeek == null &&
            s.seekPositionApplied &&
            (s.position - const Duration(seconds: 5)).abs() <=
                const Duration(milliseconds: 250),
        'seek_position_applied',
      );
      _check(
        sought.actual == PlaybackActual.paused,
        'seek_unexpectedly_started_playback',
      );
      _record('seek_observed_audio_position_only', {
        ..._snapshot(sought),
        'videoFrameEvidence': false,
      });
      await _dispatch(const Play(), 'replay_after_seek');
      await _waitSnapshot(
        (s) =>
            s.actual == PlaybackActual.playing &&
            s.position > const Duration(milliseconds: 5400),
        'replay_after_seek_observed',
      );
      _check(
        await host.backgroundHostReady(),
        'second_host_readiness_unconfirmed',
      );
      host.appForeground(false);
      _record('controlled_lifecycle', {
        'foreground': false,
        'realWindowActivation': false,
      });
      await _dispatch(const Stop(), 'stop');
      await _waitSnapshot(
        (s) =>
            s.intent == PlaybackIntent.stopped &&
            s.actual == PlaybackActual.idle &&
            s.engineAvailable,
        'stop_observed',
      );
      final retired = await _waitNative(
        (s) =>
            s['enabled'] == false &&
            s['retired'] == true &&
            s['metadataCleared'] == true,
        'native_smtc_retired',
      );
      _hidden(retired);
      _record('real_native_retired', {
        ...retired,
        'core': _snapshot(playback.current),
      });
      final denied = await playback.dispatch(const Play());
      _check(!denied.accepted, 'retired_background_play_was_accepted');
      _record('retired_background_play_rejected', {
        'status': denied.status.name,
      });
      final after = await fixture.stat();
      _check(
        after.size == _originalLength && after.modified == _originalModified,
        'original_fixture_changed',
      );
    } on _RegressionFailure catch (failure) {
      _failure = failure.code;
    } catch (_) {
      // No exception string: SDK errors can carry file paths or opaque URLs.
      _failure = 'unexpected_adapter_or_harness_failure';
    } finally {
      await _cleanup();
    }
    final result = <String, Object?>{
      'schema': 'shiyu.windows.background-regression.v1',
      'passed': _failure == null && _cleanupConfirmed,
      'failure': _failure,
      'playRequested': _playRequested,
      'silentValidation': true,
      'usesRealCore': _playback != null,
      'usesRealMediaKitEngine': _engine != null,
      'usesRealOwnHwndSmtc': _nativeSmtcConfirmed,
      'fakeAdapterUsed': false,
      'controlledLifecycleOnly': true,
      'firstFrameObserved': frameObserved,
      'firstFrameRequiredForNativePreflight': false,
      'realLockScreenVerified': false,
      'globalMediaKeysInvoked': false,
      'desktopInputOrActivationRequested': false,
      'videoOrAcousticAssessmentClaimed': false,
      'cleanupConfirmed': _cleanupConfirmed,
      'ownerCleanupRequired': !_cleanupConfirmed,
      'elapsedMs': _elapsed.elapsedMilliseconds,
      'steps': _steps,
      'snapshots': _snapshots,
    };
    if (report != null) {
      try {
        await report!.parent.create(recursive: true);
        await report!.writeAsString(
          const JsonEncoder.withIndent('  ').convert(result),
          flush: true,
        );
      } catch (_) {
        result['passed'] = false;
        result['failure'] = 'report_write_failed';
      }
    }
    stdout.writeln('SHIYU_BACKGROUND_REGRESSION_RESULT ${jsonEncode(result)}');
    if (_cleanupConfirmed) {
      // Only this isolated hidden process; all owned media callbacks drained.
      exit(result['passed'] == true ? 0 : 1);
    }
    // Do not destroy a Flutter engine with unconfirmed native callbacks. Root's
    // bounded launcher receives this failure receipt and owns explicit recovery
    // of this new hidden process, never the existing live UI probe.
    await Completer<void>().future;
  }

  Future<void> _cleanup() async {
    final controller = _playback;
    final localEngine = _engine;
    final localHost = _host;
    if (controller == null && localEngine == null) {
      try {
        if (localHost != null) await localHost.close();
        _cleanupConfirmed = true;
      } catch (_) {
        _failure ??= 'host_cleanup_unconfirmed';
      }
      return;
    }
    try {
      if (controller == null || localEngine == null || localHost == null) {
        throw const _RegressionFailure(
          'partial_initialization_cleanup_unconfirmed',
        );
      }
      _closing = true;
      await controller.dispatch(const Stop());
      await _waitSnapshot(
        (s) =>
            s.intent == PlaybackIntent.stopped &&
            s.actual == PlaybackActual.idle &&
            s.engineAvailable,
        'cleanup_stop',
        allowRecovery: true,
      );
      final expected = controller.current.token;
      await localEngine
          .releaseNative(expected)
          .timeout(const Duration(seconds: 15));
      _check(
        controller.current.token == expected &&
            controller.current.actual == PlaybackActual.idle &&
            controller.current.intent == PlaybackIntent.stopped,
        'cleanup_superseded',
      );
      await localHost.close();
      final native = await localHost.diagnosticStatus();
      _check(
        native['configured'] == true &&
            native['enabled'] == false &&
            native['metadataCleared'] == true,
        'cleanup_native_retire_unconfirmed',
      );
      _hidden(native);
      _record('cleanup_native_released_and_retired', {
        ...native,
        'nativeReleaseAwaited': true,
        'pinnedLibraryTimerDrainSeconds': 6,
        'allHardwareReleaseGuarantee': false,
      });
      await _subscription?.cancel();
      await controller.dispose();
      await localEngine.dispose();
      _cleanupConfirmed = true;
    } on _RegressionFailure catch (failure) {
      _failure ??= failure.code;
    } catch (_) {
      _failure ??= 'cleanup_native_state_unconfirmed';
    }
  }
}
