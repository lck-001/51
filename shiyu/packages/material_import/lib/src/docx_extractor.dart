import 'dart:typed_data';

import 'package:xml/xml_events.dart';

import '../material_import.dart';
import 'safe_xml.dart';
import 'safe_zip.dart';
import 'strict_text.dart';

const _packageRels =
    'http://schemas.openxmlformats.org/package/2006/relationships';
const _contentTypes =
    'http://schemas.openxmlformats.org/package/2006/content-types';
const _word = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
const _strictWord = 'http://purl.oclc.org/ooxml/wordprocessingml/main';
const _officeDocument =
    'http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument';
const _strictOfficeDocument =
    'http://purl.oclc.org/ooxml/officeDocument/relationships/officeDocument';
const _mainType =
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml';

String? _attribute(XmlStartElementEvent event, String name) =>
    event.attributes.where((a) => a.name == name).firstOrNull?.value;

final class DocxText {
  DocxText(this.text, this.blocks, this.warnings);
  final String text;
  final List<MaterialTextBlock> blocks;
  final Set<MaterialImportWarning> warnings;
}

DocxText extractDocx(Uint8List bytes, MaterialImportLimits limits) {
  final zip = SafeZip(bytes, limits);
  final xmlBudget = XmlBudget();
  final warnings = <MaterialImportWarning>{
    MaterialImportWarning.formattingOmitted,
  };
  if (!zip.entries.containsKey('_rels/.rels') ||
      !zip.entries.containsKey('[Content_Types].xml')) {
    importFailure(MaterialImportErrorCode.malformedDocument);
  }
  var main = '';
  _relations(
    zip.read('_rels/.rels', keep: true),
    limits,
    warnings,
    root: true,
    budget: xmlBudget,
    onMain: (target) {
      if (main.isNotEmpty)
        importFailure(MaterialImportErrorCode.malformedDocument);
      main = target.startsWith('/') ? target.substring(1) : target;
      if (!safePartName(main))
        importFailure(MaterialImportErrorCode.unsafePackage);
    },
  );
  if (main.isEmpty || !zip.entries.containsKey(main) || main.endsWith('/'))
    importFailure(MaterialImportErrorCode.malformedDocument);
  final defaults = <String, String>{}, overrides = <String, String>{};
  var rootSeen = false, typeDepth = 0;
  visitXml(zip.read('[Content_Types].xml', keep: true), limits, (event) {
    if (event is XmlEndElementEvent) {
      typeDepth--;
      return;
    }
    if (event is XmlTextEvent && event.value.trim().isNotEmpty)
      importFailure(MaterialImportErrorCode.malformedDocument);
    if (event is! XmlStartElementEvent) return;
    typeDepth++;
    if (!rootSeen) {
      rootSeen = true;
      if (event.localName != 'Types' || event.namespaceUri != _contentTypes)
        importFailure(MaterialImportErrorCode.malformedDocument);
      return;
    }
    if (event.namespaceUri != _contentTypes || typeDepth != 2)
      importFailure(MaterialImportErrorCode.malformedDocument);
    final type = _attribute(event, 'ContentType');
    if (type == null || type.isEmpty)
      importFailure(MaterialImportErrorCode.malformedDocument);
    if (type.toLowerCase().contains('macroenabled') ||
        type.toLowerCase().contains('vbaproject'))
      importFailure(MaterialImportErrorCode.unsafePackage);
    if (event.localName == 'Default') {
      final extension = _attribute(event, 'Extension');
      if (extension == null ||
          extension.isEmpty ||
          defaults.containsKey(extension.toLowerCase()))
        importFailure(MaterialImportErrorCode.malformedDocument);
      defaults[extension.toLowerCase()] = type;
    } else if (event.localName == 'Override') {
      final part = _attribute(event, 'PartName');
      if (part == null ||
          !part.startsWith('/') ||
          !safePartName(part.substring(1)) ||
          overrides.containsKey(part.toLowerCase()))
        importFailure(MaterialImportErrorCode.malformedDocument);
      overrides[part.toLowerCase()] = type;
    } else {
      importFailure(MaterialImportErrorCode.malformedDocument);
    }
  }, budget: xmlBudget);
  if (!rootSeen || overrides['/${main.toLowerCase()}'] != _mainType)
    importFailure(MaterialImportErrorCode.unsupportedFormat);
  final body = _Body(main, limits, warnings);
  for (final name in zip.entries.keys) {
    if (name == '_rels/.rels' || name == '[Content_Types].xml') continue;
    final lower = name.toLowerCase();
    if (lower.endsWith('/')) {
      zip.read(name, keep: false);
      continue;
    }
    final extension = lower.contains('.') ? lower.split('.').last : '';
    final type = overrides['/$lower'] ?? defaults[extension];
    if (type == null) importFailure(MaterialImportErrorCode.malformedDocument);
    final normalizedType = type.toLowerCase();
    final isXml =
        lower.endsWith('.xml') ||
        lower.endsWith('.rels') ||
        normalizedType.endsWith('+xml') ||
        normalizedType == 'application/xml' ||
        normalizedType == 'text/xml';
    if (lower.startsWith('word/media/') || normalizedType.startsWith('image/'))
      warnings.add(MaterialImportWarning.imagesOmitted);
    if (lower.contains('/header') || lower.contains('/footer'))
      warnings.add(MaterialImportWarning.headersFootersOmitted);
    if (lower.contains('comments') ||
        lower.contains('footnotes') ||
        lower.contains('endnotes'))
      warnings.add(MaterialImportWarning.annotationsOmitted);
    if (lower.startsWith('word/embeddings/') ||
        lower.startsWith('word/charts/'))
      warnings.add(MaterialImportWarning.embeddedObjectsOmitted);
    final content = zip.read(name, keep: isXml || name == main);
    if (name == main) {
      visitXml(content, limits, body.event, budget: xmlBudget);
    } else if (lower.endsWith('.rels')) {
      _relations(content, limits, warnings, budget: xmlBudget);
    } else if (isXml) {
      visitXml(content, limits, (event) {
        if (event is XmlStartElementEvent) _warningsFor(event, warnings);
      }, budget: xmlBudget);
    }
  }
  if (!body.documentSeen || body.bodyCount != 1)
    importFailure(MaterialImportErrorCode.malformedDocument);
  return body.finish();
}

