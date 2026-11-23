import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:learning_core/learning_core.dart';
import 'package:material_core/material_core.dart';

import 'root_lock.dart';
import 'strict_json.dart';
import 'windows_privacy.dart';

String _hash(List<int> bytes) => sha256.convert(bytes).toString();
String _jsonHash(Object? value) => _hash(utf8.encode(jsonEncode(value)));
Never _fail(String code) => throw StateError('media_ingest_$code');
final _hex64 = RegExp(r'^[0-9a-f]{64}$');
final _hex32 = RegExp(r'^[0-9a-f]{32}$');

String _string(
  String value,
  int budget, {
  bool empty = false,
  bool line = false,
}) {
  if ((!empty && value.trim().isEmpty) || value.length > budget)
    _fail('invalid_text');
  for (var i = 0; i < value.length; i++) {
    final u = value.codeUnitAt(i);
    if (u >= 0xd800 && u <= 0xdbff) {
      if (++i == value.length ||
          value.codeUnitAt(i) < 0xdc00 ||
          value.codeUnitAt(i) > 0xdfff)
        _fail('invalid_unicode');
    } else if (u >= 0xdc00 && u <= 0xdfff) {
      _fail('invalid_unicode');
    } else if (u == 127 ||
        (u >= 128 && u <= 159) ||
        (u < 32 && (line || !{9, 10, 13}.contains(u)))) {
      _fail('invalid_text');
    }
  }
  if (utf8.encode(value).length > budget) _fail('text_budget');
  return value;
}

Map<String, Object?> _decl(SourceDeclaration d) {
  final result = <String, Object?>{
    'preparation': _string(d.preparation, 8192),
    'provider': d.provider,
    'model': d.model,
    'modelVersion': d.modelVersion,
    'notes': d.notes,
  };
  for (final v in [d.provider, d.model, d.modelVersion, d.notes]) {
    if (v != null) _string(v, 8192, empty: true);
  }
  if (utf8.encode(jsonEncode(result)).length > 8192)
    _fail('declaration_budget');
  return result;
}

SourceDeclaration _readDecl(Map<String, dynamic> d) => SourceDeclaration(
  preparation: d['preparation'] as String,
  provider: d['provider'] as String?,
  model: d['model'] as String?,
  modelVersion: d['modelVersion'] as String?,
  notes: d['notes'] as String?,
);

final class MediaIngestSourceBinding {
  const MediaIngestSourceBinding({
    required this.materialId,
    required this.materialVersionId,
    required this.sourceTextSha256,
  });
  final String materialId, materialVersionId, sourceTextSha256;
  Map<String, Object?> _record() => {
    'materialId': materialId,
    'materialVersionId': materialVersionId,
    'sourceTextSha256': sourceTextSha256,
  };
  bool _same(MediaIngestSourceBinding b) =>
      jsonEncode(_record()) == jsonEncode(b._record());
}

/// Trusted App lease, never an authorization object decoded from transport.
final class MediaIngestGrant {
  const MediaIngestGrant({
    required this.ownerId,
    required this.integrationId,
    required this.binding,
    required this.allowMedia,
    required this.isValid,
  });
  final String ownerId, integrationId;
  final MediaIngestSourceBinding binding;
  final bool allowMedia;
  final bool Function() isValid;
}

/// Manifest only. Audio is first inspected after all chunks have arrived.
final class MediaIngestBegin {
  MediaIngestBegin({
    required this.binding,
    required this.deliveryId,
    required this.submissionSha256,
    required this.englishSha256,
    required this.mediaSha256,
    required this.mediaBytes,
    required List<SentenceTiming> timings,
    required this.declaration,
    required this.timingDeclaration,
  }) : timings = List.unmodifiable(timings);
  final MediaIngestSourceBinding binding;
  final String deliveryId,
      submissionSha256,
      englishSha256,
      mediaSha256,
      timingDeclaration;
  final int mediaBytes;
  final List<SentenceTiming> timings;
  final SourceDeclaration declaration;
  Map<String, Object?> _media() => {
    'sha256': mediaSha256,
    'byteLength': mediaBytes,
    'englishSha256': englishSha256,
    'pcm': {
      'format': 1,
      'channels': 1,
      'sampleRate': 16000,
      'bitsPerSample': 16,
    },
    'timings': [
      for (final t in timings)
        {
          'sentenceIndex': t.sentenceIndex,
          'startMs': t.startMs,
          'endMs': t.endMs,
        },
    ],
    'declaration': _decl(declaration),
    'timingDeclaration': timingDeclaration,
  };
  Map<String, Object?> _record() => {
    'binding': binding._record(),
    'deliveryId': deliveryId,
    'submissionSha256': submissionSha256,
    'media': _media(),
  };
}

