// A previously accepted revision may finish, but its delayed acknowledgement
// cannot begin confirmation after application retirement. All data is synthetic.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:learning_core/learning_core.dart';
import 'package:material_ui/material_ui.dart';

import '../lib/src/candidate_review_sheet.dart';
import 'client_shell_test.dart' as real;
import 'candidate_review_flow_test.dart' as fixture;

class RevisionAcknowledgementGate implements LearningCandidateStore {
  RevisionAcknowledgementGate(this.delegate);
  final LearningCandidateStore delegate;
  final entered = Completer<void>(), release = Completer<void>();
  int confirmations = 0;
  @override String get trustedOwnerId => delegate.trustedOwnerId;
  @override Future<LearningCandidate> reviseCandidate({required String candidateId,
      required int expectedRevision, required List<LearningSentenceInput> sentences}) async {
    final accepted = delegate.reviseCandidate(candidateId: candidateId,
        expectedRevision: expectedRevision, sentences: sentences);
    entered.complete();
    await release.future;
    return accepted;
  }
  @override Future<CandidateDeliveryReceipt> receiveCandidate({required CandidateSender sender,
      required LearningCandidateInput input}) => delegate.receiveCandidate(sender: sender, input: input);
  @override Future<LearningCandidate> readCandidate(String id) => delegate.readCandidate(id);
  @override Future<List<LearningCandidate>> listCandidates() => delegate.listCandidates();
  @override Future<LearningVersion> confirmCandidate({required String candidateId,
      required int expectedRevision}) {
    confirmations++;
    return delegate.confirmCandidate(candidateId: candidateId, expectedRevision: expectedRevision);
  }
  @override Future<LearningCandidate> rejectCandidate({required String candidateId,
      required int expectedRevision}) => delegate.rejectCandidate(
          candidateId: candidateId, expectedRevision: expectedRevision);
}

void main() {
  testWidgets('retirement between accepted revision and acknowledgement never starts confirmation', (tester) async {
    final h = (await tester.runAsync(real.Harness.create))!;
    final fixed = (await tester.runAsync(() => fixture.source(h)))!;
    final receipt = (await tester.runAsync(() => fixture.deliver(h, fixed)))!;
    final gate = RevisionAcknowledgementGate(h.learning as LearningCandidateStore);
    final retired = ValueNotifier(false);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    try {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: CandidateReviewSheet(
        candidates: gate, materials: h.materials, candidateId: receipt.candidateId,
        isCurrentScope: () => !retired.value,
      ))));
      await real.drain(tester);
      final english = find.byKey(const Key('candidate-english-0'));
      await tester.ensureVisible(english);
      await tester.enterText(english, 'An edit accepted before retirement.');
      final confirm = find.byKey(const Key('candidate-confirm'));
      await tester.ensureVisible(confirm);
      tester.widget<FilledButton>(confirm).onPressed!();
      await gate.entered.future;
      retired.value = true;
      gate.release.complete();
      await real.drain(tester);
      final actual = (await tester.runAsync(
          () => (h.learning as LearningCandidateStore).readCandidate(receipt.candidateId)))!;
      expect(actual.revision, 2, reason: 'The already accepted revision is not falsely rolled back');
      expect(actual.sentences.single.english, 'An edit accepted before retirement.');
      expect(actual.state, LearningCandidateState.pendingReview);
      expect(gate.confirmations, 0, reason: 'A late acknowledgement cannot authorize a new action');
      expect((await tester.runAsync(h.learning.listVersions))!, isEmpty);
    } finally {
      if (!gate.release.isCompleted) gate.release.complete();
      await real.unmountAndClose(tester, h);
      retired.dispose();
    }
  });
}
