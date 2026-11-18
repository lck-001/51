import 'dart:convert';
import 'dart:typed_data';

const compositionParagraphs = '今天先核对需求，再运行测试。\n确认没有问题后保存修改。';
const compositionTable = '事项\t状态\n核对需求\t待办';

Uint8List originalCompositionText() => Uint8List.fromList([
  0xef,
  0xbb,
  0xbf,
  ...utf8.encode(compositionParagraphs.replaceAll('\n', '\r\n')),
]);

Uint8List originalCompositionDocx() => _storeZip({
  '[Content_Types].xml':
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
      '<Default Extension="xml" ContentType="application/xml"/>'
      '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
      '</Types>',
  '_rels/.rels':
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="r" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
      '</Relationships>',
  'word/document.xml':
      '<q:document xmlns:q="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><q:body>'
      '<q:p><q:r><q:t>今天先核对需求，再运行测试。</q:t></q:r></q:p>'
      '<q:p><q:r><q:t>确认没有问题后保存修改。</q:t></q:r></q:p>'
      '<q:tbl><q:tr><q:tc><q:p><q:r><q:t>事项</q:t></q:r></q:p></q:tc>'
      '<q:tc><q:p><q:r><q:t>状态</q:t></q:r></q:p></q:tc></q:tr>'
      '<q:tr><q:tc><q:p><q:r><q:t>核对需求</q:t></q:r></q:p></q:tc>'
      '<q:tc><q:p><q:r><q:t>待办</q:t></q:r></q:p></q:tc></q:tr></q:tbl>'
      '</q:body></q:document>',
});

// Tiny deterministic fixture writer only, not a product ZIP implementation.
Uint8List _storeZip(Map<String, String> files) {
  final local = BytesBuilder(), central = BytesBuilder();
  void u16(BytesBuilder out, int n) => out.add(
    (ByteData(2)..setUint16(0, n, Endian.little)).buffer.asUint8List(),
  );
  void u32(BytesBuilder out, int n) => out.add(
    (ByteData(4)..setUint32(0, n, Endian.little)).buffer.asUint8List(),
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
    for (final n in [20, 0x800, 0, 0, 0]) {
      u16(local, n);
    }
    for (final n in [crc, bytes.length, bytes.length]) {
      u32(local, n);
    }
    u16(local, name.length);
    u16(local, 0);
    local.add(name);
    local.add(bytes);
    u32(central, 0x02014b50);
    for (final n in [20, 20, 0x800, 0, 0, 0]) {
      u16(central, n);
    }
    for (final n in [crc, bytes.length, bytes.length]) {
      u32(central, n);
    }
    for (final n in [name.length, 0, 0, 0, 0]) {
      u16(central, n);
    }
    u32(central, 0);
    u32(central, offset);
    central.add(name);
  }
  final out = BytesBuilder()..add(local.takeBytes());
  final offset = out.length, dir = central.takeBytes();
  out.add(dir);
  u32(out, 0x06054b50);
  for (final n in [0, 0, files.length, files.length]) {
    u16(out, n);
  }
  u32(out, dir.length);
  u32(out, offset);
  u16(out, 0);
  return out.takeBytes();
}
