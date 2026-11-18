import 'dart:async';
import 'dart:io';

import 'package:agent_bridge/agent_bridge.dart';
import 'package:learning_core/learning_core.dart';
import 'package:material_core/material_core.dart';

final class HeldCandidates implements LearningCandidateStore {
  HeldCandidates(this.real);
  final LearningCandidateStore real;
  final entered = Completer<void>(), gate = Completer<void>();
  @override
  String get trustedOwnerId => real.trustedOwnerId;
  @override
  Future<CandidateDeliveryReceipt> receiveCandidate({
    required CandidateSender sender,
    required LearningCandidateInput input,
  }) async {
    if (!entered.isCompleted) entered.complete();
    await gate.future;
    return real.receiveCandidate(sender: sender, input: input);
  }

  @override
  Future<LearningCandidate> readCandidate(String id) => real.readCandidate(id);
  @override
  Future<List<LearningCandidate>> listCandidates() => real.listCandidates();
  @override
  Future<LearningCandidate> reviseCandidate({
    required String candidateId,
    required int expectedRevision,
    required List<LearningSentenceInput> sentences,
  }) => real.reviseCandidate(
    candidateId: candidateId,
    expectedRevision: expectedRevision,
    sentences: sentences,
  );
  @override
  Future<LearningVersion> confirmCandidate({
    required String candidateId,
    required int expectedRevision,
  }) => real.confirmCandidate(
    candidateId: candidateId,
    expectedRevision: expectedRevision,
  );
  @override
  Future<LearningCandidate> rejectCandidate({
    required String candidateId,
    required int expectedRevision,
  }) => real.rejectCandidate(
    candidateId: candidateId,
    expectedRevision: expectedRevision,
  );
}

