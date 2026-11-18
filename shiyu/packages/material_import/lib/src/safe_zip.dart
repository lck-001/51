import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../material_import.dart';
import 'strict_text.dart';

final class SafeZip {
  SafeZip(this.bytes, this.limits) {
    try {
      _index();
    } on MaterialImportException {
      rethrow;
    } catch (_) {
      importFailure(MaterialImportErrorCode.malformedZip);
    }
  }
  final Uint8List bytes;
  final MaterialImportLimits limits;
  final entries = <String, ZipFileHeader>{};
  final _read = <String>{};
  var inflated = 0;
  late final ByteData data = ByteData.sublistView(bytes);
  int u16(int p) => data.getUint16(p, Endian.little);
  int u32(int p) => data.getUint32(p, Endian.little);
  void range(int p, int length, [int? end]) {
    if (p < 0 || length < 0 || p > (end ?? bytes.length) - length) {
      importFailure(MaterialImportErrorCode.malformedZip);
    }
  }

  String nameAt(int p, int length, int flags) {
    range(p, length);
    final raw = Uint8List.sublistView(bytes, p, p + length);
    if (flags & 0x800 == 0 && raw.any((b) => b >= 128)) {
      // Do not guess a legacy ZIP code page or let a Unicode extra field rename
      // a different raw path. Word-generated ASCII and explicit UTF-8 work.
      importFailure(MaterialImportErrorCode.unsafePackage);
    }
    return utf8.decode(raw, allowMalformed: false);
  }

  void extra(int p, int length) {
    final end = p + length;
    range(p, length);
    while (p < end) {
      range(p, 4, end);
      final id = u16(p), size = u16(p + 2);
      p += 4;
      range(p, size, end);
      if (id == 0x9901) importFailure(MaterialImportErrorCode.encrypted);
      if (id == 1 || id == 0x7075)
        importFailure(MaterialImportErrorCode.unsafePackage);
      p += size;
    }
  }

  void _index() {
    range(0, 4);
    if (u32(0) != 0x04034b50)
      importFailure(MaterialImportErrorCode.malformedZip);
    final directory = ZipDirectory();
    final stream = InputMemoryStream(bytes);
    final names = <String>{}, offsets = <int>{};
    final spans = <(int, int)>[];
    var count = 0, central = -1;
    for (final h in directory.headers(stream, verify: true)) {
      if (++count > limits.entries)
        importFailure(MaterialImportErrorCode.outputTooLarge);
      if (central < 0) central = directory.centralDirectoryOffset;
      range(central, 46);
      if (u32(central) != 0x02014b50)
        importFailure(MaterialImportErrorCode.malformedZip);
      final flags = u16(central + 8), method = u16(central + 10);
      final nameLength = u16(central + 28),
          extraLength = u16(central + 30),
          commentLength = u16(central + 32);
      range(central + 46, nameLength + extraLength + commentLength);
      final name = nameAt(central + 46, nameLength, flags);
      if (name != h.filename ||
          !safePartName(name) ||
          !names.add(name.toLowerCase())) {
        importFailure(MaterialImportErrorCode.unsafePackage);
      }
      if (flags & (1 | 0x40 | 0x2000) != 0)
        importFailure(MaterialImportErrorCode.encrypted);
      if (flags & ~0x80e != 0 || (method != 0 && method != 8))
        importFailure(MaterialImportErrorCode.unsafePackage);
      if (h.diskNumberStart != 0 ||
          h.compressedSize < 0 ||
          h.uncompressedSize < 0 ||
          h.compressedSize == 0xffffffff ||
          h.uncompressedSize == 0xffffffff ||
          u32(central + 42) != h.localHeaderOffset ||
          !offsets.add(h.localHeaderOffset)) {
        importFailure(MaterialImportErrorCode.malformedZip);
      }
      if (h.uncompressedSize > limits.entryBytes)
        importFailure(MaterialImportErrorCode.outputTooLarge);
      final mode = (h.externalFileAttributes >> 16) & 0xf000;
      if (mode != 0 && mode != 0x8000 && mode != 0x4000)
        importFailure(MaterialImportErrorCode.unsafePackage);
      if (h.externalFileAttributes & 0x400 != 0 ||
          (mode == 0x4000 && !name.endsWith('/')) ||
          (mode == 0x8000 && name.endsWith('/'))) {
        importFailure(MaterialImportErrorCode.unsafePackage);
      }
      if (name.toLowerCase().contains('vbaproject') ||
          name.toLowerCase().endsWith('.bin') &&
              name.toLowerCase().contains('vba')) {
        importFailure(MaterialImportErrorCode.unsafePackage);
      }
      extra(central + 46 + nameLength, extraLength);
      final p = h.localHeaderOffset;
      range(p, 30, directory.centralDirectoryOffset);
      if (u32(p) != 0x04034b50 || u16(p + 6) != flags || u16(p + 8) != method) {
        importFailure(MaterialImportErrorCode.malformedZip);
      }
      final localNameLength = u16(p + 26), localExtraLength = u16(p + 28);
      final start = p + 30 + localNameLength + localExtraLength;
      range(
        p + 30,
        localNameLength + localExtraLength,
        directory.centralDirectoryOffset,
      );
      if (nameAt(p + 30, localNameLength, flags) != name)
        importFailure(MaterialImportErrorCode.malformedZip);
      extra(p + 30 + localNameLength, localExtraLength);
      final localCrc = u32(p + 14),
          localCompressed = u32(p + 18),
          localExpanded = u32(p + 22);
      if (flags & 8 == 0) {
        if (localCrc != h.crc32 ||
            localCompressed != h.compressedSize ||
            localExpanded != h.uncompressedSize) {
          importFailure(MaterialImportErrorCode.malformedZip);
        }
      } else if ((localCrc != 0 && localCrc != h.crc32) ||
          (localCompressed != 0 && localCompressed != h.compressedSize) ||
          (localExpanded != 0 && localExpanded != h.uncompressedSize)) {
        importFailure(MaterialImportErrorCode.malformedZip);
      }
      range(start, h.compressedSize, directory.centralDirectoryOffset);
      var end = start + h.compressedSize;
      if (flags & 8 != 0) {
        range(end, 12, directory.centralDirectoryOffset);
        if (u32(end) == 0x08074b50) {
          end += 4;
          range(end, 12, directory.centralDirectoryOffset);
        }
        if (u32(end) != h.crc32 ||
            u32(end + 4) != h.compressedSize ||
            u32(end + 8) != h.uncompressedSize) {
          importFailure(MaterialImportErrorCode.malformedZip);
        }
        end += 12;
      }
      if (name.endsWith('/') &&
          (h.compressedSize != 0 || h.uncompressedSize != 0))
        importFailure(MaterialImportErrorCode.malformedZip);
      spans.add((p, end));
      entries[name] = h;
      central += 46 + nameLength + extraLength + commentLength;
    }
    if (count == 0 ||
        count != directory.totalCentralDirectoryEntries ||
        count != directory.totalCentralDirectoryEntriesOnThisDisk ||
        directory.numberOfThisDisk != 0 ||
        directory.diskWithTheStartOfTheCentralDirectory != 0 ||
        central !=
            directory.centralDirectoryOffset + directory.centralDirectorySize ||
        central != directory.filePosition)
      importFailure(MaterialImportErrorCode.malformedZip);
    range(directory.filePosition, 22);
    if (directory.filePosition + 22 + u16(directory.filePosition + 20) !=
        bytes.length)
      importFailure(MaterialImportErrorCode.malformedZip);
    spans.sort((a, b) => a.$1.compareTo(b.$1));
    for (var i = 1; i < spans.length; i++) {
      if (spans[i].$1 < spans[i - 1].$2)
        importFailure(MaterialImportErrorCode.malformedZip);
    }
  }

