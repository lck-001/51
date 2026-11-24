import 'dart:ffi';
import 'dart:io';
import 'dart:convert';

import 'package:ffi/ffi.dart';

import 'contracts.dart';
import 'root_lock.dart';
import 'windows_privacy.dart';

Never _unsafe() => throw const AgentBridgeException(
  AgentBridgeErrorCode.privateStorageUnavailable,
);
String _key(String path) =>
    Directory(path).absolute.uri
        .normalizePath()
        .toFilePath()
        .replaceAll('/', '\\')
        .replaceAll(RegExp(r'\\+$'), '')
        .toLowerCase();
String _join(String parent, String leaf) =>
    '$parent${Platform.pathSeparator}$leaf';
const _children = {
  'materials',
  'learning',
  'playable-cache',
  'material-import-staging',
  'agent_bridge',
  'media_ingest',
};
const _marker = 'client-security.marker';
const _markerValue = 'shiyu-private-root:1\n';

enum PrivateAclKind { protected, inheritedPrivate }

final class PrivateAclEvidence {
  const PrivateAclEvidence({
    required this.kind,
    required this.directory,
    required this.propagates,
  });
  final PrivateAclKind kind;
  final bool directory, propagates;
  @override
  String toString() =>
      'PrivateAclEvidence(${kind.name},directory:$directory,propagates:$propagates)';
}

final class PrivateTreeEvidence {
  const PrivateTreeEvidence(
    this.directories,
    this.files,
    this.protectedObjects,
    this.inheritedObjects,
  );
  final int directories, files, protectedObjects, inheritedObjects;
}

final class _SecurityAttributes extends Struct {
  @Uint32()
  external int length;
  external Pointer<Void> descriptor;
  @Int32()
  external int inheritHandle;
}

final class _Identity {
  const _Identity(
    this.volume,
    this.high,
    this.low,
    this.attributes,
    this.links,
  );
  final int volume, high, low, attributes, links;
  bool same(_Identity other) =>
      volume == other.volume && high == other.high && low == other.low;
}

final class _Pin {
  _Pin(this.handle, this.path, this.identity);
  final Pointer<Void> handle;
  final String path;
  final _Identity identity;
  bool closed = false;
  void close() {
    if (closed) return;
    if (_win.close(handle) == 0) _unsafe();
    closed = true;
  }

  void check() {
    if (closed) _unsafe();
    final fresh = _win.pin(path, directory: true);
    try {
      if (!identity.same(fresh.identity) || _key(path) != _key(fresh.path))
        _unsafe();
    } finally {
      fresh.close();
    }
  }
}

final _win = _WindowsRootApi();

