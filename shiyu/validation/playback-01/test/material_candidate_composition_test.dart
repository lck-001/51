// Controlled headless composition: actual file import/worker, actual private
// bridge socket, actual Shell actions and normal Store reopen. Not native cold
// start, OS picker interaction, model generation, media or brand integration.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_bridge/agent_bridge.dart';
import 'package:client_shell/client_shell.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learning_core/learning_core.dart';
import 'package:material_core/material_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shiyu_playback_probe/client_material_import.dart';

import 'support/composition_fixtures.dart';
import 'support/composition_io.dart';

final class _Composition {
  _Composition(this.root, this.io);
  final Directory root;
  final Zone io;
  LearningRootLock? authority;
  FileMaterialStore? _materials;
  FileLearningStore? _learning;
  FileMaterialStore get materials => _materials!;
  FileLearningStore get learning => _learning!;
  late IoMaterialView materialView;
  late IoLearningView learningView;
  ClientMaterialImportController? imports;
  AgentBridgeController? bridge;
  AgentBridgeClient? sender;
  StreamSubscription<AgentBridgeStatus>? events;
  final status = ValueNotifier<AgentBridgeStatus>(
    const AgentBridgeStatus(phase: AgentBridgePhase.disabled),
  );
  bool storesOpen = false;
  late MaterialVersion oldMaterial;
  late LearningVersion oldLearning;
  late File original;
  late Uint8List originalBytes;
  static Future<_Composition> create(bool docx) async {
    final h = _Composition(
      await Directory.systemTemp.createTemp('shiyu-composition-'),
      Zone.current,
    );
    await h.openStores();
    final old = await h.materials.createDraft(
      title: '既有合成内容',
      text: '原有测试材料，不应被本次流程修改。',
    );
    h.oldMaterial = await h.materials.confirmVersion(
      materialId: old.materialId,
      expectedRevision: old.revision,
    );
    h.oldLearning = await h.learning.createVersion(
      materialVersionId: h.oldMaterial.versionId,
      sentences: const [
        LearningSentenceInput(
          english: 'This older version stays unchanged.',
          translation: '这个旧版本保持不变。',
        ),
      ],
      textProvenance: const ContentProvenance(
        origin: ContentOrigin.synthetic,
        reference: 'composition:existing',
      ),
    );
    h.originalBytes = docx
        ? originalCompositionDocx()
        : originalCompositionText();
    h.original = File('${h.root.path}/original-input.${docx ? 'docx' : 'txt'}');
    await h.original.writeAsBytes(h.originalBytes);
    h.imports = ClientMaterialImportController(
      materials: h.materials,
      stagingRoot: Directory('${h.root.path}/stage'),
      selection: (_) async => h.original,
    );
    h.bridge = AgentBridgeController.attach(
      materials: h.materials,
      candidates: h.learning,
      privateDirectory: Directory('${h.root.path}/bridge'),
      rootLock: h.authority!,
      proxyCommand: [Platform.resolvedExecutable],
    ); // No setup/launch of this test executable.
    h.events = h.bridge!.snapshots.listen((value) => h.status.value = value);
    return h;
  }

  Future<void> openStores() async {
    authority = await LearningRootLock.acquire(root);
    _materials = await FileMaterialStore.open(
      root: Directory('${root.path}/materials'),
      trustedOwnerId: 'composition-owner',
    );
    _learning = await FileLearningStore.open(
      root: Directory('${root.path}/learning'),
      materials: materials,
    );
    storesOpen = true;
    materialView = IoMaterialView(materials, io);
    learningView = IoLearningView(learning, io);
  }

  Future<void> closeStores() async {
    await sender?.close();
    sender = null;
    await imports?.close();
    imports = null;
    await bridge?.close();
    bridge = null;
    await events?.cancel();
    events = null;
    if (storesOpen) {
      await learning.close();
      await materials.close();
      storesOpen = false;
    }
    await authority?.release();
    authority = null;
  }

  Future<void> reopen() async {
    await closeStores();
    await openStores();
  }

