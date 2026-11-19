import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:material_core/material_core.dart';
import 'package:playback_core/playback_core.dart';

import 'package:learning_core/learning_core.dart';

import 'candidate_independent.dart' as b1;
import '../../material_core/test/registration_regression.dart' show StopFile;
import 'support.dart';
import 'wav_fixture.dart';

const audioDeclaration = SourceDeclaration(
  preparation: 'Original synthetic PCM fixture; not narration',
  provider: 'synthetic-audio-only',
);
String hash(List<int> bytes) => sha256.convert(bytes).toString();
String english(List<LearningSentenceInput> ss) =>
    hash(utf8.encode(jsonEncode(ss.map((s) => s.english).toList())));
Directory lp(b1.Harness h) => Directory(
  '${h.root.path}/learning/${hash(utf8.encode('learning-owner:${h.ownerId}'))}',
);
File lf(b1.Harness h, String name) => File('${lp(h).path}/$name');
File blob(b1.Harness h, ArtifactRef a) => File(
  '${h.root.path}/materials/${hash(utf8.encode('owner:${h.ownerId}'))}/artifacts/${a.artifactId}.blob',
);
Future<Map<String, dynamic>> payload(
  b1.Harness h, [
  String name = 'learning.json',
]) async =>
    (jsonDecode(await lf(h, name).readAsString())
            as Map<String, dynamic>)['payload']
        as Map<String, dynamic>;
Future<void> writeSnapshot(File f, Map<String, dynamic> p, int schema) async =>
    f.writeAsString(
      jsonEncode({
        'schema': schema,
        'payload': p,
        'sha256': hash(utf8.encode(jsonEncode(p))),
      }),
      flush: true,
    );
Future<void> denied(
  FutureOr<dynamic> Function() fn,
  LearningErrorCode code,
) async {
  try {
    await fn();
  } on LearningStoreException catch (e) {
    expectThat(e.code == code, 'expected ${code.name}, got ${e.code.name}');
    return;
  }
  throw StateError('expected ${code.name}');
}

Future<LearningMediaCandidateInput> media(
  b1.Harness h,
  MaterialVersion source,
  String delivery, {
  List<LearningSentenceInput> sentences = b1.sentences,
  ArtifactRef? artifact,
  Uint8List? bytes,
  String? englishHash,
  List<SentenceTiming>? timings,
}) async {
  final ref =
      artifact ??
      await h.materials.importArtifact(
        bytes ?? pcmTone(const Duration(seconds: 1), sampleRate: 16000),
      );
  return LearningMediaCandidateInput(
    text: b1.input(source, deliveryId: delivery, text: sentences),
    media: LearningCandidateMediaInput(
      artifact: ref,
      englishSha256: englishHash ?? english(sentences),
      declaration: audioDeclaration,
      timingDeclaration:
          'Controlled exact fixture timing, not forced alignment',
      timings:
          timings ??
          [const SentenceTiming(sentenceIndex: 0, startMs: 0, endMs: 1000)],
    ),
  );
}

