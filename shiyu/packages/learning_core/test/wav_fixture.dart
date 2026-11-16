import 'dart:math' as math;
import 'dart:typed_data';

/// Original synthetic PCM tone, not English speech, TTS or an audio-quality test.
/// Bytes are generated in memory; this function never plays or records sound.
Uint8List pcmTone(Duration duration, {int sampleRate = 8000}) {
  final samples = duration.inMicroseconds * sampleRate ~/ 1000000;
  final bytes = Uint8List(44 + samples * 2);
  final data = ByteData.sublistView(bytes);
  void tag(int offset, String value) =>
      bytes.setRange(offset, offset + value.length, value.codeUnits);
  tag(0, 'RIFF');
  data.setUint32(4, bytes.length - 8, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, sampleRate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  data.setUint32(40, samples * 2, Endian.little);
  for (var i = 0; i < samples; i++) {
    data.setInt16(
      44 + i * 2,
      (4096 * math.sin(2 * math.pi * 440 * i / sampleRate)).round(),
      Endian.little,
    );
  }
  return bytes;
}
