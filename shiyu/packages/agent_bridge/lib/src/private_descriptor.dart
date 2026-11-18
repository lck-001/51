import 'dart:io';
import 'dart:typed_data';

import 'contracts.dart';
import 'root_lock.dart';
import 'strict_json.dart';
import 'windows_privacy.dart';

/// Secret-bearing transport data. Never put this in status, stdout, a URL,
/// command line, diagnostic exception, fixture in Git, or a model tool result.
final class BridgeDescriptor {
  BridgeDescriptor({
    required this.port,
    required this.session,
    required this.capability,
    required this.proofKey,
    required this.integrationId,
    required this.materialId,
    required this.materialVersionId,
    required this.sourceTextSha256,
    required this.expiresAtUtc,
    required this.allowSourceRead,
  });
  final int port;
  final String session, capability, proofKey, integrationId;
  final String materialId, materialVersionId, sourceTextSha256;
  final DateTime expiresAtUtc;
  final bool allowSourceRead;
  Map<String, Object?> toJson() => {
    'schema_version': 1,
    'host': '127.0.0.1',
    'port': port,
    'session': session,
    'capability': capability,
    'proof_key': proofKey,
    'integration_id': integrationId,
    'material_id': materialId,
    'material_version_id': materialVersionId,
    'source_text_sha256': sourceTextSha256,
    'expires_at': expiresAtUtc.toUtc().toIso8601String(),
    'allow_source_read': allowSourceRead,
  };
  static BridgeDescriptor parse(Object? decoded) {
    Never bad() => throw const AgentBridgeException(
      AgentBridgeErrorCode.privateStorageUnavailable,
    );
    if (decoded is! Map<String, dynamic>) bad();
    final m = decoded;
    const keys = {
      'schema_version',
      'host',
      'port',
      'session',
      'capability',
      'proof_key',
      'integration_id',
      'material_id',
      'material_version_id',
      'source_text_sha256',
      'expires_at',
      'allow_source_read',
    };
    if (m.keys.toSet().difference(keys).isNotEmpty ||
        m.length != keys.length ||
        m['schema_version'] != 1 ||
        m['host'] != '127.0.0.1' ||
        m['port'] is! int ||
        (m['port'] as int) < 1 ||
        (m['port'] as int) > 65535 ||
        m['allow_source_read'] is! bool)
      bad();
    for (final key in ['session', 'material_id', 'material_version_id']) {
      if (m[key] is! String ||
          !RegExp(r'^[a-f0-9]{32}$').hasMatch(m[key] as String))
        bad();
    }
    for (final key in ['capability', 'proof_key', 'source_text_sha256']) {
      if (m[key] is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(m[key] as String))
        bad();
    }
    if (m['integration_id'] is! String ||
        !RegExp(r'^[a-z0-9_-]{1,80}$')
            .hasMatch(m['integration_id'] as String) ||
        m['expires_at'] is! String ||
        !(m['expires_at'] as String).endsWith('Z'))
      bad();
    final expiry = DateTime.tryParse(m['expires_at'] as String);
    if (expiry == null) bad();
    return BridgeDescriptor(
      port: m['port'] as int,
      session: m['session'] as String,
      capability: m['capability'] as String,
      proofKey: m['proof_key'] as String,
      integrationId: m['integration_id'] as String,
      materialId: m['material_id'] as String,
      materialVersionId: m['material_version_id'] as String,
      sourceTextSha256: m['source_text_sha256'] as String,
      expiresAtUtc: expiry,
      allowSourceRead: m['allow_source_read'] as bool,
    );
  }
}

final class PrivateDescriptorStore {
  PrivateDescriptorStore({required this.rootLock, required this.directory});
  final LearningRootLock rootLock;
  final Directory directory;
  Directory? _canonical;
  String get path => '${(_canonical ?? directory).path}/descriptor.json';
  Never _fail() => throw const AgentBridgeException(
    AgentBridgeErrorCode.privateStorageUnavailable,
  );
  String _key(String p) =>
      p.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '').toLowerCase();

  Future<void> prepare() async {
    if (!rootLock.isHeld || !Platform.isWindows) _fail();
    // The reserved private directory is a direct child, never a caller-supplied
    // arbitrary subtree to create, chmod, recursively delete or execute in.
    final requested = directory.absolute;
    final parent = WindowsPrivacy.instance.canonicalPath(requested.parent.path);
    if (_key(parent) != _key(rootLock.rootDirectory.path)) _fail();
    final kind = await FileSystemEntity.type(
      requested.path,
      followLinks: false,
    );
    if (kind == FileSystemEntityType.notFound) {
      await requested.create();
      WindowsPrivacy.instance.secureNew(requested.path);
    } else {
      if (kind != FileSystemEntityType.directory) _fail();
      WindowsPrivacy.instance.verify(requested.path);
    }
    final canonical = Directory(
      WindowsPrivacy.instance.canonicalPath(requested.path),
    );
    if (_key(canonical.parent.path) != _key(rootLock.rootDirectory.path))
      _fail();
    _canonical = canonical;
  }

  Future<void> write(BridgeDescriptor descriptor) async {
    await prepare();
    final file = File(path);
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type != FileSystemEntityType.notFound) {
      if (type != FileSystemEntityType.file) _fail();
      WindowsPrivacy.instance.verify(file.path);
    }
    final temporary = File(
      '${file.parent.path}/descriptor.${descriptor.session}.next',
    );
    var owned = false;
    try {
      await temporary.create(exclusive: true);
      owned = true;
      WindowsPrivacy.instance.secureNew(temporary.path);
      final bytes = encodeAgentBridgeJson(descriptor.toJson(), maxBytes: 8192);
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(file.path);
      owned = false;
      WindowsPrivacy.instance.verify(file.path);
    } catch (_) {
      _fail();
    } finally {
      if (owned) {
        try {
          await temporary.delete();
        } catch (_) {}
      }
    }
  }

  Future<void> deleteIfSession(String session) async {
    final file = File(path);
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    final current = await readPrivateDescriptor(file.path);
    if (current.session == session) await file.delete();
  }
}

/// The stdio proxy's only file input. It never discovers or opens a Store.
Future<BridgeDescriptor> readPrivateDescriptor(String requestedPath) async {
  Never fail() => throw const AgentBridgeException(
    AgentBridgeErrorCode.privateStorageUnavailable,
  );
  if (!Platform.isWindows || requestedPath.isEmpty) fail();
  final file = File(requestedPath).absolute;
  if (file.uri.pathSegments.last != 'descriptor.json' ||
      await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file ||
      await FileSystemEntity.type(file.parent.path, followLinks: false) !=
          FileSystemEntityType.directory)
    fail();
  WindowsPrivacy.instance.verify(file.parent.path);
  WindowsPrivacy.instance.verify(file.path);
  final canonical = WindowsPrivacy.instance.canonicalPath(file.path);
  final input = await File(canonical).open();
  final builder = BytesBuilder(copy: false);
  try {
    while (true) {
      final maximum = 8192 - builder.length + 1;
      final bytes = await input.read(maximum < 1024 ? maximum : 1024);
      if (bytes.isEmpty) break;
      if (builder.length + bytes.length > 8192) fail();
      builder.add(bytes);
    }
    return BridgeDescriptor.parse(
      decodeAgentBridgeJson(builder.takeBytes(), maxBytes: 8192),
    );
  } on AgentBridgeException {
    rethrow;
  } catch (_) {
    fail();
  } finally {
    await input.close();
  }
}
