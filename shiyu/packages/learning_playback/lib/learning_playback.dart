library;

import 'package:learning_core/learning_core.dart';
import 'package:material_core/material_core.dart';
import 'package:playback_core/playback_core.dart';

export 'src/file_playable_cache.dart';
export 'src/learning_playback_coordinator.dart';

enum LearningPlaybackErrorCode {
  invalidInput,
  ownerMismatch,
  bindingMismatch,
  sourceUnavailable,
  cacheCorrupt,
  cacheWriteFailed,
  notReady,
  checkpointFailed,
  closed,
}

final class LearningPlaybackException implements Exception {
  const LearningPlaybackException(this.code);
  final LearningPlaybackErrorCode code;
  @override
  String toString() => 'LearningPlaybackException(${code.name})';
}

final class PreparedLearningMedia {
  const PreparedLearningMedia({
    required this.item,
    required this.binding,
    required this.artifact,
  });
  final PlaybackItem item;
  final LearningBinding binding;
  final ArtifactRef artifact;
}

enum LearningPlaybackPhase {
  idle,
  preparing,
  opening,
  awaitingLoad,
  restoring,
  stopping,
  ready,
  failed,
  closed,
}

enum LearningOpenStatus { ready, pending, superseded, rejected }

final class LearningOpenResult {
  const LearningOpenResult(
    this.status, {
    this.session,
    this.checkpointRestored = false,
    this.reason,
  });
  final LearningOpenStatus status;
  final LearningPlaybackSession? session;
  final bool checkpointRestored;

  /// A stable code, never raw engine errors, paths, material text or URLs.
  final String? reason;
}

final class LearningPlaybackSnapshot {
  const LearningPlaybackSnapshot({
    required this.phase,
    required this.checkpointRevision,
    required this.checkpointRestored,
    this.binding,
    this.token,
    this.error,
  });
  final LearningPlaybackPhase phase;
  final LearningBinding? binding;
  final PlaybackToken? token;
  final int checkpointRevision;
  final bool checkpointRestored;
  final String? error;
}
