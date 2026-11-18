// Independent public-Interface fixtures; no user documents or native picker.
// ZIP encoding only constructs synthetic samples. Adversarial mutations alter
// known fixture headers; this is not a second ZIP decoder or production parser.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:material_import/material_import.dart';

const wordNs =
    'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
const types = '''<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Default Extension="png" ContentType="image/png"/>
<Default Extension="bin" ContentType="application/octet-stream"/>
<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
</Types>''';
const rels = '''<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rMain" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>''';

String document(String body, {String prefix = 'w', String ns = wordNs}) =>
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<$prefix:document xmlns:$prefix="$ns"><$prefix:body>'
    '${body.replaceAll('w:', '$prefix:')}'
    '</$prefix:body></$prefix:document>';

Uint8List package(
  String xml, {
  Map<String, List<int>> extra = const {},
  String contentTypes = types,
  String relationships = rels,
}) {
  final archive = Archive();
  final parts = <String, List<int>>{
    '[Content_Types].xml': utf8.encode(contentTypes),
    '_rels/.rels': utf8.encode(relationships),
    'word/document.xml': utf8.encode(xml),
    ...extra,
  };
  for (final entry in parts.entries) {
    archive.add(ArchiveFile.bytes(entry.key, entry.value));
  }
  return ZipEncoder().encodeBytes(archive);
}

Uint8List utf16(String text, {bool bigEndian = false}) {
  final bytes = Uint8List(2 + text.codeUnits.length * 2);
  final data = ByteData.sublistView(bytes);
  bytes[0] = bigEndian ? 0xfe : 0xff;
  bytes[1] = bigEndian ? 0xff : 0xfe;
  for (var i = 0; i < text.codeUnits.length; i++) {
    data.setUint16(2 + 2 * i, text.codeUnits[i],
        bigEndian ? Endian.big : Endian.little);
  }
  return bytes;
}

Uint8List mutateEntry(
  Uint8List source,
  String filename,
  void Function(ByteData data, int offset, bool central) mutation,
) {
  final output = Uint8List.fromList(source);
  final data = ByteData.sublistView(output);
  var matches = 0;
  for (var i = 0; i + 46 < output.length; i++) {
    final signature = data.getUint32(i, Endian.little);
    final central = signature == 0x02014b50;
    if (!central && signature != 0x04034b50) continue;
    final length = data.getUint16(i + (central ? 28 : 26), Endian.little);
    final at = i + (central ? 46 : 30);
    if (at + length > output.length ||
        utf8.decode(output.sublist(at, at + length), allowMalformed: true) !=
            filename) continue;
    mutation(data, i, central);
    matches++;
  }
  check(matches == 2, 'Fixture mutation must touch local and central headers');
  return output;
}

Uint8List renameEntry(Uint8List source, String oldName, String newName) {
  check(utf8.encode(oldName).length == utf8.encode(newName).length,
      'Fixture rename must preserve header lengths');
  return mutateEntry(source, oldName, (data, at, central) {
    final bytes = data.buffer.asUint8List();
    final start = at + (central ? 46 : 30);
    bytes.setRange(start, start + newName.length, ascii.encode(newName));
  });
}

void check(bool condition, String label) {
  if (!condition) throw StateError(label);
}

void rejects(Uint8List bytes,
    {String filename = 'synthetic.docx',
    MaterialImportLimits limits = const MaterialImportLimits(),
    Set<MaterialImportErrorCode>? codes}) {
  try {
    extractMaterial(bytes: bytes, filenameHint: filename, limits: limits);
  } on MaterialImportException catch (error) {
    check(codes == null || codes.contains(error.code), 'Stable error code');
    return;
  }
  throw StateError('Unsafe or unsupported input unexpectedly succeeded');
}

