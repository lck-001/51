// B-only background proof-socket tests. Synthetic fixtures; no stdio or player.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_bridge/agent_bridge.dart';
import 'package:agent_bridge/src/framing.dart';
import 'package:agent_bridge/src/private_descriptor.dart';
import 'package:agent_bridge/src/wire.dart'
    show sessionProof, constantBridgeEqual, bridgeFrameMaximum;
import 'package:learning_core/learning_core.dart';

import 'media_ingest_local.dart' as f;
import 'media_wire_local.dart' as w;

void check(bool v, String label) => f.expect(v, label);
Future<Object> error(FutureOr<Object?> Function() action, String label) =>
    w.failure(action, label);
Future<Object?> observe(Future<Object?> future) =>
    future.then<Object?>((v) => v, onError: (Object e) => e);
void isCode(Object? value, AgentBridgeErrorCode code, String label) =>
    check(value is AgentBridgeException && value.code == code, label);
Future<void> eventTurn() =>
    Future<void>(() {}); // Event queue barrier, never a timing sleep.

final class Host {
  final data = f.Fixture();
  late AgentBridgeController controller;
  late AgentBridgeClient client;
  late String descriptorPath;
  late BridgeDescriptor descriptor;
  int abortInvocations = 0;
  Future<void> open({
    bool media = true,
    bool module = true,
    void Function()? onAbort,
    DateTime Function()? clock,
  }) async {
    await data.open();
    final dir = Directory(
      '${data.lock.rootDirectory.path}${Platform.pathSeparator}bridge',
    );
    controller = AgentBridgeController.attach(
      materials: data.probe,
      candidates: data.learning,
      privateDirectory: dir,
      rootLock: data.lock,
      proxyCommand: [Platform.resolvedExecutable],
      integrationId: 'author-fixture',
      mediaIngest: module ? data.ingest : null,
      onMediaAbortInvoked: () {
        abortInvocations++;
        onAbort?.call();
      },
      clock: clock,
    );
    await controller.authorize(
      AgentBridgeGrantRequest(
        materialVersionId: data.binding.materialVersionId,
        allowMediaReceive: media,
      ),
    );
    descriptorPath = '${dir.path}${Platform.pathSeparator}descriptor.json';
    descriptor = await readPrivateDescriptor(descriptorPath);
    client = AgentBridgeClient(descriptorPath: descriptorPath);
  }

  Map<String, Object?> control(String id) => {
    ...w.control(data.binding),
    'upload_id': id,
  };
  Future<({String id, String? receipt, Map<String, Object?> body, int calls})>
  upload({bool seal = true, String delivery = 'wire-fixture'}) async {
    final body = w.packet(data.binding)..['delivery_id'] = delivery;
    final begin = await client.beginMedia(w.beginPacket(body));
    final id = begin['upload_id'] as String;
    var calls = 1;
    for (var offset = 0, index = 0; offset < data.bytes.length; index++) {
      final end = offset + 65536 < data.bytes.length
          ? offset + 65536
          : data.bytes.length;
      final bytes = Uint8List.fromList(data.bytes.sublist(offset, end));
      await client.putMediaChunk({
        ...control(id),
        'index': index,
        'bytes_base64': base64.encode(bytes),
        'chunk_sha256': f.hash(bytes),
      });
      calls++;
      offset = end;
    }
    String? receipt;
    if (seal) {
      receipt =
          (await client.sealMedia(control(id)))['sealed_receipt'] as String;
      calls++;
      body['sealed_receipt'] = receipt;
    }
    return (id: id, receipt: receipt, body: body, calls: calls);
  }

  void pauseMaterial() {
    data.probe.registrationEntered = Completer<void>();
    data.probe.registrationRelease = Completer<void>();
  }

  void releaseMaterial() {
    final release = data.probe.registrationRelease;
    if (release != null && !release.isCompleted) release.complete();
  }

  Future<void> close() async {
    releaseMaterial();
    await client.close();
    try {
      await controller.close();
    } finally {
      await data.close();
    }
  }
}

Uint8List frame(Uint8List json) {
  final result = Uint8List(json.length + 12)
    ..setRange(0, 8, const [0x53, 0x59, 0x42, 0x31, 0, 13, 10, 0]);
  ByteData.sublistView(result).setUint32(8, json.length, Endian.big);
  result.setRange(12, result.length, json);
  return result;
}

