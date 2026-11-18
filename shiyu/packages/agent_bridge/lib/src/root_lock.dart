import 'dart:async';
import 'dart:io';

import 'contracts.dart';
import 'windows_privacy.dart';

/// Cooperative application writer authority, acquired before either Store is
/// opened. This is not a claim to block an administrator or arbitrary OS writes.
final class LearningRootLock {
  LearningRootLock._(this.rootDirectory, this._file, this._handle);
  final Directory rootDirectory;
  final File _file;
  final RandomAccessFile _handle;
  bool _released = false, _unlocked = false;
  bool get isHeld => !_released && !_unlocked;
  static final _held = <LearningRootLock>[];
  static Future<void> _acquireTail = Future<void>.value();

  static Future<LearningRootLock> acquire(Directory root) {
    final result = Completer<LearningRootLock>();
    _acquireTail = _acquireTail.then((_) async {
      try {
        result.complete(await _acquire(root));
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  static String _key(String path) {
    final normalized = Directory(path).absolute.uri
        .normalizePath()
        .toFilePath()
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'/+$'), '');
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  static Future<void> _sameProcessGuard(Directory root) async {
    // Must precede *any create/open* of the lock inode. POSIX closing a second
    // descriptor for that inode could release this process's existing lock.
    final candidate = File('${root.path}/.shiyu-owner.lock');
    for (final held in _held) {
      if (held._released) continue;
      var same = _key(root.path) == _key(held.rootDirectory.path);
      if (!same && await root.exists()) {
        same = await FileSystemEntity.identical(
          root.path,
          held.rootDirectory.path,
        );
      }
      if (!same && await candidate.exists()) {
        same = await FileSystemEntity.identical(
          candidate.path,
          held._file.path,
        );
      }
      if (same) throw const AgentBridgeException(AgentBridgeErrorCode.rootBusy);
    }
  }

  static Future<LearningRootLock> _acquire(Directory requested) async {
    final root = requested.absolute;
    await _sameProcessGuard(root);
    try {
      if (!await root.exists()) await root.create(recursive: true);
      final canonical = Directory(
        Platform.isWindows
            ? WindowsPrivacy.instance.canonicalPath(root.path)
            : await root.resolveSymbolicLinks(),
      );
      await _sameProcessGuard(canonical);
      final file = File('${canonical.path}/.shiyu-owner.lock');
      var kind = await FileSystemEntity.type(file.path, followLinks: false);
      if (kind == FileSystemEntityType.notFound) {
        try {
          await file.create(exclusive: true);
        } on FileSystemException {
          /* Another process may create the same sentinel. */
        }
        kind = await FileSystemEntity.type(file.path, followLinks: false);
      }
      if (kind != FileSystemEntityType.file) {
        throw const AgentBridgeException(AgentBridgeErrorCode.rootUnavailable);
      }
      if (Platform.isWindows) WindowsPrivacy.instance.rejectReparse(file.path);
      final handle = await file.open(mode: FileMode.append);
      try {
        await handle.lock(FileLock.exclusive, 0, 1);
      } catch (_) {
        await handle.close();
        throw const AgentBridgeException(AgentBridgeErrorCode.rootBusy);
      }
      final lock = LearningRootLock._(canonical, file, handle);
      _held.add(lock);
      return lock;
    } on AgentBridgeException {
      rethrow;
    } catch (_) {
      throw const AgentBridgeException(AgentBridgeErrorCode.rootUnavailable);
    }
  }

  /// The app calls this only after all accepted bridge commits have drained
  /// and both app-owned stores are closed. The sentinel is never unlinked.
  Future<void> release() async {
    if (_released) return;
    try {
      if (!_unlocked) {
        await _handle.unlock(0, 1);
        _unlocked = true;
      }
      await _handle.close();
      _released = true;
      _held.remove(this);
    } catch (_) {
      throw const AgentBridgeException(AgentBridgeErrorCode.rootUnavailable);
    }
  }
}
