import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:learning_core/learning_core.dart';

import 'contracts.dart';
import 'media_ingest.dart';
import 'strict_json.dart';
import 'wire.dart';

/// Pure C2-A codec only. Discovery, authentication and dispatch live elsewhere.
enum MediaWireOperation {
  begin('media_begin', 'shiyu_begin_media'),
  chunk('media_chunk', 'shiyu_put_media_chunk'),
  seal('media_seal', 'shiyu_seal_media'),
  submit('media_submit', 'shiyu_submit_media_candidate'),
  abort('media_abort', 'shiyu_abort_media');

  const MediaWireOperation(this.wireName, this.toolName);
  final String wireName, toolName;
}

sealed class MediaWireRequest {
  const MediaWireRequest(this.operation, this.binding);
  final MediaWireOperation operation;
  final MediaIngestSourceBinding binding;
}

final class MediaWireBegin extends MediaWireRequest {
  MediaWireBegin(this.manifest)
    : super(MediaWireOperation.begin, manifest.binding);
  final MediaIngestBegin manifest;
}

final class MediaWireChunk extends MediaWireRequest {
  MediaWireChunk({
    required MediaIngestSourceBinding binding,
    required this.uploadId,
    required this.index,
    required Uint8List bytes,
    required this.chunkSha256,
  }) : bytes = Uint8List.fromList(bytes).asUnmodifiableView(),
       super(MediaWireOperation.chunk, binding);
  final String uploadId, chunkSha256;
  final int index;
  final Uint8List bytes;
}

final class MediaWireSeal extends MediaWireRequest {
  const MediaWireSeal(MediaIngestSourceBinding binding, this.uploadId)
    : super(MediaWireOperation.seal, binding);
  final String uploadId;
}

final class MediaWireAbort extends MediaWireRequest {
  const MediaWireAbort(MediaIngestSourceBinding binding, this.uploadId)
    : super(MediaWireOperation.abort, binding);
  final String uploadId;
}

final class MediaWireSubmit extends MediaWireRequest {
  MediaWireSubmit(this.submission, this.sealedReceipt)
    : super(MediaWireOperation.submit, submission.binding);
  final MediaIngestSubmission submission;
  final String sealedReceipt;
}

const _common = {
  'schema_version',
  'material_id',
  'material_version_id',
  'source_text_sha256',
};
final _id = RegExp(r'^[0-9a-f]{32}$'), _hash = RegExp(r'^[0-9a-f]{64}$');
Never _invalid() =>
    throw const AgentBridgeException(AgentBridgeErrorCode.invalidRequest);
Never _large() =>
    throw const AgentBridgeException(AgentBridgeErrorCode.tooLarge);
Map<String, Object?> _object(
  Object? value,
  Set<String> keys, {
  Set<String>? required,
}) => bridgeObject(value, keys, required: required);
String _hex(Object? value, {bool id = false}) {
  if (value is! String || !(id ? _id : _hash).hasMatch(value)) _invalid();
  return value;
}

String _text(Object? value, int max, {bool empty = false, bool line = false}) {
  if (value is! String || (!empty && value.trim().isEmpty)) _invalid();
  if (value.length > max || utf8.encode(value).length > max) _large();
  // decodeAgentBridgeJson has already rejected unpaired UTF16.
  for (final c in value.codeUnits) {
    if (c == 127 ||
        (c >= 128 && c <= 159) ||
        (c < 32 && (line || !{9, 10, 13}.contains(c))))
      _invalid();
  }
  return value;
}

int _int(Object? value, int min, int max) {
  if (value is! int || value < min || value > max) _invalid();
  return value;
}

MediaIngestSourceBinding _binding(Map<String, Object?> value) {
  if (value['schema_version'] is! int || value['schema_version'] != 2)
    _invalid();
  return MediaIngestSourceBinding(
    materialId: _hex(value['material_id'], id: true),
    materialVersionId: _hex(value['material_version_id'], id: true),
    sourceTextSha256: _hex(value['source_text_sha256']),
  );
}

SourceDeclaration _declaration(Object? value) {
  final m = _object(
    value,
    {'preparation', 'provider', 'model', 'model_version', 'notes'},
    required: {'preparation'},
  );
  final preparation = _text(m['preparation'], 8192);
  for (final k in ['provider', 'model', 'model_version', 'notes']) {
    if (m[k] != null) _text(m[k], 8192, empty: true);
  }
  // Core semantic record includes every null optional field and camelCase key.
  encodeAgentBridgeJson({
    'preparation': preparation,
    'provider': m['provider'],
    'model': m['model'],
    'modelVersion': m['model_version'],
    'notes': m['notes'],
  }, maxBytes: 8192);
  return SourceDeclaration(
    preparation: preparation,
    provider: m['provider'] as String?,
    model: m['model'] as String?,
    modelVersion: m['model_version'] as String?,
    notes: m['notes'] as String?,
  );
}

