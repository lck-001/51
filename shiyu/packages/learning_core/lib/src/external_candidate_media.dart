import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;

import '../learning_core.dart';
import 'pcm_wave.dart';

/// Actual container facts only: not narration or semantic alignment evidence.
final class ExternalCandidateMediaInspection {
  const ExternalCandidateMediaInspection._({
    required this.actualSha256,
    required this.byteLength,
    required this.durationMs,
  });
  final String actualSha256;
  final int byteLength, durationMs;
}

/// Pure, bounded preflight; never registers bytes or accesses a Store or Player.
ExternalCandidateMediaInspection inspectExternalCandidateMedia({
  required Uint8List bytes,
  required List<SentenceTiming> timings,
  required int sentenceCount,
}) {
  if (bytes.length > 2 * 1024 * 1024 ||
      timings.length > LearningCandidateLimits.maxSentences ||
      sentenceCount > LearningCandidateLimits.maxSentences) {
    throw const LearningStoreException(
      LearningErrorCode.candidateLimitExceeded,
    );
  }
  if (bytes.isEmpty || sentenceCount < 1 || timings.length != sentenceCount) {
    throw const LearningStoreException(LearningErrorCode.invalidInput);
  }
  final info = inspectPcmWave(bytes, strictExternal: true);
  if (info == null) {
    throw const LearningStoreException(LearningErrorCode.invalidInput);
  }
  var previous = 0;
  for (var i = 0; i < timings.length; i++) {
    final timing = timings[i];
    if (timing.sentenceIndex != i ||
        timing.startMs < previous ||
        timing.endMs <= timing.startMs ||
        timing.endMs > 60000 ||
        timing.endMs * info.byteRate > info.dataBytes * 1000) {
      throw const LearningStoreException(LearningErrorCode.invalidInput);
    }
    previous = timing.endMs;
  }
  return ExternalCandidateMediaInspection._(
    actualSha256: hashes.sha256.convert(bytes).toString(),
    byteLength: bytes.length,
    durationMs: info.durationMs,
  );
}
