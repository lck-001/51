import 'dart:async';
import 'dart:typed_data';

import 'package:client_shell/client_shell.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_core/material_core.dart';
import 'package:material_ui/material_ui.dart';

import 'client_shell_test.dart' as fixture;

class _GatedStore implements MaterialStore {
  _GatedStore(this.inner);
  final MaterialStore inner;
  Completer<void>? saveGate, confirmGate;
  @override
  String get trustedOwnerId => inner.trustedOwnerId;
  @override
  RecoveryReport get recoveryReport => inner.recoveryReport;
  @override
  Future<MaterialDraft> createDraft({
    required String title,
    String text = '',
    Iterable<ArtifactRef> artifacts = const [],
  }) async {
    await saveGate?.future;
    return inner.createDraft(title: title, text: text, artifacts: artifacts);
  }

  @override
  Future<MaterialDraft> updateDraft({
    required String materialId,
    required int expectedRevision,
    String? title,
    String? text,
    Iterable<ArtifactRef>? artifacts,
  }) async {
    await saveGate?.future;
    return inner.updateDraft(
      materialId: materialId,
      expectedRevision: expectedRevision,
      title: title,
      text: text,
      artifacts: artifacts,
    );
  }

  @override
  Future<MaterialVersion> confirmVersion({
    required String materialId,
    required int expectedRevision,
  }) async {
    await confirmGate?.future;
    return inner.confirmVersion(
      materialId: materialId,
      expectedRevision: expectedRevision,
    );
  }

  @override
  Future<MaterialDraft> readDraft(String id) => inner.readDraft(id);
  @override
  Future<List<MaterialDraft>> listDrafts() => inner.listDrafts();
  @override
  Future<MaterialVersion> readVersion(String id) => inner.readVersion(id);
  @override
  Future<List<MaterialVersion>> listVersions(String id) =>
      inner.listVersions(id);
  @override
  Future<ArtifactRef> importArtifact(Uint8List bytes) =>
      inner.importArtifact(bytes);
  @override
  Future<Uint8List> readArtifact(ArtifactRef ref) => inner.readArtifact(ref);
  @override
  Future<void> close() => inner.close();
}

const backKey = Key('editor-back');
String text(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(Key(key))).controller!.text;
Future<void> open(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('nav-add')));
  await tester.pumpAndSettle();
  expect(
    find.byKey(backKey),
    findsOneWidget,
    reason: 'Normal desktop users need a visible editor Back entry.',
  );
  expect(tester.widget<IconButton>(find.byKey(backKey)).tooltip, '返回材料');
}

