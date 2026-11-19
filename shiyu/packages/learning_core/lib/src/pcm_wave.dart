import 'dart:convert';
import 'dart:typed_data';

/// Pure container validation; never claims speech quality or semantic alignment.
final class PcmWaveInfo {
  const PcmWaveInfo({
    required this.durationMs,
    required this.dataBytes,
    required this.byteRate,
  });
  final int durationMs, dataBytes, byteRate;
}

PcmWaveInfo? inspectPcmWave(Uint8List bytes, {bool strictExternal = false}) {
  try {
    if (strictExternal && (bytes.length < 44 || bytes.length > 2 * 1024 * 1024))
      return null;
    if (bytes.length < 12 ||
        ascii.decode(bytes.sublist(0, 4), allowInvalid: true) != 'RIFF' ||
        ascii.decode(bytes.sublist(8, 12), allowInvalid: true) != 'WAVE')
      return null;
    final data = ByteData.sublistView(bytes);
    final limit = data.getUint32(4, Endian.little) + 8;
    if (strictExternal &&
        (ascii.decode(bytes.sublist(12, 16), allowInvalid: true) != 'fmt ' ||
            data.getUint32(16, Endian.little) != 16 ||
            data.getUint16(20, Endian.little) != 1 ||
            data.getUint16(22, Endian.little) != 1 ||
            data.getUint32(24, Endian.little) != 16000 ||
            data.getUint32(28, Endian.little) != 32000 ||
            data.getUint16(32, Endian.little) != 2 ||
            data.getUint16(34, Endian.little) != 16 ||
            ascii.decode(bytes.sublist(36, 40), allowInvalid: true) != 'data' ||
            data.getUint32(40, Endian.little) != bytes.length - 44 ||
            (bytes.length - 44).isOdd ||
            bytes.length - 44 > 1920000))
      return null;

    if (limit != bytes.length) return null;
    int? blockAlign, byteRate;
    var cursor = 12, samples = 0, formats = 0;
    while (cursor + 8 <= limit) {
      final name = ascii.decode(
        bytes.sublist(cursor, cursor + 4),
        allowInvalid: true,
      );
      final length = data.getUint32(cursor + 4, Endian.little),
          begin = cursor + 8;
      if (begin + length > limit) return null;
      if (name == 'fmt ') {
        if (length < 16 ||
            ++formats != 1 ||
            data.getUint16(begin, Endian.little) != 1)
          return null;
        final channels = data.getUint16(begin + 2, Endian.little);
        final rate = data.getUint32(begin + 4, Endian.little);
        byteRate = data.getUint32(begin + 8, Endian.little);
        blockAlign = data.getUint16(begin + 12, Endian.little);
        final bits = data.getUint16(begin + 14, Endian.little);
        if (channels < 1 ||
            channels > 8 ||
            rate < 1 ||
            rate > 384000 ||
            ![8, 16, 24, 32].contains(bits) ||
            blockAlign != channels * (bits ~/ 8) ||
            byteRate != rate * blockAlign)
          return null;
      } else if (name == 'data') {
        samples += length;
      }
      cursor = begin + length + (length.isOdd ? 1 : 0);
    }
    if (cursor != limit ||
        formats != 1 ||
        byteRate == null ||
        blockAlign == null ||
        samples < 1 ||
        samples % blockAlign != 0)
      return null;
    final ms = (samples * 1000) ~/ byteRate;
    return ms > 0
        ? PcmWaveInfo(durationMs: ms, dataBytes: samples, byteRate: byteRate)
        : null;
  } catch (_) {
    return null;
  }
}