void _relations(
  Uint8List bytes,
  MaterialImportLimits limits,
  Set<MaterialImportWarning> warnings, {
  bool root = false,
  XmlBudget? budget,
  void Function(String)? onMain,
}) {
  var seen = false, depth = 0;
  final ids = <String>{};
  visitXml(bytes, limits, (event) {
    if (event is XmlEndElementEvent) {
      depth--;
      return;
    }
    if (event is XmlTextEvent && event.value.trim().isNotEmpty)
      importFailure(MaterialImportErrorCode.malformedDocument);
    if (event is! XmlStartElementEvent) return;
    depth++;
    if (!seen) {
      seen = true;
      if (event.localName != 'Relationships' ||
          event.namespaceUri != _packageRels)
        importFailure(MaterialImportErrorCode.malformedDocument);
      return;
    }
    if (event.localName != 'Relationship' ||
        event.namespaceUri != _packageRels ||
        depth != 2)
      importFailure(MaterialImportErrorCode.malformedDocument);
    final id = _attribute(event, 'Id'),
        type = _attribute(event, 'Type'),
        target = _attribute(event, 'Target'),
        mode = _attribute(event, 'TargetMode');
    if (id == null ||
        id.isEmpty ||
        !ids.add(id) ||
        type == null ||
        type.isEmpty ||
        target == null ||
        target.isEmpty)
      importFailure(MaterialImportErrorCode.malformedDocument);
    if (mode != null && mode != 'External' && mode != 'Internal')
      importFailure(MaterialImportErrorCode.malformedDocument);
    if (type.toLowerCase().contains('vba') ||
        type.toLowerCase().contains('macro'))
      importFailure(MaterialImportErrorCode.unsafePackage);
    final external = mode == 'External';
    if (external) warnings.add(MaterialImportWarning.externalLinksNotFollowed);
    if (type.endsWith('/oleObject') ||
        type.endsWith('/package') ||
        type.endsWith('/chart'))
      warnings.add(MaterialImportWarning.embeddedObjectsOmitted);
    if (type.endsWith('/header') || type.endsWith('/footer'))
      warnings.add(MaterialImportWarning.headersFootersOmitted);
    if (type.endsWith('/comments') ||
        type.endsWith('/footnotes') ||
        type.endsWith('/endnotes'))
      warnings.add(MaterialImportWarning.annotationsOmitted);
    if (root && (type == _officeDocument || type == _strictOfficeDocument)) {
      if (external) importFailure(MaterialImportErrorCode.unsafePackage);
      onMain!(target);
    }
  }, budget: budget);
  if (!seen) importFailure(MaterialImportErrorCode.malformedDocument);
}

void _warningsFor(
  XmlStartElementEvent event,
  Set<MaterialImportWarning> warnings,
) {
  final name = event.localName;
  if (name == 'drawing' || name == 'pict')
    warnings.add(MaterialImportWarning.imagesOmitted);
  if (name == 'txbxContent' ||
      name == 'object' ||
      name == 'oMath' ||
      name == 'oMathPara' ||
      name == 'altChunk' ||
      name == 'subDoc' ||
      name == 'AlternateContent')
    warnings.add(MaterialImportWarning.embeddedObjectsOmitted);
  if (name == 'ins' || name == 'del' || name == 'moveFrom' || name == 'moveTo')
    warnings.add(MaterialImportWarning.trackedChangesOmitted);
  if (name == 'commentRangeStart' ||
      name == 'commentReference' ||
      name == 'footnoteReference' ||
      name == 'endnoteReference')
    warnings.add(MaterialImportWarning.annotationsOmitted);
}

final class _Frame {
  _Frame(this.local, this.ns, this.skip);
  final String local;
  final String? ns;
  final bool skip;
}

