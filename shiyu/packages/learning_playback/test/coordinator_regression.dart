import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:learning_core/learning_core.dart';
import 'package:material_core/material_core.dart';
import 'package:playback_core/playback_core.dart';

import '../lib/learning_playback.dart';
import 'controlled_playback.dart';
import 'support.dart';

const ownerA = 'synthetic-coordinator-owner-a';
const ownerB = 'synthetic-coordinator-owner-b';
const supplied = ContentProvenance(
  origin: ContentOrigin.synthetic,
  reference: 'fixture:provided-content-no-ai',
);
const pcmSource = ContentProvenance(
  origin: ContentOrigin.synthetic,
  reference: 'fixture:pcm-silence-no-speech',
);

Future<void> expectError(
  Future<dynamic> Function() action,
  Set<LearningPlaybackErrorCode> codes,
) async {
  try {
    await action();
  } on LearningPlaybackException catch (error) {
    expectThat(
      codes.contains(error.code),
      'unexpected coordination error: ${error.code.name}',
    );
    return;
  }
  throw StateError(
    'operation unexpectedly succeeded instead of explicit refusal',
  );
}

class Lab {
  Lab(this.sandbox)
    : materialRoot = Directory(
        '${sandbox.path}${Platform.pathSeparator}materials',
      ),
      learningRoot = Directory(
        '${sandbox.path}${Platform.pathSeparator}learning',
      ),
      cacheRoot = Directory('${sandbox.path}${Platform.pathSeparator}playable');
  final Directory sandbox, materialRoot, learningRoot, cacheRoot;
  final List<MaterialStore> materials = [];
  final List<LearningStore> learnings = [];
  final List<Rig> rigs = [];
  Future<MaterialStore> material([String owner = ownerA]) async {
    final m = await FileMaterialStore.open(
      root: materialRoot,
      trustedOwnerId: owner,
    );
    materials.add(m);
    return m;
  }

  Future<LearningStore> learning(MaterialStore m) async {
    final l = await FileLearningStore.open(root: learningRoot, materials: m);
    learnings.add(l);
    return l;
  }

  FilePlayableCache cache(MaterialStore m, LearningStore l) =>
      FilePlayableCache(root: cacheRoot, materials: m, learning: l);
  Future<LearningVersion> edition(
    MaterialStore m,
    LearningStore l, {
    int seconds = 6,
    String label = 'first',
  }) async {
    final draft = await m.createDraft(
      title: 'Synthetic $label source',
      text: '这是自造的中文材料。',
    );
    final source = await m.confirmVersion(
      materialId: draft.materialId,
      expectedRevision: 1,
    );
    final artifact = await m.importArtifact(syntheticWav(seconds: seconds));
    return l.createVersion(
      materialVersionId: source.versionId,
      sentences: [
        LearningSentenceInput(
          english: 'This is the $label synthetic sentence.',
          translation: '第一句合成对照。',
        ),
        const LearningSentenceInput(
          english: 'This is another supplied sentence.',
          translation: '第二句合成对照。',
        ),
      ],
      textProvenance: supplied,
      media: LearningMediaInput(
        artifact: artifact,
        provenance: pcmSource,
        timings: [
          SentenceTiming(sentenceIndex: 0, startMs: 0, endMs: seconds * 500),
          SentenceTiming(
            sentenceIndex: 1,
            startMs: seconds * 500,
            endMs: seconds * 1000,
          ),
        ],
      ),
    );
  }

  Rig rig(
    LearningStore l,
    FilePlayableCache cache, {
    Duration readiness = const Duration(seconds: 2),
    Duration seekTimeout = const Duration(seconds: 5),
  }) {
    final r = Rig(l, cache, readiness: readiness, seekTimeout: seekTimeout);
    rigs.add(r);
    return r;
  }

  File blob(ArtifactRef ref) => File(
    '${materialRoot.path}${Platform.pathSeparator}${sha256.convert(utf8.encode('owner:${ref.ownerId}'))}${Platform.pathSeparator}artifacts${Platform.pathSeparator}${ref.artifactId}.blob',
  );
  Future<void> seedProgress(LearningStore l, LearningVersion v) async {
    final session = await l.openPlayback(v.binding.learningVersionId);
    await l.saveProgress(
      session: session,
      expectedRevision: 0,
      sentenceId: v.sentences[1].sentenceId,
      position: const Duration(milliseconds: 4200),
    );
  }

