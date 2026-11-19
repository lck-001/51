part of 'file_learning_store.dart';

/// Same library/snapshot/queue as FileLearningStore, not a second authority.
extension _FileLearningCandidates on FileLearningStore {
  Map<String, dynamic> get _candidates =>
      _data['candidates'] as Map<String, dynamic>;

  String _candidateString(
    Object? value,
    int maxBytes, {
    bool empty = false,
    bool singleLine = false,
  }) {
    if (value is! String) {
      _fail(LearningErrorCode.invalidInput);
    }
    final s = value as String;
    if (s.length > maxBytes) _fail(LearningErrorCode.candidateLimitExceeded);
    if (!empty && s.trim().isEmpty) _fail(LearningErrorCode.invalidInput);
    // Reject unpaired UTF-16 before UTF-8 hashing; do not replace/normalize it.
    for (var i = 0; i < s.length; i++) {
      final u = s.codeUnitAt(i);
      if (u >= 0xd800 && u <= 0xdbff) {
        if (++i >= s.length ||
            s.codeUnitAt(i) < 0xdc00 ||
            s.codeUnitAt(i) > 0xdfff) {
          _fail(LearningErrorCode.invalidInput);
        }
      } else if (u >= 0xdc00 && u <= 0xdfff) {
        _fail(LearningErrorCode.invalidInput);
      } else if (u == 127 ||
          (u >= 0x80 && u <= 0x9f) ||
          (u < 32 && (singleLine || (u != 9 && u != 10 && u != 13)))) {
        _fail(LearningErrorCode.invalidInput);
      }
    }
    if (utf8.encode(s).length > maxBytes)
      _fail(LearningErrorCode.candidateLimitExceeded);
    return s;
  }

  String _sourceTextHash(String text) {
    // Source is an already owned immutable MaterialVersion, not a body claim.
    _candidateString(text, max(text.length * 4, 1), empty: true);
    return _hash(utf8.encode(text));
  }

  List<Map<String, dynamic>> _candidateSentenceRecords(
    List<LearningSentenceInput> sentences,
  ) {
    if (sentences.isEmpty ||
        sentences.length > LearningCandidateLimits.maxSentences) {
      _fail(LearningErrorCode.candidateLimitExceeded);
    }
    var bytes = 0;
    final records = <Map<String, dynamic>>[];
    for (final sentence in sentences) {
      final english = _candidateString(
        sentence.english,
        LearningCandidateLimits.maxTextBytes,
      );
      final translation = _candidateString(
        sentence.translation,
        LearningCandidateLimits.maxTextBytes,
      );
      bytes += utf8.encode(english).length + utf8.encode(translation).length;
      if (bytes > LearningCandidateLimits.maxTextBytes)
        _fail(LearningErrorCode.candidateLimitExceeded);
      records.add({'english': english, 'translation': translation});
    }
    return records;
  }

  List<LearningSentenceInput> _candidateSentenceViews(Object? raw) {
    if (raw is! List || raw.length > LearningCandidateLimits.maxSentences) {
      _fail(LearningErrorCode.invalidInput);
    }
    final values = <LearningSentenceInput>[];
    for (final s in raw as List) {
      if (s is! Map<String, dynamic> ||
          s.keys.any((k) => k != 'english' && k != 'translation') ||
          s['english'] is! String ||
          s['translation'] is! String)
        _fail(LearningErrorCode.invalidInput);
      values.add(
        LearningSentenceInput(
          english: s['english'] as String,
          translation: s['translation'] as String,
        ),
      );
    }
    _candidateSentenceRecords(values);
    return values;
  }

  Map<String, dynamic> _declarationRecord(SourceDeclaration d) {
    final result = <String, dynamic>{
      'preparation': _candidateString(
        d.preparation,
        LearningCandidateLimits.maxDeclarationBytes,
      ),
      'provider': d.provider,
      'model': d.model,
      'modelVersion': d.modelVersion,
      'notes': d.notes,
    };
    for (final value in [d.provider, d.model, d.modelVersion, d.notes]) {
      if (value != null)
        _candidateString(
          value,
          LearningCandidateLimits.maxDeclarationBytes,
          empty: true,
        );
    }
    if (utf8.encode(jsonEncode(result)).length >
        LearningCandidateLimits.maxDeclarationBytes) {
      _fail(LearningErrorCode.candidateLimitExceeded);
    }
    return result;
  }

