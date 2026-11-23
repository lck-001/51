// C-stdio author checks: real process stdin -> proof socket -> real FileStores.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_bridge/agent_bridge.dart';
import 'package:agent_bridge/src/mcp_proxy.dart';
import 'package:agent_bridge/src/bounded_stdio_writer.dart';
import 'package:crypto/crypto.dart' show sha256;

import 'media_socket_local.dart' as b;
import 'media_wire_local.dart' as w;
import 'mcp_proxy_local.dart' as rpc;

void check(bool value, String label) => b.check(value, label);
final package = Directory.fromUri(Platform.script.resolve('../'));
String get taskVm {
  final executable = File(Platform.resolvedExecutable);
  final vm = File(
    '${executable.parent.path}${Platform.pathSeparator}dartvm.exe',
  );
  return Platform.isWindows && vm.existsSync() ? vm.path : executable.path;
}

String get config =>
    File('${package.path}/.dart_tool/package_config.json').absolute.path;
Map<String, String> childEnvironment(String descriptor) {
  final env = <String, String>{
    'CI': 'true',
    'SHIYU_BRIDGE_DESCRIPTOR': descriptor,
  };
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
    if (value != null) env[key] = value;
  }
  return env;
}

final class RpcChild {
  late Process process;
  late StreamSubscription<List<int>> subscription;
  final pending = <Object, Completer<Map<String, dynamic>>>{};
  final seen = <Map<String, dynamic>>[];
  final bytes = BytesBuilder(copy: false), stderrBytes = <int>[];
  int nextId = 1, parseErrors = 0;
  final outputDone = Completer<void>();
  bool paused = false;
  Future<void> start(String descriptor) async {
    process = await Process.start(
      taskVm,
      [
        '-Dshiyu_test_marker=stdio-author-${DateTime.now().microsecondsSinceEpoch}',
        '--packages=$config',
        'bin/shiyu_agent_proxy.dart',
      ],
      workingDirectory: package.path,
      environment: childEnvironment(descriptor),
      includeParentEnvironment: false,
    );
    stdout.writeln('TASK_PROXY_PID ${process.pid}');
    process.stderr.listen((data) {
      check(stderrBytes.length + data.length <= 65536, 'stderr bounded');
      stderrBytes.addAll(data);
    });
    subscription = process.stdout.listen(
      (data) {
        for (final c in data) {
          if (c == 10) {
            final line = bytes.takeBytes();
            try {
              final reply =
                  jsonDecode(utf8.decode(line)) as Map<String, dynamic>;
              seen.add(reply);
              final task = pending.remove(reply['id']);
              if (task != null && !task.isCompleted) task.complete(reply);
            } catch (_) {
              parseErrors++;
            }
          } else {
            check(bytes.length < 524288, 'response line bounded');
            bytes.addByte(c);
          }
        }
      },
      onDone: () {
        if (!outputDone.isCompleted) outputDone.complete();
        for (final task in pending.values) {
          if (!task.isCompleted)
            task.completeError(StateError('owned child EOF'));
        }
        pending.clear();
      },
    );
    await call('initialize', {
      'protocolVersion': '2025-11-25',
      'capabilities': {},
      'clientInfo': {'name': 'synthetic-stdio-code', 'version': '1'},
    });
    notify('notifications/initialized');
  }

  Future<Map<String, dynamic>> call(String method, Map<String, Object?> args) {
    final id = nextId++, done = Completer<Map<String, dynamic>>();
    done.future.ignore();
    pending[id] = done;
    process.stdin.writeln(jsonEncode(rpc.request(id, method, args)));
    return done.future;
  }

  Future<Map<String, Object?>> tool(
    String name,
    Map<String, Object?> body,
  ) async {
    final reply = await call('tools/call', {'name': name, 'arguments': body});
    check(reply['result'] is Map, 'actual MCP tool envelope');
    return Map<String, Object?>.from(reply['result'] as Map);
  }