final class _WindowsRootApi {
  late final kernel = DynamicLibrary.open('kernel32.dll'),
      adv = DynamicLibrary.open('advapi32.dll');
  late final close = kernel
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('CloseHandle');
  late final free = kernel
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>),
        Pointer<Void> Function(Pointer<Void>)
      >('LocalFree');
  late final error = kernel.lookupFunction<Uint32 Function(), int Function()>(
    'GetLastError',
  );
  late final attrs = kernel
      .lookupFunction<
        Uint32 Function(Pointer<Utf16>),
        int Function(Pointer<Utf16>)
      >('GetFileAttributesW');
  late final mkdir = kernel
      .lookupFunction<
        Int32 Function(Pointer<Utf16>, Pointer<_SecurityAttributes>),
        int Function(Pointer<Utf16>, Pointer<_SecurityAttributes>)
      >('CreateDirectoryW');
  late final create = kernel
      .lookupFunction<
        Pointer<Void> Function(
          Pointer<Utf16>,
          Uint32,
          Uint32,
          Pointer<_SecurityAttributes>,
          Uint32,
          Uint32,
          Pointer<Void>,
        ),
        Pointer<Void> Function(
          Pointer<Utf16>,
          int,
          int,
          Pointer<_SecurityAttributes>,
          int,
          int,
          Pointer<Void>,
        )
      >('CreateFileW');
  late final finalPath = kernel
      .lookupFunction<
        Uint32 Function(Pointer<Void>, Pointer<Utf16>, Uint32, Uint32),
        int Function(Pointer<Void>, Pointer<Utf16>, int, int)
      >('GetFinalPathNameByHandleW');
  late final info = kernel
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Uint32>),
        int Function(Pointer<Void>, Pointer<Uint32>)
      >('GetFileInformationByHandle');
  late final fromSddl = adv
      .lookupFunction<
        Int32 Function(
          Pointer<Utf16>,
          Uint32,
          Pointer<Pointer<Void>>,
          Pointer<Uint32>,
        ),
        int Function(
          Pointer<Utf16>,
          int,
          Pointer<Pointer<Void>>,
          Pointer<Uint32>,
        )
      >('ConvertStringSecurityDescriptorToSecurityDescriptorW');
  late final toSddl = adv
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Uint32,
          Uint32,
          Pointer<Pointer<Utf16>>,
          Pointer<Uint32>,
        ),
        int Function(
          Pointer<Void>,
          int,
          int,
          Pointer<Pointer<Utf16>>,
          Pointer<Uint32>,
        )
      >('ConvertSecurityDescriptorToStringSecurityDescriptorW');
  late final sidString = adv
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Pointer<Utf16>>),
        int Function(Pointer<Void>, Pointer<Pointer<Utf16>>)
      >('ConvertSidToStringSidW');
  late final security = adv
      .lookupFunction<
        Uint32 Function(
          Pointer<Utf16>,
          Int32,
          Uint32,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<Void>>,
        ),
        int Function(
          Pointer<Utf16>,
          int,
          int,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<Void>>,
        )
      >('GetNamedSecurityInfoW');
  late final write = kernel
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Pointer<Uint8>,
          Uint32,
          Pointer<Uint32>,
          Pointer<Void>,
        ),
        int Function(
          Pointer<Void>,
          Pointer<Uint8>,
          int,
          Pointer<Uint32>,
          Pointer<Void>,
        )
      >('WriteFile');
  late final flush = kernel
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('FlushFileBuffers');
  bool invalid(Pointer<Void> h) =>
      h == nullptr || h.address == -1 || h.address == 0xffffffffffffffff;
  void noReparseChain(String input) {
    final normalized = Directory(input).absolute.uri
        .normalizePath()
        .toFilePath()
        .replaceAll('/', '\\');
    if (!RegExp(r'^[a-zA-Z]:\\').hasMatch(normalized) ||
        input.replaceAll('/', '\\').split('\\').contains('..'))
      _unsafe();
    final parts = normalized
        .substring(3)
        .split('\\')
        .where((p) => p.isNotEmpty)
        .toList();
    var current = normalized.substring(0, 3);
    using((arena) {
      var attributes = attrs(current.toNativeUtf16(allocator: arena));
      if (attributes == 0xffffffff || attributes & 0x400 != 0) _unsafe();
      for (final part in parts) {
        current = _join(current.replaceAll(RegExp(r'\\+$'), ''), part);
        attributes = attrs(current.toNativeUtf16(allocator: arena));
        if (attributes == 0xffffffff || attributes & 0x400 != 0) _unsafe();
      }
    });
  }

  String canonical(Pointer<Void> handle) => using((arena) {
    final buffer = arena<Uint16>(32768).cast<Utf16>();
    final length = finalPath(handle, buffer, 32768, 0);
    if (length == 0 || length >= 32768) _unsafe();
    var path = buffer.toDartString(length: length);
    if (path.startsWith('\\\\?\\')) path = path.substring(4);
    if (!RegExp(r'^[A-Za-z]:\\').hasMatch(path)) _unsafe();
    return path;
  });
  _Identity identity(Pointer<Void> handle) => using((arena) {
    final data = arena<Uint32>(13);
    if (info(handle, data) == 0) _unsafe();
    return _Identity(data[7], data[11], data[12], data[0], data[10]);
  });
  _Pin pin(String path, {required bool directory}) {
    noReparseChain(path);
    return using((arena) {
      final handle = create(
        path.toNativeUtf16(allocator: arena),
        // Attribute/security-only opens do not participate in all Windows
        // sharing checks. LIST_DIRECTORY/READ_DATA makes no-share-delete real.
        0x20081,
        3,
        nullptr,
        3,
        0x02200000,
        nullptr,
      );
      if (invalid(handle)) _unsafe();
      try {
        final value = identity(handle);
        if (value.attributes & 0x400 != 0 ||
            (value.attributes & 0x10 != 0) != directory ||
            (!directory && value.links != 1))
          _unsafe();
        return _Pin(handle, canonical(handle), value);
      } catch (_) {
        close(handle);
        rethrow;
      }
    });
  }

  T withPrivateSecurity<T>(T Function(Pointer<_SecurityAttributes>) action) =>
      using((arena) {
        final output = arena<Pointer<Void>>();
        final sid = WindowsPrivacy.instance.currentSid;
        if (fromSddl(
              'O:${sid}D:P(A;OICI;FA;;;$sid)(A;OICI;FA;;;SY)'.toNativeUtf16(
                allocator: arena,
              ),
              1,
              output,
              nullptr,
            ) ==
            0)
          _unsafe();
        try {
          final sa = arena<_SecurityAttributes>();
          sa.ref.length = sizeOf<_SecurityAttributes>();
          sa.ref.descriptor = output.value;
          sa.ref.inheritHandle = 0;
          return action(sa);
        } finally {
          free(output.value);
        }
      });
  bool privateDirectory(String path) {
    bool existsDirectory() => using((arena) {
      final value = attrs(path.toNativeUtf16(allocator: arena));
      if (value == 0xffffffff) return false;
      if (value & 0x400 != 0 || value & 0x10 == 0) _unsafe();
      return true;
    });
    // Existing objects are never passed through an ACL-setting operation.
    // A racing creator is treated only as existing, then pinned and fully
    // validated by the caller; failure codes are not a permission shortcut.
    if (existsDirectory()) return false;
    return withPrivateSecurity(
      (sa) => using((arena) {
        if (mkdir(path.toNativeUtf16(allocator: arena), sa) != 0) return true;
        if (existsDirectory()) return false;
        _unsafe();
      }),
    );
  }

  void privateMarker(String path) => withPrivateSecurity(
    (sa) => using((arena) {
      final h = create(
        path.toNativeUtf16(allocator: arena),
        0xc0000000,
        3,
        sa,
        1,
        0x00200080,
        nullptr,
      );
      if (invalid(h)) _unsafe();
      try {
        final bytes = utf8.encode(_markerValue),
            data = arena<Uint8>(bytes.length),
            written = arena<Uint32>();
        data.asTypedList(bytes.length).setAll(0, bytes);
        if (write(h, data, bytes.length, written, nullptr) == 0 ||
            written.value != bytes.length ||
            flush(h) == 0)
          _unsafe();
      } finally {
        close(h);
      }
    }),
  );
  String sid(Pointer<Void> value) => using((arena) {
    final text = arena<Pointer<Utf16>>();
    if (value == nullptr || sidString(value, text) == 0) _unsafe();
    try {
      return text.value.toDartString();
    } finally {
      free(text.value.cast<Void>());
    }
  });
  PrivateAclEvidence acl(
    String path, {
    required bool directory,
    required bool protected,
  }) {
    noReparseChain(path);
    final current = WindowsPrivacy.instance.currentSid;
    final evidence = using((arena) {
      final owner = arena<Pointer<Void>>(),
          dacl = arena<Pointer<Void>>(),
          sd = arena<Pointer<Void>>();
      if (security(
                path.toNativeUtf16(allocator: arena),
                1,
                5,
                owner,
                nullptr,
                dacl,
                nullptr,
                sd,
              ) !=
              0 ||
          sd.value == nullptr)
        _unsafe();
      try {
        if (sid(owner.value) != current || dacl.value == nullptr) _unsafe();
        final text = arena<Pointer<Utf16>>();
        if (toSddl(sd.value, 1, 5, text, nullptr) == 0) _unsafe();
        late String encoded;
        try {
          encoded = text.value.toDartString();
        } finally {
          free(text.value.cast<Void>());
        }
        final at = encoded.indexOf('D:');
        if (at < 0) _unsafe();
        final acl = encoded.substring(at + 2), first = acl.indexOf('(');
        if (first < 0) _unsafe();
        final control = acl.substring(0, first);
        if (control
            .replaceAll('P', '')
            .replaceAll('AI', '')
            .replaceAll('AR', '')
            .isNotEmpty)
          _unsafe();
        final matches = RegExp(r'\(([^()]*)\)').allMatches(acl).toList();
        if (matches.isEmpty ||
            matches.map((m) => m.group(0)).join() != acl.substring(first))
          _unsafe();
        final seen = <String>{};
        for (final ace in matches) {
          final fields = ace.group(1)!.split(';');
          if (fields.length != 6 ||
              fields[0] != 'A' ||
              fields[3].isNotEmpty ||
              fields[4].isNotEmpty ||
              !{'FA', 'GA', '0x1f01ff'}.contains(fields[2]))
            _unsafe();
          final trustee = fields[5] == 'SY' ? 'S-1-5-18' : fields[5];
          if (trustee != current && trustee != 'S-1-5-18') _unsafe();
          final flags = <String>{};
          final raw = fields[1];
          if (raw.length.isOdd) _unsafe();
          for (var i = 0; i < raw.length; i += 2) {
            final token = raw.substring(i, i + 2);
            if (!{'OI', 'CI', 'ID'}.contains(token) || !flags.add(token))
              _unsafe();
          }
          if (directory && (!flags.contains('OI') || !flags.contains('CI')))
            _unsafe();
          seen.add(trustee);
        }
        if (!seen.contains(current) || !seen.contains('S-1-5-18')) _unsafe();
        final hasP = control.contains('P');
        if (protected && !hasP) _unsafe();
        return PrivateAclEvidence(
          kind: hasP
              ? PrivateAclKind.protected
              : PrivateAclKind.inheritedPrivate,
          directory: directory,
          propagates: directory,
        );
      } finally {
        free(sd.value);
      }
    });
    if (protected)
      WindowsPrivacy.instance.verify(path); // Existing strict API unchanged.
    return evidence;
  }
}

