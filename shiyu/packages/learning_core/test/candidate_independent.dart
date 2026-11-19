// Independent candidate/Core QA: public Interfaces, real temporary files and
// separate Dart processes. No HTTP, capability verifier, model, TTS or Player.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:material_core/material_core.dart';
import 'package:playback_core/playback_core.dart';
import 'package:learning_core/learning_core.dart';

import 'support.dart';

const owner = 'independent-candidate-owner';
const declaration = SourceDeclaration(
  preparation: 'Controlled external text fixture; no model invocation.',
  provider: 'Unverified fixture provider claim',
  model: 'unverified-model-label',
  notes: 'These supplied statements are not model or rights authentication.',
);
const sender = CandidateSender(integrationId: 'persistent-controlled-integration',
    transport: CandidateTransport.controlledTest,
    transportPayloadSha256: 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee');
const sentences = [LearningSentenceInput(
    english: 'Let me walk you through the plan.', translation: '我来说明一下计划。')];

class Harness {
  Harness(this.root, {this.ownerId = owner});
  final Directory root;
  final String ownerId;
  late FileMaterialStore materials;
  late FileLearningStore learning;
  bool closed = true;
  LearningCandidateStore get candidates => learning;
  Future<void> open() async {
    materials = await FileMaterialStore.open(root: Directory('${root.path}/materials'),
                                            trustedOwnerId: ownerId);
    try {
      learning = await FileLearningStore.open(root: Directory('${root.path}/learning'),
                                              materials: materials);
    } catch (_) {
      await materials.close();
      rethrow;
    }
    closed = false;
  }
  Future<void> close() async {
    if (closed) return;
    await learning.close();
    await materials.close();
    closed = true;
  }
  Future<MaterialVersion> source({String text = '合成原稿：说明计划，并保留原始事实。'}) async {
    final draft = await materials.createDraft(title: 'Synthetic confirmed source', text: text);
    return materials.confirmVersion(materialId: draft.materialId,
                                     expectedRevision: draft.revision);
  }
}

LearningCandidateInput input(MaterialVersion source, {
  String deliveryId = 'independent-delivery',
  List<LearningSentenceInput> text = sentences,
  String? hash,
  String? materialId,
}) => LearningCandidateInput(materialId: materialId ?? source.materialId,
    materialVersionId: source.versionId,
    sourceTextSha256: hash ?? sha256.convert(utf8.encode(source.text)).toString(),
    deliveryId: deliveryId, sentences: text, declaration: declaration);

Future<void> denied(LearningErrorCode code, Future<Object?> Function() operation) async {
  try { await operation(); }
  on LearningStoreException catch (error) {
    expectThat(error.code == code, 'wrong stable LearningStore error code');
    return;
  }
  throw StateError('operation unexpectedly succeeded');
}

Future<void> fixtureCase(Future<void> Function(Harness harness) body) =>
    inSandbox((root) async {
      final h = Harness(root);
      await h.open();
      try { await body(h); } finally { await h.close(); }
    });

Future<Map<String, dynamic>> legacyFixture(Directory destination) async {
  final fixture = jsonDecode(await File.fromUri(Platform.script.resolve(
      'fixtures/candidate_legacy_v1.json')).readAsString()) as Map<String, dynamic>;
  for (final entry in (fixture['files'] as Map<String, dynamic>).entries) {
    final parts = entry.key.split('/');
    expectThat(!entry.key.contains('\\') && !entry.key.contains(':') &&
        !entry.key.startsWith('/') && !parts.any((part) => part.isEmpty || part == '..'),
        'fixture file must remain in owned sandbox');
    final file = File('${destination.path}/${entry.key}');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(base64Decode(entry.value as String), flush: true);
  }
  return fixture;
}

Future<void> childConfirm(List<String> args) async {
  final h = Harness(Directory(args[1]), ownerId: args[2]);
  await h.open();
  await h.candidates.confirmCandidate(candidateId: args[3],
                                     expectedRevision: int.parse(args[4]));
  // Real commit completed, but deliberately no confirmation reply/normal close.
  // This tests an acknowledgement gap, not an invented torn-write guarantee.
  exit(0);
}

Future<void> main(List<String> args) async {
  if (args.isNotEmpty && args.first == 'child-confirm') return childConfirm(args);
  final cases = Cases();
  await cases.run('receive and delivery replay are private, durable and independent of rotated raw transport hash',
      () => fixtureCase((h) async {
    final source = await h.source();
    final receipt = await h.candidates.receiveCandidate(sender: sender, input: input(source));
    expectThat(!receipt.replayed && (await h.learning.listVersions()).isEmpty,
        'receive must not create a learning version');
    final first = await h.candidates.readCandidate(receipt.candidateId);
    expectThat(first.state == LearningCandidateState.pendingReview && first.revision == 1,
        'received candidate must remain pending');
    await h.close(); await h.open();
    const rotated = CandidateSender(integrationId: 'persistent-controlled-integration',
        transport: CandidateTransport.controlledTest,
        transportPayloadSha256: 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff');
    final again = await h.candidates.receiveCandidate(sender: rotated, input: input(source));
    expectThat(again.replayed && again.candidateId == receipt.candidateId &&
        again.payloadSha256 == receipt.payloadSha256, 'restart replay must reuse the candidate');
    final persisted = await h.candidates.readCandidate(receipt.candidateId);
    expectThat(persisted.submission.transportPayloadSha256 == sender.transportPayloadSha256,
        'first immutable transport evidence must not be overwritten by replay');
    expectThat((await h.candidates.listCandidates()).length == 1, 'one durable candidate');
    await denied(LearningErrorCode.deliveryConflict, () => h.candidates.receiveCandidate(
        sender: sender, input: input(source, text: const [LearningSentenceInput(
            english: 'Changed content.', translation: '改变的内容。')])));
  }));
  await cases.run('source owner material version and actual text digest cannot be guessed or rebound',
      () => fixtureCase((h) async {
    final source = await h.source();
    await denied(LearningErrorCode.bindingMismatch, () => h.candidates.receiveCandidate(
        sender: sender, input: input(source, hash: '0' * 64)));
    await denied(LearningErrorCode.bindingMismatch, () => h.candidates.receiveCandidate(
        sender: sender, input: input(source, materialId: 'a' * 32)));
    final received = await h.candidates.receiveCandidate(sender: sender, input: input(source));
    final other = Harness(h.root, ownerId: 'other-independent-owner');
    await other.open();
    try {
      await denied(LearningErrorCode.notFound, () => other.candidates.readCandidate(received.candidateId));
      expectThat((await other.candidates.listCandidates()).isEmpty, 'other owner sees no candidate');
    } finally { await other.close(); }
    expectThat((await h.learning.listVersions()).isEmpty, 'binding checks do not create learning');
  }));
  await cases.run('revision confirmation is atomic, text-only partial and external declaration stays unverified',
      () => fixtureCase((h) async {
    final source = await h.source();
    final received = await h.candidates.receiveCandidate(sender: sender, input: input(source));
    final revised = await h.candidates.reviseCandidate(candidateId: received.candidateId,
      expectedRevision: 1, sentences: const [LearningSentenceInput(
        english: 'Here is what I am planning to do next.', translation: '接下来我打算这样做。')]);
    expectThat(revised.revision == 2 && revised.userEdited, 'actual revision must be tracked');
    expectThat(revised.originalSentences.single.english == sentences.single.english &&
        revised.declaration.model == declaration.model,
        'editing must preserve original input and provider statements');
    await denied(LearningErrorCode.revisionConflict, () => h.candidates.confirmCandidate(
        candidateId: received.candidateId, expectedRevision: 1));
    final version = await h.candidates.confirmCandidate(candidateId: received.candidateId,
                                                       expectedRevision: 2);
    final again = await h.candidates.confirmCandidate(candidateId: received.candidateId,
                                                     expectedRevision: 2);
    expectThat(version.binding.learningVersionId == again.binding.learningVersionId &&
        (await h.learning.listVersions()).length == 1, 'fixed revision creates exactly one version');
    expectThat(version.state == LearningState.partial && version.media == null,
        'text-only content must not become playable or invent audio');
    expectThat(version.textProvenance.origin == ContentOrigin.external &&
        version.textProvenance.external?.candidateId == received.candidateId &&
        version.textProvenance.external?.candidateRevision == 2 &&
        version.textProvenance.external?.userEdited == true,
        'confirmed external snapshot must bind the actual corrected revision');
    await denied(LearningErrorCode.notReady,
        () => h.learning.openPlayback(version.binding.learningVersionId));
    await denied(LearningErrorCode.invalidInput, () => h.learning.createVersion(
        materialVersionId: source.versionId, sentences: sentences,
        textProvenance: version.textProvenance));
    await denied(LearningErrorCode.invalidState, () => h.candidates.reviseCandidate(
        candidateId: received.candidateId, expectedRevision: 2, sentences: sentences));
    await denied(LearningErrorCode.invalidState, () => h.candidates.rejectCandidate(
        candidateId: received.candidateId, expectedRevision: 2));
  }));
  await cases.run('reject wins terminal race without creating a learning version',
      () => fixtureCase((h) async {
    final source = await h.source();
    final received = await h.candidates.receiveCandidate(sender: sender, input: input(source));
    final rejecting = h.candidates.rejectCandidate(candidateId: received.candidateId,
                                                  expectedRevision: 1);
    final deniedConfirm = denied(LearningErrorCode.invalidState,
        () => h.candidates.confirmCandidate(candidateId: received.candidateId, expectedRevision: 1));
    await rejecting; await deniedConfirm;
    final repeat = await h.candidates.rejectCandidate(candidateId: received.candidateId,
                                                     expectedRevision: 1);
    expectThat(repeat.state == LearningCandidateState.rejected &&
        (await h.learning.listVersions()).isEmpty, 'reject remains terminal and private');
    await denied(LearningErrorCode.invalidState, () => h.candidates.reviseCandidate(
        candidateId: received.candidateId, expectedRevision: 1, sentences: sentences));
  }));
  await cases.run('concurrent confirm and reopen count the real versions rather than only matching replies',
      () => fixtureCase((h) async {
    final source = await h.source();
    final receipt = await h.candidates.receiveCandidate(sender: sender, input: input(source));
    final replies = await Future.wait(List.generate(8, (_) => h.candidates.confirmCandidate(
        candidateId: receipt.candidateId, expectedRevision: 1)));
    final ids = replies.map((version) => version.binding.learningVersionId).toSet();
    expectThat(ids.length == 1 && (await h.learning.listVersions()).length == 1,
        'same revision must share one actual persisted version');
    await h.close(); await h.open();
    final persisted = await h.candidates.confirmCandidate(candidateId: receipt.candidateId,
                                                          expectedRevision: 1);
    expectThat(ids.single == persisted.binding.learningVersionId &&
        (await h.learning.listVersions()).length == 1, 'reopen must preserve confirmation relation');
  }));
  await cases.run('real process exits after commit without a reply and retry still has exactly one version',
      () => fixtureCase((h) async {
    final source = await h.source();
    final receipt = await h.candidates.receiveCandidate(sender: sender, input: input(source));
    await h.close();
    final child = await Process.run(Platform.resolvedExecutable,
        [File.fromUri(Platform.script).absolute.path, 'child-confirm',
         h.root.path, h.ownerId, receipt.candidateId, '1']);
    expectThat(child.exitCode == 0 && (child.stdout as String).trim().isEmpty,
        'child must commit and terminate without an acknowledgement');
    await h.open();
    final candidate = await h.candidates.readCandidate(receipt.candidateId);
    final reply = await h.candidates.confirmCandidate(candidateId: receipt.candidateId,
                                                       expectedRevision: 1);
    expectThat(candidate.confirmedLearningVersionId == reply.binding.learningVersionId &&
        (await h.learning.listVersions()).length == 1,
        'acknowledgement gap must not duplicate a learning version');
  }));
  await cases.run('actual schema1 baseline migrates both copies while preserving IDs origins and paused checkpoint',
      () => inSandbox((root) async {
    final fixture = await legacyFixture(root);
    final h = Harness(root, ownerId: fixture['ownerId'] as String);
    await h.open();
    try {
      final manual = await h.learning.readVersion(fixture['manualVersionId'] as String);
      final synthetic = await h.learning.readVersion(fixture['syntheticVersionId'] as String);
      expectThat(manual.textProvenance.origin == ContentOrigin.manual &&
          synthetic.textProvenance.origin == ContentOrigin.synthetic,
          'legacy provenance must not become external');
      final progress = await h.learning.restoreProgress(synthetic.binding.learningVersionId);
      expectThat(progress?.position.inMilliseconds == fixture['checkpointMs'] &&
          progress?.resumeIntent == PlaybackIntent.paused &&
          progress!.binding.sameAs(synthetic.binding), 'legacy exact paused checkpoint must survive');
      expectThat((await h.learning.listVersions()).length == 2 &&
          (await h.candidates.listCandidates()).isEmpty, 'migration must not invent candidate or version');
      final files = fixture['files'] as Map<String, dynamic>;
      final originalKey = files.keys.singleWhere((path) => path.startsWith('learning/') &&
          path.endsWith('/learning.json'));
      final original = base64Decode(files[originalKey] as String);
      final partition = File('${root.path}/$originalKey').parent;
      expectThat((jsonDecode(await File('${partition.path}/learning.json').readAsString())
          as Map<String, dynamic>)['schema'] == 3, 'primary must use schema3');
      expectThat((jsonDecode(await File('${partition.path}/learning.bak').readAsString())
          as Map<String, dynamic>)['schema'] == 3, 'backup must also fence legacy writers');
      expectThat(await File('${partition.path}/store.marker').readAsString() == 'learning_core:3' &&
          !h.learning.recoveryReport.issues.any((i) => i.startsWith('recovery_hold:')),
          'schema3 migration completes marker without hold');
      final archived = await File('${partition.path}/learning.schema1.snapshot').readAsBytes();
      expectThat(base64Encode(archived) == base64Encode(original), 'actual valid v1 bytes must be preserved');
      await h.close(); await h.open();
      expectThat((await h.learning.restoreProgress(synthetic.binding.learningVersionId))!
          .position.inMilliseconds == fixture['checkpointMs'], 'migrated checkpoint survives another reopen');
    } finally { await h.close(); }
  }));
  await cases.run('invalid Unicode and actual UTF8 text limits fail without changing candidate state',
      () => fixtureCase((h) async {
    final source = await h.source();
    for (final text in [String.fromCharCode(0xd800), '中' * 40000]) {
      var rejected = false;
      try {
        await h.candidates.receiveCandidate(sender: sender,
            input: input(source, text: [LearningSentenceInput(english: text,
                                                           translation: '合成对照。')]));
      } on LearningStoreException catch (error) {
        rejected = error.code == LearningErrorCode.invalidInput ||
            error.code == LearningErrorCode.candidateLimitExceeded;
      }
      expectThat(rejected, 'invalid scalar/over-budget UTF8 must be explicitly rejected');
    }
    expectThat((await h.candidates.listCandidates()).isEmpty &&
        (await h.learning.listVersions()).isEmpty, 'invalid input must not create content');
  }));
  await cases.run('actual backup3 plus primary1 and original archive resumes without loss',
      () => inSandbox((root) async {
    final migratedRoot = Directory('${root.path}/migrated');
    final interruptedRoot = Directory('${root.path}/interrupted');
    final fixture = await legacyFixture(migratedRoot);
    await legacyFixture(interruptedRoot);
    final h = Harness(migratedRoot, ownerId: fixture['ownerId'] as String);
    await h.open(); await h.close();
    final files = fixture['files'] as Map<String, dynamic>;
    final primary = files.keys.singleWhere((path) => path.startsWith('learning/') &&
        path.endsWith('/learning.json'));
    final backup = '${primary.substring(0, primary.length - 'learning.json'.length)}learning.bak';
    // Simulate backup3 with an actual current snapshot and its actual
    // schema1 archive, persisted before backup3. Keep primary1 and marker1.
    // No schema/checksum/body is synthesized or repaired.
    await File('${interruptedRoot.path}/$backup').writeAsBytes(
        await File('${migratedRoot.path}/$primary').readAsBytes(), flush: true);
    final archivePath = '${primary.substring(0, primary.length - 'learning.json'.length)}learning.schema1.snapshot';
    await File('${interruptedRoot.path}/$archivePath').writeAsBytes(
        await File('${migratedRoot.path}/$archivePath').readAsBytes(), flush: true);
    final resumed = Harness(interruptedRoot, ownerId: fixture['ownerId'] as String);
    await resumed.open();
    try {
      final partition = File('${interruptedRoot.path}/$primary').parent;
      expectThat((jsonDecode(await File('${partition.path}/learning.json').readAsString()) as Map)['schema'] == 3 &&
          (jsonDecode(await File('${partition.path}/learning.bak').readAsString()) as Map)['schema'] == 3 &&
          await File('${partition.path}/store.marker').readAsString() == 'learning_core:3' &&
          !resumed.learning.recoveryReport.issues.any((i) => i.startsWith('recovery_hold:')),
          'actual backup3 completes both snapshots and marker without hold');
      expectThat((await resumed.learning.listVersions()).length == 2 &&
          (await resumed.candidates.listCandidates()).isEmpty,
          'interrupted migration must not duplicate or invent records');
      final progress = await resumed.learning.restoreProgress(fixture['syntheticVersionId'] as String);
      expectThat(progress?.position.inMilliseconds == fixture['checkpointMs'],
          'interrupted migration must retain the original exact checkpoint');
    } finally { await resumed.close(); }
  }));
  await cases.run('completed schema3 fence holds old-writer bytes without rewriting authority',
      () => inSandbox((root) async {
    final fixture = await legacyFixture(root);
    final h = Harness(root, ownerId: fixture['ownerId'] as String);
    await h.open();
    final source = await h.materials.readVersion(fixture['materialVersionId'] as String);
    final receipt = await h.candidates.receiveCandidate(sender: sender, input: input(source));
    await h.candidates.confirmCandidate(candidateId: receipt.candidateId, expectedRevision: 1);
    await h.close();
    final files = fixture['files'] as Map<String, dynamic>;
    final primary = files.keys.singleWhere((path) => path.startsWith('learning/') &&
        path.endsWith('/learning.json'));
    final backup = '${primary.substring(0, primary.length - 'learning.json'.length)}learning.bak';
    final backupBefore = await File('${root.path}/$backup').readAsBytes();
    final legacyPrimary = base64Decode(files[primary] as String);
    // Fault fixture only: an unsupported legacy writer overwrote the primary.
    // This is not an attempt to make old clients support schema3.
    await File('${root.path}/$primary').writeAsBytes(legacyPrimary, flush: true);
    for (var reopen = 0; reopen < 2; reopen++) {
      await h.open();
      expectThat(h.learning.recoveryReport.issues.contains('recovery_hold:migration_uncertain') &&
          h.learning.recoveryReport.issues.contains('schema_boundary_mismatch'), 'precise persistent downgrade hold');
      final hold = File('${File('${root.path}/$primary').parent.path}/learning.recovery.hold');
      expectThat((jsonDecode(await hold.readAsString()) as Map)['reason'] == 'migration_uncertain', 'independent persisted hold');
      await denied(LearningErrorCode.recoveryHold, () => h.candidates.receiveCandidate(sender: sender, input: input(source)));
      await denied(LearningErrorCode.recoveryHold, () => h.candidates.confirmCandidate(candidateId: receipt.candidateId, expectedRevision: 1));
      await denied(LearningErrorCode.recoveryHold, () => h.candidates.rejectCandidate(candidateId: receipt.candidateId, expectedRevision: 1));
      await denied(LearningErrorCode.recoveryHold, () => h.candidates.reviseCandidate(candidateId: receipt.candidateId, expectedRevision: 1, sentences: sentences));
      await denied(LearningErrorCode.recoveryHold, () => h.candidates.readCandidate(receipt.candidateId));
      await denied(LearningErrorCode.recoveryHold, h.candidates.listCandidates);
      await denied(LearningErrorCode.recoveryHold, () => h.learning.createVersion(materialVersionId: source.versionId,
          sentences: sentences, textProvenance: const ContentProvenance(origin: ContentOrigin.manual, reference: 'fixture:held')));
      await denied(LearningErrorCode.recoveryHold, () => h.learning.openPlayback(fixture['syntheticVersionId'] as String));
      await denied(LearningErrorCode.recoveryHold, () => h.learning.mediaArtifactFor(PlaybackItem(ownerId: h.ownerId,
          itemId: fixture['syntheticVersionId'] as String, itemRevision: 'unknown', kind: MediaKind.audio)));
      expectThat(base64Encode(await File('${root.path}/$backup').readAsBytes()) == base64Encode(backupBefore) &&
          base64Encode(await File('${root.path}/$primary').readAsBytes()) == base64Encode(legacyPrimary), 'hold preserves both authorities');
      await h.close();
    }
    expectThat(base64Encode(await File('${root.path}/$backup').readAsBytes()) ==
        base64Encode(backupBefore), 'failed open must not reset or rewrite the valid backup');
    expectThat(base64Encode(await File('${root.path}/$primary').readAsBytes()) ==
        base64Encode(legacyPrimary), 'failed open must preserve evidence instead of silently downgrading');
  }));
  cases.finish();
}