  void notify(String name) =>
      process.stdin.writeln(jsonEncode({'jsonrpc': '2.0', 'method': name}));
  void raw(List<int> bytes) => process.stdin.add(bytes);
  void closeInput() {
    process.stdin.close().ignore();
  }

  Future<int> finish() async {
    closeInput();
    final code = await process.exitCode.timeout(const Duration(seconds: 25));
    if (paused) {
      subscription.resume();
      paused = false;
    }
    await outputDone.future.timeout(const Duration(seconds: 3));
    return code;
  }

  void pauseOutput() {
    subscription.pause();
    paused = true;
  }

  void resumeOutput() {
    if (paused) {
      subscription.resume();
      paused = false;
    }
  }
}

Map<String, Object?> content(Map<String, Object?> result) =>
    Map<String, Object?>.from(result['structuredContent'] as Map);
Future<({String id, String receipt, Map<String, Object?> body})> upload(
  RpcChild peer,
  b.Host host,
) async {
  final body = w.packet(host.data.binding),
      start = await peer.tool('shiyu_begin_media', w.beginPacket(body));
  check(start['isError'] == false, 'actual stdio begin accepted');
  final id = content(start)['upload_id'] as String;
  for (var offset = 0, index = 0; offset < host.data.bytes.length; index++) {
    final end = offset + 65536 < host.data.bytes.length
        ? offset + 65536
        : host.data.bytes.length;
    final bytes = Uint8List.fromList(host.data.bytes.sublist(offset, end));
    final sha = sha256.convert(bytes).toString();
    final ack = await peer.tool('shiyu_put_media_chunk', {
      ...host.control(id),
      'index': index,
      'bytes_base64': base64.encode(bytes),
      'chunk_sha256': sha,
    });
    check(ack['isError'] == false, 'actual stdio code chunk');
    offset = end;
  }
  final seal = await peer.tool('shiyu_seal_media', host.control(id));
  check(seal['isError'] == false, 'actual stdio seal');
  final receipt = content(seal)['sealed_receipt'] as String;
  body['sealed_receipt'] = receipt;
  return (id: id, receipt: receipt, body: body);
}

Future<void> realProcessCases() async {
  for (final abort in [false, true]) {
    final invoked = Completer<void>(), host = b.Host();
    await host.open(
      onAbort: () {
        if (!invoked.isCompleted) invoked.complete();
      },
    );
    final peer = RpcChild();
    await peer.start(host.descriptorPath);
    try {
      final list = await peer.call('tools/list', {}),
          tools = (list['result'] as Map)['tools'] as List;
      check(tools.length == 8, 'exact eight tools discovered');
      final u = await upload(peer, host);
      if (!abort) {
        final result = await peer.tool('shiyu_submit_media_candidate', u.body);
        check(
          result['isError'] == false &&
              content(result)['status'] == 'delivered',
          'all actual stdio media stages',
        );
        final v1 = await peer.tool('shiyu_submit_learning_candidate', {
          'media': null,
        });
        check(
          v1['isError'] == true &&
              (content(v1)['error'] as Map)['code'] == 'unsupportedMedia',
          'v1 media:null still protected',
        );
        check(
          (await peer.call('ping', {})).containsKey('result'),
          'valid tool error does not close session',
        );
        check(
          (await host.data.learning.listCandidates()).length == 1,
          'real candidate present',
        );
      } else {
        host.pauseMaterial();
        final submitted = peer.tool('shiyu_submit_media_candidate', u.body);
        await host.data.probe.registrationEntered!.future;
        var submitReplied = false;
        submitted.then((_) => submitReplied = true).ignore();
        final aborted = peer.tool('shiyu_abort_media', host.control(u.id));
        await invoked.future;
        check(
          !submitReplied,
          'same stdin abort dispatched before submit reply',
        );
        host.releaseMaterial();
        final s = await submitted, a = await aborted;
        check(
          s['isError'] == true &&
              (content(s)['error'] as Map)['code'] == 'outcomeUnknown' &&
              a['isError'] == false &&
              content(a)['status'] == 'terminal',
          'same stdin stop then true drain',
        );
        check(
          (await host.data.learning.listCandidates()).isEmpty,
          'same stdin abort stopped Learning after registered Material',
        );
      }
      check(await peer.finish() == 0, 'real proxy clean EOF exit0');
      check(
        peer.stderrBytes.isEmpty && peer.parseErrors == 0,
        'stdout only complete JSON and no raw stderr',
      );
      print(
        'PASS real child stdin all media tools / pending Store abort barrier abort=$abort',
      );
    } finally {
      host.releaseMaterial();
      await host.close();
    }
  }
  final host = b.Host();
  await host.open(media: false);
  final peer = RpcChild();
  await peer.start(host.descriptorPath);
  try {
    final tools = await peer.call('tools/list', {});
    check(
      ((tools['result'] as Map)['tools'] as List).length == 8,
      'discovery available without media scope',
    );
    final denied = await peer.tool(
      'shiyu_begin_media',
      w.beginPacket(w.packet(host.data.binding)),
    );
    check(
      denied['isError'] == true &&
          (content(denied)['error'] as Map)['code'] == 'forbidden' &&
          host.data.probe.registrations == 0,
      'discovery did not grant media',
    );
    check(await peer.finish() == 0, 'scope denial session still usable');
    print(
      'PASS actual child eight-tool discovery does not grant default media scope',
    );
  } finally {
    await host.close();
  }
}