final class WindowsPrivateAppRoot {
  const WindowsPrivateAppRoot._();
  static Future<WindowsPrivateAppRootLease> open({
    required Directory supportParent,
    required String leaf,
  }) async {
    if (!Platform.isWindows)
      throw const AgentBridgeException(
        AgentBridgeErrorCode.unsupportedPlatform,
      );
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$').hasMatch(leaf) ||
        leaf.endsWith('.') ||
        RegExp(
          r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',
          caseSensitive: false,
        ).hasMatch(leaf))
      _unsafe();
    _Pin? parent, root;
    LearningRootLock? lock;
    final children = <String, _Pin>{};
    try {
      parent = _win.pin(supportParent.absolute.path, directory: true);
      final path = _join(parent.path, leaf);
      _win.privateDirectory(path);
      root = _win.pin(path, directory: true);
      if (_key(root.path) != _key(path)) _unsafe();
      _win.acl(root.path, directory: true, protected: true);
      final names = <String>{};
      const allowedTop = {..._children, _marker, '.shiyu-owner.lock'};
      await for (final entry in Directory(root.path).list(followLinks: false)) {
        final name = entry.uri.pathSegments.where((p) => p.isNotEmpty).last;
        if (!allowedTop.contains(name) || !names.add(name) || names.length > 8)
          _unsafe();
      }
      final hasMarker = names.contains(_marker);
      if (hasMarker) {
        if (names.difference({
              ..._children,
              _marker,
              '.shiyu-owner.lock',
            }).isNotEmpty ||
            !_children.every(names.contains) ||
            !names.contains('.shiyu-owner.lock'))
          _unsafe();
        await _verifyMarker(root.path);
      } else if (names.difference({'.shiyu-owner.lock'}).isNotEmpty) {
        _unsafe();
      }
      final sentinel = File(_join(root.path, '.shiyu-owner.lock'));
      if (await FileSystemEntity.type(sentinel.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        _win.acl(sentinel.path, directory: false, protected: false);
        if (await sentinel.length() != 0) _unsafe();
      }
      lock = await LearningRootLock.acquire(Directory(root.path));
      if (_key(lock.rootDirectory.path) != _key(root.path)) _unsafe();
      root.check();
      parent.check();
      _win.acl(sentinel.path, directory: false, protected: false);
      for (final name in _children) {
        final childPath = _join(root.path, name);
        if (!hasMarker) _win.privateDirectory(childPath);
        final child = _win.pin(childPath, directory: true);
        children[name] = child;
        if (_key(child.path) != _key(childPath)) _unsafe();
        _win.acl(child.path, directory: true, protected: true);
      }
      final lease = WindowsPrivateAppRootLease._(parent, root, lock, children);
      await lease.verifyPrivateDescendants();
      if (!hasMarker) {
        _win.privateMarker(_join(root.path, _marker));
        await _verifyMarker(root.path);
      }
      return lease;
    } catch (error) {
      var releaseSafe = true;
      try {
        await lock?.release();
      } catch (_) {
        releaseSafe = false;
      }
      if (releaseSafe) {
        for (final child in children.values.toList().reversed) {
          try {
            child.close();
          } catch (_) {}
        }
        try {
          root?.close();
        } catch (_) {}
        try {
          parent?.close();
        } catch (_) {}
      }
      if (error is AgentBridgeException) rethrow;
      _unsafe();
    }
  }

