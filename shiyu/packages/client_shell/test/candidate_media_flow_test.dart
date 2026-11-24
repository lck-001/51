// Real Core + file Stores. Synthetic PCM is never played or recorded.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:learning_core/learning_core.dart';
import 'package:material_ui/material_ui.dart';

import '../lib/src/candidate_review_sheet.dart';
import '../../learning_core/test/wav_fixture.dart';
import 'client_shell_test.dart' as real;
import 'candidate_review_flow_test.dart' as fixture;

Future<String> media(real.Harness h, {bool pair = false}) async {
  final source = await fixture.source(h);
  final artifact = await h.materials.importArtifact(
    pcmTone(const Duration(seconds: 1), sampleRate: 16000),
  );
  final result = await (h.learning as LearningMediaCandidateStore)
      .receiveMediaCandidate(
        sender: const CandidateSender(
          integrationId: 'ui-media',
          transport: CandidateTransport.controlledTest,
        ),
        input: LearningMediaCandidateInput(
          text: LearningCandidateInput(
            materialId: source.materialId,
            materialVersionId: source.versionId,
            sourceTextSha256: fixture.originalSha,
            deliveryId: 'ui-media-delivery',
            sentences: [
              LearningSentenceInput(
                english: 'Here is the supplied plan.',
                translation: '这是送入的计划。',
              ),
              if (pair)
                const LearningSentenceInput(
                  english: 'A second supplied sentence.',
                  translation: '合成第二句。',
                ),
            ],
            declaration: const SourceDeclaration(
              preparation: 'Synthetic text statement',
              provider: 'Text provider',
            ),
          ),
          media: LearningCandidateMediaInput(
            artifact: artifact,
            englishSha256: pair
                ? 'b9685347ce0063754d8b7c754a77cab09a5a711f66fd81c637105babbedaadc5'
                : '3504f893536c42a88faab8f7d84b2262263744089e0672bebe8836cc9c7703d8',
            declaration: const SourceDeclaration(
              preparation: 'Synthetic PCM, not narration',
              provider: 'Audio provider',
            ),
            timingDeclaration: 'Synthetic timing, not professional alignment',
            timings: pair
                ? const [
                    SentenceTiming(sentenceIndex: 0, startMs: 0, endMs: 500),
                    SentenceTiming(sentenceIndex: 1, startMs: 500, endMs: 1000),
                  ]
                : const [
                    SentenceTiming(sentenceIndex: 0, startMs: 0, endMs: 1000),
                  ],
          ),
        ),
      );
  return result.candidateId;
}

Future<void> mount(
  WidgetTester tester,
  real.Harness h,
  String id, {
  Size size = const Size(375, 667),
  double scale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale)),
        child: Scaffold(
          body: CandidateReviewSheet(
            candidates: h.learning as LearningCandidateStore,
            materials: h.materials,
            candidateId: id,
            isCurrentScope: () => true,
          ),
        ),
      ),
    ),
  );
  await real.drain(tester);
}

