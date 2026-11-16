import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../lib/material_core.dart';
import 'support.dart';

const ownerA = 'synthetic-owner-a';
const ownerB = 'synthetic-owner-b';
const story = 'A synthetic story about a blue paper boat.';
final binary = Uint8List.fromList(
  List<int>.generate(513, (i) => (i * 73) % 256),
);

bool equalBytes(List<int> a, List<int> b) =>
    a.length == b.length &&
    List<int>.generate(a.length, (i) => i).every((i) => a[i] == b[i]);

Future<MaterialStoreException> expectError(
  Future<dynamic> Function() action,
  Set<MaterialErrorCode> codes,
) async {
  try {
    await action();
  } on MaterialStoreException catch (error) {
    expectThat(
      codes.contains(error.code),
      'unexpected material error: ${error.code.name}',
    );
    return error;
  }
  throw StateError(
    'operation unexpectedly succeeded instead of explicit failure',
  );
}

/// These are the documented on-disk interchange locations, not private fields.
class Lab {
  Lab(this.sandbox)
    : root = Directory('${sandbox.path}${Platform.pathSeparator}cache');
  final Directory sandbox, root;
  final List<MaterialStore> active = [];
  Future<MaterialStore> open([String owner = ownerA]) async {
    final store = await FileMaterialStore.open(
      root: root,
      trustedOwnerId: owner,
    );
    active.add(store);
    return store;
  }

  Future<void> close(MaterialStore store) async {
    active.remove(store);
    await store.close();
  }

  Directory ownerDirectory([String owner = ownerA]) => Directory(
    '${root.path}${Platform.pathSeparator}${sha256.convert(utf8.encode('owner:$owner'))}',
  );
  File manifest([String owner = ownerA]) => File(
    '${ownerDirectory(owner).path}${Platform.pathSeparator}manifest.json',
  );
  File backup([String owner = ownerA]) => File(
    '${ownerDirectory(owner).path}${Platform.pathSeparator}manifest.bak',
  );
  File pending([String owner = ownerA]) => File(
    '${ownerDirectory(owner).path}${Platform.pathSeparator}manifest.next',
  );
  File blob(ArtifactRef ref) => File(
    '${ownerDirectory(ref.ownerId).path}${Platform.pathSeparator}artifacts${Platform.pathSeparator}${ref.artifactId}.blob',
  );
  Future<void> finish() async {
    for (final store in active.reversed.toList()) {
      await close(store);
    }
  }
}

Future<void> using(Future<void> Function(Lab) body) =>
    inSandbox((directory) async {
      final lab = Lab(directory);
      try {
        await body(lab);
      } finally {
        await lab.finish();
      }
    });

Future<MaterialDraft> checkpoint(MaterialStore store) async {
  final first = await store.createDraft(
    title: 'Synthetic checkpoint',
    text: story,
  );
  await store.updateDraft(
    materialId: first.materialId,
    expectedRevision: first.revision,
    text: '$story Revision two.',
  );
  return first;
}

Object? replaceValue(Object? value, String from, String to) {
  if (value == from) return to;
  if (value is List)
    return value.map((v) => replaceValue(v, from, to)).toList();
  if (value is Map)
    return value.map((k, v) => MapEntry(k, replaceValue(v, from, to)));
  return value;
}

Future<void> replaceInEnvelope(File file, String from, String to) async {
  final envelope =
      jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  final payload = replaceValue(envelope['payload'], from, to);
  envelope['payload'] = payload;
  envelope['sha256'] = sha256
      .convert(utf8.encode(jsonEncode(payload)))
      .toString();
  await file.writeAsString(jsonEncode(envelope), flush: true);
}