  static Future<void> _verifyMarker(String root) async {
    final path = _join(root, _marker),
        pin = _win.pin(_join(root, _marker), directory: false);
    try {
      _win.acl(path, directory: false, protected: true);
      final file = File(path);
      if (await file.length() > 128 ||
          await file.readAsString() != _markerValue)
        _unsafe();
    } finally {
      pin.close();
    }
  }
}

/// Owns lock and pins only. Caller must close actual writers/Stores first.
final class WindowsPrivateAppRootLease {
  WindowsPrivateAppRootLease._(
    this._parent,
    this._root,
    this.rootLock,
    this._pins,
  );
  final _Pin _parent, _root;
  final Map<String, _Pin> _pins;
  final LearningRootLock rootLock;
  Future<void>? _closing;
  bool _closed = false;
  Directory get root => Directory(_root.path);
  Directory childDirectory(String name) {
    if (_closed || !_children.contains(name)) _unsafe();
    return Directory(_pins[name]!.path);
  }

  void verifySameRoot(LearningRootLock candidate) {
    if (_closed ||
        !identical(candidate, rootLock) ||
        !candidate.isHeld ||
        _key(candidate.rootDirectory.path) != _key(_root.path))
      _unsafe();
    _parent.check();
    _root.check();
  }

  PrivateAclEvidence verifyEffectivePath(String path) {
    verifySameRoot(rootLock);
    final normalized = Directory(path).absolute.uri
        .normalizePath()
        .toFilePath()
        .replaceAll('/', '\\')
        .replaceAll(RegExp(r'\\+$'), '');
    if (!_key(normalized).startsWith('${_key(_root.path)}\\')) _unsafe();
    final relative = normalized.substring(_root.path.length + 1).split('\\');
    if (relative.isEmpty || !_children.contains(relative.first)) _unsafe();
    var current = _root.path;
    _win.acl(current, directory: true, protected: true);
    PrivateAclEvidence? result;
    for (var i = 0; i < relative.length; i++) {
      current = _join(current, relative[i]);
      final pin = _win.pin(
        current,
        directory:
            i < relative.length - 1 ||
            FileSystemEntity.isDirectorySync(current),
      );
      try {
        result = _win.acl(
          current,
          directory: pin.identity.attributes & 0x10 != 0,
          // Credential/session domains retain their existing strict-P policy;
          // Store/cache data may instead be effective inherited-private.
          protected:
              i == 0 ||
              {'agent_bridge', 'media_ingest'}.contains(relative.first),
        );
      } finally {
        pin.close();
      }
    }
    return result!;
  }