MediaIngestBegin _manifest(
  Map<String, Object?> value,
  MediaIngestSourceBinding binding, {
  required bool complete,
  required String commitment,
}) {
  final media = _object(value['media'], {
    'sha256',
    'byte_length',
    'pcm',
    'timings',
    'declaration',
    'timing_declaration',
    if (complete) 'english_sha256',
  });
  final english = _hex(
    complete ? media['english_sha256'] : value['english_sha256'],
  );
  final length = _int(media['byte_length'], 46, 1920044);
  if ((length - 44).isOdd) _invalid();
  final pcm = _object(media['pcm'], {
    'format',
    'channels',
    'sample_rate',
    'bits_per_sample',
  });
  for (final e in {
    'format': 1,
    'channels': 1,
    'sample_rate': 16000,
    'bits_per_sample': 16,
  }.entries) {
    if (pcm[e.key] is! int || pcm[e.key] != e.value) _invalid();
  }
  final raw = media['timings'];
  if (raw is! List || raw.isEmpty || raw.length > 128) _invalid();
  final timings = <SentenceTiming>[];
  var previous = 0;
  for (var i = 0; i < raw.length; i++) {
    final t = _object(raw[i], {'sentence_index', 'start_ms', 'end_ms'});
    final index = _int(t['sentence_index'], 0, 127),
        start = _int(t['start_ms'], 0, 60000),
        end = _int(t['end_ms'], 1, 60000);
    if (index != i ||
        start < previous ||
        end <= start ||
        end * 32000 > (length - 44) * 1000)
      _invalid();
    timings.add(
      SentenceTiming(sentenceIndex: index, startMs: start, endMs: end),
    );
    previous = end;
  }
  final declaration = _declaration(media['declaration']);
  final timing = _text(media['timing_declaration'], 8192);
  final declarationBytes = encodeAgentBridgeJson({
    'preparation': declaration.preparation,
    'provider': declaration.provider,
    'model': declaration.model,
    'modelVersion': declaration.modelVersion,
    'notes': declaration.notes,
  }, maxBytes: 8192).length;
  if (declarationBytes + utf8.encode(timing).length > 8192) _large();
  return MediaIngestBegin(
    binding: binding,
    deliveryId: _text(value['delivery_id'], 256, line: true),
    submissionSha256: commitment,
    englishSha256: english,
    mediaSha256: _hex(media['sha256']),
    mediaBytes: length,
    timings: timings,
    declaration: declaration,
    timingDeclaration: timing,
  );
}

/// Bound before allocation, then exact decode/re-encode; no URL/percent aliases.
Uint8List decodeCanonicalBridgeBase64(
  String value, {
  required int maximumBytes,
}) {
  if (maximumBytes < 0 || maximumBytes > bridgePayloadMaximum) _invalid();
  if (value.length > 4 * ((maximumBytes + 2) ~/ 3)) _large();
  if (value.length % 4 != 0) _invalid();
  for (final c in value.codeUnits) {
    if (!((c >= 65 && c <= 90) ||
        (c >= 97 && c <= 122) ||
        (c >= 48 && c <= 57) ||
        c == 43 ||
        c == 47 ||
        c == 61))
      _invalid();
  }
  Uint8List bytes;
  try {
    bytes = base64.decode(value);
  } catch (_) {
    _invalid();
  }
  if (bytes.length > maximumBytes) _large();
  if (base64.encode(bytes) != value) _invalid();
  return bytes;
}

