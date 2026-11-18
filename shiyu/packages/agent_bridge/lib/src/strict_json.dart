import 'dart:convert';
import 'dart:collection';
import 'dart:typed_data';

import 'contracts.dart';

Never _badJson() =>
    throw const AgentBridgeException(AgentBridgeErrorCode.invalidJson);

/// Byte/depth/node and duplicate-key validation precedes Dart jsonDecode.
/// Keys are decoded before comparison so escaped aliases cannot win silently.
Object? decodeAgentBridgeJson(List<int> bytes, {int maxBytes = 262144}) {
  if (bytes.length > maxBytes) {
    throw const AgentBridgeException(AgentBridgeErrorCode.tooLarge);
  }
  try {
    final text = utf8.decode(bytes, allowMalformed: false);
    _JsonScan(text).run();
    final value = jsonDecode(text);
    _scalars(value);
    return value;
  } on AgentBridgeException {
    rethrow;
  } catch (_) {
    _badJson();
  }
}

void _scalars(Object? value) {
  if (value is String) {
    for (var i = 0; i < value.length; i++) {
      final c = value.codeUnitAt(i);
      if (c >= 0xd800 && c <= 0xdbff) {
        if (++i >= value.length) _badJson();
        final low = value.codeUnitAt(i);
        if (low < 0xdc00 || low > 0xdfff) _badJson();
      } else if (c >= 0xdc00 && c <= 0xdfff) {
        _badJson();
      }
    }
  } else if (value is Map) {
    for (final entry in value.entries) {
      _scalars(entry.key);
      _scalars(entry.value);
    }
  } else if (value is List) {
    for (final item in value) {
      _scalars(item);
    }
  } else if (value is double && !value.isFinite) {
    _badJson();
  }
}

final class _JsonScan {
  _JsonScan(this.text);
  final String text;
  int at = 0, nodes = 0;
  static final _number = RegExp(
    r'-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?',
  );
  void ws() {
    while (at < text.length && {9, 10, 13, 32}.contains(text.codeUnitAt(at))) {
      at++;
    }
  }

  bool eat(String c) {
    ws();
    if (at < text.length && text[at] == c) {
      at++;
      return true;
    }
    return false;
  }

  void need(String c) {
    if (!eat(c)) _badJson();
  }

  String string({bool key = false}) {
    ws();
    final start = at;
    if (at >= text.length || text[at++] != '"') _badJson();
    while (at < text.length) {
      final c = text.codeUnitAt(at++);
      if (c == 34)
        return key ? jsonDecode(text.substring(start, at)) as String : '';
      if (c < 32) _badJson();
      if (c == 92) {
        if (at >= text.length) _badJson();
        final escape = text[at++];
        if (escape == 'u') {
          if (at + 4 > text.length ||
              !RegExp(r'^[0-9a-fA-F]{4}$').hasMatch(text.substring(at, at + 4)))
            _badJson();
          at += 4;
        } else if (!'"\\/bfnrt'.contains(escape)) {
          _badJson();
        }
      }
    }
    _badJson();
  }

  void value(int depth) {
    if (depth > 16 || ++nodes > 4096) {
      throw const AgentBridgeException(AgentBridgeErrorCode.tooLarge);
    }
    ws();
    if (at >= text.length) _badJson();
    if (eat('{')) {
      final keys = <String>{};
      if (eat('}')) return;
      do {
        final key = string(key: true);
        if (!keys.add(key)) _badJson();
        need(':');
        value(depth + 1);
      } while (eat(','));
      need('}');
      return;
    }
    if (eat('[')) {
      if (eat(']')) return;
      do {
        value(depth + 1);
      } while (eat(','));
      need(']');
      return;
    }
    if (text[at] == '"') {
      string();
      return;
    }
    for (final literal in ['true', 'false', 'null']) {
      if (text.startsWith(literal, at)) {
        at += literal.length;
        return;
      }
    }
    final number = _number.matchAsPrefix(text, at);
    if (number == null) _badJson();
    at = number.end;
  }

  void run() {
    value(0);
    ws();
    if (at != text.length) _badJson();
  }
}

/// Fully encode under a byte budget before writing to stdout or a socket.
/// Failed oversized output cannot leave a partial JSON-RPC message on stdout.
Uint8List encodeAgentBridgeJson(Object? value, {required int maxBytes}) {
  final ancestors = HashSet<Object>.identity();
  var nodes = 0, minimumBytes = 0;
  void validate(Object? item, int depth) {
    if (depth > 16 || ++nodes > 4096) {
      throw const AgentBridgeException(AgentBridgeErrorCode.tooLarge);
    }
    if (item is String) {
      // For valid Unicode, UTF-8/JSON output is at least this many UTF-16
      // units. Stop repeated/large local graphs before scanning unbounded text.
      minimumBytes += item.length;
      if (minimumBytes > maxBytes) {
        throw const AgentBridgeException(AgentBridgeErrorCode.tooLarge);
      }
      _scalars(item);
    } else if (item is Map || item is List) {
      if (!ancestors.add(item as Object)) _badJson();
      if (item is Map) {
        for (final entry in item.entries) {
          if (entry.key is! String) _badJson();
          validate(entry.key, depth + 1);
          validate(entry.value, depth + 1);
        }
      } else {
        for (final child in item as List) {
          validate(child, depth + 1);
        }
      }
      ancestors.remove(item);
    } else if (item is double && !item.isFinite) {
      _badJson();
    } else if (item != null && item is! num && item is! bool) {
      _badJson();
    }
  }

  validate(value, 0);
  final output = _JsonBytes(maxBytes);
  try {
    final encoder = JsonUtf8Encoder(
      null,
      null,
      1024,
    ).startChunkedConversion(output);
    encoder.add(value);
    encoder.close();
    return output.bytes.takeBytes();
  } on AgentBridgeException {
    rethrow;
  } catch (_) {
    _badJson();
  }
}

final class _JsonBytes implements Sink<List<int>> {
  _JsonBytes(this.maximum);
  final int maximum;
  final bytes = BytesBuilder(copy: false);
  @override
  void add(List<int> chunk) {
    if (bytes.length + chunk.length > maximum) {
      throw const AgentBridgeException(AgentBridgeErrorCode.tooLarge);
    }
    bytes.add(chunk);
  }

  @override
  void close() {}
}
