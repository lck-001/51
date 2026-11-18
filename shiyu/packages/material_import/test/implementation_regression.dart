import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:material_import/material_import.dart';

const ns = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
const strictNs = 'http://purl.oclc.org/ooxml/wordprocessingml/main';
Uint8List doc(List<int> main, {Map<String, List<int>> extra = const {}}) {
  final parts = <String, List<int>>{
    '[Content_Types].xml': utf8.encode(
      '''<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
      <Default Extension="xml" ContentType="application/xml"/>
      <Default Extension="dat" ContentType="application/octet-stream"/>
      <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>''',
    ),
    '_rels/.rels': utf8.encode(
      '''<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="main" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>''',
    ),
    'word/document.xml': main,
    ...extra,
  };
  final archive = Archive();
  for (final e in parts.entries) {
    archive.add(ArchiveFile.bytes(e.key, e.value));
  }
  return ZipEncoder().encodeBytes(archive);
}

String xml(String text, {String namespace = ns}) =>
    '<w:document xmlns:w="$namespace"><w:body><w:p><w:r><w:t>$text</w:t></w:r></w:p></w:body></w:document>';
Uint8List utf16(String text, {bool little = true}) {
  final b = Uint8List(2 + text.length * 2), d = ByteData(2 + text.length * 2);
  b[0] = little ? 0xff : 0xfe;
  b[1] = little ? 0xfe : 0xff;
  for (var i = 0; i < text.length; i++) {
    d.setUint16(
      2 + i * 2,
      text.codeUnitAt(i),
      little ? Endian.little : Endian.big,
    );
  }
  b.setRange(2, b.length, d.buffer.asUint8List(2));
  return b;
}

void check(bool ok, String label) {
  if (!ok) throw StateError(label);
}

void refuses(
  Uint8List bytes, {
  String hint = 'sample.docx',
  MaterialImportLimits limits = const MaterialImportLimits(),
}) {
  try {
    extractMaterial(bytes: bytes, filenameHint: hint, limits: limits);
  } on MaterialImportException {
    return;
  }
  throw StateError('invalid input accepted');
}