final class _Body {
  _Body(this.part, this.limits, this.warnings);
  final String part;
  final MaterialImportLimits limits;
  final Set<MaterialImportWarning> warnings;
  final stack = <_Frame>[];
  final chunks = <(String, MaterialTextBlockKind)>[];
  String? wordNamespace;
  bool documentSeen = false, inBody = false;
  int bodyCount = 0, points = 0, tableDepth = 0;
  StringBuffer? paragraph;
  List<String>? cells, cellParagraphs;

  void add(String value) {
    points += value.runes.length;
    if (points > limits.textCodePoints)
      importFailure(MaterialImportErrorCode.outputTooLarge);
    paragraph?.write(value);
  }

  void event(XmlEvent event) {
    if (event is XmlStartElementEvent) {
      _warningsFor(event, warnings);
      if (!documentSeen) {
        documentSeen = true;
        if (event.localName != 'document' ||
            (event.namespaceUri != _word && event.namespaceUri != _strictWord))
          importFailure(MaterialImportErrorCode.malformedDocument);
        wordNamespace = event.namespaceUri;
      }
      final isWord = event.namespaceUri == wordNamespace;
      final local = event.localName;
      final skipped =
          (stack.lastOrNull?.skip ?? false) ||
          (isWord &&
              {
                'ins',
                'del',
                'moveFrom',
                'moveTo',
                'txbxContent',
                'object',
                'drawing',
                'pict',
              }.contains(local)) ||
          (!isWord &&
              {'oMath', 'oMathPara', 'AlternateContent'}.contains(local)) ||
          (isWord && local == 'tbl' && tableDepth > 0);
      if (isWord && local == 'tbl' && tableDepth > 0)
        warnings.add(MaterialImportWarning.embeddedObjectsOmitted);
      final parent = stack.lastOrNull;
      stack.add(_Frame(local, event.namespaceUri, skipped));
      if (skipped) return;
      if (isWord && local == 'body') {
        if (parent?.local != 'document' ||
            parent?.ns != wordNamespace ||
            ++bodyCount != 1)
          importFailure(MaterialImportErrorCode.malformedDocument);
        inBody = true;
        return;
      }
      if (!inBody || !isWord) return;
      switch (local) {
        case 'tbl':
          tableDepth++;
        case 'tr':
          if (tableDepth != 1 || cells != null)
            importFailure(MaterialImportErrorCode.malformedDocument);
          cells = [];
        case 'tc':
          if (cells == null || cellParagraphs != null)
            importFailure(MaterialImportErrorCode.malformedDocument);
          cellParagraphs = [];
        case 'p':
          if (paragraph != null)
            importFailure(MaterialImportErrorCode.malformedDocument);
          paragraph = StringBuffer();
        case 'tab':
          add('\t');
        case 'br' || 'cr':
          add('\n');
      }
    } else if (event is XmlTextEvent || event is XmlCDATAEvent) {
      final parent = stack.lastOrNull;
      if (inBody &&
          parent != null &&
          !parent.skip &&
          parent.ns == wordNamespace &&
          parent.local == 't') {
        if (paragraph == null)
          importFailure(MaterialImportErrorCode.malformedDocument);
        add(
          event is XmlTextEvent ? event.value : (event as XmlCDATAEvent).value,
        );
      }
    } else if (event is XmlEndElementEvent) {
      if (stack.isEmpty)
        importFailure(MaterialImportErrorCode.malformedDocument);
      final frame = stack.removeLast();
      if (frame.skip || frame.ns != wordNamespace) return;
      switch (frame.local) {
        case 'body':
          inBody = false;
        case 'tbl':
          tableDepth--;
        case 'p':
          final text = paragraph?.toString();
          if (text == null)
            importFailure(MaterialImportErrorCode.malformedDocument);
          paragraph = null;
          if (cellParagraphs != null) {
            cellParagraphs!.add(text);
          } else {
            chunks.add((text, MaterialTextBlockKind.paragraph));
          }
        case 'tc':
          if (cells == null || cellParagraphs == null)
            importFailure(MaterialImportErrorCode.malformedDocument);
          cells!.add(cellParagraphs!.join('\n'));
          cellParagraphs = null;
        case 'tr':
          if (cells == null)
            importFailure(MaterialImportErrorCode.malformedDocument);
          chunks.add((cells!.join('\t'), MaterialTextBlockKind.tableRow));
          cells = null;
      }
    }
  }

  DocxText finish() {
    final out = StringBuffer(), blocks = <MaterialTextBlock>[];
    var count = 0;
    for (final chunk in chunks) {
      if (blocks.isNotEmpty) {
        out.write('\n');
        count++;
      }
      count += chunk.$1.runes.length;
      if (count > limits.textCodePoints)
        importFailure(MaterialImportErrorCode.outputTooLarge);
      final start = out.length;
      out.write(chunk.$1);
      blocks.add(
        MaterialTextBlock(
          kind: chunk.$2,
          start: start,
          end: out.length,
          ordinal: blocks.length,
          partName: part,
        ),
      );
    }
    return DocxText(out.toString(), blocks, warnings);
  }
}