Future<Map<String, dynamic>> rawCall(
  BridgeDescriptor descriptor,
  String operation,
  Uint8List raw, {
  String? capability,
  bool outerWhitespace = false,
  String? encodedPayload,
}) async {
  final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        descriptor.port,
      ),
      channel = BridgeFrameChannel(socket, initialMaximum: 512);
  try {
    final challenge = '9' * 64;
    await channel.send({
      'kind': 'hello',
      'session': descriptor.session,
      'challenge': challenge,
    }, maximum: 512);
    final proof = await channel.read(maximum: 512) as Map;
    check(
      proof['kind'] == 'proof' &&
          constantBridgeEqual(
            proof['mac'] as String,
            sessionProof(descriptor, challenge),
          ),
      'real peer proof verified',
    );
    final request = {
      'kind': 'request',
      'session': descriptor.session,
      'challenge': challenge,
      'capability': capability ?? descriptor.capability,
      'operation': operation,
      'payload': encodedPayload ?? base64.encode(raw),
    };
    channel.expectMaximum(bridgeFrameMaximum);
    if (outerWhitespace) {
      final bytes = Uint8List.fromList(
        utf8.encode(' \n${jsonEncode(request)} \n'),
      );
      await channel.sendPreencodedFrame(
        frame(bytes),
        maximum: bridgeFrameMaximum,
        beforeWrite: () {},
      );
    } else {
      await channel.send(request, maximum: bridgeFrameMaximum);
    }
    return await channel.read(maximum: bridgeFrameMaximum)
        as Map<String, dynamic>;
  } finally {
    await channel.close();
  }
}

Future<void> normalAndRawCases() async {
  final h = Host();
  await h.open();
  try {
    check(
      h.descriptor.schemaVersion == 2 &&
          h.descriptor.allowMediaReceive &&
          !h.descriptor.allowSourceRead,
      'explicit descriptor2/media scope independent source',
    );
    final u = await h.upload();
    final sealed = await h.client.sealMedia(h.control(u.id));
    check(
      sealed['sealed_receipt'] == u.receipt && sealed['replayed'] == true,
      'socket seal replay',
    );
    final submitted = await h.client.submitMediaCandidate(u.body),
        again = await h.client.submitMediaCandidate(u.body);
    check(
      again['replayed'] == true &&
          again['candidate_id'] == submitted['candidate_id'],
      'socket submit replay',
    );
    final candidate = (await h.data.learning.listCandidates()).single;
    check(
      candidate.state == LearningCandidateState.pendingReview &&
          candidate.submission.transport == CandidateTransport.localCapability,
      'socket actual pending candidate',
    );
    check(
      candidate.submission.transportPayloadSha256 ==
          f.hash(encodeAgentBridgeJson(u.body, maxBytes: 196608)),
      'Controller actual inner raw context',
    );
    check(
      (await h.data.learning.listVersions()).isEmpty,
      'no confirmed learning version',
    );
    await h.controller.close();
    check(
      h.data.ingest.isBoundTo(
        materials: h.data.probe,
        learning: h.data.learning,
        rootLock: h.data.lock,
      ),
      'Controller borrows module',
    );
    check(
      (await h.data.materials.readVersion(h.data.binding.materialVersionId))
              .text ==
          'Fixture source.',
      'Controller borrows Stores',
    );
    print(
      'PASS socket five-stage actual delivery / replay / raw audit / pending only / borrowed ownership',
    );
  } finally {
    await h.close();
  }
  final g = Host();
  await g.open();
  try {
    final u = await g.upload();
    final plain = encodeAgentBridgeJson(u.body, maxBytes: 196608),
        inner = Uint8List.fromList(utf8.encode(' \n${utf8.decode(plain)} \n'));
    final first = await rawCall(g.descriptor, 'media_submit', inner);
    final second = await rawCall(g.descriptor, 'media_submit', plain);
    final third = await rawCall(
      g.descriptor,
      'media_submit',
      plain,
      outerWhitespace: true,
    );
    check(
      first['ok'] == true && second['ok'] == true && third['ok'] == true,
      'inner and outer real socket variants accepted',
    );
    final a = first['result'] as Map,
        b = second['result'] as Map,
        c = third['result'] as Map;
    check(
      a['candidate_id'] == b['candidate_id'] &&
          b['candidate_id'] == c['candidate_id'] &&
          a['payload_sha256'] == b['payload_sha256'],
      'semantic replay across actual raw variants',
    );
    check(
      (await g.data.learning.listCandidates())
                  .single
                  .submission
                  .transportPayloadSha256 ==
              f.hash(inner) &&
          f.hash(inner) != f.hash(plain),
      'actual inner whitespace raw hash retained, outer does not replace',
    );
    final legacy = await rawCall(
      g.descriptor,
      'candidate_receive',
      w.jsonBytes({
        'schema_version': 1,
        'media': null,
        'material_id': g.data.binding.materialId,
        'material_version_id': g.data.binding.materialVersionId,
        'source_text_sha256': g.data.binding.sourceTextSha256,
      }),
    );
    check(
      legacy['ok'] == false && legacy['error'] == 'unsupportedMedia',
      'legacy media null stays unsupported',
    );
    print(
      'PASS real socket inner/outer raw three vectors / semantic unique / legacy media null protection',
    );
  } finally {
    await g.close();
  }
}

