// Test-only real-store delegation. Only asynchronous IO completion/frame timing
// is controlled; no Focus, traversal, geometry or production Widget is mocked.
import 'dart:async';
import 'dart:typed_data';

import 'package:material_core/material_core.dart';
import 'package:learning_core/learning_core.dart';
import 'package:playback_core/playback_core.dart';

class IOPhases {
  IOPhases(this.zone);
  final Zone zone;
  static const names = [
    'createDraft',
    'readDraft',
    'listDrafts',
    'material-listVersions',
    'learning-listVersions',
    'learning-listCandidates',
  ];
  bool armed = false;
  late Completer<void> saveGate;
  final done = <String, Completer<void>>{};
  final returned = <String>[];
  void arm() {
    armed = true;
    saveGate = Completer<void>();
    for (final name in names) {
      done[name] = Completer<void>();
    }
  }

  Future<T> track<T>(String name, Future<T> Function() call) =>
      zone.run(() async {
        if (armed && name == 'createDraft') await saveGate.future;
        final value = await call();
        if (armed) {
          returned.add(name);
          if (!done[name]!.isCompleted) done[name]!.complete();
        }
        return value;
      });
}

final class TimedMaterialStore implements MaterialStore {
  TimedMaterialStore(this.store, this.phases);
  final MaterialStore store;
  final IOPhases phases;
  Zone get zone => phases.zone;
  @override
  String get trustedOwnerId => store.trustedOwnerId;
  @override
  RecoveryReport get recoveryReport => store.recoveryReport;
  @override
  Future<MaterialDraft> createDraft({
    required String title,
    String text = '',
    Iterable<ArtifactRef> artifacts = const [],
  }) => phases.track(
    'createDraft',
    () => store.createDraft(title: title, text: text, artifacts: artifacts),
  );
  @override
  Future<MaterialDraft> readDraft(String id) =>
      phases.track('readDraft', () => store.readDraft(id));
  @override
  Future<List<MaterialDraft>> listDrafts() =>
      phases.track('listDrafts', store.listDrafts);
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
      phases.track('material-listVersions', () => store.listVersions(id));
  @override
  Future<ArtifactRef> importArtifact(Uint8List bytes) =>
      zone.run(() => store.importArtifact(bytes));
  @override
  Future<Uint8List> readArtifact(ArtifactRef ref) =>
      zone.run(() => store.readArtifact(ref));
  @override
  Future<void> close() => zone.run(store.close);
}

final class TimedLearningStore
    implements
        LearningStore,
        LearningCandidateStore,
        LearningMediaCandidateStore {
  TimedLearningStore(this.store, this.phases);
  final LearningStore store;
  final IOPhases phases;
  Zone get zone => phases.zone;
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
      phases.track(
        'learning-listVersions',
        () => store.listVersions(materialId: materialId),
      );
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
  Future<CandidateDeliveryReceipt> receiveCandidate({
    required CandidateSender sender,
    required LearningCandidateInput input,
  }) => zone.run(
    () => (store as LearningCandidateStore).receiveCandidate(
      sender: sender,
      input: input,
    ),
  );
  @override
  Future<CandidateDeliveryReceipt> receiveMediaCandidate({
    required CandidateSender sender,
    required LearningMediaCandidateInput input,
  }) => zone.run(
    () => (store as LearningMediaCandidateStore).receiveMediaCandidate(
      sender: sender,
      input: input,
    ),
  );
  @override
  Future<CandidateDeliveryReceipt?> findDeliveryReceipt({
    required CandidateSender sender,
    required String deliveryId,
    required int inputVersion,
    required String expectedPayloadSha256,
  }) => zone.run(
    () => (store as LearningMediaCandidateStore).findDeliveryReceipt(
      sender: sender,
      deliveryId: deliveryId,
      inputVersion: inputVersion,
      expectedPayloadSha256: expectedPayloadSha256,
    ),
  );
  @override
  Future<LearningCandidate> readCandidate(String id) =>
      zone.run(() => (store as LearningCandidateStore).readCandidate(id));
  @override
  Future<List<LearningCandidate>> listCandidates() => phases.track(
    'learning-listCandidates',
    () => (store as LearningCandidateStore).listCandidates(),
  );
  @override
  Future<LearningCandidate> reviseCandidate({
    required String candidateId,
    required int expectedRevision,
    required List<LearningSentenceInput> sentences,
  }) => zone.run(
    () => (store as LearningCandidateStore).reviseCandidate(
      candidateId: candidateId,
      expectedRevision: expectedRevision,
      sentences: sentences,
    ),
  );
  @override
  Future<LearningVersion> confirmCandidate({
    required String candidateId,
    required int expectedRevision,
  }) => zone.run(
    () => (store as LearningCandidateStore).confirmCandidate(
      candidateId: candidateId,
      expectedRevision: expectedRevision,
    ),
  );
  @override
  Future<LearningCandidate> rejectCandidate({
    required String candidateId,
    required int expectedRevision,
  }) => zone.run(
    () => (store as LearningCandidateStore).rejectCandidate(
      candidateId: candidateId,
      expectedRevision: expectedRevision,
    ),
  );
  @override
  Future<void> close() => zone.run(store.close);
}