  Future<PrivateTreeEvidence> verifyPrivateDescendants() async {
    verifySameRoot(rootLock);
    var directories = 0,
        files = 0,
        protectedCount = 0,
        inheritedCount = 0,
        entries = 0;
    Future<void> walk(Directory dir, int depth) async {
      if (depth > 12) _unsafe();
      await for (final entry in dir.list(followLinks: false)) {
        if (++entries > 8192) _unsafe();
        final evidence = verifyEffectivePath(entry.path);
        if (evidence.kind == PrivateAclKind.protected) {
          protectedCount++;
        } else {
          inheritedCount++;
        }
        if (evidence.directory) {
          directories++;
          await walk(Directory(entry.path), depth + 1);
        } else {
          files++;
        }
      }
    }

    for (final name in _children) {
      _pins[name]!.check();
      _win.acl(_pins[name]!.path, directory: true, protected: true);
      directories++;
      protectedCount++;
      await walk(Directory(_pins[name]!.path), 1);
    }
    return PrivateTreeEvidence(
      directories,
      files,
      protectedCount,
      inheritedCount,
    );
  }

  Future<void> close() {
    if (_closing != null) return _closing!;
    return _closing = () async {
      await rootLock.release();
      Object? first;
      for (final pin in [..._pins.values.toList().reversed, _root, _parent]) {
        try {
          pin.close();
        } catch (error) {
          first ??= error;
        }
      }
      if (first != null) _unsafe();
      _closed = true;
    }();
  }
}