Future<void> defaultAndBindingCases() async {
  final h = Host();
  await h.open(media: false, module: false);
  try {
    check(
      h.descriptor.schemaVersion == 2 &&
          !h.descriptor.allowMediaReceive &&
          !h.controller.current.allowMediaReceive,
      'default media false descriptor2',
    );
    isCode(
      await error(
        () => h.client.beginMedia(w.beginPacket(w.packet(h.data.binding))),
        'default media',
      ),
      AgentBridgeErrorCode.forbidden,
      'Client default denies media',
    );
    final raw = await rawCall(
      h.descriptor,
      'media_begin',
      w.jsonBytes(w.beginPacket(w.packet(h.data.binding))),
    );
    check(
      raw['ok'] == false &&
          raw['error'] == 'forbidden' &&
          h.data.probe.registrations == 0 &&
          (await h.data.learning.listCandidates()).isEmpty,
      'server independently denies media',
    );
    isCode(
      await error(
        () => h.controller.authorize(
          AgentBridgeGrantRequest(
            materialVersionId: h.data.binding.materialVersionId,
            allowMediaReceive: true,
          ),
        ),
        'missing module',
      ),
      AgentBridgeErrorCode.forbidden,
      'module missing refused',
    );
    check(
      !await File(h.descriptorPath).exists(),
      'no new descriptor on missing capability',
    );
    await error(
      () => AgentBridgeController.attach(
        materials: h.data.materials,
        candidates: h.data.learning,
        privateDirectory: Directory('${h.data.root.path}/wrong'),
        rootLock: h.data.lock,
        proxyCommand: [],
        mediaIngest: h.data.ingest,
      ),
      'same owner wrong object',
    );
    print(
      'PASS default scope false / independent server gate / missing module / exact object binding',
    );
  } finally {
    await h.close();
  }
}

Future<void> abortCases() async {
  for (final throwsObserver in [false, true]) {
    final invoked = Completer<void>();
    final h = Host();
    await h.open(
      onAbort: () {
        if (!invoked.isCompleted) invoked.complete();
        if (throwsObserver) throw StateError('synthetic observer throw');
      },
    );
    try {
      final u = await h.upload();
      h.pauseMaterial();
      final submitted = observe(h.client.submitMediaCandidate(u.body));
      await h.data.probe.registrationEntered!.future;
      final aborted = observe(h.client.abortMedia(h.control(u.id)));
      await invoked.future;
      // Barrier is after tracking real abort Future, never a global-busy assertion.
      h.releaseMaterial();
      final s = await submitted, a = await aborted;
      isCode(
        s,
        AgentBridgeErrorCode.outcomeUnknown,
        'abort stops continuation after real Material',
      );
      check(
        a is Map && a['status'] == 'terminal',
        'abort true drain returned terminal',
      );
      check(
        (await h.data.learning.listCandidates()).isEmpty &&
            await h.data.materials.findArtifactRegistration(
                  h.data.operation('wire-fixture'),
                ) !=
                null,
        'registered ref retained, no Learning receive',
      );
      print(
        'PASS authenticated abort bypasses busy / actual Material drain / observerThrow=$throwsObserver',
      );
    } finally {
      await h.close();
    }
  }
  final h = Host();
  await h.open();
  try {
    final u = await h.upload();
    h.pauseMaterial();
    final submitted = observe(h.client.submitMediaCandidate(u.body));
    await h.data.probe.registrationEntered!.future;
    final cap = await rawCall(
      h.descriptor,
      'media_abort',
      w.jsonBytes(h.control(u.id)),
      capability: '0' * 64,
    );
    final source = await rawCall(
      h.descriptor,
      'media_abort',
      w.jsonBytes({...h.control(u.id), 'material_id': 'f' * 32}),
    );
    check(
      cap['error'] == 'forbidden' &&
          source['error'] == 'sourceMismatch' &&
          h.abortInvocations == 0,
      'wrong auth/source do not invoke stop',
    );
    h.releaseMaterial();
    final result = await submitted;
    check(
      result is Map &&
          result['status'] == 'delivered' &&
          (await h.data.learning.listCandidates()).length == 1,
      'wrong abort cannot interrupt valid submit',
    );
    print(
      'PASS wrong capability/source abort never stops a valid in-flight submit',
    );
  } finally {
    await h.close();
  }
}

