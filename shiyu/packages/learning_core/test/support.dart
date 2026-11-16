import 'dart:async';
import 'dart:io';

import '../lib/learning_core.dart';

void expectThat(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> inSandbox(Future<void> Function(Directory sandbox) body) async {
  final directory = await Directory.systemTemp.createTemp('shiyu-learning-qa-');
  final resolved = await directory.resolveSymbolicLinks();
  try {
    await body(directory);
  } finally {
    if (await directory.exists()) {
      final tempRoot = await Directory.systemTemp.resolveSymbolicLinks();
      final actual = await directory.resolveSymbolicLinks();
      expectThat(
        actual == resolved &&
            actual.startsWith(
              '$tempRoot${Platform.pathSeparator}shiyu-learning-qa-',
            ),
        'refuse cleanup outside owned synthetic temporary directory',
      );
      await directory.delete(recursive: true);
    }
  }
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
          : error is LearningStoreException
          ? 'LearningStoreException(${error.code.name})'
          : error.runtimeType;
      stdout.writeln('FAIL $name: $detail');
    }
  }

  void finish() {
    stdout.writeln(
      'RESULT passed=$passed failed=$failed total=${passed + failed}',
    );
    if (failed > 0) exitCode = 1;
  }
}
