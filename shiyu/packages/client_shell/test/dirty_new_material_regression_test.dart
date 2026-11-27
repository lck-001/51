import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'client_shell_test.dart' as fixture;

const title = '合成未保存标题';
const body = 'Synthetic unsaved text. This must survive navigation.';

String field(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(Key(key))).controller!.text;

Future<void> enterDirty(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('nav-add')));
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const Key('draft-title')), title);
  await tester.enterText(find.byKey(const Key('draft-text')), body);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('control: nav-add restores dirty editor after materials tab', (
    tester,
  ) async {
    final h = (await tester.runAsync(fixture.Harness.create))!;
    try {
      await fixture.mount(tester, h);
      await enterDirty(tester);
      await tester.tap(find.byKey(const Key('nav-materials')));
      await fixture.drain(tester);
      await tester.tap(find.byKey(const Key('nav-add')));
      await tester.pumpAndSettle();
      expect(field(tester, 'draft-title'), title);
      expect(field(tester, 'draft-text'), body);
      expect((await tester.runAsync(h.materials.listDrafts))!, isEmpty);
    } finally {
      await fixture.unmountAndClose(tester, h);
    }
  });

  for (final existing in [false, true]) {
    testWidgets(
      'dirty materials Add must not silently clear input (existing=$existing)',
      (tester) async {
        final h = (await tester.runAsync(fixture.Harness.create))!;
        try {
          if (existing) {
            await tester.runAsync(
              () => h.materials.createDraft(
                title: '已有合成草稿',
                text: 'Already persisted synthetic content.',
              ),
            );
          }
          await fixture.mount(tester, h);
          await enterDirty(tester);
          await tester.tap(find.byKey(const Key('nav-materials')));
          await fixture.drain(tester);
          final add = existing
              ? find.widgetWithText(TextButton, '添加')
              : find.widgetWithText(FilledButton, '添加自己的材料');
          expect(add, findsOneWidget);
          await tester.tap(add);
          await tester.pumpAndSettle();

          final dialog = find.text('放弃未保存的内容？').evaluate().isNotEmpty;
          final editor = find
              .byKey(const Key('draft-title'))
              .evaluate()
              .isNotEmpty;
          final preserved =
              editor &&
              field(tester, 'draft-title') == title &&
              field(tester, 'draft-text') == body;
          // The test accepts either preserving the current editor or explicit
          // consent through the existing discard dialog, never silent loss.
          print(
            'DIRTY_ADD existing=$existing dialog=$dialog '
            'editor=$editor preserved=$preserved '
            'title=${editor ? field(tester, 'draft-title') : '<not-mounted>'} '
            'body=${editor ? field(tester, 'draft-text') : '<not-mounted>'}',
          );
          expect(
            dialog || preserved,
            isTrue,
            reason:
                'Materials-page Add must protect unsaved title and text; '
                'opening a blank editor without consent loses user input.',
          );
          if (dialog) {
            await tester.tap(find.text('继续编辑'));
            await tester.pumpAndSettle();
            await tester.tap(find.byKey(const Key('nav-add')));
            await tester.pumpAndSettle();
            expect(field(tester, 'draft-title'), title);
            expect(field(tester, 'draft-text'), body);
          }
        } finally {
          await fixture.unmountAndClose(tester, h);
        }
      },
    );
  }
}
