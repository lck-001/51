import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:learning_core/learning_core.dart';
import 'package:material_core/material_core.dart';
import 'package:media_kit/media_kit.dart';
import 'package:playback_core/playback_core.dart';

import 'client_application.dart';
import 'playback/windows_playback_host.dart';

/// Separate debug-only entry. The reviewed native runner must suppress Show /
/// SetFocus using --background-regression before this isolate starts. This file
/// never launches a window, controls another process, or accesses user media.
Future<void> main(List<String> args) async {
  final reports = args.where((a) => a.startsWith('--report=')).toList();
  if (!kDebugMode ||
      !Platform.isWindows ||
      !args.contains('--background-regression') ||
      !args.contains('--silent-validation') ||
      reports.length > 1) {
    stdout.writeln(
      jsonEncode({
        'schema': 'shiyu.windows.client-background-regression.v1',
        'passed': false,
        'failure': 'debug_windows_hidden_silent_flags_required',
        'playRequested': false,
      }),
    );
    exit(64);
  }
  final runner = _ClientRegression(
    reports.isEmpty ? null : File(reports.single.substring('--report='.length)),
  );
  await runner.run();
}

final class _Failure implements Exception {
  const _Failure(this.code);
  final String code;
}

final class _ClientRegression {
  _ClientRegression(this.report);
  final File? report;
  final clock = Stopwatch()..start();
  final steps = <Map<String, Object?>>[];
  Directory? root;
  String? rootResolved, failure;
  ClientApplicationOwner? owner;
  LearningVersion? version;
  StreamSubscription<PlaybackSnapshot>? subscription;
  int? durablePositionMs;
  bool cleanupConfirmed = false,
      temporaryRootRemoved = false,
      playRequested = false,
      nativeSmtcConfirmed = false,
      actualShellCallbacksUsed = false,
      unexpectedAutoplayObserved = false,
      frameObserved = true,
      initializationAttempted = false;

  ClientApplicationOwner get app => owner!;
  WindowsPlaybackHost get host => app.host as WindowsPlaybackHost;
  void check(bool condition, String code) {
    if (!condition) throw _Failure(code);
  }

  void record(String name, Map<String, Object?> values) => steps.add({
    'step': name,
    'elapsedMs': clock.elapsedMilliseconds,
    ...values,
  });
  Map<String, Object?> observed(PlaybackSnapshot s) => {
    'intent': s.intent.name,
    'actual': s.actual.name,
    'positionMs': s.position.inMilliseconds,
    'durationMs': s.duration?.inMilliseconds,
    'pendingSeek': s.pendingSeek != null,
    'seekPositionApplied': s.seekPositionApplied,
    'engineAvailable': s.engineAvailable,
    'errorPresent': s.error != null,
  };