final class MediaIngestSubmission {
  MediaIngestSubmission({
    required this.binding,
    required this.deliveryId,
    required List<LearningSentenceInput> sentences,
    required this.declaration,
    required this.media,
  }) : sentences = List.unmodifiable(sentences);
  final MediaIngestSourceBinding binding;
  final String deliveryId;
  final List<LearningSentenceInput> sentences;
  final SourceDeclaration declaration;
  final MediaIngestBegin media;
  Map<String, Object?> _payload() {
    if (sentences.isEmpty || sentences.length > 128) _fail('sentence_count');
    var total = 0;
    final rows = <Map<String, Object?>>[];
    for (final s in sentences) {
      _string(s.english, 102400);
      _string(s.translation, 102400);
      total +=
          utf8.encode(s.english).length + utf8.encode(s.translation).length;
      if (total > 102400) _fail('text_budget');
      rows.add({'english': s.english, 'translation': s.translation});
    }
    return {
      'schema': 2,
      'materialId': binding.materialId,
      'materialVersionId': binding.materialVersionId,
      'sourceTextSha256': binding.sourceTextSha256,
      'deliveryId': deliveryId,
      'sentences': rows,
      'declaration': _decl(declaration),
      'media': media._media(),
    };
  }
}

/// Same ordered semantic encoding as B2B. This does not authorize delivery.
String mediaIngestPayloadSha256(MediaIngestSubmission input) =>
    _jsonHash(input._payload());

final class MediaIngestReceipt {
  const MediaIngestReceipt({
    required this.uploadId,
    required this.status,
    this.acceptedBytes = 0,
    this.replayed = false,
    this.sealedReceipt,
    this.candidateId,
    this.payloadSha256,
  });
  final String uploadId, status;
  final int acceptedBytes;
  final bool replayed;
  final String? sealedReceipt, candidateId, payloadSha256;
}

final class _Upload {
  _Upload(
    this.id,
    this.begin,
    this.integrationId,
    this.operationKey,
    this.businessKey,
  );
  final String id, integrationId, operationKey, businessKey;
  final MediaIngestBegin begin;
  int bytes = 0;
  final chunks = <String, String>{};
  String phase = 'receiving';
  String? receipt;
  bool stopped = false, cleaned = false, unknown = false;
  MediaIngestGrant? lease;
}

