import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:client_runtime/client_runtime.dart';
import 'package:client_shell/client_shell.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learning_core/learning_core.dart';
import 'package:learning_playback/learning_playback.dart';
import 'package:material_core/material_core.dart';
import 'package:playback_core/playback_core.dart';

// Independent test adapters acknowledge commands without inventing observations.
class TestEngine implements PlaybackEngineAdapter {
  final stream = StreamController<EngineEvent>.broadcast(sync: true);
  final opens = <PlaybackToken>[];
  int plays = 0, stops = 0;
  @override
  Stream<EngineEvent> get events => stream.stream;
  @override
  Future<void> open(PlaybackItem item, PlaybackToken token) async =>
      opens.add(token);
  @override
  Future<void> play(PlaybackToken token) async {
    plays++;
  }

  @override
  Future<void> pause(PlaybackToken token) async {}
  @override
  Future<void> stop(PlaybackToken token) async {
    stops++;
  }

  @override
  Future<void> seek(
    Duration position,
    PlaybackToken token,
    int requestId,
  ) async {}
  void load(PlaybackToken token) {
    stream.add(EngineStateChanged(token, PlaybackActual.paused));
    stream.add(
      EngineProgress(
        token,
        position: Duration.zero,
        duration: const Duration(seconds: 6),
      ),
    );
  }
}

class TestSystem implements SystemPlaybackAdapter {
  final stream = StreamController<PlaybackSystemEvent>.broadcast(sync: true);
  @override
  Stream<PlaybackSystemEvent> get events => stream.stream;
  @override
  PlaybackCapabilities get capabilities =>
      const PlaybackCapabilities(seek: true);
  @override
  Future<void> publish(PlaybackSnapshot snapshot) async {}
}

Future<void> until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline))
      throw StateError('observation timeout');
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

