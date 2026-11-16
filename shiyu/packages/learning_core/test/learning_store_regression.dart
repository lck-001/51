import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:material_core/material_core.dart';
import 'package:playback_core/playback_core.dart';

import '../lib/learning_core.dart';
import 'support.dart';
import 'wav_fixture.dart';

const ownerA = 'synthetic-learning-owner-a';
const ownerB = 'synthetic-learning-owner-b';
const sourceText = '这是自造材料：纸船驶过蓝色湖面。';
const provided = ContentProvenance(
  origin: ContentOrigin.synthetic,
  reference: 'fixture:provided-english-not-ai',
);
const toneSource = ContentProvenance(
  origin: ContentOrigin.synthetic,
  reference: 'fixture:pcm-tone-not-speech-or-tts',
);
const sentences = [
  LearningSentenceInput(
    english: 'A paper boat crosses the blue lake.',
    translation: '一只纸船驶过蓝色湖面。',
  ),
  LearningSentenceInput(
    english: 'I watch it from the shore.',
    translation: '我在岸边看着它。',
  ),
];
const timing = [
  SentenceTiming(sentenceIndex: 0, startMs: 0, endMs: 3000),
  SentenceTiming(sentenceIndex: 1, startMs: 3000, endMs: 6000),
];

Future<LearningStoreException> expectError(
  Future<dynamic> Function() action,
  Set<LearningErrorCode> codes,
) async {
  try {
    await action();
  } on LearningStoreException catch (error) {
    expectThat(
      codes.contains(error.code),
      'unexpected learning error: ${error.code.name}',
    );
    return error;
  }
  throw StateError(
    'operation unexpectedly succeeded instead of explicit failure',
  );
}

class Lab {
  Lab(this.sandbox)
    : materialRoot = Directory(
        '${sandbox.path}${Platform.pathSeparator}materials',
      ),
      learningRoot = Directory(
        '${sandbox.path}${Platform.pathSeparator}learning',
      );
  final Directory sandbox, materialRoot, learningRoot;
  final List<MaterialStore> materialStores = [];
  final List<LearningStore> learningStores = [];
  Future<MaterialStore> material([String owner = ownerA]) async {
    final store = await FileMaterialStore.open(
      root: materialRoot,
      trustedOwnerId: owner,
    );
    materialStores.add(store);
    return store;
  }

  Future<LearningStore> learning(MaterialStore materials) async {
    final store = await FileLearningStore.open(
      root: learningRoot,
      materials: materials,
    );
    learningStores.add(store);
    return store;
  }

  Future<MaterialVersion> source(
    MaterialStore materials, {
    String title = '合成源材料',
  }) async {
    final draft = await materials.createDraft(title: title, text: sourceText);
    return materials.confirmVersion(
      materialId: draft.materialId,
      expectedRevision: draft.revision,
    );
  }

  Future<LearningMediaInput> media(
    MaterialStore materials, {
    Duration duration = const Duration(seconds: 6),
    Iterable<SentenceTiming> timings = timing,
  }) async {
    final artifact = await materials.importArtifact(pcmTone(duration));
    return LearningMediaInput(
      artifact: artifact,
      provenance: toneSource,
      timings: timings,
    );
  }

  Future<LearningVersion> ready(
    LearningStore learning,
    MaterialStore materials,
    MaterialVersion version, {
    LearningMediaInput? input,
  }) async => learning.createVersion(
    materialVersionId: version.versionId,
    sentences: sentences,
    textProvenance: provided,
    media: input ?? await media(materials),
  );
  Directory partition([String owner = ownerA]) => Directory(
    '${learningRoot.path}${Platform.pathSeparator}${sha256.convert(utf8.encode('learning-owner:$owner'))}',
  );
  File manifest() =>
      File('${partition().path}${Platform.pathSeparator}learning.json');
  File backup() =>
      File('${partition().path}${Platform.pathSeparator}learning.bak');
  File blob(ArtifactRef ref) => File(
    '${materialRoot.path}${Platform.pathSeparator}${sha256.convert(utf8.encode('owner:${ref.ownerId}'))}${Platform.pathSeparator}artifacts${Platform.pathSeparator}${ref.artifactId}.blob',
  );
  Future<void> closeLearning(LearningStore store) async {
    learningStores.remove(store);
    await store.close();
  }