Future<void> quotaCases() async {
  for (final target in ['submit', 'seal', 'abort']) {
    final h = Host();
    await h.open();
    try {
      final u = await h.upload(seal: target == 'submit');
      for (var calls = u.calls; calls < 63; calls++) {
        await h.client.getSourceReference();
      }
      if (target == 'submit') {
        h.pauseMaterial();
        final pending = observe(h.client.submitMediaCandidate(u.body));
        await h.data.probe.registrationEntered!.future;
        isCode(
          await error(() => h.client.abortMedia(h.control(u.id)), '65th abort'),
          AgentBridgeErrorCode.busy,
          '65th control quota denied',
        );
        check(h.abortInvocations == 0, 'quota refusal not a lease revoke');
        h.releaseMaterial();
        final result = await pending;
        // The one-shot instrumentation belongs only to the paused call.
        h.data.probe.registrationEntered = null;
        h.data.probe.registrationRelease = null;
        check(
          result is Map && result['status'] == 'delivered',
          '64th lease stays valid across actual Store await',
        );
        final original = (await h.data.materials.findArtifactRegistration(
          h.data.operation('wire-fixture'),
        ))!.artifactId;
        await h.controller.revoke();
        await h.controller.authorize(
          AgentBridgeGrantRequest(
            materialVersionId: h.data.binding.materialVersionId,
            allowMediaReceive: true,
          ),
        );
        final begin = await h.client.beginMedia(w.beginPacket(u.body));
        check(
          begin['upload_id'] == u.id && begin['replayed'] == true,
          'new cap same sealed upload',
        );
        final seal = await h.client.sealMedia(h.control(u.id));
        check(seal['sealed_receipt'] == u.receipt, 'new cap same receipt');
        final replay = await h.client.submitMediaCandidate(u.body);
        check(
          replay['replayed'] == true &&
              (await h.data.learning.listCandidates()).length == 1 &&
              (await h.data.materials.findArtifactRegistration(
                    h.data.operation('wire-fixture'),
                  ))!.artifactId ==
                  original,
          'rotation does not create artifact/candidate',
        );
      } else if (target == 'seal') {
        check(
          (await h.client.sealMedia(h.control(u.id)))['status'] == 'sealed',
          '64th seal succeeds',
        );
      } else {
        check(
          (await h.client.abortMedia(h.control(u.id)))['status'] == 'terminal',
          '64th abort succeeds',
        );
      }
      if (target != 'submit')
        isCode(
          await error(() => h.client.getSourceReference(), '65th request'),
          AgentBridgeErrorCode.busy,
          '65th ordinary quota denied',
        );
      print(
        'PASS exact 64th $target / quota lifetime separation / 65th refused',
      );
    } finally {
      await h.close();
    }
  }
}

final class CapturedTimer implements Timer {
  CapturedTimer(this.callback);
  final void Function() callback;
  bool active = true;
  @override
  bool get isActive => active;
  @override
  int get tick => active ? 0 : 1;
  @override
  void cancel() {
    active = false;
  }

  void fire() {
    if (active) {
      active = false;
      callback();
    }
  }
}

Future<void> lifecycleCases() async {
  for (final mode in ['revoke', 'retire', 'close', 'expiry']) {
    var now = DateTime.now().toUtc();
    CapturedTimer? expiry;
    await runZoned(
      () async {
        final h = Host();
        await h.open(clock: () => now);
        try {
          final u = await h.upload();
          h.pauseMaterial();
          final submitted = observe(h.client.submitMediaCandidate(u.body));
          await h.data.probe.registrationEntered!.future;
          final Future<void> stop;
          if (mode == 'revoke') {
            stop = h.controller.revoke();
          } else if (mode == 'retire') {
            h.controller.retire();
            stop = h.controller.close();
          } else if (mode == 'expiry') {
            now = h.descriptor.expiresAtUtc.add(
              const Duration(milliseconds: 1),
            );
            check(expiry != null, 'real 15min callback captured');
            expiry!.fire();
            stop = h.controller.close();
          } else {
            stop = h.controller.close();
          }
          check(
            h.controller.current.phase == AgentBridgePhase.draining,
            '$mode call-stack closed admission',
          );
          var settled = false;
          final observed = stop.then((_) => settled = true);
          await eventTurn();
          check(!settled, '$mode waits actual accepted Material Future');
          h.releaseMaterial();
          await observed;
          await submitted;
          check(
            (await h.data.learning.listCandidates()).isEmpty &&
                await h.data.materials.findArtifactRegistration(
                      h.data.operation('wire-fixture'),
                    ) !=
                    null,
            '$mode preserves registered orphan and stops Learning',
          );
          print(
            'PASS $mode synchronous retire / real Store drain / expired cleanup permission',
          );
        } finally {
          await h.close();
        }
      },
      zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, callback) {
          if (duration == const Duration(minutes: 15))
            return expiry = CapturedTimer(callback);
          return parent.createTimer(zone, duration, callback);
        },
      ),
    );
  }
}

