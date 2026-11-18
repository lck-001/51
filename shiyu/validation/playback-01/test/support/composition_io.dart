// Only scheduling adapters: all values and mutations come from the same real
// file-backed Store/session. No in-memory persistence, receipts or candidates.
import 'dart:async';
import 'dart:typed_data';

import 'package:learning_core/learning_core.dart';
import 'package:material_core/material_core.dart';
import 'package:material_import/material_import.dart';
import 'package:playback_core/playback_core.dart';

final class IoMaterialView implements MaterialStore {
  IoMaterialView(this.raw, this.io);
  final FileMaterialStore raw;
  final Zone io;
  @override
  String get trustedOwnerId => raw.trustedOwnerId;
  @override
  RecoveryReport get recoveryReport => raw.recoveryReport;
  @override
  Future<MaterialDraft> createDraft({
    required String title,
    String text = '',
    Iterable<ArtifactRef> artifacts = const [],
  }) => io.run(
    () => raw.createDraft(title: title, text: text, artifacts: artifacts),
  );
  @override
  Future<MaterialDraft> updateDraft({
    required String materialId,
    required int expectedRevision,
    String? title,
    String? text,
    Iterable<ArtifactRef>? artifacts,
  }) => io.run(
    () => raw.updateDraft(
      materialId: materialId,
      expectedRevision: expectedRevision,
      title: title,
      text: text,
      artifacts: artifacts,
    ),
  );
  @override
  Future<MaterialDraft> readDraft(String id) => io.run(() => raw.readDraft(id));
  @override
  Future<List<MaterialDraft>> listDrafts() => io.run(raw.listDrafts);
  @override
  Future<MaterialVersion> confirmVersion({
    required String materialId,
    required int expectedRevision,
  }) => io.run(
    () => raw.confirmVersion(
      materialId: materialId,
      expectedRevision: expectedRevision,
    ),
  );
  @override
  Future<MaterialVersion> readVersion(String id) =>
      io.run(() => raw.readVersion(id));
  @override
  Future<List<MaterialVersion>> listVersions(String id) =>
      io.run(() => raw.listVersions(id));
  @override
  Future<ArtifactRef> importArtifact(Uint8List bytes) =>
      io.run(() => raw.importArtifact(bytes));
  @override
  Future<Uint8List> readArtifact(ArtifactRef ref) =>
      io.run(() => raw.readArtifact(ref));
  @override
  Future<void> close() => io.run(raw.close);
}

final class IoLearningView implements LearningStore, LearningCandidateStore {
  IoLearningView(this.raw, this.io);
  final FileLearningStore raw;
  final Zone io;
  int forbiddenUiReceiveCalls = 0;
  @override
  String get trustedOwnerId => raw.trustedOwnerId;
  @override
  LearningRecoveryReport get recoveryReport => raw.recoveryReport;
  @override
  Future<LearningVersion> createVersion({
    required String materialVersionId,
    required Iterable<LearningSentenceInput> sentences,
    required ContentProvenance textProvenance,
    LearningMediaInput? media,
  }) => io.run(
    () => raw.createVersion(
      materialVersionId: materialVersionId,
      sentences: sentences,
      textProvenance: textProvenance,
      media: media,
    ),
  );
  @override
  Future<LearningVersion> readVersion(String id) =>
      io.run(() => raw.readVersion(id));
  @override
  Future<List<LearningVersion>> listVersions({String? materialId}) =>
      io.run(() => raw.listVersions(materialId: materialId));
  @override
  Future<LearningPlaybackSession> openPlayback(String id) =>
      io.run(() => raw.openPlayback(id));
  @override
  Future<ArtifactRef> mediaArtifactFor(PlaybackItem item) =>
      io.run(() => raw.mediaArtifactFor(item));
  @override
  Future<ProgressCheckpoint> saveProgress({
    required LearningPlaybackSession session,
    required int expectedRevision,
    required String sentenceId,
    required Duration position,
  }) => io.run(
    () => raw.saveProgress(
      session: session,
      expectedRevision: expectedRevision,
      sentenceId: sentenceId,
      position: position,
    ),
  );
  @override
  Future<ProgressCheckpoint?> restoreProgress(String id) =>
      io.run(() => raw.restoreProgress(id));
  @override
  Future<CandidateDeliveryReceipt> receiveCandidate({
    required CandidateSender sender,
    required LearningCandidateInput input,
  }) async {
    forbiddenUiReceiveCalls++;
    throw StateError(
      'Composition candidates must arrive through the actual bridge, never UI test seeding',
    );
  }

  @override
  Future<LearningCandidate> readCandidate(String id) =>
      io.run(() => raw.readCandidate(id));
  @override
  Future<List<LearningCandidate>> listCandidates() =>
      io.run(raw.listCandidates);
  @override
  Future<LearningCandidate> reviseCandidate({
    required String candidateId,
    required int expectedRevision,
    required List<LearningSentenceInput> sentences,
  }) => io.run(
    () => raw.reviseCandidate(
      candidateId: candidateId,
      expectedRevision: expectedRevision,
      sentences: sentences,
    ),
  );
  @override
  Future<LearningVersion> confirmCandidate({
    required String candidateId,
    required int expectedRevision,
  }) => io.run(
    () => raw.confirmCandidate(
      candidateId: candidateId,
      expectedRevision: expectedRevision,
    ),
  );
  @override
  Future<LearningCandidate> rejectCandidate({
    required String candidateId,
    required int expectedRevision,
  }) => io.run(
    () => raw.rejectCandidate(
      candidateId: candidateId,
      expectedRevision: expectedRevision,
    ),
  );
  @override
  Future<void> close() => io.run(raw.close);
}

final class IoImportSession implements MaterialImportSession {
  IoImportSession(this.raw, this.io);
  final MaterialImportSession raw;
  final Zone io;
  @override
  String get sessionId => raw.sessionId;
  @override
  String get ownerId => raw.ownerId;
  @override
  Future<MaterialImportPreview?> get preview => io.run(() => raw.preview);
  @override
  Future<List<ArtifactRef>> prepareArtifacts() => io.run(raw.prepareArtifacts);
  @override
  Future<void> cancel() => io.run(raw.cancel);
  @override
  Future<void> finish({required String savedMaterialId}) =>
      io.run(() => raw.finish(savedMaterialId: savedMaterialId));
}