  SourceDeclaration _declarationView(Object? raw) {
    if (raw is! Map<String, dynamic> ||
        raw.keys.any(
          (k) => !{
            'preparation',
            'provider',
            'model',
            'modelVersion',
            'notes',
          }.contains(k),
        ))
      _fail(LearningErrorCode.invalidInput);
    final p = raw as Map<String, dynamic>;
    final d = SourceDeclaration(
      preparation: p['preparation'] as String,
      provider: p['provider'] as String?,
      model: p['model'] as String?,
      modelVersion: p['modelVersion'] as String?,
      notes: p['notes'] as String?,
    );
    _declarationRecord(d);
    return d;
  }

  DateTime _candidateTime(Object? value) {
    if (value is! String || !value.endsWith('Z'))
      _fail(LearningErrorCode.invalidInput);
    final time = DateTime.tryParse(value as String);
    if (time == null) _fail(LearningErrorCode.invalidInput);
    return time!;
  }

  Map<String, dynamic> _submissionRecord(CandidateSubmission s) {
    if (!FileLearningStore._references.hasMatch(s.integrationId) ||
        !FileLearningStore._hashes.hasMatch(s.payloadSha256) ||
        (s.transportPayloadSha256 != null &&
            !FileLearningStore._hashes.hasMatch(s.transportPayloadSha256!)) ||
        (s.transport == CandidateTransport.localCapability &&
            s.transportPayloadSha256 == null)) {
      _fail(LearningErrorCode.invalidInput);
    }
    return {
      'integrationId': s.integrationId,
      'transport': s.transport.name,
      'deliveryId': _candidateString(
        s.deliveryId,
        LearningCandidateLimits.maxDeliveryIdBytes,
        singleLine: true,
      ),
      'payloadSha256': s.payloadSha256,
      'transportPayloadSha256': s.transportPayloadSha256,
      'receivedAt': s.receivedAtUtc.toUtc().toIso8601String(),
    };
  }

  CandidateSubmission _submissionView(Object? raw) {
    if (raw is! Map<String, dynamic> ||
        raw.keys.any(
          (k) => !{
            'integrationId',
            'transport',
            'deliveryId',
            'payloadSha256',
            'transportPayloadSha256',
            'receivedAt',
          }.contains(k),
        ))
      _fail(LearningErrorCode.invalidInput);
    final p = raw as Map<String, dynamic>;
    final s = CandidateSubmission(
      integrationId: p['integrationId'] as String,
      transport: CandidateTransport.values.byName(p['transport'] as String),
      deliveryId: p['deliveryId'] as String,
      payloadSha256: p['payloadSha256'] as String,
      transportPayloadSha256: p['transportPayloadSha256'] as String?,
      receivedAtUtc: _candidateTime(p['receivedAt']),
    );
    _submissionRecord(s);
    return s;
  }

  Map<String, dynamic> _externalRecord(ExternalContentSource e) {
    _checkId(e.candidateId);
    if (e.candidateRevision < 1 ||
        !FileLearningStore._hashes.hasMatch(e.sourceTextSha256))
      _fail(LearningErrorCode.invalidInput);
    return {
      'candidateId': e.candidateId,
      'candidateRevision': e.candidateRevision,
      'sourceTextSha256': e.sourceTextSha256,
      'declaration': _declarationRecord(e.declaration),
      'submission': _submissionRecord(e.submission),
      'userEdited': e.userEdited,
      'confirmedAt': e.confirmedAtUtc.toUtc().toIso8601String(),
    };
  }