Future<CandidateDeliveryReceipt> receive(
  b1.Harness h,
  LearningMediaCandidateInput input,
) => h.learning.receiveMediaCandidate(sender: b1.sender, input: input);
Future<void> withHarness(
  Future<void> Function(b1.Harness h, MaterialVersion source) run,
) => inSandbox((root) async {
  final h = b1.Harness(root);
  await h.open();
  try {
    await run(h, await h.source());
  } finally {
    await h.close();
  }
});
Future<void> assertHold(b1.Harness h, String candidate) async {
  expectThat(
    h.learning.recoveryReport.issues.any((i) => i.startsWith('recovery_hold:')),
    'persistent hold visible',
  );
  await denied(
    () async => h.learning.readCandidate(candidate),
    LearningErrorCode.recoveryHold,
  );
  await denied(
    () async => h.learning.listCandidates(),
    LearningErrorCode.recoveryHold,
  );
  await denied(
    () async => h.learning.confirmCandidate(
      candidateId: candidate,
      expectedRevision: 1,
    ),
    LearningErrorCode.recoveryHold,
  );
  await denied(
    () async =>
        h.learning.rejectCandidate(candidateId: candidate, expectedRevision: 1),
    LearningErrorCode.recoveryHold,
  );
  await denied(
    () async => h.learning.reviseCandidate(
      candidateId: candidate,
      expectedRevision: 1,
      sentences: b1.sentences,
    ),
    LearningErrorCode.recoveryHold,
  );
  await denied(
    () async => h.learning.createVersion(
      materialVersionId: 'a' * 32,
      sentences: b1.sentences,
      textProvenance: const ContentProvenance(
        origin: ContentOrigin.manual,
        reference: 'test:manual',
      ),
    ),
    LearningErrorCode.recoveryHold,
  );
  await denied(
    () async => h.learning.openPlayback('a' * 32),
    LearningErrorCode.recoveryHold,
  );
  await denied(
    () async => h.learning.mediaArtifactFor(
      const PlaybackItem(
        ownerId: 'synthetic',
        itemId: 'a',
        itemRevision: 'b',
        kind: MediaKind.audio,
      ),
    ),
    LearningErrorCode.recoveryHold,
  );
  final binding = LearningBinding(
    ownerId: h.ownerId,
    materialId: 'a' * 32,
    materialVersionId: 'b' * 32,
    learningVersionId: 'c' * 32,
    mediaVersionId: 'd' * 32,
  );
  await denied(
    () => h.learning.saveProgress(
      session: LearningPlaybackSession(
        sessionId: 'e' * 32,
        binding: binding,
        item: PlaybackItem(
          ownerId: h.ownerId,
          itemId: 'c' * 32,
          itemRevision: 'd' * 32,
          kind: MediaKind.audio,
        ),
        progressRevision: 0,
      ),
      expectedRevision: 0,
      sentenceId: 'f' * 32,
      position: Duration.zero,
    ),
    LearningErrorCode.recoveryHold,
  );
}

// Scope fault interception to the Learning partition; Material IO remains native.
final class LearningStopIO extends IOOverrides {
  LearningStopIO(this.point);
  final String point;
  @override
  File createFile(String path) {
    final native = super.createFile(path);
    return path.replaceAll(Platform.pathSeparator, '/').contains('/learning/')
        ? LearningStopFile(native, point)
        : native;
  }
}

final class LearningStopFile extends StopFile {
  LearningStopFile(super.inner, super.point);
  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) =>
      inner.open(mode: mode);
}

Future<void> crash(b1.Harness h, String mode, String point) async {
  final vm = File(
    '${File(Platform.resolvedExecutable).parent.path}/dartvm.exe',
  );
  expectThat(await vm.exists(), 'real VM required');
  final process = await Process.start(vm.path, [
    Platform.script.toFilePath(),
    '--child',
    h.root.path,
    h.ownerId,
    mode,
    point,
  ], workingDirectory: Directory.current.path);
  final stderrDone = process.stderr.transform(utf8.decoder).join();
  final lines = StreamIterator(
    process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
  );
  var confirmed = false;
  try {
    expectThat(
      await lines.moveNext().timeout(const Duration(seconds: 12)) &&
          lines.current == 'READY ${process.pid}',
      'real VM self pid handshake',
    );
    confirmed = true;
    if (!await lines.moveNext().timeout(const Duration(seconds: 12))) {
      await stderrDone;
      throw StateError('checkpoint child exited before rename');
    }
    expectThat(
      lines.current == 'STOP ${process.pid} $point',
      'actual filesystem checkpoint: ${lines.current}',
    );
    await lines.cancel();
    expectThat(process.kill(), 'kill owned VM');
    await process.exitCode.timeout(const Duration(seconds: 5));
    await stderrDone;
  } finally {
    await lines.cancel();
    if (confirmed) {
      process.kill();
      await process.exitCode;
    }
  }
}