Future<void> failingDrainCase() async {
  final parent = Zone.current;
  var failDescriptor = false;
  late String descriptorPath;
  final failed = Completer<void>(), invoked = Completer<void>();
  await IOOverrides.runZoned(
    () async {
      final h = Host();
      await h.open(
        onAbort: () {
          if (!invoked.isCompleted) invoked.complete();
          throw StateError('synthetic observer');
        },
      );
      descriptorPath = h.descriptorPath;
      try {
        final u = await h.upload();
        h.pauseMaterial();
        final submitted = observe(h.client.submitMediaCandidate(u.body));
        await h.data.probe.registrationEntered!.future;
        final aborted = observe(h.client.abortMedia(h.control(u.id)));
        await invoked.future;
        failDescriptor = true;
        var closed = false;
        final closing = h.controller.close().then<Object?>(
          (_) {
            closed = true;
            return null;
          },
          onError: (Object e) {
            closed = true;
            return e;
          },
        );
        await failed.future;
        await eventTurn();
        check(
          !closed,
          'descriptor cleanup error cannot skip accepted Store/control/retire drain',
        );
        h.releaseMaterial();
        final result = await closing;
        await submitted;
        await aborted;
        isCode(
          result,
          AgentBridgeErrorCode.privateStorageUnavailable,
          'first neutral cleanup error after all settled',
        );
        check(
          (await h.data.learning.listCandidates()).isEmpty &&
              h.controller.current.inFlight == 0,
          'all accepted operations actually settled',
        );
        failDescriptor = false;
        print(
          'PASS synchronous descriptor cleanup fault waits real normal/control/retirement Futures before error',
        );
      } finally {
        failDescriptor = false;
        await h.close();
      }
    },
    fseGetType: (path, follow) {
      if (failDescriptor &&
          path.replaceAll('\\', '/').toLowerCase() ==
              descriptorPath.replaceAll('\\', '/').toLowerCase()) {
        if (!failed.isCompleted) failed.complete();
        throw FileSystemException('synthetic descriptor cleanup fault');
      }
      return parent.run(() => FileSystemEntity.type(path, followLinks: follow));
    },
  );
}

Future<void> main() async {
  await normalAndRawCases();
  await defaultAndBindingCases();
  await abortCases();
  await quotaCases();
  await lifecycleCases();
  await failingDrainCase();
  await controlSlotCase();
  await enteredLearningCommitCase();
  await clientPeerCases();
  await socketDeadlineDoesNotCancelStoreCase();
  await wrongUploadIntegrationCase();
  await twoConnectionAndCanonicalCases();
}

final class Peer {
  Peer(this.mode, {this.holdProof = false});
  final String mode;
  final bool holdProof;
  final data = f.Fixture();
  late ServerSocket server;
  late BridgeDescriptor descriptor;
  late AgentBridgeClient client;
  final hello = Completer<void>(),
      proofRelease = Completer<void>(),
      release = Completer<void>();
  final handlers = <Future<void>>[], channels = <BridgeFrameChannel>[];
  int connections = 0;
  Uint8List? business;
  Future<void> open() async {
    await data.open();
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    descriptor = BridgeDescriptor(
      port: server.port,
      session: '1' * 32,
      capability: '2' * 64,
      proofKey: '3' * 64,
      integrationId: 'author-fixture',
      materialId: data.binding.materialId,
      materialVersionId: data.binding.materialVersionId,
      sourceTextSha256: data.binding.sourceTextSha256,
      expiresAtUtc: DateTime.now().toUtc().add(const Duration(minutes: 15)),
      allowSourceRead: false,
      schemaVersion: 2,
      allowMediaReceive: true,
    );
    final store = PrivateDescriptorStore(
      rootLock: data.lock,
      directory: Directory(
        '${data.lock.rootDirectory.path}${Platform.pathSeparator}peer',
      ),
    );
    await store.write(descriptor);
    client = AgentBridgeClient(descriptorPath: store.path);
    server.listen((socket) {
      connections++;
      final task = handle(socket);
      task.ignore();
      handlers.add(task);
    });
  }

  Future<void> handle(Socket socket) async {
    final c = BridgeFrameChannel(socket, initialMaximum: 512);
    channels.add(c);
    try {
      final h = await c.read(maximum: 512) as Map;
      if (!hello.isCompleted) hello.complete();
      if (holdProof) await proofRelease.future;
      c.expectMaximum(bridgeFrameMaximum);
      await c.send({
        'kind': 'proof',
        'session': descriptor.session,
        'mac': sessionProof(descriptor, h['challenge'] as String),
      }, maximum: 512);
      final request = await c.read(maximum: bridgeFrameMaximum) as Map;
      business = decodeCanonicalBridgeBase64(
        request['payload'] as String,
        maximumBytes: 196608,
      );
      if (mode == 'disconnect') {
        c.destroy();
      } else if (mode == 'badAck') {
        await c.send({
          'ok': true,
          'result': {'unexpected': true},
        }, maximum: 512);
      } else if (mode == 'unknownCode') {
        await c.send({
          'ok': false,
          'error': 'future_unknown_code',
        }, maximum: 512);
      } else if (mode == 'invalidJson') {
        await c.sendPreencodedFrame(
          frame(Uint8List.fromList(utf8.encode('{'))),
          maximum: 512,
          beforeWrite: () {},
        );
      } else if (mode == 'timeout') {
        await release.future;
      } else if (mode == 'goodSubmitHash' || mode == 'wrongSubmitHash') {
        final input = decodeMediaBridgePayload(
          'media_submit',
          business!,
        ) as MediaWireSubmit;
        final actual = input.submission.media.submissionSha256;
        check(
          actual != '0' * 64,
          'negative vector hash differs from actual semantic input',
        );
        await c.send({
          'ok': true,
          'result': {
            'candidate_id': 'e' * 32,
            'payload_sha256': mode == 'goodSubmitHash' ? actual : '0' * 64,
            'status': 'delivered',
            'replayed': false,
          },
        }, maximum: 512);
      } else if (mode == 'goodBegin') {
        await c.send({
          'ok': true,
          'result': {
            'upload_id': 'e' * 32,
            'raw_chunk_bytes': 65536,
            'next_index': 0,
            'status': 'receiving',
            'replayed': false,
          },
        }, maximum: 512);
      }
    } on AgentBridgeException {
      /* Peer EOF is expected for pre-encoded rejection. */
    } finally {
      await c.close();
      channels.remove(c);
    }
  }

