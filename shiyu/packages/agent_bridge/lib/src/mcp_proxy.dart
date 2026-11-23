import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;

import 'client.dart';
import 'bounded_stdio_writer.dart';
import 'media_wire.dart';
import 'contracts.dart';
import 'strict_json.dart';

// Protocol sources checked 2026-11-18, not inferred from a vendor client:
// https://modelcontextprotocol.io/specification/2025-11-25/basic
// https://modelcontextprotocol.io/specification/2025-11-25/basic/transports
// https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle
// https://modelcontextprotocol.io/specification/2025-11-25/server/tools
// https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle

const _requestBytes = 256 * 1024;
const _responseBytes = 512 * 1024;
const _maxSessionIds = 4096;
const _maxFrames = 8192;
const _versions = ['2025-11-25', '2025-06-18'];
const _bindingNames = {
  'material_id',
  'material_version_id',
  'source_text_sha256',
};
const _mediaNames = {'media', 'audio', 'timings', 'artifacts'};
final _idPattern = RegExp(r'^[0-9a-f]{32}$');
final _hashPattern = RegExp(r'^[0-9a-f]{64}$');

const _bindingProperties = <String, Object?>{
  'material_id': {'type': 'string', 'pattern': '^[0-9a-f]{32}\$'},
  'material_version_id': {'type': 'string', 'pattern': '^[0-9a-f]{32}\$'},
  'source_text_sha256': {'type': 'string', 'pattern': '^[0-9a-f]{64}\$'},
};
const _optionalDeclarationText = <String, Object?>{
  'type': ['string', 'null'],
  'maxLength': 8192,
};

/// A narrow stdio front end to the existing authenticated App client. It owns
/// one client lifetime, never a Store, descriptor parser, proof or second socket
/// protocol. Initial discovery remains available while the App is disabled.
final class AgentBridgeMcpProxy {
  AgentBridgeMcpProxy({required AgentBridgeClient client}) : _client = client;
  final AgentBridgeClient _client;
  final Set<String> _ids = {};
  bool _initialized = false, _ready = false, _stop = false, _ran = false;
  Future<void>? _ordinary, _abort;
  final _accepted = <Future<void>>{};
  _StdioLineReader? _reader;
  void _stopAdmission() {
    _stop = true;
    _reader?.stop();
  }

  /// Bounded ordinary + abort actions; metadata/rejections share one writer.
  Future<int> run({
    required Stream<List<int>> input,
    required IOSink output,
  }) async {
    if (_ran) return 2;
    _ran = true;
    final reader = _StdioLineReader(input);
    _reader = reader;
    final writer = BoundedStdioWriter(output, onFailure: _stopAdmission);
    var frames = 0, code = 0;
    try {
      while (!_stop) {
        final bytes = await reader.next();
        if (bytes == null) break;
        if (++frames > _maxFrames) {
          _stopAdmission();
          code = 1;
          await _send(writer, _rpcError(null, -32000, 'session_limit'));
          break;
        }
        Object? message;
        try {
          message = decodeAgentBridgeJson(bytes, maxBytes: _requestBytes);
        } on AgentBridgeException catch (error) {
          _stopAdmission();
          code = 1;
          await _send(
            writer,
            _rpcError(
              null,
              error.code == AgentBridgeErrorCode.tooLarge ? -32000 : -32700,
              error.code == AgentBridgeErrorCode.tooLarge
                  ? 'tooLarge'
                  : 'parse_error',
            ),
          );
          break;
        } catch (_) {
          _stopAdmission();
          code = 1;
          await _send(writer, _rpcError(null, -32700, 'parse_error'));
          break;
        }
        final response = await _handle(message, writer);
        if (response != null) await _send(writer, response);
        if (_stop) code = 1;
      }
    } on _StdioFault catch (error) {
      _stopAdmission();
      code = 1;
      if (!writer.failed) {
        try {
          await _send(writer, _rpcError(null, -32000, error.code));
        } catch (_) {}
      }
    } catch (_) {
      _stopAdmission();
      code = 1;
    } finally {
      reader.stop();
      // Never close Client first and call that a drain. Every admitted action
      // retains its slot through its logical writer completion, even on failure.
      final pending = List<Future<void>>.of(_accepted);
      await Future.wait(
        pending.map(
          (f) => Future<void>.sync(() => f).catchError((Object _) {
            code = 1;
          }),
        ),
      );
      try {
        await _client.close();
      } catch (_) {
        code = 1;
      }
      // Borrowed output.close/done and a timed-out native flush are not awaited.
      if (writer.failed || _stop) code = 1;
    }
    return code;
  }