void main() {
  for (final reorder in [true, false]) {
    testWidgets(
      'real saved sentence ${reorder ? 'order' : 'count'} change remains sticky after restoration',
      (tester) async {
        final h = (await tester.runAsync(real.Harness.create))!;
        final id = (await tester.runAsync(() => media(h, pair: true)))!;
        try {
          await tester.runAsync(() async {
            final store = h.learning as LearningCandidateStore;
            final original = await store.readCandidate(id);
            final sentences = original.sentences
                .map(
                  (s) => LearningSentenceInput(
                    english: s.english,
                    translation: s.translation,
                  ),
                )
                .toList();
            final changed = await store.reviseCandidate(
              candidateId: id,
              expectedRevision: original.revision,
              sentences: reorder
                  ? sentences.reversed.toList()
                  : sentences.take(1).toList(),
            );
            expect(
              changed.mediaReview!.binding,
              CandidateMediaBinding.invalidated,
            );
            await store.reviseCandidate(
              candidateId: id,
              expectedRevision: changed.revision,
              sentences: sentences,
            );
            await h.reopen();
          });
          await mount(tester, h, id);
          expect(find.textContaining('改回原文也不会恢复'), findsOneWidget);
          final current = (await tester.runAsync(
            () => (h.learning as LearningCandidateStore).readCandidate(id),
          ))!;
          expect(current.mediaReview!.invalidatedAtRevision, 2);
          expect(
            current.mediaReview!.binding,
            CandidateMediaBinding.invalidated,
          );
        } finally {
          await real.unmountAndClose(tester, h);
        }
      },
    );
  }

  testWidgets(
    'matched media confirms once without selecting or playing learning',
    (tester) async {
      final h = (await tester.runAsync(real.Harness.create))!;
      final id = (await tester.runAsync(() => media(h)))!;
      var selections = 0;
      try {
        await fixture.mount(
          tester,
          h,
          open: (_) async {
            selections++;
          },
        );
        await tester.ensureVisible(find.byKey(Key('candidate-review-$id')));
        await tester.tap(find.byKey(Key('candidate-review-$id')));
        await real.drain(tester);
        final confirm = find.byKey(const Key('candidate-confirm'));
        await tester.ensureVisible(confirm);
        await tester.tap(confirm);
        await real.drain(tester);
        expect(selections, 0);
        final versions = (await tester.runAsync(h.learning.listVersions))!;
        expect(versions, hasLength(1));
        expect(versions.single.media, isNotNull);
        expect(
          versions.single.candidateMediaReview!.binding,
          CandidateMediaBinding.matched,
        );
        final candidate = (await tester.runAsync(
          () => (h.learning as LearningCandidateStore).readCandidate(id),
        ))!;
        await tester.runAsync(
          () => (h.learning as LearningCandidateStore).confirmCandidate(
            candidateId: id,
            expectedRevision: candidate.revision,
          ),
        );
        expect((await tester.runAsync(h.learning.listVersions))!, hasLength(1));
        expect(selections, 0);
      } finally {
        await real.unmountAndClose(tester, h);
      }
    },
  );

  testWidgets(
    'real media survives Chinese edits; unsaved restore clears warning; saved English invalidation is sticky across reopen',
    (tester) async {
      final h = (await tester.runAsync(real.Harness.create))!;
      final id = (await tester.runAsync(() => media(h)))!;
      try {
        await mount(tester, h, id);
        expect(find.textContaining('绑定一致'), findsOneWidget);
        await fixture.tap(tester, find.text('来源说明'));
        expect(find.text('文字来源声明'), findsOneWidget);
        expect(find.text('音频来源声明'), findsOneWidget);
        expect(find.textContaining('Audio provider'), findsOneWidget);
        await fixture.tap(tester, find.text('知道了'));
        final chinese = find.byKey(const Key('candidate-chinese-0'));
        await tester.ensureVisible(chinese);
        await tester.enterText(chinese, '只有中文对照变更。');
        await fixture.tap(tester, find.byKey(const Key('candidate-save')));
        await real.drain(tester);
        final store = h.learning as LearningCandidateStore;
        var c = (await tester.runAsync(() => store.readCandidate(id)))!;
        expect(c.mediaReview!.binding, CandidateMediaBinding.matched);
        expect(c.mediaReview!.issues, isEmpty);
        final english = find.byKey(const Key('candidate-english-0'));
        await tester.ensureVisible(english);
        await tester.enterText(english, 'Changed English.');
        await tester.pump();
        expect(find.textContaining('未保存修改'), findsOneWidget);
        await tester.enterText(english, 'Here is the supplied plan.');
        await tester.pump();
        expect(find.textContaining('未保存修改'), findsNothing);
        expect(
          tester
              .widget<OutlinedButton>(find.byKey(const Key('candidate-save')))
              .onPressed,
          isNull,
        );
        await tester.enterText(english, 'Changed English.');
        await tester.pump();
        await fixture.tap(tester, find.byKey(const Key('candidate-save')));
        await real.drain(tester);
        c = (await tester.runAsync(() => store.readCandidate(id)))!;
        expect(c.mediaReview!.binding, CandidateMediaBinding.invalidated);
        final first = c.mediaReview!.invalidatedAtRevision;
        await tester.ensureVisible(english);
        await tester.enterText(english, 'Here is the supplied plan.');
        await tester.pump();
        await fixture.tap(tester, find.byKey(const Key('candidate-save')));
        await real.drain(tester);
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(h.reopen);
        await mount(tester, h, id, size: const Size(667, 375), scale: 2);
        expect(tester.takeException(), isNull);
        expect(find.textContaining('改回原文也不会恢复'), findsOneWidget);
        c = (await tester.runAsync(
          () => (h.learning as LearningCandidateStore).readCandidate(id),
        ))!;
        expect(c.mediaReview!.invalidatedAtRevision, first);
        await fixture.tap(tester, find.byKey(const Key('candidate-confirm')));
        await real.drain(tester);
        final versions = (await tester.runAsync(h.learning.listVersions))!;
        expect(versions, hasLength(1));
        expect(versions.single.media, isNull);
        expect(
          versions.single.candidateMediaReview!.binding,
          CandidateMediaBinding.invalidated,
        );
        await tester.runAsync(
          () => (h.learning as LearningCandidateStore).confirmCandidate(
            candidateId: id,
            expectedRevision: c.revision,
          ),
        );
        expect((await tester.runAsync(h.learning.listVersions))!, hasLength(1));
      } finally {
        await real.unmountAndClose(tester, h);
      }
    },
  );

  for (final corrupt in [false, true]) {
    testWidgets(
      'real file media ${corrupt ? 'corruption' : 'loss'} remains distinct from English invalidation',
      (tester) async {
        final h = (await tester.runAsync(real.Harness.create))!;
        final id = (await tester.runAsync(() => media(h)))!;
        try {
          await tester.runAsync(() async {
            final blobs = await h.root
                .list(recursive: true)
                .where((f) => f is File && f.path.endsWith('.blob'))
                .cast<File>()
                .toList();
            expect(blobs, hasLength(1));
            if (corrupt) {
              await blobs.single.writeAsBytes([0, 1, 2], flush: true);
            } else {
              await blobs.single.delete();
            }
          });
          await mount(tester, h, id);
          final c = (await tester.runAsync(
            () => (h.learning as LearningCandidateStore).readCandidate(id),
          ))!;
          expect(c.mediaReview!.binding, CandidateMediaBinding.matched);
          expect(c.mediaReview!.issues, isNotEmpty);
          expect(find.textContaining('当前不可用'), findsOneWidget);
          expect(find.textContaining('改回原文也不会恢复'), findsNothing);
        } finally {
          await real.unmountAndClose(tester, h);
        }
      },
    );
  }
}