  Uint8List read(String name, {required bool keep}) {
    if (!_read.add(name)) throw StateError('entry_read_twice');
    final h = entries[name];
    if (h == null) importFailure(MaterialImportErrorCode.malformedDocument);
    try {
      final output = _CountedOutput(this, keep);
      final file = h.file;
      if (file == null) importFailure(MaterialImportErrorCode.malformedZip);
      file.decompress(output);
      if (output.length != h.uncompressedSize || output.crc != h.crc32)
        importFailure(MaterialImportErrorCode.malformedZip);
      return output.bytes?.takeBytes() ?? Uint8List(0);
    } on MaterialImportException {
      rethrow;
    } catch (_) {
      importFailure(MaterialImportErrorCode.malformedZip);
    }
  }
}

bool safePartName(String name) {
  if (name.isEmpty ||
      name.startsWith('/') ||
      name.contains('\\') ||
      name.contains(':') ||
      name.contains('%') ||
      name.contains('?') ||
      name.contains('#'))
    return false;
  if (name.runes.any((r) => r < 0x20 || r == 0x7f)) return false;
  final parts = name.split('/');
  if (parts.last.isEmpty) parts.removeLast();
  return parts.isNotEmpty &&
      !parts.any((p) => p.isEmpty || p == '.' || p == '..');
}

final class _CountedOutput extends OutputStream {
  _CountedOutput(this.zip, bool keep)
    : bytes = keep ? BytesBuilder() : null,
      super(byteOrder: ByteOrder.littleEndian);
  final SafeZip zip;
  final BytesBuilder? bytes;
  var _length = 0, crc = 0;
  @override
  int get length => _length;
  @override
  void writeByte(int value) => writeBytes([value]);
  @override
  void writeBytes(List<int> values, {int? length}) {
    final size = length ?? values.length;
    if (size < 0 || size > values.length)
      importFailure(MaterialImportErrorCode.malformedZip);
    if (_length + size > zip.limits.entryBytes ||
        zip.inflated + size > zip.limits.totalInflatedBytes ||
        (bytes != null && _length + size > zip.limits.xmlBytes)) {
      importFailure(MaterialImportErrorCode.outputTooLarge);
    }
    _length += size;
    zip.inflated += size;
    final chunk = size == values.length ? values : values.sublist(0, size);
    crc = getCrc32(chunk, crc);
    bytes?.add(chunk);
  }

  @override
  void writeStream(InputStream stream) {
    final pos = stream.position;
    try {
      while (!stream.isEOS) {
        writeBytes(stream.readBytes(min(8192, stream.length)).toUint8List());
      }
    } finally {
      stream.setPosition(pos);
    }
  }

  @override
  void clear() => throw UnsupportedError('counted_output');
  @override
  void flush() {}
  @override
  Uint8List subset(int start, [int? end]) =>
      throw UnsupportedError('native_streaming_only');
}
