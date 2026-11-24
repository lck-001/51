// Author composition regression: actual App barrier above Navigator, real Stores,
// actual production dialogs. No host input/audio/network/configuration changes.
import 'package:agent_bridge/agent_bridge_contracts.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learning_core/learning_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shiyu_playback_probe/client_command_barrier.dart';

import 'package:client_shell/src/assistant_connection_widgets.dart';
import 'package:client_shell/src/candidate_review_sheet.dart';

import '../../../packages/client_shell/test/client_shell_test.dart' as real;
import '../../../packages/client_shell/test/candidate_review_flow_test.dart'
    as fixture;

void main() {
  for (final kind in [
    'authorization',
    'source',
    'declaration',
    'advanced',
    'rejection',
    'discard',
  ]) {
    testWidgets(
      'retired $kind modal blocks pointer and keyboard without Store actions',
      (tester) async {
        final h = (await tester.runAsync(real.Harness.create))!;
        final source = (await tester.runAsync(() => fixture.source(h)))!;
        final receipt = (await tester.runAsync(
          () => fixture.deliver(h, source),
        ))!;
        final frozen = ValueNotifier(false);
        var copies = 0, authorizations = 0;
        tester.view.physicalSize = const Size(375, 667);
        tester.view.devicePixelRatio = 1;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') copies++;
            return null;
          },
        );
        final direct = kind == 'authorization' || kind == 'advanced';
        try {
          await tester.pumpWidget(
            MaterialApp(
              builder: (_, navigator) => ValueListenableBuilder<bool>(
                valueListenable: frozen,
                builder: (_, retired, child) =>
                    ClientCommandBarrier(frozen: retired, child: child!),
                child: navigator,
              ),
              home: Scaffold(
                body: direct
                    ? Builder(
                        builder: (context) => TextButton(
                          child: const Text('Open test surface'),
                          onPressed: () async {
                            if (kind == 'authorization') {
                              final choice = await showAssistantGrantDialog(
                                context,
                                source,
                              );
                              if (!frozen.value && choice != null) {
                                authorizations++;
                              }
                            } else {
                              await showAssistantSetupDialog(
                                context,
                                const AgentBridgeSetup(
                                  descriptorPath: 'synthetic-not-displayed',
                                  configurationToml: 'synthetic-no-secret',
                                  instructions: 'Synthetic advanced fixture',
                                ),
                              );
                            }
                          },
                        ),
                      )
                    : CandidateReviewSheet(
                        candidates: h.learning as LearningCandidateStore,
                        materials: h.materials,
                        candidateId: receipt.candidateId,
                        isCurrentScope: () => !frozen.value,
                      ),
              ),
            ),
          );
          await real.drain(tester);
          late Finder action;
          if (direct) {
            await fixture.tap(tester, find.text('Open test surface'));
            action = find.byKey(
              Key(
                kind == 'authorization'
                    ? 'assistant-authorize-confirm'
                    : 'assistant-copy-setup',
              ),
            );
          } else if (kind == 'source' || kind == 'declaration') {
            await fixture.tap(
              tester,
              find.text(kind == 'source' ? '查看原文' : '来源说明'),
            );
            action = find.text(kind == 'source' ? '返回校对' : '知道了');
          } else if (kind == 'rejection') {
            await fixture.tap(
              tester,
              find.byKey(const Key('candidate-reject')),
            );
            action = find.text('拒绝候选').last;
          } else {
            final english = find.byKey(const Key('candidate-english-0'));
            await tester.ensureVisible(english);
            await tester.enterText(english, 'Unsaved synthetic change.');
            await tester.pump();
            await fixture.tap(tester, find.byKey(const Key('candidate-close')));
            action = find.text('放弃修改');
          }
          expect(action, findsOneWidget);
          final dialogs = find.byType(AlertDialog).evaluate().length;
          // Give the actual button keyboard focus before freezing the whole Navigator.
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          frozen.value = true;
          await tester.pumpAndSettle();
          await tester.tap(action, warnIfMissed: false);
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.sendKeyEvent(LogicalKeyboardKey.space);
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsNWidgets(dialogs));
          expect(copies, 0);
          expect(authorizations, 0);
          final current = (await tester.runAsync(
            () => (h.learning as LearningCandidateStore).readCandidate(
              receipt.candidateId,
            ),
          ))!;
          expect(current.state, LearningCandidateState.pendingReview);
          expect(current.revision, 1);
          expect((await tester.runAsync(h.learning.listVersions))!, isEmpty);
        } finally {
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          );
          await real.unmountAndClose(tester, h);
          frozen.dispose();
        }
      },
    );
  }
}
