import 'dart:io';
import 'dart:typed_data';

import 'package:learning_core/learning_core.dart';
import 'package:material_core/material_core.dart';

import 'candidate_independent.dart' as b1;
import 'media_candidate_regression.dart' as media;
import 'support.dart';
import 'wav_fixture.dart';

// A real FileMaterialStore remains authority; this observes/denies resource IO,
// never substitutes an in-memory source or artifact fact.
final class ReadGateMaterial implements MaterialStore {
  ReadGateMaterial(this.inner);
  final MaterialStore inner;
  var blocked = false, resourceReads = 0;
  RecoveryReport? reportOverride;
  @override
  String get trustedOwnerId => inner.trustedOwnerId;
  @override
  RecoveryReport get recoveryReport => reportOverride ?? inner.recoveryReport;
  @override
  Future<MaterialVersion> readVersion(String id) {
    resourceReads++;
    if (blocked) throw StateError('lookup attempted source IO');
    return inner.readVersion(id);
  }

  @override
  Future<Uint8List> readArtifact(ArtifactRef ref) {
    resourceReads++;
    if (blocked) throw StateError('lookup attempted blob IO');
    return inner.readArtifact(ref);
  }

  @override
  Future<MaterialDraft> createDraft({
    required String title,
    String text = '',
    Iterable<ArtifactRef> artifacts = const [],
  }) => inner.createDraft(title: title, text: text, artifacts: artifacts);
  @override
  Future<MaterialDraft> readDraft(String id) => inner.readDraft(id);
  @override
  Future<List<MaterialDraft>> listDrafts() => inner.listDrafts();
  @override
  Future<MaterialDraft> updateDraft({
    required String materialId,
    required int expectedRevision,
    String? title,
    String? text,
    Iterable<ArtifactRef>? artifacts,
  }) => inner.updateDraft(
    materialId: materialId,
    expectedRevision: expectedRevision,
    title: title,
    text: text,
    artifacts: artifacts,
  );
  @override
  Future<MaterialVersion> confirmVersion({
    required String materialId,
    required int expectedRevision,
  }) => inner.confirmVersion(
    materialId: materialId,
    expectedRevision: expectedRevision,
  );
  @override
  Future<List<MaterialVersion>> listVersions(String id) =>
      inner.listVersions(id);
  @override
  Future<ArtifactRef> importArtifact(Uint8List bytes) =>
      inner.importArtifact(bytes);
  @override
  Future<void> close() => inner.close();
}

Future<CandidateDeliveryReceipt?> lookup(
  b1.Harness h,
  String delivery,
  String hash, {
  int version = 2,
  CandidateSender sender = b1.sender,
}) => h.learning.findDeliveryReceipt(
  sender: sender,
  deliveryId: delivery,
  inputVersion: version,
  expectedPayloadSha256: hash,
);

