// Portable framework keyboard regressions. This is not a native Windows run or
// the exact DPI/font/viewport reproduction retained in private local evidence.
import 'dart:io';

import 'package:client_shell/client_shell.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'client_shell_test.dart' as fixture;

Finder _key(String name) => find.byKey(Key(name));
String _text(WidgetTester tester, String name) =>
    tester.widget<TextField>(_key(name)).controller!.text;

String _focusedKey() {
  var result = 'unkeyed';
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return result;
  (context as Element).visitAncestorElements((element) {
    final key = element.widget.key;
    if (key is ValueKey<String> &&
        const {
          'draft-title',
          'draft-text',
          'draft-save',
          'draft-confirm',
          'nav-learning',
          'nav-materials',
          'nav-add',
          'nav-share',
          'nav-my',
        }.contains(key.value)) {
      result = key.value;
      return false;
    }
    return true;
  });
  return result;
}

Future<void> _tab(WidgetTester tester, {bool reverse = false}) async {
  if (reverse) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.tab);
  if (reverse) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.pumpAndSettle();
}

void _expectVisibleFocus(WidgetTester tester, String name) {
  expect(_focusedKey(), name);
  expect(FocusManager.instance.highlightMode, FocusHighlightMode.traditional);
  final bounds = FocusManager.instance.primaryFocus!.rect;
  final viewport = tester.getRect(
    find.ancestor(of: _key(name), matching: find.byType(Scrollable)).first,
  );
  expect(bounds.top, greaterThanOrEqualTo(viewport.top - 0.1));
  expect(bounds.bottom, lessThanOrEqualTo(viewport.bottom + 0.1));
}

Future<void> _loadAvailableWindowsFonts(WidgetTester tester) async {
  if (!Platform.isWindows) return;
  final windows = Platform.environment['WINDIR'] ?? 'C:/Windows';
  await tester.runAsync(() async {
    for (final item in [
      ('Segoe UI', 'segoeui.ttf'),
      ('Microsoft YaHei UI', 'msyh.ttc'),
    ]) {
      final source = File('$windows/Fonts/${item.$2}');
      if (!await source.exists()) continue;
      final loader = FontLoader(item.$1)
        ..addFont(source.readAsBytes().then(ByteData.sublistView));
      await loader.load();
    }
  });
}

Future<void> _withShell(
  WidgetTester tester,
  Future<void> Function(fixture.Harness) body,
) async {
  // Exercise the desktop framework key policy on every test host. Only Windows
  // hosts read the optional system fonts above; other hosts claim no native or
  // exact Windows font/geometry verification.
  final previousPlatform = debugDefaultTargetPlatformOverride;
  debugDefaultTargetPlatformOverride = TargetPlatform.windows;
  final harness = (await tester.runAsync(fixture.Harness.create))!;
  try {
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1;
    await _loadAvailableWindowsFonts(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: ShiyuClientTokens.lightTheme(),
        home: ShiyuClientShell(
          materials: harness.materials,
          learning: harness.learning,
          onStartImport: () => throw StateError('No picker in keyboard tests'),
        ),
      ),
    );
    await fixture.drain(tester);
    await tester.tap(_key('nav-add'));
    await tester.pumpAndSettle();
    await body(harness);
  } finally {
    await fixture.unmountAndClose(tester, harness);
    debugDefaultTargetPlatformOverride = previousPlatform;
  }
}

Future<void> _fill(WidgetTester tester) async {
  await tester.enterText(_key('draft-title'), 'Synthetic keyboard draft');
  await tester.enterText(_key('draft-text'), 'Alpha one.');
  await tester.pumpAndSettle();
  expect(_focusedKey(), 'draft-text');
}