void main() {
  testWidgets('old Back callback after retirement cannot become root exit', (
    tester,
  ) async {
    final h = (await tester.runAsync(fixture.Harness.create))!;
    final retired = ValueNotifier<bool>(false);
    var roots = 0;
    try {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(
        MaterialApp(
          home: ShiyuClientShell(
            materials: h.materials,
            learning: h.learning,
            applicationRetired: retired,
            onRootBack: () async {
              roots++;
            },
          ),
        ),
      );
      await fixture.drain(tester);
      await open(tester);
      await tester.enterText(
        find.byKey(const Key('draft-text')),
        'Unsaved retirement text',
      );
      final old = tester.widget<IconButton>(find.byKey(backKey)).onPressed!;
      retired.value = true;
      old();
      await tester.pumpAndSettle();
      expect(roots, 0);
      expect(text(tester, 'draft-text'), 'Unsaved retirement text');
      expect(find.text('放弃未保存的内容？'), findsNothing);
    } finally {
      await fixture.unmountAndClose(tester, h);
      retired.dispose();
    }
  });
  testWidgets(
    'old Back callback after owner replacement cannot affect new form',
    (tester) async {
      final a = (await tester.runAsync(fixture.Harness.create))!;
      final b = (await tester.runAsync(
        () => fixture.Harness.create(owner: 'synthetic-other-owner'),
      ))!;
      try {
        await fixture.mount(tester, a);
        await open(tester);
        final old = tester.widget<IconButton>(find.byKey(backKey)).onPressed!;
        await fixture.mount(tester, b);
        await open(tester);
        await tester.enterText(
          find.byKey(const Key('draft-text')),
          'New owner input',
        );
        old();
        await tester.pumpAndSettle();
        expect(text(tester, 'draft-text'), 'New owner input');
        expect(find.text('放弃未保存的内容？'), findsNothing);
      } finally {
        await fixture.unmountAndClose(tester, b);
        await tester.runAsync(a.close);
      }
    },
  );
  testWidgets(
    'Back reentry and old callback on another tab cannot stack dialog',
    (tester) async {
      final h = (await tester.runAsync(fixture.Harness.create))!;
      var roots = 0;
      try {
        await fixture.mount(
          tester,
          h,
          rootBack: () async {
            roots++;
          },
        );
        await open(tester);
        await tester.enterText(
          find.byKey(const Key('draft-text')),
          'Dirty retained text',
        );
        final old = tester.widget<IconButton>(find.byKey(backKey)).onPressed!;
        await tester.tap(find.byKey(backKey));
        old();
        old();
        await tester.pumpAndSettle();
        expect(find.text('放弃未保存的内容？'), findsOneWidget);
        await tester.tap(find.text('继续编辑'));
        await tester.pumpAndSettle();
        for (final key in ['nav-learning', 'nav-share', 'nav-materials']) {
          await tester.tap(find.byKey(Key(key)));
          await fixture.drain(tester);
          final selected = tester
              .widget<NavigationBar>(find.byType(NavigationBar))
              .selectedIndex;
          old();
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<NavigationBar>(find.byType(NavigationBar))
                .selectedIndex,
            selected,
          );
          expect(roots, 0);
          expect(find.text('放弃未保存的内容？'), findsNothing);
        }
        expect(find.text('还没有材料'), findsOneWidget);
        await tester.tap(find.widgetWithText(FilledButton, '添加自己的材料'));
        await tester.pumpAndSettle();
        old();
        await tester.pumpAndSettle();
        expect(find.text('放弃未保存的内容？'), findsOneWidget);
        await tester.tap(find.text('继续编辑'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('nav-add')));
        await tester.pumpAndSettle();
        expect(text(tester, 'draft-text'), 'Dirty retained text');
      } finally {
        await fixture.unmountAndClose(tester, h);
      }
    },
  );
  testWidgets(
    'visible editor Back returns pristine form to materials without root exit',
    (tester) async {
      final h = (await tester.runAsync(fixture.Harness.create))!;
      var rootCalls = 0;
      try {
        await fixture.mount(
          tester,
          h,
          rootBack: () async {
            rootCalls++;
          },
        );
        await open(tester);
        await tester.tap(find.byKey(backKey));
        await fixture.drain(tester);
        expect(find.text('还没有材料'), findsOneWidget);
        expect(find.byKey(backKey), findsNothing);
        expect((await tester.runAsync(h.materials.listDrafts))!, isEmpty);
        expect(rootCalls, 0);
      } finally {
        await fixture.unmountAndClose(tester, h);
      }
    },
  );
  testWidgets('visible Back cancel preserves dirty saved editing identity', (
    tester,
  ) async {
    final h = (await tester.runAsync(fixture.Harness.create))!;
    final original = (await tester.runAsync(
      () => h.materials.createDraft(title: 'Saved title', text: 'Saved body'),
    ))!;
    try {
      await fixture.mount(tester, h);
      await tester.tap(find.byKey(const Key('nav-materials')));
      await fixture.drain(tester);
      await tester.tap(find.text('校对草稿'));
      await tester.pumpAndSettle();
      expect(find.byKey(backKey), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('draft-title')),
        'Dirty title',
      );
      await tester.enterText(find.byKey(const Key('draft-text')), 'Dirty body');
      await tester.tap(find.byKey(backKey));
      await tester.pumpAndSettle();
      expect(find.text('放弃未保存的内容？'), findsOneWidget);
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      expect(text(tester, 'draft-title'), 'Dirty title');
      expect(text(tester, 'draft-text'), 'Dirty body');
      final saved = (await tester.runAsync(
        () => h.materials.readDraft(original.materialId),
      ))!;
      expect(saved.title, 'Saved title');
      expect(saved.text, 'Saved body');
      expect(saved.revision, original.revision);
      final save = find.byKey(const Key('draft-save'));
      await tester.ensureVisible(save);
      await tester.tap(save);
      await fixture.drain(tester);
      final drafts = (await tester.runAsync(h.materials.listDrafts))!;
      expect(drafts, hasLength(1));
      expect(drafts.single.materialId, original.materialId);
      expect(drafts.single.revision, original.revision + 1);
    } finally {
      await fixture.unmountAndClose(tester, h);
    }
  });
  testWidgets(
    'visible Back discard restores saved draft and leaves fixed version unchanged',
    (tester) async {
      final h = (await tester.runAsync(fixture.Harness.create))!;
      final saved = (await tester.runAsync(
        () => h.materials.createDraft(title: 'Saved title', text: 'Saved body'),
      ))!;
      final fixed = (await tester.runAsync(
        () => h.materials.confirmVersion(
          materialId: saved.materialId,
          expectedRevision: saved.revision,
        ),
      ))!;
      try {
        await fixture.mount(tester, h);
        await tester.tap(find.byKey(const Key('nav-materials')));
        await fixture.drain(tester);
        await tester.tap(find.text('校对草稿'));
        await tester.pumpAndSettle();
        expect(find.byKey(backKey), findsOneWidget);
        await tester.enterText(
          find.byKey(const Key('draft-title')),
          'Dirty title',
        );
        await tester.enterText(
          find.byKey(const Key('draft-text')),
          'Dirty body',
        );
        await tester.tap(find.byKey(backKey));
        await tester.pumpAndSettle();
        await tester.tap(find.text('放弃修改'));
        await fixture.drain(tester);
        expect(find.byKey(const Key('material-count')), findsOneWidget);
        final draft = (await tester.runAsync(
          () => h.materials.readDraft(saved.materialId),
        ))!;
        final version = (await tester.runAsync(
          () => h.materials.readVersion(fixed.versionId),
        ))!;
        expect(draft.title, 'Saved title');
        expect(draft.text, 'Saved body');
        expect(draft.revision, saved.revision);
        expect(version.text, 'Saved body');
        expect(version.versionId, fixed.versionId);
        await tester.tap(find.byKey(const Key('nav-add')));
        await tester.pumpAndSettle();
        expect(text(tester, 'draft-title'), 'Saved title');
        expect(text(tester, 'draft-text'), 'Saved body');
      } finally {
        await fixture.unmountAndClose(tester, h);
      }
    },
  );
  for (final confirming in [false, true]) {
    testWidgets(
      'visible Back disabled during ${confirming ? 'confirm' : 'save'} and cannot leave',
      (tester) async {
        final h = (await tester.runAsync(fixture.Harness.create))!;
        final original = (await tester.runAsync(
          () =>
              h.materials.createDraft(title: 'Saved title', text: 'Saved body'),
        ))!;
        final store = _GatedStore(h.materials);
        h.materials = store;
        final gate = Completer<void>();
        try {
          await fixture.mount(tester, h);
          await tester.tap(find.byKey(const Key('nav-materials')));
          await fixture.drain(tester);
          await tester.tap(find.text('校对草稿'));
          await tester.pumpAndSettle();
          expect(find.byKey(backKey), findsOneWidget);
          if (confirming) {
            store.confirmGate = gate;
          } else {
            store.saveGate = gate;
            await tester.enterText(
              find.byKey(const Key('draft-text')),
              'Pending save',
            );
          }
          final action = find.byKey(
            Key(confirming ? 'draft-confirm' : 'draft-save'),
          );
          await tester.ensureVisible(action);
          await tester.tap(action);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          expect(
            tester.widget<IconButton>(find.byKey(backKey)).onPressed,
            isNull,
          );
          await tester.tap(find.byKey(backKey));
          await tester.pump();
          expect(find.byKey(const Key('draft-text')), findsOneWidget);
          expect(find.text('放弃未保存的内容？'), findsNothing);
          gate.complete();
          await fixture.drain(tester);
          expect(
            (await tester.runAsync(
              () => h.materials.readDraft(original.materialId),
            ))!.materialId,
            original.materialId,
          );
        } finally {
          if (!gate.isCompleted) gate.complete();
          await fixture.drain(tester);
          await fixture.unmountAndClose(tester, h);
        }
      },
    );
  }
}
