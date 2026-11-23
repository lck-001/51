// Independent actual local bridge/stdio QA. All original content and callers
// are synthetic. This is not Codex/WorkBuddy registration or brand OAuth proof.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_bridge/agent_bridge.dart';
import 'package:learning_core/learning_core.dart';
import 'package:material_core/material_core.dart';

import '../../learning_core/test/support.dart';

String directVm() {
  final current = File(Platform.resolvedExecutable);
  final vm = File('${current.parent.path}/dartvm${Platform.isWindows ? '.exe' : ''}');
  return vm.existsSync() ? vm.path : current.path;
}

Map<String, Object?> packet(Map<String, Object?> reference,
    {String delivery = 'independent-delivery'}) => {
  'schema_version': 1, ...reference, 'delivery_id': delivery,
  'sentences': [
    {'english': 'SYNTHETIC_CANDIDATE_NOT_ORIGINAL_SOURCE', 'translation': '原创合成候选。'},
  ],
  'declaration': {'preparation': 'Controlled sender fixture, not a model call.',
                  'provider': 'Unverified provider statement'},
};

Future<AgentBridgeErrorCode> refused(FutureOr<Object?> Function() operation) async {
  try { await operation(); }
  on AgentBridgeException catch (error) { return error.code; }
  throw StateError('unexpected accepted bridge operation');
}

class HeldCandidates implements LearningCandidateStore {
  HeldCandidates(this.real);
  final LearningCandidateStore real;
  final entered = Completer<void>(), release = Completer<void>();
  int receives = 0;
  @override String get trustedOwnerId => real.trustedOwnerId;
  @override Future<CandidateDeliveryReceipt> receiveCandidate({required CandidateSender sender,
      required LearningCandidateInput input}) async {
    receives++;
    if (!entered.isCompleted) entered.complete();
    await release.future;
    return real.receiveCandidate(sender: sender, input: input);
  }
  @override Future<LearningCandidate> readCandidate(String id) => real.readCandidate(id);
  @override Future<List<LearningCandidate>> listCandidates() => real.listCandidates();
  @override Future<LearningCandidate> reviseCandidate({required String candidateId,
      required int expectedRevision, required List<LearningSentenceInput> sentences}) =>
      real.reviseCandidate(candidateId: candidateId, expectedRevision: expectedRevision,
                           sentences: sentences);
  @override Future<LearningVersion> confirmCandidate({required String candidateId,
      required int expectedRevision}) => real.confirmCandidate(candidateId: candidateId,
                                                               expectedRevision: expectedRevision);
  @override Future<LearningCandidate> rejectCandidate({required String candidateId,
      required int expectedRevision}) => real.rejectCandidate(candidateId: candidateId,
                                                              expectedRevision: expectedRevision);
}

class Fixture {
  Fixture(this.root, {this.hold = false});
  final Directory root;
  final bool hold;
  late LearningRootLock lock;
  late FileMaterialStore materials;
  late FileLearningStore learning;
  late AgentBridgeController bridge;
  late MaterialVersion original;
  HeldCandidates? gate;
  AgentBridgeClient? client;
  String? locator;
  Future<void> open() async {
    lock = await LearningRootLock.acquire(root);
    final owned = lock.rootDirectory;
    materials = await FileMaterialStore.open(root: Directory('${owned.path}/materials'),
                                            trustedOwnerId: 'independent-bridge-owner');
    learning = await FileLearningStore.open(root: Directory('${owned.path}/learning'),
                                            materials: materials);
    final draft = await materials.createDraft(title: 'Synthetic selected source',
        text: 'SYNTHETIC_ORIGINAL_REQUIRES_SEPARATE_READ_SCOPE\n合成原文。');
    original = await materials.confirmVersion(materialId: draft.materialId,
                                               expectedRevision: draft.revision);
    if (hold) gate = HeldCandidates(learning);
    bridge = AgentBridgeController.attach(materials: materials,
        candidates: gate ?? learning, rootLock: lock,
        privateDirectory: Directory('${owned.path}/bridge'),
        proxyCommand: [Platform.resolvedExecutable]);
  }
  Future<AgentBridgeClient> authorize({bool read = false, String? versionId}) async {
    await bridge.authorize(AgentBridgeGrantRequest(
        materialVersionId: versionId ?? original.versionId, allowSourceRead: read));
    final setup = await bridge.setup();
    locator = setup.descriptorPath;
    return client ??= AgentBridgeClient(descriptorPath: setup.descriptorPath);
  }
  Future<Map<String, dynamic>> descriptor() async =>
      jsonDecode(await File(locator!).readAsString()) as Map<String, dynamic>;
  Future<void> close() async {
    if (gate != null && !gate!.release.isCompleted) gate!.release.complete();
    await client?.close();
    await bridge.close();
    await learning.close(); await materials.close(); await lock.release();
  }
}

