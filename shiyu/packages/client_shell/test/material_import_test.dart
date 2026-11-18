// Independent Widget/real-file-store QA. No native file picker, network, audio
// or host desktop input. Controlled sessions do not prove native extraction.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:client_shell/client_shell.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_core/material_core.dart';
import 'package:material_import/material_import.dart';
import 'package:material_ui/material_ui.dart';

import 'client_shell_test.dart' as real;

class ControlledImport implements MaterialImportSession {
  ControlledImport(this.materials, {this.sessionId = 'independent-import'});
  final MaterialStore materials;
  final previewGate = Completer<MaterialImportPreview?>();
  Completer<List<ArtifactRef>>? artifactGate;
  List<ArtifactRef> refs = [];
  int preparations = 0, cancellations = 0, finishes = 0;
  bool failFinish = false;
  String? savedId;
  @override
  final String sessionId;
  @override
  String get ownerId => materials.trustedOwnerId;
  @override
  Future<MaterialImportPreview?> get preview => previewGate.future;
  void deliver({String title = 'Imported fixture', String text = '合成导入原文。'}) {
    previewGate.complete(MaterialImportPreview(
      sessionId: sessionId, ownerId: ownerId, title: title, text: text,
      warnings: const [MaterialImportWarning.formattingOmitted],
      format: MaterialImportFormat.docx, sourceSha256: '0' * 64,
    ));
  }
  Future<void> registerRefs() async {
    refs = [
      await materials.importArtifact(Uint8List.fromList([1, 2, 3])),
      await materials.importArtifact(Uint8List.fromList(utf8.encode(
          '{"schema":"independent-controlled-fixture","notNativeExtraction":true}'))),
    ];
  }
  @override
  Future<List<ArtifactRef>> prepareArtifacts() async {
    preparations++;
    return artifactGate == null ? refs : artifactGate!.future;
  }
  @override
  Future<void> finish({required String savedMaterialId}) async {
    finishes++;
    savedId = savedMaterialId;
    final actual = await materials.readDraft(savedMaterialId);
    if (refs.any((ref) => !actual.artifacts.any((item) => item.artifactId == ref.artifactId))) {
      throw StateError('Real draft did not contain prepared references');
    }
    if (failFinish) {
      throw const MaterialImportException(MaterialImportErrorCode.readFailed);
    }
  }
  @override
  Future<void> cancel() async { cancellations++; }
}

Future<void> mount(WidgetTester tester, real.Harness h,
    StartMaterialImport start) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(MaterialApp(
    home: ShiyuClientShell(materials: h.materials, learning: h.learning,
                          onStartImport: start),
  ));
  await real.drain(tester);
}

