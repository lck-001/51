import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:material_core/material_core.dart';
import 'package:material_import/material_import.dart';

/// Inject only in background tests; the normal route is a user-clicked picker.
typedef MaterialFileSelection = Future<File?> Function(String sessionId);
typedef MaterialStageRemoval = Future<void> Function(File ownedStage);

const _maxProvenanceBytes = 2 * 1024 * 1024;

/// JsonUtf8Encoder emits fresh, fixed-size buffers. Check before retaining a
/// chunk; never construct an unbounded JSON String or full encoded byte array.
final class _BoundedProvenanceSink implements Sink<List<int>> {
  final _bytes = BytesBuilder(copy: false);
  bool _closed = false;
  @override
  void add(List<int> data) {
    if (_closed) throw StateError('provenance_sink_closed');
    if (_bytes.length + data.length > _maxProvenanceBytes) {
      throw const MaterialImportException(
        MaterialImportErrorCode.outputTooLarge,
      );
    }
    _bytes.add(data);
  }

  @override
  void close() => _closed = true;
  Uint8List takeBytes() => _bytes.takeBytes();
}

/// A read-only projection avoids building a Map for every block before the
/// byte budget can reject an expanded provenance document.
final class _ProvenanceBlocks extends ListBase<Map<String, Object?>> {
  _ProvenanceBlocks(this.blocks);
  final List<MaterialTextBlock> blocks;
  @override
  int get length => blocks.length;
  @override
  set length(int value) => throw UnsupportedError('read_only_provenance');
  @override
  Map<String, Object?> operator [](int index) {
    final block = blocks[index];
    return {
      'kind': block.kind.name,
      'start': block.start,
      'end': block.end,
      'ordinal': block.ordinal,
      'part': block.partName,
    };
  }

  @override
  void operator []=(int index, Map<String, Object?> value) =>
      throw UnsupportedError('read_only_provenance');
}

