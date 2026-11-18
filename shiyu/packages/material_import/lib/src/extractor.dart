import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../material_import.dart';
import 'docx_extractor.dart';
import 'strict_text.dart';

ExtractedMaterial extractMaterial({
  required Uint8List bytes,
  required String filenameHint,
  MaterialImportLimits limits = const MaterialImportLimits(),
}) {
  final values = [
    limits.sourceBytes,
    limits.entryBytes,
    limits.totalInflatedBytes,
    limits.xmlBytes,
    limits.textCodePoints,
    limits.entries,
    limits.xmlDepth,
    limits.xmlEvents,
    limits.attributesPerElement,
  ];
  if (values.any((v) => v <= 0))
    throw ArgumentError('positive_import_limits_required');
  if (bytes.length > limits.sourceBytes)
    importFailure(MaterialImportErrorCode.sourceTooLarge);
  if (bytes.isEmpty) importFailure(MaterialImportErrorCode.emptyMaterial);
  final hint = filenameHint.toLowerCase();
  final MaterialImportFormat format;
  final String text;
  final List<MaterialTextBlock> blocks;
  final Iterable<MaterialImportWarning> warnings;
  if (hint.endsWith('.txt')) {
    format = MaterialImportFormat.txt;
    text = strictText(bytes);
    if (text.runes.length > limits.textCodePoints)
      importFailure(MaterialImportErrorCode.outputTooLarge);
    blocks = [
      MaterialTextBlock(
        kind: MaterialTextBlockKind.plainText,
        start: 0,
        end: text.length,
        ordinal: 0,
      ),
    ];
    warnings = const [];
  } else if (hint.endsWith('.docx')) {
    format = MaterialImportFormat.docx;
    final result = extractDocx(bytes, limits);
    text = result.text;
    blocks = result.blocks;
    warnings = result.warnings;
  } else {
    importFailure(MaterialImportErrorCode.unsupportedFormat);
  }
  if (text.trim().isEmpty) importFailure(MaterialImportErrorCode.emptyMaterial);
  return ExtractedMaterial(
    format: format,
    text: text,
    sourceSha256: sha256.convert(bytes).toString(),
    textSha256: sha256.convert(utf8.encode(text)).toString(),
    blocks: blocks,
    warnings: warnings,
  );
}
