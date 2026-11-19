library;

import 'package:material_core/material_core.dart';
import 'package:playback_core/playback_core.dart';

export 'src/file_learning_store.dart';
export 'src/external_candidate_media.dart';

enum LearningState { pending, partial, ready }

enum ContentOrigin { manual, synthetic, external }

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
  deliveryConflict,
  candidateLimitExceeded,
  invalidState,
  unsupportedMedia,
  recoveryHold,
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
  const ContentProvenance({
    required this.origin,
    required this.reference,
    this.external,
  });
  final ContentOrigin origin;

  /// Opaque source/fixture reference, not a local path or signed URL.
  final String reference;

  /// External declarations are not verified model/copyright claims.
  final ExternalContentSource? external;
}

enum LearningCandidateState { pendingReview, confirmed, rejected }

enum CandidateTransport { localCapability, controlledTest }

abstract final class LearningCandidateLimits {
  static const maxSentences = 128;
  static const maxTextBytes = 100 * 1024;
  static const maxDeclarationBytes = 8 * 1024;
  static const maxPendingCandidates = 32;
  static const maxStoredCandidateBytes = 32 * 1024 * 1024;
  static const maxDeliveryIdBytes = 256;
}

/// Provider-supplied statements only; none of these fields is verified identity.
final class SourceDeclaration {
  const SourceDeclaration({
    required this.preparation,
    this.provider,
    this.model,
    this.modelVersion,
    this.notes,
  });
  final String preparation;
  final String? provider, model, modelVersion, notes;
}

/// App-authenticated context. The Core does not verify a capability itself.
/// integrationId is stable across capability rotation and process restarts.
final class CandidateSender {
  const CandidateSender({
    required this.integrationId,
    required this.transport,
    this.transportPayloadSha256,
  });
  final String integrationId;
  final CandidateTransport transport;
  final String? transportPayloadSha256;
}

final class CandidateSubmission {
  const CandidateSubmission({
    required this.integrationId,
    required this.transport,
    required this.deliveryId,
    required this.payloadSha256,
    required this.receivedAtUtc,
    this.transportPayloadSha256,
  });
  final String integrationId, deliveryId, payloadSha256;
  final CandidateTransport transport;
  final String? transportPayloadSha256;
  final DateTime receivedAtUtc;
}

/// B1 intentionally has no media field. Wire decoders must reject its presence,
/// even if null, rather than silently dropping unsupported supplied media.
final class LearningCandidateInput {
  LearningCandidateInput({
    required this.materialId,
    required this.materialVersionId,
    required this.sourceTextSha256,
    required this.deliveryId,
    required List<LearningSentenceInput> sentences,
    required this.declaration,
  }) : sentences = _candidateSentences(sentences);
  final String materialId, materialVersionId, sourceTextSha256, deliveryId;
  final List<LearningSentenceInput> sentences;
  final SourceDeclaration declaration;
}

List<LearningSentenceInput> _candidateSentences(
  List<LearningSentenceInput> value,
) {
  if (value.length > LearningCandidateLimits.maxSentences) {
    throw const LearningStoreException(
      LearningErrorCode.candidateLimitExceeded,
    );
  }
  return List.unmodifiable(value);
}

final class CandidateDeliveryReceipt {
  const CandidateDeliveryReceipt({
    required this.candidateId,
    required this.payloadSha256,
    required this.replayed,
  });
  final String candidateId, payloadSha256;
  final bool replayed;
}

final class LearningCandidate {
  LearningCandidate({
    required this.candidateId,
    required this.ownerId,
    required this.materialTitle,
    required this.materialId,
    required this.materialVersionId,
    required this.sourceTextSha256,
    required this.revision,
    required this.state,
    required Iterable<LearningSentenceInput> originalSentences,
    required Iterable<LearningSentenceInput> sentences,
    required this.declaration,
    required this.submission,
    required this.updatedAtUtc,
    required this.userEdited,
    this.confirmedLearningVersionId,
    this.confirmedRevision,
    this.mediaReview,
  }) : originalSentences = List.unmodifiable(originalSentences),
       sentences = List.unmodifiable(sentences);
  final String candidateId,
      ownerId,
      materialId,
      materialVersionId,
      sourceTextSha256;
  final String materialTitle;
  final int revision;
  final LearningCandidateState state;
  final List<LearningSentenceInput> originalSentences, sentences;
  final SourceDeclaration declaration;
  final CandidateSubmission submission;
  final DateTime updatedAtUtc;
  final bool userEdited;
  final String? confirmedLearningVersionId;
  final int? confirmedRevision;
  final LearningCandidateMediaReview? mediaReview;
}

