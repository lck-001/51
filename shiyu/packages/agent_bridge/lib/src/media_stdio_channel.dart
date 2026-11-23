import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'contracts.dart';
import 'media_wire.dart';
import 'strict_json.dart';
import 'wire.dart' show bridgeObject;

enum MediaChannelState {
  attached,
  running,
  initializing,
  ready,
  stopping,
  terminal,
}

enum MediaChannelErrorCode {
  closed,
  notRunning,
  notReady,
  busy,
  protocolFault,
  deadline,
  inputEof,
  outputFailure,
  idLimit,
  frameLimit,
  invalidRequest,
}

enum MediaRequestExecution { notSent, rejected, unknown }

final class MediaChannelException implements Exception {
  const MediaChannelException(this.code, this.execution);
  final MediaChannelErrorCode code;
  final MediaRequestExecution execution;
  @override
  String toString() => 'MediaChannelException(${code.name},${execution.name})';
}

final class MediaChannelTermination {
  const MediaChannelTermination(this.code);
  final MediaChannelErrorCode code;
  @override
  String toString() => 'MediaChannelTermination(${code.name})';
}

final class MediaChannelReady {
  MediaChannelReady(this.protocolVersion, Set<String> tools)
    : tools = Set.unmodifiable(tools);
  final String protocolVersion;
  final Set<String> tools;
}

enum MediaToolReplyKind { success, rejected, unknown }

final class MediaToolReply {
  MediaToolReply.success(Map<String, Object?> result)
    : kind = MediaToolReplyKind.success,
      result = Map.unmodifiable(result),
      code = null,
      channelError = null;
  const MediaToolReply.rejected(this.code)
    : kind = MediaToolReplyKind.rejected,
      result = null,
      channelError = null;
  const MediaToolReply.unknown([this.channelError])
    : kind = MediaToolReplyKind.unknown,
      result = null,
      code = AgentBridgeErrorCode.outcomeUnknown;
  final MediaToolReplyKind kind;
  final Map<String, Object?>? result;
  final AgentBridgeErrorCode? code;
  final MediaChannelErrorCode? channelError;
}

final class _Pending {
  _Pending(this.id, this.line, this.control, this.validate);
  final int id;
  final Uint8List line;
  final bool control;
  final Object Function(Map<String, Object?>) validate;
  final done = Completer<Object>();
  Timer? timer;
  bool started = false, flushed = false, hasReply = false;
  Object? reply;
}

/// Borrows its pipe and child. Owns subscriptions, bounded tickets and deadlines
/// only. Supplied producers/sinks must cooperate and never block this isolate.
final class MediaStdioChannel {
  MediaStdioChannel.attach({
    required Stream<List<int>> responseBytes,
    required IOSink requestSink,
  }) : _input = responseBytes,
       _sink = requestSink is Stdout ? requestSink.nonBlocking : requestSink;
  final Stream<List<int>> _input;
  final IOSink _sink;
  MediaChannelState _state = MediaChannelState.attached;
  MediaChannelState get state => _state;
  StreamSubscription<List<int>>? _subscription;
  final _ended = Completer<MediaChannelTermination>(),
      _stop = Completer<void>();
  final _pending = <int, _Pending>{}, _used = <int>{};
  final _writes = Queue<_Pending>();
  final _line = BytesBuilder(copy: false);
  _Pending? _normal, _control;
  bool _writing = false;
  int _next = 1, _frames = 0;
  Future<void>? _closing;
  Future<MediaChannelReady>? _initializingTask;
  Future<MediaChannelTermination> run() {
    if (_state != MediaChannelState.attached)
      throw const MediaChannelException(
        MediaChannelErrorCode.notRunning,
        MediaRequestExecution.notSent,
      );
    _state = MediaChannelState.running;
    try {
      _subscription = _input.listen(
        _data,
        onError: (Object _) => _finish(MediaChannelErrorCode.protocolFault),
        onDone: () => _finish(MediaChannelErrorCode.inputEof),
      );
    } catch (_) {
      _finish(MediaChannelErrorCode.protocolFault);
    }
    return _ended.future;
  }