  ExternalContentSource _externalView(Object? raw) {
    if (raw is! Map<String, dynamic> ||
        raw['userEdited'] is! bool ||
        raw['candidateRevision'] is! int ||
        raw.keys.any(
          (k) => !{
            'candidateId',
            'candidateRevision',
            'sourceTextSha256',
            'declaration',
            'submission',
            'userEdited',
            'confirmedAt',
          }.contains(k),
        )) {
      _fail(LearningErrorCode.invalidInput);
    }
    final p = raw as Map<String, dynamic>;
    final e = ExternalContentSource(
      candidateId: p['candidateId'] as String,
      candidateRevision: p['candidateRevision'] as int,
      sourceTextSha256: p['sourceTextSha256'] as String,
      declaration: _declarationView(p['declaration']),
      submission: _submissionView(p['submission']),
      userEdited: p['userEdited'] as bool,
      confirmedAtUtc: _candidateTime(p['confirmedAt']),
    );
    _externalRecord(e);
    return e;
  }

  String _deliveryKey(String integration, String delivery) =>
      _hash(utf8.encode(jsonEncode([trustedOwnerId, integration, delivery])));

  Map<String, dynamic> _candidateRecord(String id) {
    _checkId(id);
    final record = _candidates[id] as Map<String, dynamic>?;
    if (record == null) _fail(LearningErrorCode.notFound);
    return record!;
  }

  LearningCandidate _candidateView(
    Map<String, dynamic> c, {
    Iterable<String> mediaIssues = const [],
  }) => LearningCandidate(
    candidateId: c['id'] as String,
    ownerId: trustedOwnerId,
    materialTitle: c['materialTitle'] as String,
    materialId: c['materialId'] as String,
    materialVersionId: c['materialVersionId'] as String,
    sourceTextSha256: c['sourceTextSha256'] as String,
    revision: c['revision'] as int,
    state: LearningCandidateState.values.byName(c['state'] as String),
    originalSentences: _candidateSentenceViews(c['originalSentences']),
    sentences: _candidateSentenceViews(c['sentences']),
    declaration: _declarationView(c['declaration']),
    submission: _submissionView(c['submission']),
    updatedAtUtc: _candidateTime(c['updatedAt']),
    userEdited: c['userEdited'] as bool,
    confirmedLearningVersionId: c['confirmedLearningVersionId'] as String?,
    confirmedRevision: c['confirmedRevision'] as int?,
    mediaReview: this._mediaReviewRecord(c, issues: mediaIssues),
  );

  void _candidateQuota(Map<String, dynamic> record, {String? replacing}) {
    var total = utf8.encode(jsonEncode(record)).length;
    var pending = record['state'] == 'pendingReview' ? 1 : 0;
    for (final entry in _candidates.entries) {
      if (entry.key == replacing) continue;
      total += utf8.encode(jsonEncode(entry.value)).length;
      if ((entry.value as Map<String, dynamic>)['state'] == 'pendingReview')
        pending++;
      if (total > LearningCandidateLimits.maxStoredCandidateBytes)
        _fail(LearningErrorCode.candidateLimitExceeded);
    }
    if (total > LearningCandidateLimits.maxStoredCandidateBytes ||
        pending > LearningCandidateLimits.maxPendingCandidates) {
      _fail(LearningErrorCode.candidateLimitExceeded);
    }
  }

  Future<MaterialVersion> _candidateSource(
    String materialId,
    String versionId,
    String textHash,
  ) async {
    _checkId(materialId);
    _checkId(versionId);
    if (!FileLearningStore._hashes.hasMatch(textHash))
      _fail(LearningErrorCode.invalidInput);
    MaterialVersion source;
    try {
      source = await _materials.readVersion(versionId);
    } on MaterialStoreException {
      _fail(LearningErrorCode.notFound);
      rethrow;
    }
    if (source.ownerId != trustedOwnerId ||
        source.materialId != materialId ||
        source.versionId != versionId ||
        _sourceTextHash(source.text) != textHash) {
      _fail(LearningErrorCode.bindingMismatch);
    }
    return source;
  }

