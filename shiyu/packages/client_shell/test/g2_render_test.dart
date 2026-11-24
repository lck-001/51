// Synthetic widget rendering only; these are not native/device acceptance.
import 'package:client_shell/client_shell.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learning_core/learning_core.dart';
import 'package:material_ui/material_ui.dart';

import '../lib/src/assistant_connection_widgets.dart';
import '../lib/src/candidate_review_sheet.dart';
import 'client_shell_test.dart' as real;
import 'candidate_review_flow_test.dart' as flow;
import 'candidate_media_flow_test.dart' as media;

Future<void> frame(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(375, 667),
  double scale = 1,
  double inset = 0,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(
    RepaintBoundary(
      key: real.captureKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ShiyuClientTokens.lightTheme(),
        builder: (_, child) => MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(scale),
            viewInsets: EdgeInsets.only(bottom: inset),
          ),
          child: child!,
        ),
        home: Scaffold(body: child),
      ),
    ),
  );
  await real.drain(tester);
}

void main() {
  test(
    'normal explanatory token text meets contrast on actual light surfaces',
    () {
      for (final background in [
        ShiyuClientTokens.paper,
        ShiyuClientTokens.hint,
        ShiyuClientTokens.warning,
      ]) {
        final fg = ShiyuClientTokens.muted.computeLuminance(),
            bg = background.computeLuminance();
        final contrast = fg > bg
            ? (fg + .05) / (bg + .05)
            : (bg + .05) / (fg + .05);
        expect(contrast, greaterThanOrEqualTo(4.5));
      }
    },
  );
  testWidgets(
    'long meaning at 200 percent short landscape is readable to its tail inside bounded expanded card',
    (tester) async {
      final h = (await tester.runAsync(real.Harness.create))!;
      final v = (await tester.runAsync(() async {
        final source = await h.ready('合成完整释义原稿');
        return h.learning.createVersion(
          materialVersionId: source.binding.materialVersionId,
          sentences: [
            for (var i = 0; i < 40; i++)
              LearningSentenceInput(
                english:
                    'Let me explain the synthetic plan number $i with the team.',
                translation: '这是用于连续阅读验证的第$i句合成正文。',
              ),
          ],
          textProvenance: const ContentProvenance(
            origin: ContentOrigin.synthetic,
            reference: 'fixture:g2-long-reader',
          ),
        );
      }))!;
      final meaning = '${List.filled(30, '这是合成长释义用于检查').join()}释义结尾标记';
      var playbackCommands = 0;
      try {
        await frame(
          tester,
          ShiyuClientShell(
            materials: h.materials,
            learning: h.learning,
            onOpenLearning: (_) async {},
            onPlaybackCommand: (_, __) async {
              playbackCommands++;
              throw StateError(
                'Dictionary controls must not issue playback commands',
              );
            },
            onLookupWord: (_) async => WordLookupResult(
              sourceLabel: 'Synthetic source tail',
              meaning: meaning,
              example: 'Synthetic example.',
            ),
          ),
          size: const Size(667, 375),
          scale: 2,
        );
        // Stabilize actual fonts before taking any scroll metric.
        await real.capture(tester, 'g2-reader-long-200-initial.png');
        await flow.tap(
          tester,
          find.byKey(Key('learning-select-${v.binding.learningVersionId}')),
        );
        await flow.tap(tester, find.text('Let').first);
        await real.drain(tester);
        final expand = find.byKey(const Key('dictionary-expand'));
        final reader = tester.state<ScrollableState>(
          find
              .descendant(
                of: find.byKey(const Key('learning-reader')),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        final sentenceOffset = reader.position.pixels;
        final firstSentence = find.byKey(
          Key('sentence-${v.sentences.first.sentenceId}'),
        );
        final firstRelativeTop =
            tester.getRect(firstSentence).top -
            tester.getRect(find.byKey(const Key('learning-reader'))).top;
        expect(reader.position.maxScrollExtent, greaterThan(10));
        await flow.tap(tester, expand);
        expect(reader.position.maxScrollExtent, greaterThan(10));
        expect(reader.position.pixels, sentenceOffset);
        expect(tester.takeException(), isNull);
        final scroll = find.byKey(const Key('dictionary-details-scroll'));
        final text = find.byKey(const Key('dictionary-meaning'));
        expect(find.ancestor(of: text, matching: scroll), findsOneWidget);
        expect(tester.widget<Text>(text).data, meaning);
        expect(tester.widget<Text>(text).maxLines, isNull);
        expect(
          tester
              .widget<Semantics>(
                find.byKey(const Key('dictionary-expansion-state')),
              )
              .properties
              .expanded,
          isTrue,
        );
        // The header stays visible after expansion; scroll the outer reader
        // explicitly to inspect the bounded details, as a user can do.
        await tester.ensureVisible(scroll);
        await tester.pumpAndSettle();
        await tester.drag(scroll, const Offset(0, -2000));
        await tester.pumpAndSettle();
        final tail = find.byKey(const Key('dictionary-source'));
        expect(tester.getRect(tail).overlaps(tester.getRect(scroll)), isTrue);
        await real.capture(tester, 'g2-reader-long-200-tail.png');
        await flow.tap(tester, expand);
        expect(
          tester
              .widget<Semantics>(
                find.byKey(const Key('dictionary-expansion-state')),
              )
              .properties
              .expanded,
          isFalse,
        );
        // Do not call ensureVisible here: collapse itself must keep its control
        // visible when the complete compact meaning exceeds the viewport.
        final control = tester.getRect(expand);
        final outerViewport = tester.getRect(
          find
              .ancestor(
                of: expand,
                matching: find.byType(SingleChildScrollView),
              )
              .last,
        );
        expect(
          control.top,
          greaterThanOrEqualTo(outerViewport.top),
          reason: 'collapsed toggle must remain inside the viewport',
        );
        expect(
          control.bottom,
          lessThanOrEqualTo(outerViewport.bottom),
          reason: 'collapsed toggle must remain inside the viewport',
        );
        expect(
          expand.hitTestable(),
          findsOneWidget,
          reason: 'collapsed control must remain reachable without an extra corrective scroll',
        );
        expect(control.width, greaterThanOrEqualTo(48));
        expect(control.height, greaterThanOrEqualTo(48));
        expect(
          reader.position.pixels,
          sentenceOffset,
          reason: 'outer card visibility must preserve the independent sentence scroll',
        );
        expect(reader.position.maxScrollExtent, greaterThan(10));
        expect(
          tester.getRect(firstSentence).top -
              tester.getRect(find.byKey(const Key('learning-reader'))).top,
          firstRelativeTop,
          reason: 'first readable sentence retains its local position',
        );
        expect(playbackCommands, 0);
        expect(tester.takeException(), isNull);
      } finally {
        await real.unmountAndClose(tester, h);
      }
    },
  );

  testWidgets(
    'short reader permits legal clamp when larger text viewport fits every sentence',
    (tester) async {
      final h = (await tester.runAsync(real.Harness.create))!;
      final v = (await tester.runAsync(() => h.ready('合成短正文合法滚动边界')))!;
      var commands = 0;
      try {
        await frame(
          tester,
          ShiyuClientShell(
            materials: h.materials,
            learning: h.learning,
            onOpenLearning: (_) async {},
            onPlaybackCommand: (_, __) async {
              commands++;
              throw StateError('No playback expected');
            },
            onLookupWord: (_) async => WordLookupResult(
              sourceLabel: 'Synthetic short-reader fixture',
              meaning: List.filled(30, '合成长释义仅用于检查').join(),
            ),
          ),
          size: const Size(667, 375),
          scale: 2,
        );
        await real.capture(tester, 'g2-reader-short-200-initial.png');
        await flow.tap(
          tester,
          find.byKey(Key('learning-select-${v.binding.learningVersionId}')),
        );
        await flow.tap(tester, find.text('Let'));
        await real.drain(tester);
        final readerFinder = find.byKey(const Key('learning-reader'));
        final reader = tester.state<ScrollableState>(
          find
              .descendant(of: readerFinder, matching: find.byType(Scrollable))
              .first,
        );
        final prior = reader.position.pixels;
        final expand = find.byKey(const Key('dictionary-expand'));
        await flow.tap(tester, expand);
        expect(
          reader.position.pixels,
          prior.clamp(0.0, reader.position.maxScrollExtent),
        );
        expect(
          reader.position.maxScrollExtent,
          0,
          reason: 'this short fixture actually fits in the enlarged sentence viewport',
        );
        final viewport = tester.getRect(readerFinder);
        for (final sentence in v.sentences) {
          final rect = tester.getRect(
            find.byKey(Key('sentence-${sentence.sentenceId}')),
          );
          expect(rect.top, greaterThanOrEqualTo(viewport.top));
          expect(rect.bottom, lessThanOrEqualTo(viewport.bottom));
        }
        await flow.tap(tester, expand);
        final outer = tester.getRect(
          find
              .ancestor(
                of: expand,
                matching: find.byType(SingleChildScrollView),
              )
              .last,
        );
        final control = tester.getRect(expand);
        expect(control.top, greaterThanOrEqualTo(outer.top));
        expect(control.bottom, lessThanOrEqualTo(outer.bottom));
        expect(expand.hitTestable(), findsOneWidget);
        expect(commands, 0);
        expect(tester.takeException(), isNull);
      } finally {
        await real.unmountAndClose(tester, h);
      }
    },
  );

  testWidgets(
    '375 by 667 large text long material title keeps both draft actions reachable',
    (tester) async {
      final h = (await tester.runAsync(real.Harness.create))!;
      await tester.runAsync(() async {
        final draft = await h.materials.createDraft(
          title: List.filled(6, '合成长材料标题用于大字布局验证').join(),
          text: '合成固定原文。',
        );
        await h.materials.confirmVersion(
          materialId: draft.materialId,
          expectedRevision: draft.revision,
        );
      });
      try {
        await frame(
          tester,
          ShiyuClientShell(
            materials: h.materials,
            learning: h.learning,
            onAuthorizeAssistant: (_) async {},
          ),
          size: const Size(375, 667),
          scale: 2,
        );
        await flow.tap(tester, find.byKey(const Key('nav-materials')));
        expect(tester.takeException(), isNull);
        final edit = find.text('校对草稿'), fixed = find.text('查看固定版本');
        await tester.ensureVisible(edit);
        await tester.pumpAndSettle();
        expect(edit.hitTestable(), findsOneWidget);
        await tester.ensureVisible(fixed);
        await tester.pumpAndSettle();
        expect(fixed.hitTestable(), findsOneWidget);
        final rect = tester.getRect(fixed);
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(375));
        await real.capture(tester, 'g2-material-long-title-200.png');
        await flow.tap(tester, fixed);
        expect(tester.takeException(), isNull);
        final confirmed = find.textContaining('已确认第 1 版');
        if (confirmed.evaluate().isEmpty) {
          await tester.scrollUntilVisible(
            confirmed,
            160,
            scrollable: find
                .descendant(
                  of: find.byType(ListView).last,
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          await tester.pumpAndSettle();
        }
        expect(confirmed, findsOneWidget);
      } finally {
        await real.unmountAndClose(tester, h);
      }
    },
  );

  testWidgets('synthetic grant and Core matched invalidated screenshots', (
    tester,
  ) async {
    final h = (await tester.runAsync(real.Harness.create))!;
    final fixed = (await tester.runAsync(() => flow.source(h)))!;
    final id = (await tester.runAsync(() => media.media(h)))!;
    try {
      await frame(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showAssistantGrantDialog(context, fixed),
            child: const Text('选择固定版授权'),
          ),
        ),
      );
      await flow.tap(tester, find.text('选择固定版授权'));
      await real.capture(tester, 'g2-grant-375.png');
      expect(tester.takeException(), isNull);
      await flow.tap(tester, find.text('取消'));
      Widget sheet() => CandidateReviewSheet(
        candidates: h.learning as LearningCandidateStore,
        materials: h.materials,
        candidateId: id,
        isCurrentScope: () => true,
      );
      await frame(tester, sheet());
      await real.capture(tester, 'g2-matched-375.png');
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        final store = h.learning as LearningCandidateStore;
        final saved = await store.readCandidate(id);
        await store.reviseCandidate(
          candidateId: id,
          expectedRevision: saved.revision,
          sentences: const [
            LearningSentenceInput(
              english: 'Synthetic changed English.',
              translation: '合成英文修改。',
            ),
          ],
        );
      });
      await frame(tester, sheet());
      await real.capture(tester, 'g2-invalidated-375.png');
      expect(find.textContaining('改回原文也不会恢复'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await real.unmountAndClose(tester, h);
    }
  });

  for (final size in [
    const Size(375, 667),
    const Size(667, 375),
    const Size(480, 640),
  ]) {
    testWidgets(
      'reader 200 percent ${size.width} by ${size.height} keeps ordered controls scrollable',
      (tester) async {
        final h = (await tester.runAsync(real.Harness.create))!;
        final v = (await tester.runAsync(() => h.ready('合成阅读与词卡')))!;
        var selections = 0;
        try {
          await frame(
            tester,
            ShiyuClientShell(
              materials: h.materials,
              learning: h.learning,
              onOpenLearning: (_) async {
                selections++;
              },
            ),
            size: size,
            scale: 2,
          );
          await flow.tap(
            tester,
            find.byKey(Key('learning-select-${v.binding.learningVersionId}')),
          );
          expect(tester.takeException(), isNull);
          await tester.ensureVisible(
            find.byKey(const Key('dictionary-expand')),
          );
          await tester.pumpAndSettle();
          expect(
            tester.getSize(find.byKey(const Key('dictionary-expand'))).width,
            greaterThanOrEqualTo(48),
          );
          expect(
            tester.getSize(find.byKey(const Key('dictionary-expand'))).height,
            greaterThanOrEqualTo(48),
          );
          await flow.tap(tester, find.byKey(const Key('dictionary-expand')));
          expect(selections, 1);
          expect(tester.takeException(), isNull);
          await real.capture(
            tester,
            'g2-reader-200-${size.width.toInt()}x${size.height.toInt()}.png',
          );
          expect(tester.takeException(), isNull);
        } finally {
          await real.unmountAndClose(tester, h);
        }
      },
    );
  }
}
