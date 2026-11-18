import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:learning_core/learning_core.dart';

import 'contracts.dart';
import 'private_descriptor.dart';

const bridgeFrameMaximum = 256 * 1024;
const bridgePayloadMaximum = 192 * 1024;
const bridgeSourceMaximum = 100 * 1024;

Map<String, Object?> bridgeObject(
  Object? value,
  Set<String> keys, {
  Set<String>? required,
}) {
  if (value is! Map ||
      value.keys.any((key) => key is! String) ||
      value.keys.any((key) => !keys.contains(key)) ||
      (required ?? keys).any((key) => !value.containsKey(key))) {
    throw const AgentBridgeException(AgentBridgeErrorCode.invalidRequest);
  }
  return Map<String, Object?>.from(value);
}

void rejectBridgeMedia(Map<String, Object?> value) {
  for (final key in value.keys) {
    final name = key.toLowerCase();
    if ({'media', 'audio', 'timings', 'artifacts'}.contains(name) ||
        name.startsWith('media_') ||
        name.startsWith('audio_')) {
      throw const AgentBridgeException(AgentBridgeErrorCode.unsupportedMedia);
    }
  }
}

Map<String, Object?> sourceReference(BridgeDescriptor descriptor) => {
  'material_id': descriptor.materialId,
  'material_version_id': descriptor.materialVersionId,
  'source_text_sha256': descriptor.sourceTextSha256,
};

void requireSourceBinding(
  Map<String, Object?> value,
  BridgeDescriptor descriptor,
) {
  if (value['material_id'] != descriptor.materialId ||
      value['material_version_id'] != descriptor.materialVersionId ||
      value['source_text_sha256'] != descriptor.sourceTextSha256) {
    throw const AgentBridgeException(AgentBridgeErrorCode.sourceMismatch);
  }
}

LearningCandidateInput candidateInput(Map<String, Object?> payload) {
  rejectBridgeMedia(payload);
  bridgeObject(payload, {
    'schema_version',
    'material_id',
    'material_version_id',
    'source_text_sha256',
    'delivery_id',
    'sentences',
    'declaration',
  });
  if (payload['schema_version'] != 1 ||
      payload['material_id'] is! String ||
      payload['material_version_id'] is! String ||
      payload['source_text_sha256'] is! String ||
      payload['delivery_id'] is! String ||
      payload['sentences'] is! List) {
    throw const AgentBridgeException(AgentBridgeErrorCode.invalidRequest);
  }
  final sentences = payload['sentences'] as List;
  if (sentences.isEmpty ||
      sentences.length > LearningCandidateLimits.maxSentences) {
    throw const AgentBridgeException(AgentBridgeErrorCode.tooLarge);
  }
  final parsed = <LearningSentenceInput>[];
  for (final value in sentences) {
    final sentence = bridgeObject(value, {'english', 'translation'});
    if (sentence['english'] is! String ||
        sentence['translation'] is! String ||
        (sentence['english'] as String).trim().isEmpty ||
        (sentence['translation'] as String).trim().isEmpty) {
      throw const AgentBridgeException(AgentBridgeErrorCode.invalidRequest);
    }
    parsed.add(
      LearningSentenceInput(
        english: sentence['english'] as String,
        translation: sentence['translation'] as String,
      ),
    );
  }
  final declaration = bridgeObject(
    payload['declaration'],
    {'preparation', 'provider', 'model', 'model_version', 'notes'},
    required: {'preparation'},
  );
  if (declaration['preparation'] is! String ||
      (declaration['preparation'] as String).trim().isEmpty ||
      declaration.values.any((value) => value != null && value is! String)) {
    throw const AgentBridgeException(AgentBridgeErrorCode.invalidRequest);
  }
  return LearningCandidateInput(
    materialId: payload['material_id'] as String,
    materialVersionId: payload['material_version_id'] as String,
    sourceTextSha256: payload['source_text_sha256'] as String,
    deliveryId: payload['delivery_id'] as String,
    sentences: parsed,
    declaration: SourceDeclaration(
      preparation: declaration['preparation'] as String,
      provider: declaration['provider'] as String?,
      model: declaration['model'] as String?,
      modelVersion: declaration['model_version'] as String?,
      notes: declaration['notes'] as String?,
    ),
  );
}

String sessionProof(BridgeDescriptor descriptor, String challenge) {
  final key = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    key[i] = int.parse(
      descriptor.proofKey.substring(i * 2, i * 2 + 2),
      radix: 16,
    );
  }
  return Hmac(sha256, key)
      .convert(
        utf8.encode(
          'shiyu-b1-proof\n${descriptor.port}\n${descriptor.session}\n$challenge',
        ),
      )
      .toString();
}

bool constantBridgeEqual(String first, String second) {
  var difference = first.length ^ second.length;
  final maximum = first.length > second.length ? first.length : second.length;
  for (var i = 0; i < maximum; i++) {
    difference |=
        (i < first.length ? first.codeUnitAt(i) : 0) ^
        (i < second.length ? second.codeUnitAt(i) : 0);
  }
  return difference == 0;
}
