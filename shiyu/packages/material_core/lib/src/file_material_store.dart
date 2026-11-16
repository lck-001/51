import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;

import '../material_core.dart';

/// A single-writer local cache, not account authentication or a cloud database.
final class FileMaterialStore implements MaterialStore {
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

  void _validate(Map<String, dynamic> p) {
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
    if (e['schema'] != 1 || e['payload'] is! Map<String, dynamic>) {
      throw const FormatException('invalid_manifest');
    }
    final p = e['payload'] as Map<String, dynamic>;
    if (e['sha256'] != _hash(utf8.encode(jsonEncode(p)))) {
      throw const FormatException('invalid_manifest');
    }
    _validate(p);
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
    final issues = <RecoveryIssue>[];
    Map<String, dynamic>? primary, backup;
    try {
      primary = await _snapshot(_file('manifest.json'));
    } on FormatException {
      issues.add(const RecoveryIssue(RecoveryIssueKind.manifestCorrupt));
    } on TypeError {
      issues.add(const RecoveryIssue(RecoveryIssueKind.manifestCorrupt));
    }
    try {
      backup = await _snapshot(_file('manifest.bak'));
    } on FormatException {
      issues.add(const RecoveryIssue(RecoveryIssueKind.backupCorrupt));
    } on TypeError {
      issues.add(const RecoveryIssue(RecoveryIssueKind.backupCorrupt));
    }
    if (await _regular(_file('manifest.next')) ||
        await _regular(_file('manifest.bak.next')) ||
        await _regular(_file('manifest.recovery.next'))) {
      issues.add(const RecoveryIssue(RecoveryIssueKind.pendingWrite));
    }
    var status = RecoveryStatus.clean;
    if (primary != null) {
      _data = primary;
    } else if (backup != null) {
      _data = backup;
      status = RecoveryStatus.recoveredFromBackup;
      issues.add(const RecoveryIssue(RecoveryIssueKind.backupUsed));
      await _replace(
        _file('manifest.json'),
        backup,
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
          recoveryReport: RecoveryReport(RecoveryStatus.unrecoverable, issues),
        );
      }
      _data = {
        'ownerId': trustedOwnerId,
        'sequence': 0,
        'drafts': <String, dynamic>{},
        'versions': <String, dynamic>{},
        'artifacts': <String, dynamic>{},
      };
      await _replace(_file('manifest.json'), _data);
      status = RecoveryStatus.initialized;
    }
    final marker = _file('store.marker');
    if (!await _regular(marker))
      await marker.writeAsString('material_core:1', flush: true);
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

  Future<void> _replace(
    File destination,
    Map<String, dynamic> p, {
    File? temp,
  }) async {
    final next = temp ?? _file('manifest.next');
    await _regular(destination);
    await _regular(next);
    final e = {
      'schema': 1,
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
    if (_writeBlocked)
      throw const MaterialStoreException(MaterialErrorCode.writeFailed);
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
      _report = RecoveryReport(RecoveryStatus.degraded, [
        ..._report.issues,
        const RecoveryIssue(RecoveryIssueKind.pendingWrite),
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

  @override
  Future<ArtifactRef> importArtifact(Uint8List bytes) {
    final owned = Uint8List.fromList(bytes);
    return _run(() async {
      if (_writeBlocked)
        throw const MaterialStoreException(MaterialErrorCode.writeFailed);
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
