import 'dart:async';
import 'dart:io';

import 'package:agent_bridge/agent_bridge.dart';
import 'package:agent_bridge/private_storage.dart';
import 'package:learning_core/learning_core.dart';
import 'package:learning_playback/learning_playback.dart';
import 'package:material_core/material_core.dart';

import 'client_material_import.dart';

enum ClientStorageErrorCode {
  notDrained,
  learningNotClosed,
  storesNotClosed,
  shutdownUnconfirmed,
}

final class ClientStorageException implements Exception {
  const ClientStorageException(this.code);
  final ClientStorageErrorCode code;
  @override
  String toString() => 'ClientStorageException(${code.name})';
}

/// Headless App-owned storage composition. Does not construct a native host,
/// initialize MediaKit, show a picker/window or authorize any bridge scope.
final class ClientPrivateStorage {
  ClientPrivateStorage._({
    required this.rootLock,
    required this.materials,
    required this.learning,
    required this.mediaIngest,
    required this.agentBridge,
    required this.playableCache,
    required this.materialImports,
    required this._lease,
  });
  final LearningRootLock rootLock;
  final FileMaterialStore materials;
  final FileLearningStore learning;
  final MediaIngest? mediaIngest;
  final AgentBridgeController agentBridge;
  final FilePlayableCache playableCache;
  final ClientMaterialImportController materialImports;
  final WindowsPrivateAppRootLease? _lease;
  final _retirements = <Future<void>>[];
  bool _retired = false,
      _drainSuccess = false,
      _learningClosed = false,
      _materialsClosed = false,
      _authorityReleased = false;
  Future<void>? _draining,
      _closing,
      _learningClosing,
      _materialsClosing,
      _authorityReleasing;
  bool get writersDrained => _drainSuccess;
  bool get authorityReleased => _authorityReleased;
  static Future<ClientPrivateStorage> open({
    required Directory root,
    required List<String> proxyCommand,
    MaterialFileSelection? selection,
    MaterialStageRemoval? removeStage,
    MaterialNativeIdleProbe? nativeIdleProbe,
  }) async {
    WindowsPrivateAppRootLease? lease;
    LearningRootLock? lock;
    FileMaterialStore? materials;
    FileLearningStore? learning;
    MediaIngest? media;
    AgentBridgeController? bridge;
    FilePlayableCache? cache;
    ClientMaterialImportController? imports;
    try {
      final Directory owned;
      if (Platform.isWindows) {
        lease = await WindowsPrivateAppRoot.open(
          supportParent: root.parent,
          leaf: root.uri.pathSegments.where((part) => part.isNotEmpty).last,
        );
        lock = lease.rootLock;
        owned = lease.root; // Never acquire a second lock.
      } else {
        lock = await LearningRootLock.acquire(root);
        owned = lock.rootDirectory;
      }
      Directory child(String name) =>
          lease?.childDirectory(name) ?? Directory('${owned.path}/$name');
      materials = await FileMaterialStore.open(
        root: child('materials'),
        trustedOwnerId: 'local-device-only',
      );
      learning = await FileLearningStore.open(
        root: child('learning'),
        materials: materials,
      );
      if (Platform.isWindows) {
        if (materials.recoveryReport.issues.any(
              (issue) => issue.kind == RecoveryIssueKind.registrationHold,
            ) ||
            {
              RecoveryStatus.unrecoverable,
              RecoveryStatus.recoveredFromBackup,
            }.contains(materials.recoveryReport.status) ||
            learning.recoveryReport.issues.any(
              (issue) => issue.startsWith('recovery_hold:'),
            )) {
          throw const AgentBridgeException(AgentBridgeErrorCode.recoveryHold);
        }
        media = await MediaIngest.open(
          privateRoot: child('media_ingest'),
          rootLock: lock,
          materials: materials,
          learning: learning,
          ownerId: materials.trustedOwnerId,
        );
      }
      bridge = AgentBridgeController.attach(
        materials: materials,
        candidates: learning,
        rootLock: lock,
        privateDirectory: child('agent_bridge'),
        proxyCommand: proxyCommand,
        mediaIngest: media,
      );
      final authority = lease;
      void guard(FileSystemEntity entry) {
        authority!.verifyEffectivePath(entry.path);
      }

      cache = FilePlayableCache(
        root: child('playable-cache'),
        materials: materials,
        learning: learning,
        pathGuard: authority == null ? null : guard,
      );
      imports = ClientMaterialImportController(
        materials: materials,
        stagingRoot: child('material-import-staging'),
        selection: selection,
        removeStage: removeStage,
        nativeIdleProbe: nativeIdleProbe,
        pathGuard: authority == null ? null : guard,
      );
      await lease?.verifyPrivateDescendants();
      return ClientPrivateStorage._(
        rootLock: lock,
        materials: materials,
        learning: learning,
        mediaIngest: media,
        agentBridge: bridge,
        playableCache: cache,
        materialImports: imports,
        lease: lease,
      );
    } catch (_) {
      final retire = <Future<void>>[];
      for (final action in <void Function()>[
        if (cache != null) cache.retire,
        if (imports != null) imports.retire,
        if (bridge != null) bridge.retire,
      ]) {
        final future = Future<void>.sync(action);
        future.ignore();
        retire.add(future);
      }
      var safe = true;
      Future<void> settle(FutureOr<void> Function() action) async {
        try {
          await Future<void>.sync(action);
        } catch (_) {
          safe = false;
        }
      }

      await Future.wait([
        ...retire.map((f) => settle(() => f)),
        if (imports != null) settle(imports.close),
        if (cache != null) settle(cache.drain),
        settle(() async {
          if (bridge != null) await settle(bridge.close);
          if (media != null) await settle(media.close);
        }),
      ]);
      if (safe) {
        if (learning != null) await settle(learning.close);
        if (materials != null) await settle(materials.close);
      }
      if (safe) {
        if (lease != null) {
          await settle(lease.close);
        } else if (lock != null) {
          await settle(lock.release);
        }
      }
      rethrow;
    }
  }