  Future<CandidateDeliveryReceipt> _receiveCandidate(
    CandidateSender sender,
    LearningCandidateInput input, {
    LearningCandidateMediaInput? media,
  }) async {
    _writable();
    if (media != null) this._mediaGate();
    if (!FileLearningStore._references.hasMatch(sender.integrationId))
      _fail(LearningErrorCode.invalidInput);
    final sentences = _candidateSentenceRecords(input.sentences);
    final declaration = _declarationRecord(input.declaration);
    final delivery = _candidateString(
      input.deliveryId,
      LearningCandidateLimits.maxDeliveryIdBytes,
      singleLine: true,
    );
    _checkId(input.materialId);
    _checkId(input.materialVersionId);
    if (!FileLearningStore._hashes.hasMatch(input.sourceTextSha256))
      _fail(LearningErrorCode.invalidInput);
    final mediaRecord = media == null ? null : this._mediaRecord(media);
    if (mediaRecord != null) {
      if (this._englishHash(sentences) != media!.englishSha256 ||
          media.timings.length != sentences.length)
        _fail(LearningErrorCode.bindingMismatch);
      await _candidateSource(
        input.materialId,
        input.materialVersionId,
        input.sourceTextSha256,
      );
      await this._verifyMediaBytes(
        mediaRecord,
        sentenceCount: sentences.length,
      );
    }
    final payloadHash = _hash(
      utf8.encode(
        jsonEncode({
          'schema': mediaRecord == null ? 1 : 2,
          'materialId': input.materialId,
          'materialVersionId': input.materialVersionId,
          'sourceTextSha256': input.sourceTextSha256,
          'deliveryId': delivery,
          'sentences': sentences,
          'declaration': declaration,
          if (mediaRecord != null) 'media': this._mediaPayload(mediaRecord),
        }),
      ),
    );
    final submission = CandidateSubmission(
      integrationId: sender.integrationId,
      transport: sender.transport,
      deliveryId: delivery,
      payloadSha256: payloadHash,
      transportPayloadSha256: sender.transportPayloadSha256,
      receivedAtUtc: DateTime.now().toUtc(),
    );
    final submissionRecord = _submissionRecord(submission);
    final key = _deliveryKey(sender.integrationId, delivery);
    final old =
        (_data['candidateDeliveries'] as Map<String, dynamic>)[key] as String?;
    if (old != null) {
      final candidate = _candidateRecord(old);
      if ((candidate['submission'] as Map<String, dynamic>)['payloadSha256'] !=
          payloadHash) {
        _fail(LearningErrorCode.deliveryConflict);
      }
      return CandidateDeliveryReceipt(
        candidateId: old,
        payloadSha256: payloadHash,
        replayed: true,
      );
    }
    final source = await _candidateSource(
      input.materialId,
      input.materialVersionId,
      input.sourceTextSha256,
    );
    final id = _id();
    final record = <String, dynamic>{
      'id': id,
      'ownerId': trustedOwnerId,
      'materialId': source.materialId,
      'materialVersionId': source.versionId,
      'materialTitle': source.title,
      'sourceTextSha256': input.sourceTextSha256,
      'revision': 1,
      'state': 'pendingReview',
      'originalSentences': sentences,
      'sentences': sentences,
      'declaration': declaration,
      'submission': submissionRecord,
      'updatedAt': submissionRecord['receivedAt'],
      'userEdited': false,
      if (mediaRecord != null) 'inputVersion': 2,
      if (mediaRecord != null) 'originalMedia': mediaRecord,
    };
    _candidateQuota(record);
    final next = _copy();
    (next['candidates'] as Map<String, dynamic>)[id] = record;
    (next['candidateDeliveries'] as Map<String, dynamic>)[key] = id;
    if (mediaRecord != null) this._mediaGate();
    await _commit(next);
    return CandidateDeliveryReceipt(
      candidateId: id,
      payloadSha256: payloadHash,
      replayed: false,
    );
  }

  void _candidateRevision(Map<String, dynamic> c, int expected) {
    if (expected < 1) _fail(LearningErrorCode.invalidInput);
    if (c['revision'] != expected) _fail(LearningErrorCode.revisionConflict);
  }