  Future<MediaChannelReady> initialize({
    String protocolVersion = '2025-11-25',
    String clientName = 'shiyu-code-sdk',
    String clientVersion = '0.1.0',
  }) {
    if (_state != MediaChannelState.running || _initializingTask != null) {
      return Future.error(
        const MediaChannelException(
          MediaChannelErrorCode.notRunning,
          MediaRequestExecution.notSent,
        ),
      );
    }
    final task = _initialize(
      protocolVersion: protocolVersion,
      clientName: clientName,
      clientVersion: clientVersion,
    );
    _initializingTask = task;
    task.ignore();
    return task;
  }

  Future<MediaChannelReady> _initialize({
    required String protocolVersion,
    required String clientName,
    required String clientVersion,
  }) async {
    if (_state != MediaChannelState.running)
      throw const MediaChannelException(
        MediaChannelErrorCode.notRunning,
        MediaRequestExecution.notSent,
      );
    _state = MediaChannelState.initializing;
    try {
      final selected = await _rpc<String>(
        'initialize',
        {
          'protocolVersion': protocolVersion,
          'capabilities': <String, Object?>{},
          'clientInfo': {'name': clientName, 'version': clientVersion},
        },
        false,
        (reply) {
          final result = _result(reply);
          if (!{
                '2025-11-25',
                '2025-06-18',
              }.contains(result['protocolVersion']) ||
              result['serverInfo'] is! Map ||
              result['capabilities'] is! Map)
            throw const FormatException();
          return result['protocolVersion'] as String;
        },
      );
      if (_state != MediaChannelState.initializing)
        throw const MediaChannelException(
          MediaChannelErrorCode.closed,
          MediaRequestExecution.notSent,
        );
      // One ordered notification. There is deliberately no response to await.
      await _notification({
        'jsonrpc': '2.0',
        'method': 'notifications/initialized',
      });
      final tools = await _rpc<Set<String>>('tools/list', {}, false, (reply) {
        final result = _result(reply), raw = result['tools'];
        if (raw is! List || raw.length != 8) throw const FormatException();
        final names = <String>{};
        for (final value in raw) {
          if (value is! Map ||
              value['name'] is! String ||
              value['inputSchema'] is! Map ||
              !names.add(value['name'] as String))
            throw const FormatException();
          final operation = MediaWireOperation.values
              .where((op) => op.toolName == value['name'])
              .firstOrNull;
          if (operation != null) _mediaSchema(operation, value['inputSchema']);
        }
        if (!names.containsAll({
          'shiyu_get_source_reference',
          'shiyu_read_fixed_source',
          'shiyu_submit_learning_candidate',
          ...MediaWireOperation.values.map((op) => op.toolName),
        }))
          throw const FormatException();
        return names;
      });
      if (_state != MediaChannelState.initializing)
        throw const MediaChannelException(
          MediaChannelErrorCode.closed,
          MediaRequestExecution.notSent,
        );
      _state = MediaChannelState.ready;
      return MediaChannelReady(selected, tools);
    } catch (error) {
      _finish(MediaChannelErrorCode.protocolFault);
      if (error is MediaChannelException) rethrow;
      throw const MediaChannelException(
        MediaChannelErrorCode.protocolFault,
        MediaRequestExecution.rejected,
      );
    }
  }

  void _mediaSchema(MediaWireOperation operation, Object? raw) {
    Map object(Object? value, Set<String> fields, {Set<String>? required}) {
      if (value is! Map ||
          value['type'] != 'object' ||
          value['additionalProperties'] != false ||
          value['properties'] is! Map ||
          value['required'] is! List)
        throw const FormatException();
      final props = value['properties'] as Map,
          needs = value['required'] as List;
      final expected = required ?? fields;
      if (props.length != fields.length ||
          !fields.every(props.containsKey) ||
          needs.length != expected.length ||
          needs.any((v) => v is! String) ||
          needs.toSet().length != needs.length ||
          !expected.every(needs.contains))
        throw const FormatException();
      return props;
    }

    void declaration(Object? schema) => object(
      schema,
      {'preparation', 'provider', 'model', 'model_version', 'notes'},
      required: {'preparation'},
    );
    void media(Object? schema, {required bool complete}) {
      final p = object(schema, {
        'sha256',
        'byte_length',
        'pcm',
        'timings',
        'declaration',
        'timing_declaration',
        if (complete) 'english_sha256',
      });
      object(p['pcm'], {
        'format',
        'channels',
        'sample_rate',
        'bits_per_sample',
      });
      declaration(p['declaration']);
      final timings = p['timings'];
      if (timings is! Map || timings['type'] != 'array')
        throw const FormatException();
      object(timings['items'], {'sentence_index', 'start_ms', 'end_ms'});
    }

    final fields = {
      'schema_version',
      'material_id',
      'material_version_id',
      'source_text_sha256',
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
    };
    final props = object(raw, fields), version = props['schema_version'];
    if (version is! Map ||
        version['type'] != 'integer' ||
        version['const'] is! int ||
        version['const'] != 2)
      throw const FormatException();
    if (operation == MediaWireOperation.begin ||
        operation == MediaWireOperation.submit)
      media(props['media'], complete: operation == MediaWireOperation.submit);
    if (operation == MediaWireOperation.submit) {
      declaration(props['declaration']);
      final sentences = props['sentences'];
      if (sentences is! Map || sentences['type'] != 'array')
        throw const FormatException();
      object(sentences['items'], {'english', 'translation'});
    }
  }

