// Independent selection tests through the real Shell callbacks/runtime/stores.
// Engine commands and actual observations are intentionally separate; no native
// Player, speaker, microphone, cloud service or desktop window is started.
import 'dart:async';
import 'dart:io';

import 'package:client_runtime/client_runtime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learning_core/learning_core.dart';
import 'package:learning_playback/learning_playback.dart';
import 'package:material_core/material_core.dart';
import 'package:playback_core/playback_core.dart';

import 'runtime_integration_test.dart' as real;

Future<LearningVersion> readable(real.Fixture f) async {
  final draft = await f.materials.createDraft(title: 'Readable B', text: '合成只读原文。');
  final fixed = await f.materials.confirmVersion(materialId: draft.materialId,
                                                expectedRevision: draft.revision);
  return f.learning.createVersion(materialVersionId: fixed.versionId,
      sentences: const [LearningSentenceInput(english: 'A readable second version.',
                                             translation: '第二份可阅读内容。')],
      textProvenance: const ContentProvenance(origin: ContentOrigin.synthetic,
                                             reference: 'fixture:readonly-no-audio'));
}

Future<void> playAndCheckpoint(real.Fixture f, LearningVersion a) async {
  await f.open(a);
  final play = await f.shell.onPlaybackCommand!(a, const Play());
  expect(play.accepted, isTrue);
  f.engine.stream.add(EngineStateChanged(play.token, PlaybackActual.playing));
  f.engine.stream.add(EngineProgress(play.token,
      position: const Duration(milliseconds: 2100), duration: const Duration(seconds: 6)));
  await real.until(() => f.runtime.playbackView.value.snapshot?.position.inMilliseconds == 2100);
  await f.coordinator.flushProgress();
}

void observeStopped(real.Fixture f) {
  final token = f.core.current.token;
  f.engine.stream.add(EngineStateChanged(token, PlaybackActual.idle));
  f.engine.stream.add(EngineProgress(token, position: Duration.zero,
                                    duration: const Duration(seconds: 6)));
}

// Delay only an actual fixed-version read in the public preparation phase.
// Everything else delegates to the same real file Store, without fake data.
class PreparationGate implements LearningStore {
  PreparationGate(this.delegate, this.target, this.isPreparing);
  final LearningStore delegate;
  final String target;
  final bool Function() isPreparing;
  final entered = Completer<void>(), release = Completer<void>();
  bool intercepted = false;
  @override String get trustedOwnerId => delegate.trustedOwnerId;
  @override LearningRecoveryReport get recoveryReport => delegate.recoveryReport;
  @override Future<LearningVersion> readVersion(String id) async {
    if (!intercepted && id == target && isPreparing()) {
      intercepted = true; entered.complete(); await release.future;
    }
    return delegate.readVersion(id);
  }
  @override Future<LearningVersion> createVersion({required String materialVersionId,
      required Iterable<LearningSentenceInput> sentences,
      required ContentProvenance textProvenance, LearningMediaInput? media}) =>
    delegate.createVersion(materialVersionId: materialVersionId, sentences: sentences,
                           textProvenance: textProvenance, media: media);
  @override Future<List<LearningVersion>> listVersions({String? materialId}) =>
      delegate.listVersions(materialId: materialId);
  @override Future<LearningPlaybackSession> openPlayback(String id) => delegate.openPlayback(id);
  @override Future<ArtifactRef> mediaArtifactFor(PlaybackItem item) => delegate.mediaArtifactFor(item);
  @override Future<ProgressCheckpoint> saveProgress({required LearningPlaybackSession session,
      required int expectedRevision, required String sentenceId, required Duration position}) =>
    delegate.saveProgress(session: session, expectedRevision: expectedRevision,
                          sentenceId: sentenceId, position: position);
  @override Future<ProgressCheckpoint?> restoreProgress(String id) => delegate.restoreProgress(id);
  @override Future<void> close() => delegate.close();
}

