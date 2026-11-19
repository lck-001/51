part of 'file_learning_store.dart';

extension _FileLearningMediaCandidates on FileLearningStore {
  bool _digest(String value) =>
      value.length == 64 && FileLearningStore._hashes.hasMatch(value);

  String _englishHash(List<Map<String, dynamic>> sentences) => _hash(
    utf8.encode(jsonEncode(sentences.map((s) => s['english']).toList())),
  );

  void _mediaGate() {
    _writable();
    if (_materials.recoveryReport.issues.any(
          (i) => i.kind == RecoveryIssueKind.registrationHold,
        ) ||
        _materials.recoveryReport.status == RecoveryStatus.unrecoverable ||
        _materials.recoveryReport.status ==
            RecoveryStatus.recoveredFromBackup) {
      _fail(LearningErrorCode.recoveryHold);
    }
  }

  Map<String, dynamic> _mediaRecord(LearningCandidateMediaInput input) {
    final a = input.artifact;
    if (a.ownerId != trustedOwnerId) _fail(LearningErrorCode.ownerMismatch);
    _checkId(a.artifactId);
    if (a.byteLength < 46 ||
        a.byteLength > 2 * 1024 * 1024 ||
        a.byteLength - 44 > 1920000 ||
        (a.byteLength - 44).isOdd ||
        !_digest(a.sha256) ||
        !_digest(input.englishSha256))
      _fail(LearningErrorCode.invalidInput);
    final declaration = this._declarationRecord(input.declaration);
    final timingDeclaration = this._candidateString(
      input.timingDeclaration,
      LearningCandidateLimits.maxDeclarationBytes,
    );
    if (utf8.encode(jsonEncode(declaration)).length +
            utf8.encode(timingDeclaration).length >
        LearningCandidateLimits.maxDeclarationBytes)
      _fail(LearningErrorCode.candidateLimitExceeded);
    if (input.timings.isEmpty ||
        input.timings.length > LearningCandidateLimits.maxSentences)
      _fail(LearningErrorCode.invalidInput);
    var previous = 0;
    final timings = <Map<String, dynamic>>[];
    for (var i = 0; i < input.timings.length; i++) {
      final t = input.timings[i];
      if (t.sentenceIndex != i ||
          t.startMs < previous ||
          t.endMs <= t.startMs ||
          t.endMs > 60000 ||
          t.endMs * 32000 > (a.byteLength - 44) * 1000)
        _fail(LearningErrorCode.invalidInput);
      timings.add({
        'sentenceIndex': t.sentenceIndex,
        'startMs': t.startMs,
        'endMs': t.endMs,
      });
      previous = t.endMs;
    }
    return {
      'artifact': _artifactRecord(a),
      'englishSha256': input.englishSha256,
      'declaration': declaration,
      'timingDeclaration': timingDeclaration,
      'timings': timings,
    };
  }

  LearningCandidateMediaInput _mediaInput(Object? raw) {
    if (raw is! Map<String, dynamic> ||
        raw.length != 5 ||
        raw['artifact'] is! Map<String, dynamic> ||
        (raw['artifact'] as Map).length != 4 ||
        raw['timings'] is! List ||
        (raw['timings'] as List).length >
            LearningCandidateLimits.maxSentences) {
      _fail(LearningErrorCode.invalidInput);
    }
    final m = raw as Map<String, dynamic>;
    final timings = <SentenceTiming>[];
    for (final t in m['timings'] as List) {
      if (t is! Map<String, dynamic> ||
          t.length != 3 ||
          t['sentenceIndex'] is! int ||
          t['startMs'] is! int ||
          t['endMs'] is! int)
        _fail(LearningErrorCode.invalidInput);
      timings.add(
        SentenceTiming(
          sentenceIndex: t['sentenceIndex'] as int,
          startMs: t['startMs'] as int,
          endMs: t['endMs'] as int,
        ),
      );
    }
    final input = LearningCandidateMediaInput(
      artifact: _artifact(m['artifact'] as Map<String, dynamic>),
      englishSha256: m['englishSha256'] as String,
      declaration: this._declarationView(m['declaration']),
      timingDeclaration: m['timingDeclaration'] as String,
      timings: timings,
    );
    if (jsonEncode(_mediaRecord(input)) != jsonEncode(m))
      _fail(LearningErrorCode.invalidInput);
    return input;
  }

  Map<String, dynamic> _mediaPayload(Map<String, dynamic> m) {
    final a = m['artifact'] as Map<String, dynamic>;
    return {
      'sha256': a['sha256'],
      'byteLength': a['byteLength'],
      'englishSha256': m['englishSha256'],
      'pcm': {
        'format': 1,
        'channels': 1,
        'sampleRate': 16000,
        'bitsPerSample': 16,
      },
      'timings': m['timings'],
      'declaration': m['declaration'],
      'timingDeclaration': m['timingDeclaration'],
    };
  }

