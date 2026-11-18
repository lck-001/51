import 'dart:typed_data';

import 'package:xml/xml_events.dart';
import 'package:xml/xml.dart' show XmlDefaultEntityMapping;

import '../material_import.dart';
import 'strict_text.dart';

final class XmlBudget {
  int events = 0;
}

/// Event-only parsing: ignored parts never become a DOM or retained event list.
void visitXml(
  Uint8List bytes,
  MaterialImportLimits limits,
  void Function(XmlEvent event) visit, {
  XmlBudget? budget,
}) {
  if (bytes.length > limits.xmlBytes)
    importFailure(MaterialImportErrorCode.outputTooLarge);
  try {
    final text = strictText(bytes, xml: true);
    // Refuse before the XML grammar examines potentially large internal DTDs.
    if (RegExp(
      r'<!\s*(?:DOCTYPE|ENTITY)',
      caseSensitive: false,
    ).hasMatch(text)) {
      importFailure(MaterialImportErrorCode.unsafePackage);
    }
    var depth = 0, count = 0;
    for (final event in parseEvents(
      text,
      entityMapping: const _StrictEntities(),
      validateDocument: true,
      validateNesting: true,
      validateNamespace: true,
      withNamespace: true,
    )) {
      if (++count > limits.xmlEvents ||
          (budget != null && ++budget.events > limits.xmlEvents))
        importFailure(MaterialImportErrorCode.outputTooLarge);
      if (event is XmlDoctypeEvent)
        importFailure(MaterialImportErrorCode.unsafePackage);
      if (event is XmlStartElementEvent) {
        if (++depth > limits.xmlDepth ||
            event.attributes.length > limits.attributesPerElement) {
          importFailure(MaterialImportErrorCode.outputTooLarge);
        }
        final attributeNames = <String>{};
        for (final attribute in event.attributes) {
          final uri = attribute.namespacePrefix == null
              ? ''
              : attribute.namespaceUri ?? '';
          if (!attributeNames.add('$uri:${attribute.localName}')) {
            importFailure(MaterialImportErrorCode.malformedDocument);
          }
          validXmlCharacters(attribute.value);
        }
        visit(event);
        if (event.isSelfClosing) {
          // The public iterator has no separate end event for <x/>.
          visit(XmlEndElementEvent(event.name));
          depth--;
        }
      } else if (event is XmlEndElementEvent) {
        visit(event);
        depth--;
      } else {
        if (event is XmlTextEvent) validXmlCharacters(event.value);
        if (event is XmlCDATAEvent) validXmlCharacters(event.value);
        visit(event);
      }
    }
    if (depth != 0) importFailure(MaterialImportErrorCode.malformedDocument);
  } on MaterialImportException {
    rethrow;
  } catch (_) {
    importFailure(MaterialImportErrorCode.malformedDocument);
  }
}

// The upstream default mapping deliberately leaves unknown/bare entities as
// text. OOXML import requires well-formed XML, not that permissive fallback.
final class _StrictEntities extends XmlDefaultEntityMapping {
  const _StrictEntities() : super.xml();
  @override
  String decode(String input) {
    final result = StringBuffer();
    var start = 0;
    while (true) {
      final at = input.indexOf('&', start);
      if (at < 0) {
        result.write(input.substring(start));
        break;
      }
      result.write(input.substring(start, at));
      final end = input.indexOf(';', at + 1);
      if (end < 0) importFailure(MaterialImportErrorCode.malformedDocument);
      final decoded = super.decodeEntity(input.substring(at + 1, end));
      if (decoded == null)
        importFailure(MaterialImportErrorCode.malformedDocument);
      validXmlCharacters(decoded);
      result.write(decoded);
      start = end + 1;
    }
    return result.toString();
  }
}