final class TrapSink implements IOSink {
  final lines = <Map<String, dynamic>>[];
  final building = BytesBuilder(copy: false),
      blocked = Completer<void>(),
      never = Completer<void>();
  bool arm = false, broken = false;
  int closeCalls = 0, doneReads = 0, adds = 0;
  void Function(Map<String, dynamic>)? onLine;
  @override
  void add(List<int> data) {
    adds++;
    for (final c in data) {
      if (c == 10) {
        final line = jsonDecode(
          utf8.decode(building.takeBytes()),
        ) as Map<String, dynamic>;
        lines.add(line);
        onLine?.call(line);
      } else {
        building.addByte(c);
      }
    }
  }

  @override
  Future<void> flush() {
    if (broken) throw FileSystemException('owned synthetic broken stdout');
    if (arm) {
      if (!blocked.isCompleted) blocked.complete();
      return never.future;
    }
    return Future.value();
  }

  @override
  Future<void> close() {
    closeCalls++;
    return never.future;
  }

  @override
  Future<void> get done {
    doneReads++;
    return never.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unused output method');
}

final class MemoryRpc {
  MemoryRpc(this.descriptor);
  final String descriptor;
  final sink = TrapSink(), input = StreamController<List<int>>();
  final pending = <Object, Completer<Map<String, dynamic>>>{};
  final cancelled = Completer<void>();
  late Future<int> running;
  int nextId = 1;
  bool finished = false;
  Future<void> start() async {
    sink.onLine = (line) {
      final done = pending.remove(line['id']);
      if (done != null && !done.isCompleted) done.complete(line);
    };
    input.onCancel = () {
      if (!cancelled.isCompleted) cancelled.complete();
    };
    running =
        AgentBridgeMcpProxy(
          client: AgentBridgeClient(descriptorPath: descriptor),
        ).run(input: input.stream, output: sink).then((value) {
          finished = true;
          return value;
        });
    await call('initialize', {
      'protocolVersion': '2025-11-25',
      'capabilities': {},
      'clientInfo': {'name': 'controlled-code', 'version': '1'},
    });
    input.add(rpc.lines([rpc.initialized]));
  }

