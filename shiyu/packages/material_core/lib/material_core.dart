library;

import 'dart:typed_data';

export 'src/file_material_store.dart';

enum MaterialErrorCode {
  invalidOwner,
  invalidId,
  notFound,
  ownerMismatch,
  revisionConflict,
  corruptStore,
  missingArtifact,
  artifactCorrupt,
  writeFailed,
  closed,
  invalidOperationKey,
  invalidArtifactDigest,
  artifactConflict,
  capacityExceeded,
  recoveryHold,
}

enum RecoveryStatus {
  initialized,
  clean,
  recoveredFromBackup,
  degraded,
  unrecoverable,
}

enum RecoveryIssueKind {
  manifestCorrupt,
  backupCorrupt,
  backupUsed,
  pendingWrite,
  artifactMissing,
  artifactCorrupt,
  orphanArtifact,
  registrationHold,
  schemaBoundaryMismatch,
}

enum RecoveryHoldReason {
  lossyFallback,
  markerInvalid,
  migrationUncertain,
  authorityUnavailable,
}

final class RecoveryIssue {
  const RecoveryIssue(this.kind, {this.resourceId, this.holdReason});
  final RecoveryIssueKind kind;

  /// Opaque resource ID only, never an OS path.
  final String? resourceId;
  final RecoveryHoldReason? holdReason;
}

final class RecoveryReport {
  RecoveryReport(this.status, Iterable<RecoveryIssue> issues)
    : issues = List.unmodifiable(issues);
  final RecoveryStatus status;
  final List<RecoveryIssue> issues;
}

final class MaterialStoreException implements Exception {
  const MaterialStoreException(
    this.code, {
    this.resourceId,
    this.recoveryReport,
  });
  final MaterialErrorCode code;
  final String? resourceId;
  final RecoveryReport? recoveryReport;
  @override
  String toString() => 'MaterialStoreException(${code.name})';
}

final class ArtifactRef {
  const ArtifactRef({
    required this.ownerId,
    required this.artifactId,
    required this.byteLength,
    required this.sha256,
  });
  final String ownerId, artifactId, sha256;
  final int byteLength;
}

final class MaterialDraft {
  MaterialDraft({
    required this.ownerId,
    required this.materialId,
    required this.revision,
    required this.title,
    required this.text,
    required Iterable<ArtifactRef> artifacts,
    required this.updatedAtUtc,
  }) : artifacts = List.unmodifiable(artifacts);
  final String ownerId, materialId, title, text;
  final int revision;
  final List<ArtifactRef> artifacts;
  final DateTime updatedAtUtc;
}

final class MaterialVersion {
  MaterialVersion({
    required this.ownerId,
    required this.materialId,
    required this.versionId,
    required this.versionNumber,
    required this.draftRevision,
    required this.title,
    required this.text,
    required Iterable<ArtifactRef> artifacts,
    required this.confirmedAtUtc,
  }) : artifacts = List.unmodifiable(artifacts);
  final String ownerId, materialId, versionId, title, text;
  final int versionNumber, draftRevision;
  final List<ArtifactRef> artifacts;
  final DateTime confirmedAtUtc;
}

/// Caller identity is bound by the adapter's trustedOwnerId at open time.
/// This interface does not authenticate users or provide multi-process locking.
abstract interface class MaterialStore {
  String get trustedOwnerId;
  RecoveryReport get recoveryReport;
  Future<MaterialDraft> createDraft({
    required String title,
    String text = '',
    Iterable<ArtifactRef> artifacts = const [],
  });
  Future<MaterialDraft> readDraft(String materialId);
  Future<List<MaterialDraft>> listDrafts();
  Future<MaterialDraft> updateDraft({
    required String materialId,
    required int expectedRevision,
    String? title,
    String? text,
    Iterable<ArtifactRef>? artifacts,
  });
  Future<MaterialVersion> confirmVersion({
    required String materialId,
    required int expectedRevision,
  });
  Future<MaterialVersion> readVersion(String versionId);
  Future<List<MaterialVersion>> listVersions(String materialId);
  Future<ArtifactRef> importArtifact(Uint8List bytes);
  Future<Uint8List> readArtifact(ArtifactRef ref);
  Future<void> close();
}

/// Capability for a trusted application to register one immutable artifact per
/// business operation. Keys are lowercase 64-hex application-derived digests,
/// never a caller-selected path or an authentication credential.
abstract interface class IdempotentArtifactStore {
  Future<ArtifactRef> registerArtifactOnce({
    required String operationKey,
    required String expectedSha256,
    required Uint8List bytes,
  });
  Future<ArtifactRef?> findArtifactRegistration(String operationKey);
}

abstract final class ArtifactRegistrationLimits {
  static const maxArtifactBytes = 2 * 1024 * 1024;
  static const maxOperations = 128;
  static const maxRetainedBytes = 64 * 1024 * 1024;
}
