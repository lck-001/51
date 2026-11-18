import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_bridge/src/client.dart';
import 'package:agent_bridge/src/mcp_proxy.dart';

// Narrow implementation-side checks, not independent acceptance or a real
// assistant connection. Missing descriptor intentionally prevents any App call.
void check(bool condition, String detail) {
  if (!condition) throw StateError(detail);
}

Map<String, Object?> request(
  Object id,
  String method, [
  Map<String, Object?>? params,
]) => {
  'jsonrpc': '2.0',
  'id': id,
  'method': method,
  if (params != null) 'params': params,
};
Map<String, Object?> initialize(Object id, [String version = '2025-11-25']) =>
    request(id, 'initialize', {
      'protocolVersion': version,
      'capabilities': {},
      'clientInfo': {'name': 'controlled-protocol-test', 'version': '1'},
    });
const initialized = {'jsonrpc': '2.0', 'method': 'notifications/initialized'};
List<int> lines(List<Object> messages) =>
    utf8.encode('${messages.map(jsonEncode).join('\n')}\n');

Future<({int code, List<Map<String, dynamic>> replies, String raw})> runBytes(
  List<int> input, {
  String? descriptorPath,
}) async {
  final collected = <int>[];
  final controller = StreamController<List<int>>();
  final listener = controller.stream.listen(collected.addAll);
  final sink = IOSink(controller.sink);
  final descriptor =
      descriptorPath ??
      '${Directory.systemTemp.path}${Platform.pathSeparator}SHOULD_NOT_LEAK_PRIVATE_DESCRIPTOR';
  final proxy = AgentBridgeMcpProxy(
    client: AgentBridgeClient(descriptorPath: descriptor),
  );
  final code = await proxy.run(input: Stream.value(input), output: sink);
  await sink.close();
  await listener.cancel();
  final raw = utf8.decode(collected, allowMalformed: false);
  check(
    !raw.contains('SHOULD_NOT_LEAK_PRIVATE_DESCRIPTOR'),
    'private locator must not appear in stdout',
  );
  final replies = raw
      .split('\n')
      .where((s) => s.isNotEmpty)
      .map((s) => jsonDecode(s) as Map<String, dynamic>)
      .toList();
  check(
    replies.every((r) => r['jsonrpc'] == '2.0'),
    'stdout contains only RPC objects',
  );
  return (code: code, replies: replies, raw: raw);
}