  Future<void> closeLearning(LearningStore l) async {
    learnings.remove(l);
    await l.close();
  }

  Future<void> closeMaterial(MaterialStore m) async {
    materials.remove(m);
    await m.close();
  }

  Future<void> closeRig(Rig r) async {
    rigs.remove(r);
    await r.close();
  }

  Future<void> finish() async {
    for (final r in rigs.reversed.toList()) {
      await closeRig(r);
    }
    for (final l in learnings.reversed.toList()) {
      await closeLearning(l);
    }
    for (final m in materials.reversed.toList()) {
      await closeMaterial(m);
    }
  }
}

class Opening {
  Opening(this.result, this.token);
  final Future<LearningOpenResult> result;
  final PlaybackToken token;
}

class Rig {
  Rig(
    this.learning,
    FilePlayableCache cache, {
    required Duration readiness,
    required Duration seekTimeout,
  }) {
    core = PlaybackController(
      engine: engine,
      system: system,
      seekConfirmationTimeout: seekTimeout,
    );
    coordinator = LearningPlaybackCoordinator(
      learning: learning,
      playback: core,
      mediaCache: cache,
      readinessTimeout: readiness,
    );
    subscription = coordinator.snapshots.listen(seen.add);
  }
  final LearningStore learning;
  final engine = ControlledEngine();
  final system = ControlledSystem();
  late final PlaybackController core;
  late final LearningPlaybackCoordinator coordinator;
  late final StreamSubscription<LearningPlaybackSnapshot> subscription;
  final seen = <LearningPlaybackSnapshot>[];
  Future<Opening> begin(
    LearningVersion v, {
    bool restorePosition = true,
  }) async {
    final opens = engine.count('open');
    final result = coordinator.open(
      v.binding.learningVersionId,
      restorePosition: restorePosition,
    );
    await until(() => engine.count('open') > opens);
    await settle();
    return Opening(result, engine.last('open').token);
  }

  void observedLoad(
    PlaybackToken token, {
    int seconds = 6,
    int positionMs = 0,
  }) {
    engine.emit(EngineStateChanged(token, PlaybackActual.paused));
    engine.emit(
      EngineProgress(
        token,
        position: Duration(milliseconds: positionMs),
        duration: Duration(seconds: seconds),
      ),
    );
  }

  Future<LearningOpenResult> load(
    LearningVersion v, {
    int seconds = 6,
    bool restorePosition = true,
  }) async {
    final opening = await begin(v, restorePosition: restorePosition);
    observedLoad(opening.token, seconds: seconds);
    return opening.result.timeout(const Duration(seconds: 3));
  }

  Future<void> actualPlayAt(Duration position) async {
    final result = await coordinator.dispatch(const Play());
    expectThat(
      result.accepted,
      'explicit Play after readiness should be accepted',
    );
    engine.emit(EngineStateChanged(result.token, PlaybackActual.playing));
    engine.emit(
      EngineProgress(
        result.token,
        position: position,
        duration: core.current.duration,
      ),
    );
    await settle();
  }

  Future<void> close() async {
    await coordinator.close();
    await subscription.cancel();
    await core.dispose();
    await engine.source.close();
    await system.source.close();
  }
}

Future<void> using(Future<void> Function(Lab) body) =>
    inSandbox((directory) async {
      final lab = Lab(directory);
      try {
        await body(lab);
      } finally {
        await lab.finish();
      }
    });

Future<void> verifyCacheInNewProcess(
  Lab lab,
  LearningVersion v,
  DateTime modified,
) async {
  final process = await Process.start(Platform.resolvedExecutable, [
    Platform.script.toFilePath(),
    '--child-cache',
    lab.materialRoot.path,
    lab.learningRoot.path,
    lab.cacheRoot.path,
    v.binding.learningVersionId,
    modified.millisecondsSinceEpoch.toString(),
  ], workingDirectory: Directory.current.path);
  final output = process.stdout.transform(utf8.decoder).join();
  final errors = process.stderr.drain<void>();
  int code;
  try {
    code = await process.exitCode.timeout(const Duration(seconds: 10));
  } on TimeoutException {
    process.kill();
    await process.exitCode.timeout(const Duration(seconds: 3));
    throw StateError('prepared cache child process timed out');
  }
  final text = await output;
  await errors;
  expectThat(
    code == 0 && text.trim() == 'CHILD_PREPARED_CACHE_REUSED',
    'new process must reuse the verified prepared file without rewriting it',
  );
}

