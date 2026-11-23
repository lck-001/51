import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:learning_core/learning_core.dart';

import 'media_ingest.dart';
import 'media_stdio_channel.dart';
import 'media_wire.dart';
import 'strict_json.dart';

typedef StreamSourceFactory = FutureOr<Stream<List<int>>> Function();

enum MediaTransferStage {
  preflight,
  sourcePass1,
  begin,
  sourcePass2,
  chunk,
  seal,
  submit,
  abort,
  done,
}

enum MediaTransferStatus {
  delivered,
  terminal,
  rejected,
  unknown,
  needsReconcile,
  localFailure,
}

enum MediaTransferCode {
  none,
  invalidInput,
  sourceRequired,
  sourceInvalid,
  sourceTooLarge,
  sourceTimeout,
  sourceChanged,
  sourceFailure,
  cancelled,
  channelUnavailable,
  busy,
  remoteRejected,
  uncertain,
}

final class MediaTransferInput {
  MediaTransferInput({
    required this.binding,
    required this.deliveryId,
    required List<LearningSentenceInput> sentences,
    required this.textDeclaration,
    required this.mediaDeclaration,
    required List<SentenceTiming> timings,
    required this.timingDeclaration,
  }) : sentences = List.unmodifiable(sentences),
       timings = List.unmodifiable(timings);
  final MediaIngestSourceBinding binding;
  final String deliveryId, timingDeclaration;
  final List<LearningSentenceInput> sentences;
  final SourceDeclaration textDeclaration, mediaDeclaration;
  final List<SentenceTiming> timings;
}

final class OpaqueMediaProgress {
  OpaqueMediaProgress._();
  MediaTransferStage _stage = MediaTransferStage.preflight;
  bool _cancelRequested = false, _needsCallerAction = false;
  MediaTransferStage get stage => _stage;
  bool get cancelRequested => _cancelRequested;
  bool get needsCallerAction => _needsCallerAction;
  @override
  String toString() => 'OpaqueMediaProgress(${stage.name})';
}

final class MediaTransferOutcome {
  const MediaTransferOutcome._(
    this.status,
    this.code,
    this.progress, {
    this.receipt,
    this.remoteCode,
  });
  final MediaTransferStatus status;
  final MediaTransferCode code;
  final OpaqueMediaProgress progress;
  final Map<String, Object?>? receipt;
  final String? remoteCode;
  @override
  String toString() => 'MediaTransferOutcome(${status.name},${code.name})';
}

final class _SourceProblem implements Exception {
  const _SourceProblem(this.code);
  final MediaTransferCode code;
}

final class _Stopped implements Exception {
  const _Stopped();
}

final class _RemoteStop implements Exception {
  const _RemoteStop(this.reply);
  final MediaToolReply reply;
}

final class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest value) {
    this.value = value;
  }

  @override
  void close() {}
}

final class _Fingerprint {
  _Fingerprint(this.length, this.sha, this.hashes);
  final int length;
  final String sha;
  final List<String> hashes;
  bool same(_Fingerprint other) =>
      length == other.length &&
      sha == other.sha &&
      jsonEncode(hashes) == jsonEncode(other.hashes);
}

abstract interface class _ActiveSourceOperation {
  void cancel();
}

/// At most one active open/read. No listener is attached to a shared pending
/// cancellation Future. Once settled, the provider's observer retains no SDK
/// owner, iterator or timer through this ticket.
final class _SourceTicket<T> implements _ActiveSourceOperation {
  _SourceTicket(this._owner, Duration timeout) {
    _timer = Timer(timeout, _timeout);
    future.ignore();
  }
  _SourceReadGate? _owner;
  Timer? _timer;
  Completer<T>? _continuation = Completer<T>();
  Future<T> get future => _continuation!.future;
  void observe(Future<T> provider) {
    provider.then<void>(success, onError: failure).ignore();
  }

  void _release() {
    _timer?.cancel();
    _timer = null;
    final owner = _owner;
    _owner = null;
    owner?.release(this);
  }

  void success(T value) {
    final continuation = _continuation;
    if (continuation == null) return;
    _continuation = null;
    _release();
    continuation.complete(value);
  }

