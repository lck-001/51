import 'dart:convert';
import 'dart:io';

import 'package:agent_bridge/agent_bridge.dart';
import 'package:crypto/crypto.dart';
import 'package:learning_core/learning_core.dart';
import 'package:material_core/material_core.dart';

import 'mcp_proxy_local.dart' as rpc;

/// Fault injection after the real Store committed; never changes Core/transport.
final class MalformedReceiptCandidates implements LearningCandidateStore {
  MalformedReceiptCandidates(this.real);
  final LearningCandidateStore real;
  @override
  String get trustedOwnerId => real.trustedOwnerId;
  @override
  Future<CandidateDeliveryReceipt> receiveCandidate({
    required CandidateSender sender,
    required LearningCandidateInput input,
  }) async {
    final delivered = await real.receiveCandidate(sender: sender, input: input);
    return CandidateDeliveryReceipt(
      candidateId: 'invalid-ack-after-real-commit',
      payloadSha256: delivered.payloadSha256,
      replayed: delivered.replayed,
    );
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

Future<void> usingBridge(
  Future<void> Function(FileLearningStore, MaterialVersion, String) body, {
  bool malformedReceipt = false,
}) async {
  final root = await Directory.systemTemp.createTemp('shiyu-mcp-delivery-');
  final resolved = await root.resolveSymbolicLinks();
  LearningRootLock? lock;
  FileMaterialStore? materials;
  FileLearningStore? learning;
  AgentBridgeController? bridge;
  try {
    lock = await LearningRootLock.acquire(root);
    materials = await FileMaterialStore.open(
      root: Directory('${root.path}/materials'),
      trustedOwnerId: 'controlled-mcp-delivery-owner',
    );
    learning = await FileLearningStore.open(
      root: Directory('${root.path}/learning'),
      materials: materials,
    );
    final draft = await materials.createDraft(
      title: 'Original local MCP structure sample',
      text: '今天整理了计划。',
    );
    final source = await materials.confirmVersion(
      materialId: draft.materialId,
      expectedRevision: draft.revision,
    );
    bridge = AgentBridgeController.attach(
      materials: materials,
      candidates: malformedReceipt
          ? MalformedReceiptCandidates(learning)
          : learning,
      privateDirectory: Directory('${root.path}/bridge'),
      rootLock: lock,
      proxyCommand: [Platform.resolvedExecutable],
    );
    await bridge.authorize(
      AgentBridgeGrantRequest(materialVersionId: source.versionId),
    );
    rpc.check(
      !bridge.current.allowSourceRead,
      'receive does not imply source read',
    );
    await body(learning, source, '${root.path}/bridge/descriptor.json');
  } finally {
    await bridge?.close();
    await learning?.close();
    await materials?.close();
    await lock?.release();
    if (await root.exists()) {
      final actual = await root.resolveSymbolicLinks();
      final temporary = await Directory.systemTemp.resolveSymbolicLinks();
      rpc.check(
        actual == resolved &&
            actual.startsWith(
              '$temporary${Platform.pathSeparator}shiyu-mcp-delivery-',
            ),
        'cleanup only this owned synthetic temp root',
      );
      await root.delete(recursive: true);
    }
  }
}

Map<String, Object?> payload(MaterialVersion source, String delivery) => {
  'schema_version': 1,
  'material_id': source.materialId,
  'material_version_id': source.versionId,
  'source_text_sha256': sha256.convert(utf8.encode(source.text)).toString(),
  'delivery_id': delivery,
  'sentences': [
    {'english': 'Let us review the plan.', 'translation': '我们来看看这个计划。'},
  ],
  'declaration': {
    'preparation':
        'Original controlled text sample, no real model or TTS call.',
  },
};

Future<Map<String, dynamic>> submit(
  String descriptor,
  Map<String, Object?> body,
) async {
  final result = await rpc.runBytes(
    rpc.lines([
      rpc.initialize(1),
      rpc.initialized,
      rpc.request(2, 'tools/call', {
        'name': 'shiyu_submit_learning_candidate',
        'arguments': body,
      }),
    ]),
    descriptorPath: descriptor,
  );
  rpc.check(
    result.code == 0 && result.replies.length == 2,
    'one tool request gets exactly one reply',
  );
  return result.replies.last['result'] as Map<String, dynamic>;
}

Future<void> main() async {
  var passed = 0, failed = 0;
  Future<void> test(String name, Future<void> Function() action) async {
    try {
      await action().timeout(const Duration(seconds: 30));
      passed++;
      stdout.writeln('PASS $name');
    } catch (_) {
      failed++;
      stdout.writeln('FAIL $name');
    }
  }

  await test(
    'Real bridge and Core replay always reports delivered after owner confirms or rejects',
    () => usingBridge((learning, source, descriptor) async {
      final one = payload(source, 'confirmed-delivery');
      final first = await submit(descriptor, one);
      rpc.check(first['isError'] == false, 'actual initial delivery succeeds');
      final firstReceipt = first['structuredContent'] as Map;
      rpc.check(
        firstReceipt['status'] == 'delivered' &&
            firstReceipt['replayed'] == false,
        'neutral delivered receipt',
      );
      await learning.confirmCandidate(
        candidateId: firstReceipt['candidate_id'] as String,
        expectedRevision: 1,
      );
      final replay = await submit(descriptor, one);
      final confirmedReceipt = replay['structuredContent'] as Map;
      rpc.check(
        replay['isError'] == false &&
            confirmedReceipt['status'] == 'delivered' &&
            confirmedReceipt['replayed'] == true &&
            confirmedReceipt['candidate_id'] == firstReceipt['candidate_id'],
        'replay cannot pretend a confirmed candidate is currently pending',
      );
      final two = payload(source, 'rejected-delivery');
      final second = await submit(descriptor, two);
      final secondReceipt = second['structuredContent'] as Map;
      await learning.rejectCandidate(
        candidateId: secondReceipt['candidate_id'] as String,
        expectedRevision: 1,
      );
      final rejectedReplay = await submit(descriptor, two);
      final rejectedReceipt = rejectedReplay['structuredContent'] as Map;
      rpc.check(
        rejectedReplay['isError'] == false &&
            rejectedReceipt['status'] == 'delivered' &&
            rejectedReceipt['replayed'] == true &&
            rejectedReceipt['candidate_id'] == secondReceipt['candidate_id'],
        'replay does not disclose or mislabel rejected state',
      );
      rpc.check(
        (await learning.listCandidates()).length == 2 &&
            (await learning.listVersions()).length == 1,
        'replay neither duplicates candidate nor grants sender confirmation',
      );
      for (final receipt in [confirmedReceipt, rejectedReceipt]) {
        rpc.check(
          receipt.keys.toSet().difference({
            'candidate_id',
            'payload_sha256',
            'replayed',
            'status',
          }).isEmpty,
          'receive-only response has no owner review state or learning ID',
        );
      }
    }),
  );
  await test(
    'Malformed acknowledgement after actual Core commit is outcomeUnknown, not non-delivery',
    () => usingBridge((learning, source, descriptor) async {
      final result = await submit(descriptor, payload(source, 'bad-ack'));
      rpc.check(
        result['isError'] == true &&
            (((result['structuredContent'] as Map)['error'] as Map)['code']) ==
                'outcomeUnknown',
        'invalid receipt means unknown delivery outcome',
      );
      rpc.check(
        (await learning.listCandidates()).length == 1 &&
            (await learning.listVersions()).isEmpty,
        'the candidate was really stored, without automatic confirmation or retry',
      );
    }, malformedReceipt: true),
  );
  stdout.writeln(
    'RESULT passed=$passed failed=$failed total=${passed + failed}',
  );
  if (failed > 0) exitCode = 1;
}
