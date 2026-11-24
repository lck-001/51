import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as hashes;
import 'package:learning_core/learning_core.dart';
import 'package:material_core/material_core.dart';
import 'package:playback_core/playback_core.dart';

import '../learning_playback.dart';

typedef PlayableCachePathGuard = FutureOr<void> Function(
  FileSystemEntity existingOwnedPath,
);

final class FilePlayableCache {
  FilePlayableCache({
    required Directory root,
    required MaterialStore materials,
    required LearningStore learning,
    this.pathGuard,
  }) : _root = root.absolute,
       _materials = materials,
       _learning = learning {
    if (materials.trustedOwnerId != learning.trustedOwnerId) {
      throw const LearningPlaybackException(
        LearningPlaybackErrorCode.ownerMismatch,
      );
    }
  }
  final Directory _root;
  final MaterialStore _materials;
  final LearningStore _learning;
  final PlayableCachePathGuard? pathGuard;
  bool _retired = false;
  LearningPlaybackException? _drainFailure;
  Future<void> _tail = Future<void>.value();
  String get trustedOwnerId => _materials.trustedOwnerId;
  String _hash(List<int> bytes) => hashes.sha256.convert(bytes).toString();
  Future<T> _run<T>(Future<T> Function() body) {
    if (_retired)
      return Future.error(
        const LearningPlaybackException(LearningPlaybackErrorCode.closed),
      );
    final result = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        _check();
        final value = await body();
        _check();
        result.complete(value);
      } catch (e, st) {
        final failure = e is LearningPlaybackException
            ? e
            : const LearningPlaybackException(
                LearningPlaybackErrorCode.cacheWriteFailed,
              );
        if ({
          LearningPlaybackErrorCode.cacheCorrupt,
          LearningPlaybackErrorCode.cacheWriteFailed,
        }.contains(failure.code))
          _drainFailure ??= failure;
        result.completeError(failure, st);
      }
    });
    return result.future;
  }

  void retire() {
    _retired = true;
  }

  /// Completion barrier only; operation errors remain observable by callers.
  Future<void> drain() async {
    await _tail;
    if (_drainFailure != null) throw _drainFailure!;
  }

  void _check() {
    if (_retired)
      throw const LearningPlaybackException(LearningPlaybackErrorCode.closed);
  }

  Future<void> _verify(FileSystemEntity entry) async {
    _check();
    try {
      await pathGuard?.call(entry);
    } catch (_) {
      throw const LearningPlaybackException(
        LearningPlaybackErrorCode.cacheCorrupt,
      );
    }
    _check();
  }

  Future<void> _directory(Directory dir) async {
    _check();
    final type = await FileSystemEntity.type(dir.path, followLinks: false);
    _check();
    if (type == FileSystemEntityType.notFound) {
      if (pathGuard != null) {
        if (dir.absolute.uri.normalizePath() == _root.uri.normalizePath())
          throw const LearningPlaybackException(
            LearningPlaybackErrorCode.cacheCorrupt,
          );
        await _verify(dir.parent);
      }
      _check();
      await dir.create(recursive: pathGuard == null);
      _check();
    } else if (type != FileSystemEntityType.directory) {
      throw const LearningPlaybackException(
        LearningPlaybackErrorCode.cacheCorrupt,
      );
    }
    await _verify(dir);
  }

  Future<bool> _regular(File file) async {
    _check();
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    _check();
    if (type == FileSystemEntityType.notFound) return false;
    if (type != FileSystemEntityType.file) {
      throw const LearningPlaybackException(
        LearningPlaybackErrorCode.cacheCorrupt,
      );
    }
    await _verify(file);
    return true;
  }

  Future<File> _destination(PlaybackItem item) async {
    // IDs have already crossed learning_core's strict item/revision validation.
    await _directory(_root);
    final owner = hashes.sha256
        .convert(utf8.encode('learning-playback:$trustedOwnerId'))
        .toString();
    final dir = Directory('${_root.path}/$owner');
    await _directory(dir);
    return File('${dir.path}/${item.itemId}-${item.itemRevision}.wav');
  }

  Future<PreparedLearningMedia> _prepare(PlaybackItem item) async {
    try {
      if (item.ownerId != trustedOwnerId) {
        throw const LearningPlaybackException(
          LearningPlaybackErrorCode.ownerMismatch,
        );
      }
      if (pathGuard != null) await _verify(_root);
      _check();
      final artifact = await _learning.mediaArtifactFor(item);
      _check();
      final version = await _learning.readVersion(item.itemId);
      _check();
      if (version.state != LearningState.ready ||
          version.binding.mediaVersionId != item.itemRevision ||
          version.media?.artifact.artifactId != artifact.artifactId) {
        throw const LearningPlaybackException(
          LearningPlaybackErrorCode.bindingMismatch,
        );
      }
      final bytes = await _materials.readArtifact(artifact);
      _check();
      if (bytes.length != artifact.byteLength ||
          _hash(bytes) != artifact.sha256) {
        throw const LearningPlaybackException(
          LearningPlaybackErrorCode.sourceUnavailable,
        );
      }
      final destination = await _destination(item);
      if (await _regular(destination)) {
        _check();
        final length = await destination.length();
        _check();
        final digest = await hashes.sha256.bind(destination.openRead()).first;
        _check();
        if (length != artifact.byteLength ||
            digest.toString() != artifact.sha256) {
          throw const LearningPlaybackException(
            LearningPlaybackErrorCode.cacheCorrupt,
          );
        }
      } else {
        final next = File('${destination.path}.next');
        await _regular(next);
        _check();
        await next.writeAsBytes(bytes, flush: true);
        _check();
        await _verify(next);
        final length = await next.length();
        _check();
        final written = await next.readAsBytes();
        _check();
        if (length != artifact.byteLength ||
            _hash(written) != artifact.sha256) {
          throw const LearningPlaybackException(
            LearningPlaybackErrorCode.cacheWriteFailed,
          );
        }
        await _verify(next.parent);
        _check();
        await next.rename(destination.path);
        _check();
        await _verify(destination);
      }
      return PreparedLearningMedia(
        item: item,
        binding: version.binding,
        artifact: artifact,
      );
    } on LearningPlaybackException {
      rethrow;
    } on LearningStoreException catch (error) {
      if (error.code == LearningErrorCode.ownerMismatch) {
        throw const LearningPlaybackException(
          LearningPlaybackErrorCode.ownerMismatch,
        );
      }
      if (error.code == LearningErrorCode.bindingMismatch ||
          error.code == LearningErrorCode.invalidId) {
        throw const LearningPlaybackException(
          LearningPlaybackErrorCode.bindingMismatch,
        );
      }
      throw const LearningPlaybackException(
        LearningPlaybackErrorCode.sourceUnavailable,
      );
    } on MaterialStoreException {
      throw const LearningPlaybackException(
        LearningPlaybackErrorCode.sourceUnavailable,
      );
    } catch (_) {
      throw const LearningPlaybackException(
        LearningPlaybackErrorCode.cacheWriteFailed,
      );
    }
  }

  Future<PreparedLearningMedia> prepare(PlaybackItem item) =>
      _run(() => _prepare(item));

  /// Private engine Adapter seam only. Do not place this URI in learning DTOs or OS metadata.
  Future<Uri> resolveForEngine(PlaybackItem item) => _run(() async {
    await _prepare(item);
    return (await _destination(item)).uri;
  });
}