Future<void> main(List<String> args) async {
  if (args.isNotEmpty && args[0] == '--child') {
    stdout.writeln('READY $pid');
    await stdout.flush();
    await IOOverrides.runWithIOOverrides(() async {
      final h = b1.Harness(Directory(args[1]), ownerId: args[2]);
      await h.open();
      final command = jsonDecode(
        await File('${h.root.path}/command.json').readAsString(),
      ) as Map<String, dynamic>;
      if (args[3] == 'confirm') {
        await h.learning.confirmCandidate(
          candidateId: command['candidateId'] as String,
          expectedRevision: 1,
        );
      }
      if (args[3] == 'receive') {
        final source = await h.materials.readVersion(
          command['versionId'] as String,
        );
        final a = command['artifact'] as Map<String, dynamic>;
        final ref = ArtifactRef(
          ownerId: h.ownerId,
          artifactId: a['artifactId'] as String,
          byteLength: a['byteLength'] as int,
          sha256: a['sha256'] as String,
        );
        await receive(
          h,
          await media(h, source, 'crash-delivery', artifact: ref),
        );
      }
      throw StateError('checkpoint not reached');
    }, LearningStopIO(args[4]));
  }
  final c = Cases();
  await c.run(
    'v2 registered PCM receive translation edit and confirm keep text and audio declaration separate',
    () async => withHarness((h, source) async {
      final input = await media(h, source, 'valid');
      final r = await receive(h, input);
      expectThat(
        (await h.learning.listVersions()).isEmpty,
        'pending absent from editions',
      );
      final edit = await h.learning.reviseCandidate(
        candidateId: r.candidateId,
        expectedRevision: 1,
        sentences: [
          LearningSentenceInput(
            english: b1.sentences[0].english,
            translation: 'Changed translation only',
          ),
        ],
      );
      expectThat(
        edit.mediaReview!.binding == CandidateMediaBinding.matched,
        'translation preserves binding',
      );
      final v = await h.learning.confirmCandidate(
        candidateId: r.candidateId,
        expectedRevision: 2,
      );
      expectThat(
        v.state == LearningState.ready && v.media != null,
        'structure ready only',
      );
      expectThat(
        v.media!.provenance.external!.declaration.preparation ==
            b1.declaration.preparation,
        'media provenance full text context',
      );
      expectThat(
        v.media!.externalDetails!.declaration.preparation ==
            audioDeclaration.preparation,
        'audio declaration separate',
      );
      final again = await h.learning.confirmCandidate(
        candidateId: r.candidateId,
        expectedRevision: 2,
      );
      expectThat(
        again.binding.learningVersionId == v.binding.learningVersionId &&
            again.binding.mediaVersionId == v.binding.mediaVersionId,
        'same revision one edition',
      );
    }),
  );
  await c.run(
    'sticky English invalidation survives reverting and missing blob still permits audited partial confirm',
    () async => withHarness((h, source) async {
      final input = await media(h, source, 'sticky');
      final r = await receive(h, input);
      await h.learning.reviseCandidate(
        candidateId: r.candidateId,
        expectedRevision: 1,
        sentences: [
          const LearningSentenceInput(
            english: 'Different English.',
            translation: 'synthetic',
          ),
        ],
      );
      final edit = await h.learning.reviseCandidate(
        candidateId: r.candidateId,
        expectedRevision: 2,
        sentences: b1.sentences,
      );
      expectThat(
        edit.mediaReview!.binding == CandidateMediaBinding.invalidated &&
            edit.mediaReview!.invalidatedAtRevision == 2,
        'revert does not silently reattach',
      );
      await blob(h, input.media.artifact).delete();
      final v = await h.learning.confirmCandidate(
        candidateId: r.candidateId,
        expectedRevision: 3,
      );
      expectThat(
        v.state == LearningState.partial &&
            v.media == null &&
            v.issues.contains('media_english_changed') &&
            v.issues.contains('media_unavailable'),
        'invalidated missing blob partial',
      );
      expectThat(
        v.candidateMediaReview!.original.artifact.artifactId ==
            input.media.artifact.artifactId,
        'original audit preserved',
      );
      await h.close();
      await h.open();
      final restored = await h.learning.readVersion(
        v.binding.learningVersionId,
      );
      expectThat(
        restored.media == null &&
            restored.candidateMediaReview!.invalidatedAtRevision == 2,
        'sticky audit restart',
      );
    }),
  );
  await c.run(
    'matched confirmation rechecks actual bytes and never silently degrades bad media',
    () async => withHarness((h, source) async {
      final input = await media(h, source, 'missing');
      final r = await receive(h, input);
      await blob(h, input.media.artifact).delete();
      await denied(
        () async => h.learning.confirmCandidate(
          candidateId: r.candidateId,
          expectedRevision: 1,
        ),
        LearningErrorCode.mediaUnavailable,
      );
      expectThat(
        (await h.learning.listVersions()).isEmpty,
        'no false ready or partial edition',
      );
    }),
  );
  await c.run(
    'English changes whitespace count and ordering invalidate while retaining original media',
    () async => withHarness((h, source) async {
      const ss = [
        LearningSentenceInput(english: 'One.', translation: 'first'),
        LearningSentenceInput(english: 'Two.', translation: 'second'),
      ];
      const ts = [
        SentenceTiming(sentenceIndex: 0, startMs: 0, endMs: 400),
        SentenceTiming(sentenceIndex: 1, startMs: 500, endMs: 1000),
      ];
      final variants = <List<LearningSentenceInput>>[
        [ss[1], ss[0]],
        [ss[0]],
        [
          const LearningSentenceInput(english: 'One. ', translation: 'first'),
          ss[1],
        ],
      ];
      for (var i = 0; i < variants.length; i++) {
        final input = await media(
          h,
          source,
          'variant-$i',
          sentences: ss,
          timings: ts,
        );
        final r = await receive(h, input);
        final edit = await h.learning.reviseCandidate(
          candidateId: r.candidateId,
          expectedRevision: 1,
          sentences: variants[i],
        );
        expectThat(
          edit.mediaReview!.binding == CandidateMediaBinding.invalidated &&
              edit.mediaReview!.original.timings.length == 2,
          'original timings retained',
        );
      }
    }),
  );
  await c.run(
    'B1 and v2 share delivery namespace, equal bytes different refs replay original audit',
    () async => withHarness((h, source) async {
      await h.learning.receiveCandidate(
        sender: b1.sender,
        input: b1.input(source, deliveryId: 'text-first'),
      );
      await denied(
        () async => receive(h, await media(h, source, 'text-first')),
        LearningErrorCode.deliveryConflict,
      );
      final a = await media(h, source, 'media-first');
      final r = await receive(h, a);
      await denied(
        () async => h.learning.receiveCandidate(
          sender: b1.sender,
          input: b1.input(source, deliveryId: 'media-first'),
        ),
        LearningErrorCode.deliveryConflict,
      );
      final b = await media(h, source, 'media-first');
      expectThat(
        a.media.artifact.artifactId != b.media.artifact.artifactId,
        'independent random refs',
      );
      final replay = await receive(h, b);
      expectThat(
        replay.replayed && replay.candidateId == r.candidateId,
        'one semantic delivery',
      );
      expectThat(
        (await h.learning.readCandidate(r.candidateId))
                .mediaReview!
                .original
                .artifact
                .artifactId ==
            a.media.artifact.artifactId,
        'original ref unchanged',
      );
      final forged = ArtifactRef(
        ownerId: h.ownerId,
        artifactId: 'f' * 32,
        byteLength: b.media.artifact.byteLength,
        sha256: b.media.artifact.sha256,
      );
      await denied(
        () async =>
            receive(h, await media(h, source, 'media-first', artifact: forged)),
        LearningErrorCode.mediaUnavailable,
      );
    }),
  );
  await c.run(
    'source English strict PCM and timing bounds use actual bytes not sender claims',
    () async => withHarness((h, source) async {
      await denied(
        () async => receive(
          h,
          await media(h, source, 'wrong-english', englishHash: 'f' * 64),
        ),
        LearningErrorCode.bindingMismatch,
      );
      await denied(
        () async => receive(
          h,
          await media(
            h,
            source,
            'wrong-rate',
            bytes: pcmTone(const Duration(seconds: 1)),
          ),
        ),
        LearningErrorCode.invalidInput,
      );
      await denied(
        () async => receive(
          h,
          await media(
            h,
            source,
            'overlap',
            timings: [
              const SentenceTiming(sentenceIndex: 0, startMs: 0, endMs: 1001),
            ],
          ),
        ),
        LearningErrorCode.invalidInput,
      );
      await denied(
        () async => receive(
          h,
          await media(
            h,
            source,
            'index',
            timings: [
              const SentenceTiming(sentenceIndex: 1, startMs: 0, endMs: 1000),
            ],
          ),
        ),
        LearningErrorCode.invalidInput,
      );
      final over = pcmTone(
        const Duration(microseconds: 60000063),
        sampleRate: 16000,
      );
      await denied(
        () async =>
            receive(h, await media(h, source, 'one-sample-over', bytes: over)),
        LearningErrorCode.invalidInput,
      );
    }),
  );
  await c.run(
    'new media edition never overwrites old partial or carries existing progress',
    () async => withHarness((h, source) async {
      final old = await h.learning.receiveCandidate(
        sender: b1.sender,
        input: b1.input(source, deliveryId: 'old-partial'),
      );
      final partial = await h.learning.confirmCandidate(
        candidateId: old.candidateId,
        expectedRevision: 1,
      );
      final r = await receive(h, await media(h, source, 'new-media'));
      final ready = await h.learning.confirmCandidate(
        candidateId: r.candidateId,
        expectedRevision: 1,
      );
      expectThat(
        ready.binding.learningVersionId != partial.binding.learningVersionId &&
            (await h.learning.readVersion(partial.binding.learningVersionId))
                    .state ==
                LearningState.partial,
        'old partial unchanged',
      );
      expectThat(
        await h.learning.restoreProgress(ready.binding.learningVersionId) ==
            null,
        'no inherited checkpoint',
      );
      final session = await h.learning.openPlayback(
        ready.binding.learningVersionId,
      );
      await h.learning.saveProgress(
        session: session,
        expectedRevision: 0,
        sentenceId: ready.sentences[0].sentenceId,
        position: const Duration(milliseconds: 500),
      );
      expectThat(
        (await h.learning.restoreProgress(ready.binding.learningVersionId))!
                .resumeIntent ==
            PlaybackIntent.paused,
        'paused checkpoint only',
      );
    }),
  );
  await c.run(
    'lossy fallback holds every candidate action across restart while historical editions remain readable',
    () async => withHarness((h, source) async {
      final r = await receive(h, await media(h, source, 'held'));
      final v = await h.learning.confirmCandidate(
        candidateId: r.candidateId,
        expectedRevision: 1,
      );
      await h.close();
      await lf(h, 'learning.json').writeAsString('broken');
      await h.open();
      await assertHold(h, r.candidateId);
      await denied(
        () async => h.learning.receiveCandidate(
          sender: b1.sender,
          input: b1.input(source, deliveryId: 'blocked'),
        ),
        LearningErrorCode.recoveryHold,
      );
      await denied(
        () async => receive(h, await media(h, source, 'blocked-media')),
        LearningErrorCode.recoveryHold,
      );
      expectThat(
        (await h.learning.listVersions()).length <= 1,
        'history not fake new version',
      );
      await h.close();
      await h.open();
      await assertHold(h, r.candidateId);
      // The lost latest edition is not recreated from candidate/blob inference.
      expectThat(
        !(await payload(
          h,
        ))['versions'].containsKey(v.binding.learningVersionId),
        'lost authority not invented',
      );
    }),
  );
  await c.run(
    'actual old schema1 writer fixture migrates to3 preserving manual PCM checkpoint and archive bytes',
    () async => inSandbox((root) async {
      final fixture = await b1.legacyFixture(root);
      final h = b1.Harness(root, ownerId: fixture['ownerId'] as String);
      await h.open();
      try {
        final v = await h.learning.readVersion(
          fixture['syntheticVersionId'] as String,
        );
        expectThat(
          (await h.learning.restoreProgress(v.binding.learningVersionId))!
                  .position
                  .inMilliseconds ==
              fixture['checkpointMs'],
          'legacy progress exact',
        );
        expectThat(
          (jsonDecode(await lf(h, 'learning.json').readAsString())
                      as Map)['schema'] ==
                  3 &&
              (jsonDecode(await lf(h, 'learning.bak').readAsString())
                      as Map)['schema'] ==
                  3,
          'both3',
        );
        final files = fixture['files'] as Map;
        final k = files.keys.singleWhere(
          (k) =>
              k.toString().startsWith('learning/') &&
              k.toString().endsWith('/learning.json'),
        );
        expectThat(
          base64Encode(
                await lf(h, 'learning.schema1.snapshot').readAsBytes(),
              ) ==
              files[k],
          'original bytes archived',
        );
      } finally {
        await h.close();
      }
    }),
  );
  await c.run(
    'schema2 B1 records retain exact layout and hash without adding discriminator',
    () async => withHarness((h, source) async {
      final r = await h.learning.receiveCandidate(
        sender: b1.sender,
        input: b1.input(source),
      );
      await h.close();
      final p = await payload(h);
      final record = jsonEncode(p['candidates'][r.candidateId]);
      await writeSnapshot(lf(h, 'learning.json'), p, 2);
      await writeSnapshot(lf(h, 'learning.bak'), p, 2);
      await lf(h, 'store.marker').writeAsString('learning_core:2');
      await h.open();
      expectThat(
        jsonEncode((await payload(h))['candidates'][r.candidateId]) == record,
        'no layout/hash expansion',
      );
      expectThat(
        (await h.learning.readCandidate(r.candidateId)).mediaReview == null,
        'v1 default missing discriminator',
      );
    }),
  );
  await c.run(
    'rehashed forged media provenance invalidation and confirm mapping snapshots never become ready',
    () async => inSandbox((root) async {
      for (final kind in [
        'audio-as-text',
        'wrong-artifact',
        'wrong-english',
        'invalidation',
        'confirmed-link',
      ]) {
        final h = b1.Harness(Directory('${root.path}/$kind'));
        await h.open();
        try {
          final source = await h.source();
          final r = await receive(h, await media(h, source, 'forged'));
          await h.learning.confirmCandidate(
            candidateId: r.candidateId,
            expectedRevision: 1,
          );
          await h.close();
          final p = await payload(h);
          final cand = p['candidates'][r.candidateId] as Map;
          final v = (p['versions'] as Map).values.single as Map;
          if (kind == 'audio-as-text')
            v['media']['provenance']['external']['declaration']['preparation'] =
                'wrong audio declaration';
          if (kind == 'wrong-artifact')
            v['media']['artifact']['artifactId'] = 'f' * 32;
          if (kind == 'wrong-english')
            cand['originalMedia']['englishSha256'] = 'f' * 64;
          if (kind == 'invalidation')
            cand['mediaInvalidation'] = {
              'firstRevision': 1,
              'englishSha256': 'f' * 64,
            };
          if (kind == 'confirmed-link')
            cand['confirmedLearningVersionId'] = 'f' * 32;
          await writeSnapshot(lf(h, 'learning.json'), p, 3);
          await h.open();
          await assertHold(h, r.candidateId);
        } finally {
          await h.close();
        }
      }
    }),
  );
  await c.run(
    'hold persistence failure cannot overwrite damaged primary',
    () async => withHarness((h, source) async {
      await receive(h, await media(h, source, 'hold-write'));
      await h.close();
      await lf(h, 'learning.json').writeAsString('broken');
      await Directory(lf(h, 'learning.recovery.hold.next').path).create();
      await denied(h.open, LearningErrorCode.corruptStore);
      expectThat(
        await lf(h, 'learning.json').readAsString() == 'broken',
        'preserve pre-restore evidence',
      );
    }),
  );
  await c.run(
    'fixed cross-language English and complete v2 payload vectors exclude random artifact IDs',
    () => inSandbox((root) async {
      final fixture = await b1.legacyFixture(root);
      final h = b1.Harness(root, ownerId: fixture['ownerId'] as String);
      await h.open();
      try {
        final source = await h.materials.readVersion(
          fixture['materialVersionId'] as String,
        );
        final silence = pcmTone(const Duration(seconds: 1), sampleRate: 16000)
          ..fillRange(44, 32044, 0);
        expectThat(
          hash(silence) == '643f8a8dc8bd9c19225afffad2becfec5426180b3749cb208abdf1a6c8354efc',
          'exact synthetic silence vector',
        );
        const ss = [
          LearningSentenceInput(
            english: 'Hi.',
            translation: 'Unicode \u4e2d\u6587\ud83d\ude42',
          ),
          LearningSentenceInput(
            english: "Let's talk.",
            translation: 'quote " \\ slash /',
          ),
        ];
        // Escapes above are source notation; the semantic Unicode text is fixed.
        final actual = [
          LearningSentenceInput(
            english: ss[0].english,
            translation:
                'Unicode ' + String.fromCharCodes([0x4e2d, 0x6587, 0x1f642]),
          ),
          ss[1],
        ];
        const timings = [
          SentenceTiming(sentenceIndex: 0, startMs: 0, endMs: 400),
          SentenceTiming(sentenceIndex: 1, startMs: 500, endMs: 1000),
        ];
        expectThat(
          english(actual) == '84787baf8e5e4ccf6caab6dfa49c6a781746b49c74d49afb563a40ba1b8f2e47',
          'exact English vector',
        );
        final input = await media(
          h,
          source,
          'fixed-v2-vector',
          sentences: actual,
          bytes: silence,
          timings: timings,
        );
        final receipt = await receive(h, input);
        expectThat(
          receipt.payloadSha256 == 'a3fde264f49c96a8952a4af31fee03f17193b2b09cd0a4bff8fbb666124bf135',
          'independently computed Python compact UTF8 payload vector',
        );
      } finally {
        await h.close();
      }
    }),
  );
  await c.run(
    'schema2 exactly-full candidate budget migrates without discriminator expansion or eviction',
    () => withHarness((h, source) async {
      final r = await h.learning.receiveCandidate(
        sender: b1.sender,
        input: b1.input(source),
      );
      await h.close();
      final p = await payload(h);
      final record = p['candidates'][r.candidateId] as Map<String, dynamic>;
      final original = record['materialTitle'] as String;
      final amount =
          LearningCandidateLimits.maxStoredCandidateBytes -
          utf8.encode(jsonEncode(record)).length +
          utf8.encode(original).length;
      record['materialTitle'] = 'x' * amount;
      expectThat(
        utf8.encode(jsonEncode(record)).length ==
            LearningCandidateLimits.maxStoredCandidateBytes,
        'exact legacy budget boundary',
      );
      await writeSnapshot(lf(h, 'learning.json'), p, 2);
      await writeSnapshot(lf(h, 'learning.bak'), p, 2);
      await lf(h, 'store.marker').writeAsString('learning_core:2');
      await h.open();
      final after = (await payload(h))['candidates'][r.candidateId] as Map;
      expectThat(
        after.length == record.length &&
            !after.containsKey('inputVersion') &&
            utf8.encode(jsonEncode(after)).length ==
                LearningCandidateLimits.maxStoredCandidateBytes,
        'no growth, no budget exception, no eviction',
      );
    }),
  );
  await c.run(
    'Material recovery hold blocks both matched and invalidated confirm before Learning persistence',
    () => withHarness((h, source) async {
      final input = await media(h, source, 'material-held');
      final r = await receive(h, input);
      await h.learning.reviseCandidate(
        candidateId: r.candidateId,
        expectedRevision: 1,
        sentences: [
          const LearningSentenceInput(
            english: 'Changed.',
            translation: 'synthetic',
          ),
        ],
      );
      await h.close();
      final mp = File(
        '${h.root.path}/materials/${hash(utf8.encode('owner:${h.ownerId}'))}/manifest.json',
      );
      await mp.writeAsString('broken');
      await h.open();
      expectThat(
        h.materials.recoveryReport.issues.any(
          (i) => i.kind == RecoveryIssueKind.registrationHold,
        ),
        'actual Material persistent hold',
      );
      await denied(
        () => h.learning.confirmCandidate(
          candidateId: r.candidateId,
          expectedRevision: 2,
        ),
        LearningErrorCode.recoveryHold,
      );
      await denied(() => receive(h, input), LearningErrorCode.recoveryHold);
      expectThat(
        (await h.learning.listVersions()).isEmpty,
        'no cross-store rollback or fake commit',
      );
    }),
  );
  for (final point in ['learning.bak', 'learning.json', 'store.marker']) {
    await c.run(
      'actual VM migration crash at $point preserves trusted original and resumes schema3',
      () async => inSandbox((root) async {
        final fixture = await b1.legacyFixture(root);
        final h = b1.Harness(root, ownerId: fixture['ownerId'] as String);
        await crash(h, 'migrate', point);
        await h.open();
        try {
          expectThat(
            (await h.learning.listCandidates()).isEmpty &&
                (await h.learning.listVersions()).length == 2,
            'no invented records after migration',
          );
        } finally {
          await h.close();
        }
      }),
    );
  }
  for (final mode in ['receive', 'confirm']) {
    await c.run(
      'actual VM $mode commit ACK gap retains single authoritative mapping',
      () async => withHarness((h, source) async {
        final input = await media(h, source, 'crash-delivery');
        String? candidate;
        if (mode == 'confirm')
          candidate = (await receive(h, input)).candidateId;
        await File('${h.root.path}/command.json').writeAsString(
          jsonEncode({
            'versionId': source.versionId,
            'candidateId': candidate,
            'artifact': {
              'artifactId': input.media.artifact.artifactId,
              'byteLength': input.media.artifact.byteLength,
              'sha256': input.media.artifact.sha256,
            },
          }),
        );
        await h.close();
        await crash(h, mode, 'learning.json');
        await h.open();
        final r = await receive(h, input);
        expectThat(r.replayed, 'persisted delivery');
        if (mode == 'confirm') {
          final v = await h.learning.confirmCandidate(
            candidateId: r.candidateId,
            expectedRevision: 1,
          );
          expectThat(
            (await h.learning.listVersions()).length == 1 &&
                (await h.learning.readCandidate(r.candidateId))
                        .confirmedLearningVersionId ==
                    v.binding.learningVersionId,
            'one confirmed version',
          );
        } else {
          expectThat(
            (await h.learning.listCandidates()).length == 1,
            'one candidate',
          );
        }
      }),
    );
  }
  c.finish();
}