Future<void> main() async {
  final root = await Directory.systemTemp.createTemp('shiyu-bridge-flow-');
  LearningRootLock? lock;
  FileMaterialStore? materials;
  FileLearningStore? learning;
  AgentBridgeController? bridge, slow;
  AgentBridgeClient? client, slowClient;
  var checks = 0, phase = 'begin';
  void check(bool value) {
    if (!value) throw StateError('check');
    checks++;
  }

  Future<void> rejects(
    FutureOr<Object?> Function() action,
    AgentBridgeErrorCode code,
  ) async {
    try {
      await action();
      throw StateError('unexpected_success');
    } on AgentBridgeException catch (error) {
      check(error.code == code);
    }
  }

  try {
    phase = 'own-stores';
    lock = await LearningRootLock.acquire(root);
    final owned = lock.rootDirectory;
    materials = await FileMaterialStore.open(
      root: Directory('${owned.path}/materials'),
      trustedOwnerId: 'controlled-owner',
    );
    learning = await FileLearningStore.open(
      root: Directory('${owned.path}/learning'),
      materials: materials,
    );
    final draft = await materials.createDraft(
      title: 'Original synthetic source',
      text: '今天讨论了计划。',
    );
    final source = await materials.confirmVersion(
      materialId: draft.materialId,
      expectedRevision: draft.revision,
    );
    final private = Directory('${owned.path}/bridge');
    bridge = AgentBridgeController.attach(
      materials: materials,
      candidates: learning,
      privateDirectory: private,
      rootLock: lock,
      proxyCommand: [Platform.resolvedExecutable],
    );
    check(
      bridge.current.phase == AgentBridgePhase.disabled &&
          !await private.exists(),
    );
    phase = 'receive-only-grant';
    await bridge.authorize(
      AgentBridgeGrantRequest(materialVersionId: source.versionId),
    );
    client = AgentBridgeClient(
      descriptorPath: '${private.path}/descriptor.json',
    );
    final reference = await client.getSourceReference();
    check(
      reference['material_id'] == source.materialId &&
          reference['material_version_id'] == source.versionId,
    );
    await rejects(
      () => client!.readFixedSource(
        materialId: source.materialId,
        materialVersionId: source.versionId,
        sourceTextSha256: reference['source_text_sha256'] as String,
      ),
      AgentBridgeErrorCode.forbidden,
    );
    Map<String, Object?> payload(String id) => {
      'schema_version': 1,
      ...reference,
      'delivery_id': id,
      'sentences': [
        {'english': 'Let us review the plan.', 'translation': '我们来看看这个计划。'},
      ],
      'declaration': {
        'preparation':
            'Original controlled local-capability test; no model call.',
      },
    };
    phase = 'actual-receive';
    final first = await client.submitCandidate(payload('delivery-one'));
    check(first['status'] == 'delivered' && first['replayed'] == false);
    check(
      (await learning.listCandidates()).length == 1 &&
          (await learning.listVersions()).isEmpty,
    );
    final replay = await client.submitCandidate(payload('delivery-one'));
    check(
      replay['candidate_id'] == first['candidate_id'] &&
          replay['replayed'] == true,
    );
    final changed = payload('delivery-one');
    changed['declaration'] = {'preparation': 'Different same-delivery content'};
    await rejects(
      () => client!.submitCandidate(changed),
      AgentBridgeErrorCode.deliveryConflict,
    );
    final media = payload('media-delivery');
    media['media'] = null;
    await rejects(
      () => client!.submitCandidate(media),
      AgentBridgeErrorCode.unsupportedMedia,
    );
    phase = 'source-read-new-cap';
    await bridge.authorize(
      AgentBridgeGrantRequest(
        materialVersionId: source.versionId,
        allowSourceRead: true,
      ),
    );
    final text = await client.readFixedSource(
      materialId: source.materialId,
      materialVersionId: source.versionId,
      sourceTextSha256: reference['source_text_sha256'] as String,
    );
    check(text['text'] == source.text);
    await rejects(
      () => client!.readFixedSource(
        materialId: source.materialId,
        materialVersionId: source.versionId,
        sourceTextSha256: '0' * 64,
      ),
      AgentBridgeErrorCode.sourceMismatch,
    );
    final rotated = await client.submitCandidate(payload('delivery-one'));
    check(
      rotated['candidate_id'] == first['candidate_id'] &&
          rotated['replayed'] == true,
    );
    phase = 'owner-confirm-partial';
    final confirmed = await learning.confirmCandidate(
      candidateId: first['candidate_id'] as String,
      expectedRevision: 1,
    );
    check(
      confirmed.state == LearningState.partial &&
          confirmed.textProvenance.origin == ContentOrigin.external &&
          confirmed.media == null,
    );
    phase = 'revoke';
    await bridge.revoke();
    check(
      bridge.current.phase == AgentBridgePhase.disabled &&
          !await File('${private.path}/descriptor.json').exists(),
    );
    await rejects(
      () => client!.getSourceReference(),
      AgentBridgeErrorCode.privateStorageUnavailable,
    );
    phase = 'inflight-revoke';
    final held = HeldCandidates(learning);
    final slowDir = Directory('${owned.path}/slow-bridge');
    slow = AgentBridgeController.attach(
      materials: materials,
      candidates: held,
      privateDirectory: slowDir,
      rootLock: lock,
      proxyCommand: [Platform.resolvedExecutable],
    );
    await slow.authorize(
      AgentBridgeGrantRequest(materialVersionId: source.versionId),
    );
    slowClient = AgentBridgeClient(
      descriptorPath: '${slowDir.path}/descriptor.json',
    );
    final sending = slowClient.submitCandidate(payload('held-delivery'));
    sending.ignore();
    await held.entered.future;
    check(slow.current.inFlight == 1);
    var revoked = false;
    final stopping = slow.revoke().then((_) => revoked = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    check(
      !revoked &&
          slow.current.phase == AgentBridgePhase.draining &&
          lock.isHeld,
    );
    await rejects(() => sending, AgentBridgeErrorCode.outcomeUnknown);
    held.gate.complete();
    await stopping;
    check(
      revoked &&
          slow.current.inFlight == 0 &&
          (await learning.listCandidates()).length == 2,
    );
    await slow.authorize(
      AgentBridgeGrantRequest(materialVersionId: source.versionId),
    );
    final receipt = await slowClient.submitCandidate(payload('held-delivery'));
    check(
      receipt['replayed'] == true &&
          (await learning.listCandidates()).length == 2,
    );
    stdout.writeln('PASS actual bridge/Store controlled checks=$checks');
  } catch (error) {
    stderr.writeln(
      'FAIL phase=$phase code=${error is AgentBridgeException ? error.code.name : error.runtimeType}',
    );
    exitCode = 1;
  } finally {
    try {
      await slowClient?.close();
    } catch (_) {}
    try {
      await client?.close();
    } catch (_) {}
    try {
      await slow?.close();
    } catch (_) {}
    try {
      await bridge?.close();
    } catch (_) {}
    try {
      await learning?.close();
    } catch (_) {}
    try {
      await materials?.close();
    } catch (_) {}
    try {
      await lock?.release();
    } catch (_) {}
    await root.delete(recursive: true);
  }
}