Future<void> fixtureCase(Future<void> Function(Fixture f) body, {bool hold = false}) =>
    inSandbox((root) async {
      final f = Fixture(root, hold: hold); await f.open();
      try { await body(f); } finally { await f.close(); }
    });

// A small independent wire fixture, not the product's frame decoder. It only
// marshals the documented fixed magic/length and caps replies from our server.
class Wire {
  Wire(this.socket) : input = StreamIterator(socket);
  final Socket socket;
  final StreamIterator<Uint8List> input;
  final bytes = <int>[];
  int consumed = 0;
  static const magic = [0x53, 0x59, 0x42, 0x31, 0, 13, 10, 0];
  Future<Uint8List> exact(int count) async {
    expectThat(count >= 0 && count <= 262144, 'bounded independent reply');
    while (bytes.length - consumed < count) {
      if (!await input.moveNext().timeout(const Duration(seconds: 3)))
        throw StateError('reply ended before its fixed frame');
      bytes.addAll(input.current);
      expectThat(bytes.length <= 524288, 'bounded independent transcript');
    }
    final result = Uint8List.fromList(bytes.sublist(consumed, consumed + count));
    consumed += count; return result;
  }
  Future<Map<String, dynamic>> read() async {
    final header = await exact(12);
    expectThat(List.generate(8, (i) => header[i] == magic[i]).every((v) => v),
        'reply must use the documented private protocol');
    final length = ByteData.sublistView(header).getUint32(8, Endian.big);
    return jsonDecode(utf8.decode(await exact(length))) as Map<String, dynamic>;
  }
  Future<void> send(Object body) async {
    final raw = utf8.encode(jsonEncode(body));
    final header = Uint8List(12)..setRange(0, 8, magic);
    ByteData.sublistView(header).setUint32(8, raw.length, Endian.big);
    socket.add(header); socket.add(raw); await socket.flush();
  }
  Future<void> close() async { socket.destroy(); await input.cancel(); }
}

Future<Map<String, dynamic>> rawCall(Map<String, dynamic> d, String operation,
    Map<String, Object?> payload, {List<int>? rawPayload}) async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, d['port'] as int);
  final wire = Wire(socket);
  final challenge = 'a' * 64;
  try {
    await wire.send({'kind': 'hello', 'session': d['session'], 'challenge': challenge});
    final proof = await wire.read();
    expectThat(proof['kind'] == 'proof', 'real server handshake must precede the test request');
    await wire.send({'kind': 'request', 'session': d['session'], 'challenge': challenge,
      'capability': d['capability'], 'operation': operation,
      'payload': base64Encode(rawPayload ?? utf8.encode(jsonEncode(payload)))});
    return await wire.read();
  } finally { await wire.close(); }
}

Future<void> childServer(Directory root) async {
  final f = Fixture(root); await f.open(); await f.authorize();
  stdout.writeln('READY:$pid'); await stdout.flush();
  await stdin.drain<void>();
  await f.close();
}

