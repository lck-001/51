import 'dart:async';
import 'dart:io';

import '../lib/material_core.dart';

void expectThat(bool condition, String message) {
  if (!condition) throw StateError(message);
}

/// Only recursively removes a directory this test created below systemTemp.
Future<void> inSandbox(Future<void> Function(Directory sandbox) body) async {
  final parent = await Directory.systemTemp.createTemp('shiyu-material-qa-');
  final resolved = await parent.resolveSymbolicLinks();
  try {
    await body(parent);
  } finally {
    if (await parent.exists()) {
      final temporaryRoot = await Directory.systemTemp.resolveSymbolicLinks();
      final actual = await parent.resolveSymbolicLinks();
      expectThat(
        actual == resolved &&
            actual.startsWith(
              '$temporaryRoot${Platform.pathSeparator}shiyu-material-qa-',
            ),
        'refuse cleanup outside the owned synthetic temporary directory',
      );
      await parent.delete(recursive: true);
    }
  }
}

class Cases {
  var passed = 0;
  var failed = 0;

  Future<void> run(String name, Future<void> Function() body) async {
    try {
      await body().timeout(const Duration(seconds: 20));
      passed++;
      stdout.writeln('PASS $name');
    } catch (error) {
      failed++;
      // Assertions contain synthetic facts; avoid raw FileSystemException paths.
      final detail = error is StateError
          ? error.message
          : error is MaterialStoreException
          ? 'MaterialStoreException(${error.code.name})'
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