Future<void> main() async {
  var passed = 0, failed = 0;
  Future<void> test(String name, Future<void> Function() action) async {
    try {
      await action().timeout(const Duration(seconds: 20));
      passed++;
      stdout.writeln('PASS $name');
    } catch (_) {
      failed++;
      stdout.writeln('FAIL $name');
    }
  }

  await test(
    'Discovery offline uses MCP lifecycle, optional meta and typed unique IDs',
    () async {
      final r = await runBytes(
        lines([
          request(8, 'tools/list'),
          request(9, 'ping'),
          initialize(1, '2025-06-18'),
          {
            'jsonrpc': '2.0',
            'method': 'notifications/initialized',
            'params': {
              '_meta': {'progressToken': 'not-a-permission'},
            },
          },
          request('1', 'ping'),
          request(1, 'ping'),
          request(2, 'tools/list', {'_meta': {}}),
          {
            'jsonrpc': '2.0',
            'method': 'notifications/cancelled',
            'params': {'requestId': 'unknown', 'reason': 'ignored data'},
          },
        ]),
      );
      check(
        r.code == 0 && r.replies.length == 6,
        'notifications have no replies',
      );
      check(
        (r.replies[0]['error'] as Map)['message'] == 'not_initialized',
        'tools gated before initialized',
      );
      check(r.replies[1]['result'] is Map, 'ping works before init');
      check(
        (r.replies[2]['result'] as Map)['protocolVersion'] == '2025-06-18',
        'supported version echoes',
      );
      check(
        r.replies[3]['id'] == '1' && r.replies[3].containsKey('result'),
        'string ID differs from integer',
      );
      check(
        (r.replies[4]['error'] as Map)['message'] == 'duplicate_request_id',
        'integer ID cannot repeat in session',
      );
      final tools = (r.replies.last['result'] as Map)['tools'] as List;
      check(tools.length == 3, 'exactly three narrow tools');
      final names = tools.map((x) => (x as Map)['name']).toSet();
      check(
        names.containsAll({
          'shiyu_get_source_reference',
          'shiyu_read_fixed_source',
          'shiyu_submit_learning_candidate',
        }),
        'no confirm, publish, arbitrary read or generation tool',
      );
      final properties =
          ((tools[1] as Map)['inputSchema'] as Map)['properties'] as Map;
      check(
        (properties['material_id'] as Map)['pattern'] == r'^[0-9a-f]{32}$',
        'schema exposes actual binding pattern',
      );
    },
  );

  await test('Unknown protocol offers latest supported version without reading descriptor', () async {
    final r = await runBytes(lines([initialize(1, 'future-version')]));
    check(
      (r.replies.single['result'] as Map)['protocolVersion'] == '2025-11-25',
      'version negotiated, not invented',
    );
  });

  await test('Duplicate keys invalid UTF8 and surrogate JSON are rejected without raw echo', () async {
    final input = <int>[
      ...utf8.encode('{"jsonrpc":"2.0","id":1,"id":2,"method":"ping"}\n'),
      0xc3,
      0x28,
      10,
      ...utf8.encode(
        r'{"jsonrpc":"2.0","id":3,"method":"ping","params":{"_meta":{"bad":"\ud800"}}}',
      ),
      10,
      ...lines([request(4, 'ping')]),
    ];
    final r = await runBytes(input);
    check(
      r.replies.length == 4 &&
          r.replies.take(3).every((r) => (r['error'] as Map)['code'] == -32700),
      'strict codec rejects rather than normalizes',
    );
    check(
      r.replies.last['id'] == 4 && r.replies.last.containsKey('result'),
      'valid later frame still works',
    );
  });

  await test(
    'Tool argument authority and media fail before a descriptor is opened',
    () async {
      final r = await runBytes(
        lines([
          initialize(1),
          initialized,
          request(2, 'tools/call', {
            'name': 'shiyu_get_source_reference',
            'arguments': {'url': 'http://127.0.0.1/never-follow'},
          }),
          request(3, 'tools/call', {
            'name': 'shiyu_submit_learning_candidate',
            'arguments': {'media': null},
          }),
          request(4, 'tools/call', {
            'name': 'shiyu_submit_learning_candidate',
            'arguments': {
              'schema_version': 1,
              'material_id': 'a' * 32,
              'material_version_id': 'b' * 32,
              'source_text_sha256': 'c' * 64,
              'delivery_id': 'fixture-delivery',
              'sentences': [
                {'english': 'A paper boat.', 'translation': '原创结构夹具。'},
              ],
              'declaration': {
                'preparation': 'self-declared unverified fixture',
              },
              'owner_id': 'forged-owner',
            },
          }),
          request(5, 'tools/call', {
            'name': 'confirm_candidate',
            'arguments': {},
          }),
        ]),
      );
      check(r.replies.length == 5, 'requests answered once');
      for (final index in [1, 3]) {
        final result = r.replies[index]['result'] as Map;
        check(
          result['isError'] == true &&
              (((result['structuredContent'] as Map)['error']
                      as Map)['code']) ==
                  'invalidRequest',
          'unknown authority fields are not forwarded',
        );
      }
      check(
        (((r.replies[2]['result'] as Map)['structuredContent'] as Map)['error']
                as Map)['code'] ==
            'unsupportedMedia',
        'even null media explicitly unsupported',
      );
      check(
        (r.replies.last['error'] as Map)['code'] == -32602,
        'unknown tool is protocol error',
      );
    },
  );

  await test('App unavailability returns only a fixed tool error without locator or stack', () async {
    final r = await runBytes(
      lines([
        initialize(1),
        initialized,
        request(2, 'tools/call', {
          'name': 'shiyu_get_source_reference',
          'arguments': {},
        }),
      ]),
    );
    final result = r.replies.last['result'] as Map;
    check(result['isError'] == true, 'offline tool is not fabricated success');
    final error = (result['structuredContent'] as Map)['error'] as Map;
    check(
      error.length == 1 &&
          error['code'] is String &&
          !r.raw.contains('FileSystemException') &&
          !r.raw.contains('StackTrace') &&
          !r.raw.contains('descriptorPath'),
      'safe error only',
    );
  });

  await test('Oversized and unterminated lines close the session without executing JSON fragments', () async {
    final large = await runBytes(List<int>.filled(262145, 32));
    check(
      large.code == 1 &&
          large.replies.length == 1 &&
          (large.replies.single['error'] as Map)['message'] == 'tooLarge',
      'raw bytes capped before unbounded String buffering',
    );
    final partial = await runBytes(utf8.encode(jsonEncode(request(1, 'ping'))));
    check(
      partial.code == 1 &&
          (partial.replies.single['error'] as Map)['message'] ==
              'incomplete_frame',
      'EOF is not an implicit commit delimiter',
    );
  });

  await test('Session request history is bounded instead of violating unique-ID semantics', () async {
    final r = await runBytes(
      lines(List<Object>.generate(4100, (i) => request(i, 'ping'))),
    );
    check(
      r.code == 1 &&
          r.replies.length == 4097 &&
          (r.replies.last['error'] as Map)['message'] == 'session_limit',
      'bounded ID history ends the session instead of forgetting used IDs',
    );
  });
  await test('Executable entry rejects path arguments and missing descriptor without stdout contamination', () async {
    final environment = <String, String>{'CI': 'true'};
    for (final key in [
      'SystemRoot',
      'WINDIR',
      'ComSpec',
      'TEMP',
      'TMP',
      'APPDATA',
      'LOCALAPPDATA',
      'PUB_CACHE',
    ]) {
      final value = Platform.environment[key];
      if (value != null) environment[key] = value;
    }
    for (final arguments in [
      <String>[],
      ['--descriptor=PRIVATE_STARTUP_SENTINEL'],
    ]) {
      final child = await Process.run(
        Platform.resolvedExecutable,
        [
          '--packages=.dart_tool/package_config.json',
          'bin/shiyu_agent_proxy.dart',
          ...arguments,
        ],
        workingDirectory: Directory.current.path,
        environment: environment,
        includeParentEnvironment: false,
      );
      check(
        child.exitCode == 2 &&
            child.stdout == '' &&
            (child.stderr as String).trim() ==
                'shiyu_proxy_startup_unavailable',
        'startup emits only stable stderr, never a locator or runtime stack',
      );
    }
  });
  stdout.writeln(
    'RESULT passed=$passed failed=$failed total=${passed + failed}',
  );
  if (failed > 0) exitCode = 1;
}
