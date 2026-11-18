// Independent bounded-provenance regression. The synthetic document deliberately
// uses only ~2 KiB main-part name and 1000 short paragraphs: no GB/OOM fixture.
// Actual app controller, worker and FileStore are used; picker is injected.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_core/material_core.dart';
import 'package:material_import/material_import.dart';
import 'package:shiyu_playback_probe/client_material_import.dart';

import '../../../packages/material_import/test/extractor_independent.dart' as fixtures;

void main() {
  test('oversized source-location metadata is rejected before either artifact is registered', () async {
    final temporary = await Directory.systemTemp.createTemp('shiyu-provenance-independent-');
    final storeRoot = Directory('${temporary.path}/store');
    final store = await FileMaterialStore.open(root: storeRoot,
                                              trustedOwnerId: 'provenance-synthetic-owner');
    final mainPart = 'word/${'p' * 2048}/document.xml';
    final xml = fixtures.document(
      '<w:p><w:r><w:t>x</w:t></w:r></w:p>' * 1000,
    );
    final sourceBytes = fixtures.package(xml,
      extra: {mainPart: utf8.encode(xml)},
      contentTypes: fixtures.types.replaceAll('/word/document.xml', '/$mainPart'),
      relationships: fixtures.rels.replaceAll('Target="word/document.xml"',
                                               'Target="$mainPart"'),
    );
    expect(sourceBytes.length, lessThan(100000),
        reason: 'This is a safely scaled compressed fixture, not a memory stress test');
    final original = File('${temporary.path}/long-location.docx');
    await original.writeAsBytes(sourceBytes);
    final originalHash = sha256.convert(sourceBytes).toString();
    final controller = ClientMaterialImportController(
      materials: store,
      stagingRoot: Directory('${temporary.path}/stage'),
      selection: (_) async => original,
    );
    try {
      final session = controller.start();
      final preview = await session.preview;
      expect(preview, isNotNull);
      expect(preview!.text.split('\n').length, 1000);
      expect(await store.listDrafts(), isEmpty);
      await expectLater(session.prepareArtifacts(), throwsA(
        isA<MaterialImportException>().having((error) => error.code, 'code',
            MaterialImportErrorCode.outputTooLarge),
      ));
      expect(await store.listDrafts(), isEmpty);
      final blobs = await storeRoot.list(recursive: true, followLinks: false)
          .where((entry) => entry is File && entry.path.endsWith('.blob')).toList();
      expect(blobs, isEmpty,
          reason: 'Reject before source and sidecar registration, not after a partial write');
      expect(sha256.convert(await original.readAsBytes()).toString(), originalHash);
      await session.cancel();
      expect(await Directory('${temporary.path}/stage').list().toList(), isEmpty);
    } finally {
      await controller.close();
      await store.close();
      final resolved = await temporary.resolveSymbolicLinks();
      final temp = await Directory.systemTemp.resolveSymbolicLinks();
      if (!resolved.startsWith('$temp${Platform.pathSeparator}') ||
          !temporary.uri.pathSegments.where((part) => part.isNotEmpty).last
              .startsWith('shiyu-provenance-independent-')) {
        throw StateError('Refuse cleanup outside owned independent test directory');
      }
      await temporary.delete(recursive: true);
    }
  });

  test('bounded multi-chunk provenance keeps the complete JSON blocks and hashes', () async {
    final temporary = await Directory.systemTemp.createTemp('shiyu-provenance-independent-');
    final storeRoot = Directory('${temporary.path}/store');
    final store = await FileMaterialStore.open(root: storeRoot,
                                              trustedOwnerId: 'provenance-synthetic-owner');
    final mainPart = 'word/${'p' * 2048}/document.xml';
    final xml = fixtures.document(
      '<w:p><w:r><w:t>中文 😀</w:t></w:r></w:p>' * 200,
    );
    final sourceBytes = fixtures.package(xml,
      extra: {mainPart: utf8.encode(xml)},
      contentTypes: fixtures.types.replaceAll('/word/document.xml', '/$mainPart'),
      relationships: fixtures.rels.replaceAll('Target="word/document.xml"',
                                               'Target="$mainPart"'),
    );
    final original = File('${temporary.path}/short 中文😀.docx');
    await original.writeAsBytes(sourceBytes);
    final controller = ClientMaterialImportController(
      materials: store,
      stagingRoot: Directory('${temporary.path}/stage'),
      selection: (_) async => original,
    );
    try {
      final session = controller.start();
      final preview = (await session.preview)!;
      expect(preview.text.split('\n'), List<String>.filled(200, '中文 😀'));
      final refs = await session.prepareArtifacts();
      expect(refs.length, 2);
      expect(refs[1].byteLength, greaterThan(4096 * 4),
          reason: 'Exercise many encoder chunks, not only the tiny happy path');
      expect(refs[1].byteLength, lessThanOrEqualTo(2 * 1024 * 1024));
      expect(await store.readArtifact(refs[0]), sourceBytes);
      final jsonBytes = await store.readArtifact(refs[1]);
      final sidecar = jsonDecode(utf8.decode(jsonBytes)) as Map<String, dynamic>;
      expect(sidecar['source_sha256'], sha256.convert(sourceBytes).toString());
      expect(sidecar['extracted_text_sha256'],
          sha256.convert(utf8.encode(preview.text)).toString());
      expect(sidecar['source_name'], 'short 中文😀.docx');
      final blocks = sidecar['blocks'] as List<dynamic>;
      expect(blocks.length, 200);
      for (var index = 0; index < blocks.length; index++) {
        final block = blocks[index] as Map<String, dynamic>;
        expect(block['ordinal'], index);
        expect(block['part'], mainPart);
        expect(preview.text.substring(block['start'] as int, block['end'] as int),
            '中文 😀');
      }
      final draft = await store.createDraft(title: preview.title,
          text: preview.text, artifacts: refs);
      await session.finish(savedMaterialId: draft.materialId);
      expect(await Directory('${temporary.path}/stage').list().toList(), isEmpty);
      final version = await store.confirmVersion(materialId: draft.materialId,
                                                 expectedRevision: draft.revision);
      expect(version.artifacts.map((ref) => ref.artifactId),
          orderedEquals(refs.map((ref) => ref.artifactId)));
      expect(sha256.convert(await original.readAsBytes()).toString(),
          sha256.convert(sourceBytes).toString());
    } finally {
      await controller.close();
      await store.close();
      final resolved = await temporary.resolveSymbolicLinks();
      final temp = await Directory.systemTemp.resolveSymbolicLinks();
      if (!resolved.startsWith('$temp${Platform.pathSeparator}') ||
          !temporary.uri.pathSegments.where((part) => part.isNotEmpty).last
              .startsWith('shiyu-provenance-independent-')) {
        throw StateError('Refuse cleanup outside owned independent test directory');
      }
      await temporary.delete(recursive: true);
    }
  });
}