  Map<String, Object?> payload(MediaWireOperation op) {
    final submit = w.packet(data.binding), control = w.control(data.binding);
    return switch (op) {
      MediaWireOperation.begin => w.beginPacket(submit),
      MediaWireOperation.chunk => {
        ...control,
        'index': 0,
        'bytes_base64': base64.encode(Uint8List(65536)),
        'chunk_sha256': f.hash(Uint8List(65536)),
      },
      MediaWireOperation.submit => submit,
      _ => control,
    };
  }

  Future<Map<String, Object?>> call(
    MediaWireOperation op,
    Map<String, Object?> body,
  ) => switch (op) {
    MediaWireOperation.begin => client.beginMedia(body),
    MediaWireOperation.chunk => client.putMediaChunk(body),
    MediaWireOperation.seal => client.sealMedia(body),
    MediaWireOperation.submit => client.submitMediaCandidate(body),
    MediaWireOperation.abort => client.abortMedia(body),
  };
  Future<void> close() async {
    if (!proofRelease.isCompleted) proofRelease.complete();
    if (!release.isCompleted) release.complete();
    await client.close();
    await server.close();
    for (final c in channels.toList()) {
      await c.close();
    }
    await Future.wait(handlers);
    await data.close();
  }
}

Future<void> clientPeerCases() async {
  for (final good in [true, false]) {
    final p = Peer(good ? 'goodSubmitHash' : 'wrongSubmitHash');
    await p.open();
    try {
      final body = p.payload(MediaWireOperation.submit);
      if (good) {
        final result = await p.client.submitMediaCandidate(body);
        final expected = (decodeMediaBridgePayload(
          'media_submit',
          p.business!,
        ) as MediaWireSubmit).submission.media.submissionSha256;
        check(
          result['payload_sha256'] == expected &&
              result['status'] == 'delivered',
          'real peer positive semantic binding',
        );
      } else {
        isCode(
          await error(
            () => p.client.submitMediaCandidate(body),
            'wrong valid semantic hash',
          ),
          AgentBridgeErrorCode.outcomeUnknown,
          'legal hex wrong semantic ACK is unknown',
        );
      }
      check(
        p.business != null && p.connections == 1,
        'hash ACK checked after one real authenticated request',
      );
      print(
        'PASS media submit semantic ACK binding real proof peer correctHash=$good',
      );
    } finally {
      await p.close();
    }
  }
  for (final mode in ['disconnect', 'badAck', 'unknownCode', 'invalidJson']) {
    for (final op in MediaWireOperation.values) {
      final p = Peer(mode);
      await p.open();
      try {
        final outcome = await error(
          () => p.call(op, p.payload(op)),
          '$mode ${op.name}',
        );
        isCode(
          outcome,
          AgentBridgeErrorCode.outcomeUnknown,
          'every sent mutation $mode ${op.name} is unknown',
        );
        check(
          p.business != null &&
              p.connections == 1 &&
              p.data.probe.registrations == 0,
          'actual proof request sent once, no retry/Store bypass',
        );
      } finally {
        await p.close();
      }
    }
    print(
      'PASS Client all five mutation $mode cases after real proof are outcomeUnknown / one connection',
    );
  }
  // Independent task-owned peers, each one connection; actual 5s deadline, not a sleep/cancel substitute.
  await Future.wait(
    MediaWireOperation.values.map((op) async {
      final p = Peer('timeout');
      await p.open();
      try {
        isCode(
          await error(() => p.call(op, p.payload(op)), 'timeout ${op.name}'),
          AgentBridgeErrorCode.outcomeUnknown,
          'all five actual deadlines unknown',
        );
        check(
          p.business != null && p.connections == 1,
          'timeout had one real business frame',
        );
      } finally {
        await p.close();
      }
    }),
  );
  print(
    'PASS Client all five mutation actual socket deadlines unknown / no automatic retry',
  );
  final p = Peer('goodBegin', holdProof: true);
  await p.open();
  try {
    final body = p.payload(MediaWireOperation.begin),
        original = body['material_id'];
    final call = p.client.beginMedia(body);
    await p.hello.future;
    body['material_id'] = 'f' * 32;
    body['delivery_id'] = 'mutated-after-entry';
    p.proofRelease.complete();
    await call;
    final received =
        decodeAgentBridgeJson(p.business!, maxBytes: 196608) as Map;
    check(
      received['material_id'] == original &&
          received['delivery_id'] == 'wire-fixture',
      'private stable snapshot survives caller mutation across proof await',
    );
    print(
      'PASS Client stable business snapshot across awaited proof / caller Map mutation',
    );
  } finally {
    await p.close();
  }
  final q = Peer('noBusiness');
  await q.open();
  try {
    final base = w.packet(
      q.data.binding,
      english: '\\' * 97000,
      translation: 'x',
      notes: '',
    );
    final amount =
        196411 - encodeAgentBridgeJson(base, maxBytes: 196608).length;
    final tooLarge = w.packet(
      q.data.binding,
      english: '\\' * 97000,
      translation: 'x',
      notes: 'n' * amount,
    );
    check(
      encodeAgentBridgeJson(tooLarge, maxBytes: 196608).length == 196411,
      'known actual inner byte budget',
    );
    isCode(
      await error(
        () => q.client.submitMediaCandidate(tooLarge),
        'outer overflow',
      ),
      AgentBridgeErrorCode.tooLarge,
      'complete pre-encoding overflow is known local failure',
    );
    check(
      q.hello.isCompleted && q.business == null && q.connections == 1,
      'proof completed but zero business frame written',
    );
    print(
      'PASS actual outer envelope overflow before businessStarted / proof only / no sent mutation',
    );
  } finally {
    await q.close();
  }
}

