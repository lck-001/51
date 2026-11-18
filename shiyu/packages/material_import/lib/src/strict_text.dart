import 'dart:convert';
import 'dart:typed_data';

import '../material_import.dart';

Never importFailure(MaterialImportErrorCode code) =>
    throw MaterialImportException(code);

String strictText(Uint8List bytes, {bool xml = false}) {
  try {
    var encoding = 'utf-8';
    String text;
    if (bytes.length >= 2 &&
        ((bytes[0] == 0xff && bytes[1] == 0xfe) ||
            (bytes[0] == 0xfe && bytes[1] == 0xff))) {
      if (bytes.length.isOdd)
        importFailure(MaterialImportErrorCode.malformedText);
      final little = bytes[0] == 0xff;
      encoding = little ? 'utf-16le' : 'utf-16be';
      final units = <int>[];
      for (var i = 2; i < bytes.length; i += 2) {
        units.add(
          little ? bytes[i] | bytes[i + 1] << 8 : bytes[i] << 8 | bytes[i + 1],
        );
      }
      for (var i = 0; i < units.length; i++) {
        final u = units[i];
        if (u >= 0xd800 && u <= 0xdbff) {
          if (++i == units.length || units[i] < 0xdc00 || units[i] > 0xdfff) {
            importFailure(MaterialImportErrorCode.malformedText);
          }
        } else if (u >= 0xdc00 && u <= 0xdfff) {
          importFailure(MaterialImportErrorCode.malformedText);
        }
      }
      text = String.fromCharCodes(units);
    } else {
      final offset =
          bytes.length >= 3 &&
              bytes[0] == 0xef &&
              bytes[1] == 0xbb &&
              bytes[2] == 0xbf
          ? 3
          : 0;
      text = utf8.decode(
        Uint8List.sublistView(bytes, offset),
        allowMalformed: false,
      );
    }
    for (final rune in text.runes) {
      if (rune < 0x20 && rune != 9 && rune != 10 && rune != 13) {
        importFailure(MaterialImportErrorCode.malformedText);
      }
    }
    if (xml) {
      validXmlCharacters(text);
      final declaration = RegExp(
        r'''^\s*<\?xml\s[^?]*encoding\s*=\s*["']([^"']+)["']''',
        caseSensitive: false,
      ).firstMatch(text);
      if (declaration != null) {
        final declared = declaration.group(1)!.toLowerCase();
        if (!(declared == encoding ||
            (declared == 'utf-16' && encoding.startsWith('utf-16')))) {
          importFailure(MaterialImportErrorCode.malformedDocument);
        }
      }
    }
    return text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  } on MaterialImportException {
    rethrow;
  } catch (_) {
    importFailure(MaterialImportErrorCode.malformedText);
  }
}

void validXmlCharacters(String text) {
  for (final rune in text.runes) {
    if (!(rune == 9 ||
        rune == 10 ||
        rune == 13 ||
        (rune >= 0x20 && rune <= 0xd7ff) ||
        (rune >= 0xe000 && rune <= 0xfffd) ||
        (rune >= 0x10000 && rune <= 0x10ffff))) {
      importFailure(MaterialImportErrorCode.malformedDocument);
    }
  }
  // Dart runes substitutes malformed UTF-16. Check actual code units too.
  final units = text.codeUnits;
  for (var i = 0; i < units.length; i++) {
    final u = units[i];
    if (u >= 0xd800 && u <= 0xdbff) {
      if (++i == units.length || units[i] < 0xdc00 || units[i] > 0xdfff) {
        importFailure(MaterialImportErrorCode.malformedDocument);
      }
    } else if (u >= 0xdc00 && u <= 0xdfff) {
      importFailure(MaterialImportErrorCode.malformedDocument);
    }
  }
}