final class ExternalContentSource {
  const ExternalContentSource({
    required this.candidateId,
    required this.candidateRevision,
    required this.sourceTextSha256,
    required this.declaration,
    required this.submission,
    required this.userEdited,
    required this.confirmedAtUtc,
  });
  final String candidateId, sourceTextSha256;
  final int candidateRevision;
  final SourceDeclaration declaration;
  final CandidateSubmission submission;
  final bool userEdited;
  final DateTime confirmedAtUtc;
}

/// Same owning instance and atomic snapshot as LearningStore. App/transport
/// authorization is separate; no HTTP, model call or player is created here.
abstract interface class LearningCandidateStore {
  String get trustedOwnerId;
  Future<CandidateDeliveryReceipt> receiveCandidate({
    required CandidateSender sender,
    required LearningCandidateInput input,
  });
  Future<LearningCandidate> readCandidate(String candidateId);
  Future<List<LearningCandidate>> listCandidates();
  Future<LearningCandidate> reviseCandidate({
    required String candidateId,
    required int expectedRevision,
    required List<LearningSentenceInput> sentences,
  });
  Future<LearningVersion> confirmCandidate({
    required String candidateId,
    required int expectedRevision,
  });
  Future<LearningCandidate> rejectCandidate({
    required String candidateId,
    required int expectedRevision,
  });
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
    this.externalDetails,
  });
  final String mediaVersionId, validation;
  final ArtifactRef artifact;
  final ContentProvenance provenance;
  final int? durationMs;
  final ExternalLearningMediaDetails? externalDetails;
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
    this.candidateMediaReview,
  }) : sentences = List.unmodifiable(sentences),
       issues = List.unmodifiable(issues);
  final LearningBinding binding;
  final String materialTitle;
  final ContentProvenance textProvenance;
  final LearningState state;
  final List<SentenceAnchor> sentences;
  final List<String> issues;
  final LearningMedia? media;
  final LearningCandidateMediaReview? candidateMediaReview;
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

/// Structure-only media delivery capability; the App supplies trusted identity.
abstract interface class LearningMediaCandidateStore {
  Future<CandidateDeliveryReceipt> receiveMediaCandidate({
    required CandidateSender sender,
    required LearningMediaCandidateInput input,
  });

  /// Neutral, direct authority lookup; does not assert current media availability.
  Future<CandidateDeliveryReceipt?> findDeliveryReceipt({
    required CandidateSender sender,
    required String deliveryId,
    required int inputVersion,
    required String expectedPayloadSha256,
  });
}

final class LearningMediaCandidateInput {
  const LearningMediaCandidateInput({required this.text, required this.media});
  final LearningCandidateInput text;
  final LearningCandidateMediaInput media;
}

final class LearningCandidateMediaInput {
  LearningCandidateMediaInput({
    required this.artifact,
    required this.englishSha256,
    required this.declaration,
    required this.timingDeclaration,
    required List<SentenceTiming> timings,
  }) : timings = _boundedMediaTimings(timings);
  final ArtifactRef artifact;
  final String englishSha256, timingDeclaration;
  final SourceDeclaration declaration;
  final List<SentenceTiming> timings;
}

List<SentenceTiming> _boundedMediaTimings(List<SentenceTiming> timings) {
  if (timings.length > LearningCandidateLimits.maxSentences) {
    throw const LearningStoreException(
      LearningErrorCode.candidateLimitExceeded,
    );
  }
  return List.unmodifiable(timings);
}

enum CandidateMediaBinding { matched, invalidated }

final class LearningCandidateMediaReview {
  LearningCandidateMediaReview({
    required this.original,
    required this.currentEnglishSha256,
    required this.binding,
    this.invalidatedAtRevision,
    this.firstInvalidatedEnglishSha256,
    Iterable<String> issues = const [],
  }) : issues = List.unmodifiable(issues);
  final LearningCandidateMediaInput original;
  final String currentEnglishSha256;
  final CandidateMediaBinding binding;
  final int? invalidatedAtRevision;
  final String? firstInvalidatedEnglishSha256;
  final List<String> issues;
}

final class ExternalLearningMediaDetails {
  const ExternalLearningMediaDetails({
    required this.englishSha256,
    required this.declaration,
    required this.timingDeclaration,
  });
  final String englishSha256, timingDeclaration;
  final SourceDeclaration declaration;
}
