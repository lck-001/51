// C2-A pure codec and real synthetic Store contract checks; no socket or tools.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_bridge/agent_bridge.dart';
import 'package:agent_bridge/src/private_descriptor.dart';
import 'package:agent_bridge/src/wire.dart' show candidateInput;
import 'package:learning_core/learning_core.dart';
import 'package:material_core/material_core.dart';

import 'media_ingest_local.dart' as fixture;

void check(bool v, String label) => fixture.expect(v, label);
Uint8List jsonBytes(Object? value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));
Map<String, Object?> clone(Map<String, Object?> value) =>
    Map<String, Object?>.from(jsonDecode(jsonEncode(value)) as Map);
Future<Object> failure(
  FutureOr<Object?> Function() action,
  String label,
) async {
  try {
    await action();
  } catch (error) {
    return error;
  }
  throw StateError('Expected failure: $label');
}

Future<void> invalid(FutureOr<Object?> Function() action, String label) async {
  final e = await failure(action, label);
  check(e is AgentBridgeException, '$label has typed wire error');
}

const dec = {'preparation': 'synthetic PCM', 'provider': 'fixture'};
Map<String, Object?> packet(
  MediaIngestSourceBinding b, {
  String english = 'Hello fixture.',
  String translation = '合成结构测试。',
  String? notes,
}) {
  final bytes = fixture.syntheticWave();
  return {
    'schema_version': 2,
    'material_id': b.materialId,
    'material_version_id': b.materialVersionId,
    'source_text_sha256': b.sourceTextSha256,
    'delivery_id': 'wire-fixture',
    'sentences': [
      {'english': english, 'translation': translation},
    ],
    'declaration': {
      'preparation': 'synthetic text',
      'provider': 'author',
      if (notes != null) 'notes': notes,
    },
    'media': {
      'sha256': fixture.hash(bytes),
      'byte_length': bytes.length,
      'english_sha256': fixture.hash(jsonBytes([english])),
      'pcm': {
        'format': 1,
        'channels': 1,
        'sample_rate': 16000,
        'bits_per_sample': 16,
      },
      'timings': [
        {'sentence_index': 0, 'start_ms': 0, 'end_ms': 5000},
      ],
      'declaration': dec,
      'timing_declaration': 'Synthetic structural timing',
    },
    'sealed_receipt': 'd' * 64,
  };
}

Map<String, Object?> beginPacket(Map<String, Object?> submission) {
  final dto = decodeMediaBridgePayload(
    'media_submit',
    jsonBytes(submission),
  ) as MediaWireSubmit;
  final media = Map<String, Object?>.from(submission['media'] as Map)
    ..remove('english_sha256');
  return {
    'schema_version': 2,
    'material_id': submission['material_id'],
    'material_version_id': submission['material_version_id'],
    'source_text_sha256': submission['source_text_sha256'],
    'delivery_id': submission['delivery_id'],
    'submission_sha256': dto.submission.media.submissionSha256,
    'english_sha256': (submission['media'] as Map)['english_sha256'],
    'media': media,
  };
}

