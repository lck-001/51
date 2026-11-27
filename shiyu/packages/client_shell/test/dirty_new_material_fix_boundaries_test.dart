import 'package:client_shell/client_shell.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'client_shell_test.dart' as fixture;
import 'dirty_new_material_regression_test.dart' as regression;

Future<VoidCallback> prepare(WidgetTester tester, fixture.Harness h) async {
  await regression.enterDirty(tester);
  await tester.tap(find.byKey(const Key('nav-materials')));
  await fixture.drain(tester);
  final button = find.widgetWithText(FilledButton, '添加自己的材料');
  return tester.widget<FilledButton>(button).onPressed!;
}

void main() {
  testWidgets(
    'cancel retains saved editing identity and later saves same draft',
    (tester) async {
      final h = (await tester.runAsync(fixture.Harness.create))!;
      final saved = (await tester.runAsync(
        () => h.materials.createDraft(title: 'Saved title', text: 'Saved body'),
      ))!;
      try {
        await fixture.mount(tester, h);
        await tester.tap(find.byKey(const Key('nav-materials')));
        await fixture.drain(tester);
        await tester.tap(find.text('校对草稿'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('draft-title')),
          regression.title,
        );
        await tester.enterText(
          find.byKey(const Key('draft-text')),
          regression.body,
        );
        await tester.tap(find.byKey(const Key('nav-materials')));
        await fixture.drain(tester);
        await tester.tap(find.widgetWithText(TextButton, '添加'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('继续编辑'));
        await tester.pumpAndSettle();
        final before = (await tester.runAsync(
          () => h.materials.readDraft(saved.materialId),
        ))!;
        expect(before.title, 'Saved title');
        expect(before.text, 'Saved body');
        expect(before.revision, saved.revision);
        await tester.tap(find.byKey(const Key('nav-add')));
        await tester.pumpAndSettle();
        expect(regression.field(tester, 'draft-title'), regression.title);
        expect(regression.field(tester, 'draft-text'), regression.body);
        final save = find.byKey(const Key('draft-save'));
        await tester.ensureVisible(save);
        await tester.tap(save);
        await fixture.drain(tester);
        final drafts = (await tester.runAsync(h.materials.listDrafts))!;
        expect(drafts, hasLength(1));
        expect(drafts.single.materialId, saved.materialId);
        expect(drafts.single.title, regression.title);
        expect(drafts.single.text, regression.body);
        expect(drafts.single.revision, saved.revision + 1);
      } finally {
        await fixture.unmountAndClose(tester, h);
      }
    },
  );

  testWidgets(
    'explicit discard clears only unsaved form and persists no draft',
    (tester) async {
      final h = (await tester.runAsync(fixture.Harness.create))!;
      try {
        await fixture.mount(tester, h);
        final action = await prepare(tester, h);
        action();
        await tester.pumpAndSettle();
        expect(find.text('放弃未保存的内容？'), findsOneWidget);
        await tester.tap(find.text('放弃修改'));
        await tester.pumpAndSettle();
        expect(regression.field(tester, 'draft-title'), '');
        expect(regression.field(tester, 'draft-text'), '');
        expect((await tester.runAsync(h.materials.listDrafts))!, isEmpty);
      } finally {
        await fixture.unmountAndClose(tester, h);
      }
    },
  );

  testWidgets(
    'duplicate callback admits one dialog and cancel preserves both inputs',
    (tester) async {
      final h = (await tester.runAsync(fixture.Harness.create))!;
      try {
        await fixture.mount(tester, h);
        final action = await prepare(tester, h);
        action();
        action();
        await tester.pumpAndSettle();
        expect(find.text('放弃未保存的内容？'), findsOneWidget);
        await tester.tap(find.text('继续编辑'));
        await tester.pumpAndSettle();
        expect(find.text('放弃未保存的内容？'), findsNothing);
        await tester.tap(find.byKey(const Key('nav-add')));
        await tester.pumpAndSettle();
        expect(regression.field(tester, 'draft-title'), regression.title);
        expect(regression.field(tester, 'draft-text'), regression.body);
        expect((await tester.runAsync(h.materials.listDrafts))!, isEmpty);
      } finally {
        await fixture.unmountAndClose(tester, h);
      }
    },
  );

  testWidgets('dismissed dialog is not discard permission', (tester) async {
    final h = (await tester.runAsync(fixture.Harness.create))!;
    try {
      await fixture.mount(tester, h);
      final action = await prepare(tester, h);
      action();
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('nav-add')));
      await tester.pumpAndSettle();
      expect(regression.field(tester, 'draft-title'), regression.title);
      expect(regression.field(tester, 'draft-text'), regression.body);
    } finally {
      await fixture.unmountAndClose(tester, h);
    }
  });

  testWidgets(
    'retirement during dialog makes late discard unable to clear form',
    (tester) async {
      final h = (await tester.runAsync(fixture.Harness.create))!;
      final retired = ValueNotifier<bool>(false);
      try {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        await tester.pumpWidget(
          MaterialApp(
            home: ShiyuClientShell(
              materials: h.materials,
              learning: h.learning,
              applicationRetired: retired,
            ),
          ),
        );
        await fixture.drain(tester);
        final action = await prepare(tester, h);
        action();
        await tester.pumpAndSettle();
        retired.value = true;
        await tester.tap(find.text('放弃修改'));
        await tester.pumpAndSettle();
        // Navigate through the same existing callback to observe the preserved
        // controllers. Retirement is never reversed to authorize the operation.
        tester
            .widget<NavigationBar>(find.byType(NavigationBar))
            .onDestinationSelected!(2);
        await tester.pumpAndSettle();
        expect(regression.field(tester, 'draft-title'), regression.title);
        expect(regression.field(tester, 'draft-text'), regression.body);
        expect((await tester.runAsync(h.materials.listDrafts))!, isEmpty);
      } finally {
        await fixture.unmountAndClose(tester, h);
        retired.dispose();
      }
    },
  );
}
