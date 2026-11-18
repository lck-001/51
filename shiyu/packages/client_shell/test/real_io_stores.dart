// Real file-store delegation, not an in-memory fake. Flutter test's virtual
// clock must not own the serial IO actors while runAsync awaits their queues.
part of 'client_shell_test.dart';

final class _RealIoMaterialStore implements MaterialStore {
  _RealIoMaterialStore(this.store, this.zone);
  final MaterialStore store;
  final Zone zone;
  @override
  String get trustedOwnerId => store.trustedOwnerId;
  @override
  RecoveryReport get recoveryReport => store.recoveryReport;
  @override
  Future<MaterialDraft> createDraft({
    required String title,
    String text = '',
    Iterable<ArtifactRef> artifacts = const [],
  }) => zone.run(
    () => store.createDraft(title: title, text: text, artifacts: artifacts),
  );
  @override
  Future<MaterialDraft> readDraft(String id) =>
      zone.run(() => store.readDraft(id));
  @override
  Future<List<MaterialDraft>> listDrafts() => zone.run(store.listDrafts);
  @override
  Future<MaterialDraft> updateDraft({
    required String materialId,
    required int expectedRevision,
    String? title,
    String? text,
    Iterable<ArtifactRef>? artifacts,
  }) => zone.run(
    () => store.updateDraft(
      materialId: materialId,
      expectedRevision: expectedRevision,
      title: title,
      text: text,
      artifacts: artifacts,
    ),
  );
  @override
  Future<MaterialVersion> confirmVersion({
    required String materialId,
    required int expectedRevision,
  }) => zone.run(
    () => store.confirmVersion(
      materialId: materialId,
      expectedRevision: expectedRevision,
    ),
  );
  @override
  Future<MaterialVersion> readVersion(String id) =>
      zone.run(() => store.readVersion(id));
  @override
  Future<List<MaterialVersion>> listVersions(String id) =>
      zone.run(() => store.listVersions(id));
  @override
  Future<ArtifactRef> importArtifact(Uint8List bytes) =>
      zone.run(() => store.importArtifact(bytes));
  @override
  Future<Uint8List> readArtifact(ArtifactRef ref) =>
      zone.run(() => store.readArtifact(ref));
  @override
  Future<void> close() => zone.run(store.close);
}

final class _RealIoLearningStore implements LearningStore, LearningCandidateStore {
  _RealIoLearningStore(this.store, this.zone);
  final LearningStore store;
  final Zone zone;
  @override
  String get trustedOwnerId => store.trustedOwnerId;
  @override
  LearningRecoveryReport get recoveryReport => store.recoveryReport;
  @override
  Future<LearningVersion> createVersion({
    required String materialVersionId,
    required Iterable<LearningSentenceInput> sentences,
    required ContentProvenance textProvenance,
    LearningMediaInput? media,
  }) => zone.run(
    () => store.createVersion(
      materialVersionId: materialVersionId,
      sentences: sentences,
      textProvenance: textProvenance,
      media: media,
    ),
  );
  @override
  Future<LearningVersion> readVersion(String id) =>
      zone.run(() => store.readVersion(id));
  @override
  Future<List<LearningVersion>> listVersions({String? materialId}) =>
      zone.run(() => store.listVersions(materialId: materialId));
  @override
  Future<LearningPlaybackSession> openPlayback(String id) =>
      zone.run(() => store.openPlayback(id));
  @override
  Future<ArtifactRef> mediaArtifactFor(PlaybackItem item) =>
      zone.run(() => store.mediaArtifactFor(item));
  @override
  Future<ProgressCheckpoint> saveProgress({
    required LearningPlaybackSession session,
    required int expectedRevision,
    required String sentenceId,
    required Duration position,
  }) => zone.run(
    () => store.saveProgress(
      session: session,
      expectedRevision: expectedRevision,
      sentenceId: sentenceId,
      position: position,
    ),
  );
  @override
  Future<ProgressCheckpoint?> restoreProgress(String id) =>
      zone.run(() => store.restoreProgress(id));
  @override
  Future<CandidateDeliveryReceipt> receiveCandidate({required CandidateSender sender,
      required LearningCandidateInput input}) => zone.run(() =>
      (store as LearningCandidateStore).receiveCandidate(sender: sender, input: input));
  @override
  Future<LearningCandidate> readCandidate(String id) => zone.run(() =>
      (store as LearningCandidateStore).readCandidate(id));
  @override
  Future<List<LearningCandidate>> listCandidates() => zone.run(() =>
      (store as LearningCandidateStore).listCandidates());
  @override
  Future<LearningCandidate> reviseCandidate({required String candidateId,
      required int expectedRevision, required List<LearningSentenceInput> sentences}) =>
      zone.run(() => (store as LearningCandidateStore).reviseCandidate(
          candidateId: candidateId, expectedRevision: expectedRevision, sentences: sentences));
  @override
  Future<LearningVersion> confirmCandidate({required String candidateId,
      required int expectedRevision}) => zone.run(() =>
      (store as LearningCandidateStore).confirmCandidate(candidateId: candidateId,
                                                       expectedRevision: expectedRevision));
  @override
  Future<LearningCandidate> rejectCandidate({required String candidateId,
      required int expectedRevision}) => zone.run(() =>
      (store as LearningCandidateStore).rejectCandidate(candidateId: candidateId,
                                                      expectedRevision: expectedRevision));
  @override
  Future<void> close() => zone.run(store.close);
}
