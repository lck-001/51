import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_core/material_core.dart';
import 'package:material_ui/material_ui.dart';

import 'client_shell_test.dart' as fixture;

// Delays only command admission; all content still persists in the real store.
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

void main() {
  var platformExitRequests = 0;
  setUp(() {
    platformExitRequests = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'SystemNavigator.pop') platformExitRequests++;
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('system Back from reader returns to learning list without exit', (
    tester,
  ) async {
    final h = (await tester.runAsync(fixture.Harness.create))!;
    final v = (await tester.runAsync(() => h.ready('系统返回阅读测试')))!;
    var rootBackCalls = 0;
    try {
      await fixture.mount(
        tester,
        h,
        rootBack: () async {
          rootBackCalls++;
        },
      );
      await tester.tap(
        find.byKey(Key('learning-select-${v.binding.learningVersionId}')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('learning-reader')), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        find.byKey(Key('learning-select-${v.binding.learningVersionId}')),
        findsOneWidget,
        reason: 'system Back must leave the reader through internal navigation',
      );
      expect(platformExitRequests, 0);
      expect(rootBackCalls, 0);
      expect((await tester.runAsync(h.learning.listVersions))!, hasLength(1));
    } finally {
      await fixture.unmountAndClose(tester, h);
    }
  });

  testWidgets(
    'dirty edit Back cancel preserves input and discard preserves saved draft',
    (tester) async {
      final h = (await tester.runAsync(fixture.Harness.create))!;
      final original = (await tester.runAsync(
        () => h.materials.createDraft(title: '已存草稿', text: '原来已保存的正文'),
      ))!;
      var rootCalls = 0;
      try {
        await fixture.mount(
          tester,
          h,
          rootBack: () async {
            rootCalls++;
          },
        );
        await tester.tap(find.byKey(const Key('nav-materials')));
        await fixture.drain(tester);
        await tester.tap(find.text('校对草稿'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const Key('draft-text')), '新的尚未保存正文');
        await tester.pumpAndSettle();
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text('放弃未保存的内容？'), findsOneWidget);
        await tester.tap(find.text('继续编辑'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('draft-text')))
              .controller!
              .text,
          '新的尚未保存正文',
        );
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text('放弃未保存的内容？'), findsOneWidget);
        await tester.tap(find.text('放弃修改'));
        await fixture.drain(tester);
        expect(find.byKey(const Key('material-count')), findsOneWidget);
        final saved = (await tester.runAsync(
          () => h.materials.readDraft(original.materialId),
        ))!;
        expect(saved.text, '原来已保存的正文');
        expect(saved.revision, original.revision);
        expect((await tester.runAsync(h.materials.listDrafts))!, hasLength(1));
        await tester.tap(find.text('校对草稿'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('draft-text')))
              .controller!
              .text,
          '原来已保存的正文',
        );
        await tester.enterText(
          find.byKey(const Key('draft-text')),
          '藏在其他页的未保存输入',
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('nav-learning')));
        await fixture.drain(tester);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(
          find.text('放弃未保存的内容？'),
          findsOneWidget,
          reason: 'root exit must protect dirty editor state even after a tab change',
        );
        expect(rootCalls, 0);
        await tester.tap(find.text('继续编辑'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('nav-add')));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('draft-text')))
              .controller!
              .text,
          '藏在其他页的未保存输入',
        );
        expect(
          (await tester.runAsync(
            () => h.materials.readDraft(original.materialId),
          ))!.revision,
          original.revision,
        );
        expect(platformExitRequests, 0);
      } finally {
        await fixture.unmountAndClose(tester, h);
      }
    },
  );

  testWidgets('learning root Back calls owner once while shutdown is pending', (
    tester,
  ) async {
    final h = (await tester.runAsync(fixture.Harness.create))!;
    final closing = Completer<void>();
    var calls = 0;
    try {
      await fixture.mount(
        tester,
        h,
        rootBack: () {
          calls++;
          return closing.future;
        },
      );
      await tester.tap(find.byKey(const Key('nav-add')));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await fixture.drain(tester);
      expect(
        find.text('我的材料'),
        findsOneWidget,
        reason: 'a clean editor returns to materials without requesting exit',
      );
      await tester.tap(find.byKey(const Key('nav-share')));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await fixture.drain(tester);
      expect(find.text('从自己的材料开始学习'), findsOneWidget);
      expect(calls, 0);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        calls,
        1,
        reason: 'repeated system Back must not schedule two owner shutdowns',
      );
      expect(
        platformExitRequests,
        0,
        reason: 'only the app-owned callback may exit after resource cleanup',
      );
      closing.complete();
      await tester.pumpAndSettle();
    } finally {
      if (!closing.isCompleted) closing.complete();
      await fixture.unmountAndClose(tester, h);
    }
  });

  testWidgets(
    'system Back cannot leave or exit during real draft save and confirmation',
    (tester) async {
      final h = (await tester.runAsync(fixture.Harness.create))!;
      final store = _GatedStore(h.materials);
      h.materials = store;
      store.saveGate = Completer<void>();
      store.confirmGate = Completer<void>();
      var rootCalls = 0;
      try {
        await fixture.mount(
          tester,
          h,
          rootBack: () async {
            rootCalls++;
          },
        );
        await tester.tap(find.byKey(const Key('nav-add')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const Key('draft-title')), '在途返回测试');
        await tester.enterText(
          find.byKey(const Key('draft-text')),
          '只有真实保存完成后才确认',
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const Key('draft-save')));
        await tester.tap(find.byKey(const Key('draft-save')));
        await tester.pumpAndSettle();
        expect(find.text('正在保存…'), findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text('正在保存…'), findsOneWidget);
        expect(find.text('放弃未保存的内容？'), findsNothing);
        expect(rootCalls, 0);
        expect(platformExitRequests, 0);
        store.saveGate!.complete();
        await fixture.drain(tester);
        final drafts = (await tester.runAsync(store.listDrafts))!;
        expect(drafts, hasLength(1));
        await tester.ensureVisible(find.byKey(const Key('draft-confirm')));
        await tester.tap(find.byKey(const Key('draft-confirm')));
        await tester.pumpAndSettle();
        expect(find.text('正在确认…'), findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text('正在确认…'), findsOneWidget);
        expect(rootCalls, 0);
        expect(platformExitRequests, 0);
        store.confirmGate!.complete();
        await fixture.drain(tester);
        final versions = (await tester.runAsync(
          () => store.listVersions(drafts.single.materialId),
        ))!;
        expect(versions, hasLength(1));
        expect(versions.single.text, '只有真实保存完成后才确认');
      } finally {
        if (!store.saveGate!.isCompleted) store.saveGate!.complete();
        if (!store.confirmGate!.isCompleted) store.confirmGate!.complete();
        await fixture.unmountAndClose(tester, h);
      }
    },
  );
}