  Future<LearningCandidate> _reviseCandidate(
    String id,
    int expected,
    List<LearningSentenceInput> sentences,
  ) async {
    _writable();
    final old = _candidateRecord(id);
    _candidateRevision(old, expected);
    if ((old['inputVersion'] ?? 1) == 2) this._mediaGate();
    if (old['state'] != 'pendingReview') _fail(LearningErrorCode.invalidState);
    final values = _candidateSentenceRecords(sentences);
    final record = jsonDecode(jsonEncode(old)) as Map<String, dynamic>;
    record['sentences'] = values;
    record['revision'] = expected + 1;
    if ((old['inputVersion'] ?? 1) == 2 &&
        !old.containsKey('mediaInvalidation')) {
      final oldEnglish = this
          ._candidateSentenceRecords(
            this._candidateSentenceViews(old['sentences']),
          )
          .map((s) => s['english'])
          .toList();
      if (jsonEncode(oldEnglish) !=
          jsonEncode(values.map((s) => s['english']).toList())) {
        record['mediaInvalidation'] = {
          'firstRevision': expected + 1,
          'englishSha256': this._englishHash(values),
        };
      }
    }
    record['userEdited'] =
        jsonEncode(values) != jsonEncode(record['originalSentences']);
    record['updatedAt'] = DateTime.now().toUtc().toIso8601String();
    _candidateQuota(record, replacing: id);
    final next = _copy();
    (next['candidates'] as Map<String, dynamic>)[id] = record;
    if ((old['inputVersion'] ?? 1) == 2) this._mediaGate();
    await _commit(next);
    return _candidateView(record);
  }

  Future<LearningVersion> _confirmCandidate(String id, int expected) async {
    _writable();
    final old = _candidateRecord(id);
    _candidateRevision(old, expected);
    if ((old['inputVersion'] ?? 1) == 2) this._mediaGate();
    if (old['state'] == 'rejected') _fail(LearningErrorCode.invalidState);
    if (old['state'] == 'confirmed') {
      // Link integrity was validated on load/commit, and is checked before use.
      _validateCandidates(_data);
      if ((old['inputVersion'] ?? 1) == 2) {
        await _candidateSource(
          old['materialId'] as String,
          old['materialVersionId'] as String,
          old['sourceTextSha256'] as String,
        );
        if (!old.containsKey('mediaInvalidation'))
          await this._verifyMediaBytes(
            old['originalMedia'] as Map<String, dynamic>,
            sentenceCount: (old['originalSentences'] as List).length,
          );
        this._mediaGate();
      }
      return _view(_record(old['confirmedLearningVersionId'] as String));
    }
    final source = await _candidateSource(
      old['materialId'] as String,
      old['materialVersionId'] as String,
      old['sourceTextSha256'] as String,
    );
    final media =
        (old['inputVersion'] ?? 1) == 2 && !old.containsKey('mediaInvalidation')
        ? this._mediaInput(old['originalMedia'])
        : null;
    if (media != null)
      await this._verifyMediaBytes(
        old['originalMedia'] as Map<String, dynamic>,
        sentenceCount: (old['originalSentences'] as List).length,
      );
    final time = DateTime.now().toUtc();
    final external = ExternalContentSource(
      candidateId: id,
      candidateRevision: expected,
      sourceTextSha256: old['sourceTextSha256'] as String,
      declaration: _declarationView(old['declaration']),
      submission: _submissionView(old['submission']),
      userEdited: old['userEdited'] as bool,
      confirmedAtUtc: time,
    );
    final version = _buildVersionRecord(
      source: source,
      media: media == null
          ? null
          : LearningMediaInput(
              artifact: media.artifact,
              provenance: ContentProvenance(
                origin: ContentOrigin.external,
                reference: 'candidate:$id:$expected',
                external: external,
              ),
              timings: media.timings,
            ),
      allowExternalMedia: media != null,
      sentences: _candidateSentenceViews(old['sentences']),
      textProvenance: ContentProvenance(
        origin: ContentOrigin.external,
        reference: 'candidate:$id:$expected',
        external: external,
      ),
      allowExternal: true,
      createdAtUtc: time,
    );
    if (media != null) {
      (version['media'] as Map<String, dynamic>)['externalDetails'] = {
        'englishSha256': media.englishSha256,
        'declaration': this._declarationRecord(media.declaration),
        'timingDeclaration': media.timingDeclaration,
      };
    }
    final record = jsonDecode(jsonEncode(old)) as Map<String, dynamic>;
    record['state'] = 'confirmed';
    record['confirmedLearningVersionId'] = version['id'];
    record['confirmedRevision'] = expected;
    record['confirmedAt'] = time.toIso8601String();
    record['updatedAt'] = time.toIso8601String();
    _candidateQuota(record, replacing: id);
    final next = _copy();
    (next['candidates'] as Map<String, dynamic>)[id] = record;
    (next['versions'] as Map<String, dynamic>)[version['id'] as String] =
        version;
    if ((old['inputVersion'] ?? 1) == 2) this._mediaGate();
    await _commit(next);
    return _view(version);
  }

