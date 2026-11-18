import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:learning_core/learning_core.dart';
import 'package:material_core/material_core.dart';

import 'contracts.dart';
import 'framing.dart';
import 'private_descriptor.dart';
import 'root_lock.dart';
import 'strict_json.dart';
import 'windows_privacy.dart';
import 'wire.dart';

final class _Grant {
  _Grant(this.descriptor, this.epoch);
  final BridgeDescriptor descriptor;
  final int epoch;
  bool valid = true;
  int calls = 0;
}

final class _DigestResult implements Sink<Digest> {
  Digest? digest;
  @override
  void add(Digest value) => digest = value;
  @override
  void close() {}
}

(String, int) _sourceDigest(String text) {
  var bytes = 0;
  for (var i = 0; i < text.length; i++) {
    final c = text.codeUnitAt(i);
    if (c >= 0xd800 && c <= 0xdbff) {
      if (++i >= text.length ||
          text.codeUnitAt(i) < 0xdc00 ||
          text.codeUnitAt(i) > 0xdfff) {
        throw const AgentBridgeException(AgentBridgeErrorCode.sourceMismatch);
      }
      bytes += 4;
    } else if (c >= 0xdc00 && c <= 0xdfff) {
      throw const AgentBridgeException(AgentBridgeErrorCode.sourceMismatch);
    } else {
      bytes += c < 128
          ? 1
          : c < 2048
          ? 2
          : 3;
    }
  }
  final result = _DigestResult();
  final sink = utf8.encoder.startChunkedConversion(
    sha256.startChunkedConversion(result),
  );
  for (var start = 0; start < text.length;) {
    var end = start + 4096;
    if (end > text.length) end = text.length;
    if (end < text.length &&
        text.codeUnitAt(end - 1) >= 0xd800 &&
        text.codeUnitAt(end - 1) <= 0xdbff)
      end--;
    sink.add(text.substring(start, end));
    start = end;
  }
  sink.close();
  return (result.digest.toString(), bytes);
}

/// App-owned authority over existing instances. Constructor starts no listener,
/// writes no credential and never creates/opens its own Store.
final class AgentBridgeController {
  AgentBridgeController.attach({
    required this.materials,
    required this.candidates,
    required Directory privateDirectory,
    required this.rootLock,
    required List<String> proxyCommand,
    this.integrationId = 'local-assistant',
    DateTime Function()? clock,
  }) : proxyCommand = List.unmodifiable(proxyCommand),
       _clock = clock ?? DateTime.now,
       _private = PrivateDescriptorStore(
         rootLock: rootLock,
         directory: privateDirectory,
       ) {
    if (materials.trustedOwnerId != candidates.trustedOwnerId) {
      throw const AgentBridgeException(AgentBridgeErrorCode.ownerMismatch);
    }
    if (!rootLock.isHeld ||
        !RegExp(r'^[a-z0-9_-]{1,80}$').hasMatch(integrationId)) {
      throw const AgentBridgeException(AgentBridgeErrorCode.rootUnavailable);
    }
  }
  final MaterialStore materials;
  final LearningCandidateStore candidates;
  final LearningRootLock rootLock;
  final List<String> proxyCommand;
  final String integrationId;
  final DateTime Function() _clock;
  final PrivateDescriptorStore _private;
  final _changes = StreamController<AgentBridgeStatus>.broadcast(sync: true);
  final _random = Random.secure();
  final _channels = <BridgeFrameChannel>{};
  final _serverClosures = <Future<void>>[];
  final _retiringSessions = <String>{};
  Future<void> _control = Future<void>.value();
  Future<void>? _operation;
  ServerSocket? _server;
  _Grant? _grant;
  Timer? _expiry;
  AgentBridgePhase _phase = AgentBridgePhase.disabled;
  bool _retired = false, _closed = false;
  int _epoch = 0;
  String? _error, _lastCandidateId;
  AgentBridgeStatus get current => AgentBridgeStatus(
    phase: _phase,
    materialId: _grant?.descriptor.materialId,
    materialVersionId: _grant?.descriptor.materialVersionId,
    integrationId: _grant?.descriptor.integrationId,
    expiresAtUtc: _grant?.descriptor.expiresAtUtc,
    allowSourceRead:
        _phase == AgentBridgePhase.enabled &&
        (_grant?.descriptor.allowSourceRead ?? false),
    inFlight: _operation == null ? 0 : 1,
    lastCandidateId: _lastCandidateId,
    errorCode: _error,
  );
  Stream<AgentBridgeStatus> get snapshots => _changes.stream;
  void _emit() {
    if (!_changes.isClosed) _changes.add(current);
  }