Future<void> controlSlotCase() async {
  final invoked = Completer<void>();
  final h = Host();
  await h.open(
    onAbort: () {
      if (!invoked.isCompleted) invoked.complete();
    },
  );
  try {
    final u = await h.upload();
    h.pauseMaterial();
    // Trusted in-process C1 activity makes control wait without using a third socket.
    final decoded = decodeMediaBridgePayload(
      'media_submit',
      w.jsonBytes(u.body),
    ) as MediaWireSubmit;
    final direct = observe(
      h.data.ingest.submit(
        h.data.grant,
        h.data.binding,
        u.receipt!,
        decoded.submission,
      ),
    );
    await h.data.probe.registrationEntered!.future;
    final first = observe(h.client.abortMedia(h.control(u.id)));
    await invoked.future;
    isCode(
      await error(() => h.client.abortMedia(h.control(u.id)), 'second control'),
      AgentBridgeErrorCode.busy,
      'one control slot has no queue',
    );
    check(
      h.abortInvocations == 1 && h.controller.current.inFlight == 1,
      'only one actual control admitted',
    );
    h.releaseMaterial();
    await direct;
    final result = await first;
    check(
      result is Map &&
          result['status'] == 'terminal' &&
          (await h.data.learning.listCandidates()).isEmpty,
      'first control actually drained original real Store',
    );
    print(
      'PASS one control slot bounded / second control busy with two real sockets / no queued stop',
    );
  } finally {
    await h.close();
  }
}

Future<void> socketDeadlineDoesNotCancelStoreCase() async {
  final h = Host();
  await h.open();
  try {
    final u = await h.upload();
    h.pauseMaterial();
    final pending = observe(h.client.submitMediaCandidate(u.body));
    await h.data.probe.registrationEntered!.future;
    isCode(
      await pending,
      AgentBridgeErrorCode.outcomeUnknown,
      'real Controller 5s timeout unknown',
    );
    check(
      !h.data.probe.registrationRelease!.isCompleted &&
          h.controller.current.inFlight == 1,
      'Store future remains tracked after socket deadline',
    );
    final settled = h.controller.snapshots.firstWhere(
      (s) => s.inFlight == 0 && s.lastCandidateId != null,
    );
    h.releaseMaterial();
    await settled;
    check(
      (await h.data.learning.listCandidates()).length == 1,
      'real Store may complete after deadline, not cancelled',
    );
    print(
      'PASS real Controller socket deadline leaves actual Store Future alive / eventual candidate retained',
    );
  } finally {
    await h.close();
  }
}

final class PausingRenameFile implements File {
  PausingRenameFile(this.real, this.entered, this.release);
  final File real;
  final Completer<void> entered, release;
  @override
  String get path => real.path;
  @override
  Future<String> readAsString({Encoding encoding = utf8}) =>
      real.readAsString(encoding: encoding);
  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) => real.writeAsString(
    contents,
    mode: mode,
    encoding: encoding,
    flush: flush,
  );
  @override
  Future<File> rename(String destination) async {
    final result = await real.rename(destination);
    if (destination.replaceAll('\\', '/').endsWith('/learning.json')) {
      if (!entered.isCompleted) entered.complete();
      await release.future;
    }
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unused file probe ${invocation.memberName}');
}

