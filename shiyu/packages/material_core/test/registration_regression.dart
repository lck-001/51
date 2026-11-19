import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../lib/material_core.dart';
import 'support.dart';

const owner = 'synthetic-registration-owner';
String key(int n) => n.toRadixString(16).padLeft(64, '0');
String digest(List<int> b) => sha256.convert(b).toString();
final data = Uint8List.fromList([0, 1, 127, 128, 255]);
Directory partition(Directory root) =>
    Directory('${root.path}/${digest(utf8.encode('owner:$owner'))}');
File named(Directory root, String name) =>
    File('${partition(root).path}/$name');
Future<FileMaterialStore> open(Directory root) =>
    FileMaterialStore.open(root: root, trustedOwnerId: owner);
Future<ArtifactRef> register(FileMaterialStore s, int n, [Uint8List? b]) =>
    s.registerArtifactOnce(
      operationKey: key(n),
      expectedSha256: digest(b ?? data),
      bytes: b ?? data,
    );
Future<void> error(
  FutureOr<dynamic> Function() body,
  MaterialErrorCode code,
) async {
  try {
    await body();
  } on MaterialStoreException catch (e) {
    expectThat(e.code == code, 'expected ${code.name}, got ${e.code.name}');
    return;
  }
  throw StateError('expected ${code.name}');
}

Future<void> envelope(File f, Map<String, dynamic> p, int schema) async =>
    f.writeAsString(
      jsonEncode({
        'schema': schema,
        'payload': p,
        'sha256': digest(utf8.encode(jsonEncode(p))),
      }),
      flush: true,
    );
Map<String, dynamic> legacyPayload() => {
  'ownerId': owner,
  'sequence': 0,
  'drafts': <String, dynamic>{},
  'versions': <String, dynamic>{},
  'artifacts': <String, dynamic>{},
};
Future<void> legacy(Directory root, {bool backup = false}) async {
  await Directory('${partition(root).path}/artifacts').create(recursive: true);
  await envelope(named(root, 'manifest.json'), legacyPayload(), 1);
  if (backup) await envelope(named(root, 'manifest.bak'), legacyPayload(), 1);
  await named(
    root,
    'store.marker',
  ).writeAsString('material_core:1', flush: true);
}

Future<Map<String, dynamic>> payload(
  Directory root, [
  String name = 'manifest.json',
]) async =>
    (jsonDecode(await named(root, name).readAsString())
            as Map<String, dynamic>)['payload']
        as Map<String, dynamic>;
Future<void> held(FileMaterialStore s) async {
  expectThat(
    s.recoveryReport.issues.any(
      (i) => i.kind == RecoveryIssueKind.registrationHold,
    ),
    'hold report',
  );
  await error(() => register(s, 99), MaterialErrorCode.recoveryHold);
  await error(
    () => s.findArtifactRegistration(key(1)),
    MaterialErrorCode.recoveryHold,
  );
  await error(() => s.importArtifact(data), MaterialErrorCode.recoveryHold);
  await error(
    () => s.createDraft(title: 'synthetic'),
    MaterialErrorCode.recoveryHold,
  );
}

// Test-only IOOverrides stops *after* the actual filesystem rename. It neither
// changes production code nor turns a pending snapshot into committed data.
final class StopIO extends IOOverrides {
  StopIO(this.point);
  final String point;
  @override
  File createFile(String path) => StopFile(super.createFile(path), point);
}