  Future<PlaybackSnapshot> waitFor(
    bool Function(PlaybackSnapshot) condition,
    String code, {
    bool cleanup = false,
  }) async {
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (DateTime.now().isBefore(deadline)) {
      final s = app.playback.current;
      if (condition(s)) return s;
      if (!cleanup &&
          (!s.engineAvailable || s.actual == PlaybackActual.failed)) {
        throw _Failure('${code}_engine_unconfirmed');
      }
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
    throw _Failure('${code}_timeout');
  }

  void hidden(Map<String, Object?> status) {
    check(status['configured'] == true, 'native_host_not_configured');
    check(status['windowAlive'] == true, 'own_window_not_alive');
    check(status['windowVisible'] == false, 'own_window_visibility_not_false');
    check(status['windowFocused'] == false, 'own_window_focus_not_false');
    check(status['nativeForeground'] == false, 'own_window_became_foreground');
  }

  Future<Map<String, Object?>> nativeState(
    bool Function(Map<String, Object?>) condition,
    String code,
  ) async {
    final deadline = DateTime.now().add(const Duration(seconds: 12));
    while (DateTime.now().isBefore(deadline)) {
      final status = await host.diagnosticStatus();
      hidden(status);
      if (condition(status)) return status;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw _Failure('${code}_timeout');
  }

  // Original silent PCM, not spoken English, TTS output or a user recording.
  Uint8List silentPcm() {
    final bytes = Uint8List(44 + 12 * 16000 * 2);
    final d = ByteData.sublistView(bytes);
    void tag(int at, String s) =>
        bytes.setRange(at, at + s.length, s.codeUnits);
    tag(0, 'RIFF');
    d.setUint32(4, bytes.length - 8, Endian.little);
    tag(8, 'WAVE');
    tag(12, 'fmt ');
    d.setUint32(16, 16, Endian.little);
    d.setUint16(20, 1, Endian.little);
    d.setUint16(22, 1, Endian.little);
    d.setUint32(24, 16000, Endian.little);
    d.setUint32(28, 32000, Endian.little);
    d.setUint16(32, 2, Endian.little);
    d.setUint16(34, 16, Endian.little);
    tag(36, 'data');
    d.setUint32(40, bytes.length - 44, Endian.little);
    return bytes;
  }

  Future<void> seed() async {
    const provenance = ContentProvenance(
      origin: ContentOrigin.synthetic,
      reference: 'fixture:client-native-silent-pcm',
    );
    final draft = await app.materials.createDraft(
      title: 'Synthetic client validation',
      text: '原创合成验证材料，不是真人工作内容。',
    );
    final material = await app.materials.confirmVersion(
      materialId: draft.materialId,
      expectedRevision: draft.revision,
    );
    final artifact = await app.materials.importArtifact(silentPcm());
    version = await app.learning.createVersion(
      materialVersionId: material.versionId,
      sentences: const [
        LearningSentenceInput(
          english: 'This is a synthetic validation sentence.',
          translation: '这是合成验证句。',
        ),
        LearningSentenceInput(
          english: 'The file contains silence rather than speech.',
          translation: '文件中是静音，不是朗读。',
        ),
      ],
      textProvenance: provenance,
      media: LearningMediaInput(
        artifact: artifact,
        provenance: provenance,
        timings: const [
          SentenceTiming(sentenceIndex: 0, startMs: 0, endMs: 6000),
          SentenceTiming(sentenceIndex: 1, startMs: 6000, endMs: 12000),
        ],
      ),
    );
    check(
      version!.state == LearningState.ready,
      'synthetic_structure_not_ready',
    );
    record('synthetic_fixture_persisted', {
      'durationMs': 12000,
      'sentenceCount': 2,
      'isSpeechOrTts': false,
    });
  }

  Future<void> exercise() async {
    final shell = app.runtime.createShell();
    final edition = version!;
    // Calling the actual assembled Widget callbacks exercises runtime binding,
    // coordinator, private cache and native engine. This is not a rendered UI.
    actualShellCallbacksUsed = true;
    await shell.onOpenLearning!(edition).timeout(const Duration(seconds: 20));
    final loaded = await waitFor(
      (s) => s.actual == PlaybackActual.paused && s.duration != null,
      'open_paused',
    );
    check(
      loaded.intent == PlaybackIntent.paused && !unexpectedAutoplayObserved,
      'open_autoplay_observed',
    );
    check(
      app.engine.native.silentValidation,
      'per_player_silent_guard_not_enabled',
    );
    hidden(await host.diagnosticStatus());
    record('shell_open_paused', {...observed(loaded), 'playRequested': false});

    Future<PlaybackToken> command(PlaybackCommand action, String label) async {
      hidden(await host.diagnosticStatus());
      if (action is Play) playRequested = true;
      final result = await shell.onPlaybackCommand!(edition, action);
      check(result.accepted, '${label}_not_accepted');
      record(label, {'accepted': true});
      return result.token;
    }

    await command(const Play(), 'shell_play');
    final playing = await waitFor(
      (s) =>
          s.actual == PlaybackActual.playing &&
          s.intent == PlaybackIntent.playing &&
          s.position.inMilliseconds >= 500,
      'native_progress',
    );
    final smtc = await nativeState(
      (s) =>
          s['enabled'] == true &&
          s['playbackStatus'] == 'playing' &&
          s['genericMetadata'] == true,
      'smtc_playing',
    );
    nativeSmtcConfirmed = true;
    record('native_play_observed', {
      ...observed(playing),
      ...smtc,
      'muteMechanism': 'own-player-volume-zero-before-every-play',
    });

    await command(const Pause(), 'shell_pause');
    final paused = await waitFor(
      (s) =>
          s.intent == PlaybackIntent.paused &&
          s.actual == PlaybackActual.paused,
      'pause',
    );
    await Future<void>.delayed(const Duration(milliseconds: 650));
    check(
      app.playback.current.actual == PlaybackActual.paused &&
          (app.playback.current.position - paused.position).abs() <=
              const Duration(milliseconds: 100),
      'paused_position_not_stable',
    );
    record('pause_stable', observed(app.playback.current));

    await command(const Seek(Duration(seconds: 5)), 'shell_seek');
    final sought = await waitFor(
      (s) =>
          s.pendingSeek == null &&
          s.seekPositionApplied &&
          s.actual == PlaybackActual.paused &&
          (s.position.inMilliseconds - 5000).abs() <= 250,
      'seek',
    );
    await app.coordinator.flushProgress();
    final beforeStop = await app.learning.restoreProgress(
      edition.binding.learningVersionId,
    );
    check(
      beforeStop != null &&
          (beforeStop.position - sought.position).abs() <=
              const Duration(milliseconds: 250),
      'seek_checkpoint_not_persisted',
    );
    record('seek_and_checkpoint_observed', {
      ...observed(sought),
      'savedPositionMs': beforeStop!.position.inMilliseconds,
    });

    await command(const Stop(), 'shell_stop');
    await waitFor(
      (s) =>
          s.intent == PlaybackIntent.stopped &&
          s.actual == PlaybackActual.idle &&
          s.engineAvailable,
      'stop_idle',
    );
    final retired = await nativeState(
      (s) =>
          s['enabled'] == false &&
          s['retired'] == true &&
          s['metadataCleared'] == true,
      'smtc_retired',
    );
    final preserved = await app.learning.restoreProgress(
      edition.binding.learningVersionId,
    );
    check(
      preserved?.position == beforeStop.position,
      'stop_reset_overwrote_checkpoint',
    );
    record('stop_idle_checkpoint_preserved', {
      ...observed(app.playback.current),
      ...retired,
      'savedPositionMs': preserved!.position.inMilliseconds,
    });

    await command(const Play(), 'shell_fresh_replay');
    await waitFor(
      (s) =>
          s.intent == PlaybackIntent.playing &&
          s.actual == PlaybackActual.playing &&
          s.position.inMilliseconds >= 600,
      'replay_progress',
    );
    await command(const Pause(), 'shell_pause_after_replay');
    final replayed = await waitFor(
      (s) =>
          s.intent == PlaybackIntent.paused &&
          s.actual == PlaybackActual.paused,
      'replay_pause',
    );
    await app.coordinator.flushProgress();
    final saved = await app.learning.restoreProgress(
      edition.binding.learningVersionId,
    );
    check(
      saved != null &&
          saved.position > Duration.zero &&
          (saved.position - replayed.position).abs() <=
              const Duration(milliseconds: 250),
      'replay_checkpoint_not_persisted',
    );
    durablePositionMs = saved!.position.inMilliseconds;
    record('fresh_replay_checkpoint_observed', {
      ...observed(replayed),
      'savedPositionMs': durablePositionMs,
    });
  }

  Future<void> cleanup() async {
    if (owner == null) {
      // An owner initialization failure may have attempted native creation.
      // Its internal best effort is not a confirmed callback release barrier.
      cleanupConfirmed = !initializationAttempted;
      return;
    }
    try {
      app.retireCommands();
      await app.playback.dispatch(const Stop());
      await waitFor(
        (s) =>
            s.intent == PlaybackIntent.stopped &&
            s.actual == PlaybackActual.idle &&
            s.engineAvailable,
        'cleanup_stop',
        cleanup: true,
      );
      final expected = app.playback.current.token;
      await app.shutdown.drainStores();
      await app.engine.native
          .releaseNative(expected)
          .timeout(const Duration(seconds: 15));
      check(
        app.playback.current.token == expected &&
            app.playback.current.actual == PlaybackActual.idle,
        'cleanup_scope_changed',
      );
      await host.close();
      final status = await host.diagnosticStatus();
      hidden(status);
      check(
        status['enabled'] == false && status['metadataCleared'] == true,
        'cleanup_native_retirement_unconfirmed',
      );
      await subscription?.cancel();
      await app.playback.dispose();
      await app.engine.native.dispose();
      app.frozen.dispose();
      app.notice.dispose();
      cleanupConfirmed = true;
      record('cleanup_confirmed', {
        ...status,
        'nativeReleaseAwaited': true,
        'pinnedLibraryTimerDrainSeconds': 6,
        'allHardwareReleaseGuarantee': false,
      });
    } on _Failure catch (error) {
      failure ??= error.code;
    } catch (_) {
      failure ??= 'cleanup_native_or_store_drain_unconfirmed';
    }
  }

  Future<void> verifyReopen() async {
    if (!cleanupConfirmed || durablePositionMs == null || version == null) {
      return;
    }
    FileMaterialStore? material;
    FileLearningStore? learning;
    try {
      material = await FileMaterialStore.open(
        root: Directory('${root!.path}/materials'),
        trustedOwnerId: 'local-device-only',
      );
      learning = await FileLearningStore.open(
        root: Directory('${root!.path}/learning'),
        materials: material,
      );
      final restored = await learning.restoreProgress(
        version!.binding.learningVersionId,
      );
      check(
        restored != null &&
            restored.position.inMilliseconds == durablePositionMs &&
            restored.resumeIntent == PlaybackIntent.paused,
        'reopened_checkpoint_mismatch',
      );
      record('stores_reopened_without_player', {
        'positionMs': restored!.position.inMilliseconds,
        'resumeIntent': restored.resumeIntent.name,
        'newPlayerCreated': false,
      });
    } finally {
      await learning?.close();
      await material?.close();
    }
  }

  Future<void> removeOwnedRoot() async {
    if (!cleanupConfirmed || root == null) return;
    final resolved = await root!.resolveSymbolicLinks();
    final temp = await Directory.systemTemp.resolveSymbolicLinks();
    check(
      resolved == rootResolved &&
          resolved.startsWith(
            '$temp${Platform.pathSeparator}shiyu-native-client-qa-',
          ),
      'temporary_root_scope_changed',
    );
    await root!.delete(recursive: true);
    temporaryRootRemoved = true;
  }

  Future<void> run() async {
    try {
      WidgetsFlutterBinding.ensureInitialized();
      MediaKit.ensureInitialized();
      runApp(const SizedBox.shrink());
      await WidgetsBinding.instance.endOfFrame.timeout(
        const Duration(seconds: 3),
        onTimeout: () {
          frameObserved = false;
        },
      );
      root = await Directory.systemTemp.createTemp('shiyu-native-client-qa-');
      rootResolved = await root!.resolveSymbolicLinks();
      initializationAttempted = true;
      owner = await ClientApplicationOwner.open(
        root: root!,
        silentValidation: true,
      );
      subscription = app.playback.snapshots.listen((s) {
        if (!playRequested &&
            (s.actual == PlaybackActual.playing ||
                s.intent == PlaybackIntent.playing)) {
          unexpectedAutoplayObserved = true;
        }
      });
      hidden(await host.diagnosticStatus());
      record('own_hidden_window_preflight', {
        'hidden': true,
        'focused': false,
        'nativeForeground': false,
        'playRequested': false,
      });
      await seed();
      await exercise();
    } on _Failure catch (error) {
      failure = error.code;
    } catch (_) {
      failure = 'unexpected_native_client_or_harness_failure';
    } finally {
      await cleanup();
    }
    try {
      await verifyReopen();
      // Failures retain this entirely synthetic root for diagnosis. Successful
      // native cleanup alone is not a reason to erase failed-run evidence.
      if (failure == null) await removeOwnedRoot();
    } on _Failure catch (error) {
      failure ??= error.code;
    } catch (_) {
      failure ??= 'reopen_or_temporary_root_cleanup_unconfirmed';
    }
    final result = <String, Object?>{
      'schema': 'shiyu.windows.client-background-regression.v1',
      'passed': failure == null && cleanupConfirmed && temporaryRootRemoved,
      'failure': failure,
      'playRequested': playRequested,
      'silentValidation': true,
      'usesActualShellCallbacks': actualShellCallbacksUsed,
      'usesRealClientOwnerStoresCacheRuntime': owner != null,
      'usesRealMediaKitEngine': owner != null,
      'usesRealOwnHwndSmtc': nativeSmtcConfirmed,
      'fakeAdapterUsed': false,
      'controlledLifecycleOnly': true,
      'unexpectedAutoplayObserved': unexpectedAutoplayObserved,
      'renderedLearningUiVerified': false,
      'firstFrameObserved': frameObserved,
      'desktopInputOrActivationRequested': false,
      'realLockScreenVerified': false,
      'acousticQualityOrTtsClaimed': false,
      'cleanupConfirmed': cleanupConfirmed,
      'ownerCleanupRequired': !cleanupConfirmed,
      'temporaryRootRemoved': temporaryRootRemoved,
      'elapsedMs': clock.elapsedMilliseconds,
      'steps': steps,
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
    stdout.writeln(
      'SHIYU_CLIENT_BACKGROUND_REGRESSION_RESULT ${jsonEncode(result)}',
    );
    if (cleanupConfirmed) exit(result['passed'] == true ? 0 : 1);
    // Root owns bounded recovery of this newly launched hidden process. Do not
    // tear down Flutter while native callback draining remains unconfirmed.
    await Completer<void>().future;
  }
}
