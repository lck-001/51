import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_core/material_core.dart';
import 'package:material_import/material_import.dart';
import 'package:shiyu_playback_probe/client_material_import.dart';

import 'long_provenance_fixture.dart';

void main() {
  late Directory taskRoot;
  late FileMaterialStore store;
  late File original;
  late Directory stage;
  late ClientMaterialImportController controller;
  setUp(() async {
    taskRoot = await Directory.systemTemp.createTemp('shiyu-import-app-');
    store = await FileMaterialStore.open(
      root: Directory('${taskRoot.path}/store'),
      trustedOwnerId: 'test-owner',
    );
    original = File('${taskRoot.path}/original.txt');
    await original.writeAsBytes(
      utf8.encode('你好，团队。\nLet us review the plan. 😀'),
    );
    stage = Directory('${taskRoot.path}/stage');
    controller = ClientMaterialImportController(
      materials: store,
      stagingRoot: stage,
      selection: (_) async => original,
    );
  });
  tearDown(() async {
    try {
      await controller.close();
    } catch (_) {}
    try {
      await store.close();
    } catch (_) {}
    await taskRoot.delete(recursive: true);
  });

  test('real worker preview -> source/sidecar -> existing Store -> reopened version', () async {
    final originalBytes = await original.readAsBytes();
    final session = controller.start();
    final preview = (await session.preview)!;
    expect(preview.ownerId, 'test-owner');
    expect(preview.text, '你好，团队。\nLet us review the plan. 😀');
    expect(await store.listDrafts(), isEmpty);
    final refs = await session.prepareArtifacts();
    expect(refs, hasLength(2));
    expect(await store.readArtifact(refs[0]), originalBytes);
    final sidecar =
        jsonDecode(utf8.decode(await store.readArtifact(refs[1]))) as Map;
    expect(sidecar['source_sha256'], preview.sourceSha256);
    final draft = await store.createDraft(
      title: preview.title,
      text: '${preview.text}\nUser correction.',
      artifacts: refs,
    );
    await session.finish(savedMaterialId: draft.materialId);
    expect(await stage.list().toList(), isEmpty);
    final fixed = await store.confirmVersion(
      materialId: draft.materialId,
      expectedRevision: draft.revision,
    );
    await store.close();
    store = await FileMaterialStore.open(
      root: Directory('${taskRoot.path}/store'),
      trustedOwnerId: 'test-owner',
    );
    final restored = await store.readVersion(fixed.versionId);
    expect(restored.text, endsWith('User correction.'));
    expect(restored.artifacts, hasLength(2));
    expect(await store.readArtifact(restored.artifacts[0]), originalBytes);
    expect(await original.readAsBytes(), originalBytes);
  });

  test('finish verifies real draft refs and cancel does not delete registered orphan', () async {
    final session = controller.start();
    await session.preview;
    final refs = await session.prepareArtifacts();
    final unrelated = await store.createDraft(
      title: 'Unrelated',
      text: 'Unrelated',
    );
    await expectLater(
      session.finish(savedMaterialId: unrelated.materialId),
      throwsA(
        isA<MaterialImportException>().having(
          (e) => e.code,
          'code',
          MaterialImportErrorCode.bindingMismatch,
        ),
      ),
    );
    expect(await stage.list().toList(), isNotEmpty);
    await session.cancel();
    expect(await stage.list().toList(), isEmpty);
    // No fake rollback: the already-registered source remains a private orphan.
    expect(await store.readArtifact(refs[0]), await original.readAsBytes());
    expect((await store.readDraft(unrelated.materialId)).artifacts, isEmpty);
  });

  test(
    'prepare rechecks staged source hash before registering artifacts',
    () async {
      final session = controller.start();
      await session.preview;
      await File('${stage.path}/${session.sessionId}.source')
          .writeAsString('changed');
      await expectLater(
        session.prepareArtifacts(),
        throwsA(
          isA<MaterialImportException>().having(
            (e) => e.code,
            'code',
            MaterialImportErrorCode.bindingMismatch,
          ),
        ),
      );
      expect(await store.listDrafts(), isEmpty);
      await session.cancel();
      expect(await stage.list().toList(), isEmpty);
      expect(await original.readAsString(), contains('review the plan'));
    },
  );

  test('pending picker has a cancel handle, busy gate and late result cannot stage', () async {
    final entered = Completer<void>(), selected = Completer<File?>();
    controller = ClientMaterialImportController(
      materials: store,
      stagingRoot: stage,
      selection: (_) {
        entered.complete();
        return selected.future;
      },
    );
    final session = controller.start();
    await entered.future;
    await expectLater(
      controller.start().preview,
      throwsA(
        isA<MaterialImportException>().having(
          (e) => e.code,
          'code',
          MaterialImportErrorCode.busy,
        ),
      ),
    );
    var cancelled = false;
    final cancellation = session.cancel().then((_) {
      cancelled = true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(cancelled, isFalse);
    selected.complete(original);
    expect(await session.preview, isNull);
    await cancellation;
    expect(cancelled, isTrue);
    expect(await stage.list().toList(), isEmpty);
    expect(await store.listDrafts(), isEmpty);
  });

  test(
    'bounded staging rejects entire oversized source and leaves original alone',
    () async {
      controller = ClientMaterialImportController(
        materials: store,
        stagingRoot: stage,
        selection: (_) async => original,
        limits: const MaterialImportLimits(sourceBytes: 16),
      );
      await expectLater(
        controller.start().preview,
        throwsA(
          isA<MaterialImportException>().having(
            (e) => e.code,
            'code',
            MaterialImportErrorCode.sourceTooLarge,
          ),
        ),
      );
      expect(await store.listDrafts(), isEmpty);
      expect(await stage.list().toList(), isEmpty);
      expect(await original.length(), greaterThan(16));
    },
  );

  test('retired owner never opens another picker', () async {
    var selections = 0;
    controller = ClientMaterialImportController(
      materials: store,
      stagingRoot: stage,
      selection: (_) async {
        selections++;
        return original;
      },
    );
    controller.retire();
    await expectLater(
      controller.start().preview,
      throwsA(
        isA<MaterialImportException>().having(
          (e) => e.code,
          'code',
          MaterialImportErrorCode.sessionClosed,
        ),
      ),
    );
    expect(selections, 0);
    expect(await store.listDrafts(), isEmpty);
  });

  test(
    'pre-existing stage names are never owned, overwritten or deleted',
    () async {
      late File foreignNext, foreignSource;
      controller = ClientMaterialImportController(
        materials: store,
        stagingRoot: stage,
        selection: (id) async {
          foreignNext = File('${stage.path}/$id.next');
          foreignSource = File('${stage.path}/$id.source');
          await foreignNext.writeAsString('other-session-next');
          await foreignSource.writeAsString('other-session-source');
          return original;
        },
      );
      await expectLater(
        controller.start().preview,
        throwsA(isA<MaterialImportException>()),
      );
      expect(await foreignNext.exists(), isTrue);
      expect(await foreignSource.exists(), isTrue);
      expect(await foreignNext.readAsString(), 'other-session-next');
      expect(await foreignSource.readAsString(), 'other-session-source');
      expect(await store.listDrafts(), isEmpty);
    },
  );

  test('failed stage cleanup keeps admission busy and owner close observable until retry', () async {
    await original.writeAsBytes([0xff, 0xff]);
    var denyRemoval = true;
    controller = ClientMaterialImportController(
      materials: store,
      stagingRoot: stage,
      selection: (_) async => original,
      removeStage: (file) async {
        if (denyRemoval) {
          throw FileSystemException('controlled cleanup failure');
        }
        await file.delete();
      },
    );
    await expectLater(
      controller.start().preview,
      throwsA(isA<MaterialImportException>()),
    );
    expect(controller.cleanupPending, isTrue);
    expect(await stage.list().toList(), isNotEmpty);
    await expectLater(
      controller.start().preview,
      throwsA(
        isA<MaterialImportException>().having(
          (e) => e.code,
          'code',
          MaterialImportErrorCode.busy,
        ),
      ),
    );
    await expectLater(
      controller.close(),
      throwsA(isA<MaterialImportException>()),
    );
    expect(controller.cleanupPending, isTrue);
    denyRemoval = false;
    await controller.close();
    expect(controller.cleanupPending, isFalse);
    expect(await stage.list().toList(), isEmpty);
    expect(await original.readAsBytes(), [0xff, 0xff]);
  });

  test('provenance expansion is rejected before registering either artifact', () async {
    final bytes = longProvenanceDocx();
    expect(bytes.length, lessThan(128 * 1024));
    original = File('${taskRoot.path}/long-main-part.docx');
    await original.writeAsBytes(bytes);
    final session = controller.start();
    final preview = (await session.preview)!;
    expect(preview.text, List.filled(1000, 'x').join('\n'));
    await expectLater(
      session.prepareArtifacts().then((refs) async {
        final sidecar = await store.readArtifact(refs[1]);
        // Prints sizes of safe synthetic data only, documenting the pre-fix red.
        stdout.writeln(
          'Safe provenance regression: source=${bytes.length} sidecar=${sidecar.length}',
        );
        return refs;
      }),
      throwsA(
        isA<MaterialImportException>().having(
          (e) => e.code,
          'code',
          MaterialImportErrorCode.outputTooLarge,
        ),
      ),
    );
    final manifests = await Directory('${taskRoot.path}/store')
        .list(recursive: true)
        .where((f) => f is File && f.uri.pathSegments.last == 'manifest.json')
        .toList();
    expect(manifests, hasLength(1));
    final persisted =
        jsonDecode(await File(manifests.single.path).readAsString()) as Map;
    expect((persisted['payload'] as Map)['artifacts'], isEmpty);
    expect(await store.listDrafts(), isEmpty);
    expect(await original.readAsBytes(), bytes);
    await session.cancel();
  });
}
