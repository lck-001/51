import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'contracts.dart';

/// Narrow own-file security operations. No shell, process execution, account
/// credential, network object, privilege adjustment or arbitrary ACL editor.
final class WindowsPrivacy {
  WindowsPrivacy._();
  static final instance = WindowsPrivacy._();
  late final _adv = DynamicLibrary.open('advapi32.dll');
  late final _kernel = DynamicLibrary.open('kernel32.dll');
  late final _process = _kernel
      .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
        'GetCurrentProcess',
      );
  late final _openToken = _adv
      .lookupFunction<
        Int32 Function(Pointer<Void>, Uint32, Pointer<Pointer<Void>>),
        int Function(Pointer<Void>, int, Pointer<Pointer<Void>>)
      >('OpenProcessToken');
  late final _tokenInfo = _adv
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Int32,
          Pointer<Void>,
          Uint32,
          Pointer<Uint32>,
        ),
        int Function(Pointer<Void>, int, Pointer<Void>, int, Pointer<Uint32>)
      >('GetTokenInformation');
  late final _sidString = _adv
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Pointer<Utf16>>),
        int Function(Pointer<Void>, Pointer<Pointer<Utf16>>)
      >('ConvertSidToStringSidW');
  late final _fromSddl = _adv
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
  late final _toSddl = _adv
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
  late final _sdOwner = _adv
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Pointer<Void>>, Pointer<Int32>),
        int Function(Pointer<Void>, Pointer<Pointer<Void>>, Pointer<Int32>)
      >('GetSecurityDescriptorOwner');
  late final _sdDacl = _adv
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Pointer<Int32>,
          Pointer<Pointer<Void>>,
          Pointer<Int32>,
        ),
        int Function(
          Pointer<Void>,
          Pointer<Int32>,
          Pointer<Pointer<Void>>,
          Pointer<Int32>,
        )
      >('GetSecurityDescriptorDacl');
  late final _setNamed = _adv
      .lookupFunction<
        Uint32 Function(
          Pointer<Utf16>,
          Int32,
          Uint32,
          Pointer<Void>,
          Pointer<Void>,
          Pointer<Void>,
          Pointer<Void>,
        ),
        int Function(
          Pointer<Utf16>,
          int,
          int,
          Pointer<Void>,
          Pointer<Void>,
          Pointer<Void>,
          Pointer<Void>,
        )
      >('SetNamedSecurityInfoW');
  late final _getNamed = _adv
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
  late final _freeLocal = _kernel
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>),
        Pointer<Void> Function(Pointer<Void>)
      >('LocalFree');
  late final _close = _kernel
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('CloseHandle');
  late final _attributes = _kernel
      .lookupFunction<
        Uint32 Function(Pointer<Utf16>),
        int Function(Pointer<Utf16>)
      >('GetFileAttributesW');
  late final _openFile = _kernel
      .lookupFunction<
        Pointer<Void> Function(
          Pointer<Utf16>,
          Uint32,
          Uint32,
          Pointer<Void>,
          Uint32,
          Uint32,
          Pointer<Void>,
        ),
        Pointer<Void> Function(
          Pointer<Utf16>,
          int,
          int,
          Pointer<Void>,
          int,
          int,
          Pointer<Void>,
        )
      >('CreateFileW');
  late final _finalPath = _kernel
      .lookupFunction<
        Uint32 Function(Pointer<Void>, Pointer<Utf16>, Uint32, Uint32),
        int Function(Pointer<Void>, Pointer<Utf16>, int, int)
      >('GetFinalPathNameByHandleW');
  String? _currentSid;

  Never _fail() => throw const AgentBridgeException(
    AgentBridgeErrorCode.privateStorageUnavailable,
  );
  void _windows() {
    if (!Platform.isWindows) _fail();
  }

  String _sid(Pointer<Void> sid) {
    if (sid == nullptr) _fail();
    return using((arena) {
      final output = arena<Pointer<Utf16>>();
      if (_sidString(sid, output) == 0 || output.value == nullptr) _fail();
      try {
        return output.value.toDartString();
      } finally {
        _freeLocal(output.value.cast<Void>());
      }
    });
  }

  String get currentSid {
    _windows();
    final cached = _currentSid;
    if (cached != null) return cached;
    final value = using<String>((arena) {
      final handle = arena<Pointer<Void>>(), size = arena<Uint32>();
      if (_openToken(_process(), 0x0008, handle) == 0) _fail();
      try {
        _tokenInfo(
          handle.value,
          1,
          nullptr,
          0,
          size,
        ); // TokenUser, not a secret.
        if (size.value == 0 || size.value > 65536) _fail();
        final buffer = arena<Uint8>(size.value);
        if (_tokenInfo(
              handle.value,
              1,
              buffer.cast<Void>(),
              size.value,
              size,
            ) ==
            0)
          _fail();
        return _sid(buffer.cast<Pointer<Void>>().value);
      } finally {
        _close(handle.value);
      } // GetCurrentProcess pseudo-handle is never closed.
    });
    _currentSid = value;
    return value;
  }

  void rejectReparse(String path) {
    _windows();
    using((arena) {
      final flags = _attributes(path.toNativeUtf16(allocator: arena));
      if (flags == 0xffffffff || flags & 0x400 != 0) _fail();
    });
  }

  /// Uses the OS file handle to remove SUBST aliases; exported setup must not
  /// require an R: mapping visible only in a different execution context.
  String canonicalPath(String path) {
    _windows();
    return using((arena) {
      final handle = _openFile(
        path.toNativeUtf16(allocator: arena),
        0x80,
        7,
        nullptr,
        3,
        0x02000000,
        nullptr,
      );
      if (handle.address == -1 ||
          handle.address == 0xffffffffffffffff ||
          handle == nullptr)
        _fail();
      try {
        final buffer = arena<Uint16>(32768).cast<Utf16>();
        final length = _finalPath(handle, buffer, 32768, 0);
        if (length == 0 || length >= 32768) _fail();
        var resolved = buffer.toDartString(length: length);
        if (resolved.startsWith('\\\\?\\')) resolved = resolved.substring(4);
        if (!RegExp(r'^[A-Za-z]:[\\/]').hasMatch(resolved))
          _fail(); // No UNC/network descriptor.
        return resolved;
      } finally {
        _close(handle);
      }
    });
  }

  void secureNew(String path) {
    _windows();
    rejectReparse(path);
    using((arena) {
      final sd = arena<Pointer<Void>>();
      final sddl =
          'O:$currentSid'
          'D:P(A;OICI;FA;;;$currentSid)(A;OICI;FA;;;SY)';
      if (_fromSddl(sddl.toNativeUtf16(allocator: arena), 1, sd, nullptr) == 0)
        _fail();
      try {
        final owner = arena<Pointer<Void>>(), dacl = arena<Pointer<Void>>();
        final defaulted = arena<Int32>(), present = arena<Int32>();
        if (_sdOwner(sd.value, owner, defaulted) == 0 ||
            _sdDacl(sd.value, present, dacl, defaulted) == 0 ||
            present.value == 0 ||
            dacl.value == nullptr)
          _fail();
        final code = _setNamed(
          path.toNativeUtf16(allocator: arena),
          1,
          0x80000005,
          owner.value,
          nullptr,
          dacl.value,
          nullptr,
        );
        if (code != 0) _fail();
      } finally {
        _freeLocal(sd.value);
      }
    });
    verify(path);
  }

  void verify(String path) {
    _windows();
    rejectReparse(path);
    using((arena) {
      final owner = arena<Pointer<Void>>(), dacl = arena<Pointer<Void>>();
      final sd = arena<Pointer<Void>>();
      final result = _getNamed(
        path.toNativeUtf16(allocator: arena),
        1,
        5,
        owner,
        nullptr,
        dacl,
        nullptr,
        sd,
      );
      if (result != 0 || sd.value == nullptr) _fail();
      try {
        if (_sid(owner.value) != currentSid || dacl.value == nullptr) _fail();
        final text = arena<Pointer<Utf16>>();
        if (_toSddl(sd.value, 1, 5, text, nullptr) == 0 ||
            text.value == nullptr)
          _fail();
        late String encoded;
        try {
          encoded = text.value.toDartString();
        } finally {
          _freeLocal(text.value.cast<Void>());
        }
        final at = encoded.indexOf('D:');
        if (at < 0) _fail();
        final acl = encoded.substring(at + 2);
        final firstAce = acl.indexOf('(');
        if (firstAce < 0 || !acl.substring(0, firstAce).contains('P')) _fail();
        final seen = <String>{};
        final aces = RegExp(r'\(([^()]*)\)').allMatches(acl).toList();
        if (aces.isEmpty ||
            aces.map((m) => m.group(0)).join() != acl.substring(firstAce))
          _fail();
        for (final ace in aces) {
          final fields = ace.group(1)!.split(';');
          if (fields.length != 6 ||
              fields[0] != 'A' ||
              fields[3].isNotEmpty ||
              fields[4].isNotEmpty ||
              !{'FA', 'GA', '0x1f01ff'}.contains(fields[2]))
            _fail();
          final sid = fields[5] == 'SY' ? 'S-1-5-18' : fields[5];
          if (sid != currentSid && sid != 'S-1-5-18') _fail();
          seen.add(sid);
        }
        if (!seen.contains(currentSid) || !seen.contains('S-1-5-18')) _fail();
      } finally {
        _freeLocal(sd.value);
      }
    });
  }
}