Future<void> verifyInNewProcess(
  Lab lab,
  MaterialDraft draft,
  MaterialVersion version,
  ArtifactRef ref,
) async {
  final process = await Process.start(Platform.resolvedExecutable, [
    Platform.script.toFilePath(),
    '--verify-reopen',
    lab.root.path,
    ownerA,
    draft.materialId,
    version.versionId,
    ref.artifactId,
    ref.byteLength.toString(),
    ref.sha256,
  ], workingDirectory: Directory.current.path);
  final output = process.stdout.transform(utf8.decoder).join();
  final errors = process.stderr.drain<void>();
  int result;
  try {
    result = await process.exitCode.timeout(const Duration(seconds: 10));
  } on TimeoutException {
    process.kill();
    await process.exitCode.timeout(const Duration(seconds: 3));
    throw StateError('independent Dart reopen did not finish');
  }
  final text = await output;
  await errors;
  expectThat(
    result == 0 && text.trim() == 'CHILD_REOPEN_OK',
    'independent Dart process could not recover persisted version and binary',
  );
}

Future<void> child(List<String> args) async {
  MaterialStore? store;
  try {
    store = await FileMaterialStore.open(
      root: Directory(args[1]),
      trustedOwnerId: args[2],
    );
    final draft = await store.readDraft(args[3]);
    final version = await store.readVersion(args[4]);
    final ref = ArtifactRef(
      ownerId: args[2],
      artifactId: args[5],
      byteLength: int.parse(args[6]),
      sha256: args[7],
    );
    expectThat(
      draft.text == story && version.text == story,
      'child content differs',
    );
    expectThat(
      equalBytes(await store.readArtifact(ref), binary),
      'child binary differs',
    );
    expectThat((await store.listDrafts()).length == 1, 'child index differs');
    stdout.writeln('CHILD_REOPEN_OK');
  } catch (_) {
    stdout.writeln('CHILD_REOPEN_FAILED');
    exitCode = 1;
  } finally {
    await store?.close();
  }
}

