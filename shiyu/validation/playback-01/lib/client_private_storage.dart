import 'dart:async';
import 'dart:io';

import 'package:agent_bridge/agent_bridge.dart';
import 'package:agent_bridge/private_storage.dart';
import 'package:learning_core/learning_core.dart';
import 'package:learning_playback/learning_playback.dart';
import 'package:material_core/material_core.dart';

import 'client_material_import.dart';
import 'client_startup_retention.dart';

/// OS cache location supplied by the Android App owner, never by a document or
/// external assistant. The suffix is shared with BoundedDocumentImport.kt.
final class AndroidMaterialImportCache {
  AndroidMaterialImportCache({required Directory cacheDirectory})
    : _cacheDirectory = cacheDirectory.absolute;

  final Directory _cacheDirectory;
  Directory get stagingRoot =>
      Directory('${_cacheDirectory.path}/material_import_v1');
}

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
  bool get storesClosed => _learningClosed && _materialsClosed;
  static Future<ClientPrivateStorage> open({
    required Directory root,
    required List<String> proxyCommand,
    MaterialFileSelection? selection,
    MaterialStageRemoval? removeStage,
    MaterialNativeIdleProbe? nativeIdleProbe,
    AndroidMaterialImportCache? androidImportCache,
    ClientStartupAttempt? startupAttempt,
  }) async {
    // Reject a misrouted dependency before acquiring a lock or creating Stores.
    if (androidImportCache != null &&
        (!Platform.isAndroid || selection != null)) {
      throw ArgumentError(
        'Android import cache requires native Android selection',
      );
    }
    if (Platform.isAndroid && selection == null && androidImportCache == null) {
      throw ArgumentError(
        'Native Android import requires its OS cache location',
      );
    }
    final attempt = startupAttempt ?? ClientStartupAttempt();
    final ownAttempt = startupAttempt == null;
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
        lease = await attempt.observe<WindowsPrivateAppRootLease>(
          ClientStartupOperation.privateRootOpen,
          WindowsPrivateAppRoot.open(
            supportParent: root.parent,
            leaf: root.uri.pathSegments.where((part) => part.isNotEmpty).last,
          ),
        );
        attempt.retain(ClientStartupRef.lease, lease);
        lock = lease.rootLock;
        owned = lease.root; // Never acquire a second lock.
      } else {
        lock = await attempt.observe<LearningRootLock>(
          ClientStartupOperation.privateRootOpen,
          LearningRootLock.acquire(root),
        );
        owned = lock.rootDirectory;
      }
      attempt.retain(ClientStartupRef.rootLock, lock);
      Directory child(String name) =>
          lease?.childDirectory(name) ?? Directory('${owned.path}/$name');
      materials = await attempt.observe<FileMaterialStore>(
        ClientStartupOperation.materialsOpen,
        FileMaterialStore.open(
          root: child('materials'),
          trustedOwnerId: 'local-device-only',
        ),
      );
      attempt.retain(ClientStartupRef.materials, materials);
      learning = await attempt.observe<FileLearningStore>(
        ClientStartupOperation.learningOpen,
        FileLearningStore.open(root: child('learning'), materials: materials),
      );
      attempt.retain(ClientStartupRef.learning, learning);
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
        media = await attempt.observe<MediaIngest>(
          ClientStartupOperation.mediaOpen,
          MediaIngest.open(
            privateRoot: child('media_ingest'),
            rootLock: lock,
            materials: materials,
            learning: learning,
            ownerId: materials.trustedOwnerId,
          ),
        );
        attempt.retain(ClientStartupRef.media, media);
      }
      bridge = AgentBridgeController.attach(
        materials: materials,
        candidates: learning,
        rootLock: lock,
        privateDirectory: child('agent_bridge'),
        proxyCommand: proxyCommand,
        mediaIngest: media,
      );
      attempt.retain(ClientStartupRef.bridge, bridge);
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
      attempt.retain(ClientStartupRef.cache, cache);
      imports = ClientMaterialImportController(
        materials: materials,
        stagingRoot: Platform.isAndroid && selection == null
            ? androidImportCache!.stagingRoot
            : child('material-import-staging'),
        selection: selection,
        removeStage: removeStage,
        nativeIdleProbe: nativeIdleProbe,
        pathGuard: authority == null ? null : guard,
      );
      attempt.retain(ClientStartupRef.importer, imports);
      await lease?.verifyPrivateDescendants();
      final storage = ClientPrivateStorage._(
        rootLock: lock,
        materials: materials,
        learning: learning,
        mediaIngest: media,
        agentBridge: bridge,
        playableCache: cache,
        materialImports: imports,
        lease: lease,
      );
      attempt.retain(ClientStartupRef.storage, storage);
      if (ownAttempt) attempt.handoff(ClientStartupRef.storage, storage);
      return storage;
    } catch (error, stack) {
      final retainedFailure = attempt.fail(error, stack);
      var safe = true;
      Future<void> settle(
        ClientStartupCleanup step,
        FutureOr<void> Function() action,
      ) async {
        try {
          await attempt.cleanup(step, action);
        } catch (_) {
          safe = false;
        }
      }

      await Future.wait([
        if (cache != null)
          settle(ClientStartupCleanup.retireCache, cache.retire),
        if (imports != null)
          settle(ClientStartupCleanup.retireImporter, imports.retire),
        if (bridge != null)
          settle(ClientStartupCleanup.retireBridge, bridge.retire),
      ]);
      await Future.wait([
        if (imports != null)
          settle(ClientStartupCleanup.closeImporter, imports.close),
        if (cache != null) settle(ClientStartupCleanup.drainCache, cache.drain),
        () async {
          if (bridge != null) {
            await settle(ClientStartupCleanup.closeBridge, bridge.close);
          }
          if (media != null) {
            await settle(ClientStartupCleanup.closeMedia, media.close);
          }
        }(),
      ]);
      if (safe) {
        if (learning != null) {
          await settle(ClientStartupCleanup.closeLearning, learning.close);
        }
        if (materials != null && safe) {
          await settle(ClientStartupCleanup.closeMaterials, materials.close);
        }
      }
      if (safe) {
        if (lease != null) {
          await settle(ClientStartupCleanup.releaseAuthority, lease.close);
        } else if (lock != null) {
          await settle(ClientStartupCleanup.releaseAuthority, lock.release);
        }
      }
      if (safe && ownAttempt && !attempt.cleanupFailed) {
        attempt.releasedAfterCleanup();
        // Standalone callers historically receive the original Store failure.
        // Unwrap only after all actual work settled and owned resources ended;
        // explicit upper-owner tokens and unresolved cleanup keep the carrier.
        if (attempt.resourcesEnded && !attempt.hasPending) {
          Error.throwWithStackTrace(
            retainedFailure.primaryError,
            retainedFailure.primaryStack,
          );
        }
      }
      Error.throwWithStackTrace(retainedFailure, retainedFailure.primaryStack);
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