  Future<Map<String, Object?>?> _handle(
    Object? raw,
    BoundedStdioWriter writer,
  ) async {
    if (raw is! Map<String, Object?>)
      return _rpcError(null, -32600, 'invalid_request');
    final hasId = raw.containsKey('id');
    final id = raw['id'];
    // Valid notifications never receive a response, including unsupported or
    // malformed notification parameters. They never invoke an App operation.
    if (!hasId && raw['jsonrpc'] == '2.0' && raw['method'] is String) {
      if (raw.keys.any((k) => !{'jsonrpc', 'method', 'params'}.contains(k)))
        return null;
      final params = raw['params'];
      if (raw.containsKey('params') && params is! Map<String, Object?>)
        return null;
      if (raw['method'] == 'notifications/initialized' &&
          _initialized &&
          !_ready) {
        if (params == null ||
            (params is Map<String, Object?> &&
                params.keys.every((k) => k == '_meta') &&
                (!params.containsKey('_meta') ||
                    params['_meta'] is Map<String, Object?>)))
          _ready = true;
      }
      // Optional notifications/cancelled is ignored: delivery may have committed.
      return null;
    }
    if (!hasId || !_validRpcId(id))
      return _rpcError(null, -32600, 'invalid_request');
    final key = jsonEncode(id is num ? id.toInt() : id);
    if (_ids.contains(key))
      return _rpcError(id, -32600, 'duplicate_request_id');
    if (_ids.length >= _maxSessionIds) {
      _stop = true;
      return _rpcError(id, -32000, 'session_limit');
    }
    _ids.add(key);
    try {
      if (raw['jsonrpc'] != '2.0' ||
          raw['method'] is! String ||
          (raw['method'] as String).length > 128 ||
          raw.keys.any(
            (k) => !{'jsonrpc', 'id', 'method', 'params'}.contains(k),
          )) {
        throw const _RpcFault(-32600, 'invalid_request');
      }
      final params = raw.containsKey('params')
          ? _object(raw['params'])
          : <String, Object?>{};
      final method = raw['method'] as String;
      if (method == 'ping') {
        _keys(params, {'_meta'});
        _meta(params);
        return _rpcResult(id, <String, Object?>{});
      }
      if (method == 'initialize') return _initialize(id, params);
      if (method != 'tools/list' && method != 'tools/call') {
        throw const _RpcFault(-32601, 'method_not_found');
      }
      if (!_ready) throw const _RpcFault(-32000, 'not_initialized');
      if (method == 'tools/list') {
        _keys(params, {'cursor', '_meta'});
        _meta(params);
        if (params.containsKey('cursor'))
          throw const _RpcFault(-32602, 'invalid_cursor');
        return _rpcResult(id, {'tools': _tools});
      }
      _keys(params, {'name', 'arguments', '_meta'}, required: {'name'});
      _meta(params);
      final name = params['name'];
      if (name is! String || !_toolNames.contains(name)) {
        throw const _RpcFault(-32602, 'unknown_tool');
      }
      final arguments = params.containsKey('arguments')
          ? _object(params['arguments'])
          : <String, Object?>{};
      try {
        _validateToolArguments(name, arguments);
      } on AgentBridgeException catch (error) {
        return _rpcResult(id, _toolError(error.code.name));
      }
      final abort = name == 'shiyu_abort_media';
      if (abort ? _abort != null : _ordinary != null)
        return _rpcResult(id, _toolError('busy'));
      final done = Completer<void>();
      if (abort) {
        _abort = done.future;
      } else {
        _ordinary = done.future;
      }
      _accepted.add(done.future);
      () async {
        try {
          await _send(writer, _rpcResult(id, await _callTool(name, arguments)));
        } catch (_) {
          _stopAdmission();
        } finally {
          if (abort) {
            _abort = null;
          } else {
            _ordinary = null;
          }
          done.complete();
          _accepted.remove(done.future);
        }
      }().ignore();
      return null;
    } on _RpcFault catch (error) {
      return _rpcError(id, error.code, error.message);
    } catch (_) {
      return _rpcError(id, -32603, 'internal_error');
    }
  }