  Future<void> destroy() async {
    await closeStores();
    status.dispose();
    final actual = await root.resolveSymbolicLinks(),
        base = await Directory.systemTemp.resolveSymbolicLinks();
    if (!actual.startsWith(
      '$base${Platform.pathSeparator}shiyu-composition-',
    )) {
      throw StateError('Refusing cleanup outside own composition fixture');
    }
    await root.delete(recursive: true);
  }
}

Future<void> settle(WidgetTester tester, bool Function() done) async {
  for (var attempt = 0; attempt < 250; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 30));
    if (done()) {
      await tester.pump(const Duration(milliseconds: 100));
      return;
    }
  }
  fail('Actual composition IO/UI did not reach the expected state');
}

Future<void> tapKey(WidgetTester tester, String key) async {
  final target = find.byKey(Key(key));
  // Finish pending route/caret layout before computing the target hit point.
  await tester.pumpAndSettle(
    const Duration(milliseconds: 30),
    EnginePhase.sendSemanticsUpdate,
    const Duration(seconds: 2),
  );
  await tester.ensureVisible(target);
  await tester.pump();
  await tester.tap(target);
}

void main() {
  for (final docx in [false, true]) {
    testWidgets(
      '${docx ? 'DOCX' : 'TXT'} actual import -> private bridge -> Shell corrections -> partial reader -> Store reopen',
      (tester) async {
        final h = (await tester.runAsync(() => _Composition.create(docx)))!;
        final golden = docx
            ? '$compositionParagraphs\n$compositionTable'
            : compositionParagraphs;
        final correctedSource = docx ? golden : '$golden\n这轮只做文字练习。';
        const receivedEnglish =
            "First, I'll check the requirements and run the tests.";
        const correctedEnglish =
            "First, I'll review the requirements, then run the tests.";
        final retired = ValueNotifier<bool>(false);
        try {
          tester.view.physicalSize = const Size(900, 1200);
          tester.view.devicePixelRatio = 1;
          await tester.pumpWidget(
            MaterialApp(
              theme: ShiyuClientTokens.lightTheme(),
              home: ShiyuClientShell(
                materials: h.materialView,
                learning: h.learningView,
                assistantStatus: h.status,
                applicationRetired: retired,
                onStartImport: () =>
                    IoImportSession(h.io.run(h.imports!.start), h.io),
              ),
            ),
          );
          await settle(
            tester,
            () => find.byType(CircularProgressIndicator).evaluate().isEmpty,
          );
          await tapKey(tester, 'nav-add');
          await tester.pump();
          await tapKey(tester, 'import-file');
          await settle(
            tester,
            () => find.textContaining('文件已在本机提取').evaluate().isNotEmpty,
          );
          await tester.ensureVisible(find.byKey(const Key('draft-text')));
          await tester.pump();
          expect(
            tester
                .widget<TextField>(find.byKey(const Key('draft-text')))
                .controller!
                .text,
            golden,
          );
          expect(
            (await tester.runAsync(h.materials.listDrafts))!,
            hasLength(1),
            reason: 'preview creates no draft',
          );
          await tester.enterText(
            find.byKey(const Key('draft-title')),
            '${docx ? 'DOCX' : 'TXT'}上传原创',
          );
          if (!docx) {
            await tester.enterText(
              find.byKey(const Key('draft-text')),
              correctedSource,
            );
          }
          await tapKey(tester, 'draft-save');
          await settle(
            tester,
            () => find.textContaining('草稿已保存在本机').evaluate().isNotEmpty,
          );
          final drafts = (await tester.runAsync(h.materials.listDrafts))!;
          final imported = drafts.singleWhere(
            (d) => d.materialId != h.oldMaterial.materialId,
          );
          expect(imported.text, correctedSource);
          expect(imported.artifacts, hasLength(2));
          final sourceBytes = (await tester.runAsync(
            () => h.materials.readArtifact(imported.artifacts[0]),
          ))!;
          final sidecarBytes = (await tester.runAsync(
            () => h.materials.readArtifact(imported.artifacts[1]),
          ))!;
          final metadata = jsonDecode(utf8.decode(sidecarBytes)) as Map;
          final extractedHash = sha256.convert(utf8.encode(golden)).toString();
          expect(sourceBytes, h.originalBytes);
          expect(
            metadata['source_sha256'],
            sha256.convert(h.originalBytes).toString(),
          );
          expect(metadata['extracted_text_sha256'], extractedHash);
          expect(metadata['blocks'], isNotEmpty);
          await settle(
            tester,
            () =>
                tester
                    .widget<OutlinedButton>(
                      find.byKey(const Key('draft-confirm')),
                    )
                    .onPressed !=
                null,
          );
          await tapKey(tester, 'draft-confirm');
          await settle(
            tester,
            () => find.textContaining('已确认第 1 版').evaluate().isNotEmpty,
          );
          final source = (await tester.runAsync(
            () => h.materials.listVersions(imported.materialId),
          ))!.single;
          expect(source.text, correctedSource);
          expect(
            source.artifacts.map((r) => r.artifactId),
            imported.artifacts.map((r) => r.artifactId),
          );
          await tester.runAsync(
            () => h.bridge!.authorize(
              AgentBridgeGrantRequest(
                materialVersionId: source.versionId,
                allowSourceRead: true,
              ),
            ),
          );
          h.sender = AgentBridgeClient(
            descriptorPath: '${h.root.path}/bridge/descriptor.json',
          );
          final reference = (await tester.runAsync(
            h.sender!.getSourceReference,
          ))!;
          final actualHash = sha256
              .convert(utf8.encode(correctedSource))
              .toString();
          expect(reference['source_text_sha256'], actualHash);
          final actualText = (await tester.runAsync(
            () => h.sender!.readFixedSource(
              materialId: source.materialId,
              materialVersionId: source.versionId,
              sourceTextSha256: actualHash,
            ),
          ))!;
          expect(actualText['text'], correctedSource);
          Map<String, Object?> packet(String hash) => {
            'schema_version': 1,
            ...reference,
            'source_text_sha256': hash,
            'delivery_id': 'composition-${docx ? 'docx' : 'txt'}',
            'sentences': [
              {'english': receivedEnglish, 'translation': '我会先核对需求，再运行测试。'},
              {
                'english': "If everything looks good, I'll save the changes.",
                'translation': '确认没有问题后，我会保存修改。',
              },
            ],
            'declaration': {'preparation': '原创headless组合测试，不是模型或语音服务生成。'},
          };
          final invalidHashes = docx
              ? [sha256.convert(h.originalBytes).toString()]
              : [extractedHash, sha256.convert(h.originalBytes).toString()];
          for (final wrong in invalidHashes) {
            expect(wrong, isNot(actualHash));
            final error = await tester.runAsync(() async {
              try {
                await h.sender!.submitCandidate(packet(wrong));
                return null;
              } on AgentBridgeException catch (e) {
                return e.code;
              }
            });
            expect(error, AgentBridgeErrorCode.sourceMismatch);
          }
          expect((await tester.runAsync(h.learning.listCandidates))!, isEmpty);
          expect(
            (await tester.runAsync(h.learning.listVersions))!,
            hasLength(1),
            reason: 'only pre-existing learning remains',
          );
          final delivered = (await tester.runAsync(
            () => h.sender!.submitCandidate(packet(actualHash)),
          ))!;
          final replay = (await tester.runAsync(
            () => h.sender!.submitCandidate(packet(actualHash)),
          ))!;
          expect(delivered['status'], 'delivered');
          expect(replay['replayed'], isTrue);
          expect(replay['candidate_id'], delivered['candidate_id']);
          final candidateId = delivered['candidate_id'] as String;
          expect(
            (await tester.runAsync(h.learning.listCandidates))!,
            hasLength(1),
          );
          expect(
            h.learningView.forbiddenUiReceiveCalls,
            0,
            reason: 'no direct receiveCandidate bypass',
          );
          await tapKey(tester, 'nav-learning');
          await settle(
            tester,
            () => find
                .byKey(Key('candidate-review-$candidateId'))
                .evaluate()
                .isNotEmpty,
          );
          await tapKey(tester, 'candidate-review-$candidateId');
          await settle(
            tester,
            () => find
                .byKey(const Key('candidate-english-0'))
                .evaluate()
                .isNotEmpty,
          );
          await tester.enterText(
            find.byKey(const Key('candidate-english-0')),
            correctedEnglish,
          );
          await tapKey(tester, 'candidate-confirm');
          await settle(
            tester,
            () =>
                find.byKey(const Key('candidate-confirm')).evaluate().isEmpty &&
                find.byKey(const Key('candidate-inbox')).evaluate().isEmpty,
          );
          final candidate = (await tester.runAsync(
            () => h.learning.readCandidate(candidateId),
          ))!;
          expect(candidate.state, LearningCandidateState.confirmed);
          expect(candidate.revision, 2);
          expect(candidate.originalSentences.first.english, receivedEnglish);
          expect(candidate.sentences.first.english, correctedEnglish);
          expect(candidate.userEdited, isTrue);
          expect(
            candidate.submission.transport,
            CandidateTransport.localCapability,
          );
          expect(
            candidate.declaration.preparation,
            '原创headless组合测试，不是模型或语音服务生成。',
          );
          final external = (await tester.runAsync(
            () => h.learning.readVersion(candidate.confirmedLearningVersionId!),
          ))!;
          expect(external.state, LearningState.partial);
          expect(external.media, isNull);
          expect(external.textProvenance.origin, ContentOrigin.external);
          expect(external.sentences.first.english, correctedEnglish);
          expect(external.binding.materialVersionId, source.versionId);
          final repeated = (await tester.runAsync(
            () => h.learning.confirmCandidate(
              candidateId: candidateId,
              expectedRevision: 2,
            ),
          ))!;
          expect(
            repeated.binding.learningVersionId,
            external.binding.learningVersionId,
          );
          expect(
            (await tester.runAsync(h.learning.listVersions))!,
            hasLength(2),
          );
          await tapKey(
            tester,
            'learning-select-${external.binding.learningVersionId}',
          );
          await settle(
            tester,
            () =>
                find.byKey(const Key('learning-reader')).evaluate().isNotEmpty,
          );
          expect(find.text('可先阅读文字，音频尚未提供。'), findsOneWidget);
          final englishTokens = find.descendant(
            of: find.descendant(
              of: find.byKey(
                Key('sentence-${external.sentences.first.sentenceId}'),
              ),
              matching: find.byType(Wrap),
            ),
            matching: find.byType(Text),
          );
          expect(
            tester
                .widgetList<Text>(englishTokens)
                .map((word) => word.data!)
                .join(),
            correctedEnglish,
          );
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(h.reopen);
          final restored = (await tester.runAsync(
            () => h.learning.readCandidate(candidateId),
          ))!;
          final stable = (await tester.runAsync(
            () => h.learning.confirmCandidate(
              candidateId: candidateId,
              expectedRevision: 2,
            ),
          ))!;
          expect(
            restored.confirmedLearningVersionId,
            external.binding.learningVersionId,
          );
          expect(
            stable.binding.learningVersionId,
            external.binding.learningVersionId,
          );
          expect(
            (await tester.runAsync(h.learning.listVersions))!,
            hasLength(2),
          );
          final persistedSource = (await tester.runAsync(
            () => h.materials.readVersion(source.versionId),
          ))!;
          expect(persistedSource.text, correctedSource);
          expect(persistedSource.artifacts, hasLength(2));
          expect(
            (await tester.runAsync(
              () => h.materials.readArtifact(persistedSource.artifacts[0]),
            ))!,
            h.originalBytes,
          );
          expect(
            (await tester.runAsync(
              () => h.materials.readArtifact(persistedSource.artifacts[1]),
            ))!,
            sidecarBytes,
          );
          expect(
            (await tester.runAsync(
              () => h.learning.readVersion(
                h.oldLearning.binding.learningVersionId,
              ),
            ))!.sentences.single.english,
            'This older version stays unchanged.',
          );
          expect(
            (await tester.runAsync(
              () => h.materials.readVersion(h.oldMaterial.versionId),
            ))!.text,
            h.oldMaterial.text,
          );
          expect(
            (await tester.runAsync(h.original.readAsBytes))!,
            h.originalBytes,
          );
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(h.destroy);
          retired.dispose();
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        }
      },
      skip: !Platform.isWindows,
    );
  }
}