void main() {
  var passed = 0, failed = 0;
  void test(String name, void Function() body) {
    try {
      body();
      passed++;
      stdout.writeln('PASS $name');
    } catch (_) {
      failed++;
      stdout.writeln('FAIL $name');
    }
  }

  test(
    'TXT UTF16 endian variants preserve emoji and exact UTF16 block offsets',
    () {
      for (final little in [true, false]) {
        final bytes = utf16('中文😀\r\nHello', little: little);
        final result = extractMaterial(bytes: bytes, filenameHint: 'local.txt');
        check(result.text == '中文😀\nHello', 'normalized text');
        check(result.blocks.single.end == result.text.length, 'UTF16 offsets');
        check(
          result.sourceSha256 == sha256.convert(bytes).toString(),
          'source hash',
        );
        check(
          result.textSha256 ==
              sha256.convert(utf8.encode(result.text)).toString(),
          'text hash',
        );
      }
    },
  );
  test('TXT malformed UTF16 and UTF8 are rejected rather than replaced', () {
    for (final raw in [
      [0xff, 0xfe, 0x01],
      [0xff, 0xfe, 0x00, 0xd8],
      [0xff, 0xfe, 0x00, 0xdc],
      [0xc0, 0xaf],
    ]) {
      refuses(Uint8List.fromList(raw), hint: 'sample.txt');
    }
  });
  test('strict Word namespace and default namespace extract in document order', () {
    final result = extractMaterial(
      bytes: doc(
        utf8.encode(
          '<document xmlns="$strictNs"><body><p><r><t>Strict 😀</t></r></p></body></document>',
        ),
      ),
      filenameHint: 'sample.docx',
    );
    check(result.text == 'Strict 😀', 'strict text');
    check(result.blocks.single.partName == 'word/document.xml', 'part mapping');
  });
  test('UTF16 XML BOM works and declaration disagreement fails', () {
    final good = utf16(
      '<?xml version="1.0" encoding="UTF-16"?>${xml('Hello')}',
    );
    check(
      extractMaterial(bytes: doc(good), filenameHint: 'sample.docx').text ==
          'Hello',
      'UTF16 XML',
    );
    refuses(
      doc(
        utf8.encode('<?xml version="1.0" encoding="UTF-16"?>${xml('Hello')}'),
      ),
    );
  });
  test('unknown entities and bare ampersands do not silently become text', () {
    refuses(doc(utf8.encode(xml('&missing;'))));
    refuses(doc(utf8.encode(xml('A & B'))));
    check(
      extractMaterial(
            bytes: doc(utf8.encode(xml('A &amp; B'))),
            filenameHint: 'sample.docx',
          ).text ==
          'A & B',
      'standard XML entity',
    );
  });
  test('ignored XML part DTD remains forbidden', () {
    refuses(
      doc(
        utf8.encode(xml('Main')),
        extra: {
          'word/styles.xml': utf8.encode('<!DOCTYPE x [<!ENTITY a "x">]><x/>'),
        },
      ),
    );
  });
  test(
    'local header name disagreement is refused despite valid central content',
    () {
      final bytes = doc(utf8.encode(xml('Main')));
      final broken = Uint8List.fromList(bytes);
      broken[30] = 'X'.codeUnitAt(0);
      refuses(broken);
    },
  );
  test(
    'discarded binary entries count towards actual cumulative output limit',
    () {
      final bytes = doc(
        utf8.encode(xml('Main')),
        extra: {'word/ignored.dat': List.filled(128 * 1024, 65)},
      );
      refuses(
        bytes,
        limits: const MaterialImportLimits(totalInflatedBytes: 8192),
      );
    },
  );
  test('tracked and textbox content is omitted with explicit warnings', () {
    final raw =
        '<w:document xmlns:w="$ns"><w:body><w:p><w:r><w:t>Kept</w:t></w:r><w:ins><w:r><w:t>Inserted</w:t></w:r></w:ins><w:txbxContent><w:p><w:r><w:t>Box</w:t></w:r></w:p></w:txbxContent></w:p></w:body></w:document>';
    final result = extractMaterial(
      bytes: doc(utf8.encode(raw)),
      filenameHint: 'sample.docx',
    );
    check(result.text == 'Kept', 'omitted content');
    check(
      result.warnings.contains(MaterialImportWarning.trackedChangesOmitted) &&
          result.warnings.contains(
            MaterialImportWarning.embeddedObjectsOmitted,
          ),
      'warnings',
    );
  });
  test('XML event budget includes metadata and body cumulatively', () {
    try {
      extractMaterial(
        bytes: doc(utf8.encode(xml('Main'))),
        filenameHint: 'sample.docx',
        limits: const MaterialImportLimits(xmlEvents: 20),
      );
    } on MaterialImportException catch (e) {
      check(
        e.code == MaterialImportErrorCode.outputTooLarge,
        'event budget classification',
      );
      return;
    }
    throw StateError('package-wide XML event cap not enforced');
  });
  test('representative thousand-paragraph source is complete within candidate limits', () {
    final body = List.generate(
      1000,
      (i) =>
          '<w:p><w:r><w:t>Section $i: Hello 中文 😀, keep the full sentence.</w:t></w:r></w:p>',
    ).join();
    final source = doc(
      utf8.encode(
        '<w:document xmlns:w="$ns"><w:body>$body</w:body></w:document>',
      ),
    );
    final watch = Stopwatch()..start();
    final result = extractMaterial(bytes: source, filenameHint: 'sample.docx');
    watch.stop();
    check(
      result.blocks.length == 1000 &&
          result.text.startsWith('Section 0:') &&
          result.text.endsWith(
            'Section 999: Hello 中文 😀, keep the full sentence.',
          ),
      'complete ordinary source',
    );
    stdout.writeln(
      'BASELINE paragraphs=1000 compressedBytes=${source.length} textCodePoints=${result.text.runes.length} elapsedMs=${watch.elapsedMilliseconds} processMaxRssBytes=${ProcessInfo.maxRss}',
    );
  });
  stdout.writeln(
    'RESULT passed=$passed failed=$failed total=${passed + failed}',
  );
  if (failed != 0) exitCode = 1;
}