  Map<String, Object?> _initialize(Object? id, Map<String, Object?> params) {
    if (_initialized) throw const _RpcFault(-32600, 'already_initialized');
    _keys(
      params,
      {'protocolVersion', 'capabilities', 'clientInfo', '_meta'},
      required: {'protocolVersion', 'capabilities', 'clientInfo'},
    );
    _meta(params);
    final version = params['protocolVersion'];
    if (version is! String || version.isEmpty || version.length > 64) {
      throw const _RpcFault(-32602, 'invalid_params');
    }
    _object(
      params['capabilities'],
    ); // Offers are bounded metadata, not permissions.
    final info = _object(params['clientInfo']);
    _keys(
      info,
      {
        'name',
        'version',
        'title',
        'description',
        'icons',
        'websiteUrl',
        '_meta',
      },
      required: {'name', 'version'},
    );
    _meta(info);
    if (info['name'] is! String ||
        (info['name'] as String).isEmpty ||
        (info['name'] as String).length > 128 ||
        info['version'] is! String ||
        (info['version'] as String).isEmpty ||
        (info['version'] as String).length > 128) {
      throw const _RpcFault(-32602, 'invalid_params');
    }
    for (final key in ['title', 'description', 'websiteUrl']) {
      if (info.containsKey(key) && info[key] is! String)
        throw const _RpcFault(-32602, 'invalid_params');
    }
    if (info.containsKey('icons') && info['icons'] is! List)
      throw const _RpcFault(-32602, 'invalid_params');
    _initialized = true;
    return _rpcResult(id, {
      'protocolVersion': _versions.contains(version)
          ? version
          : _versions.first,
      'capabilities': {
        'tools': {'listChanged': false},
      },
      'serverInfo': {'name': 'shiyu-agent-proxy', 'version': '0.1.0'},
      'instructions':
          'Only locally granted access to one fixed source. Getting its reference does not read its text. '
          'Submission delivers a private review candidate, not a confirmed lesson or publication. '
          'Sender authorization does not verify an assistant brand, model or copyright declaration. '
          'If delivery outcome is unknown, verify only with the same delivery_id and identical content; '
          'do not create a new delivery ID to retry.',
    });
  }

