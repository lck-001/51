import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;
import 'package:material_core/material_core.dart';
import 'package:playback_core/playback_core.dart';

import '../learning_core.dart';
import 'pcm_wave.dart';

part 'file_learning_candidates.dart';
part 'file_learning_media_candidates.dart';

/// File-backed single-writer experiment; never opens a player or calls AI.
final class FileLearningStore
    implements
        LearningStore,
        LearningCandidateStore,
        LearningMediaCandidateStore {
  FileLearningStore._(this._root, this._materials);
  static Future<FileLearningStore> open({
    required Directory root,
    required MaterialStore materials,
  }) async {
    final store = FileLearningStore._(root.absolute, materials);
    try {
      await store._load();
      return store;
    } on LearningStoreException {
      rethrow;
    } catch (_) {
      throw const LearningStoreException(LearningErrorCode.corruptStore);
    }
  }

  final Directory _root;
  final MaterialStore _materials;
  late Directory _partition;
  late Map<String, dynamic> _data;
  late LearningRecoveryReport _report;
  Future<void> _tail = Future<void>.value();
  bool _closed = false, _writeBlocked = false;
  String? _hold;
  LearningPlaybackSession? _active;
  final Random _random = Random.secure();
  final Map<String, int> _snapshotSchemas = {};
  static final _ids = RegExp(r'^[0-9a-f]{32}$');
  static final _hashes = RegExp(r'^[0-9a-f]{64}$');
  static final _references = RegExp(r'^[A-Za-z0-9:_-]{1,160}$');
  @override
  String get trustedOwnerId => _materials.trustedOwnerId;
  @override
  LearningRecoveryReport get recoveryReport => _report;
  Map<String, dynamic> get _versions =>
      _data['versions'] as Map<String, dynamic>;
  Map<String, dynamic> get _checkpoints =>
      _data['checkpoints'] as Map<String, dynamic>;
  String _hash(List<int> value) => hashes.sha256.convert(value).toString();
  String _id() => List.generate(
    16,
    (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  void _fail(LearningErrorCode code) => throw LearningStoreException(code);
  void _checkId(String value) {
    if (!_ids.hasMatch(value)) _fail(LearningErrorCode.invalidId);
  }

  File _file(String name) => File('${_partition.path}/$name');
  Map<String, dynamic> _copy() =>
      jsonDecode(jsonEncode(_data)) as Map<String, dynamic>;
  Future<T> _run<T>(Future<T> Function() body) {
    final result = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        if (_closed) _fail(LearningErrorCode.closed);
        result.complete(await body());
      } catch (e, st) {
        result.completeError(e, st);
      }
    });
    return result.future;
  }

  Future<void> _directory(Directory dir) async {
    final type = await FileSystemEntity.type(dir.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      await dir.create(recursive: true);
    } else if (type != FileSystemEntityType.directory) {
      _fail(LearningErrorCode.corruptStore);
    }
  }

  Future<bool> _regular(File file) async {
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return false;
    if (type != FileSystemEntityType.file)
      _fail(LearningErrorCode.corruptStore);
    return true;
  }

  Map<String, dynamic> _provenance(
    ContentProvenance p, {
    bool allowExternal = false,
  }) {
    if (!_references.hasMatch(p.reference))
      _fail(LearningErrorCode.invalidInput);
    if (p.origin == ContentOrigin.external) {
      if (!allowExternal || p.external == null)
        _fail(LearningErrorCode.invalidInput);
      return {
        'origin': p.origin.name,
        'reference': p.reference,
        'external': this._externalRecord(p.external!),
      };
    }
    if (p.external != null) _fail(LearningErrorCode.invalidInput);
    return {'origin': p.origin.name, 'reference': p.reference};
  }

  ContentProvenance _provenanceView(Map<String, dynamic> p) =>
      ContentProvenance(
        origin: ContentOrigin.values.byName(p['origin'] as String),
        reference: p['reference'] as String,
        external: p['external'] == null
            ? null
            : this._externalView(p['external']),
      );
  ArtifactRef _artifact(Map<String, dynamic> p) => ArtifactRef(
    ownerId: p['ownerId'] as String,
    artifactId: p['artifactId'] as String,
    byteLength: p['byteLength'] as int,
    sha256: p['sha256'] as String,
  );
  Map<String, dynamic> _artifactRecord(ArtifactRef r) => {
    'ownerId': r.ownerId,
    'artifactId': r.artifactId,
    'byteLength': r.byteLength,
    'sha256': r.sha256,
  };
  LearningBinding _binding(Map<String, dynamic> v) => LearningBinding(
    ownerId: trustedOwnerId,
    materialId: v['materialId'] as String,
    materialVersionId: v['materialVersionId'] as String,
    learningVersionId: v['id'] as String,
    mediaVersionId: (v['media'] as Map<String, dynamic>?)?['id'] as String?,
  );
  Map<String, dynamic> _bindingRecord(LearningBinding b) => {
    'ownerId': b.ownerId,
    'materialId': b.materialId,
    'materialVersionId': b.materialVersionId,
    'learningVersionId': b.learningVersionId,
    'mediaVersionId': b.mediaVersionId,
  };
  LearningBinding _bindingView(Map<String, dynamic> b) => LearningBinding(
    ownerId: b['ownerId'] as String,
    materialId: b['materialId'] as String,
    materialVersionId: b['materialVersionId'] as String,
    learningVersionId: b['learningVersionId'] as String,
    mediaVersionId: b['mediaVersionId'] as String?,
  );
  void _validate(
    Map<String, dynamic> p, {
    bool legacy = false,
    int schema = 3,
  }) {
    bool id(Object? v) => v is String && _ids.hasMatch(v);
    bool time(Object? v) =>
        v is String && v.endsWith('Z') && DateTime.tryParse(v) != null;
    bool provenance(Object? v) {
      if (v is! Map<String, dynamic> ||
          !ContentOrigin.values.any((e) => e.name == v['origin']) ||
          v['reference'] is! String ||
          !_references.hasMatch(v['reference'] as String))
        return false;
      if (v.keys.any((k) => !{'origin', 'reference', 'external'}.contains(k)))
        return false;
      if (v['origin'] == 'external') {
        if (legacy || v['external'] == null) return false;
        try {
          this._externalView(v['external']);
        } catch (_) {
          return false;
        }
      } else if (v['external'] != null) {
        return false;
      }
      return true;
    }

    void bad() => throw const FormatException('invalid_learning_manifest');
    if (p['ownerId'] != trustedOwnerId ||
        p['sequence'] is! int ||
        (p['sequence'] as int) < 0 ||
        p['versions'] is! Map<String, dynamic> ||
        p['checkpoints'] is! Map<String, dynamic>)
      bad();
    final versions = p['versions'] as Map<String, dynamic>;
    for (final e in versions.entries) {
      final v = e.value;
      if (!id(e.key) ||
          v is! Map<String, dynamic> ||
          v['id'] != e.key ||
          !id(v['materialId']) ||
          !id(v['materialVersionId']) ||
          !id(v['unitId']) ||
          v['materialTitle'] is! String ||
          !provenance(v['textProvenance']) ||
          !time(v['createdAt']) ||
          v['sentences'] is! List)
        bad();
      if (v.keys.any(
        (k) => !{
          'id',
          'materialId',
          'materialVersionId',
          'materialTitle',
          'unitId',
          'textProvenance',
          'sentences',
          'media',
          'createdAt',
        }.contains(k),
      ))
        bad();
      final seen = <String>{};
      for (final s in v['sentences'] as List) {
        if (s is! Map<String, dynamic> ||
            s.keys.any((k) => !{'id', 'english', 'translation'}.contains(k)) ||
            !id(s['id']) ||
            !seen.add(s['id'] as String) ||
            s['english'] is! String ||
            s['translation'] is! String)
          bad();
      }
      final m = v['media'];
      if (m != null) {
        if (m is! Map<String, dynamic> ||
            !id(m['id']) ||
            !provenance(m['provenance']) ||
            m['artifact'] is! Map<String, dynamic> ||
            m['timings'] is! List)
          bad();
        if ((m['provenance'] as Map<String, dynamic>)['origin'] == 'external' &&
            (v['textProvenance'] as Map<String, dynamic>)['origin'] !=
                'external')
          bad();
        // B1 introduces external text only. No external-media record can be
        // manufactured through a schema2 snapshot to bypass that restriction.
        if ((m['provenance'] as Map<String, dynamic>)['origin'] == 'external' &&
            schema < 3)
          bad();
        if ((m['provenance'] as Map<String, dynamic>)['origin'] != 'external' &&
            m.containsKey('externalDetails'))
          bad();
        if (m.keys.any(
          (k) => !{
            'id',
            'artifact',
            'provenance',
            'timings',
            'externalDetails',
          }.contains(k),
        ))
          bad();
        final a = m['artifact'] as Map<String, dynamic>;
        if (a.keys.any(
          (k) => !{'ownerId', 'artifactId', 'byteLength', 'sha256'}.contains(k),
        ))
          bad();
        if (a['ownerId'] != trustedOwnerId ||
            !id(a['artifactId']) ||
            a['byteLength'] is! int ||
            (a['byteLength'] as int) < 0 ||
            a['sha256'] is! String ||
            !_hashes.hasMatch(a['sha256'] as String))
          bad();
        for (final t in m['timings'] as List) {
          if (t is! Map<String, dynamic> ||
              t.keys.any(
                (k) => !{'sentenceIndex', 'startMs', 'endMs'}.contains(k),
              ) ||
              t['sentenceIndex'] is! int ||
              t['startMs'] is! int ||
              t['endMs'] is! int)
            bad();
        }
      }
    }
    for (final e in (p['checkpoints'] as Map<String, dynamic>).entries) {
      final c = e.value;
      if (!id(e.key) ||
          !versions.containsKey(e.key) ||
          c is! Map<String, dynamic> ||
          c['binding'] is! Map<String, dynamic> ||
          c['revision'] is! int ||
          (c['revision'] as int) < 1 ||
          c['positionMs'] is! int ||
          (c['positionMs'] as int) < 0 ||
          !id(c['sentenceId']) ||
          c['resumeIntent'] != 'paused' ||
          !time(c['savedAt']))
        bad();
      if (c.keys.any(
            (k) => !{
              'binding',
              'revision',
              'positionMs',
              'sentenceId',
              'resumeIntent',
              'savedAt',
            }.contains(k),
          ) ||
          (c['binding'] as Map).keys.any(
            (k) => !{
              'ownerId',
              'materialId',
              'materialVersionId',
              'learningVersionId',
              'mediaVersionId',
            }.contains(k),
          ))
        bad();
      final v = versions[e.key] as Map<String, dynamic>;
      if (!_binding(v)
              .sameAs(_bindingView(c['binding'] as Map<String, dynamic>)) ||
          !(v['sentences'] as List).any((s) => s['id'] == c['sentenceId']))
        bad();
    }
    if (legacy) {
      if (p.containsKey('candidates') || p.containsKey('candidateDeliveries'))
        bad();
    } else {
      this._validateCandidates(p, schema: schema);
    }
  }

  Future<Map<String, dynamic>?> _snapshot(File file) async {
    if (!await _regular(file)) return null;
    final envelope =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    if ((envelope['schema'] != 1 &&
            envelope['schema'] != 2 &&
            envelope['schema'] != 3) ||
        envelope['payload'] is! Map<String, dynamic>) {
      throw const FormatException('invalid_learning_manifest');
    }
    final p = envelope['payload'] as Map<String, dynamic>;
    if (envelope['sha256'] != _hash(utf8.encode(jsonEncode(p)))) {
      throw const FormatException('invalid_learning_manifest');
    }
    _validate(
      p,
      legacy: envelope['schema'] == 1,
      schema: envelope['schema'] as int,
    );
    _snapshotSchemas[file.path] = envelope['schema'] as int;
    return p;
  }

  Future<void> _replace(
    File destination,
    Map<String, dynamic> p, {
    File? temp,
  }) async {
    final next = temp ?? _file('learning.next');
    await _regular(destination);
    await _regular(next);
    await next.writeAsString(
      jsonEncode({
        'schema': 3,
        'payload': p,
        'sha256': _hash(utf8.encode(jsonEncode(p))),
      }),
      flush: true,
    );
    if (jsonEncode(await _snapshot(next)) != jsonEncode(p))
      _fail(LearningErrorCode.writeFailed);
    await next.rename(destination.path);
  }

  Map<String, dynamic> _upgradePayload(Map<String, dynamic> p, int schema) {
    final next = jsonDecode(jsonEncode(p)) as Map<String, dynamic>;
    if (schema == 1) {
      next['candidates'] = <String, dynamic>{};
      next['candidateDeliveries'] = <String, dynamic>{};
    }
    return next;
  }

  Future<void> _persistHold(String reason) async {
    _hold ??= reason;
    try {
      final next = _file('learning.recovery.hold.next');
      await _regular(next);
      await _regular(_file('learning.recovery.hold'));
      final encoded = jsonEncode({'schema': 1, 'reason': _hold});
      await next.writeAsString(encoded, flush: true);
      if (await next.readAsString() != encoded)
        _fail(LearningErrorCode.corruptStore);
      await next.rename(_file('learning.recovery.hold').path);
    } catch (_) {
      _fail(LearningErrorCode.corruptStore);
    }
  }

  void _writable() {
    if (_hold != null) _fail(LearningErrorCode.recoveryHold);
    if (_writeBlocked) _fail(LearningErrorCode.writeFailed);
  }

  Future<void> _writeMarker3() async {
    final next = _file('store.marker.next');
    await _regular(next);
    await _regular(_file('store.marker'));
    await next.writeAsString('learning_core:3', flush: true);
    if (await next.readAsString() != 'learning_core:3')
      _fail(LearningErrorCode.writeFailed);
    await next.rename(_file('store.marker').path);
  }

  Future<Map<String, dynamic>?> _upgradeArchive(int schema) async {
    final file = _file('learning.schema$schema.snapshot');
    if (!await _regular(file)) return null;
    final archived = await _snapshot(file);
    if (_snapshotSchemas[file.path] != schema)
      _fail(LearningErrorCode.corruptStore);
    return archived;
  }

  Future<void> _archiveForUpgrade(
    File selected,
    Map<String, dynamic> p,
    int schema,
  ) async {
    final name = 'learning.schema$schema.snapshot';
    final old = await _upgradeArchive(schema);
    if (old != null) {
      if (jsonEncode(old) != jsonEncode(p))
        _fail(LearningErrorCode.corruptStore);
      return;
    }
    final next = _file('$name.next');
    await _regular(next);
    final bytes = await selected.readAsBytes();
    await next.writeAsBytes(bytes, flush: true);
    final copied = await _snapshot(next);
    if (_snapshotSchemas[next.path] != schema ||
        jsonEncode(copied) != jsonEncode(p) ||
        _hash(await next.readAsBytes()) != _hash(bytes))
      _fail(LearningErrorCode.writeFailed);
    await next.rename(_file(name).path);
  }

  Future<void> _load() async {
    await _directory(_root);
    _partition = Directory(
      '${_root.path}/${_hash(utf8.encode('learning-owner:$trustedOwnerId'))}',
    );
    await _directory(_partition);
    final fresh = await _partition.list(followLinks: false).isEmpty;
    final issues = <String>[];
    const reasons = {
      'lossy_fallback',
      'marker_invalid',
      'migration_uncertain',
      'authority_unavailable',
    };
    final hold = _file('learning.recovery.hold');
    if (await FileSystemEntity.type(hold.path, followLinks: false) !=
            FileSystemEntityType.notFound ||
        await FileSystemEntity.type(
              _file('learning.recovery.hold.next').path,
              followLinks: false,
            ) !=
            FileSystemEntityType.notFound) {
      _hold = 'authority_unavailable';
      try {
        if (!await _regular(hold) || await hold.length() > 256)
          throw const FormatException();
        final h = jsonDecode(await hold.readAsString()) as Map<String, dynamic>;
        if (h.length != 2 || h['schema'] != 1 || !reasons.contains(h['reason']))
          throw const FormatException();
        _hold = h['reason'] as String;
      } catch (_) {
        /* Unreadable or incomplete fencing remains a hold. */
      }
    }
    String? marker;
    try {
      final f = _file('store.marker');
      if (await _regular(f) && await f.length() <= 64)
        marker = await f.readAsString();
    } catch (_) {
      marker = null;
    }
    Map<String, dynamic>? primary, backup;
    try {
      primary = await _snapshot(_file('learning.json'));
    } catch (_) {
      issues.add('manifest_corrupt');
    }
    try {
      backup = await _snapshot(_file('learning.bak'));
    } catch (_) {
      issues.add('backup_corrupt');
    }
    for (final name in [
      'learning.next',
      'learning.bak.next',
      'learning.recovery.next',
      'store.marker.next',
      'learning.schema1.snapshot.next',
      'learning.schema2.snapshot.next',
    ]) {
      if (await FileSystemEntity.type(_file(name).path, followLinks: false) !=
          FileSystemEntityType.notFound)
        issues.add('pending_write');
    }
    var status = LearningRecoveryStatus.clean;
    if (primary == null && backup == null) {
      if (!fresh) _fail(LearningErrorCode.corruptStore);
      _data = {
        'ownerId': trustedOwnerId,
        'sequence': 0,
        'versions': <String, dynamic>{},
        'checkpoints': <String, dynamic>{},
        'candidates': <String, dynamic>{},
        'candidateDeliveries': <String, dynamic>{},
      };
      await _replace(
        _file('learning.bak'),
        _data,
        temp: _file('learning.bak.next'),
      );
      await _replace(_file('learning.json'), _data);
      await _writeMarker3();
      status = LearningRecoveryStatus.initialized;
    } else if (primary == null) {
      await _persistHold('lossy_fallback');
      _data = _upgradePayload(
        backup!,
        _snapshotSchemas[_file('learning.bak').path]!,
      );
      await _replace(
        _file('learning.json'),
        _data,
        temp: _file('learning.recovery.next'),
      );
      status = LearningRecoveryStatus.recoveredFromBackup;
      issues.add('backup_used');
    } else {
      final ps = _snapshotSchemas[_file('learning.json').path]!;
      final bs = _snapshotSchemas[_file('learning.bak').path];
      _data = _upgradePayload(primary, ps);
      if (_hold == null) {
        if (marker == 'learning_core:3') {
          if (ps != 3 || bs != 3) await _persistHold('migration_uncertain');
        } else if (marker != 'learning_core:1' && marker != 'learning_core:2') {
          await _persistHold('marker_invalid');
        } else {
          try {
            final legacySchema = marker == 'learning_core:1' ? 1 : 2;
            final backupAbsent =
                await FileSystemEntity.type(
                  _file('learning.bak').path,
                  followLinks: false,
                ) ==
                FileSystemEntityType.notFound;
            final pending = issues.contains('pending_write');
            var allowed = false;
            if (ps == legacySchema &&
                !pending &&
                ((backupAbsent && !issues.contains('backup_corrupt')) ||
                    bs == legacySchema)) {
              await _archiveForUpgrade(_file('learning.json'), primary, ps);
              allowed = true;
            } else if (bs == 3 &&
                backup != null &&
                !pending &&
                jsonEncode(_upgradePayload(primary, ps)) ==
                    jsonEncode(backup) &&
                (ps == legacySchema || ps == 3)) {
              final archived = await _upgradeArchive(legacySchema);
              allowed =
                  archived != null &&
                  jsonEncode(_upgradePayload(archived, legacySchema)) ==
                      jsonEncode(backup);
            } else if (marker == 'learning_core:1' &&
                !pending &&
                (ps == 1 || ps == 2) &&
                bs == 2 &&
                backup != null &&
                jsonEncode(_upgradePayload(primary, ps)) ==
                    jsonEncode(backup) &&
                (backup['candidates'] as Map).isEmpty &&
                (backup['candidateDeliveries'] as Map).isEmpty) {
              final archive = await _upgradeArchive(1);
              allowed =
                  archive != null &&
                  jsonEncode(_upgradePayload(archive, 1)) == jsonEncode(backup);
              if (allowed && ps == 2)
                await _archiveForUpgrade(_file('learning.json'), primary, 2);
            }
            if (allowed) {
              await _replace(
                _file('learning.bak'),
                _data,
                temp: _file('learning.bak.next'),
              );
              await _replace(_file('learning.json'), _data);
              await _writeMarker3();
            } else {
              await _persistHold('migration_uncertain');
            }
          } catch (_) {
            await _persistHold('migration_uncertain');
          }
        }
      }
    }
    if (_hold != null) {
      issues.add('recovery_hold:$_hold');
      if (_hold == 'marker_invalid' || _hold == 'migration_uncertain')
        issues.add('schema_boundary_mismatch');
    }
    for (final raw in _versions.values) {
      final version = await _view(raw as Map<String, dynamic>);
      for (final issue in [
        'material_source_unavailable',
        'media_unavailable',
        'media_unverified',
      ]) {
        if (version.issues.contains(issue)) issues.add(issue);
      }
    }
    if (issues.isNotEmpty &&
        status != LearningRecoveryStatus.recoveredFromBackup)
      status = LearningRecoveryStatus.degraded;
    _report = LearningRecoveryReport(status, issues.toSet());
  }

  Future<void> _commit(Map<String, dynamic> next) async {
    _writable();
    next['sequence'] = (_data['sequence'] as int) + 1;
    try {
      _validate(next);
      await _replace(
        _file('learning.bak'),
        _data,
        temp: _file('learning.bak.next'),
      );
      await _replace(_file('learning.json'), next);
      _data = next;
    } catch (_) {
      _writeBlocked = true;
      await _persistHold('authority_unavailable');
      _report = LearningRecoveryReport(LearningRecoveryStatus.degraded, [
        ..._report.issues,
        'pending_write',
        'recovery_hold:$_hold',
      ]);
      _fail(LearningErrorCode.writeFailed);
    }
  }

  Map<String, dynamic> _record(String id) {
    _checkId(id);
    final record = _versions[id] as Map<String, dynamic>?;
    if (record == null) _fail(LearningErrorCode.notFound);
    return record!;
  }

  bool _timingsValid(List<dynamic> list, int count, int duration) {
    if (count == 0 || list.length != count) return false;
    final sorted = list.cast<Map<String, dynamic>>().toList()
      ..sort(
        (a, b) =>
            (a['sentenceIndex'] as int).compareTo(b['sentenceIndex'] as int),
      );
    var previous = 0;
    for (var i = 0; i < sorted.length; i++) {
      final t = sorted[i], start = t['startMs'] as int, end = t['endMs'] as int;
      if (t['sentenceIndex'] != i ||
          start < 0 ||
          end <= start ||
          end > duration ||
          start < previous)
        return false;
      previous = end;
    }
    return true;
  }

  Future<LearningVersion> _view(Map<String, dynamic> v) async {
    final issues = <String>[];
    var sourceValid = true;
    try {
      final source = await _materials.readVersion(
        v['materialVersionId'] as String,
      );
      sourceValid =
          source.ownerId == trustedOwnerId &&
          source.materialId == v['materialId'];
      if ((v['textProvenance'] as Map<String, dynamic>)['origin'] ==
          'external') {
        final external = this._externalView(
          (v['textProvenance'] as Map<String, dynamic>)['external'],
        );
        sourceValid =
            sourceValid &&
            this._sourceTextHash(source.text) == external.sourceTextSha256;
      }
    } on MaterialStoreException {
      sourceValid = false;
    }
    if (!sourceValid) issues.add('material_source_unavailable');
    final sourceSentences = (v['sentences'] as List)
        .cast<Map<String, dynamic>>();
    final completeText =
        sourceSentences.isNotEmpty &&
        sourceSentences.every(
          (s) => (s['english'] as String).trim().isNotEmpty,
        );
    final anyText = sourceSentences.any(
      (s) => (s['english'] as String).trim().isNotEmpty,
    );
    if (!completeText) issues.add('english_missing');
    LearningMedia? media;
    var timingValid = false;
    final raw = v['media'] as Map<String, dynamic>?;
    if (raw == null) {
      issues.add('audio_missing');
    } else {
      final artifact = _artifact(raw['artifact'] as Map<String, dynamic>);
      int? duration;
      var validation = 'unverified';
      try {
        final bytes = await _materials.readArtifact(artifact);
        duration = inspectPcmWave(
          bytes,
          strictExternal:
              (raw['provenance'] as Map<String, dynamic>)['origin'] ==
              'external',
        )?.durationMs;
        if (duration == null) {
          issues.add('media_unverified');
        } else {
          timingValid = _timingsValid(
            raw['timings'] as List,
            sourceSentences.length,
            duration,
          );
          if (!timingValid) issues.add('timing_invalid');
          validation = timingValid ? 'pcm_wav' : 'timing_invalid';
        }
      } on MaterialStoreException {
        validation = 'unavailable';
        issues.add('media_unavailable');
      }
      media = LearningMedia(
        mediaVersionId: raw['id'] as String,
        artifact: artifact,
        provenance: _provenanceView(raw['provenance'] as Map<String, dynamic>),
        validation: validation,
        durationMs: duration,
        externalDetails: raw['externalDetails'] == null
            ? null
            : ExternalLearningMediaDetails(
                englishSha256:
                    raw['externalDetails']['englishSha256'] as String,
                declaration: this._declarationView(
                  raw['externalDetails']['declaration'],
                ),
                timingDeclaration:
                    raw['externalDetails']['timingDeclaration'] as String,
              ),
      );
    }
    final byIndex = <int, Map<String, dynamic>>{};
    if (timingValid) {
      for (final t in raw!['timings'] as List) {
        byIndex[t['sentenceIndex'] as int] = t as Map<String, dynamic>;
      }
    }
    final anchors = <SentenceAnchor>[];
    for (var i = 0; i < sourceSentences.length; i++) {
      final sentence = sourceSentences[i], timing = byIndex[i];
      anchors.add(
        SentenceAnchor(
          sentenceId: sentence['id'] as String,
          unitId: v['unitId'] as String,
          english: sentence['english'] as String,
          translation: sentence['translation'] as String,
          startMs: timing?['startMs'] as int?,
          endMs: timing?['endMs'] as int?,
        ),
      );
    }
    LearningCandidateMediaReview? review;
    final textOrigin = v['textProvenance'] as Map<String, dynamic>;
    if (textOrigin['origin'] == 'external') {
      final candidate =
          (_data['candidates']
                  as Map<
                    String,
                    dynamic
                  >)[textOrigin['external']['candidateId']]
              as Map<String, dynamic>?;
      if (candidate != null && (candidate['inputVersion'] ?? 1) == 2) {
        review = this._mediaReviewRecord(
          candidate,
          issues: await this._mediaIssues(candidate),
        );
        for (final issue in review!.issues) {
          if (!issues.contains(issue)) issues.add(issue);
        }
      }
    }
    return LearningVersion(
      candidateMediaReview: review,
      binding: _binding(v),
      materialTitle: v['materialTitle'] as String,
      textProvenance: _provenanceView(
        v['textProvenance'] as Map<String, dynamic>,
      ),
      state: completeText && sourceValid && timingValid
          ? LearningState.ready
          : anyText
          ? LearningState.partial
          : LearningState.pending,
      sentences: anchors,
      issues: issues,
      media: media,
      createdAtUtc: DateTime.parse(v['createdAt'] as String),
    );
  }

  Map<String, dynamic> _buildVersionRecord({
    required MaterialVersion source,
    required List<LearningSentenceInput> sentences,
    required ContentProvenance textProvenance,
    LearningMediaInput? media,
    bool allowExternal = false,
    bool allowExternalMedia = false,
    DateTime? createdAtUtc,
  }) {
    final provenance = _provenance(
      textProvenance,
      allowExternal: allowExternal,
    );
    Map<String, dynamic>? audio;
    if (media != null) {
      if (media.artifact.ownerId != trustedOwnerId)
        _fail(LearningErrorCode.ownerMismatch);
      _checkId(media.artifact.artifactId);
      if (media.artifact.byteLength < 0 ||
          !_hashes.hasMatch(media.artifact.sha256)) {
        _fail(LearningErrorCode.invalidInput);
      }
      audio = {
        'id': _id(),
        'artifact': _artifactRecord(media.artifact),
        'provenance': _provenance(
          media.provenance,
          allowExternal: allowExternalMedia,
        ),
        'timings': media.timings
            .map(
              (t) => {
                'sentenceIndex': t.sentenceIndex,
                'startMs': t.startMs,
                'endMs': t.endMs,
              },
            )
            .toList(),
      };
    }
    final id = _id();
    final record = <String, dynamic>{
      'id': id,
      'materialId': source.materialId,
      'materialVersionId': source.versionId,
      'materialTitle': source.title,
      'unitId': _id(),
      'textProvenance': provenance,
      'sentences': sentences
          .map(
            (s) => {
              'id': _id(),
              'english': s.english,
              'translation': s.translation,
            },
          )
          .toList(),
      'media': audio,
      'createdAt': (createdAtUtc ?? DateTime.now().toUtc()).toIso8601String(),
    };
    return record;
  }

  @override
  Future<LearningVersion> createVersion({
    required String materialVersionId,
    required Iterable<LearningSentenceInput> sentences,
    required ContentProvenance textProvenance,
    LearningMediaInput? media,
  }) {
    final ownSentences = List<LearningSentenceInput>.of(sentences);
    return _run(() async {
      _writable();
      _checkId(materialVersionId);
      MaterialVersion source;
      try {
        source = await _materials.readVersion(materialVersionId);
      } on MaterialStoreException {
        _fail(LearningErrorCode.notFound);
        rethrow;
      }
      if (source.ownerId != trustedOwnerId)
        _fail(LearningErrorCode.ownerMismatch);
      final record = _buildVersionRecord(
        source: source,
        sentences: ownSentences,
        textProvenance: textProvenance,
        media: media,
      );
      final id = record['id'] as String;
      final next = _copy();
      (next['versions'] as Map<String, dynamic>)[id] = record;
      await _commit(next);
      return _view(record);
    });
  }

  @override
  Future<LearningVersion> readVersion(String id) =>
      _run(() async => _view(_record(id)));
  @override
  Future<List<LearningVersion>> listVersions({String? materialId}) =>
      _run(() async {
        if (materialId != null) _checkId(materialId);
        final list = <LearningVersion>[];
        for (final raw in _versions.values) {
          final record = raw as Map<String, dynamic>;
          if (materialId == null || record['materialId'] == materialId)
            list.add(await _view(record));
        }
        return List.unmodifiable(list);
      });
  @override
  Future<LearningPlaybackSession> openPlayback(String id) => _run(() async {
    _writable();
    _active = null;
    final version = await _view(_record(id));
    if (version.candidateMediaReview != null) this._mediaGate();
    if (version.state != LearningState.ready) _fail(LearningErrorCode.notReady);
    final session = LearningPlaybackSession(
      sessionId: _id(),
      binding: version.binding,
      item: PlaybackItem(
        ownerId: trustedOwnerId,
        itemId: id,
        itemRevision: version.binding.mediaVersionId!,
        kind: MediaKind.audio,
      ),
      progressRevision:
          (_checkpoints[id] as Map<String, dynamic>?)?['revision'] as int? ?? 0,
    );
    _active = session;
    return session;
  });
  @override
  Future<ArtifactRef> mediaArtifactFor(PlaybackItem item) => _run(() async {
    _writable();
    if (item.ownerId != trustedOwnerId) _fail(LearningErrorCode.ownerMismatch);
    final version = await _view(_record(item.itemId));
    if (version.candidateMediaReview != null) this._mediaGate();
    if (item.itemRevision != version.binding.mediaVersionId ||
        item.kind != MediaKind.audio) {
      _fail(LearningErrorCode.bindingMismatch);
    }
    if (version.state != LearningState.ready) _fail(LearningErrorCode.notReady);
    return version.media!.artifact;
  });
  ProgressCheckpoint _checkpoint(Map<String, dynamic> c) => ProgressCheckpoint(
    binding: _bindingView(c['binding'] as Map<String, dynamic>),
    revision: c['revision'] as int,
    sentenceId: c['sentenceId'] as String,
    position: Duration(milliseconds: c['positionMs'] as int),
    savedAtUtc: DateTime.parse(c['savedAt'] as String),
  );
  void _position(
    LearningVersion version,
    String sentenceId,
    Duration position,
  ) {
    final found = version.sentences
        .where((s) => s.sentenceId == sentenceId)
        .firstOrNull;
    if (found == null ||
        position.isNegative ||
        found.startMs == null ||
        found.endMs == null ||
        position.inMilliseconds < found.startMs! ||
        position.inMilliseconds > found.endMs! ||
        position.inMilliseconds > version.media!.durationMs!)
      _fail(LearningErrorCode.invalidInput);
  }

  @override
  Future<ProgressCheckpoint> saveProgress({
    required LearningPlaybackSession session,
    required int expectedRevision,
    required String sentenceId,
    required Duration position,
  }) => _run(() async {
    _writable();
    final active = _active;
    if (active == null || active.sessionId != session.sessionId)
      _fail(LearningErrorCode.staleSession);
    if (!active!.binding.sameAs(session.binding) ||
        session.item.ownerId != trustedOwnerId ||
        session.item.itemId != active.item.itemId ||
        session.item.itemRevision != active.item.itemRevision ||
        session.item.kind != MediaKind.audio)
      _fail(LearningErrorCode.bindingMismatch);
    final version = await _view(_record(session.binding.learningVersionId));
    if (!version.binding.sameAs(session.binding))
      _fail(LearningErrorCode.bindingMismatch);
    if (version.state != LearningState.ready) _fail(LearningErrorCode.notReady);
    _position(version, sentenceId, position);
    final old =
        _checkpoints[version.binding.learningVersionId]
            as Map<String, dynamic>?;
    if (expectedRevision < 0 ||
        expectedRevision != (old?['revision'] as int? ?? 0)) {
      _fail(LearningErrorCode.revisionConflict);
    }
    final record = <String, dynamic>{
      'binding': _bindingRecord(version.binding),
      'revision': expectedRevision + 1,
      'sentenceId': sentenceId,
      'positionMs': position.inMilliseconds,
      'resumeIntent': 'paused',
      'savedAt': DateTime.now().toUtc().toIso8601String(),
    };
    final next = _copy();
    (next['checkpoints']
            as Map<String, dynamic>)[version.binding.learningVersionId] =
        record;
    if (version.candidateMediaReview != null) this._mediaGate();
    await _commit(next);
    return _checkpoint(record);
  });
  @override
  Future<ProgressCheckpoint?> restoreProgress(String id) => _run(() async {
    final version = await _view(_record(id));
    final record = _checkpoints[id] as Map<String, dynamic>?;
    if (record == null) return null;
    if (version.state != LearningState.ready) _fail(LearningErrorCode.notReady);
    final checkpoint = _checkpoint(record);
    _position(version, checkpoint.sentenceId, checkpoint.position);
    return checkpoint;
  });

  @override
  Future<CandidateDeliveryReceipt?> findDeliveryReceipt({
    required CandidateSender sender,
    required String deliveryId,
    required int inputVersion,
    required String expectedPayloadSha256,
  }) => _run(() async {
    this._mediaGate();
    if (!FileLearningStore._references.hasMatch(sender.integrationId) ||
        sender.integrationId.contains(RegExp(r'[\x00-\x1f\x7f]')) ||
        (inputVersion != 1 && inputVersion != 2) ||
        !this._digest(expectedPayloadSha256)) {
      _fail(LearningErrorCode.invalidInput);
    }
    final delivery = this._candidateString(
      deliveryId,
      LearningCandidateLimits.maxDeliveryIdBytes,
      singleLine: true,
    );
    final id =
        (_data['candidateDeliveries'] as Map<String, dynamic>)[this
                ._deliveryKey(sender.integrationId, delivery)]
            as String?;
    if (id == null) return null;
    final candidate = this._candidateRecord(id);
    final hash =
        (candidate['submission'] as Map<String, dynamic>)['payloadSha256']
            as String;
    if ((candidate['inputVersion'] ?? 1) != inputVersion ||
        hash != expectedPayloadSha256) {
      _fail(LearningErrorCode.deliveryConflict);
    }
    return CandidateDeliveryReceipt(
      candidateId: id,
      payloadSha256: hash,
      replayed: true,
    );
  });

  @override
  Future<CandidateDeliveryReceipt> receiveMediaCandidate({
    required CandidateSender sender,
    required LearningMediaCandidateInput input,
  }) => _run(
    () => this._receiveCandidate(sender, input.text, media: input.media),
  );

  @override
  Future<CandidateDeliveryReceipt> receiveCandidate({
    required CandidateSender sender,
    required LearningCandidateInput input,
  }) => _run(() => this._receiveCandidate(sender, input));
  @override
  Future<LearningCandidate> readCandidate(String candidateId) => _run(() async {
    _writable();
    final c = this._candidateRecord(candidateId);
    return this._candidateView(c, mediaIssues: await this._mediaIssues(c));
  });
  @override
  Future<List<LearningCandidate>> listCandidates() => _run(() async {
    _writable();
    final results = <LearningCandidate>[];
    for (final c in (_data['candidates'] as Map<String, dynamic>).values) {
      results.add(
        this._candidateView(
          c as Map<String, dynamic>,
          mediaIssues: await this._mediaIssues(c),
        ),
      );
    }
    return List.unmodifiable(results);
  });

  @override
  Future<LearningCandidate> reviseCandidate({
    required String candidateId,
    required int expectedRevision,
    required List<LearningSentenceInput> sentences,
  }) {
    if (sentences.length > LearningCandidateLimits.maxSentences) {
      _fail(LearningErrorCode.candidateLimitExceeded);
    }
    final own = List<LearningSentenceInput>.unmodifiable(sentences);
    return _run(
      () => this._reviseCandidate(candidateId, expectedRevision, own),
    );
  }

  @override
  Future<LearningVersion> confirmCandidate({
    required String candidateId,
    required int expectedRevision,
  }) => _run(() => this._confirmCandidate(candidateId, expectedRevision));
  @override
  Future<LearningCandidate> rejectCandidate({
    required String candidateId,
    required int expectedRevision,
  }) => _run(() => this._rejectCandidate(candidateId, expectedRevision));
  @override
  Future<void> close() => _run(() async {
    _active = null;
    _closed = true;
  });
}
