import 'dart:async';
import 'dart:io';

void expectThat(bool condition, String message) {
  if (!condition) throw StateError(message);
}

/// Drain explicitly bounded event-loop turns; no native services or real media.
Future<void> settle([int turns = 8]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class Cases {
  var passed = 0;
  var failed = 0;

  Future<void> run(String name, Future<void> Function() body) async {
    try {
      await body().timeout(const Duration(seconds: 4));
      passed++;
      stdout.writeln('PASS $name');
    } catch (error) {
      failed++;
      stdout.writeln('FAIL $name: $error');
    }
  }

  void finish() {
    stdout.writeln(
      'RESULT passed=$passed failed=$failed total=${passed + failed}',
    );
    if (failed != 0) exitCode = 1;
  }
}