  Future<Map<String, Object?>> _callTool(
    String name,
    Map<String, Object?> args,
  ) async {
    var submitResponseObserved = false;
    try {
      final media = MediaWireOperation.values
          .where((op) => op.toolName == name)
          .firstOrNull;
      if (media == null && _hasMedia(args))
        throw const AgentBridgeException(AgentBridgeErrorCode.unsupportedMedia);
      Map<String, Object?> result;
      if (media != null) {
        decodeMediaBridgePayload(
          media.wireName,
          encodeAgentBridgeJson(args, maxBytes: 192 * 1024),
        );
        result = await switch (media) {
          MediaWireOperation.begin => _client.beginMedia(args),
          MediaWireOperation.chunk => _client.putMediaChunk(args),
          MediaWireOperation.seal => _client.sealMedia(args),
          MediaWireOperation.submit => _client.submitMediaCandidate(args),
          MediaWireOperation.abort => _client.abortMedia(args),
        };
        submitResponseObserved = true;
      } else if (name == 'shiyu_get_source_reference') {
        _argumentKeys(args, const {});
        result = await _client.getSourceReference();
        _resultBinding(result, withText: false);
      } else if (name == 'shiyu_read_fixed_source') {
        _argumentKeys(args, _bindingNames, required: _bindingNames);
        _binding(args);
        result = await _client.readFixedSource(
          materialId: args['material_id'] as String,
          materialVersionId: args['material_version_id'] as String,
          sourceTextSha256: args['source_text_sha256'] as String,
        );
        _resultBinding(result, withText: true);
        if (_bindingNames.any((k) => result[k] != args[k]) ||
            hashes.sha256
                    .convert(utf8.encode(result['text'] as String))
                    .toString() !=
                result['source_text_sha256']) {
          throw const AgentBridgeException(AgentBridgeErrorCode.sourceMismatch);
        }
      } else {
        _candidate(args);
        result = await _client.submitCandidate(args);
        submitResponseObserved = true;
        if (result.keys.toSet().difference({
              'candidate_id',
              'payload_sha256',
              'replayed',
              'status',
            }).isNotEmpty ||
            result.length != 4 ||
            result['candidate_id'] is! String ||
            !_idPattern.hasMatch(result['candidate_id'] as String) ||
            result['payload_sha256'] is! String ||
            !_hashPattern.hasMatch(result['payload_sha256'] as String) ||
            result['replayed'] is! bool ||
            result['status'] != 'delivered') {
          // The App may already have durably accepted the candidate. A malformed
          // acknowledgement is not proof of non-delivery and must not cause a
          // blind resend with a different delivery ID.
          throw const AgentBridgeException(AgentBridgeErrorCode.outcomeUnknown);
        }
      }
      // The text compatibility block is fixed serialization of an allowlisted
      // result, never a raw response body/exception or descriptor diagnostics.
      final text = utf8.decode(
        encodeAgentBridgeJson(result, maxBytes: _responseBytes),
      );
      return {
        'content': [
          {'type': 'text', 'text': text},
        ],
        'structuredContent': result,
        'isError': false,
      };
    } on AgentBridgeException catch (error) {
      return _toolError(error.code.name);
    } catch (_) {
      return _toolError(
        submitResponseObserved ? 'outcomeUnknown' : 'unavailable',
      );
    }
  }

  void _validateToolArguments(String name, Map<String, Object?> args) {
    final media = MediaWireOperation.values
        .where((op) => op.toolName == name)
        .firstOrNull;
    if (media != null) {
      decodeMediaBridgePayload(
        media.wireName,
        encodeAgentBridgeJson(args, maxBytes: 192 * 1024),
      );
      return;
    }
    if (_hasMedia(args))
      throw const AgentBridgeException(AgentBridgeErrorCode.unsupportedMedia);
    if (name == 'shiyu_get_source_reference') {
      _argumentKeys(args, const {});
    } else if (name == 'shiyu_read_fixed_source') {
      _argumentKeys(args, _bindingNames, required: _bindingNames);
      _binding(args);
    } else {
      _candidate(args);
    }
  }

  Future<void> _send(
    BoundedStdioWriter output,
    Map<String, Object?> response,
  ) async {
    Uint8List bytes;
    try {
      bytes = encodeAgentBridgeJson(response, maxBytes: _responseBytes);
    } catch (_) {
      final fallback =
          response['result'] is Map &&
              (response['result'] as Map).containsKey('content')
          ? _rpcResult(response['id'], _toolError('tooLarge'))
          : _rpcError(response['id'], -32603, 'response_too_large');
      bytes = encodeAgentBridgeJson(fallback, maxBytes: _responseBytes);
    }
    await output.sendLine(bytes);
  }
}