Map<String, Object?> control(MediaIngestSourceBinding b) => {
  'schema_version': 2,
  'material_id': b.materialId,
  'material_version_id': b.materialVersionId,
  'source_text_sha256': b.sourceTextSha256,
  'upload_id': 'e' * 32,
};
Future<void> codecCases() async {
  final bind = MediaIngestSourceBinding(
    materialId: 'a' * 32,
    materialVersionId: 'b' * 32,
    sourceTextSha256: 'c' * 64,
  );
  final submit = packet(bind), begin = beginPacket(packet(bind));
  check(
    decodeMediaBridgePayload('media_begin', jsonBytes(begin)) is MediaWireBegin,
    'manifest-only begin',
  );
  final full = decodeMediaBridgePayload(
    'media_submit',
    jsonBytes(submit),
  ) as MediaWireSubmit;
  check(
    full.submission.media.submissionSha256 == begin['submission_sha256'],
    'full submit actual B2B semantic commitment',
  );
  check(
    full.submission.declaration.preparation !=
        full.submission.media.declaration.preparation,
    'text/audio declaration independent',
  );
  check(
    decodeMediaBridgePayload('media_seal', jsonBytes(control(bind)))
        is MediaWireSeal,
    'seal DTO',
  );
  check(
    decodeMediaBridgePayload('media_abort', jsonBytes(control(bind)))
        is MediaWireAbort,
    'abort DTO',
  );
  final raw = Uint8List(65536),
      chunk = {
        ...control(bind),
        'index': 31,
        'bytes_base64': base64.encode(raw),
        'chunk_sha256': fixture.hash(raw),
      };
  final dto = decodeMediaBridgePayload(
    'media_chunk',
    jsonBytes(chunk),
  ) as MediaWireChunk;
  check(dto.bytes.length == 65536 && dto.index == 31, '64KiB bounded chunk');
  await failure(() => dto.bytes[0] = 1, 'DTO bytes immutable');
  for (final e in {
    'owner': 'forged',
    'integration_id': 'forged',
    'capability': 'forged',
    'epoch': 1,
    'trustedCallerContext': {},
    'transport_payload_sha256': 'f' * 64,
    'path': 'file',
    'url': 'https://invalid.test',
    'artifact_id': 'f' * 32,
  }.entries) {
    for (final operation in MediaWireOperation.values) {
      final original = switch (operation) {
        MediaWireOperation.begin => begin,
        MediaWireOperation.submit => submit,
        MediaWireOperation.chunk => chunk,
        _ => control(bind),
      };
      await invalid(
        () => decodeMediaBridgePayload(
          operation.wireName,
          jsonBytes({...original, e.key: e.value}),
        ),
        'unknown authority field ${e.key} ${operation.name}',
      );
    }
  }
  for (final change in <void Function(Map<String, Object?>)>[
    (m) => m['schema_version'] = 2.0,
    (m) => m['schema_version'] = true,
    (m) => m['schema_version'] = 1,
    (m) => m['media'] = null,
    (m) => (m['media'] as Map)['english_sha256'] = 'f' * 64,
    (m) => (m['media'] as Map)['path'] = 'x',
    (m) => ((m['media'] as Map)['pcm'] as Map)['sample_rate'] = 16000.0,
    (m) => (((m['media'] as Map)['timings'] as List).first as Map)['start_ms'] =
        true,
    (m) => (m['declaration'] as Map)['unexpected'] = 'x',
    (m) => m['declaration'] = {'preparation': ''},
    (m) =>
        (m['sentences'] as List)[0] = {'english': '\ud800', 'translation': 'x'},
    (m) => m['submission_sha256'] = 'f' * 64,
  ]) {
    final bad = clone(submit);
    change(bad);
    await invalid(
      () => decodeMediaBridgePayload('media_submit', jsonBytes(bad)),
      'strict nested shape/type',
    );
  }
  await invalid(
    () => decodeMediaBridgePayload(
      'media_begin',
      jsonBytes({...begin, 'sentences': []}),
    ),
    'begin has no body',
  );
  final duplicate = Uint8List.fromList(
    utf8.encode(
      utf8
          .decode(jsonBytes(control(bind)))
          .replaceFirst('{', '{"schema_version":2,'),
    ),
  );
  await invalid(
    () => decodeMediaBridgePayload('media_abort', duplicate),
    'duplicate key',
  );
  await invalid(
    () => decodeMediaBridgePayload('media_unknown', jsonBytes(begin)),
    'unknown action',
  );
  print(
    'PASS five DTOs / manifest-only / strict nested shape / Unicode / no body authority',
  );
  for (final bad in [
    'AA=',
    'AA===',
    'AB==',
    'AA==\n',
    '_w==',
    '/w',
    '%2Fw==',
    ' A A==',
    'AA==AA==',
  ]) {
    await invalid(
      () => decodeCanonicalBridgeBase64(bad, maximumBytes: 65536),
      'canonical base64 $bad',
    );
  }
  check(
    decodeCanonicalBridgeBase64('AA==', maximumBytes: 1).length == 1,
    'canonical base64 accepted',
  );
  await invalid(
    () => decodeCanonicalBridgeBase64(
      base64.encode(Uint8List(65537)),
      maximumBytes: 65536,
    ),
    'chunk limit+1',
  );
  await invalid(
    () => decodeMediaBridgePayload(
      'media_chunk',
      jsonBytes({...chunk, 'index': 32}),
    ),
    'chunk index32',
  );
  await invalid(
    () => decodeMediaBridgePayload(
      'media_chunk',
      jsonBytes({...chunk, 'index': 1.0}),
    ),
    'chunk float index',
  );
  await invalid(
    () => decodeMediaBridgePayload(
      'media_chunk',
      jsonBytes({...chunk, 'chunk_sha256': '0' * 64}),
    ),
    'actual chunk hash',
  );
  final encoded = encodeMediaBridgeRequest(
    operation: MediaWireOperation.chunk,
    payload: chunk,
    session: '1' * 32,
    challenge: '2' * 64,
    capability: '3' * 64,
  );
  check(
    encoded.frame.length == encoded.requestJson.length + 12,
    'full frame+12',
  );
  check(
    ByteData.sublistView(encoded.frame).getUint32(8, Endian.big) ==
        encoded.requestJson.length,
    'frame declared actual length',
  );
  final outer = jsonDecode(utf8.decode(encoded.requestJson)) as Map;
  check(
    fixture.hash(
          decodeCanonicalBridgeBase64(
            outer['payload'] as String,
            maximumBytes: 196608,
          ),
        ) ==
        fixture.hash(encoded.businessJson),
    'outer exact business bytes',
  );
  final mcp = encodeMediaMcpCall(
    id: 'request-id',
    operation: MediaWireOperation.chunk,
    payload: chunk,
  );
  check(
    mcp.last == 10 &&
        (jsonDecode(utf8.decode(mcp.sublist(0, mcp.length - 1)))
                as Map)['method'] ==
            'tools/call',
    'actual MCP envelope + LF',
  );
  print(
    'PASS canonical base64 / actual chunk SHA / immutable bytes / full encoders',
  );
  print(
    'VECTOR raw=${raw.length} business=${encoded.businessJson.length} request=${encoded.requestJson.length} frame=${encoded.frame.length} mcp_with_lf=${mcp.length}',
  );
  // A one-byte change in declaration padding locates the true outer-envelope edge.
  Map<String, Object?> large(int padding) => packet(
    bind,
    english: '\\' * 97000,
    translation: 'x',
    notes: 'n' * padding,
  );
  var low = 0, high = 8000;
  while (low < high) {
    final mid = (low + high + 1) ~/ 2;
    try {
      encodeMediaBridgeRequest(
        operation: MediaWireOperation.submit,
        payload: large(mid),
        session: '1' * 32,
        challenge: '2' * 64,
        capability: '3' * 64,
      );
      low = mid;
    } on AgentBridgeException catch (e) {
      check(e.code == AgentBridgeErrorCode.tooLarge, 'limit error known');
      high = mid - 1;
    }
  }
  final edge = encodeMediaBridgeRequest(
    operation: MediaWireOperation.submit,
    payload: large(low),
    session: '1' * 32,
    challenge: '2' * 64,
    capability: '3' * 64,
  );
  check(
    edge.businessJson.length <= 196608 && edge.requestJson.length <= 262144,
    'both actual budgets',
  );
  final next = jsonBytes(large(low + 1));
  final previous = encodeMediaBridgeRequest(
    operation: MediaWireOperation.submit,
    payload: large(low - 1),
    session: '1' * 32,
    challenge: '2' * 64,
    capability: '3' * 64,
  );
  // Diagnostic-only measurement of the rejected envelope. Product encoder
  // still enforces 262144; this does not send data or raise a product limit.
  final rejectedEnvelope = encodeAgentBridgeJson({
    'kind': 'request',
    'session': '1' * 32,
    'challenge': '2' * 64,
    'capability': '3' * 64,
    'operation': 'media_submit',
    'payload': base64.encode(next),
  }, maxBytes: 512 * 1024);
  check(
    previous.businessJson.length + 1 == edge.businessJson.length &&
        next.length == edge.businessJson.length + 1 &&
        rejectedEnvelope.length > 262144,
    'actual inner threshold minus/equal/plus one',
  );
  check(
    next.length <= 196608,
    'next valid inner budget still below outer ceiling',
  );
  await invalid(
    () => encodeMediaBridgeRequest(
      operation: MediaWireOperation.submit,
      payload: large(low + 1),
      session: '1' * 32,
      challenge: '2' * 64,
      capability: '3' * 64,
    ),
    'actual envelope threshold+1 inner byte',
  );
  print(
    'PASS actual outer threshold minus/equal/plus one actual bytes and product rejection',
  );
  print(
    'VECTOR threshold_minus1 business=${previous.businessJson.length} request=${previous.requestJson.length} frame=${previous.frame.length}',
  );
  print(
    'VECTOR threshold_edge business=${edge.businessJson.length} request=${edge.requestJson.length} frame=${edge.frame.length}',
  );
  print(
    'VECTOR threshold_plus1 business=${next.length} request=${rejectedEnvelope.length} frame=${rejectedEnvelope.length + 12} product_rejected=true',
  );
  // Original v1 decoder continues rejecting explicit media, even null.
  for (final field in [
    'media',
    'audio',
    'timings',
    'artifacts',
    'media_sha256',
  ]) {
    await invalid(
      () => candidateInput({'schema_version': 1, field: null}),
      'v1 $field remains rejected',
    );
  }
  print('PASS v1 media-presence protection unchanged');
}