  void failure(Object error, StackTrace stack) {
    final continuation = _continuation;
    if (continuation == null) return;
    _continuation = null;
    _release();
    continuation.completeError(
      const _SourceProblem(MediaTransferCode.sourceFailure),
    );
  }

  void _timeout() {
    final continuation = _continuation;
    if (continuation == null) return;
    _continuation = null;
    _release();
    continuation.completeError(
      const _SourceProblem(MediaTransferCode.sourceTimeout),
    );
  }

  @override
  void cancel() {
    final continuation = _continuation;
    if (continuation == null) return;
    _continuation = null;
    _release();
    continuation.completeError(const _Stopped());
  }
}

final class _SourceReadGate {
  _ActiveSourceOperation? _active;
  _SourceTicket<T> _start<T>(Duration timeout) {
    if (_active != null)
      throw const _SourceProblem(MediaTransferCode.sourceFailure);
    final ticket = _SourceTicket<T>(this, timeout);
    _active = ticket;
    return ticket;
  }

  Future<Stream<List<int>>> open(StreamSourceFactory factory) {
    final ticket = _start<Stream<List<int>>>(const Duration(seconds: 15));
    final result = ticket.future;
    try {
      ticket.observe(Future<Stream<List<int>>>.value(factory()));
    } catch (error, stack) {
      ticket.failure(error, stack);
    }
    return result;
  }

  Future<bool> next(StreamIterator<List<int>> iterator, Duration timeout) {
    final ticket = _start<bool>(timeout);
    final result = ticket.future;
    // Direct call avoids a StreamIterator instance tear-off/closure in the hot
    // async reader on Dart3.14's default optimizing VM.
    try {
      ticket.observe(iterator.moveNext());
    } catch (error, stack) {
      ticket.failure(error, stack);
    }
    return result;
  }

  void release(_ActiveSourceOperation ticket) {
    if (identical(_active, ticket)) _active = null;
  }

  void cancelCurrent() {
    _active?.cancel();
  }
}

/// Input factories and their onListen/pause/cancel cooperate asynchronously.
/// A deadline cannot preempt synchronous user code on the same isolate.
final class MediaTransfer {
  MediaTransfer._(this.input, this._source, this._channel);
  final MediaTransferInput input;
  StreamSourceFactory _source;
  MediaStdioChannel _channel;
  final _progress = OpaqueMediaProgress._();
  final _sourceGate = _SourceReadGate();
  late Future<MediaTransferOutcome> _completion;
  Future<MediaTransferOutcome>? _aborting;
  Future<void>? _sourceCleanup;
  StreamIterator<List<int>>? _iterator;
  _Fingerprint? _fingerprint;
  String? _uploadId, _receipt;
  int _nextChunk = 0;
  bool _active = false, _verifiedPass2 = false;
  MediaTransferOutcome? _last;
  static MediaTransfer start({
    required MediaTransferInput input,
    required StreamSourceFactory source,
    required MediaStdioChannel channel,
  }) {
    final transfer = MediaTransfer._(input, source, channel);
    transfer._completion = transfer._attempt();
    return transfer;
  }

  Future<MediaTransferOutcome> get completion => _completion;
  OpaqueMediaProgress get progress => _progress;
  MediaTransferOutcome _outcome(
    MediaTransferStatus status,
    MediaTransferCode code, {
    Map<String, Object?>? receipt,
    String? remoteCode,
  }) {
    _progress._needsCallerAction = !{
      MediaTransferStatus.delivered,
      MediaTransferStatus.terminal,
    }.contains(status);
    return _last = MediaTransferOutcome._(
      status,
      code,
      _progress,
      receipt: receipt == null ? null : Map.unmodifiable(receipt),
      remoteCode: remoteCode,
    );
  }

  void _gate() {
    if (_progress._cancelRequested) throw const _Stopped();
    if (_channel.state != MediaChannelState.ready)
      throw const MediaChannelException(
        MediaChannelErrorCode.notReady,
        MediaRequestExecution.notSent,
      );
  }

