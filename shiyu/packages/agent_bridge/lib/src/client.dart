import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'contracts.dart';
import 'framing.dart';
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

  Future<Map<String, Object?>> _call(
    String operation,
    Map<String, Object?> payload,
  ) async {
    if (_closed) throw const AgentBridgeException(AgentBridgeErrorCode.closed);
    final bytes = encodeAgentBridgeJson(
      payload,
      maxBytes: bridgePayloadMaximum,
    );
    late BridgeDescriptor descriptor;
    try { descriptor = await readPrivateDescriptor(descriptorPath); }
    on AgentBridgeException { rethrow; }
    catch (_) { throw const AgentBridgeException(AgentBridgeErrorCode.privateStorageUnavailable); }
    if (_closed) throw const AgentBridgeException(AgentBridgeErrorCode.closed);
    if (!DateTime.now().toUtc().isBefore(descriptor.expiresAtUtc)) {
      throw const AgentBridgeException(AgentBridgeErrorCode.expired);
    }
    if (operation != 'source_reference')
      requireSourceBinding(payload, descriptor);
    if (operation == 'source_read' && !descriptor.allowSourceRead) {
      throw const AgentBridgeException(AgentBridgeErrorCode.forbidden);
    }
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
      channel.expectMaximum(bridgeFrameMaximum);
      // No fresh socket, redirect or retry is possible after this proof.
      businessStarted = true;
      await channel.send({
        'kind': 'request',
        'session': descriptor.session,
        'challenge': challenge,
        'capability': descriptor.capability,
        'operation': operation,
        'payload': base64.encode(bytes),
      }, maximum: bridgeFrameMaximum);
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
        throw AgentBridgeException(codes.single);
      }
      final result = bridgeObject(response, {'ok', 'result'})['result'];
      if (result is! Map<String, dynamic>)
        throw const AgentBridgeException(AgentBridgeErrorCode.unavailable);
      knownReply = true;
      return Map<String, Object?>.from(result);
    } on AgentBridgeException catch (error) {
      if (operation == 'candidate_receive' &&
          businessStarted &&
          !knownReply &&
          !{
            AgentBridgeErrorCode.tooLarge,
            AgentBridgeErrorCode.invalidJson,
          }.contains(error.code)) {
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
      if (operation == 'candidate_receive' && businessStarted && !knownReply) {
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
        try { await channel.close(); } catch (_) {}
      }
    }
  }

  Future<void> close() async {
    _closed = true;
    for (final task in _connecting.toList()) {
      task.cancel();
    }
    for (final channel in _channels.toList()) {
      try { await channel.close(); } catch (_) {}
    }
    _channels.clear();
    _connecting.clear();
  }
}