BridgeDescriptor descriptor({int version = 1, bool media = false}) =>
    BridgeDescriptor(
      port: 12345,
      session: '1' * 32,
      capability: '2' * 64,
      proofKey: '3' * 64,
      integrationId: 'test-integration',
      materialId: 'a' * 32,
      materialVersionId: 'b' * 32,
      sourceTextSha256: 'c' * 64,
      expiresAtUtc: DateTime.utc(2027),
      allowSourceRead: false,
      schemaVersion: version,
      allowMediaReceive: media,
    );
Future<void> descriptorCases() async {
  final one = descriptor().toJson(),
      two = descriptor(version: 2, media: true).toJson();
  check(
    !one.containsKey('allow_media_receive') &&
        !BridgeDescriptor.parse(jsonDecode(jsonEncode(one))).allowMediaReceive,
    'strict v1 defaults media false',
  );
  check(
    BridgeDescriptor.parse(jsonDecode(jsonEncode(two))).allowMediaReceive,
    'strict v2 explicit true',
  );
  check(
    !BridgeDescriptor.parse(
      jsonDecode(jsonEncode(descriptor(version: 2).toJson())),
    ).allowMediaReceive,
    'v2 boolean defaults false',
  );
  for (final m in <Map<String, Object?>>[
    {...one, 'allow_media_receive': false},
    Map<String, Object?>.from(two)..remove('allow_media_receive'),
    {...two, 'allow_media_receive': null},
    {...two, 'allow_media_receive': 1},
    {...two, 'schema_version': 2.0},
    {...two, 'schema_version': 3},
    {...two, 'schema_version': true},
    {...two, 'owner': 'forged'},
  ]) {
    await invalid(
      () => BridgeDescriptor.parse(jsonDecode(jsonEncode(m))),
      'strict descriptor versions and flags',
    );
  }
  await invalid(
    () => descriptor(version: 1, media: true),
    'v1 cannot silently enable media',
  );
  print(
    'PASS descriptor strict1/2 / missing-null-type flags / default false / no Controller changes',
  );
}