Future<void> main() async {
  final c = Cases();
  await c.run('pure public inspection returns actual immutable facts and exact sample bounds', () async {
    final bytes = pcmTone(const Duration(seconds: 1), sampleRate: 16000);
    final result = inspectExternalCandidateMedia(
      bytes: bytes,
      timings: [
        const SentenceTiming(sentenceIndex: 0, startMs: 0, endMs: 1000),
      ],
      sentenceCount: 1,
    );
    expectThat(
      result.actualSha256 == media.hash(bytes) &&
          result.byteLength == 32044 &&
          result.durationMs == 1000,
      'actual complete bytes facts',
    );
    bytes[44] ^= 1;
    expectThat(
      result.actualSha256 != media.hash(bytes),
      'inspection retains no mutable bytes authority',
    );
    final fractional = pcmTone(
      const Duration(microseconds: 1500),
      sampleRate: 16000,
    );
    expectThat(
      inspectExternalCandidateMedia(
            bytes: fractional,
            timings: [
              const SentenceTiming(sentenceIndex: 0, startMs: 0, endMs: 1),
            ],
            sentenceCount: 1,
          ).durationMs ==
          1,
      'floor is presentation only',
    );
    await media.denied(
      () => inspectExternalCandidateMedia(
        bytes: fractional,
        timings: [const SentenceTiming(sentenceIndex: 0, startMs: 0, endMs: 2)],
        sentenceCount: 1,
      ),
      LearningErrorCode.invalidInput,
    );
    final exact = pcmTone(const Duration(seconds: 60), sampleRate: 16000);
    expectThat(
      inspectExternalCandidateMedia(
            bytes: exact,
            timings: [
              const SentenceTiming(sentenceIndex: 0, startMs: 0, endMs: 60000),
            ],
            sentenceCount: 1,
          ).byteLength ==
          1920044,
      'exact60 seconds',
    );
    await media.denied(
      () => inspectExternalCandidateMedia(
        bytes: pcmTone(
          const Duration(microseconds: 60000063),
          sampleRate: 16000,
        ),
        timings: [
          const SentenceTiming(sentenceIndex: 0, startMs: 0, endMs: 60000),
        ],
        sentenceCount: 1,
      ),
      LearningErrorCode.invalidInput,
    );
  });
  await c.run('preflight rejects bytes count list and ordered timing limits before parsing/hash', () async {
    final bytes = pcmTone(const Duration(seconds: 1), sampleRate: 16000);
    const t = SentenceTiming(sentenceIndex: 0, startMs: 0, endMs: 1000);
    await media.denied(
      () => inspectExternalCandidateMedia(
        bytes: Uint8List(2 * 1024 * 1024 + 1),
        timings: [],
        sentenceCount: 1,
      ),
      LearningErrorCode.candidateLimitExceeded,
    );
    await media.denied(
      () => inspectExternalCandidateMedia(
        bytes: Uint8List(0),
        timings: List.filled(129, t),
        sentenceCount: 129,
      ),
      LearningErrorCode.candidateLimitExceeded,
    );
    await media.denied(
      () => inspectExternalCandidateMedia(
        bytes: bytes,
        timings: [t],
        sentenceCount: 0,
      ),
      LearningErrorCode.invalidInput,
    );
    await media.denied(
      () => inspectExternalCandidateMedia(
        bytes: bytes,
        timings: [t],
        sentenceCount: 2,
      ),
      LearningErrorCode.invalidInput,
    );
    for (final ts in [
      [const SentenceTiming(sentenceIndex: 1, startMs: 0, endMs: 1000)],
      [const SentenceTiming(sentenceIndex: 0, startMs: -1, endMs: 10)],
      [
        const SentenceTiming(sentenceIndex: 0, startMs: 0, endMs: 700),
        const SentenceTiming(sentenceIndex: 1, startMs: 600, endMs: 900),
      ],
      [const SentenceTiming(sentenceIndex: 0, startMs: 0, endMs: 0)],
    ]) {
      await media.denied(
        () => inspectExternalCandidateMedia(
          bytes: bytes,
          timings: ts,
          sentenceCount: ts.length,
        ),
        LearningErrorCode.invalidInput,
      );
    }
    await media.denied(
      () => inspectExternalCandidateMedia(
        bytes: pcmTone(const Duration(seconds: 1)),
        timings: [t],
        sentenceCount: 1,
      ),
      LearningErrorCode.invalidInput,
    );
  });
  await c.run(
    'lookup directly returns neutral receipt for three terminal states and B1 without resource or file IO',
    () => media.withHarness((h, source) async {
      final receipts = <String, CandidateDeliveryReceipt>{};
      final inputs = <String, LearningMediaCandidateInput>{};
      for (final state in ['pending', 'confirmed', 'rejected']) {
        final input = await media.media(h, source, state);
        inputs[state] = input;
        final r = await media.receive(h, input);
        receipts[state] = r;
        if (state == 'confirmed')
          await h.learning.confirmCandidate(
            candidateId: r.candidateId,
            expectedRevision: 1,
          );
        if (state == 'rejected')
          await h.learning.rejectCandidate(
            candidateId: r.candidateId,
            expectedRevision: 1,
          );
      }
      final text = await h.learning.receiveCandidate(
        sender: b1.sender,
        input: b1.input(source, deliveryId: 'b1'),
      );
      final before = await media.lf(h, 'learning.json').readAsString();
      await h.learning.close();
      final gate = ReadGateMaterial(h.materials);
      h.learning = await FileLearningStore.open(
        root: Directory('${h.root.path}/learning'),
        materials: gate,
      );
      gate.blocked = true;
      gate.resourceReads = 0;
      for (final input in inputs.values) {
        await media.blob(h, input.media.artifact).delete();
      }
      await IOOverrides.runZoned(
        () async {
          for (final entry in receipts.entries) {
            final result = await lookup(
              h,
              entry.key,
              entry.value.payloadSha256,
            );
            expectThat(
              result!.candidateId == entry.value.candidateId &&
                  result.payloadSha256 == entry.value.payloadSha256 &&
                  result.replayed,
              'same neutral receipt across state',
            );
          }
          expectThat(
            (await lookup(
                  h,
                  'b1',
                  text.payloadSha256,
                  version: 1,
                ))!.candidateId ==
                text.candidateId,
            'missing inputVersion means1',
          );
          expectThat(
            await lookup(h, 'absent', 'a' * 64) == null,
            'only absent key returns null',
          );
          await media.denied(
            () => lookup(h, 'b1', text.payloadSha256),
            LearningErrorCode.deliveryConflict,
          );
          await media.denied(
            () => lookup(
              h,
              'pending',
              receipts['pending']!.payloadSha256,
              version: 1,
            ),
            LearningErrorCode.deliveryConflict,
          );
          await media.denied(
            () => lookup(h, 'pending', 'f' * 64),
            LearningErrorCode.deliveryConflict,
          );
        },
        createFile: (_) =>
            throw StateError('lookup attempted any filesystem access'),
      );
      expectThat(
        gate.resourceReads == 0,
        'no Material source/blob reads, including absence and conflicts',
      );
      expectThat(
        await media.lf(h, 'learning.json').readAsString() == before,
        'no sequence snapshot or audit write',
      );
      gate.blocked = false;
      await media.denied(
        () => media.receive(h, inputs['pending']!),
        LearningErrorCode.mediaUnavailable,
      );
    }),
  );
  await c.run(
    'lookup validates trusted sender delivery version and digest without broadening error codes',
    () => media.withHarness((h, source) async {
      await media.denied(
        () => lookup(h, 'valid', 'a' * 63),
        LearningErrorCode.invalidInput,
      );
      await media.denied(
        () => lookup(h, 'valid', 'a' * 64, version: 3),
        LearningErrorCode.invalidInput,
      );
      await media.denied(
        () => lookup(
          h,
          'valid',
          'a' * 64,
          sender: const CandidateSender(
            integrationId: '../outside',
            transport: CandidateTransport.controlledTest,
          ),
        ),
        LearningErrorCode.invalidInput,
      );
      await media.denied(
        () => lookup(h, 'bad\ndelivery', 'a' * 64),
        LearningErrorCode.invalidInput,
      );
      await media.denied(
        () => lookup(h, 'x' * 257, 'a' * 64),
        LearningErrorCode.candidateLimitExceeded,
      );
      expectThat(
        await lookup(
              h,
              'valid',
              'a' * 64,
              sender: const CandidateSender(
                integrationId: 'other-integration',
                transport: CandidateTransport.controlledTest,
              ),
            ) ==
            null,
        'trusted integration partition',
      );
    }),
  );
  await c.run(
    'Material hold and closed gate precede both absent and existing lookup early returns',
    () => media.withHarness((h, source) async {
      final r = await media.receive(h, await media.media(h, source, 'known'));
      await h.learning.close();
      final gate = ReadGateMaterial(h.materials);
      h.learning = await FileLearningStore.open(
        root: Directory('${h.root.path}/learning'),
        materials: gate,
      );
      gate.reportOverride = RecoveryReport(RecoveryStatus.degraded, [
        const RecoveryIssue(
          RecoveryIssueKind.registrationHold,
          holdReason: RecoveryHoldReason.authorityUnavailable,
        ),
      ]);
      for (final delivery in ['known', 'unknown']) {
        await media.denied(
          () => lookup(h, delivery, r.payloadSha256),
          LearningErrorCode.recoveryHold,
        );
      }
      await h.learning.close();
      await media.denied(
        () => lookup(h, 'known', r.payloadSha256),
        LearningErrorCode.closed,
      );
      await media.denied(
        () => lookup(h, 'unknown', r.payloadSha256),
        LearningErrorCode.closed,
      );
      h.learning = await FileLearningStore.open(
        root: Directory('${h.root.path}/learning'),
        materials: h.materials,
      );
    }),
  );
  await c.run(
    'actual Learning recovery hold and uncertain write never look absent or delivered',
    () => media.withHarness((h, source) async {
      final r = await media.receive(h, await media.media(h, source, 'known'));
      await Directory(media.lf(h, 'learning.next').path).create();
      await media.denied(
        () => h.learning.receiveCandidate(
          sender: b1.sender,
          input: b1.input(source, deliveryId: 'fail-write'),
        ),
        LearningErrorCode.writeFailed,
      );
      for (final delivery in ['known', 'unknown']) {
        await media.denied(
          () => lookup(h, delivery, r.payloadSha256),
          LearningErrorCode.recoveryHold,
        );
      }
      await h.close();
      await Directory(media.lf(h, 'learning.next').path).delete();
      await h.open();
      for (final delivery in ['known', 'unknown']) {
        await media.denied(
          () => lookup(h, delivery, r.payloadSha256),
          LearningErrorCode.recoveryHold,
        );
      }
    }),
  );
  c.finish();
}