Future<void> childCache(List<String> args) async {
  MaterialStore? m;
  LearningStore? l;
  try {
    m = await FileMaterialStore.open(
      root: Directory(args[1]),
      trustedOwnerId: ownerA,
    );
    l = await FileLearningStore.open(root: Directory(args[2]), materials: m);
    final session = await l.openPlayback(args[4]);
    final cache = FilePlayableCache(
      root: Directory(args[3]),
      materials: m,
      learning: l,
    );
    final prepared = await cache.prepare(session.item);
    final uri = await cache.resolveForEngine(session.item);
    final file = File.fromUri(uri);
    expectThat(
      sha256.convert(await file.readAsBytes()).toString() ==
          prepared.artifact.sha256,
      'child prepared bytes must match owned artifact',
    );
    expectThat(
      (await file.lastModified()).millisecondsSinceEpoch == int.parse(args[5]),
      'existing valid prepared source must not be rewritten',
    );
    expectThat(
      session.resumeIntent == PlaybackIntent.paused,
      'new process source preparation cannot ask to Play',
    );
    stdout.writeln('CHILD_PREPARED_CACHE_REUSED');
  } catch (_) {
    stdout.writeln('CHILD_PREPARED_CACHE_FAILED');
    exitCode = 1;
  } finally {
    await l?.close();
    await m?.close();
  }
}