Future<void> main(List<String> args) async {
  if (args.isNotEmpty && args.first == '--verify-reopen') {
    await child(args);
    return;
  }
  final tests = Cases();

  await tests.run(
    'New empty store is explicit initialization, not corruption recovery',
    () => using((lab) async {
      final s = await lab.open();
      expectThat(
        s.recoveryReport.status == RecoveryStatus.initialized &&
            (await s.listDrafts()).isEmpty,
        'only a genuinely new root initializes empty',
      );
    }),
  );

  await tests.run(
    'Draft persists to a fresh repository instance',
    () => using((lab) async {
      final s = await lab.open();
      final d = await s.createDraft(title: 'Synthetic story', text: story);
      expectThat(
        await lab.manifest().exists() && await lab.manifest().length() > 0,
        'successful draft requires nonempty on-disk manifest',
      );
      await lab.close(s);
      final reopened = await lab.open();
      final got = await reopened.readDraft(d.materialId);
      expectThat(
        got.text == story && got.ownerId == ownerA && got.revision == 1,
        'new instance must recover owner, content and revision',
      );
    }),
  );

  await tests.run(
    'Independent Dart process restores index, version and binary',
    () => using((lab) async {
      final s = await lab.open();
      final ref = await s.importArtifact(binary);
      final d = await s.createDraft(
        title: 'Synthetic process fixture',
        text: story,
        artifacts: [ref],
      );
      final v = await s.confirmVersion(
        materialId: d.materialId,
        expectedRevision: d.revision,
      );
      await lab.close(s);
      await verifyInNewProcess(lab, d, v, ref);
    }),
  );

  await tests.run(
    'Two trusted synthetic owners have separate lists and cannot read each other',
    () => using((lab) async {
      final a = await lab.open();
      final b = await lab.open(ownerB);
      final da = await a.createDraft(
        title: 'Same synthetic title',
        text: 'A private synthetic text',
      );
      final db = await b.createDraft(
        title: 'Same synthetic title',
        text: 'B private synthetic text',
      );
      final va = await a.confirmVersion(
        materialId: da.materialId,
        expectedRevision: da.revision,
      );
      expectThat(
        (await a.listDrafts()).single.materialId == da.materialId &&
            (await b.listDrafts()).single.materialId == db.materialId,
        'owner lists must remain separate',
      );
      await expectError(() => b.readDraft(da.materialId), {
        MaterialErrorCode.notFound,
        MaterialErrorCode.ownerMismatch,
      });
      await expectError(() => b.readVersion(va.versionId), {
        MaterialErrorCode.notFound,
        MaterialErrorCode.ownerMismatch,
      });
      await expectError(() => b.listVersions(da.materialId), {
        MaterialErrorCode.notFound,
        MaterialErrorCode.ownerMismatch,
      });
    }),
  );

  await tests.run(
    'Foreign artifact reference is denied without reading its bytes',
    () => using((lab) async {
      final a = await lab.open();
      final ref = await a.importArtifact(binary);
      final b = await lab.open(ownerB);
      await expectError(() => b.readArtifact(ref), {
        MaterialErrorCode.ownerMismatch,
      });
      await expectError(
        () => b.createDraft(
          title: 'Synthetic forged attachment',
          artifacts: [ref],
        ),
        {MaterialErrorCode.ownerMismatch},
      );
      expectThat(
        (await b.listDrafts()).isEmpty,
        'denied foreign attachment must not create a draft',
      );
    }),
  );

  await tests.run(
    'Stale expectedRevision cannot overwrite newer draft',
    () => using((lab) async {
      final s = await lab.open();
      final d = await s.createDraft(title: 'Synthetic rev', text: 'one');
      final updated = await s.updateDraft(
        materialId: d.materialId,
        expectedRevision: 1,
        text: 'two',
      );
      expectThat(
        updated.revision == 2,
        'successful update increments revision',
      );
      await expectError(
        () => s.updateDraft(
          materialId: d.materialId,
          expectedRevision: 1,
          text: 'stale overwrite',
        ),
        {MaterialErrorCode.revisionConflict},
      );
      expectThat(
        (await s.readDraft(d.materialId)).text == 'two',
        'conflict preserves committed content',
      );
    }),
  );

  await tests.run(
    'Stale confirmation cannot manufacture a version',
    () => using((lab) async {
      final s = await lab.open();
      final d = await s.createDraft(title: 'Synthetic confirm');
      await s.updateDraft(
        materialId: d.materialId,
        expectedRevision: 1,
        text: 'updated',
      );
      await expectError(
        () => s.confirmVersion(materialId: d.materialId, expectedRevision: 1),
        {MaterialErrorCode.revisionConflict},
      );
      expectThat(
        (await s.listVersions(d.materialId)).isEmpty,
        'failed confirm creates no version',
      );
    }),
  );

  await tests.run(
    'Confirmed old version and its binary stay immutable after edits',
    () => using((lab) async {
      final s = await lab.open();
      final firstRef = await s.importArtifact(binary);
      final d = await s.createDraft(
        title: 'Synthetic original',
        text: 'first text',
        artifacts: [firstRef],
      );
      final v1 = await s.confirmVersion(
        materialId: d.materialId,
        expectedRevision: 1,
      );
      final secondRef = await s.importArtifact(Uint8List.fromList([9, 8, 7]));
      final changed = await s.updateDraft(
        materialId: d.materialId,
        expectedRevision: 1,
        title: 'Synthetic changed',
        text: 'second text',
        artifacts: [secondRef],
      );
      final v2 = await s.confirmVersion(
        materialId: d.materialId,
        expectedRevision: changed.revision,
      );
      await lab.close(s);
      final restored = await lab.open();
      final old = await restored.readVersion(v1.versionId);
      expectThat(
        old.text == 'first text' &&
            old.title == 'Synthetic original' &&
            old.draftRevision == 1 &&
            old.artifacts.single.artifactId == firstRef.artifactId,
        'old version may never follow mutable draft',
      );
      expectThat(
        v2.versionNumber > v1.versionNumber &&
            v2.versionId != v1.versionId &&
            v2.draftRevision == 2,
        'new confirmation has separate version anchor',
      );
      expectThat(
        equalBytes(await restored.readArtifact(old.artifacts.single), binary),
        'old binary remains byte-identical',
      );
    }),
  );

  await tests.run(
    'Original file and caller buffer are not overwritten by cache updates',
    () => using((lab) async {
      final original = File(
        '${lab.sandbox.path}${Platform.pathSeparator}synthetic-original.bin',
      );
      await original.writeAsBytes(binary, flush: true);
      final s = await lab.open();
      final buffer = await original.readAsBytes();
      final ref = await s.importArtifact(buffer);
      buffer.fillRange(0, buffer.length, 0);
      final d = await s.createDraft(
        title: 'Synthetic original preservation',
        artifacts: [ref],
      );
      await s.updateDraft(
        materialId: d.materialId,
        expectedRevision: 1,
        text: 'new metadata',
      );
      expectThat(
        equalBytes(await original.readAsBytes(), binary),
        'repository must not mutate original source',
      );
      expectThat(
        equalBytes(await s.readArtifact(ref), binary),
        'buffer changes after import do not alter cached artifact',
      );
    }),
  );

  await tests.run(
    'Binary recovery preserves every byte including zero and high-bit values',
    () => using((lab) async {
      final s = await lab.open();
      final ref = await s.importArtifact(binary);
      await s.createDraft(title: 'Synthetic binary', artifacts: [ref]);
      await lab.close(s);
      final restored = await lab.open();
      final got = await restored.readArtifact(ref);
      expectThat(
        equalBytes(got, binary) && ref.byteLength == binary.length,
        'binary must not become text/base64 or truncate at null',
      );
      got[0] ^= 255;
      expectThat(
        equalBytes(await restored.readArtifact(ref), binary),
        'returned byte buffer cannot mutate persisted source',
      );
    }),
  );

  await tests.run(
    'Missing artifact is degraded, not a successfully empty library',
    () => using((lab) async {
      final s = await lab.open();
      final ref = await s.importArtifact(binary);
      final d = await s.createDraft(
        title: 'Synthetic missing attachment',
        text: story,
        artifacts: [ref],
      );
      await lab.close(s);
      await lab.blob(ref).delete();
      final restored = await lab.open();
      expectThat(
        restored.recoveryReport.issues.any(
          (i) => i.kind == RecoveryIssueKind.artifactMissing,
        ),
        'missing cache blob must be reported',
      );
      expectThat(
        (await restored.readDraft(d.materialId)).text == story,
        'missing media must not silently delete text/index',
      );
      await expectError(() => restored.readArtifact(ref), {
        MaterialErrorCode.missingArtifact,
      });
    }),
  );

  await tests.run(
    'Same-length artifact corruption is detected by integrity check',
    () => using((lab) async {
      final s = await lab.open();
      final ref = await s.importArtifact(binary);
      await s.createDraft(
        title: 'Synthetic damaged attachment',
        artifacts: [ref],
      );
      await lab.close(s);
      final damaged = Uint8List.fromList(binary);
      damaged[20] ^= 1;
      await lab.blob(ref).writeAsBytes(damaged, flush: true);
      final restored = await lab.open();
      expectThat(
        restored.recoveryReport.issues.any(
          (i) => i.kind == RecoveryIssueKind.artifactCorrupt,
        ),
        'equal length is not proof of integrity',
      );
      await expectError(() => restored.readArtifact(ref), {
        MaterialErrorCode.artifactCorrupt,
      });
    }),
  );

  await tests.run(
    'Caller-supplied wrong length or hash is rejected',
    () => using((lab) async {
      final s = await lab.open();
      final ref = await s.importArtifact(binary);
      final wrongHash = ArtifactRef(
        ownerId: ownerA,
        artifactId: ref.artifactId,
        byteLength: ref.byteLength,
        sha256: '0' * 64,
      );
      final wrongSize = ArtifactRef(
        ownerId: ownerA,
        artifactId: ref.artifactId,
        byteLength: ref.byteLength + 1,
        sha256: ref.sha256,
      );
      await expectError(() => s.readArtifact(wrongHash), {
        MaterialErrorCode.artifactCorrupt,
      });
      await expectError(() => s.readArtifact(wrongSize), {
        MaterialErrorCode.artifactCorrupt,
      });
    }),
  );

  await tests.run(
    'Corrupt primary recovers explicit previous checkpoint from backup',
    () => using((lab) async {
      final s = await lab.open();
      final first = await checkpoint(s);
      await lab.close(s);
      expectThat(
        await lab.backup().exists(),
        'prior checkpoint must exist for recovery',
      );
      await lab.manifest().writeAsString('{"schema":', flush: true);
      final restored = await lab.open();
      final got = await restored.readDraft(first.materialId);
      expectThat(
        restored.recoveryReport.status == RecoveryStatus.recoveredFromBackup &&
            got.text == story &&
            got.revision == 1,
        'fallback must expose recovery and preserve known backup checkpoint',
      );
    }),
  );

  await tests.run(
    'Missing primary with valid backup cannot initialize an empty store',
    () => using((lab) async {
      final s = await lab.open();
      final first = await checkpoint(s);
      await lab.close(s);
      await lab.manifest().delete();
      final restored = await lab.open();
      expectThat(
        restored.recoveryReport.status == RecoveryStatus.recoveredFromBackup &&
            (await restored.readDraft(first.materialId)).text == story,
        'backup is evidence of existing store, not a new empty root',
      );
    }),
  );

  await tests.run(
    'Primary checksum mismatch is not accepted as current data',
    () => using((lab) async {
      final s = await lab.open();
      final first = await checkpoint(s);
      await lab.close(s);
      final manifest = jsonDecode(
        await lab.manifest().readAsString(),
      ) as Map<String, dynamic>;
      manifest['sha256'] = '0' * 64;
      await lab.manifest().writeAsString(jsonEncode(manifest), flush: true);
      final restored = await lab.open();
      expectThat(
        restored.recoveryReport.status == RecoveryStatus.recoveredFromBackup &&
            (await restored.readDraft(first.materialId)).revision == 1,
        'checksum-corrupt latest payload cannot be trusted',
      );
    }),
  );

  await tests.run(
    'Corrupt primary and backup fail explicitly instead of returning empty success',
    () => using((lab) async {
      final s = await lab.open();
      await checkpoint(s);
      await lab.close(s);
      await lab.manifest().writeAsString('{', flush: true);
      await lab.backup().writeAsString('broken', flush: true);
      final error = await expectError(() => lab.open(), {
        MaterialErrorCode.corruptStore,
      });
      expectThat(
        error.recoveryReport?.status == RecoveryStatus.unrecoverable,
        'irrecoverable index must carry a failure report',
      );
    }),
  );

  await tests.run(
    'Valid primary survives corrupt backup with visible recovery issue',
    () => using((lab) async {
      final s = await lab.open();
      final first = await checkpoint(s);
      await lab.close(s);
      await lab.backup().writeAsString('broken', flush: true);
      final restored = await lab.open();
      expectThat(
        (await restored.readDraft(first.materialId)).revision == 2,
        'good primary remains authoritative',
      );
      expectThat(
        restored.recoveryReport.issues.any(
          (i) => i.kind == RecoveryIssueKind.backupCorrupt,
        ),
        'damaged backup cannot be silently called healthy',
      );
    }),
  );

  await tests.run(
    'Truncated staged write cannot replace valid primary',
    () => using((lab) async {
      final s = await lab.open();
      final first = await checkpoint(s);
      await lab.close(s);
      await lab.pending().writeAsString('{"partial":', flush: true);
      final restored = await lab.open();
      expectThat(
        (await restored.readDraft(first.materialId)).revision == 2,
        'uncommitted truncated next cannot overwrite current',
      );
      expectThat(
        restored.recoveryReport.issues.any(
          (i) => i.kind == RecoveryIssueKind.pendingWrite,
        ),
        'partial-write evidence must be visible',
      );
    }),
  );

  await tests.run(
    'Nonempty artifact store without either index is not fresh initialization',
    () => using((lab) async {
      final s = await lab.open();
      final ref = await s.importArtifact(binary);
      await s.createDraft(title: 'Synthetic lost indexes', artifacts: [ref]);
      await lab.close(s);
      await lab.manifest().delete();
      if (await lab.backup().exists()) await lab.backup().delete();
      await expectError(() => lab.open(), {MaterialErrorCode.corruptStore});
    }),
  );

  await tests.run(
    'Failed staged-file write leaves memory and reopened revision unchanged',
    () => using((lab) async {
      final s = await lab.open();
      final d = await s.createDraft(
        title: 'Synthetic write failure',
        text: story,
      );
      final obstacle = Directory(lab.pending().path);
      await obstacle.create();
      await expectError(
        () => s.updateDraft(
          materialId: d.materialId,
          expectedRevision: 1,
          text: 'must not commit',
        ),
        {MaterialErrorCode.writeFailed},
      );
      expectThat(
        (await s.readDraft(d.materialId)).revision == 1 &&
            (await s.readDraft(d.materialId)).text == story,
        'failed write must not expose uncommitted memory',
      );
      await obstacle.delete();
      await lab.close(s);
      final restored = await lab.open();
      expectThat(
        (await restored.readDraft(d.materialId)).revision == 1,
        'reopen sees last successful revision',
      );
    }),
  );

  await tests.run(
    'Material/version/artifact traversal inputs cannot escape root',
    () => using((lab) async {
      final sentinel = File(
        '${lab.sandbox.path}${Platform.pathSeparator}outside-sentinel.txt',
      );
      await sentinel.writeAsString('synthetic sentinel', flush: true);
      final s = await lab.open();
      await expectError(() => s.readDraft('../outside-sentinel.txt'), {
        MaterialErrorCode.invalidId,
      });
      await expectError(() => s.readVersion('../../outside-sentinel.txt'), {
        MaterialErrorCode.invalidId,
      });
      final forged = ArtifactRef(
        ownerId: ownerA,
        artifactId: '../../../outside-sentinel.txt',
        byteLength: 18,
        sha256: '0' * 64,
      );
      await expectError(() => s.readArtifact(forged), {
        MaterialErrorCode.invalidId,
      });
      expectThat(
        await sentinel.readAsString() == 'synthetic sentinel',
        'outside fixture must remain unchanged',
      );
    }),
  );

  await tests.run(
    'Manifest artifact traversal is rejected even with a recomputed envelope digest',
    () => using((lab) async {
      final s = await lab.open();
      final ref = await s.importArtifact(binary);
      await s.createDraft(title: 'Synthetic tampered index', artifacts: [ref]);
      await lab.close(s);
      await replaceInEnvelope(
        lab.manifest(),
        ref.artifactId,
        '../../../outside',
      );
      await lab.backup().writeAsString('invalid backup', flush: true);
      await expectError(() => lab.open(), {MaterialErrorCode.corruptStore});
    }),
  );

  await tests.run(
    'Manifest owner substitution is rejected despite a valid checksum',
    () => using((lab) async {
      final s = await lab.open();
      await s.createDraft(title: 'Synthetic owner check', text: story);
      await lab.close(s);
      await replaceInEnvelope(lab.manifest(), ownerA, ownerB);
      await lab.backup().writeAsString('invalid backup', flush: true);
      await expectError(() => lab.open(), {
        MaterialErrorCode.corruptStore,
        MaterialErrorCode.ownerMismatch,
      });
    }),
  );

  await tests.run(
    'Closed repository reports closed, not an empty healthy list',
    () => using((lab) async {
      final s = await lab.open();
      final d = await s.createDraft(title: 'Synthetic closed');
      await lab.close(s);
      await expectError(() => s.listDrafts(), {MaterialErrorCode.closed});
      await expectError(() => s.readDraft(d.materialId), {
        MaterialErrorCode.closed,
      });
      await expectError(() => s.createDraft(title: 'not allowed'), {
        MaterialErrorCode.closed,
      });
      await expectError(() => s.importArtifact(binary), {
        MaterialErrorCode.closed,
      });
    }),
  );
  await tests.run(
    'Opaque owner with traversal-like text stays inside hashed partition',
    () => using((lab) async {
      const owner = '../outside-owner';
      final s = await lab.open(owner);
      final d = await s.createDraft(
        title: 'Synthetic opaque identity',
        text: story,
      );
      expectThat(
        s.trustedOwnerId == owner &&
            (await s.readDraft(d.materialId)).ownerId == owner,
        'opaque trusted identity must not be confused with a filesystem path',
      );
      expectThat(
        await lab.manifest(owner).exists(),
        'owner data belongs to documented hashed partition',
      );
      expectThat(
        !await Directory(
          '${lab.sandbox.path}${Platform.pathSeparator}outside-owner',
        ).exists(),
        'owner text must not escape storage root',
      );
      final a = await lab.open();
      expectThat(
        (await a.listDrafts()).isEmpty,
        'different owner partitions remain isolated',
      );
    }),
  );

  await tests.run(
    'Empty or control-character owner is rejected explicitly',
    () => using((lab) async {
      await expectError(() => lab.open(''), {MaterialErrorCode.invalidOwner});
      await expectError(() => lab.open('synthetic\nowner'), {
        MaterialErrorCode.invalidOwner,
      });
    }),
  );

  await tests.run(
    'Confirmation of the same draft revision is idempotent',
    () => using((lab) async {
      final s = await lab.open();
      final d = await s.createDraft(
        title: 'Synthetic idempotent confirmation',
        text: story,
      );
      final first = await s.confirmVersion(
        materialId: d.materialId,
        expectedRevision: 1,
      );
      final again = await s.confirmVersion(
        materialId: d.materialId,
        expectedRevision: 1,
      );
      expectThat(
        first.versionId == again.versionId &&
            (await s.listVersions(d.materialId)).length == 1,
        'same confirmation must not create duplicate versions',
      );
      expectThat(
        (await s.readDraft(d.materialId)).revision == 1,
        'confirming does not edit the draft',
      );
    }),
  );

  await tests.run(
    'Valid staged file alone is not silently promoted to committed library',
    () => using((lab) async {
      final s = await lab.open();
      await checkpoint(s);
      await lab.close(s);
      await lab.manifest().copy(lab.pending().path);
      await lab.manifest().delete();
      if (await lab.backup().exists()) await lab.backup().delete();
      await expectError(() => lab.open(), {MaterialErrorCode.corruptStore});
    }),
  );
  await tests.run(
    'Chinese text, emoji and line breaks survive immutable version recovery',
    () => using((lab) async {
      const text = '这是自造的中文材料：纸船驶过蓝色湖面。🚀\n第二行\t保留制表符\r\n最后一行';
      const title = '合成材料 · 中文与 English';
      final s = await lab.open();
      final d = await s.createDraft(title: title, text: text);
      final version = await s.confirmVersion(
        materialId: d.materialId,
        expectedRevision: 1,
      );
      await lab.close(s);
      final restored = await lab.open();
      expectThat(
        (await restored.readDraft(d.materialId)).text == text,
        'draft text must preserve every Unicode character and line break',
      );
      final got = await restored.readVersion(version.versionId);
      expectThat(
        got.title == title && got.text == text,
        'confirmed version must recover bilingual text without lossy encoding',
      );
    }),
  );
  tests.finish();
}