  Future<MediaToolReply> invoke(
    MediaWireOperation operation,
    Map<String, Object?> arguments,
  ) async {
    if (_state != MediaChannelState.ready)
      throw const MediaChannelException(
        MediaChannelErrorCode.notReady,
        MediaRequestExecution.notSent,
      );
    late Map<String, Object?> snapshot;
    late MediaWireRequest decoded;
    try {
      final bytes = encodeAgentBridgeJson(arguments, maxBytes: 196608);
      decoded = decodeMediaBridgePayload(operation.wireName, bytes);
      snapshot = Map<String, Object?>.from(
        decodeAgentBridgeJson(bytes, maxBytes: 196608) as Map,
      );
    } on AgentBridgeException catch (error) {
      return MediaToolReply.rejected(error.code);
    }
    try {
      return await _rpc<MediaToolReply>(
        'tools/call',
        {'name': operation.toolName, 'arguments': snapshot},
        operation == MediaWireOperation.abort,
        (reply) => _toolResult(reply, operation, snapshot, decoded),
      );
    } on MediaChannelException catch (error) {
      if (error.execution == MediaRequestExecution.unknown)
        return MediaToolReply.unknown(error.code);
      rethrow;
    }
  }

  Future<T> _rpc<T extends Object>(
    String method,
    Map<String, Object?> params,
    bool control,
    T Function(Map<String, Object?>) validate,
  ) {
    if (_state == MediaChannelState.stopping ||
        _state == MediaChannelState.terminal ||
        _state == MediaChannelState.attached)
      throw const MediaChannelException(
        MediaChannelErrorCode.closed,
        MediaRequestExecution.notSent,
      );
    if (control ? _control != null : _normal != null)
      throw const MediaChannelException(
        MediaChannelErrorCode.busy,
        MediaRequestExecution.notSent,
      );
    if (_used.length >= 4096) {
      _finish(MediaChannelErrorCode.idLimit);
      throw const MediaChannelException(
        MediaChannelErrorCode.idLimit,
        MediaRequestExecution.notSent,
      );
    }
    final id = _next++;
    late Uint8List bytes;
    try {
      bytes = encodeAgentBridgeJson({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      }, maxBytes: 262144);
    } catch (_) {
      throw const MediaChannelException(
        MediaChannelErrorCode.invalidRequest,
        MediaRequestExecution.notSent,
      );
    }
    final p = _Pending(id, bytes, control, validate);
    p.done.future.ignore();
    _used.add(id);
    _pending[id] = p;
    if (control) {
      _control = p;
    } else {
      _normal = p;
    }
    p.timer = Timer(
      const Duration(seconds: 25),
      () => _finish(MediaChannelErrorCode.deadline),
    );
    _writes.add(p);
    if (!_writing) {
      _writing = true;
      _pump().ignore();
    }
    return p.done.future.then((value) => value as T);
  }

  Future<void> _notification(Map<String, Object?> value) async {
    if (_writes.isNotEmpty || _writing)
      throw const MediaChannelException(
        MediaChannelErrorCode.busy,
        MediaRequestExecution.notSent,
      );
    final bytes = encodeAgentBridgeJson(value, maxBytes: 262144);
    try {
      _sink.add(bytes);
      _sink.add(const [10]);
      final flushing = Future<void>.sync(_sink.flush);
      flushing.ignore();
      await Future.any([flushing, _stop.future])
          .timeout(const Duration(seconds: 25));
      if (_state != MediaChannelState.initializing)
        throw const FormatException();
    } catch (_) {
      _finish(MediaChannelErrorCode.outputFailure);
      throw const MediaChannelException(
        MediaChannelErrorCode.outputFailure,
        MediaRequestExecution.unknown,
      );
    }
  }

