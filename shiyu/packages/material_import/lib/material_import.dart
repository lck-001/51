library;

import 'dart:typed_data';

import 'package:material_core/material_core.dart';

export 'src/extractor.dart' show extractMaterial;

enum MaterialImportFormat { txt, docx }

enum MaterialImportErrorCode {
  cancelled,
  busy,
  unsupportedFormat,
  sourceTooLarge,
  readDenied,
  readFailed,
  malformedText,
  malformedZip,
  malformedDocument,
  encrypted,
  unsafePackage,
  outputTooLarge,
  emptyMaterial,
  timedOut,
  sessionClosed,
  ownerMismatch,
  bindingMismatch,
  writeFailed,
}

final class MaterialImportException implements Exception {
  const MaterialImportException(this.code);
  final MaterialImportErrorCode code;
  @override
  String toString() => 'MaterialImportException(${code.name})';
}

enum MaterialImportWarning {
  formattingOmitted,
  imagesOmitted,
  headersFootersOmitted,
  annotationsOmitted,
  externalLinksNotFollowed,
  embeddedObjectsOmitted,
  trackedChangesOmitted,
}

/// First-slice, testable candidate limits; not a universal device safety claim.
final class MaterialImportLimits {
  const MaterialImportLimits({
    this.sourceBytes = 20 * 1024 * 1024,
    this.entryBytes = 16 * 1024 * 1024,
    this.totalInflatedBytes = 64 * 1024 * 1024,
    this.xmlBytes = 8 * 1024 * 1024,
    this.textCodePoints = 200000,
    this.entries = 2048,
    this.xmlDepth = 128,
    this.xmlEvents = 500000,
    this.attributesPerElement = 128,
  });
  final int sourceBytes, entryBytes, totalInflatedBytes, xmlBytes;
  final int textCodePoints, entries, xmlDepth, xmlEvents, attributesPerElement;
}

enum MaterialTextBlockKind { paragraph, tableRow, plainText }

/// Offsets are Dart UTF-16 code units into the exact extracted text, never the
/// editable draft after user correction. partName is an OOXML name, no OS path.
final class MaterialTextBlock {
  const MaterialTextBlock({
    required this.kind,
    required this.start,
    required this.end,
    required this.ordinal,
    this.partName,
  });
  final MaterialTextBlockKind kind;
  final int start, end, ordinal;
  final String? partName;
}

final class ExtractedMaterial {
  ExtractedMaterial({
    required this.format,
    required this.text,
    required this.sourceSha256,
    required this.textSha256,
    required Iterable<MaterialTextBlock> blocks,
    required Iterable<MaterialImportWarning> warnings,
    this.parserVersion = 'shiyu-txt-docx-v1',
  }) : blocks = List.unmodifiable(blocks),
       warnings = List.unmodifiable(warnings);
  final MaterialImportFormat format;
  final String text, sourceSha256, textSha256, parserVersion;
  final List<MaterialTextBlock> blocks;
  final List<MaterialImportWarning> warnings;
}

/// No file path, content URI, cloud task or parser implementation reaches UI.
final class MaterialImportPreview {
  MaterialImportPreview({
    required this.sessionId,
    required this.ownerId,
    required this.title,
    required this.text,
    required Iterable<MaterialImportWarning> warnings,
    required this.format,
    required this.sourceSha256,
  }) : warnings = List.unmodifiable(warnings);
  final String sessionId, ownerId, title, text, sourceSha256;
  final MaterialImportFormat format;
  final List<MaterialImportWarning> warnings;
}

/// A click starts one app-owned session. UI only previews, prepares source
/// artifacts when saving, and finishes after the actual same-owner draft readback.
abstract interface class MaterialImportSession {
  String get sessionId;
  String get ownerId;
  Future<MaterialImportPreview?> get preview;

  /// Returns source + extraction-provenance refs, verifying the staged source
  /// still has the exact preview hash. Does not create/update/confirm a draft.
  Future<List<ArtifactRef>> prepareArtifacts();

  /// Stops picker/read/worker and removes only this session's staging files.
  /// Already-registered, unreferenced private artifacts are not secretly deleted.
  Future<void> cancel();

  /// Reads the actual same-owner draft and checks both returned refs occur in
  /// its artifacts before stage retirement. User-corrected text may differ from
  /// extracted text; provenance records the extracted hash separately.
  Future<void> finish({required String savedMaterialId});
}

typedef StartMaterialImport = MaterialImportSession Function();

/// Pure parser function contract implemented in src/extractor.dart:
/// ExtractedMaterial extractMaterial({required Uint8List bytes,
///   required String filenameHint,
///   MaterialImportLimits limits = const MaterialImportLimits()});
/// [Uint8List] is used by the implementation; native paths stay app-private.
typedef MaterialExtractor = ExtractedMaterial Function({
  required Uint8List bytes,
  required String filenameHint,
  MaterialImportLimits limits,
});