Future<void> storeContextCases() async {
  final f = fixture.Fixture();
  await f.open();
  try {
    check(
      f.ingest.isBoundTo(
        materials: f.probe,
        learning: f.learning,
        rootLock: f.lock,
      ),
      'binding exact real objects',
    );
    check(
      !f.ingest.isBoundTo(
        materials: f.materials,
        learning: f.learning,
        rootLock: f.lock,
      ),
      'same underlying owner but different object rejected',
    );
    final body = packet(f.binding),
        pre = decodeMediaBridgePayload(
          'media_submit',
          jsonBytes(body),
        ) as MediaWireSubmit;
    final receipt = await f.upload(pre.submission.media);
    body['sealed_receipt'] = receipt;
    final raw = Uint8List.fromList(utf8.encode(' \n${jsonEncode(body)}\n '));
    final decoded =
        decodeMediaBridgePayload('media_submit', raw) as MediaWireSubmit;
    final context = MediaIngestCallerContext.authenticatedBusinessBytes(raw);
    final plain = jsonBytes(body),
        plainDecoded =
            decodeMediaBridgePayload('media_submit', plain) as MediaWireSubmit;
    check(
      context.actualBusinessBytesSha256 == fixture.hash(raw) &&
          fixture.hash(raw) != fixture.hash(plain),
      'actual raw not reencoded SHA',
    );
    check(
      decoded.submission.media.submissionSha256 ==
          plainDecoded.submission.media.submissionSha256,
      'inner whitespace semantic hash stable',
    );
    check(
      context.actualBusinessBytesSha256 !=
          decoded.submission.media.submissionSha256,
      'semantic not raw hash',
    );
    final result = await f.ingest.submit(
      f.grant,
      f.binding,
      receipt,
      decoded.submission,
      trustedCallerContext: context,
    );
    final original = (await f.learning.listCandidates()).single;
    check(
      original.submission.transport == CandidateTransport.localCapability &&
          original.submission.transportPayloadSha256 == fixture.hash(raw),
      'real persisted trusted caller audit',
    );
    final repeated = await f.ingest.submit(
      f.grant,
      f.binding,
      receipt,
      plainDecoded.submission,
      trustedCallerContext: MediaIngestCallerContext.authenticatedBusinessBytes(
        plain,
      ),
    );
    check(
      repeated.replayed && repeated.candidateId == result.candidateId,
      'semantic replay original candidate',
    );
    check(
      (await f.learning.listCandidates())
              .single
              .submission
              .transportPayloadSha256 ==
          fixture.hash(raw),
      'replay does not replace first audit',
    );
    final outer1 = {'payload': base64.encode(raw)},
        outer2 = jsonDecode(' \n${jsonEncode(outer1)} \n') as Map;
    check(
      fixture.hash(
            decodeCanonicalBridgeBase64(
              outer2['payload'] as String,
              maximumBytes: 196608,
            ),
          ) ==
          fixture.hash(raw),
      'outer whitespace leaves business bytes hash unchanged',
    );
    print(
      'PASS trusted caller actual raw SHA / semantic replay / audit retained / exact Store binding',
    );
  } finally {
    await f.close();
  }
  final g = fixture.Fixture();
  await g.open();
  try {
    final b = g.input('default-context');
    final receipt = await g.upload(b);
    await g.ingest.submit(g.grant, g.binding, receipt, g.submission(b));
    final candidate = (await g.learning.listCandidates()).single;
    check(
      candidate.submission.transport == CandidateTransport.controlledTest &&
          candidate.submission.transportPayloadSha256 == null,
      'default controlledTest still honest',
    );
    print(
      'PASS no caller context remains controlledTest without synthetic raw hash',
    );
  } finally {
    await g.close();
  }
}