  Future<void> _pump() async {
    try {
      while (_writes.isNotEmpty && _state != MediaChannelState.terminal) {
        final p = _writes.first;
        if (p.done.isCompleted) {
          _writes.removeFirst();
          continue;
        }
        try {
          p.started = true;
          _sink.add(p.line);
          _sink.add(const [10]);
          final flush = Future<void>.sync(_sink.flush);
          flush.ignore();
          await Future.any([flush, _stop.future]);
          if (_state == MediaChannelState.terminal) return;
          _writes.removeFirst();
          p.flushed = true;
          _complete(p);
        } catch (_) {
          _finish(MediaChannelErrorCode.outputFailure);
          return;
        }
      }
    } finally {
      _writing = false;
    }
  }

  void _data(List<int> bytes) {
    if (_state == MediaChannelState.terminal) return;
    try {
      for (final c in bytes) {
        if (c < 0 || c > 255) throw const FormatException();
        if (c == 10) {
          if (++_frames > 8192) {
            _finish(MediaChannelErrorCode.frameLimit);
            return;
          }
          _reply(decodeAgentBridgeJson(_line.takeBytes(), maxBytes: 524288));
          if (_state == MediaChannelState.terminal) return;
        } else {
          if (_line.length >= 524288) throw const FormatException();
          _line.addByte(c);
        }
      }
    } catch (_) {
      _finish(MediaChannelErrorCode.protocolFault);
    }
  }

  void _reply(Object? raw) {
    if (raw is! Map) throw const FormatException();
    final hasError = raw.containsKey('error');
    final reply = bridgeObject(raw, {
      'jsonrpc',
      'id',
      hasError ? 'error' : 'result',
    });
    final id = reply['id'];
    if (reply['jsonrpc'] != '2.0' ||
        id is! num ||
        !id.isFinite ||
        id != id.truncateToDouble() ||
        id.abs() > 9007199254740991)
      throw const FormatException();
    final p = _pending[id.toInt()];
    if (p == null || p.hasReply) throw const FormatException();
    p.reply = p.validate(reply);
    p.hasReply = true;
    _complete(p);
  }

  void _complete(_Pending p) {
    if (!p.hasReply || !p.flushed || p.done.isCompleted) return;
    _remove(p);
    p.done.complete(p.reply!);
  }

  void _remove(_Pending p) {
    p.timer?.cancel();
    _pending.remove(p.id);
    if (identical(_normal, p)) _normal = null;
    if (identical(_control, p)) _control = null;
  }

  void _finish(MediaChannelErrorCode code) {
    if (_state == MediaChannelState.terminal) return;
    _state = MediaChannelState.terminal;
    if (!_stop.isCompleted) _stop.complete();
    for (final p in _pending.values.toList()) {
      _remove(p);
      if (p.done.isCompleted) continue;
      if (p.hasReply) {
        p.done.complete(p.reply!);
      } else {
        p.done.completeError(
          MediaChannelException(
            code,
            p.started
                ? MediaRequestExecution.unknown
                : MediaRequestExecution.notSent,
          ),
        );
      }
    }
    _writes.clear();
    final subscription = _subscription;
    if (subscription != null) Future<void>.sync(subscription.cancel).ignore();
    if (!_ended.isCompleted) _ended.complete(MediaChannelTermination(code));
  }

  Future<void> close() {
    if (_closing != null) return _closing!;
    if (_state != MediaChannelState.terminal)
      _state = MediaChannelState.stopping;
    final pending = <Future<Object>>[
      ..._pending.values.map((p) => p.done.future),
      if (_initializingTask != null) _initializingTask!,
    ];
    if (_pending.isEmpty) _finish(MediaChannelErrorCode.closed);
    return _closing = () async {
      await Future.wait(
        pending.map((f) => f.then<void>((_) {}, onError: (Object _) {})),
      );
      _finish(MediaChannelErrorCode.closed);
    }();
  }

  Map<String, Object?> _result(Map<String, Object?> reply) {
    if (reply.containsKey('error')) throw const FormatException();
    final result = reply['result'];
    if (result is! Map) throw const FormatException();
    return Map<String, Object?>.from(result);
  }