const _toolNames = {
  'shiyu_get_source_reference',
  'shiyu_read_fixed_source',
  'shiyu_submit_learning_candidate',
  'shiyu_begin_media',
  'shiyu_put_media_chunk',
  'shiyu_seal_media',
  'shiyu_submit_media_candidate',
  'shiyu_abort_media',
};
final _tools = <Map<String, Object?>>[
  {
    'name': 'shiyu_get_source_reference',
    'title': 'Get selected source reference',
    'description': 'Returns only IDs/hash for the one source selected and locally granted in Shiyu, not its text or proof the assistant read it.',
    'inputSchema': {
      'type': 'object',
      'properties': {},
      'additionalProperties': false,
    },
    'annotations': {'readOnlyHint': true, 'openWorldHint': false},
  },
  {
    'name': 'shiyu_read_fixed_source',
    'title': 'Read the selected fixed source',
    'description': 'Reads only the exact source binding, with a separate explicit source:read grant. It cannot read other materials.',
    'inputSchema': {
      'type': 'object',
      'properties': _bindingProperties,
      'required': ['material_id', 'material_version_id', 'source_text_sha256'],
      'additionalProperties': false,
    },
    'annotations': {'readOnlyHint': true, 'openWorldHint': false},
  },
  {
    'name': 'shiyu_submit_learning_candidate',
    'title': 'Deliver a private text learning candidate',
    'description': 'Sends bilingual text for owner review against a fixed source. Does not confirm, publish, generate audio or score speech. Declarations remain unverified. UTF-8 size limits also apply.',
    'inputSchema': {
      'type': 'object',
      'additionalProperties': false,
      'required': [
        'schema_version',
        'material_id',
        'material_version_id',
        'source_text_sha256',
        'delivery_id',
        'sentences',
        'declaration',
      ],
      'properties': {
        ..._bindingProperties,
        'schema_version': {'type': 'integer', 'const': 1},
        'delivery_id': {'type': 'string', 'minLength': 1, 'maxLength': 256},
        'sentences': {
          'type': 'array',
          'minItems': 1,
          'maxItems': 128,
          'items': {
            'type': 'object',
            'additionalProperties': false,
            'required': ['english', 'translation'],
            'properties': {
              'english': {
                'type': 'string',
                'minLength': 1,
                'maxLength': 102400,
              },
              'translation': {
                'type': 'string',
                'minLength': 1,
                'maxLength': 102400,
              },
            },
          },
        },
        'declaration': {
          'type': 'object',
          'additionalProperties': false,
          'required': ['preparation'],
          'properties': {
            'preparation': {
              'type': 'string',
              'minLength': 1,
              'maxLength': 8192,
            },
            'provider': _optionalDeclarationText,
            'model': _optionalDeclarationText,
            'model_version': _optionalDeclarationText,
            'notes': _optionalDeclarationText,
          },
        },
      },
    },
    'annotations': {
      'readOnlyHint': false,
      'destructiveHint': false,
      'idempotentHint': true,
      'openWorldHint': false,
    },
  },
  ..._mediaTools,
];

Map<String, Object?> _rpcResult(Object? id, Map<String, Object?> result) => {
  'jsonrpc': '2.0',
  'id': id,
  'result': result,
};
Map<String, Object?> _rpcError(Object? id, int code, String message) => {
  'jsonrpc': '2.0',
  'id': id,
  'error': {'code': code, 'message': message},
};
Map<String, Object?> _toolError(String code) => {
  'content': [
    {
      'type': 'text',
      'text': jsonEncode({
        'error': {'code': code},
      }),
    },
  ],
  'structuredContent': {
    'error': {'code': code},
  },
  'isError': true,
};

bool _validRpcId(Object? value) {
  if (value is String)
    return value.length <= 128 && utf8.encode(value).length <= 256;
  return value is num &&
      value.isFinite &&
      value >= -9007199254740991 &&
      value <= 9007199254740991 &&
      value == value.truncateToDouble();
}

Map<String, Object?> _object(Object? value) {
  if (value is! Map<String, Object?>)
    throw const _RpcFault(-32602, 'invalid_params');
  return value;
}

void _keys(
  Map<String, Object?> value,
  Set<String> allowed, {
  Set<String> required = const {},
}) {
  if (value.keys.any((k) => !allowed.contains(k)) ||
      required.any((k) => !value.containsKey(k))) {
    throw const _RpcFault(-32602, 'invalid_params');
  }
}