  Map<String, Object?> get _binding => {
    'schema_version': 2,
    'material_id': input.binding.materialId,
    'material_version_id': input.binding.materialVersionId,
    'source_text_sha256': input.binding.sourceTextSha256,
  };
  Map<String, Object?> _declaration(SourceDeclaration d) => {
    'preparation': d.preparation,
    'provider': d.provider,
    'model': d.model,
    'model_version': d.modelVersion,
    'notes': d.notes,
  };
  String get _englishSha => sha256
      .convert(
        utf8.encode(jsonEncode(input.sentences.map((s) => s.english).toList())),
      )
      .toString();
  Map<String, Object?> _media({required bool complete}) => {
    'sha256': _fingerprint?.sha ?? '0' * 64,
    'byte_length': _fingerprint?.length ?? 1920044,
    if (complete) 'english_sha256': _englishSha,
    'pcm': {
      'format': 1,
      'channels': 1,
      'sample_rate': 16000,
      'bits_per_sample': 16,
    },
    'timings': [
      for (final t in input.timings)
        {
          'sentence_index': t.sentenceIndex,
          'start_ms': t.startMs,
          'end_ms': t.endMs,
        },
    ],
    'declaration': _declaration(input.mediaDeclaration),
    'timing_declaration': input.timingDeclaration,
  };
  Map<String, Object?> _submit() => {
    ..._binding,
    'delivery_id': input.deliveryId,
    'sentences': [
      for (final s in input.sentences)
        {'english': s.english, 'translation': s.translation},
    ],
    'declaration': _declaration(input.textDeclaration),
    'media': _media(complete: true),
    'sealed_receipt': _receipt ?? '0' * 64,
  };
  Map<String, Object?> _begin() {
    final parsed = decodeMediaBridgePayload(
      'media_submit',
      encodeAgentBridgeJson(_submit(), maxBytes: 196608),
    ) as MediaWireSubmit;
    return {
      ..._binding,
      'delivery_id': input.deliveryId,
      'submission_sha256': parsed.submission.media.submissionSha256,
      'english_sha256': _englishSha,
      'media': _media(complete: false),
    };
  }

  Map<String, Object?> get _control => {..._binding, 'upload_id': _uploadId};
  Future<Map<String, Object?>> _call(
    MediaWireOperation operation,
    Map<String, Object?> body, {
    bool control = false,
  }) async {
    if (!control) _gate();
    _progress._stage = switch (operation) {
      MediaWireOperation.begin => MediaTransferStage.begin,
      MediaWireOperation.chunk => MediaTransferStage.chunk,
      MediaWireOperation.seal => MediaTransferStage.seal,
      MediaWireOperation.submit => MediaTransferStage.submit,
      MediaWireOperation.abort => MediaTransferStage.abort,
    };
    final reply = await _channel.invoke(operation, body);
    if (reply.kind != MediaToolReplyKind.success) throw _RemoteStop(reply);
    return reply.result!;
  }