Future<void> main(List<String> args) async {
  if (args.isNotEmpty && args.first == 'child-server')
    return childServer(Directory(args[1]));
  if (!Platform.isWindows) {
    stdout.writeln('NOT_RUN Windows bridge validation requires its actual ACL adapter');
    exitCode = 2; return;
  }
  final cases = Cases();
  await cases.run('default closed, real receive-only transport, source scope and persisted private candidate',
      () => fixtureCase((f) async {
    expectThat(f.bridge.current.phase == AgentBridgePhase.disabled,
        'constructing the bridge must not enable it');
    expectThat(await refused(f.bridge.setup) == AgentBridgeErrorCode.disabled,
        'setup cannot silently create an authorization');
    final client = await f.authorize();
    final reference = await client.getSourceReference();
    expectThat(!reference.containsKey('text') && reference.length == 3,
        'receive grant exposes only fixed reference metadata');
    final d = await f.descriptor();
    final read = await rawCall(d, 'source_read', reference);
    expectThat(read['ok'] == false && read['error'] == 'forbidden',
        'server, not only the client, must deny source reads');
    final first = await client.submitCandidate(packet(reference));
    final again = await client.submitCandidate(packet(reference));
    expectThat(first['candidate_id'] == again['candidate_id'] && again['replayed'] == true,
        'actual transport must return durable delivery replay');
    final records = await f.learning.listCandidates();
    expectThat(records.length == 1 && records.single.state == LearningCandidateState.pendingReview &&
        (await f.learning.listVersions()).isEmpty, 'receive must not confirm or create learning');
    final forbidden = await rawCall(d, 'candidate_confirm',
                                   {'candidate_id': records.single.candidateId});
    expectThat(forbidden['ok'] == false && forbidden['error'] == 'forbidden' &&
        (await f.learning.listVersions()).isEmpty, 'receive token cannot confirm through another operation');
    final media = await rawCall(d, 'candidate_receive', {...packet(reference), 'media': null});
    expectThat(media['ok'] == false && media['error'] == 'unsupportedMedia',
        'presence of media cannot be silently discarded');
    final forged = await rawCall(d, 'candidate_receive',
        {...packet(reference, delivery: 'forged'), 'owner_id': 'forged-owner'});
    expectThat(forged['ok'] == false && (await f.learning.listCandidates()).length == 1,
        'body owner claims cannot select a different space');
  }));
  await cases.run('source change and reauthorization cannot relabel an old candidate; reads need separate grant',
      () => fixtureCase((f) async {
    final client = await f.authorize();
    final a = await client.getSourceReference();
    final receipt = await client.submitCandidate(packet(a));
    final integration = f.bridge.current.integrationId;
    final draft = await f.materials.createDraft(title: 'Other fixed source', text: '第二份合成固定原文。');
    final b = await f.materials.confirmVersion(materialId: draft.materialId,
                                              expectedRevision: draft.revision);
    await f.authorize(read: true, versionId: b.versionId);
    final refB = await client.getSourceReference();
    expectThat(refB['material_version_id'] == b.versionId &&
        f.bridge.current.integrationId == integration, 'source selection changes without inventing a new sender identity');
    expectThat(await refused(() => client.submitCandidate(packet(a, delivery: 'late-a'))) ==
        AgentBridgeErrorCode.sourceMismatch, 'old payload stays bound to A');
    final read = await client.readFixedSource(materialId: refB['material_id'] as String,
        materialVersionId: refB['material_version_id'] as String,
        sourceTextSha256: refB['source_text_sha256'] as String);
    expectThat(read['text'] == b.text, 'separately authorized read returns the exact fixed source');
    await f.authorize(versionId: f.original.versionId);
    final replay = await client.submitCandidate(packet(a));
    expectThat(replay['candidate_id'] == receipt['candidate_id'] && replay['replayed'] == true &&
        (await f.learning.listCandidates()).length == 1, 'capability rotation must not bypass persistent idempotence');
  }));
  await cases.run('actual raw framing rejects HTTP, excessive declared bytes and duplicate keys before Store entry',
      () => fixtureCase((f) async {
    await f.authorize();
    final d = await f.descriptor();
    Future<Map<String, dynamic>> unauthenticated(List<int> request) async {
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, d['port'] as int);
      final wire = Wire(socket);
      try { socket.add(request); await socket.flush(); return await wire.read(); }
      finally { await wire.close(); }
    }
    final browser = await unauthenticated(ascii.encode(
        'POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: https://invalid.example\r\nContent-Length: 0\r\n\r\n'));
    expectThat(browser['ok'] == false, 'HTTP/WebSocket-like traffic is not this protocol');
    final header = Uint8List(12)..setRange(0, 8, Wire.magic);
    // A safe 1 MiB claim, never a giant allocation/stress fixture. No body sent.
    ByteData.sublistView(header).setUint32(8, 1024 * 1024, Endian.big);
    final excessive = await unauthenticated(header);
    expectThat(excessive['ok'] == false && excessive['error'] == 'tooLarge',
        'raw declared length is rejected before reading/allocating that body');
    final duplicate = await rawCall(d, 'source_reference', {},
        rawPayload: utf8.encode(r'{"x":1,"\u0078":2}'));
    expectThat(duplicate['ok'] == false && duplicate['error'] == 'invalidJson',
        'escaped duplicate keys must be rejected by the server codec, not last-wins');
    expectThat((await f.learning.listCandidates()).isEmpty &&
        (await f.learning.listVersions()).isEmpty && f.bridge.current.inFlight == 0,
        'malformed raw traffic never enters a Store operation');
  }));
  await cases.run('revoke closes admission but drains a real delayed Store operation and preserves unknown delivery',
      () => fixtureCase((f) async {
    final client = await f.authorize();
    final ref = await client.getSourceReference();
    final sending = client.submitCandidate(packet(ref)).then<Object?>((value) => value,
        onError: (Object error) => error);
    await f.gate!.entered.future.timeout(const Duration(seconds: 3));
    final secondClient = AgentBridgeClient(descriptorPath: f.locator!);
    try {
      expectThat(await refused(() => secondClient.submitCandidate(
          packet(ref, delivery: 'second-concurrent'))) == AgentBridgeErrorCode.busy &&
          f.gate!.receives == 1, 'second actual connection must not start a concurrent Store operation');
    } finally { await secondClient.close(); }
    var revoked = false;
    final revoking = f.bridge.revoke().then((_) { revoked = true; });
    await Future<void>.delayed(const Duration(milliseconds: 25));
    expectThat(!revoked && f.bridge.current.phase == AgentBridgePhase.draining &&
        f.bridge.current.inFlight == 1 && f.lock.isHeld,
        'network shutdown is not completion of the accepted Store future');
    final outcome = await sending;
    expectThat(outcome is AgentBridgeException && outcome.code == AgentBridgeErrorCode.outcomeUnknown,
        'socket cancellation cannot claim no delivery');
    f.gate!.release.complete(); await revoking;
    expectThat(f.bridge.current.phase == AgentBridgePhase.disabled &&
        (await f.learning.listCandidates()).length == 1,
        'accepted old operation must actually drain before disabled completion');
    await f.authorize();
    final replay = await client.submitCandidate(packet(ref));
    expectThat(replay['replayed'] == true && (await f.learning.listCandidates()).length == 1,
        'explicit same-delivery recovery must not create another candidate');
  }, hold: true));
  await cases.run('actual stdio MCP process enters the real bridge, never the Store directly',
      () => fixtureCase((f) async {
    await f.authorize();
    final descriptor = await f.descriptor();
    final process = await Process.start(Platform.resolvedExecutable,
      [File.fromUri(Platform.script.resolve('../bin/shiyu_agent_proxy.dart')).absolute.path],
      environment: {'SHIYU_BRIDGE_DESCRIPTOR': f.locator!,
        'SystemRoot': Platform.environment['SystemRoot'] ?? 'C:\\Windows'},
      includeParentEnvironment: false);
    final output = StreamIterator(process.stdout.transform(utf8.decoder)
        .transform(const LineSplitter()));
    final stderr = BytesBuilder(); process.stderr.listen(stderr.add);
    final transcript = StringBuffer();
    Future<Map<String, dynamic>> call(int id, String method, Map<String, Object?> params) async {
      process.stdin.writeln(jsonEncode({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params}));
      await process.stdin.flush();
      expectThat(await output.moveNext().timeout(const Duration(seconds: 5)), 'stdio reply must arrive');
      transcript.writeln(output.current);
      final value = jsonDecode(output.current) as Map<String, dynamic>;
      expectThat(value['id'] == id, 'actual proxy preserves the RPC request ID');
      return value;
    }
    try {
      final init = await call(1, 'initialize', {'protocolVersion': '2025-11-25',
        'capabilities': <String, Object?>{}, 'clientInfo': {'name': 'controlled-independent-fixture', 'version': '1'}});
      expectThat((init['result'] as Map)['protocolVersion'] == '2025-11-25', 'actual lifecycle negotiation');
      process.stdin.writeln(jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'}));
      final listed = await call(2, 'tools/list', {});
      expectThat(((listed['result'] as Map)['tools'] as List).length == 8, 'exactly eight reviewed tools are discoverable without granting scope');
      final referenceReply = await call(3, 'tools/call', {'name': 'shiyu_get_source_reference', 'arguments': <String, Object?>{}});
      final ref = Map<String, Object?>.from((referenceReply['result'] as Map)['structuredContent'] as Map);
      final forbidden = await call(4, 'tools/call', {'name': 'shiyu_read_fixed_source', 'arguments': ref});
      expectThat((forbidden['result'] as Map)['isError'] == true, 'actual stdio does not elevate source scope');
      final accepted = await call(5, 'tools/call', {'name': 'shiyu_submit_learning_candidate', 'arguments': packet(ref)});
      final content = (accepted['result'] as Map)['structuredContent'] as Map;
      expectThat((accepted['result'] as Map)['isError'] == false && content['candidate_id'] is String,
          'actual MCP transport obtains a durable candidate receipt');
      final candidates = await f.learning.listCandidates();
      expectThat(candidates.length == 1 && (await f.learning.listVersions()).isEmpty,
          'stdio success remains an unconfirmed candidate');
      final learned = await f.learning.confirmCandidate(candidateId: candidates.single.candidateId,
                                                         expectedRevision: candidates.single.revision);
      expectThat(learned.state == LearningState.partial && learned.media == null &&
          learned.textProvenance.origin == ContentOrigin.external,
          'owner confirmation produces readable external text, not audio or authentication');
      final replay = await call(6, 'tools/call', {'name': 'shiyu_submit_learning_candidate', 'arguments': packet(ref)});
      expectThat(((replay['result'] as Map)['structuredContent'] as Map)['replayed'] == true &&
          (await f.learning.listVersions()).length == 1, 'stdio replay after confirmation cannot duplicate learning');
      final logs = '${transcript.toString()}${utf8.decode(stderr.toBytes(), allowMalformed: true)}';
      for (final private in [descriptor['capability'], descriptor['proof_key'], f.locator,
                            f.original.text]) {
        expectThat(private is String && !logs.contains(private), 'stdio must not reflect secrets, path or unauthorized source');
      }
      expectThat(!logs.contains('SYNTHETIC_ORIGINAL_REQUIRES_SEPARATE_READ_SCOPE') &&
          !logs.contains(jsonEncode(f.locator).substring(1, jsonEncode(f.locator).length - 1)),
          'JSON escaping cannot hide unauthorized source or private locator in output');
      await process.stdin.close();
      expectThat(await process.exitCode.timeout(const Duration(seconds: 5)) == 0, 'clean stdio EOF exits');
    } finally {
      await output.cancel();
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
    }
  }));
  await cases.run('stale private descriptor on a reused port discloses neither credential nor candidate payload',
      () => inSandbox((root) async {
    Process? child;
    ServerSocket? fake;
    Socket? accepted;
    var phase = 'starting-owned-server';
    try {
      child = await Process.start(directVm(),
          [File.fromUri(Platform.script).absolute.path, 'child-server', root.path]);
      child.stderr.listen((_) {});
      final ready = await child.stdout.transform(utf8.decoder).transform(const LineSplitter())
          .first.timeout(const Duration(seconds: 5));
      expectThat(ready == 'READY:${child.pid}',
          'the Process handle must identify the actual server VM, not an SDK launcher');
      final descriptorFile = File('${root.path}/bridge/descriptor.json');
      final d = jsonDecode(await descriptorFile.readAsString()) as Map<String, dynamic>;
      expectThat(child.kill(ProcessSignal.sigkill), 'terminate only the actual owned server VM');
      await child.exitCode; child = null;
      expectThat(await descriptorFile.exists(), 'an actual VM crash must leave the stale private descriptor');
      phase = 'binding-reused-port';
      fake = await ServerSocket.bind(InternetAddress.loopbackIPv4, d['port'] as int);
      final transcript = BytesBuilder();
      final serverDone = Completer<void>();
      fake.listen((socket) {
        accepted = socket;
        unawaited(() async {
          final wire = Wire(socket);
          try {
            final hello = await wire.read();
            expectThat(hello.keys.length == 3 && hello['kind'] == 'hello' &&
                !hello.containsKey('capability') && !hello.containsKey('payload'),
                'only a credential-free challenge precedes server proof');
            await wire.send({'kind': 'proof', 'session': d['session'], 'mac': '0' * 64});
            // Capture any prohibited second message too; normal client closes.
            try {
              while (await wire.input.moveNext().timeout(const Duration(seconds: 3))) {
                wire.bytes.addAll(wire.input.current);
              }
            } on SocketException {
              // Windows may surface the expected destroy-after-refusal as
              // ECONNRESET instead of clean EOF. Keep every captured byte and
              // still require the actual client error/no-secret assertions.
            }
            transcript.add(wire.bytes);
            serverDone.complete();
          } catch (error, stack) { serverDone.completeError(error, stack); }
          finally { await wire.close(); }
        }());
      });
      final client = AgentBridgeClient(descriptorPath: descriptorFile.path);
      try {
        final ref = <String, Object?>{for (final key in
            ['material_id', 'material_version_id', 'source_text_sha256']) key: d[key]};
        final outgoing = packet(ref);
        phase = 'client-rejecting-proof';
        expectThat(await refused(() => client.submitCandidate(outgoing)) ==
            AgentBridgeErrorCode.sessionUnconfirmed, 'unproven replacement endpoint must fail closed');
        phase = 'capturing-refused-connection';
        await serverDone.future.timeout(const Duration(seconds: 5));
        final raw = utf8.decode(transcript.toBytes(), allowMalformed: true);
        expectThat(!raw.contains(d['capability'] as String) &&
            !raw.contains(base64Encode(utf8.encode(jsonEncode(outgoing)))) &&
            !raw.contains('SYNTHETIC_CANDIDATE_NOT_ORIGINAL_SOURCE'),
            'wrong endpoint must receive neither the capability nor candidate bytes');
      } finally { await client.close(); }
    } on SocketException catch (error) {
      throw StateError('stale endpoint stage=$phase socket-code=${error.osError?.errorCode}');
    } finally {
      accepted?.destroy(); await fake?.close();
      if (child != null) { child.kill(ProcessSignal.sigkill); await child.exitCode; }
    }
  }));
  cases.finish();
}
