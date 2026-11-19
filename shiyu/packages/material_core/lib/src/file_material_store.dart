import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;

import '../material_core.dart';

/// A single-writer local cache, not account authentication or a cloud database.
final class FileMaterialStore
    implements MaterialStore, IdempotentArtifactStore {
  FileMaterialStore._(this._root, this.trustedOwnerId);
  static Future<FileMaterialStore> open({
    required Directory root,
    required String trustedOwnerId,
  }) async {
    if (trustedOwnerId.isEmpty ||
        trustedOwnerId.length > 256 ||
        trustedOwnerId.runes.any((c) => c < 32 || c == 127)) {
      throw const MaterialStoreException(MaterialErrorCode.invalidOwner);
    }
    final store = FileMaterialStore._(root.absolute, trustedOwnerId);
    try {
      await store._load();
      return store;
    } on MaterialStoreException {
      rethrow;
    } catch (_) {
      throw MaterialStoreException(
        MaterialErrorCode.corruptStore,
        recoveryReport: RecoveryReport(RecoveryStatus.unrecoverable, [
          const RecoveryIssue(RecoveryIssueKind.manifestCorrupt),
        ]),
      );
    }
  }

  final Directory _root;
  @override
  final String trustedOwnerId;
  late Directory _partition, _artifacts;
  late Map<String, dynamic> _data;
  late RecoveryReport _report;
  Future<void> _tail = Future<void>.value();
  bool _closed = false, _writeBlocked = false;
  RecoveryHoldReason? _hold;
  final Map<String, int> _snapshotSchemas = {};
  final Random _random = Random.secure();
  static final _ids = RegExp(r'^[0-9a-f]{32}$');
  static final _hashes = RegExp(r'^[0-9a-f]{64}$');
  @override
  RecoveryReport get recoveryReport => _report;
  String _hash(List<int> bytes) => hashes.sha256.convert(bytes).toString();
  String _id() => List.generate(
    16,
    (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  void _checkId(String id) {
    if (!_ids.hasMatch(id)) {
      throw const MaterialStoreException(MaterialErrorCode.invalidId);
    }
  }

  File _file(String name) => File('${_partition.path}/$name');
  File _blob(String id) {
    _checkId(id);
    return File('${_artifacts.path}/$id.blob');
  }

  Map<String, dynamic> get _drafts => _data['drafts'] as Map<String, dynamic>;
  Map<String, dynamic> get _versions =>
      _data['versions'] as Map<String, dynamic>;
  Map<String, dynamic> get _refs => _data['artifacts'] as Map<String, dynamic>;
  Map<String, dynamic> _copy() =>
      jsonDecode(jsonEncode(_data)) as Map<String, dynamic>;
  Future<T> _run<T>(Future<T> Function() fn) {
    final result = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        if (_closed)
          throw const MaterialStoreException(MaterialErrorCode.closed);
        result.complete(await fn());
      } catch (e, st) {
        result.completeError(e, st);
      }
    });
    return result.future;
  }

  Future<void> _directory(Directory dir) async {
    final t = await FileSystemEntity.type(dir.path, followLinks: false);
    if (t == FileSystemEntityType.notFound) {
      await dir.create(recursive: true);
    } else if (t != FileSystemEntityType.directory) {
      throw const MaterialStoreException(MaterialErrorCode.corruptStore);
    }
  }

  Future<bool> _regular(File f) async {
    final t = await FileSystemEntity.type(f.path, followLinks: false);
    if (t == FileSystemEntityType.notFound) return false;
    if (t != FileSystemEntityType.file) {
      throw const MaterialStoreException(MaterialErrorCode.corruptStore);
    }
    return true;
  }

  void _validate(Map<String, dynamic> p, {int schema = 2}) {
    bool id(Object? v) => v is String && _ids.hasMatch(v);
    bool pos(Object? v) => v is int && v > 0;
    bool time(Object? v) =>
        v is String && v.endsWith('Z') && DateTime.tryParse(v) != null;
    void bad() => throw const FormatException('invalid_manifest');
    if (p['ownerId'] != trustedOwnerId ||
        p['sequence'] is! int ||
        (p['sequence'] as int) < 0 ||
        p['drafts'] is! Map<String, dynamic> ||
        p['versions'] is! Map<String, dynamic> ||
        p['artifacts'] is! Map<String, dynamic>)
      bad();
    final refs = p['artifacts'] as Map<String, dynamic>;
    for (final e in refs.entries) {
      final v = e.value;
      if (!id(e.key) ||
          v is! Map<String, dynamic> ||
          v['id'] != e.key ||
          v['byteLength'] is! int ||
          (v['byteLength'] as int) < 0 ||
          v['sha256'] is! String ||
          !_hashes.hasMatch(v['sha256'] as String))
        bad();
    }
    if (schema == 1) {
      if (p.containsKey('artifactOperations')) bad();
    } else {
      final operations = p['artifactOperations'];
      if (operations is! Map<String, dynamic> ||
          operations.length > ArtifactRegistrationLimits.maxOperations)
        bad();
      final bound = <String>{};
      for (final e in (operations as Map<String, dynamic>).entries) {
        final v = e.value;
        if (e.key.length != 64 ||
            !_hashes.hasMatch(e.key) ||
            v is! Map<String, dynamic> ||
            v.length != 3 ||
            !id(v['artifactId']) ||
            !bound.add(v['artifactId'] as String) ||
            v['byteLength'] is! int ||
            (v['byteLength'] as int) < 1 ||
            (v['byteLength'] as int) >
                ArtifactRegistrationLimits.maxArtifactBytes ||
            v['sha256'] is! String ||
            !_hashes.hasMatch(v['sha256'] as String))
          bad();
        final ref = refs[v['artifactId']];
        if (ref is! Map<String, dynamic> ||
            ref['byteLength'] != v['byteLength'] ||
            ref['sha256'] != v['sha256'])
          bad();
      }
    }
    bool validRefs(Object? list) =>
        list is List && list.every((v) => id(v) && refs.containsKey(v));
    final drafts = p['drafts'] as Map<String, dynamic>;
    for (final e in drafts.entries) {
      final v = e.value;
      if (!id(e.key) ||
          v is! Map<String, dynamic> ||
          v['id'] != e.key ||
          v['title'] is! String ||
          v['text'] is! String ||
          !pos(v['revision']) ||
          !time(v['updatedAt']) ||
          !validRefs(v['artifacts']))
        bad();
    }
    final numbers = <String>{}, revisions = <String>{};
    for (final e in (p['versions'] as Map<String, dynamic>).entries) {
      final v = e.value;
      if (!id(e.key) ||
          v is! Map<String, dynamic> ||
          v['id'] != e.key ||
          !id(v['materialId']) ||
          !drafts.containsKey(v['materialId']) ||
          v['title'] is! String ||
          v['text'] is! String ||
          !pos(v['versionNumber']) ||
          !pos(v['draftRevision']) ||
          !time(v['confirmedAt']) ||
          !validRefs(v['artifacts']))
        bad();
      if ((v['draftRevision'] as int) >
              (drafts[v['materialId']]['revision'] as int) ||
          !numbers.add('${v['materialId']}:${v['versionNumber']}') ||
          !revisions.add('${v['materialId']}:${v['draftRevision']}'))
        bad();
    }
  }

  Future<Map<String, dynamic>?> _snapshot(File f) async {
    if (!await _regular(f)) return null;
    final e = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    if ((e['schema'] != 1 && e['schema'] != 2) ||
        e['payload'] is! Map<String, dynamic>) {
      throw const FormatException('invalid_manifest');
    }
    final p = e['payload'] as Map<String, dynamic>;
    if (e['sha256'] != _hash(utf8.encode(jsonEncode(p)))) {
      throw const FormatException('invalid_manifest');
    }
    _validate(p, schema: e['schema'] as int);
    _snapshotSchemas[f.path] = e['schema'] as int;
    return p;
  }

  Future<void> _load() async {
    await _directory(_root);
    _partition = Directory(
      '${_root.path}/${_hash(utf8.encode('owner:$trustedOwnerId'))}',
    );
    await _directory(_partition);
    _artifacts = Directory('${_partition.path}/artifacts');
    await _directory(_artifacts);
    final initialEntries = await _partition.list(followLinks: false).toList();
    final initialBlobs = await _artifacts.list(followLinks: false).toList();
    final fresh =
        initialBlobs.isEmpty &&
        initialEntries.every(
          (e) =>
              e.absolute.uri.normalizePath() ==
              _artifacts.absolute.uri.normalizePath(),
        );
    final issues = <RecoveryIssue>[];
    final holdFile = _file('registration.hold');
    if (await FileSystemEntity.type(holdFile.path, followLinks: false) !=
            FileSystemEntityType.notFound ||
        await FileSystemEntity.type(
              _file('registration.hold.next').path,
              followLinks: false,
            ) !=
            FileSystemEntityType.notFound) {
      _hold = RecoveryHoldReason.authorityUnavailable;
      try {
        if (!await _regular(holdFile)) throw const FormatException();
        final h =
            jsonDecode(await holdFile.readAsString()) as Map<String, dynamic>;
        if (h.length != 2 || h['schema'] != 1) throw const FormatException();
        _hold = RecoveryHoldReason.values.byName(h['reason'] as String);
      } catch (_) {
        /* An unreadable hold is still a hold. */
      }
    }
    Map<String, dynamic>? primary, backup;
    try {
      primary = await _snapshot(_file('manifest.json'));
    } on FormatException {
      issues.add(const RecoveryIssue(RecoveryIssueKind.manifestCorrupt));
    } catch (_) {
      issues.add(const RecoveryIssue(RecoveryIssueKind.manifestCorrupt));
    }
    try {
      backup = await _snapshot(_file('manifest.bak'));
    } on FormatException {
      issues.add(const RecoveryIssue(RecoveryIssueKind.backupCorrupt));
    } catch (_) {
      issues.add(const RecoveryIssue(RecoveryIssueKind.backupCorrupt));
    }
    if (await _regular(_file('manifest.next')) ||
        await _regular(_file('manifest.bak.next')) ||
        await _regular(_file('manifest.recovery.next')) ||
        await _regular(_file('store.marker.next'))) {
      issues.add(const RecoveryIssue(RecoveryIssueKind.pendingWrite));
    }
    var status = RecoveryStatus.clean;
    if (primary != null) {
      _data = primary;
    } else if (backup != null) {
      await _persistHold(RecoveryHoldReason.lossyFallback);
      _data = backup;
      // A schema1 backup is readable historical data only, never new authority.
      if (!_data.containsKey('artifactOperations')) {
        _data = {..._data, 'artifactOperations': <String, dynamic>{}};
      }
      status = RecoveryStatus.recoveredFromBackup;
      issues.add(const RecoveryIssue(RecoveryIssueKind.backupUsed));
      await _replace(
        _file('manifest.json'),
        _data,
        temp: _file('manifest.recovery.next'),
      );
    } else {
      final entries = await _partition.list(followLinks: false).toList();
      final blobs = await _artifacts.list(followLinks: false).toList();
      if (issues.isNotEmpty ||
          blobs.isNotEmpty ||
          entries.any(
            (e) =>
                e.absolute.uri.normalizePath() !=
                _artifacts.absolute.uri.normalizePath(),
          )) {
        throw MaterialStoreException(
          MaterialErrorCode.corruptStore,
          recoveryReport: RecoveryReport(RecoveryStatus.unrecoverable, [
            ...issues,
            if (_hold != null)
              RecoveryIssue(
                RecoveryIssueKind.registrationHold,
                holdReason: _hold,
              ),
          ]),
        );
      }
      _data = {
        'ownerId': trustedOwnerId,
        'sequence': 0,
        'drafts': <String, dynamic>{},
        'versions': <String, dynamic>{},
        'artifacts': <String, dynamic>{},
        'artifactOperations': <String, dynamic>{},
      };
      await _replace(_file('manifest.json'), _data);
      status = RecoveryStatus.initialized;
    }
    final marker = _file('store.marker');
    String? markerValue;
    try {
      if (await _regular(marker)) markerValue = await marker.readAsString();
    } catch (_) {
      markerValue = null;
    }
    if (fresh) {
      await _replace(
        _file('manifest.bak'),
        _data,
        temp: _file('manifest.bak.next'),
      );
      await _writeMarker();
    } else if (_hold == null) {
      final ps = _snapshotSchemas[_file('manifest.json').path];
      final bs = _snapshotSchemas[_file('manifest.bak').path];
      final backupAbsent =
          await FileSystemEntity.type(
            _file('manifest.bak').path,
            followLinks: false,
          ) ==
          FileSystemEntityType.notFound;
      final pending = issues.any(
        (i) => i.kind == RecoveryIssueKind.pendingWrite,
      );
      if (markerValue == 'material_core:1' && primary != null) {
        bool equivalent(Map<String, dynamic> a, Map<String, dynamic> b) {
          final aa = {...a}..remove('artifactOperations');
          final bb = {...b}..remove('artifactOperations');
          return jsonEncode(aa) == jsonEncode(bb);
        }

        final oldClean =
            ps == 1 &&
            !pending &&
            ((backupAbsent &&
                    !issues.any(
                      (i) => i.kind == RecoveryIssueKind.backupCorrupt,
                    )) ||
                bs == 1);
        final completing =
            bs == 2 &&
            backup != null &&
            (backup['artifactOperations'] as Map).isEmpty &&
            (ps == 1 ||
                (ps == 2 && (primary['artifactOperations'] as Map).isEmpty)) &&
            equivalent(primary, backup) &&
            !pending;
        if (oldClean || completing) {
          _data = {...primary, 'artifactOperations': <String, dynamic>{}};
          await _replace(
            _file('manifest.bak'),
            _data,
            temp: _file('manifest.bak.next'),
          );
          await _replace(_file('manifest.json'), _data);
          await _writeMarker();
        } else {
          await _persistHold(RecoveryHoldReason.migrationUncertain);
        }
      } else if (markerValue != 'material_core:2') {
        await _persistHold(RecoveryHoldReason.markerInvalid);
      } else if (ps != 2 || bs != 2) {
        await _persistHold(RecoveryHoldReason.migrationUncertain);
      }
    }
    if (!_data.containsKey('artifactOperations')) {
      _data = {..._data, 'artifactOperations': <String, dynamic>{}};
    }
    if (_hold != null) {
      if (_hold == RecoveryHoldReason.markerInvalid ||
          _hold == RecoveryHoldReason.migrationUncertain) {
        issues.add(
          const RecoveryIssue(RecoveryIssueKind.schemaBoundaryMismatch),
        );
      }
      issues.add(
        RecoveryIssue(RecoveryIssueKind.registrationHold, holdReason: _hold),
      );
    }
    for (final e in _refs.entries) {
      try {
        await _verify(_ref(e.key));
      } on MaterialStoreException catch (error) {
        if (error.code == MaterialErrorCode.missingArtifact) {
          issues.add(
            RecoveryIssue(RecoveryIssueKind.artifactMissing, resourceId: e.key),
          );
        } else if (error.code == MaterialErrorCode.artifactCorrupt) {
          issues.add(
            RecoveryIssue(RecoveryIssueKind.artifactCorrupt, resourceId: e.key),
          );
        } else {
          rethrow;
        }
      }
    }
    await for (final f in _artifacts.list(followLinks: false)) {
      final name = f.uri.pathSegments.last;
      if (name.endsWith('.blob')) {
        final id = name.substring(0, name.length - 5);
        if (!_refs.containsKey(id))
          issues.add(
            RecoveryIssue(
              RecoveryIssueKind.orphanArtifact,
              resourceId: _ids.hasMatch(id) ? id : null,
            ),
          );
      } else {
        issues.add(const RecoveryIssue(RecoveryIssueKind.pendingWrite));
      }
    }
    if (issues.isNotEmpty && status != RecoveryStatus.recoveredFromBackup)
      status = RecoveryStatus.degraded;
    _report = RecoveryReport(status, issues);
  }

  Future<void> _writeMarker() async {
    final next = _file('store.marker.next');
    await _regular(next);
    await _regular(_file('store.marker'));
    await next.writeAsString('material_core:2', flush: true);
    if (await next.readAsString() != 'material_core:2') {
      throw const MaterialStoreException(MaterialErrorCode.writeFailed);
    }
    await next.rename(_file('store.marker').path);
  }

  Future<void> _persistHold(RecoveryHoldReason reason) async {
    _hold ??= reason;
    final next = _file('registration.hold.next');
    try {
      await _regular(next);
      await _regular(_file('registration.hold'));
      final encoded = jsonEncode({'schema': 1, 'reason': _hold!.name});
      await next.writeAsString(encoded, flush: true);
      if (await next.readAsString() != encoded) throw const FormatException();
      await next.rename(_file('registration.hold').path);
    } catch (_) {
      throw MaterialStoreException(
        MaterialErrorCode.corruptStore,
        recoveryReport: RecoveryReport(RecoveryStatus.unrecoverable, [
          RecoveryIssue(RecoveryIssueKind.registrationHold, holdReason: _hold),
        ]),
      );
    }
  }

  void _writable() {
    if (_hold != null)
      throw MaterialStoreException(
        MaterialErrorCode.recoveryHold,
        recoveryReport: _report,
      );
    if (_writeBlocked)
      throw const MaterialStoreException(MaterialErrorCode.writeFailed);
  }

  Future<void> _replace(
    File destination,
    Map<String, dynamic> p, {
    File? temp,
  }) async {
    final next = temp ?? _file('manifest.next');
    await _regular(destination);
    await _regular(next);
    final e = {
      'schema': 2,
      'payload': p,
      'sha256': _hash(utf8.encode(jsonEncode(p))),
    };
    await next.writeAsString(jsonEncode(e), flush: true);
    final check = await _snapshot(next);
    if (check == null || jsonEncode(check) != jsonEncode(p)) {
      throw const MaterialStoreException(MaterialErrorCode.writeFailed);
    }
    await next.rename(destination.path);
  }

  Future<void> _commit(Map<String, dynamic> next) async {
    _writable();
    next['sequence'] = (_data['sequence'] as int) + 1;
    try {
      _validate(next);
      await _replace(
        _file('manifest.bak'),
        _data,
        temp: _file('manifest.bak.next'),
      );
      await _replace(_file('manifest.json'), next);
      _data = next;
    } catch (_) {
      _writeBlocked = true;
      await _persistHold(RecoveryHoldReason.authorityUnavailable);
      _report = RecoveryReport(RecoveryStatus.degraded, [
        ..._report.issues,
        const RecoveryIssue(RecoveryIssueKind.pendingWrite),
        RecoveryIssue(RecoveryIssueKind.registrationHold, holdReason: _hold),
      ]);
      throw const MaterialStoreException(MaterialErrorCode.writeFailed);
    }
  }

  ArtifactRef _ref(String id) {
    final v = _refs[id] as Map<String, dynamic>?;
    if (v == null)
      throw MaterialStoreException(MaterialErrorCode.notFound, resourceId: id);
    return ArtifactRef(
      ownerId: trustedOwnerId,
      artifactId: id,
      byteLength: v['byteLength'] as int,
      sha256: v['sha256'] as String,
    );
  }

  List<String> _artifactIds(Iterable<ArtifactRef> refs) {
    final result = <String>{};
    for (final r in refs) {
      _checkId(r.artifactId);
      if (r.ownerId != trustedOwnerId)
        throw const MaterialStoreException(MaterialErrorCode.ownerMismatch);
      final known = _ref(r.artifactId);
      if (known.byteLength != r.byteLength || known.sha256 != r.sha256) {
        throw const MaterialStoreException(MaterialErrorCode.artifactCorrupt);
      }
      result.add(r.artifactId);
    }
    return result.toList();
  }

  MaterialDraft _draft(Map<String, dynamic> v) => MaterialDraft(
    ownerId: trustedOwnerId,
    materialId: v['id'] as String,
    revision: v['revision'] as int,
    title: v['title'] as String,
    text: v['text'] as String,
    artifacts: (v['artifacts'] as List).cast<String>().map(_ref),
    updatedAtUtc: DateTime.parse(v['updatedAt'] as String),
  );
  MaterialVersion _version(Map<String, dynamic> v) => MaterialVersion(
    ownerId: trustedOwnerId,
    materialId: v['materialId'] as String,
    versionId: v['id'] as String,
    versionNumber: v['versionNumber'] as int,
    draftRevision: v['draftRevision'] as int,
    title: v['title'] as String,
    text: v['text'] as String,
    artifacts: (v['artifacts'] as List).cast<String>().map(_ref),
    confirmedAtUtc: DateTime.parse(v['confirmedAt'] as String),
  );
  Map<String, dynamic> _draftRecord(String id) {
    _checkId(id);
    final v = _drafts[id] as Map<String, dynamic>?;
    if (v == null)
      throw MaterialStoreException(MaterialErrorCode.notFound, resourceId: id);
    return v;
  }

  @override
  Future<MaterialDraft> createDraft({
    required String title,
    String text = '',
    Iterable<ArtifactRef> artifacts = const [],
  }) => _run(() async {
    _writable();
    final id = _id(), next = _copy();
    final v = <String, dynamic>{
      'id': id,
      'title': title,
      'text': text,
      'revision': 1,
      'artifacts': _artifactIds(artifacts),
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    };
    (next['drafts'] as Map<String, dynamic>)[id] = v;
    await _commit(next);
    return _draft(v);
  });
  @override
  Future<MaterialDraft> readDraft(String materialId) =>
      _run(() async => _draft(_draftRecord(materialId)));
  @override
  Future<List<MaterialDraft>> listDrafts() => _run(
    () async => List.unmodifiable(
      _drafts.values.map((v) => _draft(v as Map<String, dynamic>)),
    ),
  );
  @override
  Future<MaterialDraft> updateDraft({
    required String materialId,
    required int expectedRevision,
    String? title,
    String? text,
    Iterable<ArtifactRef>? artifacts,
  }) => _run(() async {
    _writable();
    final old = _draftRecord(materialId);
    if (old['revision'] != expectedRevision)
      throw const MaterialStoreException(MaterialErrorCode.revisionConflict);
    final v = <String, dynamic>{
      ...old,
      'revision': expectedRevision + 1,
      'title': title ?? old['title'],
      'text': text ?? old['text'],
      'artifacts': artifacts == null
          ? old['artifacts']
          : _artifactIds(artifacts),
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    };
    final next = _copy();
    (next['drafts'] as Map<String, dynamic>)[materialId] = v;
    await _commit(next);
    return _draft(v);
  });
  @override
  Future<MaterialVersion> confirmVersion({
    required String materialId,
    required int expectedRevision,
  }) => _run(() async {
    _writable();
    final d = _draftRecord(materialId);
    if (d['revision'] != expectedRevision)
      throw const MaterialStoreException(MaterialErrorCode.revisionConflict);
    var number = 1;
    for (final raw in _versions.values) {
      final v = raw as Map<String, dynamic>;
      if (v['materialId'] != materialId) continue;
      if (v['draftRevision'] == expectedRevision) return _version(v);
      number = max(number, (v['versionNumber'] as int) + 1);
    }
    final v = <String, dynamic>{
      'id': _id(),
      'materialId': materialId,
      'versionNumber': number,
      'draftRevision': expectedRevision,
      'title': d['title'],
      'text': d['text'],
      'artifacts': List<String>.from(d['artifacts'] as List),
      'confirmedAt': DateTime.now().toUtc().toIso8601String(),
    };
    final next = _copy();
    (next['versions'] as Map<String, dynamic>)[v['id'] as String] = v;
    await _commit(next);
    return _version(v);
  });
  @override
  Future<MaterialVersion> readVersion(String versionId) => _run(() async {
    _checkId(versionId);
    final v = _versions[versionId] as Map<String, dynamic>?;
    if (v == null)
      throw MaterialStoreException(
        MaterialErrorCode.notFound,
        resourceId: versionId,
      );
    return _version(v);
  });
  @override
  Future<List<MaterialVersion>> listVersions(String materialId) =>
      _run(() async {
        _draftRecord(materialId);
        final list =
            _versions.values
                .cast<Map<String, dynamic>>()
                .where((v) => v['materialId'] == materialId)
                .map(_version)
                .toList()
              ..sort((a, b) => a.versionNumber.compareTo(b.versionNumber));
        return List.unmodifiable(list);
      });
  Future<void> _verify(ArtifactRef r) async {
    try {
      final f = _blob(r.artifactId);
      if (!await _regular(f))
        throw MaterialStoreException(
          MaterialErrorCode.missingArtifact,
          resourceId: r.artifactId,
        );
      if (await f.length() != r.byteLength ||
          (await hashes.sha256.bind(f.openRead()).first).toString() !=
              r.sha256) {
        throw MaterialStoreException(
          MaterialErrorCode.artifactCorrupt,
          resourceId: r.artifactId,
        );
      }
    } on FileSystemException {
      // A read/delete race or access failure must not expose an OS path.
      throw MaterialStoreException(
        MaterialErrorCode.artifactCorrupt,
        resourceId: r.artifactId,
      );
    }
  }

  void _checkOperationKey(String key) {
    if (key.length != 64 || !_hashes.hasMatch(key)) {
      throw const MaterialStoreException(MaterialErrorCode.invalidOperationKey);
    }
  }

  Map<String, dynamic> get _operations =>
      _data['artifactOperations'] as Map<String, dynamic>;

  Future<int> _retainedBytes() async {
    var total = 0;
    try {
      await for (final entry in _artifacts.list(followLinks: false)) {
        if (await FileSystemEntity.type(entry.path, followLinks: false) !=
            FileSystemEntityType.file) {
          throw const MaterialStoreException(
            MaterialErrorCode.capacityExceeded,
          );
        }
        total += await File(entry.path).length();
        if (total > ArtifactRegistrationLimits.maxRetainedBytes) return total;
      }
    } catch (_) {
      throw const MaterialStoreException(MaterialErrorCode.capacityExceeded);
    }
    return total;
  }

  Future<Uint8List> _checkedBytes(ArtifactRef ref) async {
    await _verify(ref);
    try {
      final bytes = await _blob(ref.artifactId).readAsBytes();
      if (bytes.length != ref.byteLength || _hash(bytes) != ref.sha256) {
        throw const MaterialStoreException(MaterialErrorCode.artifactCorrupt);
      }
      return bytes;
    } on MaterialStoreException {
      rethrow;
    } catch (_) {
      throw const MaterialStoreException(MaterialErrorCode.artifactCorrupt);
    }
  }

  @override
  Future<ArtifactRef?> findArtifactRegistration(String operationKey) {
    _checkOperationKey(operationKey);
    return _run(() async {
      _writable(); // Hold/unknown outcome must never appear as an absent mapping.
      final operation = _operations[operationKey];
      if (operation == null) return null;
      final ref = _ref(operation['artifactId'] as String);
      await _checkedBytes(ref);
      return ref;
    });
  }

  @override
  Future<ArtifactRef> registerArtifactOnce({
    required String operationKey,
    required String expectedSha256,
    required Uint8List bytes,
  }) {
    _checkOperationKey(operationKey);
    if (expectedSha256.length != 64 || !_hashes.hasMatch(expectedSha256)) {
      throw const MaterialStoreException(
        MaterialErrorCode.invalidArtifactDigest,
      );
    }
    if (bytes.isEmpty ||
        bytes.length > ArtifactRegistrationLimits.maxArtifactBytes) {
      throw const MaterialStoreException(MaterialErrorCode.capacityExceeded);
    }
    // Bound before copying; caller mutation after invocation cannot change work.
    final owned = Uint8List.fromList(bytes);
    return _run(() async {
      _writable();
      final digest = _hash(owned);
      if (digest != expectedSha256) {
        throw const MaterialStoreException(
          MaterialErrorCode.invalidArtifactDigest,
        );
      }
      final operation = _operations[operationKey];
      if (operation != null) {
        final ref = _ref(operation['artifactId'] as String);
        final existing = await _checkedBytes(ref);
        var equal = existing.length == owned.length;
        if (equal) {
          for (var i = 0; i < owned.length; i++) {
            if (existing[i] != owned[i]) {
              equal = false;
              break;
            }
          }
        }
        if (!equal)
          throw const MaterialStoreException(
            MaterialErrorCode.artifactConflict,
          );
        return ref;
      }
      if (_operations.length >= ArtifactRegistrationLimits.maxOperations ||
          await _retainedBytes() + owned.length >
              ArtifactRegistrationLimits.maxRetainedBytes) {
        throw const MaterialStoreException(MaterialErrorCode.capacityExceeded);
      }
      final id = _id();
      final destination = _blob(id);
      final temp = File('${destination.path}.next');
      try {
        if (await _regular(destination) || await _regular(temp)) {
          throw const MaterialStoreException(MaterialErrorCode.writeFailed);
        }
        await temp.writeAsBytes(owned, flush: true);
        final persisted = await temp.readAsBytes();
        if (persisted.length != owned.length || _hash(persisted) != digest) {
          throw const MaterialStoreException(MaterialErrorCode.writeFailed);
        }
        for (var i = 0; i < owned.length; i++) {
          if (persisted[i] != owned[i]) {
            throw const MaterialStoreException(MaterialErrorCode.writeFailed);
          }
        }
        await temp.rename(destination.path);
        final next = _copy();
        (next['artifacts'] as Map<String, dynamic>)[id] = {
          'id': id,
          'byteLength': owned.length,
          'sha256': digest,
        };
        (next['artifactOperations'] as Map<String, dynamic>)[operationKey] = {
          'artifactId': id,
          'byteLength': owned.length,
          'sha256': digest,
        };
        await _commit(next);
        return _ref(id);
      } on MaterialStoreException {
        rethrow;
      } catch (_) {
        throw const MaterialStoreException(MaterialErrorCode.writeFailed);
      }
    });
  }

  @override
  Future<ArtifactRef> importArtifact(Uint8List bytes) {
    final owned = Uint8List.fromList(bytes);
    return _run(() async {
      _writable();
      final id = _id();
      final destination = _blob(id);
      // The destination ID is independent of caller input and never reused.
      final temp = File('${destination.path}.next');
      try {
        if (await _regular(destination) || await _regular(temp)) {
          throw const MaterialStoreException(MaterialErrorCode.writeFailed);
        }
        await temp.writeAsBytes(owned, flush: true);
        final digest = _hash(owned);
        if (_hash(await temp.readAsBytes()) != digest)
          throw const MaterialStoreException(MaterialErrorCode.writeFailed);
        await temp.rename(destination.path);
        final next = _copy();
        (next['artifacts'] as Map<String, dynamic>)[id] = {
          'id': id,
          'byteLength': owned.length,
          'sha256': digest,
        };
        await _commit(next);
        return _ref(id);
      } on MaterialStoreException {
        rethrow;
      } catch (_) {
        throw const MaterialStoreException(MaterialErrorCode.writeFailed);
      }
    });
  }

  @override
  Future<Uint8List> readArtifact(ArtifactRef ref) => _run(() async {
    _artifactIds([ref]);
    await _verify(ref);
    try {
      final bytes = await _blob(ref.artifactId).readAsBytes();
      if (bytes.length != ref.byteLength || _hash(bytes) != ref.sha256) {
        throw const MaterialStoreException(MaterialErrorCode.artifactCorrupt);
      }
      return bytes;
    } on MaterialStoreException {
      rethrow;
    } catch (_) {
      throw MaterialStoreException(
        MaterialErrorCode.missingArtifact,
        resourceId: ref.artifactId,
      );
    }
  });
  @override
  Future<void> close() => _run(() async {
    _closed = true;
  });
}