  Future<MediaTransferOutcome> _attempt() async {
    if (_active)
      return _outcome(MediaTransferStatus.localFailure, MediaTransferCode.busy);
    _active = true;
    try {
      _gate();
      // Provisional bounded envelope validates all already-knowable input shape.
      decodeMediaBridgePayload(
        'media_submit',
        encodeAgentBridgeJson(_submit(), maxBytes: 196608),
      );
      if (_fingerprint == null ||
          _uploadId == null ||
          (!_verifiedPass2 && _receipt == null)) {
        _progress._stage = MediaTransferStage.sourcePass1;
        final original = _fingerprint;
        final current = await _readSource();
        if (original != null && !original.same(current))
          throw const _SourceProblem(MediaTransferCode.sourceChanged);
        _fingerprint = current;
        // Recheck timings against actual length before any begin.
        _begin();
        _gate();
      }
      if (_uploadId == null) {
        final result = await _call(MediaWireOperation.begin, _begin());
        _uploadId = result['upload_id'] as String;
        if (result['status'] == 'terminal') {
          _progress._stage = MediaTransferStage.done;
          return _outcome(
            MediaTransferStatus.terminal,
            MediaTransferCode.none,
            receipt: result,
          );
        }
        if (result['status'] == 'sealed') _verifiedPass2 = true;
      }
      _gate();
      if (_receipt == null && !_verifiedPass2) {
        _progress._stage = MediaTransferStage.sourcePass2;
        final actual = await _readSource(
          onBlock: (index, bytes) async {
            if (index >= _fingerprint!.hashes.length ||
                sha256.convert(bytes).toString() != _fingerprint!.hashes[index])
              throw const _SourceProblem(MediaTransferCode.sourceChanged);
            if (index < _nextChunk)
              return; // Only our own already ACKed prefix, not a remote offset.
            _gate();
            await _call(MediaWireOperation.chunk, {
              ..._control,
              'index': index,
              'bytes_base64': base64.encode(bytes),
              'chunk_sha256': _fingerprint!.hashes[index],
            });
            _nextChunk = index + 1;
            _gate();
          },
        );
        if (!_fingerprint!.same(actual))
          throw const _SourceProblem(MediaTransferCode.sourceChanged);
        _verifiedPass2 = true;
      }
      _gate();
      if (_receipt == null) {
        final result = await _call(MediaWireOperation.seal, _control);
        _receipt = result['sealed_receipt'] as String;
      }
      _gate();
      final result = await _call(MediaWireOperation.submit, _submit());
      _progress._stage = MediaTransferStage.done;
      return _outcome(
        MediaTransferStatus.delivered,
        MediaTransferCode.none,
        receipt: result,
      );
    } on _Stopped {
      return _outcome(
        MediaTransferStatus.needsReconcile,
        MediaTransferCode.cancelled,
      );
    } on _SourceProblem catch (error) {
      return _outcome(
        _uploadId == null
            ? MediaTransferStatus.localFailure
            : MediaTransferStatus.needsReconcile,
        error.code,
      );
    } on _RemoteStop catch (error) {
      return error.reply.kind == MediaToolReplyKind.unknown
          ? _outcome(MediaTransferStatus.unknown, MediaTransferCode.uncertain)
          : _outcome(
              MediaTransferStatus.rejected,
              MediaTransferCode.remoteRejected,
              remoteCode: error.reply.code?.name,
            );
    } on MediaChannelException catch (error) {
      return _outcome(
        error.execution == MediaRequestExecution.unknown
            ? MediaTransferStatus.unknown
            : MediaTransferStatus.localFailure,
        error.code == MediaChannelErrorCode.busy
            ? MediaTransferCode.busy
            : MediaTransferCode.channelUnavailable,
      );
    } catch (_) {
      return _outcome(
        MediaTransferStatus.localFailure,
        MediaTransferCode.invalidInput,
      );
    } finally {
      await _cancelSource();
      _active = false;
    }
  }

  Future<MediaTransferOutcome> abort() {
    _progress._cancelRequested = true;
    _sourceGate.cancelCurrent();
    _cancelSource().ignore();
    if (_aborting != null) return _aborting!;
    if (_uploadId == null)
      return Future.value(
        _outcome(
          MediaTransferStatus.needsReconcile,
          MediaTransferCode.cancelled,
        ),
      );
    final task = () async {
      try {
        final result = await _call(
          MediaWireOperation.abort,
          _control,
          control: true,
        );
        return _outcome(
          MediaTransferStatus.terminal,
          MediaTransferCode.cancelled,
          receipt: result,
        );
      } on _RemoteStop catch (error) {
        return _outcome(
          error.reply.kind == MediaToolReplyKind.unknown
              ? MediaTransferStatus.unknown
              : MediaTransferStatus.rejected,
          MediaTransferCode.cancelled,
          remoteCode: error.reply.code?.name,
        );
      } on MediaChannelException catch (error) {
        return _outcome(
          error.execution == MediaRequestExecution.unknown
              ? MediaTransferStatus.unknown
              : MediaTransferStatus.needsReconcile,
          MediaTransferCode.cancelled,
        );
      } catch (_) {
        return _outcome(
          MediaTransferStatus.unknown,
          MediaTransferCode.cancelled,
        );
      }
    }();
    _aborting = task;
    task.whenComplete(() => _aborting = null).ignore();
    return task;
  }