  Future<void> _verifyMediaBytes(
    Map<String, dynamic> media, {
    required int sentenceCount,
  }) async {
    final input = _mediaInput(media);
    Uint8List bytes;
    try {
      bytes = await _materials.readArtifact(input.artifact);
    } on MaterialStoreException {
      _fail(LearningErrorCode.mediaUnavailable);
      rethrow;
    }
    if (bytes.length != input.artifact.byteLength)
      _fail(LearningErrorCode.mediaUnavailable);
    final inspection = inspectExternalCandidateMedia(
      bytes: bytes,
      timings: input.timings,
      sentenceCount: sentenceCount,
    );
    if (inspection.byteLength != input.artifact.byteLength ||
        inspection.actualSha256 != input.artifact.sha256) {
      _fail(LearningErrorCode.mediaUnavailable);
    }
  }

  LearningCandidateMediaReview? _mediaReviewRecord(
    Map<String, dynamic> c, {
    Iterable<String> issues = const [],
  }) {
    if ((c['inputVersion'] ?? 1) != 2) return null;
    final invalidation = c['mediaInvalidation'] as Map<String, dynamic>?;
    return LearningCandidateMediaReview(
      original: _mediaInput(c['originalMedia']),
      currentEnglishSha256: _englishHash(
        this._candidateSentenceRecords(
          this._candidateSentenceViews(c['sentences']),
        ),
      ),
      binding: invalidation == null
          ? CandidateMediaBinding.matched
          : CandidateMediaBinding.invalidated,
      invalidatedAtRevision: invalidation?['firstRevision'] as int?,
      firstInvalidatedEnglishSha256: invalidation?['englishSha256'] as String?,
      issues: [if (invalidation != null) 'media_english_changed', ...issues],
    );
  }

  Future<List<String>> _mediaIssues(Map<String, dynamic> c) async {
    if ((c['inputVersion'] ?? 1) != 2) return const [];
    try {
      await _verifyMediaBytes(
        c['originalMedia'] as Map<String, dynamic>,
        sentenceCount: (c['originalSentences'] as List).length,
      );
      return const [];
    } on LearningStoreException catch (e) {
      return [
        e.code == LearningErrorCode.mediaUnavailable
            ? 'media_unavailable'
            : 'media_unverified',
      ];
    }
  }

  void _validateMediaCandidate(Map<String, dynamic> c) {
    final version = c['inputVersion'] ?? 1;
    if (c.containsKey('inputVersion') && c['inputVersion'] is! int)
      _fail(LearningErrorCode.invalidInput);
    if (version == 1) {
      if (c.containsKey('originalMedia') || c.containsKey('mediaInvalidation'))
        _fail(LearningErrorCode.invalidInput);
      return;
    }
    if (version != 2) _fail(LearningErrorCode.invalidInput);
    final original = this._candidateSentenceRecords(
      this._candidateSentenceViews(c['originalSentences']),
    );
    final current = this._candidateSentenceRecords(
      this._candidateSentenceViews(c['sentences']),
    );
    final media = _mediaInput(c['originalMedia']);
    if (media.englishSha256 != _englishHash(original) ||
        media.timings.length != original.length)
      _fail(LearningErrorCode.invalidInput);
    if (c.containsKey('mediaInvalidation')) {
      final i = c['mediaInvalidation'];
      if (i is! Map<String, dynamic> ||
          i.length != 2 ||
          i['firstRevision'] is! int ||
          (i['firstRevision'] as int) < 2 ||
          (i['firstRevision'] as int) > (c['revision'] as int) ||
          i['englishSha256'] is! String ||
          !_digest(i['englishSha256'] as String) ||
          i['englishSha256'] == media.englishSha256)
        _fail(LearningErrorCode.invalidInput);
    } else if (_englishHash(current) != media.englishSha256 ||
        jsonEncode(original.map((s) => s['english']).toList()) !=
            jsonEncode(current.map((s) => s['english']).toList())) {
      _fail(LearningErrorCode.invalidInput);
    }
  }

  void _validateMediaConfirmation(
    Map<String, dynamic> c,
    Map<String, dynamic> v,
  ) {
    final version = c['inputVersion'] ?? 1;
    if (version == 1 || c.containsKey('mediaInvalidation')) {
      if (v['media'] != null) _fail(LearningErrorCode.invalidInput);
      return;
    }
    final original = c['originalMedia'] as Map<String, dynamic>;
    final m = v['media'];
    if (m is! Map<String, dynamic> ||
        m.length != 5 ||
        jsonEncode(m['artifact']) != jsonEncode(original['artifact']) ||
        jsonEncode(m['timings']) != jsonEncode(original['timings']) ||
        jsonEncode(m['provenance']) != jsonEncode(v['textProvenance']) ||
        jsonEncode(m['externalDetails']) !=
            jsonEncode({
              'englishSha256': original['englishSha256'],
              'declaration': original['declaration'],
              'timingDeclaration': original['timingDeclaration'],
            })) {
      _fail(LearningErrorCode.invalidInput);
    }
  }
}