  String _hex(int n) => List.generate(
    n,
    (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  DateTime get _now => _clock().toUtc();

  Future<T> _queue<T>(Future<T> Function() body) {
    final result = Completer<T>();
    _control = _control.then((_) async {
      try {
        result.complete(await body());
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  void _invalidate() {
    _expiry?.cancel();
    _expiry = null;
    final grant = _grant;
    if (grant != null) {
      grant.valid = false;
      _retiringSessions.add(grant.descriptor.session);
    }
    final server = _server;
    _server = null;
    if (server != null) {
      final closed = server.close().then<void>((_) {});
      closed.ignore();
      _serverClosures.add(closed);
    }
    for (final channel in _channels.toList()) {
      channel.destroy();
    }
    if (grant != null || _operation != null || _serverClosures.isNotEmpty)
      _phase = AgentBridgePhase.draining;
    _emit();
  }

  Future<void> _drain() async {
    // Never let an old queued revoke delete a newer descriptor.
    for (final session in _retiringSessions.toList()) {
      try {
        await _private.deleteIfSession(session);
      } catch (_) {
        throw const AgentBridgeException(
          AgentBridgeErrorCode.privateStorageUnavailable,
        );
      }
      _retiringSessions.remove(session);
    }
    for (final closure in _serverClosures.toList()) {
      await closure;
      _serverClosures.remove(closure);
    }
    final pending = _operation;
    if (pending != null)
      await pending; // Real Store completion, no fake timeout cancellation.
    if (_grant?.valid == false) _grant = null;
  }

  void _ticket(int ticket) {
    if (_closed || _retired)
      throw const AgentBridgeException(AgentBridgeErrorCode.closed);
    if (ticket != _epoch)
      throw const AgentBridgeException(AgentBridgeErrorCode.revoked);
    if (!rootLock.isHeld)
      throw const AgentBridgeException(AgentBridgeErrorCode.rootUnavailable);
  }

  Future<AgentBridgeStatus> authorize(AgentBridgeGrantRequest request) {
    if (_retired || _closed)
      return Future.error(
        const AgentBridgeException(AgentBridgeErrorCode.closed),
      );
    if (!Platform.isWindows)
      return Future.error(
        const AgentBridgeException(AgentBridgeErrorCode.unsupportedPlatform),
      );
    final ticket = ++_epoch;
    _invalidate();
    return _queue(() async {
      try {
        await _drain();
        _ticket(ticket);
        final version = await materials.readVersion(request.materialVersionId);
        _ticket(ticket);
        if (version.ownerId != materials.trustedOwnerId) {
          throw const AgentBridgeException(AgentBridgeErrorCode.ownerMismatch);
        }
        final digest = _sourceDigest(version.text);
        if (request.allowSourceRead && digest.$2 > bridgeSourceMaximum) {
          throw const AgentBridgeException(AgentBridgeErrorCode.sourceTooLarge);
        }
        await _private.prepare();
        _ticket(ticket);
        final server = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
          backlog: 2,
        );
        if (ticket != _epoch || _retired || _closed) {
          await server.close();
          _ticket(ticket);
        }
        final descriptor = BridgeDescriptor(
          port: server.port,
          session: _hex(16),
          capability: _hex(32),
          proofKey: _hex(32),
          integrationId: integrationId,
          materialId: version.materialId,
          materialVersionId: version.versionId,
          sourceTextSha256: digest.$1,
          expiresAtUtc: _now.add(const Duration(minutes: 15)),
          allowSourceRead: request.allowSourceRead,
        );
        final grant = _Grant(descriptor, ticket);
        _grant = grant;
        _server = server;
        await _private.write(descriptor);
        _ticket(ticket);
        _phase = AgentBridgePhase.enabled;
        _error = null;
        server.listen(
          (socket) {
            if (_channels.length >= 2 || !_valid(grant)) {
              socket.destroy();
              return;
            }
            unawaited(_handle(socket, grant));
          },
          onError: (Object _) {
            if (identical(_server, server))
              unawaited(
                revoke().catchError((Object _) {
                  _error = AgentBridgeErrorCode.unavailable.name;
                  _emit();
                }),
              );
          },
        );
        _expiry = Timer(const Duration(minutes: 15), () {
          if (identical(_grant, grant)) {
            unawaited(revoke().catchError((Object _) {}));
          }
        });
        _emit();
        return current;
      } catch (error) {
        _invalidate();
        await _drain();
        if (ticket == _epoch) {
          _phase = AgentBridgePhase.disabled;
          _error = error is AgentBridgeException
              ? error.code.name
              : AgentBridgeErrorCode.unavailable.name;
          _emit();
        }
        if (error is AgentBridgeException) rethrow;
        throw const AgentBridgeException(AgentBridgeErrorCode.unavailable);
      }
    });
  }

  Future<void> revoke() {
    ++_epoch;
    _invalidate();
    return _queue(() async {
      await _drain();
      if (!_closed) {
        _phase = AgentBridgePhase.disabled;
        _error = null;
        _emit();
      }
    });
  }

  void retire() {
    if (_retired) return;
    _retired = true;
    ++_epoch;
    _invalidate();
  }

  Future<void> close() {
    retire();
    return _queue(() async {
      if (_closed) return;
      await _drain();
      _closed = true;
      _phase = AgentBridgePhase.closed;
      _emit();
      await _changes.close();
    });
  }

  bool _valid(_Grant grant) =>
      !_retired &&
      !_closed &&
      rootLock.isHeld &&
      grant.valid &&
      identical(_grant, grant) &&
      grant.epoch == _epoch &&
      _phase == AgentBridgePhase.enabled &&
      _now.isBefore(grant.descriptor.expiresAtUtc);
  void _require(_Grant grant) {
    if (!_valid(grant))
      throw const AgentBridgeException(AgentBridgeErrorCode.revoked);
  }

  Future<void> _handle(Socket socket, _Grant grant) async {
    final channel = BridgeFrameChannel(socket, initialMaximum: 512);
    _channels.add(channel);
    final deadline = Timer(const Duration(seconds: 5), channel.destroy);
    try {
      final hello = bridgeObject(
        await channel.read(maximum: 512).timeout(const Duration(seconds: 2)),
        {'kind', 'session', 'challenge'},
      );
      _require(grant);
      if (hello['kind'] != 'hello' ||
          hello['session'] != grant.descriptor.session ||
          hello['challenge'] is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(hello['challenge'] as String)) {
        throw const AgentBridgeException(AgentBridgeErrorCode.invalidRequest);
      }
      final challenge = hello['challenge'] as String;
      channel.expectMaximum(bridgeFrameMaximum);
      await channel.send({
        'kind': 'proof',
        'session': grant.descriptor.session,
        'mac': sessionProof(grant.descriptor, challenge),
      }, maximum: 512);
      final request = bridgeObject(
        await channel
            .read(maximum: bridgeFrameMaximum)
            .timeout(const Duration(seconds: 2)),
        {'kind', 'session', 'challenge', 'capability', 'operation', 'payload'},
      );
      _require(grant);
      if (request['kind'] != 'request' ||
          request['session'] != grant.descriptor.session ||
          request['challenge'] != challenge ||
          request['capability'] is! String ||
          !RegExp(r'^[a-f0-9]{64}$')
              .hasMatch(request['capability'] as String) ||
          !constantBridgeEqual(
            request['capability'] as String,
            grant.descriptor.capability,
          ) ||
          request['operation'] is! String ||
          request['payload'] is! String) {
        throw const AgentBridgeException(AgentBridgeErrorCode.forbidden);
      }
      if (_operation != null)
        throw const AgentBridgeException(AgentBridgeErrorCode.busy);
      if (++grant.calls > 64)
        throw const AgentBridgeException(AgentBridgeErrorCode.busy);
      final raw = base64.decode(request['payload'] as String);
      if (raw.length > bridgePayloadMaximum)
        throw const AgentBridgeException(AgentBridgeErrorCode.tooLarge);
      final payload = decodeAgentBridgeJson(
        raw,
        maxBytes: bridgePayloadMaximum,
      );
      if (payload is! Map<String, dynamic>)
        throw const AgentBridgeException(AgentBridgeErrorCode.invalidRequest);
      final operation = request['operation'] as String;
      final done = Completer<void>();
      _operation = done.future;
      _emit();
      late Map<String, Object?> response;
      try {
        response = await _execute(
          grant,
          operation,
          Map<String, Object?>.from(payload),
          raw,
        );
      } finally {
        done.complete();
        _operation = null;
        _emit();
      }
      await channel.send({
        'ok': true,
        'result': response,
      }, maximum: bridgeFrameMaximum);
    } catch (error) {
      final code = error is AgentBridgeException
          ? error.code
          : error is LearningStoreException
          ? _coreCode(error.code)
          : error is MaterialStoreException
          ? AgentBridgeErrorCode.sourceMismatch
          : AgentBridgeErrorCode.unavailable;
      try {
        await channel.send({'ok': false, 'error': code.name}, maximum: 512);
      } catch (_) {}
    } finally {
      deadline.cancel();
      _channels.remove(channel);
      await channel.close();
    }
  }

  AgentBridgeErrorCode _coreCode(LearningErrorCode code) => switch (code) {
    LearningErrorCode.deliveryConflict => AgentBridgeErrorCode.deliveryConflict,
    LearningErrorCode.candidateLimitExceeded =>
      AgentBridgeErrorCode.candidateLimitExceeded,
    LearningErrorCode.unsupportedMedia => AgentBridgeErrorCode.unsupportedMedia,
    LearningErrorCode.writeFailed ||
    LearningErrorCode.corruptStore => AgentBridgeErrorCode.outcomeUnknown,
    LearningErrorCode.bindingMismatch ||
    LearningErrorCode.ownerMismatch ||
    LearningErrorCode.notFound => AgentBridgeErrorCode.sourceMismatch,
    _ => AgentBridgeErrorCode.invalidRequest,
  };

  Future<Map<String, Object?>> _execute(
    _Grant grant,
    String operation,
    Map<String, Object?> payload,
    List<int> raw,
  ) async {
    _require(grant);
    final descriptor = grant.descriptor;
    if (operation == 'source_reference') {
      bridgeObject(payload, {});
      return sourceReference(descriptor);
    }
    if (operation == 'source_read') {
      if (!descriptor.allowSourceRead)
        throw const AgentBridgeException(AgentBridgeErrorCode.forbidden);
      bridgeObject(payload, {
        'material_id',
        'material_version_id',
        'source_text_sha256',
      });
      requireSourceBinding(payload, descriptor);
      final version = await materials.readVersion(descriptor.materialVersionId);
      _require(grant);
      final digest = _sourceDigest(version.text);
      if (version.ownerId != materials.trustedOwnerId ||
          version.materialId != descriptor.materialId ||
          digest.$1 != descriptor.sourceTextSha256)
        throw const AgentBridgeException(AgentBridgeErrorCode.sourceMismatch);
      if (digest.$2 > bridgeSourceMaximum)
        throw const AgentBridgeException(AgentBridgeErrorCode.sourceTooLarge);
      return {...sourceReference(descriptor), 'text': version.text};
    }
    if (operation == 'candidate_receive') {
      requireSourceBinding(payload, descriptor);
      final input = candidateInput(payload);
      _require(grant);
      final receipt = await candidates.receiveCandidate(
        sender: CandidateSender(
          integrationId: integrationId,
          transport: CandidateTransport.localCapability,
          transportPayloadSha256: sha256.convert(raw).toString(),
        ),
        input: input,
      );
      _lastCandidateId = receipt.candidateId;
      _emit();
      return {
        'candidate_id': receipt.candidateId,
        'payload_sha256': receipt.payloadSha256,
        'replayed': receipt.replayed,
        'status': 'delivered',
      };
    }
    throw const AgentBridgeException(AgentBridgeErrorCode.forbidden);
  }

  Future<AgentBridgeSetup> setup() async {
    final grant = _grant;
    if (grant == null || !_valid(grant))
      throw const AgentBridgeException(AgentBridgeErrorCode.disabled);
    if (proxyCommand.length != 1 ||
        !proxyCommand.single.toLowerCase().endsWith('.exe') ||
        await FileSystemEntity.type(proxyCommand.single, followLinks: false) !=
            FileSystemEntityType.file) {
      throw const AgentBridgeException(AgentBridgeErrorCode.unavailable);
    }
    final executable = WindowsPrivacy.instance.canonicalPath(
      proxyCommand.single,
    );
    final descriptor = WindowsPrivacy.instance.canonicalPath(_private.path);
    _require(grant);
    return AgentBridgeSetup(
      descriptorPath: descriptor,
      configurationToml:
          '[mcp_servers.shiyu_local]\ncommand = ${jsonEncode(executable)}\nargs = []\n'
          'startup_timeout_sec = 10\ntool_timeout_sec = 15\n\n'
          '[mcp_servers.shiyu_local.env]\nSHIYU_BRIDGE_DESCRIPTOR = ${jsonEncode(descriptor)}\n',
      instructions:
          '仅本机授权，不认证外部助手品牌。原文读取单独授权；送入仅成为待校对候选。'
          '请在助手的高级MCP设置中配置此独立stdio程序，按该客户端要求重新加载；本App不会代您重启。'
          '配置中仅有私有文件位置，切勿公开该文件。未使用任何模型账户或语音服务。',
    );
  }
}