Future<void> certaintyCases() async {
  final f = fixture.Fixture();
  await f.open();
  try {
    final b = f.input('certainty');
    final receipt = await f.upload(b);
    final id = (await f.ingest.begin(f.grant, b)).uploadId;
    final before = fixture.hash(
      await File('${f.root.path}/ingest/$id/media.part').readAsBytes(),
    );
    final bad = MediaIngestSubmission(
      binding: f.binding,
      deliveryId: b.deliveryId,
      sentences: f.sentences,
      declaration: const SourceDeclaration(preparation: ''),
      media: b,
    );
    final rejected = await failure(
      () => f.ingest.submit(f.grant, f.binding, receipt, bad),
      'known invalid before once',
    );
    check(
      rejected is MediaIngestFailure &&
          rejected.execution == MediaIngestExecution.notAttempted &&
          rejected.code == MediaIngestErrorCode.invalidRequest,
      'typed known preflight rejection',
    );
    check(
      f.probe.registrations == 0 &&
          before ==
              fixture.hash(
                await File('${f.root.path}/ingest/$id/media.part')
                    .readAsBytes(),
              ),
      'preflight retains real file and once0 facts',
    );
    f.probe.registrationEntered = Completer<void>();
    f.probe.registrationRelease = Completer<void>();
    final pending = f.ingest.submit(
      f.grant,
      f.binding,
      receipt,
      f.submission(b),
    );
    final observed = pending.then<Object?>((v) => v, onError: (Object e) => e);
    await f.probe.registrationEntered!.future;
    final busy = await failure(
      () => f.ingest.seal(f.grant, f.binding, id),
      'concurrent busy',
    );
    check(
      busy is MediaIngestFailure &&
          busy.code == MediaIngestErrorCode.busy &&
          busy.execution == MediaIngestExecution.notAttempted,
      'independent attempts do not share durable flag',
    );
    final stop = f.ingest.abort(f.grant, f.binding, id);
    f.probe.registrationRelease!.complete();
    final unknown = await observed;
    await stop;
    check(
      unknown is MediaIngestFailure &&
          unknown.execution == MediaIngestExecution.unknown &&
          mediaIngestBridgeError(unknown) ==
              AgentBridgeErrorCode.outcomeUnknown,
      'after actual durable registration stop is unknown',
    );
    check(
      (await f.learning.listCandidates()).isEmpty &&
          await f.materials.findArtifactRegistration(
                f.operation(b.deliveryId),
              ) !=
              null,
      'registered artifact preserved no Learning delivery',
    );
    print(
      'PASS typed preflight/once0/file unchanged / independent busy attempt / real registration then unknown',
    );
  } finally {
    await f.close();
  }
  for (final known in [false, true]) {
    final f = fixture.Fixture();
    await f.open();
    try {
      f.probe.readVersionFailure = known
          ? const MaterialStoreException(MaterialErrorCode.notFound)
          : StateError('synthetic unknown with misleading text invalidRequest');
      final e = await failure(
        () => f.ingest.begin(f.grant, f.input('source-failure')),
        'source failure',
      );
      check(
        e is MediaIngestFailure &&
            e.execution ==
                (known
                    ? MediaIngestExecution.notAttempted
                    : MediaIngestExecution.unknown),
        'typed source certainty known=$known',
      );
      check(
        f.probe.registrations == 0 &&
            (await Directory('${f.root.path}/ingest').list().toList()).length ==
                1,
        'no new session or registration',
      );
      print(
        'PASS unknown exceptions conservative / typed Core failure known=$known',
      );
    } finally {
      f.probe.readVersionFailure = null;
      await f.close();
    }
  }
  final h = fixture.Fixture();
  await h.open();
  try {
    final b = h.input('journal-unknown');
    final id = (await h.ingest.begin(h.grant, b)).uploadId;
    await Directory('${h.root.path}/ingest/$id/journal.json.next').create();
    final bytes = Uint8List.fromList(h.bytes.sublist(0, 65536));
    final e = await failure(
      () =>
          h.ingest.chunk(h.grant, h.binding, id, 0, bytes, fixture.hash(bytes)),
      'post-append journal fault',
    );
    check(
      e is MediaIngestFailure &&
          e.execution == MediaIngestExecution.unknown &&
          mediaIngestBridgeError(e) == AgentBridgeErrorCode.outcomeUnknown,
      'journal attempted failure unknown',
    );
    check(
      await File('${h.root.path}/ingest/$id/media.part').length() == 65536 &&
          h.probe.registrations == 0 &&
          await File('${h.root.path}/ingest/hold').exists(),
      'actual partial write hold and once0 retained',
    );
    print(
      'PASS journal post-append failure typed unknown / actual bytes and hold retained',
    );
  } finally {
    await h.close();
  }
}

Future<void> main() async {
  await codecCases();
  await descriptorCases();
  await storeContextCases();
  await certaintyCases();
}