void main() {
  var passed = 0, failed = 0;
  void test(String name, void Function() body) {
    try {
      body();
      passed++;
      stdout.writeln('PASS $name');
    } catch (error) {
      failed++;
      // Never print raw parser error messages, paths or document bodies.
      stdout.writeln('FAIL $name (${error.runtimeType})');
    }
  }

  const paragraph = '<w:p><w:r><w:t>A paper boat.</w:t></w:r></w:p>';
  test('TXT UTF8 BOM keeps Chinese emoji and normalizes line endings', () {
    final bytes = Uint8List.fromList([
      0xef, 0xbb, 0xbf, ...utf8.encode('Hello\r\n中文 😀\rNext\n'),
    ]);
    final result = extractMaterial(bytes: bytes, filenameHint: 'sample.txt');
    check(result.text == 'Hello\n中文 😀\nNext\n', 'Exact text preservation');
    check(result.format == MaterialImportFormat.txt, 'TXT format');
    check(result.sourceSha256 == sha256.convert(bytes).toString(), 'Source hash');
    check(result.textSha256 == sha256.convert(utf8.encode(result.text)).toString(),
        'Extracted hash');
    check(result.blocks.isNotEmpty, 'Original text block location');
  });
  test('TXT UTF16 LE and BE decode real surrogate pair', () {
    for (final big in [false, true]) {
      final result = extractMaterial(
          bytes: utf16('纸船 😀\r\nSecond', bigEndian: big),
          filenameHint: 'unicode.txt');
      check(result.text == '纸船 😀\nSecond', 'UTF16 exact decoding');
    }
  });
  test('TXT invalid UTF8 UTF16 truncation and isolated surrogate fail', () {
    for (final bytes in [
      Uint8List.fromList([0xc3, 0x28]),
      Uint8List.fromList([0xff, 0xfe, 0x41]),
      Uint8List.fromList([0xff, 0xfe, 0x00, 0xd8]),
    ]) {
      rejects(bytes, filename: 'bad.txt',
          codes: {MaterialImportErrorCode.malformedText});
    }
  });
  test('Empty and whitespace files do not become successful material', () {
    rejects(Uint8List(0), filename: 'empty.txt');
    rejects(Uint8List.fromList(utf8.encode(' \r\n\t')), filename: 'blank.txt');
  });
  test('DOCX preserves paragraph line tab and table row order', () {
    final xml = document('<w:p><w:r><w:t>Hello</w:t><w:tab/>'
        '<w:t>world.</w:t><w:br/><w:t>中文 😀</w:t></w:r></w:p>'
        '<w:tbl><w:tr><w:tc><w:p><w:r><w:t>A</w:t></w:r></w:p></w:tc>'
        '<w:tc><w:p><w:r><w:t>B</w:t></w:r></w:p></w:tc></w:tr>'
        '<w:tr><w:tc><w:p><w:r><w:t>C</w:t></w:r></w:p></w:tc>'
        '<w:tc><w:p><w:r><w:t>D</w:t></w:r></w:p></w:tc></w:tr></w:tbl>');
    final result = extractMaterial(bytes: package(xml), filenameHint: 'sample.docx');
    check(result.text.trimRight() == 'Hello\tworld.\n中文 😀\nA\tB\nC\tD',
        'Expected original paragraph/table order');
    check(result.blocks.any((block) => block.kind == MaterialTextBlockKind.tableRow),
        'Table row source location');
    for (final block in result.blocks) {
      check(block.start >= 0 && block.end >= block.start &&
          block.end <= result.text.length, 'Bounded original text positions');
    }
  });
  test('DOCX namespace is identified by URI not literal w prefix', () {
    final result = extractMaterial(bytes: package(document(paragraph, prefix: 'q')),
        filenameHint: 'alternate.docx');
    check(result.text.trim() == 'A paper boat.', 'Namespace-resolved body');
  });
  test('DOCX warns about omitted header images and external relationships', () {
    final xml = document(paragraph);
    const documentRels = '''<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="externalLink" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" Target="https://invalid.example/never-fetch" TargetMode="External"/>
</Relationships>''';
    final result = extractMaterial(
      bytes: package(xml, extra: {
        'word/header1.xml': utf8.encode('<w:hdr xmlns:w="$wordNs">'
            '<w:p><w:r><w:t>Omitted header fixture</w:t></w:r></w:p></w:hdr>'),
        'word/_rels/document.xml.rels': utf8.encode(documentRels),
        'word/media/image.png': [0x89, 0x50, 0x4e, 0x47],
      }),
      filenameHint: 'partial.docx',
    );
    check(result.text.trim() == 'A paper boat.', 'Only approved document body');
    check(result.warnings.contains(MaterialImportWarning.headersFootersOmitted),
        'Header omission visible');
    check(result.warnings.contains(MaterialImportWarning.imagesOmitted),
        'Image omission visible');
    check(result.warnings.contains(MaterialImportWarning.externalLinksNotFollowed),
        'External relation not fetched');
  });
  test('DOCX actual content type and root main relation are required', () {
    rejects(package(document(paragraph),
        contentTypes: types.replaceAll('wordprocessingml.document.main+xml',
            'presentationml.presentation.main+xml')));
    rejects(package(document(paragraph), relationships:
        rels.replaceAll('word/document.xml', 'word/other.xml')));
    rejects(Uint8List.fromList(utf8.encode('This is not an OOXML package.')));
  });
  test('DOCX DTD custom and external entities are rejected', () {
    for (final declaration in [
      '<!DOCTYPE w:document [<!ENTITY x "nested fixture">]>',
      '<!DOCTYPE w:document [<!ENTITY x SYSTEM "https://invalid.example/no-fetch">]>',
    ]) {
      final xml = document('<w:p><w:r><w:t>&x;</w:t></w:r></w:p>')
          .replaceFirst('<w:document', '$declaration<w:document');
      rejects(package(xml));
    }
  });
  test('DOCX numeric emoji works but forbidden scalar entities fail', () {
    final result = extractMaterial(bytes: package(document(
        '<w:p><w:r><w:t>&#x1F600; &amp; &#65;</w:t></w:r></w:p>')),
        filenameHint: 'entities.docx');
    check(result.text.trim() == '😀 & A', 'Built-in and numeric entities');
    for (final entity in ['&#xD800;', '&#0;', '&#x110000;']) {
      rejects(package(document('<w:p><w:r><w:t>$entity</w:t></w:r></w:p>')));
    }
  });
  test('DOCX duplicate canonical parts cannot use last-writer-wins', () {
    final base = package(document(paragraph), extra: {
      'word/a.xml': utf8.encode('<fixture/>'),
      'word/b.xml': utf8.encode('<different/>'),
    });
    rejects(renameEntry(base, 'word/b.xml', 'word/a.xml'));
  });
  test('DOCX traversal entries are rejected before any extraction', () {
    final base = package(document(paragraph), extra: {
      'xx/evil.txt': utf8.encode('not executed'),
    });
    rejects(renameEntry(base, 'xx/evil.txt', '../evil.txt'));
  });
  test('DOCX declared encryption cannot reach plaintext extraction', () {
    final bytes = mutateEntry(package(document(paragraph)), 'word/document.xml',
        (data, at, central) {
      final offset = at + (central ? 8 : 6);
      data.setUint16(offset, data.getUint16(offset, Endian.little) | 1, Endian.little);
    });
    rejects(bytes);
  });
  test('DOCX corrupted CRC with matching local central claims is rejected', () {
    final bytes = mutateEntry(package(document(paragraph)), 'word/document.xml',
        (data, at, central) {
      final offset = at + (central ? 16 : 14);
      data.setUint32(offset, data.getUint32(offset, Endian.little) ^ 1, Endian.little);
    });
    rejects(bytes);
  });
  test('DOCX underdeclared inflate output cannot succeed', () {
    final xml = document('<w:p><w:r><w:t>${'x' * 16000}</w:t></w:r></w:p>');
    final bytes = mutateEntry(package(xml), 'word/document.xml', (data, at, central) {
      data.setUint32(at + (central ? 24 : 22), 16, Endian.little);
    });
    rejects(bytes);
  });
  test('Source entry total XML and text resource limits reject whole result', () {
    final bytes = package(document(paragraph), extra: {
      'word/media/ignored.bin': List<int>.filled(4096, 0),
    });
    for (final limits in [
      const MaterialImportLimits(sourceBytes: 8),
      const MaterialImportLimits(entries: 2),
      const MaterialImportLimits(entryBytes: 1024),
      const MaterialImportLimits(totalInflatedBytes: 2048),
      const MaterialImportLimits(xmlBytes: 40),
      const MaterialImportLimits(textCodePoints: 3),
    ]) {
      rejects(bytes, limits: limits);
    }
  });
  test('XML deep nesting and excessive event count are bounded', () {
    final deep = document('${'<w:customXml>' * 40}$paragraph${'</w:customXml>' * 40}');
    rejects(package(deep), limits: const MaterialImportLimits(xmlDepth: 16));
    rejects(package(document(paragraph * 30)),
        limits: const MaterialImportLimits(xmlEvents: 20));
  });
  test('DOCX symlink file metadata is rejected', () {
    final source = package(document(paragraph), extra: {
      'word/link': utf8.encode('document.xml'),
    });
    final changed = mutateEntry(source, 'word/link', (data, at, central) {
      if (central) {
        data.setUint16(at + 4, 0x0314, Endian.little);
        data.setUint32(at + 38, 0xa1ff << 16, Endian.little);
      }
    });
    rejects(changed);
  });
  test('PDF DOC and DOCM are not represented as supported extraction', () {
    rejects(Uint8List.fromList(ascii.encode('%PDF-1.7 fixture')), filename: 'x.pdf');
    rejects(Uint8List.fromList([0xd0, 0xcf, 0x11, 0xe0]), filename: 'x.doc');
    rejects(package(document(paragraph)), filename: 'x.docm');
  });
  stdout.writeln('RESULT passed=$passed failed=$failed total=${passed + failed}');
  if (failed != 0) exitCode = 1;
}