void _meta(Map<String, Object?> value) {
  if (value.containsKey('_meta') && value['_meta'] is! Map<String, Object?>) {
    throw const _RpcFault(-32602, 'invalid_params');
  }
}

void _argumentKeys(
  Map<String, Object?> value,
  Set<String> allowed, {
  Set<String> required = const {},
}) {
  if (value.keys.any((k) => !allowed.contains(k)) ||
      required.any((k) => !value.containsKey(k))) {
    throw const AgentBridgeException(AgentBridgeErrorCode.invalidRequest);
  }
}

void _binding(Map<String, Object?> value) {
  if (value['material_id'] is! String ||
      !_idPattern.hasMatch(value['material_id'] as String) ||
      value['material_version_id'] is! String ||
      !_idPattern.hasMatch(value['material_version_id'] as String) ||
      value['source_text_sha256'] is! String ||
      !_hashPattern.hasMatch(value['source_text_sha256'] as String)) {
    throw const AgentBridgeException(AgentBridgeErrorCode.invalidRequest);
  }
}

bool _hasMedia(Object? value) {
  if (value is Map<String, Object?>) {
    return value.keys.any(_mediaNames.contains) || value.values.any(_hasMedia);
  }
  if (value is List) return value.any(_hasMedia);
  return false;
}

void _text(
  Object? value,
  int maxBytes, {
  bool empty = false,
  bool singleLine = false,
}) {
  if (value is! String || (!empty && value.trim().isEmpty)) {
    throw const AgentBridgeException(AgentBridgeErrorCode.invalidRequest);
  }
  if (value.length > maxBytes || utf8.encode(value).length > maxBytes) {
    throw const AgentBridgeException(AgentBridgeErrorCode.tooLarge);
  }
  for (final u in value.codeUnits) {
    if (u == 127 ||
        (u >= 0x80 && u <= 0x9f) ||
        (u < 32 && (singleLine || (u != 9 && u != 10 && u != 13)))) {
      throw const AgentBridgeException(AgentBridgeErrorCode.invalidRequest);
    }
  }
}

void _candidate(Map<String, Object?> value) {
  _argumentKeys(
    value,
    {
      ..._bindingNames,
      'schema_version',
      'delivery_id',
      'sentences',
      'declaration',
    },
    required: {
      ..._bindingNames,
      'schema_version',
      'delivery_id',
      'sentences',
      'declaration',
    },
  );
  _binding(value);
  if (value['schema_version'] is! int || value['schema_version'] != 1) {
    throw const AgentBridgeException(AgentBridgeErrorCode.invalidRequest);
  }
  _text(value['delivery_id'], 256, singleLine: true);
  final sentences = value['sentences'];
  if (sentences is! List || sentences.isEmpty || sentences.length > 128) {
    throw const AgentBridgeException(AgentBridgeErrorCode.invalidRequest);
  }
  var bytes = 0;
  for (final raw in sentences) {
    if (raw is! Map<String, Object?>)
      throw const AgentBridgeException(AgentBridgeErrorCode.invalidRequest);
    _argumentKeys(
      raw,
      {'english', 'translation'},
      required: {'english', 'translation'},
    );
    _text(raw['english'], 102400);
    _text(raw['translation'], 102400);
    bytes +=
        utf8.encode(raw['english'] as String).length +
        utf8.encode(raw['translation'] as String).length;
  }
  if (bytes > 102400)
    throw const AgentBridgeException(AgentBridgeErrorCode.tooLarge);
  final d = value['declaration'];
  if (d is! Map<String, Object?>)
    throw const AgentBridgeException(AgentBridgeErrorCode.invalidRequest);
  _argumentKeys(
    d,
    {'preparation', 'provider', 'model', 'model_version', 'notes'},
    required: {'preparation'},
  );
  _text(d['preparation'], 8192);
  for (final key in ['provider', 'model', 'model_version', 'notes']) {
    if (d[key] != null) _text(d[key], 8192, empty: true);
  }
  encodeAgentBridgeJson(d, maxBytes: 8192);
}

