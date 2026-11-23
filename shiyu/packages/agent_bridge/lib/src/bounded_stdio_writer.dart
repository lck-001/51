import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

/// Neutral output failure. Native errors and response bodies never escape.
final class StdioOutputFault implements Exception {
  const StdioOutputFault();
}

final class _Write {
  _Write(this.bytes);
  final Uint8List bytes;
  final done = Completer<void>();
}

/// Three producers only: one ordinary action, one abort, one reader response.
/// A failed/expired native flush is observed, never awaited a second time.
final class BoundedStdioWriter {
  BoundedStdioWriter(IOSink output, {required this.onFailure})
    : _output = output is Stdout ? output.nonBlocking : output {
    if (output is Stdout) _output.done.ignore();
  }
  // Custom IOSinks must be nonblocking too; Dart cannot time out a synchronous
  // native write which prevents its isolate's timers from running.
  final IOSink _output;
  final void Function() onFailure;
  final _queue = Queue<_Write>();
  bool _running = false, _failed = false;
  int peakPending = 0;
  bool get failed => _failed;
  int get pending => _queue.length;
  Future<void> sendLine(Uint8List bytes) {
    if (_failed) return Future.error(const StdioOutputFault());
    if (bytes.length > 512 * 1024 || _queue.length >= 3) {
      _break();
      return Future.error(const StdioOutputFault());
    }
    final item = _Write(bytes);
    item.done.future.ignore();
    _queue.add(item);
    if (_queue.length > peakPending) peakPending = _queue.length;
    if (!_running) {
      _running = true;
      _pump().ignore();
    }
    return item.done.future;
  }

  void _break() {
    if (_failed) return;
    _failed = true;
    while (_queue.isNotEmpty) {
      final item = _queue.removeFirst();
      if (!item.done.isCompleted)
        item.done.completeError(const StdioOutputFault());
    }
    try {
      onFailure();
    } catch (_) {}
  }

  Future<void> _pump() async {
    try {
      while (!_failed && _queue.isNotEmpty) {
        final item = _queue.first;
        try {
          _output.add(item.bytes);
          _output.add(const [10]);
          final flush = Future<void>.sync(_output.flush);
          flush.ignore();
          await flush.timeout(const Duration(seconds: 15));
        } catch (_) {
          _break();
          return;
        }
        if (_failed) return;
        _queue.removeFirst();
        item.done.complete();
      }
    } finally {
      _running = false;
    }
  }
}
