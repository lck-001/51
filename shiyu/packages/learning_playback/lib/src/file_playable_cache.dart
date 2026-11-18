import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as hashes;
import 'package:learning_core/learning_core.dart';
import 'package:material_core/material_core.dart';
import 'package:playback_core/playback_core.dart';

import '../learning_playback.dart';

final class FilePlayableCache {
  FilePlayableCache({
    required Directory root,
    required MaterialStore materials,
    required LearningStore learning,
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
  Future<void> _tail = Future<void>.value();
  String get trustedOwnerId => _materials.trustedOwnerId;
  String _hash(List<int> bytes) => hashes.sha256.convert(bytes).toString();
  Future<T> _run<T>(Future<T> Function() body) {
    final result = Completer<T>();
    _tail = _tail.then((_) async {
      try {
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
      throw const LearningPlaybackException(
        LearningPlaybackErrorCode.cacheCorrupt,
      );
    }
  }

  Future<bool> _regular(File file) async {
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return false;
    if (type != FileSystemEntityType.file) {
      throw const LearningPlaybackException(
        LearningPlaybackErrorCode.cacheCorrupt,
      );
    }
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
      final artifact = await _learning.mediaArtifactFor(item);
      final version = await _learning.readVersion(item.itemId);
      if (version.state != LearningState.ready ||
          version.binding.mediaVersionId != item.itemRevision ||
          version.media?.artifact.artifactId != artifact.artifactId) {
        throw const LearningPlaybackException(
          LearningPlaybackErrorCode.bindingMismatch,
        );
      }
      final bytes = await _materials.readArtifact(artifact);
      if (bytes.length != artifact.byteLength ||
          _hash(bytes) != artifact.sha256) {
        throw const LearningPlaybackException(
          LearningPlaybackErrorCode.sourceUnavailable,
        );
      }
      final destination = await _destination(item);
      if (await _regular(destination)) {
        if (await destination.length() != artifact.byteLength ||
            (await hashes.sha256.bind(destination.openRead()).first)
                    .toString() !=
                artifact.sha256) {
          throw const LearningPlaybackException(
            LearningPlaybackErrorCode.cacheCorrupt,
          );
        }
      } else {
        final next = File('${destination.path}.next');
        await _regular(next);
        await next.writeAsBytes(bytes, flush: true);
        if (await next.length() != artifact.byteLength ||
            _hash(await next.readAsBytes()) != artifact.sha256) {
          throw const LearningPlaybackException(
            LearningPlaybackErrorCode.cacheWriteFailed,
          );
        }
        await next.rename(destination.path);
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