class StopFile implements File {
  StopFile(this.inner, this.point);
  final File inner;
  final String point;
  @override
  String get path => inner.path;
  @override
  Uri get uri => inner.uri;
  @override
  Future<String> readAsString({Encoding encoding = utf8}) =>
      inner.readAsString(encoding: encoding);
  @override
  Future<Uint8List> readAsBytes() => inner.readAsBytes();
  @override
  Future<int> length() => inner.length();
  @override
  Stream<List<int>> openRead([int? start, int? end]) =>
      inner.openRead(start, end);
  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) => inner.writeAsString(
    contents,
    mode: mode,
    encoding: encoding,
    flush: flush,
  );
  @override
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) => inner.writeAsBytes(bytes, mode: mode, flush: flush);
  @override
  Future<File> rename(String newPath) async {
    final result = await inner.rename(newPath);
    final basename = newPath.replaceAll('\\', '/').split('/').last;
    if (basename == point || (point == 'blob' && basename.endsWith('.blob'))) {
      stdout.writeln('STOP $pid $point');
      await stdout.flush();
      await Completer<void>().future;
    }
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> crash(
  Directory root,
  String point, {
  bool migration = false,
}) async {
  final exe = File(
    '${File(Platform.resolvedExecutable).parent.path}/dartvm.exe',
  );
  expectThat(await exe.exists(), 'real Dart VM required');
  final child = await Process.start(exe.path, [
    Platform.script.toFilePath(),
    '--child',
    root.path,
    point,
    migration ? 'migrate' : 'register',
  ], workingDirectory: Directory.current.path);
  final stderrText = child.stderr.transform(utf8.decoder).join();
  var identity = false;
  try {
    final lines = StreamIterator(
      child.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    expectThat(
      await lines.moveNext().timeout(const Duration(seconds: 12)) &&
          lines.current == 'READY ${child.pid}',
      'actual child VM PID handshake',
    );
    identity = true;
    expectThat(
      await lines.moveNext().timeout(const Duration(seconds: 12)),
      'checkpoint required',
    );
    final fields = lines.current.split(' ');
    expectThat(
      fields.length == 3 &&
          fields[0] == 'STOP' &&
          int.parse(fields[1]) == child.pid &&
          fields[2] == point,
      'actual child VM PID checkpoint',
    );
    await lines.cancel();
    identity = true;
    expectThat(child.kill(), 'terminate owned confirmed VM');
    await child.exitCode.timeout(const Duration(seconds: 5));
    await stderrText;
  } finally {
    // This Process object is created by this test. Never enumerate/kill others.
    if (identity) {
      child.kill();
      await child.exitCode;
    }
  }
}

Future<void> main(List<String> args) async {
  if (args.isNotEmpty && args.first == '--child') {
    stdout.writeln('READY $pid');
    await stdout.flush();
    await IOOverrides.runWithIOOverrides(() async {
      final s = await open(Directory(args[1]));
      if (args[3] == 'register') await register(s, 1);
      throw StateError('checkpoint not reached');
    }, StopIO(args[2]));
  }
  final c = Cases();
  await c.run(
    'trusted-key validation, copy-before-await, exact bytes conflict and independent operation identity',
    () => inSandbox((root) async {
      final s = await open(root);
      await error(
        () => s.registerArtifactOnce(
          operationKey: '../',
          expectedSha256: digest(data),
          bytes: data,
        ),
        MaterialErrorCode.invalidOperationKey,
      );
      await error(
        () => s.findArtifactRegistration('${key(1)}\n'),
        MaterialErrorCode.invalidOperationKey,
      );
      await error(
        () => s.registerArtifactOnce(
          operationKey: key(1),
          expectedSha256: key(0),
          bytes: data,
        ),
        MaterialErrorCode.invalidArtifactDigest,
      );
      await error(
        () => register(s, 1, Uint8List(0)),
        MaterialErrorCode.capacityExceeded,
      );
      await error(
        () => register(
          s,
          1,
          Uint8List(ArtifactRegistrationLimits.maxArtifactBytes + 1),
        ),
        MaterialErrorCode.capacityExceeded,
      );
      final mutable = Uint8List.fromList(data);
      final future = register(s, 1, mutable);
      mutable[0] = 42;
      final refs = await Future.wait([future, register(s, 1)]);
      expectThat(
        refs[0].artifactId == refs[1].artifactId,
        'concurrent one ref',
      );
      expectThat((await s.readArtifact(refs[0]))[0] == 0, 'copied bytes');
      await error(
        () => register(s, 1, Uint8List.fromList([0, 1, 127, 128, 254])),
        MaterialErrorCode.artifactConflict,
      );
      expectThat(
        (await register(s, 2)).artifactId != refs[0].artifactId,
        'no global dedup',
      );
      await s.close();
      final reopened = await open(root);
      expectThat(
        (await register(reopened, 1)).artifactId == refs[0].artifactId,
        'reopen original ref',
      );
      await reopened.close();
    }),
  );
  await c.run(
    'legacy first initialization without backup and completed migration preserve schema facts',
    () => inSandbox((root) async {
      await legacy(root);
      final before = await payload(root);
      final s = await open(root);
      expectThat(
        !s.recoveryReport.issues.any(
          (i) => i.kind == RecoveryIssueKind.registrationHold,
        ),
        'normal initial legacy no hold',
      );
      final after = await payload(root);
      after.remove('artifactOperations');
      expectThat(
        jsonEncode(before) == jsonEncode(after),
        'legacy fields unchanged',
      );
      expectThat(
        await named(root, 'store.marker').readAsString() == 'material_core:2',
        'marker2',
      );
      expectThat(
        (jsonDecode(await named(root, 'manifest.bak').readAsString())
                as Map)['schema'] ==
            2,
        'backup2 first',
      );
      await register(s, 1);
      await s.close();
    }),
  );
  await c.run(
    'legacy corrupt or non-file backup cannot masquerade as missing',
    () => inSandbox((root) async {
      for (final directory in [false, true]) {
        final r = Directory('${root.path}/${directory ? 'directory' : 'bad'}');
        await legacy(r);
        if (directory) {
          await Directory(named(r, 'manifest.bak').path).create();
        } else {
          await named(r, 'manifest.bak').writeAsString('broken');
        }
        final s = await open(r);
        await held(s);
        await s.close();
        final reopened = await open(r);
        await held(reopened);
        await reopened.close();
      }
    }),
  );
  await c.run(
    'legacy fallback holds before restore and remains readable across restart',
    () => inSandbox((root) async {
      await legacy(root, backup: true);
      await named(root, 'manifest.json').writeAsString('broken');
      final s = await open(root);
      await held(s);
      expectThat((await s.listDrafts()).isEmpty, 'valid historical read');
      expectThat(
        s.recoveryReport.status == RecoveryStatus.recoveredFromBackup,
        'explicit fallback',
      );
      await s.close();
      final again = await open(root);
      await held(again);
      await again.close();
    }),
  );
  await c.run(
    'lossy op fallback cannot recreate lost key, all writes held, history readable',
    () => inSandbox((root) async {
      final s = await open(root);
      final draft = await s.createDraft(title: 'synthetic history');
      await s.confirmVersion(materialId: draft.materialId, expectedRevision: 1);
      await register(s, 1);
      await s.close();
      await named(root, 'manifest.json').writeAsString('broken');
      var r = await open(root);
      await held(r);
      expectThat(
        (await r.readDraft(draft.materialId)).title == 'synthetic history',
        'history retained',
      );
      await error(
        () => r.updateDraft(
          materialId: draft.materialId,
          expectedRevision: 1,
          title: 'blocked',
        ),
        MaterialErrorCode.recoveryHold,
      );
      await error(
        () =>
            r.confirmVersion(materialId: draft.materialId, expectedRevision: 1),
        MaterialErrorCode.recoveryHold,
      );
      await r.close();
      r = await open(root);
      await held(r);
      await r.close();
    }),
  );
  await c.run(
    'failed hold persistence leaves original damaged primary untouched',
    () => inSandbox((root) async {
      final s = await open(root);
      await register(s, 1);
      await s.close();
      await named(root, 'manifest.json').writeAsString('broken');
      await Directory(named(root, 'registration.hold.next').path).create();
      await error(() => open(root), MaterialErrorCode.corruptStore);
      expectThat(
        await named(root, 'manifest.json').readAsString() == 'broken',
        'no restore before durable hold',
      );
    }),
  );
  await c.run(
    'missing marker and downgrade mismatch persist hold',
    () => inSandbox((root) async {
      final s = await open(root);
      await register(s, 1);
      await s.close();
      await named(root, 'store.marker').delete();
      final r = await open(root);
      await held(r);
      await r.close();
    }),
  );
  await c.run(
    '128-operation saturation allows existing key only, closed remains closed',
    () => inSandbox((root) async {
      final s = await open(root);
      final first = await register(s, 1);
      for (var i = 2; i <= 128; i++) {
        await register(s, i);
      }
      expectThat(
        (await register(s, 1)).artifactId == first.artifactId,
        'full replay',
      );
      await error(() => register(s, 129), MaterialErrorCode.capacityExceeded);
      await s.close();
      await error(() => register(s, 1), MaterialErrorCode.closed);
    }),
  );
  await c.run(
    'actual orphan, incomplete and legacy bytes count toward 64MiB; full replay no new blob',
    () => inSandbox((root) async {
      final s = await open(root);
      final first = await register(s, 1);
      await s.importArtifact(data);
      final dir = Directory('${partition(root).path}/artifacts');
      await File('${dir.path}/unknown.next').writeAsBytes([1, 2, 3]);
      final orphan = File('${dir.path}/${'a' * 32}.blob');
      final out = await orphan.open(mode: FileMode.write);
      await out.truncate(
        ArtifactRegistrationLimits.maxRetainedBytes - data.length * 2 - 3,
      );
      await out.close();
      await error(() => register(s, 2), MaterialErrorCode.capacityExceeded);
      expectThat(
        (await register(s, 1)).artifactId == first.artifactId,
        'full existing replay',
      );
      final count = await dir.list().length;
      expectThat(
        count == 4,
        'retained entries not deleted/new files not created',
      );
      await s.close();
    }),
  );
  await c.run(
    '2MiB exact source accepted; missing and same-length corrupt registered bytes never fake success',
    () => inSandbox((root) async {
      final s = await open(root);
      await register(
        s,
        1,
        Uint8List(ArtifactRegistrationLimits.maxArtifactBytes),
      );
      final ref = await register(s, 2);
      final f = named(root, 'artifacts/${ref.artifactId}.blob');
      await f.writeAsBytes([0, 1, 127, 128, 254]);
      await error(() => register(s, 2), MaterialErrorCode.artifactCorrupt);
      await f.delete();
      await error(
        () => s.findArtifactRegistration(key(2)),
        MaterialErrorCode.missingArtifact,
      );
      await s.close();
    }),
  );
  await c.run(
    'schema2 downgrade, incomplete hold and forged operation snapshots fail closed',
    () => inSandbox((root) async {
      for (final kind in ['downgrade', 'incomplete', 'forged']) {
        final dir = Directory('${root.path}/$kind');
        final s = await open(dir);
        await register(s, 1);
        await s.close();
        if (kind == 'downgrade') {
          await envelope(named(dir, 'manifest.bak'), legacyPayload(), 1);
        }
        if (kind == 'incomplete') {
          await named(dir, 'registration.hold.next').writeAsString('{');
        }
        if (kind == 'forged') {
          final p = await payload(dir);
          (p['artifactOperations'] as Map)[key(1)]['artifactId'] = 'f' * 32;
          await envelope(named(dir, 'manifest.json'), p, 2);
        }
        final r = await open(dir);
        await held(r);
        await r.close();
        final again = await open(dir);
        await held(again);
        await again.close();
      }
    }),
  );
  await c.run(
    'commit failure permanently blocks replay and does not lose durable hold on reopen',
    () => inSandbox((root) async {
      final s = await open(root);
      await register(s, 1);
      await Directory(named(root, 'manifest.next').path).create();
      await error(() => register(s, 2), MaterialErrorCode.writeFailed);
      await error(() => register(s, 1), MaterialErrorCode.recoveryHold);
      await error(
        () => s.findArtifactRegistration(key(1)),
        MaterialErrorCode.recoveryHold,
      );
      await s.close();
      // Replace only this test-owned obstruction; the persisted hold must remain.
      await Directory(named(root, 'manifest.next').path).delete();
      final r = await open(root);
      await held(r);
      await r.close();
    }),
  );
  await c.run(
    'unaccountable residual directory refuses new admission without cleanup',
    () => inSandbox((root) async {
      final s = await open(root);
      await Directory('${partition(root).path}/artifacts/unknown').create();
      await error(() => register(s, 1), MaterialErrorCode.capacityExceeded);
      expectThat(
        await Directory('${partition(root).path}/artifacts/unknown').exists(),
        'residual retained',
      );
      await s.close();
    }),
  );
  for (final point in ['manifest.bak', 'manifest.json', 'store.marker']) {
    await c.run(
      'real VM migration crash after $point rename resumes without loss',
      () => inSandbox((root) async {
        await legacy(root);
        await crash(root, point, migration: true);
        final s = await open(root);
        expectThat(
          !s.recoveryReport.issues.any(
            (i) => i.kind == RecoveryIssueKind.registrationHold,
          ),
          'completed-boundary migration resumes',
        );
        await register(s, 1);
        await s.close();
      }),
    );
  }
  await c.run(
    'real VM commit ACK gap returns persisted original ref',
    () => inSandbox((root) async {
      final s = await open(root);
      await s.close();
      await crash(root, 'manifest.json');
      final committed = await payload(root);
      final id = (committed['artifactOperations'] as Map)[key(1)]['artifactId'];
      final r = await open(root);
      expectThat(
        (await register(r, 1)).artifactId == id,
        'ACK gap original authority',
      );
      expectThat(
        (await r.findArtifactRegistration(key(1)))!.artifactId == id,
        'read only op query',
      );
      await r.close();
    }),
  );
  await c.run(
    'real VM blob-before-index crash creates accounted orphan, never fake registration',
    () => inSandbox((root) async {
      final s = await open(root);
      await s.close();
      await crash(root, 'blob');
      final r = await open(root);
      expectThat(
        await r.findArtifactRegistration(key(1)) == null,
        'orphan not authority',
      );
      expectThat(
        r.recoveryReport.issues.any(
          (i) => i.kind == RecoveryIssueKind.orphanArtifact,
        ),
        'orphan reported',
      );
      await register(r, 1);
      expectThat(
        await Directory('${partition(root).path}/artifacts').list().length == 2,
        'orphan retained',
      );
      await r.close();
    }),
  );
  c.finish();
}