  void retire() {
    if (_retired) return;
    _retired = true;
    for (final action in <void Function()>[
      playableCache.retire,
      materialImports.retire,
      agentBridge.retire,
    ]) {
      final future = Future<void>.sync(action);
      future.ignore();
      _retirements.add(future);
    }
  }

  Future<void> drainWriters() {
    if (_draining != null) return _draining!;
    final done = Completer<void>();
    _draining = done.future;
    done.future.ignore();
    Future<void>.sync(() async {
      retire();
      var failed = false;
      Future<void> settle(FutureOr<void> Function() action) =>
          Future<void>.sync(action).catchError((Object _) {
            failed = true;
          });
      await Future.wait([
        ..._retirements.map((f) => settle(() => f)),
        settle(materialImports.close),
        settle(playableCache.drain),
        settle(() async {
          await settle(
            agentBridge.close,
          ); // B settles all accepted futures even on error.
          if (mediaIngest != null) await settle(mediaIngest!.close);
        }),
      ]);
      if (failed) {
        throw const ClientStorageException(
          ClientStorageErrorCode.shutdownUnconfirmed,
        );
      }
      _drainSuccess = true;
    }).then(done.complete, onError: done.completeError);
    return done.future;
  }

  Future<void> closeLearning() {
    if (_learningClosing != null) return _learningClosing!;
    if (!_drainSuccess) {
      return Future.error(
        const ClientStorageException(ClientStorageErrorCode.notDrained),
      );
    }
    final done = Completer<void>();
    _learningClosing = done.future;
    done.future.ignore();
    Future<void>.sync(learning.close).then((_) {
      _learningClosed = true;
      done.complete();
    }, onError: done.completeError);
    return done.future;
  }

  Future<void> closeMaterials() {
    if (_materialsClosing != null) return _materialsClosing!;
    if (!_drainSuccess || !_learningClosed) {
      return Future.error(
        const ClientStorageException(ClientStorageErrorCode.learningNotClosed),
      );
    }
    final done = Completer<void>();
    _materialsClosing = done.future;
    done.future.ignore();
    Future<void>.sync(materials.close).then((_) {
      _materialsClosed = true;
      done.complete();
    }, onError: done.completeError);
    return done.future;
  }

  Future<void> releaseAuthority() {
    if (_authorityReleasing != null) return _authorityReleasing!;
    if (!_drainSuccess || !_learningClosed || !_materialsClosed) {
      return Future.error(
        const ClientStorageException(ClientStorageErrorCode.storesNotClosed),
      );
    }
    final done = Completer<void>();
    _authorityReleasing = done.future;
    done.future.ignore();
    Future<void>.sync(
      () => _lease != null ? _lease.close() : rootLock.release(),
    ).then((_) {
      _authorityReleased = true;
      done.complete();
    }, onError: done.completeError);
    return done.future;
  }

  Future<void> closeStoresAndAuthority() {
    if (!_drainSuccess) {
      return Future.error(
        const ClientStorageException(ClientStorageErrorCode.notDrained),
      );
    }
    return _closing ??= () async {
      await closeLearning();
      await closeMaterials();
      await releaseAuthority();
    }();
  }
}