Future<void> main(List<String> args) async {
  if (args.isNotEmpty && args.first == '--child-cache') {
    await childCache(args);
    return;
  }
  final tests = Cases();

  await tests.run(
    'Prepared media is a private verified copy and never overwrites original artifact',
    () => using((lab) async {
      final m = await lab.material();
      final l = await lab.learning(m);
      final v = await lab.edition(m, l);
      final session = await l.openPlayback(v.binding.learningVersionId);
      final cache = lab.cache(m, l);
      final original = lab.blob(v.media!.artifact);
      final before = await original.readAsBytes();
      final prepared = await cache.prepare(session.item);
      final uri = await cache.resolveForEngine(session.item);
      final file = File.fromUri(uri);
      expectThat(
        prepared.binding.sameAs(v.binding) && uri.scheme == 'file',
        'only checked full binding reaches the private engine resolver',
      );
      final parent = await lab.cacheRoot.resolveSymbolicLinks();
      final actual = await file.resolveSymbolicLinks();
      expectThat(
        actual.startsWith('$parent${Platform.pathSeparator}') &&
            !FileSystemEntity.identicalSync(file.path, original.path),
        'prepared bytes must stay below private cache root in a separate file',
      );
      expectThat(
        sha256.convert(await file.readAsBytes()).toString() ==
                v.media!.artifact.sha256 &&
            sha256.convert(await original.readAsBytes()).toString() ==
                sha256.convert(before).toString(),
        'copy and original must remain byte-identical to the declared source',
      );
    }),
  );

  await tests.run(
    'Prepared source is reused after an independent Dart process restart',
    () => using((lab) async {
      final m = await lab.material();
      final l = await lab.learning(m);
      final v = await lab.edition(m, l);
      final session = await l.openPlayback(v.binding.learningVersionId);
      final cache = lab.cache(m, l);
      await cache.prepare(session.item);
      final file = File.fromUri(await cache.resolveForEngine(session.item));
      final modified = DateTime.utc(2020, 1, 2, 3, 4, 5);
      await file.setLastModified(modified);
      await lab.closeLearning(l);
      await lab.closeMaterial(m);
      await verifyCacheInNewProcess(lab, v, modified);
    }),
  );

  await tests.run(
    'Valid prepared cache never bypasses missing original source',
    () => using((lab) async {
      final m = await lab.material();
      final l = await lab.learning(m);
      final v = await lab.edition(m, l);
      final session = await l.openPlayback(v.binding.learningVersionId);
      final cache = lab.cache(m, l);
      await cache.prepare(session.item);
      await lab.blob(v.media!.artifact).delete();
      await expectError(() => cache.prepare(session.item), {
        LearningPlaybackErrorCode.sourceUnavailable,
      });
      await expectError(() => cache.resolveForEngine(session.item), {
        LearningPlaybackErrorCode.sourceUnavailable,
      });
    }),
  );

  await tests.run(
    'Same-length corrupted prepared bytes are rejected without automatic repair',
    () => using((lab) async {
      final m = await lab.material();
      final l = await lab.learning(m);
      final v = await lab.edition(m, l);
      final session = await l.openPlayback(v.binding.learningVersionId);
      final cache = lab.cache(m, l);
      await cache.prepare(session.item);
      final file = File.fromUri(await cache.resolveForEngine(session.item));
      final bytes = await file.readAsBytes();
      bytes[60] ^= 1;
      await file.writeAsBytes(bytes, flush: true);
      await expectError(() => cache.prepare(session.item), {
        LearningPlaybackErrorCode.cacheCorrupt,
      });
      await expectError(() => cache.resolveForEngine(session.item), {
        LearningPlaybackErrorCode.cacheCorrupt,
      });
      expectThat(
        sha256
                .convert(await lab.blob(v.media!.artifact).readAsBytes())
                .toString() ==
            v.media!.artifact.sha256,
        'cache damage cannot mutate original artifact',
      );
    }),
  );

  await tests.run(
    'Private resolver rejects wrong owner and wrong media revision',
    () => using((lab) async {
      final m = await lab.material();
      final l = await lab.learning(m);
      final v = await lab.edition(m, l);
      final other = await lab.edition(m, l, label: 'other');
      final session = await l.openPlayback(v.binding.learningVersionId);
      final cache = lab.cache(m, l);
      await expectError(
        () => cache.prepare(
          PlaybackItem(
            ownerId: ownerB,
            itemId: session.item.itemId,
            itemRevision: session.item.itemRevision,
            kind: MediaKind.audio,
          ),
        ),
        {LearningPlaybackErrorCode.ownerMismatch},
      );
      await expectError(
        () => cache.prepare(
          PlaybackItem(
            ownerId: ownerA,
            itemId: session.item.itemId,
            itemRevision: other.binding.mediaVersionId!,
            kind: MediaKind.audio,
          ),
        ),
        {LearningPlaybackErrorCode.bindingMismatch},
      );
    }),
  );

  await tests.run(
    'Cache rejects mismatched trusted material and learning owners',
    () => using((lab) async {
      final a = await lab.material();
      final b = await lab.material(ownerB);
      final la = await lab.learning(a);
      await expectError(() => Future.sync(() => lab.cache(b, la)), {
        LearningPlaybackErrorCode.ownerMismatch,
      });
    }),
  );

  await tests.run(
    'Open ack is not ready and Open never dispatches Play',
    () => using((lab) async {
      final m = await lab.material();
      final l = await lab.learning(m);
      final v = await lab.edition(m, l);
      final r = lab.rig(l, lab.cache(m, l));
      final gate = Completer<void>();
      r.engine.nextOpen = gate;
      final opening = await r.begin(v);
      gate.complete();
      await settle();
      expectThat(
        r.coordinator.current.phase != LearningPlaybackPhase.ready &&
            r.engine.count('play') == 0 &&
            r.engine.count('seek') == 0,
        'native load acknowledgement cannot pretend loaded facts or start playback',
      );
      r.observedLoad(opening.token);
      final result = await opening.result;
      expectThat(
        result.status == LearningOpenStatus.ready &&
            !result.checkpointRestored &&
            r.engine.count('play') == 0,
        'observed load/duration can mark ready while staying paused',
      );
      expectThat(
        r.core.current.intent == PlaybackIntent.paused,
        'restored source must not inherit playing intent',
      );
    }),
  );

  await tests.run(
    'Positive duration without loaded state does not prematurely restore',
    () => using((lab) async {
      final m = await lab.material();
      final l = await lab.learning(m);
      final v = await lab.edition(m, l);
      await lab.seedProgress(l, v);
      final r = lab.rig(l, lab.cache(m, l));
      final opening = await r.begin(v);
      r.engine.emit(
        EngineProgress(
          opening.token,
          position: Duration.zero,
          duration: const Duration(seconds: 6),
        ),
      );
      await settle();
      expectThat(
        r.engine.count('seek') == 0 &&
            r.coordinator.current.phase != LearningPlaybackPhase.ready,
        'duration alone is not actual loaded state',
      );
      r.engine.emit(EngineStateChanged(opening.token, PlaybackActual.paused));
      await until(() => r.engine.count('seek') == 1);
      final seek = r.engine.last('seek');
      r.engine.emit(
        EngineSeekSettled(
          seek.token,
          requestId: seek.requestId!,
          position: seek.position!,
        ),
      );
      expectThat(
        (await opening.result).status == LearningOpenStatus.ready &&
            r.engine.count('play') == 0,
        'restore only follows current loaded facts',
      );
    }),
  );

  await tests.run(
    'Restoration waits for nonzero duration and confirmed exact seek before ready',
    () => using((lab) async {
      final m = await lab.material();
      final l = await lab.learning(m);
      final v = await lab.edition(m, l);
      await lab.seedProgress(l, v);
      final r = lab.rig(l, lab.cache(m, l));
      final opening = await r.begin(v);
      r.engine.emit(EngineStateChanged(opening.token, PlaybackActual.paused));
      r.engine.emit(
        EngineProgress(
          opening.token,
          position: Duration.zero,
          duration: Duration.zero,
        ),
      );
      await settle();
      expectThat(
        r.engine.count('seek') == 0 && r.engine.count('play') == 0,
        'zero duration cannot trigger a clamped or guessed seek',
      );
      r.engine.emit(
        EngineProgress(
          opening.token,
          position: Duration.zero,
          duration: const Duration(seconds: 6),
        ),
      );
      await until(() => r.engine.count('seek') == 1);
      final seek = r.engine.last('seek');
      expectThat(
        seek.position == const Duration(milliseconds: 4200) &&
            !r.coordinator.current.checkpointRestored,
        'seek target is exact old-version position, not completion evidence',
      );
      expectThat(
        (await l.restoreProgress(v.binding.learningVersionId))!.position ==
            const Duration(milliseconds: 4200),
        'load default zero must not overwrite old checkpoint',
      );
      r.engine.emit(
        EngineSeekSettled(
          seek.token,
          requestId: seek.requestId!,
          position: seek.position!,
        ),
      );
      final result = await opening.result;
      expectThat(
        result.status == LearningOpenStatus.ready &&
            result.checkpointRestored &&
            r.core.current.intent == PlaybackIntent.paused &&
            r.engine.count('play') == 0,
        'confirmed restoration remains paused',
      );
    }),
  );

  await tests.run(
    'Mismatched native duration is not accepted as the prepared media',
    () => using((lab) async {
      final m = await lab.material();
      final l = await lab.learning(m);
      final v = await lab.edition(m, l);
      await lab.seedProgress(l, v);
      final r = lab.rig(l, lab.cache(m, l));
      final opening = await r.begin(v);
      r.observedLoad(opening.token, seconds: 12);
      final result = await opening.result;
      expectThat(
        result.status != LearningOpenStatus.ready &&
            r.engine.count('seek') == 0 &&
            r.engine.count('play') == 0,
        'different duration cannot claim restore or guessed progress',
      );
    }),
  );

  await tests.run(
    'Actual observed position is saved; pending seek target never is',
    () => using((lab) async {
      final m = await lab.material();
      final l = await lab.learning(m);
      final v = await lab.edition(m, l);
      final r = lab.rig(l, lab.cache(m, l));
      expectThat(
        (await r.load(v)).status == LearningOpenStatus.ready,
        'fixture load should become ready',
      );
      await r.actualPlayAt(const Duration(milliseconds: 1800));
      await r.coordinator.flushProgress();
      final first = await l.restoreProgress(v.binding.learningVersionId);
      expectThat(
        first!.position == const Duration(milliseconds: 1800),
        'observed position, not a displayed target, is authoritative',
      );
      final result = await r.coordinator.dispatch(
        const Seek(Duration(seconds: 5)),
      );
      expectThat(result.accepted, 'user seek accepted');
      await until(() => r.engine.count('seek') == 1);
      final seek = r.engine.last('seek');
      await settle();
      await expectError(() => r.coordinator.flushProgress(), {
        LearningPlaybackErrorCode.notReady,
      });
      expectThat(
        (await l.restoreProgress(v.binding.learningVersionId))!.position ==
            first.position,
        'seek ack alone cannot advance checkpoint to five seconds',
      );
      r.engine.emit(
        EngineSeekSettled(
          seek.token,
          requestId: seek.requestId!,
          position: const Duration(seconds: 5),
        ),
      );
      await settle();
      await r.coordinator.flushProgress();
      final saved = await l.restoreProgress(v.binding.learningVersionId);
      expectThat(
        saved!.position == const Duration(seconds: 5) &&
            saved.sentenceId == v.sentences[1].sentenceId &&
            saved.binding.sameAs(v.binding),
        'confirmed real position uses correct sentence and full version binding',
      );
    }),
  );

  await tests.run(
    'Seek confirmation timeout never becomes completed progress',
    () => using((lab) async {
      final m = await lab.material();
      final l = await lab.learning(m);
      final v = await lab.edition(m, l);
      final r = lab.rig(
        l,
        lab.cache(m, l),
        seekTimeout: const Duration(milliseconds: 30),
      );
      await r.load(v);
      await r.actualPlayAt(const Duration(seconds: 1));
      await r.coordinator.flushProgress();
      final before = await l.restoreProgress(v.binding.learningVersionId);
      final failed = r.core.snapshots.firstWhere((s) => s.error != null);
      await r.coordinator.dispatch(const Seek(Duration(seconds: 5)));
      await failed;
      await settle();
      expectThat(
        r.coordinator.current.error != null,
        'unconfirmed seek must remain observable as failure',
      );
      await expectError(() => r.coordinator.flushProgress(), {
        LearningPlaybackErrorCode.notReady,
      });
      expectThat(
        (await l.restoreProgress(v.binding.learningVersionId))!.position ==
            before!.position,
        'timeout cannot pretend target arrival',
      );
    }),
  );

  await tests.run(
    'Explicit Pause cancels old automatic restore without replacing checkpoint by zero',
    () => using((lab) async {
      final m = await lab.material();
      final l = await lab.learning(m);
      final v = await lab.edition(m, l);
      await lab.seedProgress(l, v);
      final r = lab.rig(l, lab.cache(m, l));
      final opening = await r.begin(v);
      final paused = await r.coordinator.dispatch(const Pause());
      r.observedLoad(paused.token);
      final result = await opening.result;
      expectThat(
        result.status == LearningOpenStatus.ready &&
            !result.checkpointRestored &&
            r.engine.count('seek') == 0 &&
            r.engine.count('play') == 0,
        'manual pause revokes stale automatic restore',
      );
      try {
        await r.coordinator.flushProgress();
      } on LearningPlaybackException catch (error) {
        expectThat(
          error.code == LearningPlaybackErrorCode.notReady,
          'only unconfirmed progress can refuse flushing',
        );
      }
      expectThat(
        (await l.restoreProgress(v.binding.learningVersionId))!.position ==
            const Duration(milliseconds: 4200),
        'default zero after canceled restore is not an observed replacement checkpoint',
      );
    }),
  );

  await tests.run(
    'Readiness timeout is pending and late load cannot resurrect canceled restore',
    () => using((lab) async {
      final m = await lab.material();
      final l = await lab.learning(m);
      final v = await lab.edition(m, l);
      await lab.seedProgress(l, v);
      final r = lab.rig(
        l,
        lab.cache(m, l),
        readiness: const Duration(milliseconds: 40),
      );
      final opening = await r.begin(v);
      final result = await opening.result;
      expectThat(
        result.status == LearningOpenStatus.pending &&
            !result.checkpointRestored,
        'deadline is not proof of load/seek readiness',
      );
      r.observedLoad(opening.token);
      await settle();
      expectThat(
        r.engine.count('seek') == 0 && r.engine.count('play') == 0,
        'late metadata must not restart an expired automatic restore',
      );
      expectThat(
        (await l.restoreProgress(v.binding.learningVersionId))!.position ==
            const Duration(milliseconds: 4200),
        'timeout keeps prior checkpoint intact',
      );
    }),
  );

  await tests.run(
    'Old engine callbacks after another material open cannot label or save the new item',
    () => using((lab) async {
      final m = await lab.material();
      final l = await lab.learning(m);
      final a = await lab.edition(m, l);
      final b = await lab.edition(m, l, label: 'different-material');
      final r = lab.rig(l, lab.cache(m, l));
      final old = await r.begin(a);
      final current = await r.begin(b);
      r.observedLoad(old.token);
      r.engine.emit(
        EngineProgress(
          old.token,
          position: const Duration(seconds: 5),
          duration: const Duration(seconds: 6),
        ),
      );
      await settle();
      expectThat(
        r.coordinator.current.binding!.sameAs(b.binding) &&
            r.coordinator.current.phase != LearningPlaybackPhase.ready,
        'old native state cannot satisfy current loading',
      );
      r.observedLoad(current.token);
      expectThat(
        (await current.result).status == LearningOpenStatus.ready,
        'current observed source can load',
      );
      expectThat(
        (await old.result).status == LearningOpenStatus.superseded,
        'old open future explicitly reports replacement',
      );
      await r.actualPlayAt(const Duration(seconds: 1));
      await r.coordinator.flushProgress();
      expectThat(
        await l.restoreProgress(a.binding.learningVersionId) == null &&
            (await l.restoreProgress(b.binding.learningVersionId))!.position ==
                const Duration(seconds: 1),
        'only current observed material receives progress',
      );
    }),
  );

  await tests.run(
    'Different learning-media revision does not inherit prior edition percentage',
    () => using((lab) async {
      final m = await lab.material();
      final l = await lab.learning(m);
      final a = await lab.edition(m, l);
      await lab.seedProgress(l, a);
      final b = await lab.edition(m, l, seconds: 24, label: 'new-media');
      final r = lab.rig(l, lab.cache(m, l));
      final result = await r.load(b, seconds: 24);
      expectThat(
        result.status == LearningOpenStatus.ready &&
            !result.checkpointRestored &&
            r.engine.count('seek') == 0,
        'fresh media starts without scaled old progress',
      );
      expectThat(
        await l.restoreProgress(b.binding.learningVersionId) == null &&
            (await l.restoreProgress(a.binding.learningVersionId))!.position ==
                const Duration(milliseconds: 4200),
        'editions retain independent checkpoints',
      );
    }),
  );

  await tests.run(
    'Foreign owner edition and malformed source never reach engine Open',
    () => using((lab) async {
      final a = await lab.material();
      final b = await lab.material(ownerB);
      final la = await lab.learning(a);
      final lb = await lab.learning(b);
      final foreign = await lab.edition(b, lb);
      final r = lab.rig(la, lab.cache(a, la));
      final result = await r.coordinator.open(
        foreign.binding.learningVersionId,
      );
      final invalid = await r.coordinator.open('../../synthetic-outside');
      final bypass = await r.coordinator.dispatch(
        const Open(
          PlaybackItem(
            ownerId: ownerB,
            itemId: 'untrusted-item',
            itemRevision: 'untrusted-revision',
            kind: MediaKind.audio,
          ),
        ),
      );
      expectThat(
        result.status == LearningOpenStatus.rejected &&
            invalid.status == LearningOpenStatus.rejected &&
            !bypass.accepted &&
            r.engine.count('open') == 0 &&
            r.engine.count('play') == 0,
        'untrusted owner/id must fail before native loading',
      );
    }),
  );

  await tests.run(
    'Source hash drift is rejected before a new engine load',
    () => using((lab) async {
      final m = await lab.material();
      final l = await lab.learning(m);
      final v = await lab.edition(m, l);
      final file = lab.blob(v.media!.artifact);
      final bytes = await file.readAsBytes();
      bytes[60] ^= 1;
      await file.writeAsBytes(bytes, flush: true);
      final r = lab.rig(l, lab.cache(m, l));
      final result = await r.coordinator.open(v.binding.learningVersionId);
      expectThat(
        result.status == LearningOpenStatus.rejected &&
            r.engine.count('open') == 0,
        'source mismatch cannot become playable from stale version metadata',
      );
    }),
  );

  await tests.run(
    'Stop and native idle zero cannot erase the last actual learning position',
    () => using((lab) async {
      final m = await lab.material();
      final l = await lab.learning(m);
      final v = await lab.edition(m, l);
      final r = lab.rig(l, lab.cache(m, l));
      await r.load(v);
      await r.actualPlayAt(const Duration(milliseconds: 1800));
      await r.coordinator.flushProgress();
      final stopped = await r.coordinator.dispatch(const Stop());
      r.engine.emit(EngineStateChanged(stopped.token, PlaybackActual.idle));
      r.engine.emit(EngineProgress(stopped.token, position: Duration.zero));
      await settle();
      try {
        await r.coordinator.flushProgress();
      } on LearningPlaybackException catch (error) {
        expectThat(
          error.code == LearningPlaybackErrorCode.notReady,
          'stopped callback must only refuse unready progress',
        );
      }
      expectThat(
        (await l.restoreProgress(v.binding.learningVersionId))!.position ==
            const Duration(milliseconds: 1800),
        'Stop reset is not a manual rewind checkpoint',
      );
    }),
  );

  await tests.run(
    'Closing coordinator rejects later commands without disposing externally owned stores',
    () => using((lab) async {
      final m = await lab.material();
      final l = await lab.learning(m);
      final v = await lab.edition(m, l);
      final r = lab.rig(l, lab.cache(m, l));
      await r.load(v);
      await r.coordinator.close();
      expectThat(
        r.coordinator.current.phase == LearningPlaybackPhase.closed,
        'closed phase is explicit',
      );
      expectThat(
        !(await r.coordinator.dispatch(const Play())).accepted,
        'closed coordinator cannot play',
      );
      expectThat(
        (await l.readVersion(v.binding.learningVersionId)).binding
            .sameAs(v.binding),
        'external learning store remains usable',
      );
      expectThat(
        (await m.listDrafts()).isNotEmpty,
        'external material store remains usable',
      );
    }),
  );
  await tests.run(
    'External checkpoint revision conflict blocks blind retry and preserves newer progress',
    () => using((lab) async {
      final m = await lab.material();
      final l = await lab.learning(m);
      final v = await lab.edition(m, l);
      final r = lab.rig(l, lab.cache(m, l));
      final opened = await r.load(v);
      await r.actualPlayAt(const Duration(seconds: 1));
      await r.coordinator.flushProgress();
      final current = (await l.restoreProgress(v.binding.learningVersionId))!;
      final external = await l.saveProgress(
        session: opened.session!,
        expectedRevision: current.revision,
        sentenceId: v.sentences[0].sentenceId,
        position: const Duration(milliseconds: 1200),
      );
      r.engine.emit(
        EngineProgress(
          r.core.current.token,
          position: const Duration(seconds: 2),
          duration: const Duration(seconds: 6),
        ),
      );
      await until(() => r.coordinator.current.error != null);
      await expectError(() => r.coordinator.flushProgress(), {
        LearningPlaybackErrorCode.checkpointFailed,
      });
      final stored = (await l.restoreProgress(v.binding.learningVersionId))!;
      expectThat(
        stored.revision == external.revision &&
            stored.position == external.position,
        'stale coordinator revision must not blindly rebase and overwrite newer checkpoint',
      );
    }),
  );

  await tests.run(
    'Externally replaced learning session rejects old coordinator checkpoint receipts',
    () => using((lab) async {
      final m = await lab.material();
      final l = await lab.learning(m);
      final v = await lab.edition(m, l);
      final r = lab.rig(l, lab.cache(m, l));
      await r.load(v);
      await r.actualPlayAt(const Duration(seconds: 1));
      await r.coordinator.flushProgress();
      final current = (await l.restoreProgress(v.binding.learningVersionId))!;
      final newerSession = await l.openPlayback(v.binding.learningVersionId);
      final external = await l.saveProgress(
        session: newerSession,
        expectedRevision: current.revision,
        sentenceId: v.sentences[0].sentenceId,
        position: const Duration(milliseconds: 1200),
      );
      r.engine.emit(
        EngineProgress(
          r.core.current.token,
          position: const Duration(seconds: 2),
          duration: const Duration(seconds: 6),
        ),
      );
      await until(() => r.coordinator.current.error != null);
      await expectError(() => r.coordinator.flushProgress(), {
        LearningPlaybackErrorCode.checkpointFailed,
      });
      final stored = (await l.restoreProgress(v.binding.learningVersionId))!;
      expectThat(
        stored.revision == external.revision &&
            stored.position == external.position,
        'old session cannot relabel its native observation as the newer session',
      );
    }),
  );
  tests.finish();
}
