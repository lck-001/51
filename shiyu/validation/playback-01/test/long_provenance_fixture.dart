import 'dart:convert';
import 'dart:typed_data';

// A tiny, deterministic classic-STORE ZIP fixture writer, never a production
// extractor. The ~2KiB main part name and 1000 tiny paragraphs stay far below
// input/XML/text limits but used to amplify serialized provenance above 2MiB.
Uint8List longProvenanceDocx() {
  final part = 'word/${List.filled(18, 'p' * 120).join('/')}/document.xml';
  final files = <String, String>{
    '[Content_Types].xml':
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/$part" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
        '</Types>',
    '_rels/.rels':
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="r" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="$part"/>'
        '</Relationships>',
    part:
        '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>'
        '${List.filled(1000, '<w:p><w:r><w:t>x</w:t></w:r></w:p>').join()}'
        '</w:body></w:document>',
  };
  final local = BytesBuilder(), central = BytesBuilder();
  void u16(BytesBuilder out, int value) => out.add(
    (ByteData(2)..setUint16(0, value, Endian.little)).buffer.asUint8List(),
  );
  void u32(BytesBuilder out, int value) => out.add(
    (ByteData(4)..setUint32(0, value, Endian.little)).buffer.asUint8List(),
  );
  int crc32(List<int> bytes) {
    var crc = 0xffffffff;
    for (final byte in bytes) {
      crc ^= byte;
      for (var i = 0; i < 8; i++) {
        crc = (crc >>> 1) ^ ((crc & 1) != 0 ? 0xedb88320 : 0);
      }
    }
    return (crc ^ 0xffffffff) & 0xffffffff;
  }

  for (final entry in files.entries) {
    final name = utf8.encode(entry.key), bytes = utf8.encode(entry.value);
    final offset = local.length, crc = crc32(bytes);
    u32(local, 0x04034b50);
    for (final value in [20, 0x800, 0, 0, 0]) {
      u16(local, value);
    }
    for (final value in [crc, bytes.length, bytes.length]) {
      u32(local, value);
    }
    u16(local, name.length);
    u16(local, 0);
    local.add(name);
    local.add(bytes);
    u32(central, 0x02014b50);
    for (final value in [20, 20, 0x800, 0, 0, 0]) {
      u16(central, value);
    }
    for (final value in [crc, bytes.length, bytes.length]) {
      u32(central, value);
    }
    for (final value in [name.length, 0, 0, 0, 0]) {
      u16(central, value);
    }
    u32(central, 0);
    u32(central, offset);
    central.add(name);
  }
  final result = BytesBuilder()..add(local.takeBytes());
  final offset = result.length, directory = central.takeBytes();
  result.add(directory);
  u32(result, 0x06054b50);
  for (final value in [0, 0, files.length, files.length]) {
    u16(result, value);
  }
  u32(result, directory.length);
  u32(result, offset);
  u16(result, 0);
  return result.takeBytes();
}