Future<void> enteredLearningCommitCase() async {
  final parent = Zone.current;
  var active = false;
  final entered = Completer<void>(),
      release = Completer<void>(),
      abortInvoked = Completer<void>();
  await IOOverrides.runZoned(
    () async {
      final h = Host();
      await h.open(
        onAbort: () {
          if (!abortInvoked.isCompleted) abortInvoked.complete();
        },
      );
      try {
        final u = await h.upload();
        active = true;
        final submitted = observe(h.client.submitMediaCandidate(u.body));
        await entered.future;
        final aborted = observe(h.client.abortMedia(h.control(u.id)));
        await abortInvoked.future;
        release.complete();
        final s = await submitted, a = await aborted;
        isCode(
          s,
          AgentBridgeErrorCode.outcomeUnknown,
          'already entered Learning commit may finish after stop',
        );
        check(
          a is Map &&
              a['status'] == 'terminal' &&
              (await h.data.learning.listCandidates()).length == 1,
          'terminal never claims Learning rollback',
        );
        print(
          'PASS actual Learning primary rename then paused response / abort permits committed candidate',
        );
      } finally {
        active = false;
        if (!release.isCompleted) release.complete();
        await h.close();
      }
    },
    createFile: (path) {
      final real = parent.run(() => File(path));
      return active && path.replaceAll('\\', '/').endsWith('/learning.next')
          ? PausingRenameFile(real, entered, release)
          : real;
    },
  );
}

Future<void> wrongUploadIntegrationCase() async {
  final h = Host();
  await h.open();
  try {
    final manifest = (decodeMediaBridgePayload(
      'media_begin',
      w.jsonBytes(w.beginPacket(w.packet(h.data.binding))),
    ) as MediaWireBegin).manifest;
    final foreign = MediaIngestGrant(
      ownerId: 'author',
      integrationId: 'foreign-integration',
      binding: h.data.binding,
      allowMedia: true,
      isValid: () => true,
    );
    final begin = await h.data.ingest.begin(foreign, manifest);
    isCode(
      await error(
        () => h.client.abortMedia(h.control(begin.uploadId)),
        'wrong upload integration',
      ),
      AgentBridgeErrorCode.forbidden,
      'C1 rejects foreign upload before stop',
    );
    final bytes = Uint8List.fromList(h.data.bytes.sublist(0, 65536));
    check(
      (await h.data.ingest.chunk(
            foreign,
            h.data.binding,
            begin.uploadId,
            0,
            bytes,
            f.hash(bytes),
          )).acceptedBytes ==
          65536,
      'foreign trusted upload still receiving after unauthorized abort',
    );
    await h.data.ingest.abort(foreign, h.data.binding, begin.uploadId);
    check(
      h.data.probe.registrations == 0,
      'wrong integration never enters registration',
    );
    print(
      'PASS real C1 upload integration binding rejects authenticated wrong upload before stop',
    );
  } finally {
    await h.close();
  }
}

Future<void> twoConnectionAndCanonicalCases() async {
  final h = Host();
  await h.open();
  final held = <BridgeFrameChannel>[];
  try {
    final raw = w.jsonBytes(w.beginPacket(w.packet(h.data.binding)));
    final bad = await rawCall(
      h.descriptor,
      'media_begin',
      raw,
      encodedPayload: '${base64.encode(raw)}\n',
    );
    check(
      bad['ok'] == false &&
          bad['error'] == 'invalidRequest' &&
          h.data.probe.registrations == 0,
      'server rejects noncanonical outer base64 before module',
    );
    for (var i = 0; i < 2; i++) {
      final socket = await Socket.connect(
            InternetAddress.loopbackIPv4,
            h.descriptor.port,
          ),
          channel = BridgeFrameChannel(socket, initialMaximum: 512);
      held.add(channel);
      final challenge = (i == 0 ? '8' : '9') * 64;
      await channel.send({
        'kind': 'hello',
        'session': h.descriptor.session,
        'challenge': challenge,
      }, maximum: 512);
      final proof = await channel.read(maximum: 512) as Map;
      check(
        proof['mac'] == sessionProof(h.descriptor, challenge),
        'two held connections actually passed proof',
      );
    }
    isCode(
      await error(() => h.client.getSourceReference(), 'third connection'),
      AgentBridgeErrorCode.sessionUnconfirmed,
      'third connection not admitted',
    );
    check(
      h.controller.current.inFlight == 0 && h.data.probe.registrations == 0,
      'no business operation accepted by held proofs',
    );
    print(
      'PASS server canonical outer base64 rejection / exactly two proven connections / third rejected',
    );
  } finally {
    for (final channel in held) {
      await channel.close();
    }
    await h.close();
  }
}