  Future<LearningCandidate> _rejectCandidate(String id, int expected) async {
    _writable();
    final old = _candidateRecord(id);
    _candidateRevision(old, expected);
    if ((old['inputVersion'] ?? 1) == 2) this._mediaGate();
    if (old['state'] == 'confirmed') _fail(LearningErrorCode.invalidState);
    if (old['state'] == 'rejected') return _candidateView(old);
    final record = jsonDecode(jsonEncode(old)) as Map<String, dynamic>;
    record['state'] = 'rejected';
    record['updatedAt'] = DateTime.now().toUtc().toIso8601String();
    _candidateQuota(record, replacing: id);
    final next = _copy();
    (next['candidates'] as Map<String, dynamic>)[id] = record;
    if ((old['inputVersion'] ?? 1) == 2) this._mediaGate();
    await _commit(next);
    return _candidateView(record);
  }

  void _validateCandidates(Map<String, dynamic> p, {int schema = 3}) {
    void bad() => throw const FormatException('invalid_candidate_manifest');
    try {
      if (p['candidates'] is! Map<String, dynamic> ||
          p['candidateDeliveries'] is! Map<String, dynamic>)
        bad();
      final candidates = p['candidates'] as Map<String, dynamic>;
      final deliveries = p['candidateDeliveries'] as Map<String, dynamic>;
      final versions = p['versions'] as Map<String, dynamic>;
      if (deliveries.length != candidates.length) bad();
      var total = 0, pending = 0;
      for (final entry in candidates.entries) {
        final c = entry.value;
        if (c is! Map<String, dynamic> ||
            c['id'] != entry.key ||
            c['ownerId'] != trustedOwnerId ||
            c['revision'] is! int ||
            (c['revision'] as int) < 1 ||
            c['userEdited'] is! bool ||
            c['materialTitle'] is! String ||
            c.containsKey('media'))
          bad();
        if (c.keys.any(
          (k) => !{
            'id',
            'ownerId',
            'materialId',
            'materialVersionId',
            'materialTitle',
            'sourceTextSha256',
            'revision',
            'state',
            'originalSentences',
            'sentences',
            'declaration',
            'submission',
            'updatedAt',
            'userEdited',
            'confirmedLearningVersionId',
            'confirmedRevision',
            'confirmedAt',
            'inputVersion',
            'originalMedia',
            'mediaInvalidation',
          }.contains(k),
        ))
          bad();
        if (schema < 3 &&
            (c.containsKey('inputVersion') ||
                c.containsKey('originalMedia') ||
                c.containsKey('mediaInvalidation')))
          bad();
        this._validateMediaCandidate(c);
        _checkId(entry.key);
        _checkId(c['materialId'] as String);
        _checkId(c['materialVersionId'] as String);
        if (!FileLearningStore._hashes.hasMatch(
          c['sourceTextSha256'] as String,
        ))
          bad();
        final candidate = _candidateView(c);
        final original = _candidateSentenceRecords(candidate.originalSentences);
        final current = _candidateSentenceRecords(candidate.sentences);
        if (candidate.userEdited !=
            (jsonEncode(original) != jsonEncode(current)))
          bad();
        final expectedKey = _deliveryKey(
          candidate.submission.integrationId,
          candidate.submission.deliveryId,
        );
        if (deliveries[expectedKey] != entry.key) bad();
        final expectedHash = _hash(
          utf8.encode(
            jsonEncode({
              'schema': (c['inputVersion'] ?? 1) == 2 ? 2 : 1,
              'materialId': candidate.materialId,
              'materialVersionId': candidate.materialVersionId,
              'sourceTextSha256': candidate.sourceTextSha256,
              'deliveryId': candidate.submission.deliveryId,
              'sentences': original,
              'declaration': _declarationRecord(candidate.declaration),
              if ((c['inputVersion'] ?? 1) == 2)
                'media': this._mediaPayload(
                  c['originalMedia'] as Map<String, dynamic>,
                ),
            }),
          ),
        );
        if (expectedHash != candidate.submission.payloadSha256) bad();
        if (candidate.state == LearningCandidateState.confirmed) {
          if (candidate.confirmedRevision != candidate.revision ||
              candidate.confirmedLearningVersionId == null)
            bad();
          final v = versions[candidate.confirmedLearningVersionId];
          if (v is! Map<String, dynamic> ||
              v['materialId'] != candidate.materialId ||
              v['materialVersionId'] != candidate.materialVersionId ||
              v['materialTitle'] != candidate.materialTitle ||
              v['createdAt'] != c['confirmedAt'])
            bad();
          this._validateMediaConfirmation(c, v);
          final provenance = v['textProvenance'] as Map<String, dynamic>;
          if (provenance['origin'] != 'external' ||
              provenance['reference'] !=
                  'candidate:${candidate.candidateId}:${candidate.revision}')
            bad();
          final expectedExternal = ExternalContentSource(
            candidateId: candidate.candidateId,
            candidateRevision: candidate.revision,
            sourceTextSha256: candidate.sourceTextSha256,
            declaration: candidate.declaration,
            submission: candidate.submission,
            userEdited: candidate.userEdited,
            confirmedAtUtc: _candidateTime(c['confirmedAt']),
          );
          if (jsonEncode(provenance['external']) !=
              jsonEncode(_externalRecord(expectedExternal)))
            bad();
          final versionText = (v['sentences'] as List)
              .map(
                (s) => {
                  'english': s['english'],
                  'translation': s['translation'],
                },
              )
              .toList();
          if (jsonEncode(versionText) != jsonEncode(current)) bad();
        } else {
          if (c.containsKey('confirmedLearningVersionId') ||
              c.containsKey('confirmedRevision') ||
              c.containsKey('confirmedAt'))
            bad();
          if (candidate.state == LearningCandidateState.pendingReview)
            pending++;
        }
        total += utf8.encode(jsonEncode(c)).length;
        if (total > LearningCandidateLimits.maxStoredCandidateBytes) bad();
      }
      if (pending > LearningCandidateLimits.maxPendingCandidates) bad();
      for (final entry in deliveries.entries) {
        if (!FileLearningStore._hashes.hasMatch(entry.key) ||
            entry.value is! String ||
            !candidates.containsKey(entry.value))
          bad();
      }
      for (final v in versions.values) {
        final record = v as Map<String, dynamic>;
        final provenance = record['textProvenance'] as Map<String, dynamic>;
        if (provenance['origin'] != 'external') continue;
        final external = _externalView(provenance['external']);
        final candidate = candidates[external.candidateId];
        if (candidate is! Map<String, dynamic> ||
            candidate['state'] != 'confirmed' ||
            candidate['confirmedLearningVersionId'] != record['id'] ||
            candidate['confirmedRevision'] != external.candidateRevision)
          bad();
      }
    } on FormatException {
      rethrow;
    } catch (_) {
      bad();
    }
  }
}