/// Bounded private lifecycle. The caller owns the Stores and the root lock.
final class MediaIngest {
  MediaIngest._(
    this._root,
    this._lock,
    this._materials,
    this._learning,
    this._registration,
    this._media,
    this._owner,
  );
  final Directory _root;
  final LearningRootLock _lock;
  final MaterialStore _materials;
  final LearningStore _learning;
  final IdempotentArtifactStore _registration;
  final LearningMediaCandidateStore _media;
  final String _owner;
  final _uploads = <String, _Upload>{};
  final _retired = <MediaIngestGrant>{};
  static final _openRoots = <String>{};
  String? _openKey;
  bool _closed = false, _held = false, _busy = false;
  Future<void> _drain = Future.value();
  Future<void> _lifecycle = Future.value();
  Future<void>? _closeFuture;
  static const _stagingLimit = 4 * 1024 * 1024;
  String _path(String name) =>
      '${_root.path}${Platform.pathSeparator}${name.replaceAll('/', Platform.pathSeparator)}';
  File _part(_Upload u) => File(_path('${u.id}/media.part'));
  File _journal(_Upload u) => File(_path('${u.id}/journal.json'));
  String _business(String integration, String delivery) =>
      _jsonHash([_owner, integration, delivery]);
  String _operation(String integration, String delivery) => _jsonHash([
    'shiyu-media-ingest-artifact:v1',
    _owner,
    integration,
    delivery,
  ]);
  String _random(int count) {
    final r = Random.secure();
    return [
      for (var i = 0; i < count; i++)
        r.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
  }

  static Future<MediaIngest> open({
    required Directory privateRoot,
    required LearningRootLock rootLock,
    required Object materials,
    required Object learning,
    required String ownerId,
    DateTime Function()? clock,
  }) async {
    if (materials is! MaterialStore ||
        materials is! IdempotentArtifactStore ||
        learning is! LearningStore ||
        learning is! LearningCandidateStore ||
        learning is! LearningMediaCandidateStore)
      _fail('capability_pair_required');
    if (materials.trustedOwnerId != ownerId ||
        learning.trustedOwnerId != ownerId)
      _fail('owner_mismatch');
    if (!rootLock.isHeld) _fail('root_lock_required');
    final requested = privateRoot.absolute;
    final resolvedParent = Platform.isWindows
        ? WindowsPrivacy.instance.canonicalPath(requested.parent.path)
        : await requested.parent.resolveSymbolicLinks();
    String key(String p) {
      final value = Directory(p).absolute.uri
          .normalizePath()
          .toFilePath()
          .replaceAll('\\', '/')
          .replaceAll(RegExp(r'/+$'), '');
      return Platform.isWindows ? value.toLowerCase() : value;
    }

    // A direct private child avoids following an unverified intermediate path.
    if (key(resolvedParent) != key(rootLock.rootDirectory.path))
      _fail('root_outside_lock');
    final leaf = requested.path
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'/+$'), '')
        .split('/')
        .last;
    if (leaf.isEmpty || leaf == '.' || leaf == '..') _fail('root_outside_lock');
    final root = Directory('$resolvedParent${Platform.pathSeparator}$leaf');
    final module = MediaIngest._(
      root,
      rootLock,
      materials,
      learning,
      materials as IdempotentArtifactStore,
      learning as LearningMediaCandidateStore,
      ownerId,
    );
    final openKey = key(root.path);
    if (!_openRoots.add(openKey)) _fail('already_open');
    module._openKey = openKey;
    try {
      await module._prepareRoot();
      await module._scanRecovery();
      return module;
    } catch (_) {
      _openRoots.remove(openKey);
      rethrow;
    }
  }

  Future<void> _regular(
    String path, {
    bool directory = false,
    bool absent = false,
  }) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound && absent) return;
    if (type !=
        (directory
            ? FileSystemEntityType.directory
            : FileSystemEntityType.file))
      _fail('unexpected_file');
    if (Platform.isWindows) {
      WindowsPrivacy.instance.rejectReparse(path);
      WindowsPrivacy.instance.verify(path);
    }
  }

  Future<void> _prepareRoot() async {
    if (Platform.isWindows)
      WindowsPrivacy.instance.rejectReparse(_lock.rootDirectory.path);
    final existing = await FileSystemEntity.type(
      _root.path,
      followLinks: false,
    );
    if (existing == FileSystemEntityType.notFound) {
      await _root.create();
      if (Platform.isWindows) WindowsPrivacy.instance.secureNew(_root.path);
    }
    await _regular(_root.path, directory: true);
    final holdType = await FileSystemEntity.type(
      _path('hold'),
      followLinks: false,
    );
    if (holdType != FileSystemEntityType.notFound) _fail('recovery_hold');
    final marker = File(_path('marker'));
    final markerType = await FileSystemEntity.type(
      marker.path,
      followLinks: false,
    );
    if (markerType != FileSystemEntityType.file &&
        markerType != FileSystemEntityType.notFound)
      _fail('invalid_marker');
    if (markerType == FileSystemEntityType.notFound) {
      if (!await _root.list(followLinks: false).isEmpty) {
        await _hold();
      }
      await marker.create(exclusive: true);
      await marker.writeAsString('media-ingest:2', flush: true);
      if (Platform.isWindows) WindowsPrivacy.instance.secureNew(marker.path);
    }
    await _regular(marker.path);
    if (await marker.readAsString() != 'media-ingest:2') await _hold();
  }

  Future<Never> _hold() async {
    _held = true;
    final hold = File(_path('hold'));
    final type = await FileSystemEntity.type(hold.path, followLinks: false);
    if (type != FileSystemEntityType.notFound) _fail('recovery_hold');
    await hold.create(exclusive: true);
    await hold.writeAsString('media-ingest:hold', flush: true);
    if (Platform.isWindows) WindowsPrivacy.instance.secureNew(hold.path);
    _fail('recovery_hold');
  }

  void _identity(
    MediaIngestGrant g,
    MediaIngestSourceBinding b, {
    _Upload? upload,
  }) {
    if (g.ownerId != _owner ||
        !g.binding._same(b) ||
        !g.allowMedia ||
        (upload != null &&
            (g.integrationId != upload.integrationId ||
                !upload.begin.binding._same(b))))
      _fail('identity_mismatch');
  }

  void _gate(
    MediaIngestGrant g,
    MediaIngestSourceBinding b, {
    _Upload? upload,
  }) {
    _identity(g, b, upload: upload);
    if (_closed ||
        _held ||
        !_lock.isHeld ||
        _retired.contains(g) ||
        !g.isValid() ||
        (upload != null && (upload.stopped || upload.phase == 'terminal')))
      _fail('stopped_or_forbidden');
    if (_materials.recoveryReport.issues.any(
          (i) => i.kind == RecoveryIssueKind.registrationHold,
        ) ||
        {_materials.recoveryReport.status}.any(
          (s) =>
              s == RecoveryStatus.recoveredFromBackup ||
              s == RecoveryStatus.unrecoverable,
        ) ||
        _learning.recoveryReport.issues.any(
          (s) => s.startsWith('recovery_hold:'),
        ) ||
        _learning.recoveryReport.status ==
            LearningRecoveryStatus.unrecoverable ||
        _learning.recoveryReport.status ==
            LearningRecoveryStatus.recoveredFromBackup)
      _fail('store_hold');
  }

  Future<T> _run<T>(Future<T> Function() action) {
    if (_busy) return Future.error(StateError('media_ingest_busy'));
    _busy = true;
    final done = Completer<void>();
    _drain = done.future;
    return Future.sync(action).whenComplete(() {
      _busy = false;
      done.complete();
    });
  }

  CandidateSender _sender(String integration) => CandidateSender(
    integrationId: integration,
    transport: CandidateTransport.localCapability,
  );
  void _manifest(MediaIngestBegin b) {
    if (!_hex32.hasMatch(b.binding.materialId) ||
        !_hex32.hasMatch(b.binding.materialVersionId) ||
        !_hex64.hasMatch(b.binding.sourceTextSha256) ||
        !_hex64.hasMatch(b.submissionSha256) ||
        !_hex64.hasMatch(b.englishSha256) ||
        !_hex64.hasMatch(b.mediaSha256))
      _fail('invalid_manifest');
    _string(b.deliveryId, 256, line: true);
    if (b.mediaBytes < 46 ||
        b.mediaBytes > 1920044 ||
        (b.mediaBytes - 44).isOdd ||
        b.timings.isEmpty ||
        b.timings.length > 128)
      _fail('invalid_manifest');
    _string(b.timingDeclaration, 8192);
    if (utf8.encode(jsonEncode(_decl(b.declaration))).length +
            utf8.encode(b.timingDeclaration).length >
        8192)
      _fail('declaration_budget');
    var previous = 0;
    for (var i = 0; i < b.timings.length; i++) {
      final t = b.timings[i];
      if (t.sentenceIndex != i ||
          t.startMs < previous ||
          t.endMs <= t.startMs ||
          t.endMs > 60000 ||
          t.endMs * 32000 > (b.mediaBytes - 44) * 1000)
        _fail('invalid_timings');
      previous = t.endMs;
    }
  }

  Future<void> _source(MediaIngestSourceBinding b) async {
    final source = await _materials.readVersion(b.materialVersionId);
    _string(source.text, source.text.length * 4 + 1, empty: true);
    if (source.ownerId != _owner ||
        source.materialId != b.materialId ||
        _hash(utf8.encode(source.text)) != b.sourceTextSha256)
      _fail('source_mismatch');
  }

  Future<(ArtifactRef?, CandidateDeliveryReceipt?)> _authorities(
    _Upload u,
  ) async {
    try {
      final a = await _registration.findArtifactRegistration(u.operationKey);
      final d = await _media.findDeliveryReceipt(
        sender: _sender(u.integrationId),
        deliveryId: u.begin.deliveryId,
        inputVersion: 2,
        expectedPayloadSha256: u.begin.submissionSha256,
      );
      if (a != null &&
          (a.ownerId != _owner ||
              a.sha256 != u.begin.mediaSha256 ||
              a.byteLength != u.begin.mediaBytes))
        _fail('artifact_conflict');
      return (a, d);
    } on LearningStoreException catch (e) {
      if (e.code == LearningErrorCode.deliveryConflict) rethrow;
      u.unknown = true;
      await _hold();
    } catch (_) {
      u.unknown = true;
      await _hold();
    }
  }

  Map<String, Object?> _record(_Upload u) => {
    'version': 2,
    'id': u.id,
    'owner': _owner,
    'integration': u.integrationId,
    'businessKey': u.businessKey,
    'operationKey': u.operationKey,
    'begin': u.begin._record(),
    'phase': u.phase,
    'bytes': u.bytes,
    'chunks': u.chunks,
    'receipt': u.receipt,
    'cleaned': u.cleaned,
    'unknown': u.unknown,
  };
  Future<void> _writeJournal(_Upload u, {void Function()? check}) async {
    try {
      check?.call();
      final data = _record(u);
      final encoded = jsonEncode({'record': data, 'sha256': _jsonHash(data)});
      if (utf8.encode(encoded).length > 256 * 1024) _fail('journal_budget');
      final journal = _journal(u),
          next = File('${_journal(u).path}.next'),
          bak = File('${_journal(u).path}.bak');
      await _regular(Directory(journal.path).parent.path, directory: true);
      check?.call();
      await _regular(next.path, absent: true);
      check?.call();
      await _regular(journal.path, absent: true);
      check?.call();
      await _regular(bak.path, absent: true);
      check?.call();
      await next.writeAsString(encoded, flush: true);
      if (Platform.isWindows) WindowsPrivacy.instance.secureNew(next.path);
      check?.call();
      if (await next.readAsString() != encoded) _fail('journal_readback');
      check?.call();
      final exists = await journal.exists();
      check?.call();
      if (exists) {
        await journal.copy(bak.path);
        if (Platform.isWindows) WindowsPrivacy.instance.secureNew(bak.path);
        check?.call();
      }
      await next.rename(journal.path);
      check?.call();
    } catch (_) {
      // A write attempt must not become an ACK from volatile counters on retry.
      u.stopped = true;
      u.unknown = true;
      await _hold();
    }
  }

  Future<int> _staging() async {
    var size = 0;
    for (final u in _uploads.values) {
      final file = _part(u);
      await _regular(file.path, absent: true);
      if (await file.exists()) {
        size += await file.length();
      } else if (!u.cleaned) {
        size += u.begin.mediaBytes;
      }
    }
    return size;
  }

  Future<MediaIngestReceipt> begin(
    MediaIngestGrant g,
    MediaIngestBegin b,
  ) => _run(() async {
    _gate(g, b.binding);
    _manifest(b);
    if (!RegExp(r'^[A-Za-z0-9:_-]{1,160}$').hasMatch(g.integrationId))
      _fail('invalid_integration');
    await _source(b.binding);
    _gate(g, b.binding);
    final business = _business(g.integrationId, b.deliveryId);
    final same = _uploads.values
        .where((u) => u.businessKey == business)
        .firstOrNull;
    if (same != null) {
      if (jsonEncode(same.begin._record()) != jsonEncode(b._record()))
        _fail('business_conflict');
      await _authorities(same);
      _gate(g, b.binding);
      if (same.phase == 'terminal')
        return MediaIngestReceipt(
          uploadId: same.id,
          status: 'terminal',
          replayed: true,
        );
      if (same.stopped && (same.phase != 'sealed' || identical(same.lease, g)))
        _fail('stopped_or_forbidden');
      same.lease = g;
      same.stopped = false;
      return MediaIngestReceipt(
        uploadId: same.id,
        status: same.phase,
        acceptedBytes: same.bytes,
        replayed: true,
        sealedReceipt: same.receipt,
      );
    }
    final u = _Upload(
      _random(16),
      b,
      g.integrationId,
      _operation(g.integrationId, b.deliveryId),
      business,
    )..lease = g;
    final authority = await _authorities(u);
    _gate(g, b.binding);
    if (authority.$1 != null || authority.$2 != null) await _hold();
    if (_uploads.length >= 128 ||
        await _staging() + b.mediaBytes > _stagingLimit)
      _fail('capacity_exceeded');
    for (final previous in _uploads.values) {
      if (previous.phase == 'terminal') continue;
      final previousAuthority = await _authorities(previous);
      _gate(g, b.binding);
      if (previousAuthority.$2 == null) _fail('capacity_exceeded');
    }
    _gate(g, b.binding);
    final dir = Directory(_path(u.id));
    await dir.create();
    if (Platform.isWindows) WindowsPrivacy.instance.secureNew(dir.path);
    _gate(g, b.binding);
    await _part(u).writeAsBytes(const [], flush: true);
    if (Platform.isWindows) WindowsPrivacy.instance.secureNew(_part(u).path);
    _gate(g, b.binding);
    _uploads[u.id] = u;
    await _writeJournal(u, check: () => _gate(g, b.binding, upload: u));
    _gate(g, b.binding, upload: u);
    return MediaIngestReceipt(uploadId: u.id, status: 'receiving');
  });
  _Upload _upload(MediaIngestGrant g, MediaIngestSourceBinding b, String id) {
    final u = _uploads[id];
    if (u == null) _fail('unknown_upload');
    _gate(g, b, upload: u);
    u.lease = g;
    return u;
  }

  Future<MediaIngestReceipt> chunk(
    MediaIngestGrant g,
    MediaIngestSourceBinding b,
    String id,
    int index,
    Uint8List bytes,
    String claimedHash,
  ) => _run(() async {
    final u = _upload(g, b, id);
    if (u.phase != 'receiving' ||
        bytes.isEmpty ||
        bytes.length > 65536 ||
        !_hex64.hasMatch(claimedHash) ||
        _hash(bytes) != claimedHash ||
        index < 0)
      _fail('chunk_invalid');
    if (index < u.chunks.length) {
      if (u.chunks['$index'] != claimedHash) _fail('chunk_conflict');
      final file = await _part(u).open();
      try {
        await file.setPosition(index * 65536);
        final previous = await file.read(bytes.length);
        if (_hash(previous) != claimedHash) _fail('chunk_conflict');
      } finally {
        await file.close();
      }
      _gate(g, b, upload: u);
      return MediaIngestReceipt(
        uploadId: id,
        status: 'receiving',
        acceptedBytes: u.bytes,
        replayed: true,
      );
    }
    final remaining = u.begin.mediaBytes - u.bytes;
    if (index != u.chunks.length ||
        bytes.length != (remaining > 65536 ? 65536 : remaining))
      _fail('chunk_invalid');
    if (await _staging() + bytes.length > _stagingLimit)
      _fail('capacity_exceeded');
    _gate(g, b, upload: u);
    await _regular(_part(u).path);
    _gate(g, b, upload: u);
    final file = await _part(u).open(mode: FileMode.writeOnlyAppend);
    try {
      _gate(g, b, upload: u);
      await file.writeFrom(bytes);
      _gate(g, b, upload: u);
      await file.flush();
    } finally {
      await file.close();
    }
    _gate(g, b, upload: u);
    u.bytes += bytes.length;
    u.chunks['$index'] = claimedHash;
    await _writeJournal(u, check: () => _gate(g, b, upload: u));
    _gate(g, b, upload: u);
    return MediaIngestReceipt(
      uploadId: id,
      status: 'receiving',
      acceptedBytes: u.bytes,
    );
  });
  Future<Uint8List> _bytes(_Upload u) async {
    await _regular(_part(u).path);
    final bytes = await _part(u).readAsBytes();
    if (bytes.length != u.begin.mediaBytes ||
        _hash(bytes) != u.begin.mediaSha256)
      _fail('media_hash');
    inspectExternalCandidateMedia(
      bytes: bytes,
      timings: u.begin.timings,
      sentenceCount: u.begin.timings.length,
    );
    return bytes;
  }

  Future<MediaIngestReceipt> seal(
    MediaIngestGrant g,
    MediaIngestSourceBinding b,
    String id,
  ) => _run(() async {
    final u = _upload(g, b, id);
    if (u.bytes != u.begin.mediaBytes) _fail('chunk_missing');
    await _bytes(u);
    _gate(g, b, upload: u);
    final replayed = u.phase == 'sealed';
    u.phase = 'sealed';
    u.receipt ??= _random(32);
    await _writeJournal(u, check: () => _gate(g, b, upload: u));
    _gate(g, b, upload: u);
    return MediaIngestReceipt(
      uploadId: id,
      status: 'sealed',
      sealedReceipt: u.receipt,
      replayed: replayed,
    );
  });
  Future<MediaIngestReceipt> submit(
    MediaIngestGrant g,
    MediaIngestSourceBinding b,
    String sealedReceipt,
    MediaIngestSubmission input,
  ) => _run(() async {
    final u = _uploads.values
        .where((u) => u.receipt == sealedReceipt)
        .firstOrNull;
    if (u == null || u.phase != 'sealed') _fail('unknown_receipt');
    _gate(g, b, upload: u);
    u.lease = g;
    _manifest(input.media);
    if (!input.binding._same(b) ||
        input.deliveryId != u.begin.deliveryId ||
        jsonEncode(input.media._record()) != jsonEncode(u.begin._record()) ||
        input.sentences.length != u.begin.timings.length)
      _fail('submission_binding');
    final payload = input._payload();
    if (_jsonHash(payload) != u.begin.submissionSha256 ||
        _jsonHash(input.sentences.map((s) => s.english).toList()) !=
            u.begin.englishSha256)
      _fail('submission_hash');
    encodeAgentBridgeJson({
      'schema_version': 2,
      ...payload,
      'sealed_receipt': sealedReceipt,
    }, maxBytes: 196608);
    await _source(b);
    _gate(g, b, upload: u);
    final bytes = await _bytes(u);
    _gate(g, b, upload: u);
    await _authorities(u);
    _gate(g, b, upload: u);
    // This records intent/uncertainty only, never a copied registration fact.
    u.unknown = true;
    await _writeJournal(u, check: () => _gate(g, b, upload: u));
    _gate(g, b, upload: u);
    final artifact = await _registration.registerArtifactOnce(
      operationKey: u.operationKey,
      expectedSha256: u.begin.mediaSha256,
      bytes: bytes,
    );
    _gate(g, b, upload: u);
    final found = (await _authorities(u)).$1;
    _gate(g, b, upload: u);
    if (found == null ||
        found.artifactId != artifact.artifactId ||
        found.sha256 != u.begin.mediaSha256 ||
        found.byteLength != bytes.length)
      _fail('registration_unknown');
    final receipt = await _media.receiveMediaCandidate(
      sender: CandidateSender(
        integrationId: u.integrationId,
        // C1 has no transport. C2 must supply actual request-byte context.
        transport: CandidateTransport.controlledTest,
      ),
      input: LearningMediaCandidateInput(
        text: LearningCandidateInput(
          materialId: b.materialId,
          materialVersionId: b.materialVersionId,
          sourceTextSha256: b.sourceTextSha256,
          deliveryId: input.deliveryId,
          sentences: input.sentences,
          declaration: input.declaration,
        ),
        media: LearningCandidateMediaInput(
          artifact: found,
          englishSha256: u.begin.englishSha256,
          declaration: u.begin.declaration,
          timingDeclaration: u.begin.timingDeclaration,
          timings: u.begin.timings,
        ),
      ),
    );
    _gate(g, b, upload: u);
    u.unknown = false;
    await _writeJournal(u, check: () => _gate(g, b, upload: u));
    _gate(g, b, upload: u);
    return MediaIngestReceipt(
      uploadId: u.id,
      status: 'delivered',
      candidateId: receipt.candidateId,
      payloadSha256: receipt.payloadSha256,
      replayed: receipt.replayed,
    );
  });
  Future<void> _terminate(_Upload u) async {
    await _drain;
    if (u.phase == 'terminal' && u.cleaned) return;
    u.phase = 'terminal';
    try {
      final authority = await _authorities(u);
      if (authority.$1 == null && authority.$2 == null) {
        await _regular(_part(u).path, absent: true);
        if (await _part(u).exists()) await _part(u).delete();
        u.cleaned = true;
        u.unknown = false;
      }
    } catch (_) {
      u.unknown = true;
    }
    await _writeJournal(u);
  }

  Future<void> _scheduleStop(List<_Upload> uploads) {
    final next = _lifecycle.then((_) async {
      await _drain;
      for (final u in uploads) {
        await _terminate(u);
      }
    });
    _lifecycle = next.catchError((Object _) {});
    return next;
  }

  Future<MediaIngestReceipt> abort(
    MediaIngestGrant g,
    MediaIngestSourceBinding b,
    String id,
  ) {
    final u = _uploads[id];
    _identity(g, b, upload: u);
    if (_closed || _retired.contains(g) || !g.isValid())
      _fail('stopped_or_forbidden');
    if (u == null)
      return Future.value(MediaIngestReceipt(uploadId: id, status: 'terminal'));
    u.stopped = true;
    u.phase = 'terminal';
    return _scheduleStop([u])
        .then((_) => MediaIngestReceipt(uploadId: id, status: 'terminal'));
  }

  Future<void> retireGrant(MediaIngestGrant g) {
    _identity(g, g.binding);
    if (_closed) return _closeFuture ?? Future<void>.value();
    _retired.add(g);
    final affected = _uploads.values
        .where((u) => identical(u.lease, g))
        .toList();
    final receiving = affected.where((u) => u.phase == 'receiving').toList();
    for (final u in affected) {
      u.stopped = true;
    }
    for (final u in receiving) {
      u.phase = 'terminal';
    }
    return _scheduleStop(receiving);
  }

  Future<void> close() {
    _closed = true;
    for (final u in _uploads.values) {
      u.stopped = true;
    }
    return _closeFuture ??= () async {
      await _drain;
      await _lifecycle;
      _openRoots.remove(_openKey);
    }();
  }

  MediaIngestBegin _readBegin(Map<String, dynamic> record) {
    final binding = record['binding'] as Map<String, dynamic>;
    final media = record['media'] as Map<String, dynamic>;
    final begin = MediaIngestBegin(
      binding: MediaIngestSourceBinding(
        materialId: binding['materialId'] as String,
        materialVersionId: binding['materialVersionId'] as String,
        sourceTextSha256: binding['sourceTextSha256'] as String,
      ),
      deliveryId: record['deliveryId'] as String,
      submissionSha256: record['submissionSha256'] as String,
      englishSha256: media['englishSha256'] as String,
      mediaSha256: media['sha256'] as String,
      mediaBytes: media['byteLength'] as int,
      timings: [
        for (final t in media['timings'] as List)
          SentenceTiming(
            sentenceIndex: t['sentenceIndex'] as int,
            startMs: t['startMs'] as int,
            endMs: t['endMs'] as int,
          ),
      ],
      declaration: _readDecl(media['declaration'] as Map<String, dynamic>),
      timingDeclaration: media['timingDeclaration'] as String,
    );
    _manifest(begin);
    if (jsonEncode(begin._record()) != jsonEncode(record))
      _fail('journal_shape');
    return begin;
  }

  Future<Map<String, dynamic>> _readJournal(File file) async {
    await _regular(file.path);
    if (await file.length() > 256 * 1024) _fail('journal_budget');
    final value = decodeAgentBridgeJson(
      await file.readAsBytes(),
      maxBytes: 256 * 1024,
    );
    if (value is! Map<String, dynamic> ||
        value.length != 2 ||
        value['record'] is! Map<String, dynamic> ||
        value['sha256'] != _jsonHash(value['record']))
      _fail('journal_checksum');
    return value['record'] as Map<String, dynamic>;
  }

  _Upload _restoreRecord(Map<String, dynamic> r, String id) {
    final begin = _readBegin(r['begin'] as Map<String, dynamic>);
    final integration = r['integration'] as String;
    if (!RegExp(r'^[A-Za-z0-9:_-]{1,160}$').hasMatch(integration))
      _fail('journal_identity');
    final u = _Upload(
      id,
      begin,
      integration,
      _operation(integration, begin.deliveryId),
      _business(integration, begin.deliveryId),
    );
    if (r['version'] != 2 ||
        r['id'] != id ||
        r['owner'] != _owner ||
        r['operationKey'] != u.operationKey ||
        r['businessKey'] != u.businessKey)
      _fail('journal_identity');
    u.phase = r['phase'] as String;
    u.bytes = r['bytes'] as int;
    u.receipt = r['receipt'] as String?;
    u.cleaned = r['cleaned'] as bool;
    u.unknown = r['unknown'] as bool;
    if (!{'receiving', 'sealed', 'terminal'}.contains(u.phase) ||
        u.bytes < 0 ||
        u.bytes > begin.mediaBytes ||
        (u.receipt != null && !_hex64.hasMatch(u.receipt!)) ||
        (u.phase == 'sealed' &&
            (u.receipt == null || u.bytes != begin.mediaBytes)) ||
        (u.phase == 'receiving' && u.receipt != null) ||
        (u.cleaned && u.phase != 'terminal'))
      _fail('journal_state');
    final chunks = r['chunks'] as Map<String, dynamic>;
    if (chunks.length > 32) _fail('journal_chunks');
    for (var i = 0; i < chunks.length; i++) {
      final h = chunks['$i'];
      if (h is! String || !_hex64.hasMatch(h)) _fail('journal_chunks');
      u.chunks['$i'] = h;
    }
    if (min(chunks.length * 65536, begin.mediaBytes) != u.bytes ||
        jsonEncode(_record(u)) != jsonEncode(r))
      _fail('journal_shape');
    return u;
  }

  Future<void> _scanRecovery() async {
    try {
      await for (final e in _root.list(followLinks: false)) {
        if (e.path == _path('marker')) continue;
        await _regular(e.path, directory: true);
        final id = e.path.replaceAll('\\', '/').split('/').last;
        if (!_hex32.hasMatch(id) || _uploads.length >= 128)
          _fail('journal_identity');
        final journal = File('${e.path}${Platform.pathSeparator}journal.json');
        final allowed = {'journal.json', 'journal.json.bak', 'media.part'};
        await for (final child in Directory(e.path).list(followLinks: false)) {
          if (!allowed.contains(
            child.path.replaceAll('\\', '/').split('/').last,
          ))
            _fail('unowned_residue');
          await _regular(child.path);
        }
        final r = await _readJournal(journal);
        final u = _restoreRecord(r, id), begin = u.begin;
        if (_uploads.values.any((v) => v.businessKey == u.businessKey))
          _fail('journal_identity');
        final bak = File('${journal.path}.bak');
        if (await bak.exists()) {
          final b = _restoreRecord(await _readJournal(bak), id);
          final transitions = {
            'receiving': {'receiving', 'sealed', 'terminal'},
            'sealed': {'sealed', 'terminal'},
            'terminal': {'terminal'},
          };
          if (b.businessKey != u.businessKey ||
              b.operationKey != u.operationKey ||
              jsonEncode(b.begin._record()) != jsonEncode(u.begin._record()) ||
              b.bytes > u.bytes ||
              !transitions[b.phase]!.contains(u.phase) ||
              (b.cleaned && !u.cleaned) ||
              (b.receipt != null && b.receipt != u.receipt) ||
              b.chunks.entries.any((e) => u.chunks[e.key] != e.value))
            _fail('journal_backup');
        }
        final part = _part(u);
        if (u.cleaned) {
          if (await part.exists()) _fail('cleanup_residue');
        } else {
          await _regular(part.path);
          if (await part.length() != u.bytes) _fail('accepted_length');
          final bytes = await part.readAsBytes();
          var offset = 0;
          for (var i = 0; i < u.chunks.length; i++) {
            final end = min(offset + 65536, begin.mediaBytes);
            if (end > bytes.length ||
                _hash(bytes.sublist(offset, end)) != u.chunks['$i'])
              _fail('accepted_chunk');
            offset = end;
          }
          if (offset != u.bytes) _fail('accepted_length');
          if (u.phase == 'sealed') await _bytes(u);
        }
        _uploads[u.id] = u;
      }
      if (await _staging() > _stagingLimit) _fail('capacity_exceeded');
      for (final u in _uploads.values) {
        // Reconstruction supplies no grant and never enters either Store write.
        await _authorities(u);
        if (u.phase == 'receiving') {
          u.stopped = true;
          await _terminate(u);
        } else if (u.phase == 'terminal') {
          u.stopped = true;
        }
      }
    } catch (_) {
      await _hold();
    }
  }
}
