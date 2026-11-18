import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:client_shell/client_shell.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learning_core/learning_core.dart';
import 'package:material_core/material_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:playback_core/playback_core.dart';

part 'real_io_stores.dart';

const captureKey = Key('synthetic-widget-render');
bool fontsLoaded = false;

final class Harness {
  Harness._(this.root, this.owner);
  final Directory root;
  final String owner;
  late MaterialStore materials;
  late LearningStore learning;
  late Zone _ioZone;
  static Future<Harness> create({
    String owner = 'synthetic-widget-owner',
  }) async {
    final harness = Harness._(
      await Directory.systemTemp.createTemp('shiyu-shell-test-'),
      owner,
    );
    await harness._open();
    return harness;
  }

  Future<void> _open() async {
    _ioZone = Zone.current;
    final material = await FileMaterialStore.open(
      root: Directory('${root.path}/materials'),
      trustedOwnerId: owner,
    );
    materials = _RealIoMaterialStore(material, _ioZone);
    final store = await FileLearningStore.open(
      root: Directory('${root.path}/learning'),
      materials: materials,
    );
    learning = _RealIoLearningStore(store, _ioZone);
  }

  Future<void> reopen() async {
    await learning.close();
    await materials.close();
    await _open();
  }

  Future<void> close() async {
    await learning.close();
    await materials.close();
    final resolved = await root.resolveSymbolicLinks();
    final temp = await Directory.systemTemp.resolveSymbolicLinks();
    if (!resolved.startsWith('$temp${Platform.pathSeparator}') ||
        !root.uri.pathSegments
            .where((part) => part.isNotEmpty)
            .last
            .startsWith('shiyu-shell-test-')) {
      throw StateError('Refusing cleanup outside owned test temp directory');
    }
    await root.delete(recursive: true);
  }

  Future<LearningVersion> ready(
    String title, {
    String first = 'Let me walk you through the plan.',
  }) async {
    final draft = await materials.createDraft(
      title: title,
      text: '合成结构测试原文，不是用户材料。',
    );
    final material = await materials.confirmVersion(
      materialId: draft.materialId,
      expectedRevision: draft.revision,
    );
    final sentences = [
      LearningSentenceInput(english: first, translation: '我来说明一下计划。'),
      const LearningSentenceInput(
        english: 'There are still a few details to work out.',
        translation: '还有一些细节需要确认。',
      ),
      const LearningSentenceInput(
        english: 'Here is what I am planning to do next.',
        translation: '接下来，我打算这样推进。',
      ),
      const LearningSentenceInput(
        english: 'First, I will check a few things with the team.',
        translation: '首先，我会和团队确认几件事。',
      ),
      const LearningSentenceInput(
        english: 'Then we can agree on the next steps.',
        translation: '然后，我们就能商定下一步。',
      ),
      const LearningSentenceInput(
        english: 'We can take it one step at a time.',
        translation: '我们可以一步一步来。',
      ),
    ];
    // Silent in-memory PCM structure fixture only. Never opened in a player.
    final artifact = await materials.importArtifact(_silentWave(3000));
    return learning.createVersion(
      materialVersionId: material.versionId,
      sentences: sentences,
      textProvenance: const ContentProvenance(
        origin: ContentOrigin.synthetic,
        reference: 'widget:synthetic-text',
      ),
      media: LearningMediaInput(
        artifact: artifact,
        provenance: const ContentProvenance(
          origin: ContentOrigin.synthetic,
          reference: 'widget:silent-pcm-not-speech',
        ),
        timings: List.generate(
          sentences.length,
          (i) => SentenceTiming(
            sentenceIndex: i,
            startMs: i * 500,
            endMs: (i + 1) * 500,
          ),
        ),
      ),
    );
  }
}

