import 'package:client_shell/client_shell.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learning_core/learning_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:playback_core/playback_core.dart';

import 'client_shell_test.dart' as fixture;

ClientPlaybackView observed(LearningVersion version, int milliseconds) {
  final b = version.binding;
  return ClientPlaybackView(
    learningVersionId: b.learningVersionId,
    snapshot: PlaybackSnapshot(
      item: PlaybackItem(
        ownerId: b.ownerId,
        itemId: b.learningVersionId,
        itemRevision: b.mediaVersionId!,
        kind: MediaKind.audio,
      ),
      token: PlaybackToken(
        ownerId: b.ownerId,
        itemId: b.learningVersionId,
        itemRevision: b.mediaVersionId!,
        generation: 1,
        commandEpoch: 1,
      ),
      intent: PlaybackIntent.paused,
      actual: PlaybackActual.paused,
      pauseCauses: {},
      resources: {},
      requiresFreshPlay: false,
      foreground: true,
      position: Duration(milliseconds: milliseconds),
      duration: const Duration(milliseconds: 3000),
      rate: 1,
      capabilities: const PlaybackCapabilities(seek: true),
      pendingSeek: null,
      error: null,
      hostReady: true,
      captureEpoch: 0,
      seekPositionApplied: true,
      seekFrameReady: false,
    ),
  );
}