void _resultBinding(Map<String, Object?> value, {required bool withText}) {
  final expected = {..._bindingNames, if (withText) 'text'};
  if (value.length != expected.length ||
      value.keys.any((k) => !expected.contains(k))) {
    throw const AgentBridgeException(AgentBridgeErrorCode.unavailable);
  }
  try {
    _binding(value);
  } catch (_) {
    throw const AgentBridgeException(AgentBridgeErrorCode.unavailable);
  }
  if (withText) _text(value['text'], 128 * 1024, empty: true);
}

final class _RpcFault implements Exception {
  const _RpcFault(this.code, this.message);
  final int code;
  final String message;
}

final class _StdioFault implements Exception {
  const _StdioFault(this.code);
  final String code;
}

final class _StdioLineReader {
  _StdioLineReader(Stream<List<int>> input) : _iterator = StreamIterator(input);
  final StreamIterator<List<int>> _iterator;
  final _stopped = Completer<bool>();
  final _bytes = BytesBuilder(copy: false);
  List<int> _piece = const [];
  int _offset = 0;
  DateTime? _started;
  void stop() {
    if (!_stopped.isCompleted) _stopped.complete(false);
    Future<void>.sync(_iterator.cancel).ignore();
  }

  Future<Uint8List?> next() async {
    while (!_stopped.isCompleted) {
      if (_offset == _piece.length) {
        var moving = _iterator.moveNext();
        moving.ignore();
        if (_started != null) {
          final left =
              const Duration(seconds: 15) -
              DateTime.now().difference(_started!);
          if (left <= Duration.zero) throw const _StdioFault('timeout');
          moving = moving.timeout(
            left,
            onTimeout: () => throw const _StdioFault('timeout'),
          );
          moving.ignore();
        }
        final hasNext = await Future.any<bool>([moving, _stopped.future]);
        if (_stopped.isCompleted) return null;
        if (!hasNext) {
          if (_bytes.length != 0) throw const _StdioFault('incomplete_frame');
          return null;
        }
        _piece = _iterator.current;
        _offset = 0;
      }
      while (_offset < _piece.length) {
        final byte = _piece[_offset++];
        if (byte < 0 || byte > 255) throw const _StdioFault('parse_error');
        if (byte == 10) {
          _started = null;
          return _bytes.takeBytes();
        }
        _started ??= DateTime.now();
        if (_bytes.length >= _requestBytes) throw const _StdioFault('tooLarge');
        _bytes.addByte(byte);
      }
    }
    return null;
  }
}