Uint8List _silentWave(int milliseconds) {
  final samples = milliseconds * 16000 ~/ 1000;
  final bytes = Uint8List(44 + samples * 2);
  final data = ByteData.sublistView(bytes);
  void tag(int offset, String value) =>
      bytes.setRange(offset, offset + value.length, value.codeUnits);
  tag(0, 'RIFF');
  data.setUint32(4, bytes.length - 8, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 16000, Endian.little);
  data.setUint32(28, 32000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  data.setUint32(40, samples * 2, Endian.little);
  return bytes;
}

Future<void> drain(WidgetTester tester) async {
  // File-backed stores do real IO; runAsync releases the test fake clock only.
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  for (
    var i = 0;
    i < 80 && find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
    i++
  ) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(
    find.byType(CircularProgressIndicator),
    findsNothing,
    reason: 'real file IO must settle before pumping virtual animation frames',
  );
  await tester.pumpAndSettle(
    const Duration(milliseconds: 100),
    EnginePhase.sendSemanticsUpdate,
    const Duration(seconds: 3),
  );
}

Future<void> mount(
  WidgetTester tester,
  Harness h, {
  WordLookupCallback? lookup,
  OpenLearningCallback? open,
  ValueListenable<ClientPlaybackView>? playback,
  PlaybackCommandCallback? command,
  PracticeCallback? practice,
  Future<void> Function()? rootBack,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(
    RepaintBoundary(
      key: captureKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ShiyuClientTokens.lightTheme(),
        home: ShiyuClientShell(
          materials: h.materials,
          learning: h.learning,
          onLookupWord: lookup,
          onOpenLearning: open,
          playback: playback,
          onPlaybackCommand: command,
          onPractice: practice,
          onRootBack: rootBack,
        ),
      ),
    ),
  );
  await drain(tester);
}

Future<void> capture(WidgetTester tester, String file) async {
  if (!fontsLoaded) {
    await tester.runAsync(() async {
      for (final item in [
        ('Segoe UI', 'C:/Windows/Fonts/segoeui.ttf'),
        ('Microsoft YaHei UI', 'C:/Windows/Fonts/msyh.ttc'),
        (
          'MaterialIcons',
          Platform.environment['SHIYU_TEST_ICON_FONT'] ?? 'R:/dayline-prototype/.toolchains/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
        ),
      ]) {
        final source = File(item.$2);
        if (await source.exists()) {
          final loader = FontLoader(item.$1)
            ..addFont(source.readAsBytes().then(ByteData.sublistView));
          await loader.load().timeout(const Duration(seconds: 5));
        }
      }
    });
    fontsLoaded = true;
    await tester.pumpAndSettle();
  }
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(captureKey),
    );
    final image = await boundary
        .toImage(pixelRatio: 1)
        .timeout(const Duration(seconds: 5));
    final encoded = await image
        .toByteData(format: ui.ImageByteFormat.png)
        .timeout(const Duration(seconds: 5));
    final output = File('results/$file');
    await output.parent.create(recursive: true);
    await output.writeAsBytes(encoded!.buffer.asUint8List());
    image.dispose();
  });
}

Future<void> unmountAndClose(WidgetTester tester, Harness h) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.runAsync(h.close);
  tester.view.resetPhysicalSize();
  tester.view.resetDevicePixelRatio();
}