Future<Uint8List> _boundedBytes(File file, int limit) async {
  if (await FileSystemEntity.type(file.path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw const MaterialImportException(MaterialImportErrorCode.readFailed);
  }
  final input = await file.open();
  final bytes = BytesBuilder(copy: false);
  try {
    while (true) {
      final chunk = await input.read(min(16384, limit - bytes.length + 1));
      if (chunk.isEmpty) break;
      if (bytes.length + chunk.length > limit) {
        throw const MaterialImportException(
          MaterialImportErrorCode.sourceTooLarge,
        );
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  } finally {
    await input.close();
  }
}

Future<void> _extractionWorker(List<Object> args) async {
  final reply = args[0] as SendPort;
  try {
    final bytes = await _boundedBytes(
      File(args[1] as String),
      (args[3] as MaterialImportLimits).sourceBytes,
    );
    final extracted = extractMaterial(
      bytes: bytes,
      filenameHint: args[2] as String,
      limits: args[3] as MaterialImportLimits,
    );
    Isolate.exit(reply, extracted);
  } on MaterialImportException catch (error) {
    Isolate.exit(reply, error.code);
  } catch (_) {
    Isolate.exit(reply, MaterialImportErrorCode.readFailed);
  }
}

/// One active local import session. It owns temporary files, never the Store,
/// original document, global playback, a provider account or network requests.
final class ClientMaterialImportController {
  ClientMaterialImportController({
    required this.materials,
    required this.stagingRoot,
    this.selection,
    this.removeStage,
    this.limits = const MaterialImportLimits(),
    this.parseTimeout = const Duration(seconds: 20),
  });
  final MaterialStore materials;
  final Directory stagingRoot;
  final MaterialFileSelection? selection;

  /// Failure-injectable private IO seam. Called only for this session's files.
  final MaterialStageRemoval? removeStage;
  final MaterialImportLimits limits;
  final Duration parseTimeout;
  static const _native = MethodChannel('shiyu/material_import');
  final _random = Random.secure();
  _ClientImportSession? _active;
  bool _retired = false;
  bool get cleanupPending => _active?._cleanupPending ?? false;

  MaterialImportSession start() {
    final id = List.generate(
      16,
      (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    if (_retired || _active != null) {
      return _RejectedImportSession(
        id,
        materials.trustedOwnerId,
        _retired
            ? MaterialImportErrorCode.sessionClosed
            : MaterialImportErrorCode.busy,
      );
    }
    final session = _ClientImportSession(this, id);
    _active = session;
    session.begin();
    return session;
  }

  /// Stop new admission synchronously; close() observes cancellation completion.
  void retire() {
    _retired = true;
    final active = _active;
    if (active != null) active.markCancelled();
  }

  Future<void> close() async {
    retire();
    await _active?.cancel();
  }

  bool _owns(_ClientImportSession session) =>
      identical(_active, session) &&
      !_retired &&
      !session.cancelled &&
      session.ownerId == materials.trustedOwnerId;

  Future<void> _directory() async {
    final kind = await FileSystemEntity.type(
      stagingRoot.path,
      followLinks: false,
    );
    if (kind == FileSystemEntityType.notFound) {
      await stagingRoot.create(recursive: true);
    } else if (kind != FileSystemEntityType.directory) {
      throw const MaterialImportException(MaterialImportErrorCode.readFailed);
    }
  }

  File _file(String id, String suffix) =>
      File('${stagingRoot.path}/$id.$suffix');

  Future<String?> _choose(_ClientImportSession session) async {
    await _directory();
    if (!_owns(session)) return null;
    if (Platform.isAndroid && selection == null) {
      try {
        final reply = await _native.invokeMapMethod<String, dynamic>('pick', {
          'requestId': session.sessionId,
        });
        if (reply == null || reply['cancelled'] == true) return null;
        if (reply['requestId'] != session.sessionId ||
            reply['handle'] != session.sessionId ||
            reply['name'] is! String) {
          throw const MaterialImportException(
            MaterialImportErrorCode.bindingMismatch,
          );
        }
        return reply['name'] as String;
      } on PlatformException catch (error) {
        throw MaterialImportException(switch (error.code) {
          'too_large' => MaterialImportErrorCode.sourceTooLarge,
          'denied' => MaterialImportErrorCode.readDenied,
          'busy' => MaterialImportErrorCode.busy,
          _ => MaterialImportErrorCode.readFailed,
        });
      }
    }
    final File? selected;
    if (selection != null) {
      selected = await selection!(session.sessionId);
    } else if (Platform.isWindows) {
      final result = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(label: 'TXT / DOCX', extensions: ['txt', 'docx']),
        ],
      );
      selected = result == null ? null : File(result.path);
    } else {
      throw const MaterialImportException(
        MaterialImportErrorCode.unsupportedFormat,
      );
    }
    if (selected == null || !_owns(session)) return null;
    if (await selected.length() > limits.sourceBytes) {
      throw const MaterialImportException(
        MaterialImportErrorCode.sourceTooLarge,
      );
    }
    final next = _file(session.sessionId, 'next');
    final ready = _file(session.sessionId, 'source');
    if (await FileSystemEntity.type(next.path, followLinks: false) !=
            FileSystemEntityType.notFound ||
        await FileSystemEntity.type(ready.path, followLinks: false) !=
            FileSystemEntityType.notFound) {
      throw const MaterialImportException(MaterialImportErrorCode.readFailed);
    }
    await next.create(exclusive: true);
    session._ownedStages.add('next');
    RandomAccessFile? input, output;
    var total = 0;
    try {
      input = await selected.open();
      output = await next.open(mode: FileMode.writeOnly);
      while (true) {
        if (!_owns(session)) return null;
        final piece = await input.read(
          min(16384, limits.sourceBytes - total + 1),
        );
        if (!_owns(session)) return null;
        if (piece.isEmpty) break;
        if (total + piece.length > limits.sourceBytes) {
          throw const MaterialImportException(
            MaterialImportErrorCode.sourceTooLarge,
          );
        }
        await output.writeFrom(piece);
        total += piece.length;
      }
      await output.flush();
    } finally {
      await input?.close();
      await output?.close();
    }
    if (!_owns(session)) return null;
    // Reserve the destination exclusively; rename may replace only our own
    // placeholder, never an already existing foreign session's source.
    await ready.create(exclusive: true);
    session._ownedStages.add('source');
    await next.rename(ready.path);
    session._ownedStages.remove('next');
    return selected.uri.pathSegments.last;
  }

  Future<bool> _cancelNative(String id) async {
    if (!Platform.isAndroid || selection != null) return true;
    try {
      var state = await _native.invokeMapMethod<String, dynamic>('cancel', {
        'requestId': id,
      });
      for (var i = 0; state?['idle'] != true && i < 30; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        state = await _native.invokeMapMethod<String, dynamic>('status', {
          'requestId': id,
        });
      }
      return state?['idle'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _cleanup(_ClientImportSession session) async {
    final id = session.sessionId;
    if (Platform.isAndroid && selection == null) {
      final state = await _native.invokeMapMethod<String, dynamic>('discard', {
        'requestId': id,
      });
      if (state?['idle'] != true) {
        throw const MaterialImportException(MaterialImportErrorCode.busy);
      }
      return;
    }
    for (final suffix in List<String>.of(session._ownedStages)) {
      final file = _file(id, suffix);
      final kind = await FileSystemEntity.type(file.path, followLinks: false);
      if (kind != FileSystemEntityType.notFound) {
        if (kind != FileSystemEntityType.file) {
          throw const MaterialImportException(
            MaterialImportErrorCode.readFailed,
          );
        }
        if (removeStage != null) {
          await removeStage!(file);
        } else {
          await file.delete();
        }
      }
      session._ownedStages.remove(suffix);
    }
  }
}

final class _ClientImportSession implements MaterialImportSession {
  _ClientImportSession(this.controller, this.sessionId)
    : ownerId = controller.materials.trustedOwnerId;
  final ClientMaterialImportController controller;
  @override
  final String sessionId;
  @override
  final String ownerId;
  @override
  late final Future<MaterialImportPreview?> preview;
  final _runDone = Completer<void>();
  Isolate? _worker;
  ReceivePort? _workerPort;
  Completer<Object?>? _workerResult;
  bool cancelled = false, _finished = false;
  bool _cleanupPending = false;
  final _ownedStages = <String>{};
  ExtractedMaterial? _extracted;
  List<ArtifactRef>? _refs;
  Future<List<ArtifactRef>>? _preparing;
  String? _name;

  void begin() {
    preview = _run();
    preview.ignore();
  }

  void _check() {
    if (!controller._owns(this) || _finished) {
      throw const MaterialImportException(
        MaterialImportErrorCode.sessionClosed,
      );
    }
  }

  void markCancelled() {
    cancelled = true;
    _worker?.kill(priority: Isolate.immediate);
    _workerPort?.close();
    final result = _workerResult;
    if (result != null && !result.isCompleted) {
      result.complete(MaterialImportErrorCode.cancelled);
    }
  }

  Future<MaterialImportPreview?> _run() async {
    var keepStage = false;
    try {
      final name = await controller._choose(this);
      if (name == null || cancelled) return null;
      _check();
      _name = name;
      final port = ReceivePort();
      _workerPort = port;
      final result = Completer<Object?>();
      _workerResult = result;
      port.listen((message) {
        if (!result.isCompleted) result.complete(message);
      });
      _worker = await Isolate.spawn(
        _extractionWorker,
        <Object>[
          port.sendPort,
          controller._file(sessionId, 'source').path,
          name,
          controller.limits,
        ],
        onError: port.sendPort,
        onExit: port.sendPort,
      );
      if (cancelled) markCancelled();
      final timer = Timer(controller.parseTimeout, () {
        _worker?.kill(priority: Isolate.immediate);
        if (!result.isCompleted) {
          result.complete(MaterialImportErrorCode.timedOut);
        }
      });
      Object? value;
      try {
        value = await result.future;
      } finally {
        timer.cancel();
        _worker?.kill(priority: Isolate.immediate);
        port.close();
        _worker = null;
        _workerPort = null;
      }
      if (cancelled) return null;
      if (value is MaterialImportErrorCode) {
        throw MaterialImportException(value);
      }
      if (value is! ExtractedMaterial) {
        throw const MaterialImportException(MaterialImportErrorCode.readFailed);
      }
      _check();
      _extracted = value;
      keepStage = true;
      var title = name
          .replaceAll(RegExp(r'\.[^.]+$'), '')
          .replaceAll(RegExp(r'[\x00-\x1f/\\]'), ' ')
          .trim();
      title = String.fromCharCodes(title.runes.take(120));
      return MaterialImportPreview(
        sessionId: sessionId,
        ownerId: ownerId,
        title: title.isEmpty ? '导入的材料' : title,
        text: value.text,
        warnings: value.warnings,
        format: value.format,
        sourceSha256: value.sourceSha256,
      );
    } on MaterialImportException {
      rethrow;
    } catch (_) {
      if (cancelled) return null;
      throw const MaterialImportException(MaterialImportErrorCode.readFailed);
    } finally {
      if (!keepStage) {
        try {
          await controller._cleanup(this);
          _cleanupPending = false;
        } catch (_) {
          _cleanupPending = true;
        }
        if (!_cleanupPending &&
            !cancelled &&
            identical(controller._active, this)) {
          controller._active = null;
        }
      }
      if (!_runDone.isCompleted) _runDone.complete();
    }
  }

  @override
  Future<List<ArtifactRef>> prepareArtifacts() async {
    _check();
    if (_refs != null) return _refs!;
    final inFlight = _preparing;
    if (inFlight != null) return inFlight;
    final work = _prepare();
    _preparing = work;
    try {
      return await work;
    } finally {
      _preparing = null;
    }
  }

  Future<List<ArtifactRef>> _prepare() async {
    _check();
    final extracted = _extracted;
    if (extracted == null) {
      throw const MaterialImportException(
        MaterialImportErrorCode.sessionClosed,
      );
    }
    final bytes = await _boundedBytes(
      controller._file(sessionId, 'source'),
      controller.limits.sourceBytes,
    );
    _check();
    if (sha256.convert(bytes).toString() != extracted.sourceSha256) {
      throw const MaterialImportException(
        MaterialImportErrorCode.bindingMismatch,
      );
    }
    final metadataOutput = _BoundedProvenanceSink();
    final encoder = JsonUtf8Encoder(
      null,
      null,
      4096,
    ).startChunkedConversion(metadataOutput);
    encoder.add({
      'schema': 'shiyu-material-extraction-v1',
      'source_name': _name,
      'format': extracted.format.name,
      'parser_version': extracted.parserVersion,
      'source_sha256': extracted.sourceSha256,
      'extracted_text_sha256': extracted.textSha256,
      'blocks': _ProvenanceBlocks(extracted.blocks),
      'warnings': [for (final warning in extracted.warnings) warning.name],
    });
    encoder.close();
    final metadata = metadataOutput.takeBytes();
    _check();
    // Encode and bound the whole sidecar before either artifact is registered.
    // The source digest was already verified against the actual staged bytes.
    final source = await controller.materials.importArtifact(bytes);
    _check();
    final sidecar = await controller.materials.importArtifact(metadata);
    _check();
    _refs = List.unmodifiable([source, sidecar]);
    return _refs!;
  }

  @override
  Future<void> finish({required String savedMaterialId}) async {
    _check();
    final refs = _refs;
    if (refs == null) {
      throw const MaterialImportException(
        MaterialImportErrorCode.bindingMismatch,
      );
    }
    final draft = await controller.materials.readDraft(savedMaterialId);
    _check();
    if (draft.ownerId != ownerId ||
        refs.any(
          (expected) => !draft.artifacts.any(
            (actual) =>
                actual.ownerId == expected.ownerId &&
                actual.artifactId == expected.artifactId &&
                actual.sha256 == expected.sha256 &&
                actual.byteLength == expected.byteLength,
          ),
        )) {
      throw const MaterialImportException(
        MaterialImportErrorCode.bindingMismatch,
      );
    }
    for (final ref in refs) {
      await controller.materials.readArtifact(ref);
      _check();
    }
    await controller._cleanup(this);
    _cleanupPending = false;
    _finished = true;
    if (identical(controller._active, this)) controller._active = null;
  }

  @override
  Future<void> cancel() async {
    if (_finished) return;
    markCancelled();
    final nativeIdle = await controller._cancelNative(sessionId);
    if (!nativeIdle) {
      throw const MaterialImportException(MaterialImportErrorCode.busy);
    }
    await _runDone.future;
    final preparing = _preparing;
    if (preparing != null) {
      try {
        await preparing;
      } catch (_) {}
    }
    try {
      await controller._cleanup(this);
      _cleanupPending = false;
    } catch (_) {
      _cleanupPending = true;
      throw const MaterialImportException(MaterialImportErrorCode.readFailed);
    }
    if (identical(controller._active, this)) controller._active = null;
  }
}

final class _RejectedImportSession implements MaterialImportSession {
  _RejectedImportSession(
    this.sessionId,
    this.ownerId,
    MaterialImportErrorCode code,
  ) {
    preview = Future<MaterialImportPreview?>.error(
      MaterialImportException(code),
    );
    preview.ignore();
  }
  @override
  final String sessionId;
  @override
  final String ownerId;
  @override
  late final Future<MaterialImportPreview?> preview;
  @override
  Future<List<ArtifactRef>> prepareArtifacts() async =>
      throw const MaterialImportException(
        MaterialImportErrorCode.sessionClosed,
      );
  @override
  Future<void> cancel() async {}
  @override
  Future<void> finish({required String savedMaterialId}) async =>
      throw const MaterialImportException(
        MaterialImportErrorCode.sessionClosed,
      );
}