void main() {
  late real.Fixture f;
  setUp(() async {
    f = real.Fixture();
    await f.init();
    f.engine.autoStopObservation = false;
  });
  tearDown(() => f.close());

  test('choosing readable B waits for actual Stop of playing A and preserves A checkpoint', () async {
    final a = await f.edition('A');
    final b = await readable(f);
    expect(b.state, LearningState.partial);
    await playAndCheckpoint(f, a);
    final stops = f.engine.stops, opens = f.engine.opens.length, plays = f.engine.plays;
    var completed = false;
    Object? failure;
    final selection = f.shell.onOpenLearning!(b).then<void>((_) { completed = true; },
        onError: (Object error) { failure = error; });
    await real.until(() => f.engine.stops > stops || failure != null);
    expect(f.engine.stops, greaterThan(stops),
        reason: 'A text-only selection must stop the previous actual audio');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(completed, isFalse, reason: 'Stop acknowledgement is not actual idle');
    observeStopped(f);
    await selection;
    expect(failure, isNull);
    expect(completed, isTrue);
    expect(f.engine.opens.length, opens, reason: 'B has no media to Open');
    expect(f.engine.plays, plays, reason: 'Selection never auto-Plays');
    expect(f.core.current.actual, PlaybackActual.idle);
    expect(f.runtime.playbackView.value.snapshot, isNull);
    expect((await f.learning.restoreProgress(a.binding.learningVersionId))!
        .position.inMilliseconds, 2100);
    expect(await f.learning.restoreProgress(b.binding.learningVersionId), isNull);
  });

  test('late previous preparation cannot Open after a readable selection succeeded', () async {
    final a = await f.edition('A');
    final b = await readable(f);
    await f.runtime.detach(); await f.coordinator.close();
    final gate = PreparationGate(f.learning, a.binding.learningVersionId,
        () => f.coordinator.current.phase == LearningPlaybackPhase.preparing);
    f.coordinator = LearningPlaybackCoordinator(learning: gate, playback: f.core,
        mediaCache: FilePlayableCache(root: Directory('${f.root.path}/gated-cache'),
                                     materials: f.materials, learning: gate),
        readinessTimeout: const Duration(milliseconds: 500));
    f.runtime = ShiyuClientRuntime.attach(materials: f.materials, learning: gate,
                                          playback: f.core, coordinator: f.coordinator);
    f.shell = f.runtime.createShell();
    Object? oldFailure, newFailure;
    final old = f.shell.onOpenLearning!(a).catchError((Object error) { oldFailure = error; });
    try {
      await gate.entered.future.timeout(const Duration(seconds: 2));
      await f.shell.onOpenLearning!(b).catchError((Object error) { newFailure = error; });
      expect(newFailure, isNull, reason: 'B should be readable without an audio requirement');
      gate.release.complete();
      await old;
      expect(oldFailure, isNull, reason: 'Superseded old selection is not a new view error');
      expect(f.engine.opens, isEmpty, reason: 'Late preparation is fenced before native Open');
      expect(f.engine.plays, 0);
      expect(f.runtime.playbackView.value.snapshot, isNull);
    } finally {
      if (!gate.release.isCompleted) gate.release.complete();
      await old;
    }
  });

  test('unconfirmed Stop does not report readable selection success and explicit retry can complete', () async {
    final a = await f.edition('A');
    final b = await readable(f);
    await playAndCheckpoint(f, a);
    final before = f.engine.stops;
    Object? failure;
    var completed = false;
    final selection = f.shell.onOpenLearning!(b).then<void>((_) { completed = true; },
        onError: (Object error) { failure = error; });
    await real.until(() => f.engine.stops > before || failure != null);
    expect(f.engine.stops, greaterThan(before));
    await selection.timeout(const Duration(seconds: 8));
    expect(completed, isFalse);
    expect(failure, isNotNull);
    final retryStops = f.engine.stops;
    Object? retryFailure;
    final retry = f.shell.onOpenLearning!(b).catchError((Object error) { retryFailure = error; });
    await real.until(() => f.engine.stops > retryStops || retryFailure != null);
    expect(f.engine.stops, greaterThan(retryStops));
    observeStopped(f);
    await retry;
    expect(retryFailure, isNull);
    expect(f.core.current.actual, PlaybackActual.idle);
    expect(f.engine.plays, 1);
    expect((await f.learning.restoreProgress(a.binding.learningVersionId))!
        .position.inMilliseconds, 2100);
  });
}
