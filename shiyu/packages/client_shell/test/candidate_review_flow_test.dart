// Real-file UI workflows with controlled app callbacks. No network/OS picker,
// brand account, player, host clipboard or desktop input is exercised here.
import 'package:agent_bridge/agent_bridge_contracts.dart';
import 'package:client_shell/client_shell.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learning_core/learning_core.dart';
import 'package:material_core/material_core.dart';
import 'package:material_ui/material_ui.dart';

import 'client_shell_test.dart' as real;

const originalText = 'OWNER_A_PRIVATE_SOURCE_ONLY';
const originalSha = '7e532c299c1e215643dfd660bc3d7fd8dc76100b2db577e05b862c71d9fc016f';

Future<MaterialVersion> source(real.Harness h) async {
  final draft = await h.materials.createDraft(title: 'UI candidate source', text: originalText);
  return h.materials.confirmVersion(materialId: draft.materialId,
                                     expectedRevision: draft.revision);
}

Future<CandidateDeliveryReceipt> deliver(real.Harness h, MaterialVersion fixed) =>
    (h.learning as LearningCandidateStore).receiveCandidate(
      sender: const CandidateSender(integrationId: 'ui-controlled',
                                     transport: CandidateTransport.controlledTest),
      input: LearningCandidateInput(materialId: fixed.materialId,
        materialVersionId: fixed.versionId, sourceTextSha256: originalSha,
        deliveryId: 'ui-fixed-delivery',
        sentences: const [LearningSentenceInput(english: 'Here is the supplied plan.',
                                                 translation: '这是送入的计划。')],
        declaration: const SourceDeclaration(preparation: 'Controlled unverified fixture',
            provider: 'Unverified fixture provider', model: 'unverified-model-statement')),
    );