void main() {
  testWidgets(
    'restored actual sentence enables previous and successive next advances',
    (tester) async {
      final h = (await tester.runAsync(fixture.Harness.create))!;
      final version = (await tester.runAsync(() => h.ready('实际进度导航')))!;
      final playback = ValueNotifier(
        observed(version, 1200),
      ); // Third sentence.
      final seeks = <int>[];
      try {
        await fixture.mount(
          tester,
          h,
          playback: playback,
          open: (_) async {},
          command: (_, command) async {
            if (command is Seek) seeks.add(command.position.inMilliseconds);
            return CommandResult(
              CommandStatus.accepted,
              token: playback.value.snapshot!.token,
            );
          },
        );
        await tester.tap(
          find.byKey(
            Key('learning-select-${version.binding.learningVersionId}'),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<IconButton>(
                find.byWidgetPredicate(
                  (w) => w is IconButton && w.tooltip == '上一句',
                ),
              )
              .onPressed,
          isNotNull,
          reason: 'restored 1200ms is in sentence three without any dictionary selection',
        );
        await tester.tap(find.byTooltip('上一句'));
        await tester.pumpAndSettle();
        expect(seeks.last, 500);
        await tester.tap(find.byTooltip('下一句'));
        await tester.pumpAndSettle();
        expect(seeks.last, 1500);
        playback.value = observed(version, 1500);
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('下一句'));
        await tester.pumpAndSettle();
        expect(
          seeks.last,
          2000,
          reason:
              'a confirmed next position advances the subsequent next target',
        );
        playback.value = observed(version, 3000);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<IconButton>(
                find.byWidgetPredicate(
                  (w) => w is IconButton && w.tooltip == '下一句',
                ),
              )
              .onPressed,
          isNull,
        );
        await tester.tap(find.byTooltip('上一句'));
        await tester.pumpAndSettle();
        expect(
          seeks.last,
          2000,
          reason: 'end position belongs to the last timed sentence',
        );
      } finally {
        await fixture.unmountAndClose(tester, h);
        playback.dispose();
      }
    },
  );

  testWidgets(
    'dictionary focus and scrub preview do not replace actual playback sentence',
    (tester) async {
      final h = (await tester.runAsync(fixture.Harness.create))!;
      final version = (await tester.runAsync(() => h.ready('查词不改播放句')))!;
      final playback = ValueNotifier(observed(version, 1200));
      final seeks = <int>[];
      final practice = <PracticeRequest>[];
      try {
        await fixture.mount(
          tester,
          h,
          playback: playback,
          open: (_) async {},
          practice: (request) async {
            practice.add(request);
          },
          command: (_, command) async {
            if (command is Seek) seeks.add(command.position.inMilliseconds);
            return CommandResult(
              CommandStatus.accepted,
              token: playback.value.snapshot!.token,
            );
          },
        );
        await tester.tap(
          find.byKey(
            Key('learning-select-${version.binding.learningVersionId}'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('plan'));
        await tester.pumpAndSettle();
        expect(
          seeks,
          isEmpty,
          reason: 'word selection does not request a media seek',
        );
        await tester.tap(find.text('这一句没听懂'));
        await tester.pumpAndSettle();
        expect(
          practice.single.sentence.sentenceId,
          version.sentences[2].sentenceId,
          reason: 'practice follows actual listening sentence rather than dictionary focus',
        );
        await tester.tap(find.byTooltip('下一句'));
        await tester.pumpAndSettle();
        expect(
          seeks.last,
          1500,
          reason: 'dictionary word in sentence one must not redirect next from actual sentence three',
        );
        tester.widget<Slider>(find.byType(Slider)).onChanged!(2500);
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('下一句'));
        await tester.pumpAndSettle();
        expect(
          seeks.last,
          1500,
          reason:
              'uncommitted slider preview does not count as actual progress',
        );
      } finally {
        await fixture.unmountAndClose(tester, h);
        playback.dispose();
      }
    },
  );

  testWidgets(
    'sentence gap and exact boundary have stable navigation; absent timings disable it',
    (tester) async {
      final h = (await tester.runAsync(fixture.Harness.create))!;
      final base = (await tester.runAsync(() => h.ready('时间间隙基线')))!;
      final gap = (await tester.runAsync(
        () => h.learning.createVersion(
          materialVersionId: base.binding.materialVersionId,
          sentences: base.sentences
              .take(3)
              .map(
                (s) => LearningSentenceInput(
                  english: s.english,
                  translation: s.translation,
                ),
              ),
          textProvenance: base.textProvenance,
          media: LearningMediaInput(
            artifact: base.media!.artifact,
            provenance: base.media!.provenance,
            timings: [
              const SentenceTiming(sentenceIndex: 0, startMs: 200, endMs: 400),
              const SentenceTiming(sentenceIndex: 1, startMs: 500, endMs: 800),
              const SentenceTiming(
                sentenceIndex: 2,
                startMs: 1500,
                endMs: 3000,
              ),
            ],
          ),
        ),
      ))!;
      final partial = (await tester.runAsync(
        () => h.learning.createVersion(
          materialVersionId: base.binding.materialVersionId,
          sentences: [
            const LearningSentenceInput(english: 'Untimed supplied sentence.'),
          ],
          textProvenance: base.textProvenance,
        ),
      ))!;
      final playback = ValueNotifier(observed(gap, 1000));
      final seeks = <int>[];
      try {
        await fixture.mount(
          tester,
          h,
          playback: playback,
          open: (_) async {},
          command: (_, command) async {
            if (command is Seek) seeks.add(command.position.inMilliseconds);
            return CommandResult(
              CommandStatus.accepted,
              token: playback.value.snapshot!.token,
            );
          },
        );
        await tester.tap(
          find.byKey(Key('learning-select-${gap.binding.learningVersionId}')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('下一句'));
        await tester.pumpAndSettle();
        expect(
          seeks.last,
          1500,
          reason: 'the gap after sentence two keeps sentence two as navigation context',
        );
        playback.value = observed(gap, 1500);
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('上一句'));
        await tester.pumpAndSettle();
        expect(
          seeks.last,
          500,
          reason: 'the exact third-sentence start belongs to sentence three',
        );
        playback.value = observed(gap, 100);
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('下一句'));
        await tester.pumpAndSettle();
        expect(
          seeks.last,
          500,
          reason: 'before the first timed start uses the first sentence',
        );
        await tester.tap(find.byTooltip('返回学习列表'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(
            Key('learning-select-${partial.binding.learningVersionId}'),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<IconButton>(
                find.byWidgetPredicate(
                  (w) => w is IconButton && w.tooltip == '下一句',
                ),
              )
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<IconButton>(
                find.byWidgetPredicate(
                  (w) => w is IconButton && w.tooltip == '上一句',
                ),
              )
              .onPressed,
          isNull,
        );
      } finally {
        await fixture.unmountAndClose(tester, h);
        playback.dispose();
      }
    },
  );
}