  MediaToolReply _toolResult(
    Map<String, Object?> reply,
    MediaWireOperation operation,
    Map<String, Object?> input,
    MediaWireRequest decoded,
  ) {
    if (reply.containsKey('error')) {
      final error = bridgeObject(reply['error'], {'code', 'message'});
      if (error['code'] is! int || error['message'] is! String)
        throw const FormatException();
      if ({-32600, -32601, -32602, -32000}.contains(error['code']))
        return const MediaToolReply.rejected(
          AgentBridgeErrorCode.invalidRequest,
        );
      throw const FormatException();
    }
    final wrapper = bridgeObject(reply['result'], {
      'content',
      'structuredContent',
      'isError',
    });
    final content = wrapper['content'],
        structured = wrapper['structuredContent'];
    if (wrapper['isError'] is! bool ||
        content is! List ||
        content.length != 1 ||
        structured is! Map)
      throw const FormatException();
    final text = bridgeObject(content.single, {'type', 'text'});
    if (text['type'] != 'text' || text['text'] is! String)
      throw const FormatException();
    final parsed = decodeAgentBridgeJson(
      utf8.encode(text['text'] as String),
      maxBytes: 524288,
    );
    if (jsonEncode(parsed) != jsonEncode(structured))
      throw const FormatException();
    final result = Map<String, Object?>.from(structured);
    if (wrapper['isError'] == true) {
      final body = bridgeObject(result, {'error'}),
          error = bridgeObject(body['error'], {'code'});
      final code = AgentBridgeErrorCode.values
          .where((c) => c.name == error['code'])
          .firstOrNull;
      if (code == null) throw const FormatException();
      return code == AgentBridgeErrorCode.outcomeUnknown
          ? const MediaToolReply.unknown()
          : MediaToolReply.rejected(code);
    }
    void hex(Object? v, int n) {
      if (v is! String || !RegExp('^[0-9a-f]{$n}' + r'$').hasMatch(v))
        throw const FormatException();
    }

    void integer(Object? v, int min, int max) {
      if (v is! int || v < min || v > max) throw const FormatException();
    }

    void replay() {
      if (result['replayed'] is! bool) throw const FormatException();
    }

    void upload() {
      hex(result['upload_id'], 32);
      if (result['upload_id'] != input['upload_id'])
        throw const FormatException();
    }

    switch (operation) {
      case MediaWireOperation.begin:
        bridgeObject(result, {
          'upload_id',
          'raw_chunk_bytes',
          'next_index',
          'status',
          'replayed',
        });
        hex(result['upload_id'], 32);
        integer(result['raw_chunk_bytes'], 65536, 65536);
        integer(result['next_index'], 0, 30);
        replay();
        if (!{'receiving', 'sealed', 'terminal'}.contains(result['status']))
          throw const FormatException();
      case MediaWireOperation.chunk:
        bridgeObject(result, {
          'upload_id',
          'index',
          'accepted_bytes',
          'status',
          'replayed',
        });
        upload();
        integer(result['index'], 0, 29);
        integer(result['accepted_bytes'], 1, 1920044);
        replay();
        if (result['index'] != input['index'] ||
            result['status'] != 'receiving')
          throw const FormatException();
        final length = decodeCanonicalBridgeBase64(
          input['bytes_base64'] as String,
          maximumBytes: 65536,
        ).length;
        if ((result['accepted_bytes'] as int) <
            (input['index'] as int) * 65536 + length)
          throw const FormatException();
      case MediaWireOperation.seal:
        bridgeObject(result, {
          'upload_id',
          'sealed_receipt',
          'status',
          'replayed',
        });
        upload();
        hex(result['sealed_receipt'], 64);
        replay();
        if (result['status'] != 'sealed') throw const FormatException();
      case MediaWireOperation.submit:
        bridgeObject(result, {
          'candidate_id',
          'payload_sha256',
          'replayed',
          'status',
        });
        hex(result['candidate_id'], 32);
        hex(result['payload_sha256'], 64);
        replay();
        if (result['status'] != 'delivered' ||
            result['payload_sha256'] !=
                (decoded as MediaWireSubmit).submission.media.submissionSha256)
          throw const FormatException();
      case MediaWireOperation.abort:
        bridgeObject(result, {'upload_id', 'status'});
        upload();
        if (result['status'] != 'terminal') throw const FormatException();
    }
    return MediaToolReply.success(result);
  }
}
