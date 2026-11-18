// Independent privacy regression: real candidate Store data in a modal route
// must disappear when the parent switches Store/owner. No native UI is used.
import 'package:flutter_test/flutter_test.dart';
import 'package:learning_core/learning_core.dart';
import 'package:material_ui/material_ui.dart';

import 'client_shell_test.dart' as real;

void main() {
  testWidgets('owner replacement removes the old candidate review and its original-source dialog',
      (tester) async {
    final a = (await tester.runAsync(() => real.Harness.create(owner: 'candidate-owner-a')))!;
    final b = (await tester.runAsync(() => real.Harness.create(owner: 'candidate-owner-b')))!;
    const privateSource = 'OWNER_A_PRIVATE_SOURCE_ONLY';
    final receipt = (await tester.runAsync(() async {
      final draft = await a.materials.createDraft(title: 'Owner A private fixture',
                                                 text: privateSource);
      final fixed = await a.materials.confirmVersion(materialId: draft.materialId,
                                                     expectedRevision: draft.revision);
      return (a.learning as LearningCandidateStore).receiveCandidate(
        sender: const CandidateSender(integrationId: 'scope-test-integration',
                                      transport: CandidateTransport.controlledTest),
        input: LearningCandidateInput(materialId: fixed.materialId,
          materialVersionId: fixed.versionId,
          sourceTextSha256: '7e532c299c1e215643dfd660bc3d7fd8dc76100b2db577e05b862c71d9fc016f',
          deliveryId: 'owner-a-only-delivery',
          sentences: const [LearningSentenceInput(english: 'OWNER_A_PRIVATE_ENGLISH_ONLY',
                                                   translation: 'A的私有合成对照。')],
          declaration: const SourceDeclaration(preparation: 'Controlled fixture',
                                                 notes: 'OWNER_A_PRIVATE_DECLARATION_ONLY')),
      );
    }))!;
    try {
      await real.mount(tester, a);
      await tester.tap(find.byKey(Key('candidate-review-${receipt.candidateId}')));
      await real.drain(tester);
      expect(tester.widget<TextField>(find.byKey(const Key('candidate-english-0')))
          .controller!.text, 'OWNER_A_PRIVATE_ENGLISH_ONLY');
      await tester.ensureVisible(find.text('查看原文'));
      await tester.tap(find.text('查看原文'));
      await tester.pumpAndSettle();
      final sourceText = find.byWidgetPredicate(
          (widget) => widget is SelectableText && widget.data == privateSource);
      expect(sourceText, findsOneWidget);
      await real.mount(tester, b);
      await tester.pumpAndSettle();
      expect(sourceText, findsNothing,
          reason: 'An old owner modal must not display its private original over the new owner');
      expect(find.byKey(const Key('candidate-english-0')), findsNothing,
          reason: 'The old review route must retire too, not only its top dialog');
      expect(find.text('Owner A private fixture'), findsNothing);
      expect((await tester.runAsync(b.learning.listVersions))!, isEmpty);
      expect((await tester.runAsync(
          () => (b.learning as LearningCandidateStore).listCandidates()))!, isEmpty);
    } finally {
      await real.unmountAndClose(tester, b);
      await tester.runAsync(a.close);
    }
  });
}