Map<String, Object?> _mediaContainerSchema({required bool complete}) => {
  'type': 'object',
  'additionalProperties': false,
  'required': [
    'sha256',
    'byte_length',
    'pcm',
    'timings',
    'declaration',
    'timing_declaration',
    if (complete) 'english_sha256',
  ],
  'properties': {
    'sha256': {'type': 'string', 'pattern': r'^[0-9a-f]{64}$'},
    'byte_length': {'type': 'integer', 'minimum': 46, 'maximum': 1920044},
    if (complete)
      'english_sha256': {'type': 'string', 'pattern': r'^[0-9a-f]{64}$'},
    'pcm': {
      'type': 'object',
      'additionalProperties': false,
      'required': ['format', 'channels', 'sample_rate', 'bits_per_sample'],
      'properties': {
        'format': {'type': 'integer', 'const': 1},
        'channels': {'type': 'integer', 'const': 1},
        'sample_rate': {'type': 'integer', 'const': 16000},
        'bits_per_sample': {'type': 'integer', 'const': 16},
      },
    },
    'timings': {
      'type': 'array',
      'minItems': 1,
      'maxItems': 128,
      'items': {
        'type': 'object',
        'additionalProperties': false,
        'required': ['sentence_index', 'start_ms', 'end_ms'],
        'properties': {
          'sentence_index': {'type': 'integer', 'minimum': 0, 'maximum': 127},
          'start_ms': {'type': 'integer', 'minimum': 0, 'maximum': 60000},
          'end_ms': {'type': 'integer', 'minimum': 1, 'maximum': 60000},
        },
      },
    },
    'declaration': _mediaDeclarationSchema,
    'timing_declaration': {'type': 'string', 'minLength': 1, 'maxLength': 8192},
  },
};
const _mediaDeclarationSchema = {
  'type': 'object',
  'additionalProperties': false,
  'required': ['preparation'],
  'properties': {
    'preparation': {'type': 'string', 'minLength': 1, 'maxLength': 8192},
    'provider': _optionalDeclarationText,
    'model': _optionalDeclarationText,
    'model_version': _optionalDeclarationText,
    'notes': _optionalDeclarationText,
  },
};
final _mediaTools = <Map<String, Object?>>[
  for (final operation in MediaWireOperation.values)
    {
      'name': operation.toolName,
      'description': operation == MediaWireOperation.chunk
          ? 'Code/SDK data plane only: transfers one bounded PCM chunk. Do not compose or copy audio base64 in model context. Requires explicit media scope.'
          : 'Explicitly scoped private media ${operation.name}; does not confirm, publish, play or withdraw committed content. Declarations remain unverified.',
      'inputSchema': {
        'type': 'object',
        'additionalProperties': false,
        'required': [
          'schema_version',
          ..._bindingNames,
          if (operation == MediaWireOperation.begin) ...[
            'delivery_id',
            'submission_sha256',
            'english_sha256',
            'media',
          ],
          if (operation == MediaWireOperation.chunk) ...[
            'upload_id',
            'index',
            'bytes_base64',
            'chunk_sha256',
          ],
          if (operation == MediaWireOperation.seal ||
              operation == MediaWireOperation.abort)
            'upload_id',
          if (operation == MediaWireOperation.submit) ...[
            'delivery_id',
            'sentences',
            'declaration',
            'media',
            'sealed_receipt',
          ],
        ],
        'properties': {
          ..._bindingProperties,
          'schema_version': {'type': 'integer', 'const': 2},
          if (operation == MediaWireOperation.begin ||
              operation == MediaWireOperation.submit)
            'delivery_id': {'type': 'string', 'minLength': 1, 'maxLength': 256},
          if (operation == MediaWireOperation.begin) ...{
            'submission_sha256': {
              'type': 'string',
              'pattern': r'^[0-9a-f]{64}$',
            },
            'english_sha256': {'type': 'string', 'pattern': r'^[0-9a-f]{64}$'},
            'media': _mediaContainerSchema(complete: false),
          },
          if (operation == MediaWireOperation.chunk) ...{
            'index': {'type': 'integer', 'minimum': 0, 'maximum': 31},
            'bytes_base64': {
              'type': 'string',
              'minLength': 4,
              'maxLength': 87384,
            },
            'chunk_sha256': {'type': 'string', 'pattern': r'^[0-9a-f]{64}$'},
          },
          if (operation == MediaWireOperation.chunk ||
              operation == MediaWireOperation.seal ||
              operation == MediaWireOperation.abort)
            'upload_id': {'type': 'string', 'pattern': r'^[0-9a-f]{32}$'},
          if (operation == MediaWireOperation.submit) ...{
            'sealed_receipt': {'type': 'string', 'pattern': r'^[0-9a-f]{64}$'},
            'sentences': {
              'type': 'array',
              'minItems': 1,
              'maxItems': 128,
              'items': {
                'type': 'object',
                'additionalProperties': false,
                'required': ['english', 'translation'],
                'properties': {
                  'english': {
                    'type': 'string',
                    'minLength': 1,
                    'maxLength': 102400,
                  },
                  'translation': {
                    'type': 'string',
                    'minLength': 1,
                    'maxLength': 102400,
                  },
                },
              },
            },
            'declaration': _mediaDeclarationSchema,
            'media': _mediaContainerSchema(complete: true),
          },
        },
      },
      'annotations': {
        'readOnlyHint': false,
        'destructiveHint': false,
        'idempotentHint': true,
        'openWorldHint': false,
      },
    },
];