Future<void> tap(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> mount(WidgetTester tester, real.Harness h, {
  ValueNotifier<AgentBridgeStatus>? status,
  OpenLearningCallback? open,
  Future<void> Function(AgentBridgeGrantRequest)? authorize,
  Future<void> Function()? revoke,
  Future<AgentBridgeSetup> Function()? setup,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(MaterialApp(home: ShiyuClientShell(
    materials: h.materials, learning: h.learning, onOpenLearning: open,
    assistantStatus: status, onAuthorizeAssistant: authorize,
    onRevokeAssistant: revoke, onAssistantSetup: setup,
  )));
  await real.drain(tester);
}

void main() {
  testWidgets('arrival preserves current reader; correction and confirmation add exactly one external readable version',
      (tester) async {
    final h = (await tester.runAsync(real.Harness.create))!;
    final existing = (await tester.runAsync(() => h.ready('Existing reader A')))!;
    final fixed = (await tester.runAsync(() => source(h)))!;
    final status = ValueNotifier(const AgentBridgeStatus(phase: AgentBridgePhase.disabled));
    var selections = 0;
    try {
      await mount(tester, h, status: status, open: (_) async { selections++; });
      await tap(tester, find.byKey(Key('learning-select-${existing.binding.learningVersionId}')));
      expect(selections, 1);
      final receipt = (await tester.runAsync(() => deliver(h, fixed)))!;
      status.value = AgentBridgeStatus(phase: AgentBridgePhase.enabled,
          materialId: fixed.materialId, materialVersionId: fixed.versionId,
          integrationId: 'ui-controlled', lastCandidateId: receipt.candidateId);
      await real.drain(tester);
      expect(find.text('Existing reader A'), findsOneWidget);
      expect(selections, 1, reason: 'arrival must not navigate or select learning');
      expect((await tester.runAsync(h.learning.listVersions))!.length, 1);
      await tap(tester, find.byTooltip('返回学习列表'));
      final review = find.byKey(Key('candidate-review-${receipt.candidateId}'));
      await tester.ensureVisible(review);
      await tester.tap(review);
      // The sheet opens actual FileStore futures and an indeterminate loading
      // animation. Let real IO progress before settling the virtual clock.
      await real.drain(tester);
      await tap(tester, find.text('来源说明'));
      expect(find.textContaining('模型、版权和语言质量尚未独立核实'), findsOneWidget);
      await tap(tester, find.text('知道了'));
      final english = find.byKey(const Key('candidate-english-0'));
      await tester.ensureVisible(english);
      await tester.enterText(english, 'I will explain the next step.');
      final confirm = find.byKey(const Key('candidate-confirm'));
      await tester.ensureVisible(confirm);
      // Two activations in one frame exercise UI busy admission; Core's durable
      // confirmation idempotence is independently tested across real processes.
      final action = tester.widget<FilledButton>(confirm).onPressed!;
      action(); action();
      await real.drain(tester);
      final candidate = (await tester.runAsync(
          () => (h.learning as LearningCandidateStore).readCandidate(receipt.candidateId)))!;
      expect(candidate.state, LearningCandidateState.confirmed);
      expect(candidate.revision, 2);
      expect(candidate.userEdited, isTrue);
      expect(candidate.originalSentences.single.english, 'Here is the supplied plan.');
      expect(candidate.declaration.model, 'unverified-model-statement');
      var versions = (await tester.runAsync(h.learning.listVersions))!;
      expect(versions.length, 2);
      expect(selections, 1, reason: 'confirmation is not an automatic reading/playback selection');
      expect(find.byKey(const Key('learning-reader')), findsNothing);
      final id = candidate.confirmedLearningVersionId!;
      final learned = versions.singleWhere((v) => v.binding.learningVersionId == id);
      expect(learned.state, LearningState.partial);
      expect(learned.media, isNull);
      expect(learned.textProvenance.origin, ContentOrigin.external);
      await tester.runAsync(() => (h.learning as LearningCandidateStore).confirmCandidate(
          candidateId: receipt.candidateId, expectedRevision: candidate.revision));
      versions = (await tester.runAsync(h.learning.listVersions))!;
      expect(versions.length, 2, reason: 'repeating confirmation does not duplicate the new version');
      await tap(tester, find.byKey(Key('learning-select-$id')));
      expect(selections, 2);
      expect(find.text('外部助手提供'), findsOneWidget);
      expect(find.text('explain'), findsOneWidget);
      expect(tester.widget<IconButton>(find.byKey(const Key('reader-play'))).onPressed, isNull);
    } finally {
      await real.unmountAndClose(tester, h);
      status.dispose();
    }
  });

  testWidgets('receive authorization works with source-read unchecked; setup copies only on an explicit mocked clipboard action',
      (tester) async {
    final h = (await tester.runAsync(real.Harness.create))!;
    final fixed = (await tester.runAsync(() => source(h)))!;
    final status = ValueNotifier(const AgentBridgeStatus(phase: AgentBridgePhase.disabled));
    final requests = <AgentBridgeGrantRequest>[];
    final copied = <String>[];
    var setups = 0;
    const config = '[mcp_servers.controlled_fixture]\ncommand = "fixture-only-not-a-real-tool"\n';
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform,
        (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    try {
      await mount(tester, h, status: status, authorize: (request) async {
        requests.add(request);
        status.value = AgentBridgeStatus(phase: AgentBridgePhase.enabled,
            materialId: fixed.materialId, materialVersionId: request.materialVersionId,
            allowSourceRead: request.allowSourceRead,
            expiresAtUtc: DateTime.now().toUtc().add(const Duration(minutes: 15)));
      }, revoke: () async {
        status.value = const AgentBridgeStatus(phase: AgentBridgePhase.disabled);
      }, setup: () async {
        setups++;
        return const AgentBridgeSetup(descriptorPath: 'PRIVATE_FIXTURE_LOCATOR',
            configurationToml: config, instructions: 'Controlled template; no live settings changed.');
      });
      expect(setups, 0);
      expect(copied, isEmpty);
      await tap(tester, find.byKey(const Key('nav-materials')));
      await tap(tester, find.text('查看固定版本'));
      await tap(tester, find.byKey(Key('assistant-authorize-${fixed.versionId}')));
      expect(tester.widget<CheckboxListTile>(find.byKey(const Key('assistant-allow-source-read')))
          .value, isFalse);
      expect(tester.widget<FilledButton>(find.byKey(const Key('assistant-authorize-confirm')))
          .onPressed, isNotNull);
      await tap(tester, find.byKey(const Key('assistant-authorize-confirm')));
      await real.drain(tester);
      expect(requests.length, 1);
      expect(requests.single.materialVersionId, fixed.versionId);
      expect(requests.single.allowSourceRead, isFalse);
      expect(setups, 0);
      expect(copied, isEmpty);
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await tester.pumpAndSettle();
      await tap(tester, find.byKey(const Key('nav-my')));
      await tap(tester, find.byKey(const Key('assistant-setup')));
      expect(setups, 1);
      expect(copied, isEmpty, reason: 'showing advanced setup never writes the host clipboard');
      expect(tester.widget<SelectableText>(find.byKey(const Key('assistant-setup-configuration')))
          .data, config);
      await tap(tester, find.byKey(const Key('assistant-copy-setup')));
      expect(copied, [config], reason: 'only the explicit action reaches the mocked platform channel');
    } finally {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
      await real.unmountAndClose(tester, h);
      status.dispose();
    }
  });
}
