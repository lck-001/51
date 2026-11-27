// Portable framework regressions. Exact Windows font/DPI/native evidence is a
// separate local acceptance artifact; these tests use no system font or SDK path.
import 'dart:async';

import 'package:client_shell/client_shell.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_core/material_core.dart';
import 'package:material_ui/material_ui.dart';

import 'client_shell_test.dart' as fixture;
import 'material_import_test.dart' as imports;
import 'support/editor_io_timing.dart';

Finder _key(String name) => find.byKey(Key(name));
String _focused() {
  var result = 'unkeyed';
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return result;
  (context as Element).visitAncestorElements((element) {
    final k = element.widget.key;
    if (k is ValueKey<String> &&
        const {
          'draft-save',
          'draft-confirm',
          'nav-learning',
          'refresh-data',
        }.contains(k.value)) {
      result = k.value;
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

Rect _viewport() {
  final box =
      Scrollable.of(FocusManager.instance.primaryFocus!.context!).context
              .findRenderObject()!
          as RenderBox;
  return box.localToGlobal(Offset.zero) & box.size;
}

void _visible(String action) {
  expect(_focused(), action);
  final box = FocusManager.instance.primaryFocus!.rect, view = _viewport();
  expect(box.top, greaterThanOrEqualTo(view.top - 0.1));
  expect(box.bottom, lessThanOrEqualTo(view.bottom + 0.1));
}

class _ObservedImport extends imports.ControlledImport {
  _ObservedImport(super.materials, this.phases);
  final IOPhases phases;
  final finished = Completer<void>();
  @override
  Future<List<ArtifactRef>> prepareArtifacts() =>
      phases.zone.run(super.prepareArtifacts);
  @override
  Future<void> finish({required String savedMaterialId}) =>
      phases.zone.run(() async {
        await super.finish(savedMaterialId: savedMaterialId);
        finished.complete();
      });
}

class _Scene {
  _Scene(this.tester, this.h, this.phases)
    : session = imports.ControlledImport(h.materials);
  final WidgetTester tester;
  final fixture.Harness h;
  final IOPhases phases;
  imports.ControlledImport session;
  final retired = ValueNotifier<bool>(false);
  late final materials = TimedMaterialStore(h.materials, phases);
  late final learning = TimedLearningStore(h.learning, phases);

  Widget root() => MaterialApp(
    theme: ShiyuClientTokens.lightTheme(),
    home: ShiyuClientShell(
      materials: materials,
      learning: learning,
      applicationRetired: retired,
      onStartImport: () => session,
    ),
  );
  Future<void> finishIO({_ObservedImport? imported}) async {
    await tester.runAsync(() async {
      phases.saveGate.complete();
    });
    for (final name in IOPhases.names) {
      if (name == 'listDrafts' && imported != null) {
        await tester.runAsync(
          () => imported.finished.future.timeout(const Duration(seconds: 5)),
        );
        await tester.idle();
      }
      await tester.runAsync(
        () => phases.done[name]!.future.timeout(const Duration(seconds: 5)),
      );
      await tester.idle();
    }
    expect(phases.returned, IOPhases.names);
  }

  Future<void> savedScope() async {
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    await finishIO();
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, isA<FocusScopeNode>());
  }

  Future<void> pendingConfirm() async {
    await savedScope();
    for (var i = 0; i < 5; i++) {
      await _tab(tester, reverse: true);
    }
    expect(_focused(), 'nav-learning');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.idle();
    expect(_focused(), 'draft-confirm');
    expect(
      FocusManager.instance.primaryFocus!.rect.bottom,
      greaterThan(_viewport().bottom),
    );
  }

  Future<void> close() async {
    await fixture.unmountAndClose(tester, h);
    retired.dispose();
    debugDefaultTargetPlatformOverride = null;
  }
}

Future<_Scene> _open(WidgetTester tester) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.windows;
  final h = (await tester.runAsync(fixture.Harness.create))!;
  final phases = (await tester.runAsync(() async => IOPhases(Zone.current)))!;
  final scene = _Scene(tester, h, phases);
  tester.view.physicalSize = const Size(900, 600);
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(scene.root());
  await fixture.drain(tester);
  await tester.tap(_key('nav-add'));
  await tester.pumpAndSettle();
  await tester.enterText(_key('draft-title'), 'Synthetic editor draft');
  await tester.enterText(_key('draft-text'), 'Alpha one.');
  await tester.pumpAndSettle();
  await _tab(tester);
  expect(_focused(), 'draft-save');
  await tester.runAsync(() async {
    phases.arm();
  });
  return scene;
}

void main() {
  for (final action in ['draft-confirm', 'draft-save']) {
    testWidgets('selected reverse editor action is fully visible: $action', (
      tester,
    ) async {
      final s = await _open(tester);
      try {
        await s.savedScope();
        for (var i = 0; i < (action == 'draft-confirm' ? 6 : 7); i++) {
          await _tab(tester, reverse: true);
        }
        _visible(action);
      } finally {
        await s.close();
      }
    });
  }
  testWidgets('retained Save node remains visible after saved-status layout', (
    tester,
  ) async {
    final s = await _open(tester);
    try {
      final selected = FocusManager.instance.primaryFocus!;
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await s.finishIO();
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus, same(selected));
      _visible('draft-save');
      final drafts = (await tester.runAsync(s.h.materials.listDrafts))!;
      expect(drafts, hasLength(1));
      expect(drafts.single.text, 'Alpha one.');
      expect(drafts.single.revision, 1);
    } finally {
      await s.close();
    }
  });
  testWidgets('busy save does not reclaim focus the user moved to refresh', (
    tester,
  ) async {
    final s = await _open(tester);
    try {
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      await _tab(tester);
      expect(_focused(), 'refresh-data');
      final moved = FocusManager.instance.primaryFocus!;
      await s.finishIO();
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus, same(moved));
      expect(_focused(), 'refresh-data');
    } finally {
      await s.close();
    }
  });
  for (final change in ['retired', 'view-roundtrip', 'detach']) {
    testWidgets('late editor reveal is cancelled after $change', (
      tester,
    ) async {
      final s = await _open(tester);
      try {
        await s.pendingConfirm();
        final p = Scrollable.of(
              tester.element(
                find.byKey(const Key('draft-confirm'), skipOffstage: false),
              ),
            ).position,
            moves = <double>[];
        p.addListener(() => moves.add(p.pixels));
        if (change == 'retired') {
          s.retired.value = true;
          await tester.pumpAndSettle();
        } else if (change == 'view-roundtrip') {
          final nav = tester.widget<NavigationBar>(find.byType(NavigationBar));
          nav.onDestinationSelected!(1);
          nav.onDestinationSelected!(2);
          await tester.pumpAndSettle();
        } else {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        }
        expect(moves, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await s.close();
      }
    });
  }
  testWidgets(
    'import preview removal preserves the original implicit Save node',
    (tester) async {
      final s = await _open(tester);
      try {
        final imported = (await tester.runAsync(
          () async => _ObservedImport(s.h.materials, s.phases),
        ))!;
        s.session = imported;
        await tester.runAsync(imported.registerRefs);
        await tester.ensureVisible(_key('import-file'));
        await tester.tap(_key('import-file'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('放弃修改'));
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          imported.deliver(title: 'Synthetic editor draft', text: 'Alpha one.');
          await Future<void>.delayed(Duration.zero);
        });
        await tester.idle();
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('import-preview-note'), skipOffstage: false),
          findsOneWidget,
        );
        await tester.ensureVisible(_key('draft-text'));
        await tester.tap(_key('draft-text'));
        await tester.pumpAndSettle();
        await _tab(tester);
        expect(_focused(), 'draft-save');
        final selected = FocusManager.instance.primaryFocus!;
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.idle();
        await s.finishIO(imported: imported);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('import-preview-note'), skipOffstage: false),
          findsNothing,
        );
        expect(FocusManager.instance.primaryFocus, same(selected));
        _visible('draft-save');
        expect(imported.finishes, 1);
        final drafts = (await tester.runAsync(s.h.materials.listDrafts))!;
        expect(drafts, hasLength(1));
        expect(drafts.single.artifacts, hasLength(2));
        expect(drafts.single.revision, 1);
      } finally {
        await s.close();
      }
    },
  );
}