MediaWireRequest decodeMediaBridgePayload(
  String operation,
  Uint8List rawBusinessBytes,
) {
  final operations = MediaWireOperation.values.where(
    (v) => v.wireName == operation,
  );
  if (operations.isEmpty) _invalid();
  final kind = operations.single;
  final decoded = decodeAgentBridgeJson(
    rawBusinessBytes,
    maxBytes: bridgePayloadMaximum,
  );
  final keys = switch (kind) {
    MediaWireOperation.begin => {
      ..._common,
      'delivery_id',
      'submission_sha256',
      'english_sha256',
      'media',
    },
    MediaWireOperation.chunk => {
      ..._common,
      'upload_id',
      'index',
      'bytes_base64',
      'chunk_sha256',
    },
    MediaWireOperation.seal ||
    MediaWireOperation.abort => {..._common, 'upload_id'},
    MediaWireOperation.submit => {
      ..._common,
      'delivery_id',
      'sentences',
      'declaration',
      'media',
      'sealed_receipt',
    },
  };
  final value = _object(decoded, keys),
      binding = _binding(_object(decoded, keys));
  switch (kind) {
    case MediaWireOperation.begin:
      return MediaWireBegin(
        _manifest(
          value,
          binding,
          complete: false,
          commitment: _hex(value['submission_sha256']),
        ),
      );
    case MediaWireOperation.chunk:
      final encoded = value['bytes_base64'];
      if (encoded is! String || encoded.isEmpty) _invalid();
      final bytes = decodeCanonicalBridgeBase64(encoded, maximumBytes: 65536);
      final digest = _hex(value['chunk_sha256']);
      if (sha256.convert(bytes).toString() != digest) _invalid();
      return MediaWireChunk(
        binding: binding,
        uploadId: _hex(value['upload_id'], id: true),
        index: _int(value['index'], 0, 31),
        bytes: bytes,
        chunkSha256: digest,
      );
    case MediaWireOperation.seal:
      return MediaWireSeal(binding, _hex(value['upload_id'], id: true));
    case MediaWireOperation.abort:
      return MediaWireAbort(binding, _hex(value['upload_id'], id: true));
    case MediaWireOperation.submit:
      final media = _manifest(
        value,
        binding,
        complete: true,
        commitment: '0' * 64,
      );
      final rows = value['sentences'];
      if (rows is! List ||
          rows.isEmpty ||
          rows.length > 128 ||
          rows.length != media.timings.length)
        _invalid();
      final sentences = <LearningSentenceInput>[];
      var total = 0;
      for (final row in rows) {
        final r = _object(row, {'english', 'translation'}),
            english = _text(r['english'], 102400),
            translation = _text(r['translation'], 102400);
        total += utf8.encode(english).length + utf8.encode(translation).length;
        if (total > 102400) _large();
        sentences.add(
          LearningSentenceInput(english: english, translation: translation),
        );
      }
      if (sha256
              .convert(
                utf8.encode(
                  jsonEncode(sentences.map((s) => s.english).toList()),
                ),
              )
              .toString() !=
          media.englishSha256)
        _invalid();
      final declaration = _declaration(value['declaration']);
      final provisional = MediaIngestSubmission(
        binding: binding,
        deliveryId: media.deliveryId,
        sentences: sentences,
        declaration: declaration,
        media: media,
      );
      final commitment = mediaIngestPayloadSha256(provisional);
      final complete = MediaIngestBegin(
        binding: binding,
        deliveryId: media.deliveryId,
        submissionSha256: commitment,
        englishSha256: media.englishSha256,
        mediaSha256: media.mediaSha256,
        mediaBytes: media.mediaBytes,
        timings: media.timings,
        declaration: media.declaration,
        timingDeclaration: media.timingDeclaration,
      );
      return MediaWireSubmit(
        MediaIngestSubmission(
          binding: binding,
          deliveryId: media.deliveryId,
          sentences: sentences,
          declaration: declaration,
          media: complete,
        ),
        _hex(value['sealed_receipt']),
      );
  }
}

final class EncodedMediaBridgeRequest {
  EncodedMediaBridgeRequest._(
    Uint8List business,
    Uint8List request,
    Uint8List frame,
  ) : businessJson = business.asUnmodifiableView(),
      requestJson = request.asUnmodifiableView(),
      frame = frame.asUnmodifiableView();
  final Uint8List businessJson, requestJson, frame;
}

/// Pure encoding for later authenticated callers. It grants no permission.
EncodedMediaBridgeRequest encodeMediaBridgeRequest({
  required MediaWireOperation operation,
  required Map<String, Object?> payload,
  required String session,
  required String challenge,
  required String capability,
}) {
  _hex(session, id: true);
  _hex(challenge);
  _hex(capability);
  final business = encodeAgentBridgeJson(
    payload,
    maxBytes: bridgePayloadMaximum,
  );
  decodeMediaBridgePayload(operation.wireName, business);
  final request = encodeAgentBridgeJson({
    'kind': 'request',
    'session': session,
    'challenge': challenge,
    'capability': capability,
    'operation': operation.wireName,
    'payload': base64.encode(business),
  }, maxBytes: bridgeFrameMaximum);
  final frame = Uint8List(request.length + 12)
    ..setRange(0, 8, const [0x53, 0x59, 0x42, 0x31, 0, 13, 10, 0]);
  ByteData.sublistView(frame).setUint32(8, request.length, Endian.big);
  frame.setRange(12, frame.length, request);
  return EncodedMediaBridgeRequest._(business, request, frame);
}

Uint8List encodeMediaMcpCall({
  required Object id,
  required MediaWireOperation operation,
  required Map<String, Object?> payload,
}) {
  if (id is String) {
    if (id.length > 128 || utf8.encode(id).length > 256) _invalid();
  } else if (id is! num ||
      !id.isFinite ||
      id.abs() > 9007199254740991 ||
      id != id.truncateToDouble()) {
    _invalid();
  }
  decodeMediaBridgePayload(
    operation.wireName,
    encodeAgentBridgeJson(payload, maxBytes: bridgePayloadMaximum),
  );
  final json = encodeAgentBridgeJson({
    'jsonrpc': '2.0',
    'id': id,
    'method': 'tools/call',
    'params': {'name': operation.toolName, 'arguments': payload},
  }, maxBytes: 256 * 1024);
  return Uint8List(json.length + 1)
    ..setRange(0, json.length, json)
    ..[json.length] = 10;
}
