import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../lib/learning_playback.dart';

void expectThat(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> until(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline))
      throw StateError('expected controlled-adapter event did not arrive');
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

Future<void> inSandbox(Future<void> Function(Directory sandbox) body) async {
  final root = await Directory.systemTemp.createTemp(
    'shiyu-learning-playback-qa-',
  );
  final resolved = await root.resolveSymbolicLinks();
  try {
    await body(root);
  } finally {
    if (await root.exists()) {
      final temp = await Directory.systemTemp.resolveSymbolicLinks();
      final current = await root.resolveSymbolicLinks();
      expectThat(
        current == resolved &&
            current.startsWith(
              '$temp${Platform.pathSeparator}shiyu-learning-playback-qa-',
            ),
        'refuse cleanup outside owned synthetic temporary directory',
      );
      await root.delete(recursive: true);
    }
  }
}

/// Original synthetic PCM silence; not English speech, a model output or TTS.
Uint8List syntheticWav({int seconds = 6}) {
  final bytes = Uint8List(44 + seconds * 8000 * 2);
  final data = ByteData.sublistView(bytes);
  void tag(int offset, String text) =>
      bytes.setRange(offset, offset + text.length, text.codeUnits);
  tag(0, 'RIFF');
  data.setUint32(4, bytes.length - 8, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 8000, Endian.little);
  data.setUint32(28, 16000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  data.setUint32(40, bytes.length - 44, Endian.little);
  return bytes;
}

class Cases {
  var passed = 0, failed = 0;
  Future<void> run(String name, Future<void> Function() body) async {
    try {
      await body().timeout(const Duration(seconds: 20));
      passed++;
      stdout.writeln('PASS $name');
    } catch (error) {
      failed++;
      final detail = error is StateError
          ? error.message
          : error is LearningPlaybackException
          ? error.code.name
          : error.runtimeType;
      stdout.writeln('FAIL $name: $detail');
    }
  }

  void finish() {
    stdout.writeln(
      'RESULT passed=$passed failed=$failed total=${passed + failed}',
    );
    if (failed != 0) exitCode = 1;
  }
}
