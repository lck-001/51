// Selection intent must reach the app even when the new learning version has
// no audio. A real file-backed partial version is used, not a fabricated DTO.
import 'package:flutter_test/flutter_test.dart';
import 'package:learning_core/learning_core.dart';
import 'package:material_ui/material_ui.dart';

import 'client_shell_test.dart' as real;

void main() {
  testWidgets('choosing a text-only version invokes app selection rather than silently skipping audio retirement',
      (tester) async {
    final h = (await tester.runAsync(real.Harness.create))!;
    final partial = (await tester.runAsync(() async {
      final draft = await h.materials.createDraft(title: 'Readable candidate B',
                                                  text: '合成固定原文。');
      final fixed = await h.materials.confirmVersion(materialId: draft.materialId,
                                                      expectedRevision: draft.revision);
      return h.learning.createVersion(materialVersionId: fixed.versionId,
        sentences: const [LearningSentenceInput(english: 'A readable version without audio.',
                                                 translation: '没有音频的可阅读内容。')],
        textProvenance: const ContentProvenance(origin: ContentOrigin.synthetic,
                                                 reference: 'fixture:readonly-widget'));
    }))!;
    var selections = 0;
    try {
      expect(partial.state, LearningState.partial);
      await real.mount(tester, h, open: (selected) async {
        expect(selected.binding.learningVersionId, partial.binding.learningVersionId);
        selections++;
      });
      await tester.tap(find.byKey(Key('learning-select-${partial.binding.learningVersionId}')));
      await tester.pumpAndSettle();
      expect(selections, 1,
          reason: 'The app owns retiring previously selected audio even for text-only B');
      expect(find.text('Readable candidate B'), findsOneWidget);
      expect(find.text('without'), findsOneWidget);
      expect(tester.widget<IconButton>(find.byKey(const Key('reader-play'))).onPressed, isNull,
          reason: 'Text-only selection does not invent a playable audio source');
    } finally {
      await real.unmountAndClose(tester, h);
    }
  });
}
