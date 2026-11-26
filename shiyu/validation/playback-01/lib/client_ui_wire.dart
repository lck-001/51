import 'dart:convert';

import 'package:crypto/crypto.dart';

const uiWireMaxInt = 9007199254740991;
const uiPhasePrefix = 'SHIYU_UI_PHASE ';
const uiContext0Keys = {
  'protocol',
  'role',
  'runId',
  'attempt',
  'desktopNonce',
  'rootScope',
  'appPid',
  'creationFileTime',
  'imageSha256',
  'bundleSha256',
};
const uiContextKeys = {...uiContext0Keys, 'ownerScope', 'mainIsolateId'};

Never uiReject(String code) => throw FormatException('ui_validation_$code');
void uiNeed(bool value, String code) {
  if (!value) uiReject(code);
}

bool uiHash(Object? v) => v is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(v);
bool uiIdentity(Object? v) =>
    v is String && RegExp(r'^[0-9a-f]{16}:[0-9a-f]{16}$').hasMatch(v);
bool uiDecimal(Object? v) =>
    v is String && RegExp(r'^[1-9][0-9]*$').hasMatch(v);
bool uiInt(Object? v, {bool positive = false}) =>
    v is int && v >= (positive ? 1 : 0) && v <= uiWireMaxInt;
Map<String, Object?> uiObject(Object? value, Set<String> fields) {
  uiNeed(value is Map && value.keys.every((k) => k is String), 'object');
  final map = Map<String, Object?>.from(value as Map);
  uiNeed(
    map.length == fields.length && fields.every(map.containsKey),
    'fields',
  );
  return map;
}

String _uiString(String value) {
  final out = StringBuffer('"'), units = value.codeUnits;
  const escapes = {
    8: r'\b',
    9: r'\t',
    10: r'\n',
    12: r'\f',
    13: r'\r',
    34: r'\"',
    92: r'\\',
  };
  for (var i = 0; i < units.length; i++) {
    final c = units[i];
    if (c >= 0xd800 && c <= 0xdbff) {
      uiNeed(
        i + 1 < units.length &&
            units[i + 1] >= 0xdc00 &&
            units[i + 1] <= 0xdfff,
        'surrogate',
      );
    }
    if (c >= 0xdc00 && c <= 0xdfff) {
      uiNeed(
        i > 0 && units[i - 1] >= 0xd800 && units[i - 1] <= 0xdbff,
        'surrogate',
      );
    }
    if (escapes.containsKey(c)) {
      out.write(escapes[c]);
    } else if (c < 32 || c > 126) {
      out.write('\\u${c.toRadixString(16).padLeft(4, '0')}');
    } else {
      out.writeCharCode(c);
    }
  }
  return (out..write('"')).toString();
}

String uiCanonical(Object? value) {
  if (value == null) return 'null';
  if (value is bool) return value ? 'true' : 'false';
  if (value is int) {
    uiNeed(uiInt(value), 'integer');
    return value.toString();
  }
  if (value is String) return _uiString(value);
  if (value is List) return '[${value.map(uiCanonical).join(',')}]';
  if (value is Map) {
    uiNeed(
      value.keys.every(
        (k) => k is String && k.codeUnits.every((c) => c >= 32 && c <= 126),
      ),
      'keys',
    );
    final keys = value.keys.cast<String>().toList()..sort();
    return '{${keys.map((k) => '${_uiString(k)}:${uiCanonical(value[k])}').join(',')}}';
  }
  return uiReject('type');
}

List<int> uiBytes(Object? value, {bool lf = false}) =>
    ascii.encode('${uiCanonical(value)}${lf ? '\n' : ''}');
String uiSha(List<int> bytes) => sha256.convert(bytes).toString();
Object? uiDecode(List<int> bytes, {required int limit, bool lf = false}) {
  uiNeed(
    bytes.isNotEmpty &&
        bytes.length <= limit &&
        bytes.every((b) => b >= 0 && b <= 127),
    'bytes',
  );
  final raw = ascii.decode(bytes);
  uiNeed(!lf || raw.endsWith('\n'), 'lf');
  final body = lf ? raw.substring(0, raw.length - 1) : raw;
  final value = jsonDecode(body);
  uiNeed(uiCanonical(value) == body, 'canonical');
  return value;
}

List<int> uiBase64(Object? value, int limit) {
  uiNeed(value is String && value.length <= ((limit + 2) ~/ 3) * 4, 'base64');
  final data = base64.decode(value as String);
  uiNeed(data.length <= limit && base64.encode(data) == value, 'base64');
  return data;
}

void uiCheckContext0(Map<String, Object?> c) {
  uiObject(c, uiContext0Keys);
  uiNeed(
    c['protocol'] == 1 &&
        c['protocol'] is int &&
        c['role'] == 'ordinary-empty-ui',
    'context-role',
  );
  uiNeed(
    c['runId'] is String &&
        RegExp(r'^ui-[0-9a-f]{8}$').hasMatch(c['runId'] as String),
    'run',
  );
  uiNeed(
    c['attempt'] is String &&
        RegExp(r'^[0-9a-f]{32}$').hasMatch(c['attempt'] as String),
    'attempt',
  );
  uiNeed(
    c['desktopNonce'] is String &&
        RegExp(r'^ShiyuIso_[0-9a-f]{32}$')
            .hasMatch(c['desktopNonce'] as String),
    'desktop',
  );
  uiNeed(
    uiHash(c['rootScope']) &&
        uiHash(c['imageSha256']) &&
        uiHash(c['bundleSha256']) &&
        uiInt(c['appPid'], positive: true) &&
        uiDecimal(c['creationFileTime']),
    'context',
  );
}