  Future<MediaTransferOutcome> resume({
    required MediaStdioChannel channel,
    StreamSourceFactory? source,
  }) {
    if (_active || _aborting != null)
      return Future.value(
        _outcome(MediaTransferStatus.localFailure, MediaTransferCode.busy),
      );
    if (_progress._cancelRequested) {
      // Explicitly rebind for a later caller-requested control retry only.
      // Never reopen source or clear cancellation to continue data here.
      if (channel.state == MediaChannelState.ready) _channel = channel;
      return Future.value(
        _outcome(
          MediaTransferStatus.needsReconcile,
          MediaTransferCode.cancelled,
        ),
      );
    }
    if (_last?.status == MediaTransferStatus.delivered ||
        _last?.status == MediaTransferStatus.terminal)
      return Future.value(_last!);
    if ((_fingerprint == null ||
            _uploadId == null ||
            (!_verifiedPass2 && _receipt == null)) &&
        source == null)
      return Future.value(
        _outcome(
          MediaTransferStatus.needsReconcile,
          MediaTransferCode.sourceRequired,
        ),
      );
    _channel = channel;
    if (source != null) _source = source;
    _completion = _attempt();
    return _completion;
  }

  Future<void> drain() async {
    final futures = <Future<Object?>>[
      _completion,
      if (_aborting != null) _aborting!,
    ];
    await Future.wait(
      futures.map((f) => f.then<void>((_) {}, onError: (Object _) {})),
    );
    await _cancelSource();
  }

  Future<void> _cancelSource() {
    _sourceGate.cancelCurrent();
    final iterator = _iterator;
    if (iterator == null) return _sourceCleanup ?? Future.value();
    _iterator = null;
    late Future<void> original;
    try {
      original = iterator.cancel();
    } catch (_) {
      return _sourceCleanup = Future.value();
    }
    original.ignore();
    return _sourceCleanup = original
        .timeout(const Duration(seconds: 15))
        .catchError((Object _) {});
  }

  Future<_Fingerprint> _readSource({
    Future<void> Function(int, Uint8List)? onBlock,
  }) async {
    _gate();
    final stream = await _sourceGate.open(_source);
    _gate();
    final iterator = StreamIterator<List<int>>(stream);
    _iterator = iterator;
    _sourceCleanup = null;
    final digest = _DigestSink(), hashes = <String>[];
    final sink = sha256.startChunkedConversion(digest);
    var buffer = Uint8List(65536), used = 0, total = 0, events = 0;
    final inactivity = Stopwatch()..start();
    Future<void> emit() async {
      if (used == 0) return;
      final bytes = Uint8List.fromList(buffer.sublist(0, used));
      hashes.add(sha256.convert(bytes).toString());
      if (hashes.length > 30)
        throw const _SourceProblem(MediaTransferCode.sourceTooLarge);
      if (onBlock != null) await onBlock(hashes.length - 1, bytes);
      buffer = Uint8List(65536);
      used = 0;
    }

    try {
      while (true) {
        _gate();
        final left = const Duration(seconds: 15) - inactivity.elapsed;
        if (left <= Duration.zero)
          throw const _SourceProblem(MediaTransferCode.sourceTimeout);
        final more = await _sourceGate.next(iterator, left);
        _gate();
        if (!more) break;
        final sourceFragment = iterator.current;
        if (sourceFragment.length > 65536)
          throw const _SourceProblem(MediaTransferCode.sourceInvalid);
        // Own one bounded snapshot before any network await; an emitted List
        // must not remain a mutable alias across a chunk acknowledgement.
        final fragment = Uint8List(sourceFragment.length);
        for (var i = 0; i < fragment.length; i++) {
          final value = sourceFragment[i];
          if (value < 0 || value > 255)
            throw const _SourceProblem(MediaTransferCode.sourceInvalid);
          fragment[i] = value;
        }
        if (fragment.isNotEmpty) {
          if (total + fragment.length > 1920044)
            throw const _SourceProblem(MediaTransferCode.sourceTooLarge);
          inactivity.reset();
          total += fragment.length;
          sink.add(fragment);
          var offset = 0;
          while (offset < fragment.length) {
            final take = (65536 - used) < (fragment.length - offset)
                ? 65536 - used
                : fragment.length - offset;
            buffer.setRange(used, used + take, fragment, offset);
            used += take;
            offset += take;
            if (used == 65536) {
              await emit();
              inactivity.reset();
            }
          }
        }
        if (++events % 64 == 0) await Future<void>(() {});
      }
      await emit();
      sink.close();
      if (total < 46 || (total - 44).isOdd)
        throw const _SourceProblem(MediaTransferCode.sourceInvalid);
      return _Fingerprint(
        total,
        digest.value.toString(),
        List.unmodifiable(hashes),
      );
    } finally {
      await _cancelSource();
    }
  }
}