Uint8List silentWav() {
  final b = Uint8List(44 + 6 * 16000);
  final d = ByteData.sublistView(b);
  void tag(int p, String s) => b.setRange(p, p + s.length, s.codeUnits);
  tag(0, 'RIFF');
  d.setUint32(4, b.length - 8, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  d.setUint32(16, 16, Endian.little);
  d.setUint16(20, 1, Endian.little);
  d.setUint16(22, 1, Endian.little);
  d.setUint32(24, 8000, Endian.little);
  d.setUint32(28, 16000, Endian.little);
  d.setUint16(32, 2, Endian.little);
  d.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  d.setUint32(40, b.length - 44, Endian.little);
  return b;
}

class Fixture {
  late Directory root;
  late MaterialStore materials;
  late LearningStore learning;
  final engine = TestEngine();
  final system = TestSystem();
  late PlaybackController core;
  late LearningPlaybackCoordinator coordinator;
  late ShiyuClientRuntime runtime;
  late ShiyuClientShell shell;
  bool detached = false;
  Future<void> init() async {
    root = await Directory.systemTemp.createTemp('shiyu-runtime-qa-');
    materials = await FileMaterialStore.open(
      root: Directory('${root.path}/materials'),
      trustedOwnerId: 'synthetic-runtime-owner',
    );
    learning = await FileLearningStore.open(
      root: Directory('${root.path}/learning'),
      materials: materials,
    );
    core = PlaybackController(engine: engine, system: system);
    coordinator = LearningPlaybackCoordinator(
      learning: learning,
      playback: core,
      mediaCache: FilePlayableCache(
        root: Directory('${root.path}/cache'),
        materials: materials,
        learning: learning,
      ),
      readinessTimeout: const Duration(milliseconds: 500),
    );
    runtime = ShiyuClientRuntime.attach(
      materials: materials,
      learning: learning,
      playback: core,
      coordinator: coordinator,
    );
    shell = runtime.createShell();
  }

  Future<LearningVersion> edition(String label) async {
    const source = ContentProvenance(
      origin: ContentOrigin.synthetic,
      reference: 'fixture:runtime-qa-no-ai',
    );
    final draft = await materials.createDraft(
      title: 'Synthetic $label',
      text: '自造测试内容',
    );
    final version = await materials.confirmVersion(
      materialId: draft.materialId,
      expectedRevision: 1,
    );
    final artifact = await materials.importArtifact(silentWav());
    return learning.createVersion(
      materialVersionId: version.versionId,
      sentences: [
        LearningSentenceInput(
          english: 'This is synthetic $label.',
          translation: '合成对照。',
        ),
      ],
      textProvenance: source,
      media: LearningMediaInput(
        artifact: artifact,
        provenance: source,
        timings: [
          const SentenceTiming(sentenceIndex: 0, startMs: 0, endMs: 6000),
        ],
      ),
    );
  }

  Future<void> open(LearningVersion version) async {
    final before = engine.opens.length;
    final pending = shell.onOpenLearning!(version);
    await until(() => engine.opens.length > before);
    engine.load(engine.opens.last);
    await pending;
  }

  Future<void> close() async {
    if (!detached) await runtime.detach();
    await coordinator.close();
    await core.dispose();
    await engine.stream.close();
    await system.stream.close();
    await learning.close();
    await materials.close();
    final temp = await Directory.systemTemp.resolveSymbolicLinks();
    final actual = await root.resolveSymbolicLinks();
    if (!actual.startsWith('$temp${Platform.pathSeparator}shiyu-runtime-qa-'))
      throw StateError('unsafe cleanup');
    await root.delete(recursive: true);
  }
}

void main() {
  late Fixture f;
  setUp(() async {
    f = Fixture();
    await f.init();
  });
  tearDown(() => f.close());

  test(
    'actual shell callback waits for observed load and never auto plays',
    () async {
      final v = await f.edition('A');
      expect(identical(f.shell.materials, f.materials), isTrue);
      expect(identical(f.shell.learning, f.learning), isTrue);
      var completed = false;
      final opening = f.shell.onOpenLearning!(v).then((_) {
        completed = true;
      });
      await until(() => f.engine.opens.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(completed, isFalse);
      expect(f.runtime.playbackView.value.snapshot, isNull);
      expect(f.engine.plays, 0);
      f.engine.load(f.engine.opens.last);
      await opening;
      expect(
        f.runtime.playbackView.value.learningVersionId,
        v.binding.learningVersionId,
      );
      expect(
        f.runtime.playbackView.value.snapshot!.actual,
        PlaybackActual.paused,
      );
      expect(f.engine.plays, 0);
    },
  );

  test('accepted explicit Play is distinct from observed playing and saved position', () async {
    final v = await f.edition('A');
    await f.open(v);
    final result = await f.shell.onPlaybackCommand!(v, const Play());
    expect(result.accepted, isTrue);
    expect(f.engine.plays, 1);
    expect(
      f.runtime.playbackView.value.snapshot?.actual,
      isNot(PlaybackActual.playing),
    );
    f.engine.stream.add(
      EngineStateChanged(result.token, PlaybackActual.playing),
    );
    f.engine.stream.add(
      EngineProgress(
        result.token,
        position: const Duration(milliseconds: 2100),
        duration: const Duration(seconds: 6),
      ),
    );
    await until(
      () =>
          f.runtime.playbackView.value.snapshot?.position.inMilliseconds ==
          2100,
    );
    await f.coordinator.flushProgress();
    final checkpoint = await f.learning.restoreProgress(
      v.binding.learningVersionId,
    );
    expect(checkpoint!.position.inMilliseconds, 2100);
  });

  test('old version events and commands cannot relabel or control selected version', () async {
    final a = await f.edition('A'), b = await f.edition('B');
    await f.open(a);
    final old = f.core.current.token;
    await f.open(b);
    final plays = f.engine.plays;
    f.engine.stream.add(EngineStateChanged(old, PlaybackActual.playing));
    f.engine.stream.add(
      EngineProgress(old, position: const Duration(seconds: 5)),
    );
    final denied = await f.shell.onPlaybackCommand!(a, const Play());
    expect(denied.status, CommandStatus.rejected);
    expect(f.engine.plays, plays);
    expect(
      f.runtime.playbackView.value.learningVersionId,
      b.binding.learningVersionId,
    );
    expect(f.runtime.playbackView.value.snapshot!.position, Duration.zero);
  });

  test('old command epoch cannot dispatch into current session', () async {
    final v = await f.edition('A');
    await f.open(v);
    final old = f.runtime.playbackView.value.snapshot!.token;
    expect(
      (await f.shell.onPlaybackCommand!(v, const Play())).accepted,
      isTrue,
    );
    final before = f.engine.plays;
    final denied = await f.runtime.command(v, const Play(), expectedToken: old);
    expect(denied.status, CommandStatus.rejected);
    expect(f.engine.plays, before);
  });

  test('detach invalidates callbacks without closing external stores or stopping playback', () async {
    final v = await f.edition('A');
    await f.open(v);
    final before = f.engine.stops;
    await f.runtime.detach();
    f.detached = true;
    expect(f.engine.stops, before);
    expect(
      (await f.learning.readVersion(v.binding.learningVersionId)).binding
          .sameAs(v.binding),
      isTrue,
    );
    expect((await f.materials.listDrafts()).length, 1);
    expect((await f.core.dispatch(const Play())).accepted, isTrue);
    expect(
      (await f.shell.onPlaybackCommand!(v, const Pause())).reason,
      'runtime_closed',
    );
    await expectLater(
      f.shell.onOpenLearning!(v),
      throwsA(
        isA<ClientRuntimeException>().having(
          (e) => e.code,
          'code',
          ClientRuntimeErrorCode.closed,
        ),
      ),
    );
  });

  test('late load after detach cannot revive bridge or auto play', () async {
    final v = await f.edition('A');
    final pending = f.shell.onOpenLearning!(v);
    await until(() => f.engine.opens.isNotEmpty);
    final token = f.engine.opens.last;
    final priorStops = f.engine.stops;
    await f.runtime.detach();
    f.detached = true;
    f.engine.load(token);
    await pending;
    expect(f.engine.plays, 0);
    expect(f.engine.stops, priorStops);
  });

  test('explicit Play after Stop resumes saving actual progress without saving Stop reset', () async {
    final v = await f.edition('A');
    await f.open(v);
    var play = await f.shell.onPlaybackCommand!(v, const Play());
    f.engine.stream.add(EngineStateChanged(play.token, PlaybackActual.playing));
    f.engine.stream.add(
      EngineProgress(
        play.token,
        position: const Duration(milliseconds: 2100),
        duration: const Duration(seconds: 6),
      ),
    );
    await until(
      () =>
          f.runtime.playbackView.value.snapshot?.position.inMilliseconds ==
          2100,
    );
    await f.coordinator.flushProgress();
    final stop = await f.shell.onPlaybackCommand!(v, const Stop());
    f.engine.stream.add(EngineStateChanged(stop.token, PlaybackActual.paused));
    f.engine.stream.add(
      EngineProgress(
        stop.token,
        position: Duration.zero,
        duration: const Duration(seconds: 6),
      ),
    );
    expect(
      (await f.learning.restoreProgress(v.binding.learningVersionId))!
          .position
          .inMilliseconds,
      2100,
    );
    play = await f.shell.onPlaybackCommand!(v, const Play());
    expect(play.accepted, isTrue);
    f.engine.stream.add(EngineStateChanged(play.token, PlaybackActual.playing));
    f.engine.stream.add(
      EngineProgress(
        play.token,
        position: const Duration(milliseconds: 2800),
        duration: const Duration(seconds: 6),
      ),
    );
    await until(
      () =>
          f.runtime.playbackView.value.snapshot?.position.inMilliseconds ==
          2800,
    );
    await f.coordinator.flushProgress();
    expect(
      (await f.learning.restoreProgress(v.binding.learningVersionId))!
          .position
          .inMilliseconds,
      2800,
    );
  });

  test('native-like Stop idle reset allows fresh explicit replay and actual checkpoint', () async {
    final v = await f.edition('A');
    await f.open(v);
    var play = await f.shell.onPlaybackCommand!(v, const Play());
    f.engine.stream.add(EngineStateChanged(play.token, PlaybackActual.playing));
    f.engine.stream.add(
      EngineProgress(
        play.token,
        position: const Duration(milliseconds: 2100),
        duration: const Duration(seconds: 6),
      ),
    );
    await until(
      () =>
          f.runtime.playbackView.value.snapshot?.position.inMilliseconds ==
          2100,
    );
    await f.coordinator.flushProgress();
    final stopped = await f.shell.onPlaybackCommand!(v, const Stop());
    expect(stopped.accepted, isTrue);
    // MediaKitEngine.stop reports idle, rather than the paused alternative in
    // the preceding adapter contract case. This is a controlled observation,
    // not a claim this test executed the native SDK.
    f.engine.stream.add(EngineStateChanged(stopped.token, PlaybackActual.idle));
    f.engine.stream.add(
      EngineProgress(
        stopped.token,
        position: Duration.zero,
        duration: const Duration(seconds: 6),
      ),
    );
    expect(f.runtime.playbackView.value.snapshot?.actual, PlaybackActual.idle);
    expect(
      (await f.learning.restoreProgress(v.binding.learningVersionId))!
          .position
          .inMilliseconds,
      2100,
    );
    final before = f.engine.plays;
    play = await f.shell.onPlaybackCommand!(v, const Play());
    expect(
      play.accepted,
      isTrue,
      reason: 'known same-session idle Stop must admit a fresh foreground Play',
    );
    expect(f.engine.plays, before + 1);
    expect(
      f.runtime.playbackView.value.snapshot?.actual,
      isNot(PlaybackActual.playing),
      reason: 'replay acceptance must not fabricate playing',
    );
    f.engine.stream.add(EngineStateChanged(play.token, PlaybackActual.playing));
    f.engine.stream.add(
      EngineProgress(
        play.token,
        position: const Duration(milliseconds: 2900),
        duration: const Duration(seconds: 6),
      ),
    );
    await until(
      () =>
          f.runtime.playbackView.value.snapshot?.position.inMilliseconds ==
          2900,
    );
    await f.coordinator.flushProgress();
    expect(
      (await f.learning.restoreProgress(v.binding.learningVersionId))!
          .position
          .inMilliseconds,
      2900,
    );
  });

  test('idle without a confirmed Stop cannot replay and stopped idle cannot Seek', () async {
    final v = await f.edition('A');
    await f.open(v);
    f.engine.stream.add(
      EngineStateChanged(f.core.current.token, PlaybackActual.idle),
    );
    final before = f.engine.plays;
    expect(
      (await f.shell.onPlaybackCommand!(v, const Play())).accepted,
      isFalse,
      reason: 'arbitrary idle is not proof a verified stopped source can be reloaded',
    );
    expect(f.engine.plays, before);
    final stop = await f.shell.onPlaybackCommand!(v, const Stop());
    f.engine.stream.add(EngineStateChanged(stop.token, PlaybackActual.idle));
    expect(
      (await f.shell.onPlaybackCommand!(
        v,
        const Seek(Duration(seconds: 1)),
      )).accepted,
      isFalse,
      reason:
          'replay allowance must not bypass actual load requirements for Seek',
    );
  });
}