Future<void> tap(WidgetTester tester, String key) async {
  final target = find.byKey(Key(key));
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

String field(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(Key(key))).controller!.text;

Future<void> preview(WidgetTester tester, ControlledImport session) async {
  await tap(tester, 'nav-add');
  await tap(tester, 'import-file');
  session.deliver();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('cancelled replacement import preserves preexisting unsaved text', (tester) async {
    final h = (await tester.runAsync(real.Harness.create))!;
    final session = ControlledImport(h.materials);
    try {
      await mount(tester, h, () => session);
      await tap(tester, 'nav-add');
      await tester.enterText(find.byKey(const Key('draft-title')), 'My unsaved title');
      await tester.enterText(find.byKey(const Key('draft-text')), '原有未保存输入。');
      await tap(tester, 'import-file');
      expect(find.text('放弃未保存的内容？'), findsOneWidget);
      await tester.tap(find.text('放弃修改'));
      await tester.pumpAndSettle();
      session.previewGate.complete(null);
      await tester.pumpAndSettle();
      expect(field(tester, 'draft-title'), 'My unsaved title');
      expect(field(tester, 'draft-text'), '原有未保存输入。');
      final drafts = (await tester.runAsync(h.materials.listDrafts))!;
      expect(drafts, isEmpty);
    } finally {
      await real.unmountAndClose(tester, h);
    }
  });

  testWidgets('save source preparation blocks navigation until actual commit', (tester) async {
    final h = (await tester.runAsync(real.Harness.create))!;
    final session = ControlledImport(h.materials)
      ..artifactGate = Completer<List<ArtifactRef>>();
    try {
      await tester.runAsync(session.registerRefs);
      await mount(tester, h, () => session);
      await preview(tester, session);
      expect((await tester.runAsync(h.materials.listDrafts))!, isEmpty);
      await tap(tester, 'draft-save');
      expect(session.preparations, 1);
      await tap(tester, 'nav-materials');
      expect(find.byKey(const Key('draft-title')), findsOneWidget,
          reason: 'A save transaction must retain the editing page');
      session.artifactGate!.complete(session.refs);
      await real.drain(tester);
      expect(session.finishes, 1);
      final drafts = (await tester.runAsync(h.materials.listDrafts))!;
      expect(drafts.length, 1);
      expect(drafts.single.artifacts.length, 2);
    } finally {
      if (!session.artifactGate!.isCompleted) session.artifactGate!.complete(session.refs);
      await real.unmountAndClose(tester, h);
    }
  });

  testWidgets('finish failure never labels an already saved draft as unsaved', (tester) async {
    final h = (await tester.runAsync(real.Harness.create))!;
    final session = ControlledImport(h.materials)..failFinish = true;
    try {
      await tester.runAsync(session.registerRefs);
      await mount(tester, h, () => session);
      await preview(tester, session);
      await tap(tester, 'draft-save');
      await real.drain(tester);
      expect((await tester.runAsync(h.materials.listDrafts))!.length, 1);
      expect(find.textContaining('草稿已保存，导入来源的收尾尚未确认'), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('import-preview-note')),
          matching: find.textContaining('已保存')), findsOneWidget);
      expect(find.textContaining('尚未保存'), findsNothing,
          reason: 'Pending source cleanup is not an unsaved draft');
      expect(session.finishes, 1);
    } finally {
      await real.unmountAndClose(tester, h);
    }
  });

  testWidgets('import preview correction save confirm and reopen use actual artifacts', (tester) async {
    final h = (await tester.runAsync(real.Harness.create))!;
    final session = ControlledImport(h.materials);
    try {
      await tester.runAsync(session.registerRefs);
      await mount(tester, h, () => session);
      await preview(tester, session);
      expect((await tester.runAsync(h.materials.listDrafts))!, isEmpty);
      expect(find.byKey(const Key('import-preview-note')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('draft-text')));
      await tester.enterText(find.byKey(const Key('draft-text')), '人工校对后的合成原文。');
      await tap(tester, 'draft-save');
      await real.drain(tester);
      expect(session.finishes, 1);
      expect(session.savedId, isNotNull);
      var drafts = (await tester.runAsync(h.materials.listDrafts))!;
      expect(drafts.length, 1);
      expect(drafts.single.text, '人工校对后的合成原文。');
      expect(drafts.single.artifacts.map((item) => item.artifactId),
          orderedEquals(session.refs.map((item) => item.artifactId)));
      await tap(tester, 'draft-confirm');
      await real.drain(tester);
      final versions = (await tester.runAsync(
          () => h.materials.listVersions(drafts.single.materialId)))!;
      expect(versions.length, 1);
      expect(versions.single.text, '人工校对后的合成原文。');
      expect(versions.single.artifacts.length, 2);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(h.reopen);
      await mount(tester, h, () => session);
      await tap(tester, 'nav-materials');
      await real.drain(tester);
      expect(find.text('Imported fixture'), findsOneWidget);
      drafts = (await tester.runAsync(h.materials.listDrafts))!;
      expect(drafts.single.artifacts.length, 2);
      for (final ref in drafts.single.artifacts) {
        expect((await tester.runAsync(() => h.materials.readArtifact(ref)))!, isNotEmpty);
      }
      expect((await tester.runAsync(h.learning.listVersions))!, isEmpty,
          reason: 'Import never manufactures an English learning version');
    } finally {
      await real.unmountAndClose(tester, h);
    }
  });

  testWidgets('cancelled late preview cannot overwrite later manual input', (tester) async {
    final h = (await tester.runAsync(real.Harness.create))!;
    final session = ControlledImport(h.materials);
    try {
      await mount(tester, h, () => session);
      await tap(tester, 'nav-add');
      await tap(tester, 'import-file');
      await tap(tester, 'import-cancel');
      expect(session.cancellations, greaterThanOrEqualTo(1));
      await tester.enterText(find.byKey(const Key('draft-title')), 'Later manual title');
      await tester.enterText(find.byKey(const Key('draft-text')), '后来的手工输入。');
      session.deliver(title: 'Stale document title', text: '过时的导入原文。');
      await tester.pumpAndSettle();
      expect(field(tester, 'draft-title'), 'Later manual title');
      expect(field(tester, 'draft-text'), '后来的手工输入。');
      expect(find.text('Stale document title'), findsNothing);
      expect((await tester.runAsync(h.materials.listDrafts))!, isEmpty);
    } finally {
      await real.unmountAndClose(tester, h);
    }
  });

  testWidgets('an unsaved import preview cannot silently lose its source through reselection', (tester) async {
    final h = (await tester.runAsync(real.Harness.create))!;
    final session = ControlledImport(h.materials);
    var starts = 0;
    try {
      await tester.runAsync(session.registerRefs);
      await mount(tester, h, () { starts++; return session; });
      await preview(tester, session);
      final importButton = tester.widget<OutlinedButton>(
          find.byKey(const Key('import-file')));
      expect(importButton.onPressed, isNull,
          reason: 'Finish or explicitly discard this source before picking another');
      await tap(tester, 'import-file');
      expect(starts, 1);
      expect(session.cancellations, 0);
      expect(field(tester, 'draft-text'), '合成导入原文。');
      await tap(tester, 'draft-save');
      await real.drain(tester);
      final drafts = (await tester.runAsync(h.materials.listDrafts))!;
      expect(drafts.length, 1);
      expect(drafts.single.artifacts.length, 2);
      expect(session.finishes, 1);
    } finally {
      await real.unmountAndClose(tester, h);
    }
  });

  testWidgets('owner replacement during source preparation cannot commit either draft', (tester) async {
    final a = (await tester.runAsync(() => real.Harness.create(owner: 'import-owner-a')))!;
    final b = (await tester.runAsync(() => real.Harness.create(owner: 'import-owner-b')))!;
    final session = ControlledImport(a.materials)
      ..artifactGate = Completer<List<ArtifactRef>>();
    try {
      await tester.runAsync(session.registerRefs);
      await mount(tester, a, () => session);
      await preview(tester, session);
      await tap(tester, 'draft-save');
      expect(session.preparations, 1);
      await mount(tester, b, () => ControlledImport(b.materials));
      session.artifactGate!.complete(session.refs);
      await real.drain(tester);
      expect(session.cancellations, greaterThanOrEqualTo(1));
      expect(session.finishes, 0);
      expect((await tester.runAsync(a.materials.listDrafts))!, isEmpty);
      expect((await tester.runAsync(b.materials.listDrafts))!, isEmpty);
      expect(find.text('Imported fixture'), findsNothing);
    } finally {
      if (!session.artifactGate!.isCompleted) session.artifactGate!.complete(session.refs);
      await real.unmountAndClose(tester, b);
      await tester.runAsync(a.close);
    }
  });
}
