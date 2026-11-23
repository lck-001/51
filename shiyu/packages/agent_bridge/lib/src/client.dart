import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'contracts.dart';
import 'framing.dart';
import 'media_wire.dart';
import 'private_descriptor.dart';
import 'strict_json.dart';
import 'wire.dart';

/// A local protocol client, NOT a Store client. Its only file input is the
/// explicit owner-private descriptor. Each call uses a newly proven one Socket.
final class AgentBridgeClient {
  AgentBridgeClient({required this.descriptorPath});
  final String descriptorPath;
  final _random = Random.secure();
  final _channels = <BridgeFrameChannel>{};
  final _connecting = <ConnectionTask<Socket>>{};
  bool _closed = false;
  String _nonce() => List.generate(
    32,
    (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  Future<Map<String, Object?>> getSourceReference() =>
      _call('source_reference', {});
  Future<Map<String, Object?>> readFixedSource({
    required String materialId,
    required String materialVersionId,
    required String sourceTextSha256,
  }) => _call('source_read', {
    'material_id': materialId,
    'material_version_id': materialVersionId,
    'source_text_sha256': sourceTextSha256,
  });
  Future<Map<String, Object?>> submitCandidate(Map<String, Object?> payload) {
    candidateInput(
      payload,
    ); // Includes media-presence rejection; never silently discard fields.
    return _call('candidate_receive', payload);
  }

  Future<Map<String, Object?>> beginMedia(Map<String, Object?> payload) =>
      _mediaCall(MediaWireOperation.begin, payload);
  Future<Map<String, Object?>> putMediaChunk(Map<String, Object?> payload) =>
      _mediaCall(MediaWireOperation.chunk, payload);
  Future<Map<String, Object?>> sealMedia(Map<String, Object?> payload) =>
      _mediaCall(MediaWireOperation.seal, payload);
  Future<Map<String, Object?>> submitMediaCandidate(
    Map<String, Object?> payload,
  ) => _mediaCall(MediaWireOperation.submit, payload);
  Future<Map<String, Object?>> abortMedia(Map<String, Object?> payload) =>
      _mediaCall(MediaWireOperation.abort, payload);
  Future<Map<String, Object?>> _mediaCall(
    MediaWireOperation operation,
    Map<String, Object?> payload,
  ) {
    decodeMediaBridgePayload(
      operation.wireName,
      encodeAgentBridgeJson(payload, maxBytes: bridgePayloadMaximum),
    );
    return _call(operation.wireName, payload);
  }

  Future<Map<String, Object?>> _call(
    String operation,
    Map<String, Object?> payload,
  ) async {
    if (_closed) throw const AgentBridgeException(AgentBridgeErrorCode.closed);
    final bytes = encodeAgentBridgeJson(
      payload,
      maxBytes: bridgePayloadMaximum,
    );
    // Stable owned snapshot; callers may mutate their original Map while we await proof.
    final snapshot = Map<String, Object?>.from(
      decodeAgentBridgeJson(bytes, maxBytes: bridgePayloadMaximum) as Map,
    );
    final mediaKind = MediaWireOperation.values
        .where((k) => k.wireName == operation)
        .firstOrNull;
    final expectedMediaPayloadSha256 = mediaKind == MediaWireOperation.submit
        ? (decodeMediaBridgePayload(
            operation,
            bytes,
          ) as MediaWireSubmit).submission.media.submissionSha256
        : null;
    final mutation = operation == 'candidate_receive' || mediaKind != null;
    late BridgeDescriptor descriptor;
    try {
      descriptor = await readPrivateDescriptor(descriptorPath);
    } on AgentBridgeException {
      rethrow;
    } catch (_) {
      throw const AgentBridgeException(
        AgentBridgeErrorCode.privateStorageUnavailable,
      );
    }
    if (_closed) throw const AgentBridgeException(AgentBridgeErrorCode.closed);
    if (!DateTime.now().toUtc().isBefore(descriptor.expiresAtUtc)) {
      throw const AgentBridgeException(AgentBridgeErrorCode.expired);
    }
    if (operation != 'source_reference')
      requireSourceBinding(snapshot, descriptor);
    if (operation == 'source_read' && !descriptor.allowSourceRead) {
      throw const AgentBridgeException(AgentBridgeErrorCode.forbidden);
    }
    if (mediaKind != null && !descriptor.allowMediaReceive)
      throw const AgentBridgeException(AgentBridgeErrorCode.forbidden);
    BridgeFrameChannel? channel;
    ConnectionTask<Socket>? connecting;
    Timer? deadline;
    var proven = false, businessStarted = false, knownReply = false;
    try {
      connecting = await Socket.startConnect(
        InternetAddress.loopbackIPv4,
        descriptor.port,
      );
      _connecting.add(connecting);
      if (_closed) {
        connecting.cancel();
        throw const AgentBridgeException(AgentBridgeErrorCode.closed);
      }
      deadline = Timer(const Duration(seconds: 5), () {
        connecting?.cancel();
        channel?.destroy();
      });
      final socket = await connecting.socket.timeout(
        const Duration(seconds: 2),
        onTimeout: () {
          connecting!.cancel();
          throw const AgentBridgeException(AgentBridgeErrorCode.timeout);
        },
      );
      _connecting.remove(connecting);
      channel = BridgeFrameChannel(socket, initialMaximum: 512);
      _channels.add(channel);
      if (_closed)
        throw const AgentBridgeException(AgentBridgeErrorCode.closed);
      final challenge = _nonce();
      await channel.send({
        'kind': 'hello',
        'session': descriptor.session,
        'challenge': challenge,
      }, maximum: 512);
      final proof = bridgeObject(
        await channel.read(maximum: 512).timeout(const Duration(seconds: 2)),
        {'kind', 'session', 'mac'},
      );
      if (proof['kind'] != 'proof' ||
          proof['session'] != descriptor.session ||
          proof['mac'] is! String ||
          !constantBridgeEqual(
            proof['mac'] as String,
            sessionProof(descriptor, challenge),
          )) {
        throw const AgentBridgeException(
          AgentBridgeErrorCode.sessionUnconfirmed,
        );
      }
      proven = true;
      if (_closed)
        throw const AgentBridgeException(AgentBridgeErrorCode.closed);
      // Encode the complete request before marking business transmission started.
      final Uint8List frame;
      if (mediaKind != null) {
        frame = encodeMediaBridgeRequest(
          operation: mediaKind,
          payload: snapshot,
          session: descriptor.session,
          challenge: challenge,
          capability: descriptor.capability,
        ).frame;
      } else {
        final body = encodeAgentBridgeJson({
          'kind': 'request',
          'session': descriptor.session,
          'challenge': challenge,
          'capability': descriptor.capability,
          'operation': operation,
          'payload': base64.encode(bytes),
        }, maxBytes: bridgeFrameMaximum);
        frame = Uint8List(body.length + 12)
          ..setRange(0, 8, const [0x53, 0x59, 0x42, 0x31, 0, 13, 10, 0]);
        ByteData.sublistView(frame).setUint32(8, body.length, Endian.big);
        frame.setRange(12, frame.length, body);
      }
      channel.expectMaximum(bridgeFrameMaximum);
      // No fresh socket, redirect or retry is possible after this proof.
      await channel.sendPreencodedFrame(
        frame,
        maximum: bridgeFrameMaximum,
        beforeWrite: () => businessStarted = true,
      );
      final response = await channel.read(maximum: bridgeFrameMaximum);
      if (response is! Map<String, dynamic> || response['ok'] is! bool) {
        throw const AgentBridgeException(AgentBridgeErrorCode.unavailable);
      }
      if (response['ok'] == false) {
        final error = bridgeObject(response, {'ok', 'error'})['error'];
        final codes = AgentBridgeErrorCode.values.where(
          (code) => code.name == error,
        );
        if (codes.length != 1)
          throw const AgentBridgeException(AgentBridgeErrorCode.unavailable);
        knownReply = true;
        throw AgentBridgeException(
          mutation && codes.single == AgentBridgeErrorCode.unavailable
              ? AgentBridgeErrorCode.outcomeUnknown
              : codes.single,
        );
      }
      final result = bridgeObject(response, {'ok', 'result'})['result'];
      if (result is! Map<String, dynamic>)
        throw const AgentBridgeException(AgentBridgeErrorCode.unavailable);
      _validateResult(
        operation,
        Map<String, Object?>.from(result),
        snapshot,
        expectedMediaPayloadSha256: expectedMediaPayloadSha256,
      );
      knownReply = true;
      return Map<String, Object?>.from(result);
    } on AgentBridgeException catch (error) {
      if (mutation && businessStarted && !knownReply) {
        throw const AgentBridgeException(AgentBridgeErrorCode.outcomeUnknown);
      }
      if (!proven &&
          error.code != AgentBridgeErrorCode.closed &&
          error.code != AgentBridgeErrorCode.timeout) {
        throw const AgentBridgeException(
          AgentBridgeErrorCode.sessionUnconfirmed,
        );
      }
      rethrow;
    } catch (_) {
      if (mutation && businessStarted && !knownReply) {
        throw const AgentBridgeException(AgentBridgeErrorCode.outcomeUnknown);
      }
      throw AgentBridgeException(
        proven
            ? AgentBridgeErrorCode.unavailable
            : AgentBridgeErrorCode.sessionUnconfirmed,
      );
    } finally {
      deadline?.cancel();
      if (connecting != null) _connecting.remove(connecting);
      if (channel != null) {
        _channels.remove(channel);
        try {
          await channel.close();
        } catch (_) {}
      }
    }
  }

  void _validateResult(
    String operation,
    Map<String, Object?> result,
    Map<String, Object?> input, {
    String? expectedMediaPayloadSha256,
  }) {
    void invalid() =>
        throw const AgentBridgeException(AgentBridgeErrorCode.unavailable);
    void id(Object? value, {bool hash = false}) {
      if (value is! String ||
          !RegExp(hash ? r'^[0-9a-f]{64}$' : r'^[0-9a-f]{32}$').hasMatch(value))
        invalid();
    }

    void integer(Object? value, int minimum, int maximum) {
      if (value is! int || value < minimum || value > maximum) invalid();
    }

    void replay() {
      if (result['replayed'] is! bool) invalid();
    }

    void upload() {
      id(result['upload_id']);
      if (result['upload_id'] != input['upload_id']) invalid();
    }

    if (operation == 'candidate_receive' || operation == 'media_submit') {
      bridgeObject(result, {
        'candidate_id',
        'payload_sha256',
        'replayed',
        'status',
      });
      id(result['candidate_id']);
      id(result['payload_sha256'], hash: true);
      replay();
      if (result['status'] != 'delivered') invalid();
      if (operation == 'media_submit' &&
          result['payload_sha256'] != expectedMediaPayloadSha256)
        invalid();
      return;
    }
    if (operation == 'media_begin') {
      bridgeObject(result, {
        'upload_id',
        'raw_chunk_bytes',
        'next_index',
        'status',
        'replayed',
      });
      id(result['upload_id']);
      integer(result['raw_chunk_bytes'], 65536, 65536);
      integer(result['next_index'], 0, 32);
      replay();
      if (!{'receiving', 'sealed', 'terminal'}.contains(result['status']))
        invalid();
      return;
    }
    if (operation == 'media_chunk') {
      bridgeObject(result, {
        'upload_id',
        'index',
        'accepted_bytes',
        'replayed',
        'status',
      });
      upload();
      integer(result['index'], 0, 31);
      integer(result['accepted_bytes'], 1, 1920044);
      replay();
      if (result['index'] != input['index'] || result['status'] != 'receiving')
        invalid();
      final bytes = decodeCanonicalBridgeBase64(
        input['bytes_base64'] as String,
        maximumBytes: 65536,
      );
      if ((result['accepted_bytes'] as int) <
          (input['index'] as int) * 65536 + bytes.length)
        invalid();
      return;
    }
    if (operation == 'media_seal') {
      bridgeObject(result, {
        'upload_id',
        'sealed_receipt',
        'status',
        'replayed',
      });
      upload();
      id(result['sealed_receipt'], hash: true);
      replay();
      if (result['status'] != 'sealed') invalid();
      return;
    }
    if (operation == 'media_abort') {
      bridgeObject(result, {'upload_id', 'status'});
      upload();
      if (result['status'] != 'terminal') invalid();
      return;
    }
    // Legacy source result validation remains in its existing consumer/proxy.
  }

  Future<void> close() async {
    _closed = true;
    for (final task in _connecting.toList()) {
      task.cancel();
    }
    for (final channel in _channels.toList()) {
      try {
        await channel.close();
      } catch (_) {}
    }
    _channels.clear();
    _connecting.clear();
  }
}