  Future<Map<String, dynamic>> call(
    String method,
    Map<String, Object?> params,
  ) {
    final id = nextId++, done = Completer<Map<String, dynamic>>();
    done.future.ignore();
    pending[id] = done;
    input.add(rpc.lines([rpc.request(id, method, params)]));
    return done.future;
  }

  Future<Map<String, dynamic>> tool(String name, Map<String, Object?> body) =>
      call('tools/call', {'name': name, 'arguments': body});
  void eof() {
    input.close().ignore();
  }

  void dispose() {
    input.close().ignore();
    for (final p in pending.values) {
      if (!p.isCompleted)
        p.completeError(StateError('logical output unavailable'));
    }
    pending.clear();
  }
}

Future<void> exitDrainCases() async {
  for (final mode in [
    'eof',
    'duplicate',
    'utf8',
    'surrogate',
    'stdoutBroken',
  ]) {
    final host = b.Host();
    await host.open();
    final m = MemoryRpc(host.descriptorPath);
    await m.start();
    try {
      final u = await host.upload();
      host.pauseMaterial();
      final submitted = m.tool('shiyu_submit_media_candidate', u.body);
      await host.data.probe.registrationEntered!.future;
      if (mode == 'eof') {
        m.eof();
        await m.cancelled.future;
      } else if (mode == 'stdoutBroken') {
        m.sink.broken = true;
        m.call('ping', {}).ignore();
        await m.cancelled.future;
      } else {
        final parseSeen = Completer<void>(), old = m.sink.onLine;
        m.sink.onLine = (line) {
          old?.call(line);
          if (line['error'] is Map &&
              (line['error'] as Map)['code'] == -32700 &&
              !parseSeen.isCompleted)
            parseSeen.complete();
        };
        m.input.add(switch (mode) {
          'duplicate' => utf8.encode('{"jsonrpc":"2.0","id":7,"id":8}\n'),
          'utf8' => <int>[0xc3, 0x28, 10],
          _ => utf8.encode(
            r'{"jsonrpc":"2.0","id":7,"method":"ping","params":{"bad":"\ud800"}}'
            '\n',
          ),
        });
        m.input.add(rpc.lines([rpc.request(999, 'ping')]));
        await parseSeen.future;
      }
      await b.eventTurn();
      check(
        !m.finished,
        '$mode did not close Client before accepted Future settled',
      );
      host.releaseMaterial();
      if (mode != 'stdoutBroken') {
        final response = await submitted;
        check(
          (response['result'] as Map)['isError'] == false,
          '$mode accepted submit may complete',
        );
      } else {
        submitted.ignore();
      }
      check(
        await m.running == (mode == 'eof' ? 0 : 1),
        '$mode exit policy exact',
      );
      check(
        (await host.data.learning.listCandidates()).length == 1 &&
            !m.sink.lines.any((r) => r['id'] == 999),
        '$mode no later admission, real candidate retained',
      );
      check(
        m.sink.closeCalls == 0 && m.sink.doneReads == 0,
        'borrowed sink not closed/awaited',
      );
      print(
        'PASS $mode stops new admission and drains already accepted real Client Future',
      );
    } finally {
      m.dispose();
      host.releaseMaterial();
      await host.close();
    }
  }
}

Future<void> watchdogAndBoundCases() async {
  final timers = <b.CapturedTimer>[];
  await runZoned(
    () async {
      final host = b.Host();
      await host.open();
      final m = MemoryRpc(host.descriptorPath);
      await m.start();
      try {
        final u = await host.upload();
        host.pauseMaterial();
        m.tool('shiyu_submit_media_candidate', u.body).ignore();
        await host.data.probe.registrationEntered!.future;
        m.sink.arm = true;
        m.call('ping', {}).ignore();
        await m.sink.blocked.future;
        final active = timers.where((t) => t.isActive).toList();
        check(active.length == 1, 'one actual writer watchdog active');
        active.single.fire();
        await m.cancelled.future;
        await b.eventTurn();
        check(
          !m.finished,
          'writer watchdog still waits accepted actual Client Future',
        );
        host.releaseMaterial();
        check(await m.running == 1, 'logical watchdog terminal exit');
        check(
          !m.sink.never.isCompleted &&
              m.sink.closeCalls == 0 &&
              m.sink.doneReads == 0,
          'never await original flush or borrowed sink close/done',
        );
        check(
          (await host.data.learning.listCandidates()).length == 1,
          'writer failure not a Store cancellation',
        );
        print(
          'PASS 15s writer logical watchdog drains real Client / no re-await stuck flush-close-done',
        );
      } finally {
        m.dispose();
        host.releaseMaterial();
        await host.close();
      }
    },
    zoneSpecification: ZoneSpecification(
      createTimer: (self, parent, zone, duration, callback) {
        if (duration == const Duration(seconds: 15)) {
          final timer = b.CapturedTimer(callback);
          timers.add(timer);
          return timer;
        }
        return parent.createTimer(zone, duration, callback);
      },
    ),
  );
  final sink = TrapSink()..arm = true;
  var failed = false;
  final writer = BoundedStdioWriter(sink, onFailure: () => failed = true);
  final tasks = [
    for (var i = 0; i < 3; i++)
      writer.sendLine(Uint8List.fromList(utf8.encode(jsonEncode({'id': i})))),
  ];
  for (final task in tasks) {
    task.ignore();
  }
  check(
    writer.pending == 3 && writer.peakPending == 3,
    'writer includes active in fixed capacity3',
  );
  final fourth = writer.sendLine(Uint8List.fromList(utf8.encode('{}')));
  fourth.ignore();
  await Future.wait(
    [
      ...tasks,
      fourth,
    ].map((task) => task.then((_) => false, onError: (Object _) => true)),
  );
  check(
    failed && writer.failed && writer.pending == 0 && sink.adds == 2,
    'bounded overflow fails all logical completions without more output',
  );
  print(
    'PASS unified writer capacity3 includes active / fourth fails closed / no infinite response queue',
  );
}

Future<void> actualPipeBackpressureCase() async {
  final invoked = Completer<void>(), host = b.Host();
  await host.open(
    onAbort: () {
      if (!invoked.isCompleted) invoked.complete();
    },
  );
  Process? child;
  var exited = false;
  final stderrBytes = <int>[];
  try {
    // Use a raw owned process and NEVER subscribe to stdout until after exit.
    // StreamSubscription.pause can buffer upstream data and is not OS pressure.
    final u = await host.upload();
    host.pauseMaterial();
    child = await Process.start(
      taskVm,
      [
        '-Dshiyu_test_marker=stdio-backpressure-${DateTime.now().microsecondsSinceEpoch}',
        '--packages=$config',
        'bin/shiyu_agent_proxy.dart',
      ],
      workingDirectory: package.path,
      environment: childEnvironment(host.descriptorPath),
      includeParentEnvironment: false,
    );
    stdout.writeln('TASK_PROXY_PID ${child.pid}');
    child.stderr.listen(stderrBytes.addAll);
    void send(Object message) => child!.stdin.writeln(jsonEncode(message));
    send(rpc.initialize(1));
    send(rpc.initialized);
    send(
      rpc.request(2, 'tools/call', {
        'name': 'shiyu_submit_media_candidate',
        'arguments': u.body,
      }),
    );
    await host.data.probe.registrationEntered!.future;
    send(
      rpc.request(3, 'tools/call', {
        'name': 'shiyu_abort_media',
        'arguments': host.control(u.id),
      }),
    );
    await invoked.future;
    for (var i = 4; i < 204; i++) {
      send(rpc.request(i, 'tools/list', {}));
    }
    child.stdin.flush().ignore();
    final code = await child.exitCode.timeout(const Duration(seconds: 25));
    exited = true;
    check(
      code == 1 && !host.data.probe.registrationRelease!.isCompleted,
      'real unread OS stdout watchdog exited while remote Store remained pending',
    );
    final output = await child.stdout.fold<List<int>>(<int>[], (bytes, piece) {
      check(
        bytes.length + piece.length <= 1024 * 1024,
        'owned pipe capture bounded',
      );
      bytes.addAll(piece);
      return bytes;
    });
    final text = utf8.decode(output, allowMalformed: true);
    check(
      !text.contains(host.descriptor.capability) &&
          !text.contains(host.descriptor.proofKey) &&
          !text.contains(host.descriptorPath),
      'no credential/private path in output',
    );
    check(
      host.controller.current.inFlight > 0,
      'proxy exit never claims remote Store is settled',
    );
    final drained = host.controller.snapshots.firstWhere(
      (s) => s.inFlight == 0,
    );
    host.releaseMaterial();
    await drained;
    check(
      (await host.data.learning.listCandidates()).isEmpty,
      'previous accepted abort retained',
    );
    check(stderrBytes.isEmpty, 'broken output has no stderr/body fallback');
    print(
      'PASS real child unread OS stdout metadata flood / finite watchdog exit / B true drain retained',
    );
  } finally {
    // Only this test-owned Process object may be terminated on a bounded failure.
    if (child != null) {
      if (!exited) child.kill();
      Future<void>.sync(child.stdin.close).ignore();
      try {
        await child.exitCode.timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
    host.releaseMaterial();
    await host.close();
  }
}

Future<void> main() async {
  await realProcessCases();
  await exitDrainCases();
  await watchdogAndBoundCases();
  await actualPipeBackpressureCase();
  await cancelledNotificationAndBusyCase();
  await frameLimitCase();
}

Future<void> cancelledNotificationAndBusyCase() async {
  final host = b.Host();
  await host.open();
  final peer = RpcChild();
  await peer.start(host.descriptorPath);
  try {
    final u = await upload(peer, host);
    host.pauseMaterial();
    final id = peer.nextId;
    final submitted = peer.tool('shiyu_submit_media_candidate', u.body);
    await host.data.probe.registrationEntered!.future;
    peer.raw(
      utf8.encode(
        '${jsonEncode({
          'jsonrpc': '2.0',
          'method': 'notifications/cancelled',
          'params': {'requestId': id, 'reason': 'synthetic fixture'},
        })}\n',
      ),
    );
    final busy = await peer.tool('shiyu_get_source_reference', {});
    check(
      busy['isError'] == true &&
          (content(busy)['error'] as Map)['code'] == 'busy',
      'ordinary refusal shares reader writer lane',
    );
    check(
      (await peer.call('ping', {})).containsKey('result') &&
          host.abortInvocations == 0,
      'metadata follows cancellation notification with no abort',
    );
    host.releaseMaterial();
    check(
      (await submitted)['isError'] == false &&
          (await host.data.learning.listCandidates()).length == 1,
      'notification never claims private delivery reversal',
    );
    check(await peer.finish() == 0, 'cancel notification nonfatal');
    print(
      'PASS actual stdin cancelled notification is no-op / bounded ordinary busy / metadata works',
    );
  } finally {
    host.releaseMaterial();
    await host.close();
  }
}

Future<void> frameLimitCase() async {
  final messages = List<Object>.generate(
    8193,
    (index) => {
      'jsonrpc': '2.0',
      'method': 'notifications/cancelled',
      'params': {'requestId': index},
    },
  );
  final result = await rpc.runBytes(rpc.lines(messages));
  check(
    result.code == 1 &&
        result.replies.length == 1 &&
        (result.replies.single['error'] as Map)['message'] == 'session_limit',
    '8192-frame boundary closes notification flood without actions',
  );
  print(
    'PASS exact 8192 frame ledger / notification flood bounded / fixed session-limit output',
  );
}