void main() {
  testWidgets(
    'navigation, real draft confirmation and store reopen survive Widget disposal',
    (tester) async {
      final h = (await tester.runAsync(Harness.create))!;
      try {
        await mount(tester, h);
        for (final label in ['学习', '材料', '添加', '分享', '我的']) {
          expect(find.text(label), findsWidgets);
        }
        await tester.tap(find.byKey(const Key('nav-add')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('draft-title')),
          '随手记录的想法 · 本机测试',
        );
        await tester.enterText(
          find.byKey(const Key('draft-text')),
          '这是合成原文，只保存草稿，不自动调用翻译或语音服务。',
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const Key('draft-save')));
        await tester.tap(find.byKey(const Key('draft-save')));
        await drain(tester);
        final saved = (await tester.runAsync(h.materials.listDrafts))!;
        expect(saved, hasLength(1));
        expect(saved.single.text, contains('不自动调用'));
        expect(
          (await tester.runAsync(
            () => h.materials.listVersions(saved.single.materialId),
          ))!,
          isEmpty,
        );
        await tester.ensureVisible(find.byKey(const Key('draft-confirm')));
        await tester.tap(find.byKey(const Key('draft-confirm')));
        await drain(tester);
        final versions = (await tester.runAsync(
          () => h.materials.listVersions(saved.single.materialId),
        ))!;
        expect(versions, hasLength(1));
        expect(versions.single.text, saved.single.text);
        expect(find.byKey(const Key('material-count')), findsOneWidget);
        expect(find.textContaining('尚未翻译、生成音频'), findsOneWidget);
        await capture(tester, 'materials-mobile.png');
        await tester.tap(find.byKey(const Key('nav-my')));
        await drain(tester);
        expect(
          tester
              .widget<Text>(find.byKey(const Key('confirmed-version-count')))
              .data,
          '1',
        );
        await tester.tap(find.byKey(const Key('nav-share')));
        await tester.pumpAndSettle();
        expect(find.text('分享还未接入'), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        // Shell disposal must not close app-owned stores.
        expect((await tester.runAsync(h.materials.listDrafts))!, hasLength(1));
        await tester.runAsync(h.reopen);
        await mount(tester, h);
        await tester.tap(find.byKey(const Key('nav-materials')));
        await drain(tester);
        expect(find.text('随手记录的想法 · 本机测试'), findsOneWidget);
      } finally {
        await unmountAndClose(tester, h);
      }
    },
  );

  testWidgets(
    'reader follows v13 ordering and missing provider never invents word entry',
    (tester) async {
      final h = (await tester.runAsync(Harness.create))!;
      final version = (await tester.runAsync(
        () => h.ready('随手记录的想法 · 合成结构示例'),
      ))!;
      try {
        await mount(tester, h);
        await tester.tap(
          find.byKey(
            Key('learning-select-${version.binding.learningVersionId}'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('plan'));
        await tester.pumpAndSettle();
        expect(find.text('词典尚未接入，暂不显示释义或音标。'), findsOneWidget);
        final reader = tester.getRect(find.byKey(const Key('learning-reader')));
        final controls = tester.getRect(
          find.byKey(const Key('playback-controls')),
        );
        final practice = tester.getRect(
          find.byKey(const Key('practice-controls')),
        );
        final card = tester.getRect(find.byKey(const Key('dictionary-card')));
        expect(controls.top, greaterThanOrEqualTo(reader.bottom));
        expect(practice.top, greaterThanOrEqualTo(controls.bottom));
        expect(card.top, greaterThanOrEqualTo(practice.bottom));
        expect(card.height, closeTo(72, .1));
        expect(
          tester
              .widget<IconButton>(find.byKey(const Key('reader-play')))
              .onPressed,
          isNull,
        );
        await capture(tester, 'learning-mobile.png');
        await tester.tap(find.byKey(const Key('dictionary-expand')));
        await tester.pumpAndSettle();
        expect(
          tester.getRect(find.byKey(const Key('dictionary-card'))).height,
          greaterThan(72),
        );
        expect(
          tester.getRect(find.byKey(const Key('dictionary-card'))).top,
          greaterThanOrEqualTo(
            tester.getRect(find.byKey(const Key('practice-controls'))).bottom,
          ),
        );
        await capture(tester, 'learning-word-expanded-mobile.png');
        expect(tester.takeException(), isNull);
      } finally {
        await unmountAndClose(tester, h);
      }
    },
  );

  testWidgets(
    'late word result from learning A cannot overwrite selected learning B',
    (tester) async {
      final h = (await tester.runAsync(Harness.create))!;
      final a = (await tester.runAsync(
        () => h.ready('合成材料 A', first: 'Alpha details.'),
      ))!;
      final b = (await tester.runAsync(
        () => h.ready('合成材料 B', first: 'Beta plan.'),
      ))!;
      final old = Completer<WordLookupResult?>(),
          newer = Completer<WordLookupResult?>();
      final requests = <WordLookupRequest>[];
      try {
        await mount(
          tester,
          h,
          lookup: (request) {
            requests.add(request);
            return request.word == 'Alpha' ? old.future : newer.future;
          },
        );
        await tester.tap(
          find.byKey(Key('learning-select-${a.binding.learningVersionId}')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Alpha'));
        await tester.pump();
        await tester.tap(find.byTooltip('返回学习列表'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(Key('learning-select-${b.binding.learningVersionId}')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Beta'));
        await tester.pump();
        newer.complete(
          const WordLookupResult(
            sourceLabel: '合成测试返回，非实际词典',
            meaning: '测试返回 B',
          ),
        );
        await tester.pumpAndSettle();
        old.complete(
          const WordLookupResult(sourceLabel: '迟到的合成测试返回', meaning: '过期返回 A'),
        );
        await tester.pumpAndSettle();
        expect(requests.map((r) => r.binding.learningVersionId), [
          a.binding.learningVersionId,
          b.binding.learningVersionId,
        ]);
        expect(find.text('测试返回 B'), findsOneWidget);
        expect(find.text('过期返回 A'), findsNothing);
      } finally {
        await unmountAndClose(tester, h);
      }
    },
  );

  testWidgets('late Open failure from A does not mark B failed or auto Play', (
    tester,
  ) async {
    final h = (await tester.runAsync(Harness.create))!;
    final a = (await tester.runAsync(() => h.ready('打开测试 A')))!;
    final b = (await tester.runAsync(() => h.ready('打开测试 B')))!;
    final old = Completer<void>();
    var opens = 0;
    var commands = 0;
    try {
      await mount(
        tester,
        h,
        open: (v) {
          opens++;
          return v.binding.learningVersionId == a.binding.learningVersionId
              ? old.future
              : Future.value();
        },
        command: (v, c) {
          commands++;
          throw StateError('not expected without observed binding');
        },
      );
      await tester.tap(
        find.byKey(Key('learning-select-${a.binding.learningVersionId}')),
      );
      await tester.pump();
      // Selection is now committed only after the app confirms retirement/open.
      // While A is pending the list remains visible, so B can supersede it
      // directly instead of returning from an unconfirmed A reader.
      expect(find.byTooltip('返回学习列表'), findsNothing);
      await tester.tap(
        find.byKey(Key('learning-select-${b.binding.learningVersionId}')),
      );
      await tester.pumpAndSettle();
      old.completeError(StateError('synthetic old open failure'));
      await tester.pumpAndSettle();
      expect(find.text('打开测试 B'), findsOneWidget);
      expect(find.textContaining('打开未确认'), findsNothing);
      expect(find.textContaining('切换未完成'), findsNothing);
      expect(opens, 2);
      expect(commands, 0);
    } finally {
      await unmountAndClose(tester, h);
    }
  });

  testWidgets(
    'changing app-owned stores invalidates pending word response and old owner content',
    (tester) async {
      final a = (await tester.runAsync(
        () => Harness.create(owner: 'owner-a-synthetic'),
      ))!;
      final b = (await tester.runAsync(
        () => Harness.create(owner: 'owner-b-synthetic'),
      ))!;
      final version = (await tester.runAsync(
        () => a.ready('仅 A 所有的合成内容', first: 'Private sample.'),
      ))!;
      final pending = Completer<WordLookupResult?>();
      try {
        await mount(tester, a, lookup: (_) => pending.future);
        await tester.tap(
          find.byKey(
            Key('learning-select-${version.binding.learningVersionId}'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Private'));
        await tester.pump();
        await mount(tester, b);
        pending.complete(
          const WordLookupResult(
            sourceLabel: '合成 A 迟到回执',
            meaning: 'A owner stale entry',
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('仅 A 所有的合成内容'), findsNothing);
        expect(find.text('A owner stale entry'), findsNothing);
        expect(find.text('从自己的材料开始学习'), findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(a.close);
        await tester.runAsync(b.close);
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    },
  );
}