  Future<void> closeMaterial(MaterialStore store) async {
    materialStores.remove(store);
    await store.close();
  }

  Future<void> finish() async {
    for (final store in learningStores.reversed.toList()) {
      await closeLearning(store);
    }
    for (final store in materialStores.reversed.toList()) {
      await closeMaterial(store);
    }
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

LearningBinding copyBinding(
  LearningBinding b, {
  String? owner,
  String? material,
  String? materialVersion,
  String? learningVersion,
  String? mediaVersion,
}) => LearningBinding(
  ownerId: owner ?? b.ownerId,
  materialId: material ?? b.materialId,
  materialVersionId: materialVersion ?? b.materialVersionId,
  learningVersionId: learningVersion ?? b.learningVersionId,
  mediaVersionId: mediaVersion ?? b.mediaVersionId,
);

Future<void> newProcess(Lab lab, String versionId, String sentenceId) async {
  final process = await Process.start(Platform.resolvedExecutable, [
    Platform.script.toFilePath(),
    '--child-restore',
    lab.materialRoot.path,
    lab.learningRoot.path,
    versionId,
    sentenceId,
  ], workingDirectory: Directory.current.path);
  final output = process.stdout.transform(utf8.decoder).join();
  final errors = process.stderr.drain<void>();
  int result;
  try {
    result = await process.exitCode.timeout(const Duration(seconds: 10));
  } on TimeoutException {
    process.kill();
    await process.exitCode.timeout(const Duration(seconds: 3));
    throw StateError('independent learning restore timed out');
  }
  final text = await output;
  await errors;
  expectThat(
    result == 0 && text.trim() == 'CHILD_LEARNING_RESTORE_OK',
    'new Dart process must recover exact version position paused',
  );
}

Future<void> childRestore(List<String> args) async {
  MaterialStore? materials;
  LearningStore? learning;
  try {
    materials = await FileMaterialStore.open(
      root: Directory(args[1]),
      trustedOwnerId: ownerA,
    );
    learning = await FileLearningStore.open(
      root: Directory(args[2]),
      materials: materials,
    );
    final version = await learning.readVersion(args[3]);
    final checkpoint = await learning.restoreProgress(args[3]);
    expectThat(
      checkpoint != null && checkpoint.binding.sameAs(version.binding),
      'child must retain full version binding',
    );
    expectThat(
      checkpoint!.sentenceId == args[4] &&
          checkpoint.position == const Duration(milliseconds: 4200) &&
          checkpoint.revision == 1,
      'child restored the wrong anchor or exact position',
    );
    expectThat(
      checkpoint.resumeIntent == PlaybackIntent.paused,
      'cold restore must never request playing',
    );
    final session = await learning.openPlayback(args[3]);
    expectThat(
      session.resumeIntent == PlaybackIntent.paused &&
          session.progressRevision == 1,
      'opening restored edition must also remain paused',
    );
    stdout.writeln('CHILD_LEARNING_RESTORE_OK');
  } catch (_) {
    stdout.writeln('CHILD_LEARNING_RESTORE_FAILED');
    exitCode = 1;
  } finally {
    await learning?.close();
    await materials?.close();
  }
}

Future<void> main(List<String> args) async {
  if (args.isNotEmpty && args.first == '--child-restore') {
    await childRestore(args);
    return;
  }
  final tests = Cases();

  await tests.run(
    'Only confirmed source material versions can anchor learning',
    () => using((lab) async {
      final m = await lab.material();
      final l = await lab.learning(m);
      final draft = await m.createDraft(
        title: 'Synthetic unconfirmed source',
        text: sourceText,
      );
      await expectError(
        () => l.createVersion(
          materialVersionId: draft.materialId,
          sentences: sentences,
          textProvenance: provided,
        ),
        {LearningErrorCode.notFound, LearningErrorCode.invalidId},
      );
      expectThat(
        (await l.listVersions()).isEmpty,
        'unconfirmed source must not create a learning edition',
      );
    }),
  );

  await tests.run(
    'Missing English never becomes ready even with real PCM bytes',
    () => using((lab) async {
      final m = await lab.material();
      final l = await lab.learning(m);
      final source = await lab.source(m);
      final v = await l.createVersion(
        materialVersionId: source.versionId,
        sentences: [const LearningSentenceInput(english: '   ')],
        textProvenance: provided,
        media: await lab.media(
          m,
          timings: [
            const SentenceTiming(sentenceIndex: 0, startMs: 0, endMs: 6000),
          ],
        ),
      );
      expectThat(
        v.state == LearningState.pending && v.issues.isNotEmpty,
        'blank English must be pending, not ready',
      );
      await expectError(() => l.openPlayback(v.binding.learningVersionId), {
        LearningErrorCode.notReady,
      });
    }),
  );

  await tests.run(
    'Provided English without audio is explicit partial not a generated lesson',
    () => using((lab) async {
      final m = await lab.material();
      final l = await lab.learning(m);
      final source = await lab.source(m);
      final v = await l.createVersion(
        materialVersionId: source.versionId,
        sentences: sentences,
        textProvenance: provided,
      );
      expectThat(
        v.state == LearningState.partial &&
            v.media == null &&
            v.issues.isNotEmpty,
        'English alone cannot pretend audio-ready',
      );
      expectThat(
        v.textProvenance.origin == ContentOrigin.synthetic &&
            v.textProvenance.reference == provided.reference,
        'provided content must not acquire an AI-generated label',
      );
      await expectError(() => l.openPlayback(v.binding.learningVersionId), {
        LearningErrorCode.notReady,
      });
    }),
  );

  await tests.run(
    'Valid PCM and supplied content retain complete fixed-version provenance',
    () => using((lab) async {
      final m = await lab.material();
      final l = await lab.learning(m);
      final source = await lab.source(m);
      final v = await lab.ready(l, m, source);
      expectThat(
        v.state == LearningState.ready && v.media!.durationMs == 6000,
        'ready requires duration parsed from actual PCM bytes',
      );
      expectThat(
        v.binding.ownerId == ownerA &&
            v.binding.materialId == source.materialId &&
            v.binding.materialVersionId == source.versionId &&
            v.binding.mediaVersionId == v.media!.mediaVersionId,
        'all source, learning and media identities must be bound',
      );
      expectThat(
        v.textProvenance.origin == ContentOrigin.synthetic &&
            v.media!.provenance.reference == toneSource.reference,
        'synthetic tone must not be reported as AI/TTS speech',
      );
      final session = await l.openPlayback(v.binding.learningVersionId);
      expectThat(
        session.binding.sameAs(v.binding) &&
            session.item.ownerId == ownerA &&
            session.item.kind == MediaKind.audio &&
            session.resumeIntent == PlaybackIntent.paused,
        'open returns matching audio context paused, never auto-Play',
      );
    }),
  );

  await tests.run(
    'Foreign owner material versions and media cannot cross the boundary',
    () => using((lab) async {
      final a = await lab.material();
      final b = await lab.material(ownerB);
      final l = await lab.learning(a);
      final sourceA = await lab.source(a);
      final sourceB = await lab.source(b);
      await expectError(
        () => l.createVersion(
          materialVersionId: sourceB.versionId,
          sentences: sentences,
          textProvenance: provided,
        ),
        {LearningErrorCode.notFound, LearningErrorCode.ownerMismatch},
      );
      final foreign = await lab.media(b);
      await expectError(
        () => l.createVersion(
          materialVersionId: sourceA.versionId,
          sentences: sentences,
          textProvenance: provided,
          media: foreign,
        ),
        {LearningErrorCode.ownerMismatch},
      );
      expectThat(
        (await l.listVersions()).isEmpty,
        'foreign references must not create hidden ready editions',
      );
    }),
  );

  await tests.run(
    'Two synthetic owners have isolated editions and checkpoints',
    () => using((lab) async {
      final a = await lab.material();
      final b = await lab.material(ownerB);
      final la = await lab.learning(a);
      final lb = await lab.learning(b);
      final v = await lab.ready(la, a, await lab.source(a));
      final session = await la.openPlayback(v.binding.learningVersionId);
      await la.saveProgress(
        session: session,
        expectedRevision: 0,
        sentenceId: v.sentences.first.sentenceId,
        position: const Duration(seconds: 1),
      );
      expectThat(
        (await lb.listVersions()).isEmpty,
        'other owner cannot list the edition',
      );
      await expectError(() => lb.readVersion(v.binding.learningVersionId), {
        LearningErrorCode.notFound,
        LearningErrorCode.ownerMismatch,
      });
      await expectError(() => lb.openPlayback(v.binding.learningVersionId), {
        LearningErrorCode.notFound,
        LearningErrorCode.ownerMismatch,
      });
      await expectError(() => lb.restoreProgress(v.binding.learningVersionId), {
        LearningErrorCode.notFound,
        LearningErrorCode.ownerMismatch,
      });
    }),
  );

  await tests.run(
    'Old editions and sentence anchors remain immutable after source revision',
    () => using((lab) async {
      final m = await lab.material();
      final l = await lab.learning(m);
      final original = await lab.source(m, title: 'Original synthetic title');
      final old = await lab.ready(l, m, original);
      final anchorIds = old.sentences.map((s) => s.sentenceId).toList();
      final changed = await m.updateDraft(
        materialId: original.materialId,
        expectedRevision: original.draftRevision,
        title: 'New synthetic title',
        text: '新版合成原文',
      );
      final source2 = await m.confirmVersion(
        materialId: changed.materialId,
        expectedRevision: changed.revision,
      );
      final newer = await l.createVersion(
        materialVersionId: source2.versionId,
        sentences: const [
          LearningSentenceInput(
            english: 'The synthetic story now describes a red kite.',
          ),
          LearningSentenceInput(
            english: 'Its wording changed in a new edition.',
          ),
        ],
        textProvenance: provided,
        media: await lab.media(m),
      );
      await lab.closeLearning(l);
      final restored = await lab.learning(m);
      final oldAgain = await restored.readVersion(
        old.binding.learningVersionId,
      );
      expectThat(
        oldAgain.binding.materialVersionId == original.versionId &&
            oldAgain.materialTitle == 'Original synthetic title',
        'old lesson must never follow latest material title/version',
      );
      expectThat(
        oldAgain.sentences.map((s) => s.sentenceId).join(',') ==
                anchorIds.join(',') &&
            oldAgain.sentences.first.english == sentences.first.english,
        'old sentence anchors and wording must remain fixed',
      );
      expectThat(
        newer.binding.learningVersionId != old.binding.learningVersionId &&
            newer.binding.mediaVersionId != old.binding.mediaVersionId &&
            newer.binding.materialVersionId == source2.versionId,
        'new edition/media has separate version anchors',
      );
    }),
  );

  await tests.run(
    'Sentence anchors carry exact text and non-overwritten time bounds',
    () => using((lab) async {
      final m = await lab.material();
      final l = await lab.learning(m);
      final v = await lab.ready(l, m, await lab.source(m));
      expectThat(
        v.sentences.length == 2 &&
            v.sentences.map((s) => s.sentenceId).toSet().length == 2,
        'each immutable sentence needs a distinct anchor',
      );
      expectThat(
        v.sentences.every((s) => s.unitId.isNotEmpty),
        'sentence must retain its unit anchor',
      );
      expectThat(
        v.sentences[0].startMs == 0 &&
            v.sentences[0].endMs == 3000 &&
            v.sentences[1].startMs == 3000 &&
            v.sentences[1].endMs == 6000,
        'timing must use supplied validated sentence anchors',
      );
      expectThat(
        v.sentences[0].translation == sentences[0].translation,
        'Chinese translation must survive JSON storage',
      );
    }),
  );

  await tests.run(
    'Incomplete duplicate or out-of-duration timing never claims ready',
    () => using((lab) async {
      final m = await lab.material();
      final l = await lab.learning(m);
      final source = await lab.source(m);
      for (final times in [
        [const SentenceTiming(sentenceIndex: 0, startMs: 0, endMs: 3000)],
        [
          const SentenceTiming(sentenceIndex: 0, startMs: 0, endMs: 3000),
          const SentenceTiming(sentenceIndex: 0, startMs: 3000, endMs: 6000),
        ],
        [
          const SentenceTiming(sentenceIndex: 0, startMs: 0, endMs: 3000),
          const SentenceTiming(sentenceIndex: 1, startMs: 3000, endMs: 7000),
        ],
      ]) {
        final v = await lab.ready(
          l,
          m,
          source,
          input: await lab.media(m, timings: times),
        );
        expectThat(
          v.state != LearningState.ready && v.issues.isNotEmpty,
          'invalid timing must remain explicit non-ready',
        );
        await expectError(() => l.openPlayback(v.binding.learningVersionId), {
          LearningErrorCode.notReady,
        });
      }
    }),
  );

  await tests.run(
    'Unsupported and truncated audio remain partial without fake duration',
    () => using((lab) async {
      final m = await lab.material();
      final l = await lab.learning(m);
      final source = await lab.source(m);
      final full = pcmTone(const Duration(seconds: 6));
      for (final bytes in [
        Uint8List.fromList([1, 2, 3]),
        Uint8List.sublistView(full, 0, 55),
      ]) {
        final ref = await m.importArtifact(bytes);
        final v = await lab.ready(
          l,
          m,
          source,
          input: LearningMediaInput(
            artifact: ref,
            provenance: toneSource,
            timings: timing,
          ),
        );
        expectThat(
          v.state == LearningState.partial && v.issues.isNotEmpty,
          'bad/unsupported audio is partial, not verified',
        );
        expectThat(
          v.media?.durationMs == null,
          'truncated header cannot manufacture trusted duration',
        );
        await expectError(() => l.openPlayback(v.binding.learningVersionId), {
          LearningErrorCode.notReady,
        });
      }
    }),
  );

  await tests.run(
    'Manual provided provenance stays manual on disk and reopening',
    () => using((lab) async {
      final m = await lab.material();
      final l = await lab.learning(m);
      final source = await lab.source(m);
      const manual = ContentProvenance(
        origin: ContentOrigin.manual,
        reference: 'manual:provided-story',
      );
      final v = await l.createVersion(
        materialVersionId: source.versionId,
        sentences: sentences,
        textProvenance: manual,
        media: await lab.media(m),
      );
      await lab.closeLearning(l);
      final restored = await lab.learning(m);
      final got = await restored.readVersion(v.binding.learningVersionId);
      expectThat(
        got.textProvenance.origin == ContentOrigin.manual &&
            got.textProvenance.reference == manual.reference,
        'manual supplied English must not become AI-generated or synthetic by default',
      );
    }),
  );

  await tests.run(
    'Empty or private-path provenance is rejected without creating an edition',
    () => using((lab) async {
      final m = await lab.material();
      final l = await lab.learning(m);
      final source = await lab.source(m);
      for (final reference in [
        '',
        'file:///synthetic-private/story.txt',
        'C:\\synthetic-private\\story.txt',
      ]) {
        await expectError(
          () => l.createVersion(
            materialVersionId: source.versionId,
            sentences: sentences,
            textProvenance: ContentProvenance(
              origin: ContentOrigin.manual,
              reference: reference,
            ),
          ),
          {LearningErrorCode.invalidInput},
        );
      }
      expectThat(
        (await l.listVersions()).isEmpty,
        'invalid provenance must not appear as a normal provided edition',
      );
    }),
  );

  await tests.run(
    'Checkpoint revision conflict cannot overwrite acknowledged progress',
    () => using((lab) async {
      final m = await lab.material();
      final l = await lab.learning(m);
      final v = await lab.ready(l, m, await lab.source(m));
      final session = await l.openPlayback(v.binding.learningVersionId);
      expectThat(
        session.progressRevision == 0,
        'first checkpoint revision starts at zero',
      );
      final first = await l.saveProgress(
        session: session,
        expectedRevision: 0,
        sentenceId: v.sentences[0].sentenceId,
        position: const Duration(seconds: 1),
      );
      expectThat(
        first.revision == 1,
        'first committed checkpoint increments revision',
      );
      await expectError(
        () => l.saveProgress(
          session: session,
          expectedRevision: 0,
          sentenceId: v.sentences[0].sentenceId,
          position: const Duration(seconds: 2),
        ),
        {LearningErrorCode.revisionConflict},
      );
      final got = await l.restoreProgress(v.binding.learningVersionId);
      expectThat(
        got!.revision == 1 && got.position == const Duration(seconds: 1),
        'stale receipt must not overwrite position',
      );
      final second = await l.saveProgress(
        session: session,
        expectedRevision: 1,
        sentenceId: v.sentences[1].sentenceId,
        position: const Duration(seconds: 4),
      );
      expectThat(
        second.revision == 2,
        'same active session can checkpoint again with current expected revision',
      );
    }),
  );

  await tests.run(
    'New playback session rejects previous same-edition callbacks',
    () => using((lab) async {
      final m = await lab.material();
      final l = await lab.learning(m);
      final v = await lab.ready(l, m, await lab.source(m));
      final old = await l.openPlayback(v.binding.learningVersionId);
      final current = await l.openPlayback(v.binding.learningVersionId);
      expectThat(
        old.sessionId != current.sessionId,
        'each explicit open must have a new receipt context',
      );
      await expectError(
        () => l.saveProgress(
          session: old,
          expectedRevision: 0,
          sentenceId: v.sentences[0].sentenceId,
          position: const Duration(seconds: 1),
        ),
        {LearningErrorCode.staleSession},
      );
      expectThat(
        await l.restoreProgress(v.binding.learningVersionId) == null,
        'rejected late callback cannot create progress',
      );
    }),
  );

  await tests.run(
    'Every binding field is checked before checkpoint write',
    () => using((lab) async {
      final m = await lab.material();
      final l = await lab.learning(m);
      final v = await lab.ready(l, m, await lab.source(m));
      final current = await l.openPlayback(v.binding.learningVersionId);
      for (final binding in [
        copyBinding(current.binding, owner: ownerB),
        copyBinding(current.binding, material: 'a' * 32),
        copyBinding(current.binding, materialVersion: 'b' * 32),
        copyBinding(current.binding, learningVersion: 'c' * 32),
        copyBinding(current.binding, mediaVersion: 'd' * 32),
      ]) {
        final forged = LearningPlaybackSession(
          sessionId: current.sessionId,
          binding: binding,
          item: current.item,
          progressRevision: current.progressRevision,
        );
        await expectError(
          () => l.saveProgress(
            session: forged,
            expectedRevision: 0,
            sentenceId: v.sentences[0].sentenceId,
            position: const Duration(seconds: 1),
          ),
          {LearningErrorCode.bindingMismatch, LearningErrorCode.ownerMismatch},
        );
      }
      expectThat(
        await l.restoreProgress(v.binding.learningVersionId) == null,
        'forged bindings must not create any checkpoint',
      );
    }),
  );

  await tests.run(
    'Sentence from another edition and out-of-range positions are denied',
    () => using((lab) async {
      final m = await lab.material();
      final l = await lab.learning(m);
      final source = await lab.source(m);
      final first = await lab.ready(l, m, source);
      final other = await lab.ready(l, m, source);
      final session = await l.openPlayback(first.binding.learningVersionId);
      await expectError(
        () => l.saveProgress(
          session: session,
          expectedRevision: 0,
          sentenceId: other.sentences[0].sentenceId,
          position: const Duration(seconds: 1),
        ),
        {
          LearningErrorCode.bindingMismatch,
          LearningErrorCode.invalidInput,
          LearningErrorCode.notFound,
        },
      );
      for (final position in [
        const Duration(milliseconds: -1),
        const Duration(seconds: 7),
      ]) {
        await expectError(
          () => l.saveProgress(
            session: session,
            expectedRevision: 0,
            sentenceId: first.sentences[0].sentenceId,
            position: position,
          ),
          {LearningErrorCode.invalidInput},
        );
      }
      expectThat(
        await l.restoreProgress(first.binding.learningVersionId) == null,
        'invalid anchor or position cannot persist',
      );
    }),
  );

  await tests.run(
    'New learning-media version never inherits old percentage progress',
    () => using((lab) async {
      final m = await lab.material();
      final l = await lab.learning(m);
      final source = await lab.source(m);
      final first = await lab.ready(l, m, source);
      final session = await l.openPlayback(first.binding.learningVersionId);
      await l.saveProgress(
        session: session,
        expectedRevision: 0,
        sentenceId: first.sentences[1].sentenceId,
        position: const Duration(seconds: 4),
      );
      final media = await lab.media(
        m,
        duration: const Duration(seconds: 24),
        timings: [
          const SentenceTiming(sentenceIndex: 0, startMs: 0, endMs: 12000),
          const SentenceTiming(sentenceIndex: 1, startMs: 12000, endMs: 24000),
        ],
      );
      final newer = await lab.ready(l, m, source, input: media);
      expectThat(
        await l.restoreProgress(newer.binding.learningVersionId) == null,
        'new duration cannot scale old checkpoint percentage into new media',
      );
      final current = await l.openPlayback(newer.binding.learningVersionId);
      expectThat(
        current.progressRevision == 0 &&
            current.resumeIntent == PlaybackIntent.paused,
        'new edition starts without old progress or playing intent',
      );
      expectThat(
        (await l.restoreProgress(first.binding.learningVersionId))!.position ==
            const Duration(seconds: 4),
        'old edition keeps its own exact position',
      );
      await expectError(
        () => l.saveProgress(
          session: session,
          expectedRevision: 1,
          sentenceId: first.sentences[1].sentenceId,
          position: const Duration(seconds: 5),
        ),
        {LearningErrorCode.staleSession},
      );
    }),
  );

  await tests.run(
    'Fresh repository restores same-version exact checkpoint paused',
    () => using((lab) async {
      final m = await lab.material();
      final l = await lab.learning(m);
      final v = await lab.ready(l, m, await lab.source(m));
      final old = await l.openPlayback(v.binding.learningVersionId);
      await l.saveProgress(
        session: old,
        expectedRevision: 0,
        sentenceId: v.sentences[1].sentenceId,
        position: const Duration(milliseconds: 4200),
      );
      await lab.closeLearning(l);
      final restored = await lab.learning(m);
      final got = await restored.restoreProgress(v.binding.learningVersionId);
      expectThat(
        got!.binding.sameAs(v.binding) &&
            got.position == const Duration(milliseconds: 4200) &&
            got.resumeIntent == PlaybackIntent.paused,
        'reopen must preserve exact position and default paused',
      );
      await expectError(
        () => restored.saveProgress(
          session: old,
          expectedRevision: 1,
          sentenceId: v.sentences[1].sentenceId,
          position: const Duration(milliseconds: 4500),
        ),
        {LearningErrorCode.staleSession},
      );
    }),
  );

  await tests.run(
    'New Dart process restores version anchors and progress without Play',
    () => using((lab) async {
      final m = await lab.material();
      final l = await lab.learning(m);
      final v = await lab.ready(l, m, await lab.source(m));
      final session = await l.openPlayback(v.binding.learningVersionId);
      await l.saveProgress(
        session: session,
        expectedRevision: 0,
        sentenceId: v.sentences[1].sentenceId,
        position: const Duration(milliseconds: 4200),
      );
      await lab.closeLearning(l);
      await lab.closeMaterial(m);
      await newProcess(
        lab,
        v.binding.learningVersionId,
        v.sentences[1].sentenceId,
      );
    }),
  );

  await tests.run(
    'Missing verified media cannot resolve a playable session',
    () => using((lab) async {
      final m = await lab.material();
      final l = await lab.learning(m);
      final v = await lab.ready(l, m, await lab.source(m));
      await lab.blob(v.media!.artifact).delete();
      await expectError(() => l.openPlayback(v.binding.learningVersionId), {
        LearningErrorCode.mediaUnavailable,
        LearningErrorCode.notReady,
      });
    }),
  );

  await tests.run(
    'Media hash drift cannot resolve or checkpoint as healthy audio',
    () => using((lab) async {
      final m = await lab.material();
      final l = await lab.learning(m);
      final v = await lab.ready(l, m, await lab.source(m));
      final session = await l.openPlayback(v.binding.learningVersionId);
      final file = lab.blob(v.media!.artifact);
      final bytes = await file.readAsBytes();
      bytes[50] ^= 1;
      await file.writeAsBytes(bytes, flush: true);
      await expectError(() => l.openPlayback(v.binding.learningVersionId), {
        LearningErrorCode.mediaUnavailable,
        LearningErrorCode.notReady,
      });
      await expectError(
        () => l.saveProgress(
          session: session,
          expectedRevision: 0,
          sentenceId: v.sentences[0].sentenceId,
          position: const Duration(seconds: 1),
        ),
        {
          LearningErrorCode.mediaUnavailable,
          LearningErrorCode.staleSession,
          LearningErrorCode.notReady,
        },
      );
    }),
  );

  await tests.run(
    'Corrupt primary recovers explicit backup checkpoint not a fake zero',
    () => using((lab) async {
      final m = await lab.material();
      final l = await lab.learning(m);
      final v = await lab.ready(l, m, await lab.source(m));
      final session = await l.openPlayback(v.binding.learningVersionId);
      await l.saveProgress(
        session: session,
        expectedRevision: 0,
        sentenceId: v.sentences[0].sentenceId,
        position: const Duration(seconds: 1),
      );
      await l.saveProgress(
        session: session,
        expectedRevision: 1,
        sentenceId: v.sentences[0].sentenceId,
        position: const Duration(seconds: 2),
      );
      await lab.closeLearning(l);
      await lab.manifest().writeAsString('{"truncated":', flush: true);
      final restored = await lab.learning(m);
      final checkpoint = await restored.restoreProgress(
        v.binding.learningVersionId,
      );
      expectThat(
        restored.recoveryReport.status ==
                LearningRecoveryStatus.recoveredFromBackup &&
            checkpoint!.revision == 1 &&
            checkpoint.position == const Duration(seconds: 1),
        'backup recovery must be explicit and keep prior exact anchor',
      );
    }),
  );

  await tests.run(
    'Both damaged learning indexes fail rather than return empty successful library',
    () => using((lab) async {
      final m = await lab.material();
      final l = await lab.learning(m);
      await lab.ready(l, m, await lab.source(m));
      await lab.closeLearning(l);
      await lab.manifest().writeAsString('{', flush: true);
      await lab.backup().writeAsString('invalid', flush: true);
      await expectError(() => lab.learning(m), {
        LearningErrorCode.corruptStore,
      });
    }),
  );

  await tests.run(
    'Closed learning store refuses new reads writes and playback sessions',
    () => using((lab) async {
      final m = await lab.material();
      final l = await lab.learning(m);
      final v = await lab.ready(l, m, await lab.source(m));
      await lab.closeLearning(l);
      await expectError(() => l.listVersions(), {LearningErrorCode.closed});
      await expectError(() => l.openPlayback(v.binding.learningVersionId), {
        LearningErrorCode.closed,
      });
      await expectError(() => l.restoreProgress(v.binding.learningVersionId), {
        LearningErrorCode.closed,
      });
    }),
  );
  await tests.run(
    'Opaque PlaybackItem resolves only its exact owned learning-media version',
    () => using((lab) async {
      final m = await lab.material();
      final l = await lab.learning(m);
      final source = await lab.source(m);
      final v = await lab.ready(l, m, source);
      final other = await lab.ready(l, m, source);
      final session = await l.openPlayback(v.binding.learningVersionId);
      final artifact = await l.mediaArtifactFor(session.item);
      expectThat(
        artifact.artifactId == v.media!.artifact.artifactId &&
            artifact.ownerId == ownerA &&
            artifact.sha256 == v.media!.artifact.sha256,
        'resolver must return the checked artifact for this exact binding',
      );
      await expectError(
        () => l.mediaArtifactFor(
          PlaybackItem(
            ownerId: ownerB,
            itemId: session.item.itemId,
            itemRevision: session.item.itemRevision,
            kind: MediaKind.audio,
          ),
        ),
        {LearningErrorCode.ownerMismatch},
      );
      await expectError(
        () => l.mediaArtifactFor(
          PlaybackItem(
            ownerId: ownerA,
            itemId: session.item.itemId,
            itemRevision: other.binding.mediaVersionId!,
            kind: MediaKind.audio,
          ),
        ),
        {LearningErrorCode.bindingMismatch},
      );
      await expectError(
        () => l.mediaArtifactFor(
          PlaybackItem(
            ownerId: ownerA,
            itemId: session.item.itemId,
            itemRevision: session.item.itemRevision,
            kind: MediaKind.video,
          ),
        ),
        {LearningErrorCode.invalidInput, LearningErrorCode.bindingMismatch},
      );
    }),
  );
  tests.finish();
}
