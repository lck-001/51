import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'contracts.dart';
import 'strict_json.dart';

/// Private, fixed two-phase binary framing; deliberately NOT HTTP or an MCP
/// network transport. HTTP/WebSocket handshakes cannot match this NUL magic.
final class BridgeFrameChannel {
  BridgeFrameChannel(this.socket, {required int initialMaximum})
    : _budget = initialMaximum + 12 {
    _subscription = socket.listen(
      _data,
      onError: (Object _) => destroy(),
      onDone: destroy,
    );
  }
  static const _magic = [0x53, 0x59, 0x42, 0x31, 0, 13, 10, 0];
  final Socket socket;
  final _pieces = Queue<Uint8List>();
  late final StreamSubscription<Uint8List> _subscription;
  Completer<void>? _wake;
  int _offset = 0, _available = 0, _received = 0, _budget;
  bool _closed = false;
  bool get hasBufferedData => _available != 0;

  void _data(Uint8List bytes) {
    if (_closed) return;
    if (_received + bytes.length > _budget) {
      destroy();
      return;
    }
    _received += bytes.length;
    _available += bytes.length;
    _pieces.add(bytes);
    final wake = _wake;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  void expectMaximum(int maximum) {
    if (hasBufferedData || _closed) {
      throw const AgentBridgeException(AgentBridgeErrorCode.invalidRequest);
    }
    _received = 0;
    _budget = maximum + 12;
  }

  Future<Uint8List> _exact(int count) async {
    final result = Uint8List(count);
    var copied = 0;
    while (copied < count) {
      while (_pieces.isEmpty) {
        if (_closed)
          throw const AgentBridgeException(AgentBridgeErrorCode.unavailable);
        _wake = Completer<void>();
        await _wake!.future;
        _wake = null;
      }
      final piece = _pieces.first;
      final remaining = count - copied;
      final take = remaining < piece.length - _offset
          ? remaining
          : piece.length - _offset;
      result.setRange(copied, copied + take, piece, _offset);
      copied += take;
      _offset += take;
      _available -= take;
      if (_offset == piece.length) {
        _pieces.removeFirst();
        _offset = 0;
      }
    }
    return result;
  }

  Future<Object?> read({required int maximum}) async {
    final header = await _exact(12);
    for (var i = 0; i < _magic.length; i++) {
      if (header[i] != _magic[i])
        throw const AgentBridgeException(AgentBridgeErrorCode.invalidRequest);
    }
    final length = ByteData.sublistView(header).getUint32(8, Endian.big);
    if (length > maximum)
      throw const AgentBridgeException(AgentBridgeErrorCode.tooLarge);
    final body = await _exact(length);
    // At most one frame per phase. Never execute a queued third/pipelined call.
    if (hasBufferedData)
      throw const AgentBridgeException(AgentBridgeErrorCode.invalidRequest);
    return decodeAgentBridgeJson(body, maxBytes: maximum);
  }

  Future<void> send(Object? value, {required int maximum}) async {
    if (_closed)
      throw const AgentBridgeException(AgentBridgeErrorCode.unavailable);
    final body = encodeAgentBridgeJson(value, maxBytes: maximum);
    final header = Uint8List(12)..setRange(0, 8, _magic);
    ByteData.sublistView(header).setUint32(8, body.length, Endian.big);
    socket.add(header);
    socket.add(body);
    await socket.flush();
  }

  void destroy() {
    if (_closed) return;
    _closed = true;
    socket.destroy();
    _pieces.clear();
    _available = 0;
    final wake = _wake;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  Future<void> close() async {
    destroy();
    await _subscription.cancel();
  }
}
