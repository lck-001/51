import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:material_core/material_core.dart';

import '../lib/learning_core.dart';
import 'learning_store_regression.dart' as fixture;
import 'support.dart';

const sender = CandidateSender(
  integrationId: 'stable-connector-v1',
  transport: CandidateTransport.controlledTest,
);
const declaration = SourceDeclaration(
  preparation: '原创外部文本结构样本，非供应商执行',
  provider: 'self-declared',
  model: 'unknown',
  notes: '声明未经独立核实。',
);

LearningCandidateInput packet(
  MaterialVersion source,
  String delivery, {
  List<LearningSentenceInput>? sentences,
}) => LearningCandidateInput(
  materialId: source.materialId,
  materialVersionId: source.versionId,
  sourceTextSha256: sha256.convert(utf8.encode(source.text)).toString(),
  deliveryId: delivery,
  sentences: sentences ?? fixture.sentences,
  declaration: declaration,
);

Future<void> main() async {
  final cases = Cases();
  await cases.run(
    'Candidate confirmation keeps original declaration and exactly one external partial edition',
    () => fixture.using((lab) async {
      final m = await lab.material();
      final source = await lab.source(m);
      final l = await lab.learning(m);
      final c = l as LearningCandidateStore;
      final r = await c.receiveCandidate(
        sender: sender,
        input: packet(source, 'sample-1'),
      );
      expectThat(
        (await l.listVersions()).isEmpty,
        'receipt is not a learning version',
      );
      final edit = await c.reviseCandidate(
        candidateId: r.candidateId,
        expectedRevision: 1,
        sentences: [
          const LearningSentenceInput(
            english: 'I can explain the plan.',
            translation: '我能说明这个计划。',
          ),
        ],
      );
      expectThat(
        edit.revision == 2 &&
            edit.userEdited &&
            edit.originalSentences.first.english ==
                fixture.sentences.first.english,
        'original input is immutable while latest revision changes',
      );
      final v = await c.confirmCandidate(
        candidateId: r.candidateId,
        expectedRevision: 2,
      );
      final again = await c.confirmCandidate(
        candidateId: r.candidateId,
        expectedRevision: 2,
      );
      expectThat(
        v.state == LearningState.partial &&
            v.media == null &&
            v.textProvenance.origin == ContentOrigin.external &&
            v.textProvenance.external!.declaration.model == 'unknown' &&
            v.textProvenance.external!.userEdited &&
            v.binding.learningVersionId == again.binding.learningVersionId &&
            (await l.listVersions()).length == 1,
        'one confirmed text-only external version, no fabricated audio',
      );
      await fixture.expectError(
        () =>
            c.rejectCandidate(candidateId: r.candidateId, expectedRevision: 2),
        {LearningErrorCode.invalidState},
      );
      await fixture.expectError(
        () => c.reviseCandidate(
          candidateId: r.candidateId,
          expectedRevision: 2,
          sentences: fixture.sentences,
        ),
        {LearningErrorCode.invalidState},
      );
      await fixture.expectError(
        () => l.createVersion(
          materialVersionId: source.versionId,
          sentences: fixture.sentences,
          textProvenance: v.textProvenance,
        ),
        {LearningErrorCode.invalidInput},
      );
      await fixture.expectError(
        () => l.createVersion(
          materialVersionId: source.versionId,
          sentences: fixture.sentences,
          textProvenance: ContentProvenance(
            origin: ContentOrigin.manual,
            reference: 'manual:invalid-mixed',
            external: v.textProvenance.external,
          ),
        ),
        {LearningErrorCode.invalidInput},
      );
      await lab.closeLearning(l);
      final reopened = await lab.learning(m);
      final same = await (reopened as LearningCandidateStore).confirmCandidate(
        candidateId: r.candidateId,
        expectedRevision: 2,
      );
      expectThat(
        same.binding.learningVersionId == v.binding.learningVersionId &&
            (await reopened.listVersions()).length == 1,
        'confirmation link and content survive reopen together',
      );
    }),
  );

  await cases.run(
    'Capability rotation keeps stable delivery idempotency and original transport statement',
    () => fixture.using((lab) async {
      final m = await lab.material();
      final source = await lab.source(m);
      final c = (await lab.learning(m)) as LearningCandidateStore;
      final p = packet(source, 'same-delivery');
      final a = await c.receiveCandidate(
        sender: CandidateSender(
          integrationId: sender.integrationId,
          transport: CandidateTransport.localCapability,
          transportPayloadSha256: 'a' * 64,
        ),
        input: p,
      );
      final b = await c.receiveCandidate(
        sender: CandidateSender(
          integrationId: sender.integrationId,
          transport: CandidateTransport.localCapability,
          transportPayloadSha256: 'b' * 64,
        ),
        input: p,
      );
      expectThat(
        a.candidateId == b.candidateId &&
            b.replayed &&
            (await c.readCandidate(a.candidateId))
                    .submission
                    .transportPayloadSha256 ==
                'a' * 64,
        'new raw request/capability does not replace the first immutable receipt',
      );
      final other = await c.receiveCandidate(
        sender: const CandidateSender(
          integrationId: 'another-stable-connector',
          transport: CandidateTransport.controlledTest,
        ),
        input: p,
      );
      expectThat(
        other.candidateId != a.candidateId,
        'different logical integration has its own delivery namespace',
      );
    }),
  );

  await cases.run(
    'UTF8 limits and malformed scalars reject rather than normalize or silently truncate',
    () => fixture.using((lab) async {
      final m = await lab.material();
      final source = await lab.source(m);
      final c = (await lab.learning(m)) as LearningCandidateStore;
      await fixture.expectError(
        () => c.receiveCandidate(
          sender: sender,
          input: packet(
            source,
            'bad-scalar',
            sentences: [
              LearningSentenceInput(
                english: String.fromCharCode(0xd800),
                translation: '结构测试',
              ),
            ],
          ),
        ),
        {LearningErrorCode.invalidInput},
      );
      await fixture.expectError(
        () => c.receiveCandidate(
          sender: sender,
          input: packet(
            source,
            'big-utf8',
            sentences: [
              LearningSentenceInput(english: '测' * 40000, translation: '结构测试'),
            ],
          ),
        ),
        {LearningErrorCode.candidateLimitExceeded},
      );
      await fixture.expectError(
        () => c.receiveCandidate(
          sender: sender,
          input: packet(
            source,
            'big-ascii',
            sentences: [
              LearningSentenceInput(english: 'a' * 102401, translation: '结构测试'),
            ],
          ),
        ),
        {LearningErrorCode.candidateLimitExceeded},
      );
      expectThat(
        (await c.listCandidates()).isEmpty,
        'invalid payloads leave no receipt/candidate',
      );
    }),
  );

  await cases.run(
    'Pending quota rejects excess then permits one new candidate after rejection without deleting history',
    () => fixture.using((lab) async {
      final m = await lab.material();
      final source = await lab.source(m);
      final c = (await lab.learning(m)) as LearningCandidateStore;
      String? first;
      for (var i = 0; i < LearningCandidateLimits.maxPendingCandidates; i++) {
        final r = await c.receiveCandidate(
          sender: sender,
          input: packet(source, 'quota-$i'),
        );
        first ??= r.candidateId;
      }
      await fixture.expectError(
        () => c.receiveCandidate(
          sender: sender,
          input: packet(source, 'over-quota'),
        ),
        {LearningErrorCode.candidateLimitExceeded},
      );
      await c.rejectCandidate(candidateId: first!, expectedRevision: 1);
      await c.receiveCandidate(
        sender: sender,
        input: packet(source, 'after-reject'),
      );
      final all = await c.listCandidates();
      expectThat(
        all.length == 33 &&
            all
                    .where(
                      (v) => v.state == LearningCandidateState.pendingReview,
                    )
                    .length ==
                32,
        'rejection frees pending slot but preserves previous candidate history',
      );
    }),
  );
  cases.finish();
}
