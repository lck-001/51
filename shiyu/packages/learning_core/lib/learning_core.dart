library;

import 'package:material_core/material_core.dart';
import 'package:playback_core/playback_core.dart';

export 'src/file_learning_store.dart';

enum LearningState { pending, partial, ready }

enum ContentOrigin { manual, synthetic }

enum LearningErrorCode {
  invalidInput,
  invalidId,
  ownerMismatch,
  notFound,
  notReady,
  revisionConflict,
  staleSession,
  bindingMismatch,
  corruptStore,
  writeFailed,
  closed,
  mediaUnavailable,
}

enum LearningRecoveryStatus {
  initialized,
  clean,
  recoveredFromBackup,
  degraded,
  unrecoverable,
}

final class LearningStoreException implements Exception {
  const LearningStoreException(this.code);
  final LearningErrorCode code;
  @override
  String toString() => 'LearningStoreException(${code.name})';
}

final class ContentProvenance {
  const ContentProvenance({required this.origin, required this.reference});
  final ContentOrigin origin;

  /// Opaque source/fixture reference, not a local path or signed URL.
  final String reference;
}

final class LearningSentenceInput {
  const LearningSentenceInput({required this.english, this.translation = ''});
  final String english, translation;
}

final class SentenceTiming {
  const SentenceTiming({
    required this.sentenceIndex,
    required this.startMs,
    required this.endMs,
  });
  final int sentenceIndex, startMs, endMs;
}

final class LearningMediaInput {
  LearningMediaInput({
    required this.artifact,
    required this.provenance,
    required Iterable<SentenceTiming> timings,
  }) : timings = List.unmodifiable(timings);
  final ArtifactRef artifact;
  final ContentProvenance provenance;
  final List<SentenceTiming> timings;
}

final class SentenceAnchor {
  const SentenceAnchor({
    required this.sentenceId,
    required this.unitId,
    required this.english,
    required this.translation,
    this.startMs,
    this.endMs,
  });
  final String sentenceId, unitId, english, translation;
  final int? startMs, endMs;
}

final class LearningBinding {
  const LearningBinding({
    required this.ownerId,
    required this.materialId,
    required this.materialVersionId,
    required this.learningVersionId,
    this.mediaVersionId,
  });
  final String ownerId, materialId, materialVersionId, learningVersionId;
  final String? mediaVersionId;
  bool sameAs(LearningBinding other) =>
      ownerId == other.ownerId &&
      materialId == other.materialId &&
      materialVersionId == other.materialVersionId &&
      learningVersionId == other.learningVersionId &&
      mediaVersionId == other.mediaVersionId;
}

final class LearningMedia {
  const LearningMedia({
    required this.mediaVersionId,
    required this.artifact,
    required this.provenance,
    required this.validation,
    this.durationMs,
  });
  final String mediaVersionId, validation;
  final ArtifactRef artifact;
  final ContentProvenance provenance;
  final int? durationMs;
}

final class LearningVersion {
  LearningVersion({
    required this.binding,
    required this.materialTitle,
    required this.textProvenance,
    required this.state,
    required Iterable<SentenceAnchor> sentences,
    required Iterable<String> issues,
    required this.createdAtUtc,
    this.media,
  }) : sentences = List.unmodifiable(sentences),
       issues = List.unmodifiable(issues);
  final LearningBinding binding;
  final String materialTitle;
  final ContentProvenance textProvenance;
  final LearningState state;
  final List<SentenceAnchor> sentences;
  final List<String> issues;
  final LearningMedia? media;
  final DateTime createdAtUtc;
}

final class LearningRecoveryReport {
  LearningRecoveryReport(this.status, Iterable<String> issues)
    : issues = List.unmodifiable(issues);
  final LearningRecoveryStatus status;
  final List<String> issues;
}

final class LearningPlaybackSession {
  const LearningPlaybackSession({
    required this.sessionId,
    required this.binding,
    required this.item,
    required this.progressRevision,
  });
  final String sessionId;
  final LearningBinding binding;
  final PlaybackItem item;
  final int progressRevision;
  PlaybackIntent get resumeIntent => PlaybackIntent.paused;
}

final class ProgressCheckpoint {
  const ProgressCheckpoint({
    required this.binding,
    required this.revision,
    required this.sentenceId,
    required this.position,
    required this.savedAtUtc,
  });
  final LearningBinding binding;
  final int revision;
  final String sentenceId;
  final Duration position;
  final DateTime savedAtUtc;

  /// Never persisted as playing and never dispatches Play on restoration.
  PlaybackIntent get resumeIntent => PlaybackIntent.paused;
}

abstract interface class LearningStore {
  String get trustedOwnerId;
  LearningRecoveryReport get recoveryReport;
  Future<LearningVersion> createVersion({
    required String materialVersionId,
    required Iterable<LearningSentenceInput> sentences,
    required ContentProvenance textProvenance,
    LearningMediaInput? media,
  });
  Future<LearningVersion> readVersion(String learningVersionId);
  Future<List<LearningVersion>> listVersions({String? materialId});
  Future<LearningPlaybackSession> openPlayback(String learningVersionId);
  Future<ArtifactRef> mediaArtifactFor(PlaybackItem item);
  Future<ProgressCheckpoint> saveProgress({
    required LearningPlaybackSession session,
    required int expectedRevision,
    required String sentenceId,
    required Duration position,
  });
  Future<ProgressCheckpoint?> restoreProgress(String learningVersionId);
  Future<void> close();
}