void main() {
  testWidgets(
    'editor body Tab reaches visible Save and Shift Tab returns body',
    (tester) async {
      await _withShell(tester, (harness) async {
        await _fill(tester);
        await _tab(tester);
        _expectVisibleFocus(tester, 'draft-save');
        await _tab(tester, reverse: true);
        _expectVisibleFocus(tester, 'draft-text');
        expect((await tester.runAsync(harness.materials.listDrafts))!, isEmpty);
      });
    },
  );

  testWidgets('editor skips disabled actions and can exit to footer', (
    tester,
  ) async {
    await _withShell(tester, (harness) async {
      await tester.enterText(_key('draft-title'), 'Synthetic keyboard draft');
      await tester.tap(_key('draft-text'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('draft-save'), skipOffstage: false),
            )
            .onPressed,
        isNull,
      );
      await _tab(tester, reverse: true);
      expect(_focusedKey(), 'draft-title');
      await _tab(tester);
      expect(_focusedKey(), 'draft-text');
      await _tab(tester);
      expect(_focusedKey(), 'nav-learning');
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        2,
      );
      expect((await tester.runAsync(harness.materials.listDrafts))!, isEmpty);
    });
  });

  testWidgets(
    'enabled Save skips disabled Confirm and footer reverse returns Save',
    (tester) async {
      await _withShell(tester, (harness) async {
        await _fill(tester);
        await _tab(tester);
        _expectVisibleFocus(tester, 'draft-save');
        final confirm = find.byKey(
          const Key('draft-confirm'),
          skipOffstage: false,
        );
        expect(tester.widget<OutlinedButton>(confirm).onPressed, isNull);
        await _tab(tester);
        expect(_focusedKey(), 'nav-learning');
        await _tab(tester, reverse: true);
        _expectVisibleFocus(tester, 'draft-save');
        expect((await tester.runAsync(harness.materials.listDrafts))!, isEmpty);
      });
    },
  );

  testWidgets('multiline Enter contract keeps newline without submitting', (
    tester,
  ) async {
    await _withShell(tester, (harness) async {
      await _fill(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(_focusedKey(), 'draft-text');
      expect(
        tester.testTextInput.setClientArgs!['inputAction'],
        'TextInputAction.newline',
      );
      // A framework key event does not synthesize a platform text edit. Supply
      // that separate text/action boundary instead of claiming native Enter IO.
      tester.testTextInput.enterText('Alpha one.\n');
      await tester.testTextInput.receiveAction(TextInputAction.newline);
      await tester.pumpAndSettle();
      expect(_text(tester, 'draft-text'), 'Alpha one.\n');
      expect(_focusedKey(), 'draft-text');
      expect((await tester.runAsync(harness.materials.listDrafts))!, isEmpty);
    });
  });

  testWidgets(
    'saved editor traverses enabled actions after explicit UI re-entry',
    (tester) async {
      await _withShell(tester, (harness) async {
        await _fill(tester);
        await _tab(tester);
        _expectVisibleFocus(tester, 'draft-save');
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await fixture.drain(tester);
        final drafts = (await tester.runAsync(harness.materials.listDrafts))!;
        expect(drafts, hasLength(1));
        expect(drafts.single.text, 'Alpha one.');
        // This tests saved-form relative order, not the unspecified natural
        // post-save focus or the uninterrupted native Save->Q07 acceptance chain.
        await tester.ensureVisible(_key('draft-text'));
        await tester.tap(_key('draft-text'));
        await tester.pumpAndSettle();
        await _tab(tester);
        _expectVisibleFocus(tester, 'draft-save');
        await _tab(tester);
        _expectVisibleFocus(tester, 'draft-confirm');
        await _tab(tester, reverse: true);
        _expectVisibleFocus(tester, 'draft-save');
        expect(
          (await tester.runAsync(
            () => harness.materials.listVersions(drafts.single.materialId),
          ))!,
          isEmpty,
        );
      });
    },
  );

  testWidgets(
    'back cancel and material-tab roundtrip preserve keyboard input',
    (tester) async {
      await _withShell(tester, (harness) async {
        await _fill(tester);
        await tester.tap(_key('editor-back'));
        await tester.pumpAndSettle();
        expect(find.text('放弃未保存的内容？'), findsOneWidget);
        await tester.tap(find.text('继续编辑'));
        await tester.pumpAndSettle();
        await tester.tap(_key('nav-materials'));
        await fixture.drain(tester);
        await tester.tap(_key('nav-add'));
        await tester.pumpAndSettle();
        expect(_text(tester, 'draft-title'), 'Synthetic keyboard draft');
        expect(_text(tester, 'draft-text'), 'Alpha one.');
        await tester.ensureVisible(_key('draft-text'));
        await tester.tap(_key('draft-text'));
        await tester.pumpAndSettle();
        await _tab(tester);
        _expectVisibleFocus(tester, 'draft-save');
        expect((await tester.runAsync(harness.materials.listDrafts))!, isEmpty);
      });
    },
  );
}
