import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_bridge/agent_bridge.dart';
import 'package:learning_core/learning_core.dart';

import 'media_socket_local.dart' as b;
import 'media_ingest_local.dart' as f;
import 'mcp_proxy_local.dart' as rpc;
import 'media_wire_local.dart' as w;

void check(bool value, String name) => f.expect(value, name);
final package = Directory.fromUri(Platform.script.resolve('../'));
String get vm {
  final sdk = File(Platform.resolvedExecutable).parent;
  final path = File('${sdk.path}${Platform.pathSeparator}dartvm.exe');
  return path.existsSync() ? path.path : Platform.resolvedExecutable;
}

final class CountingSink implements IOSink {
  CountingSink(this.real);
  final IOSink real;
  final buffer = BytesBuilder(copy: false);
  final operations = <String>[];
  final abortUploadIds = <String>[];
  int closeCalls = 0, doneReads = 0;
  @override
  void add(List<int> bytes) {
    for (final b in bytes) {
      if (b == 10) {
        final value = jsonDecode(utf8.decode(buffer.takeBytes())) as Map;
        if (value['method'] == 'tools/call' &&
            (value['params'] as Map)['name'] == 'shiyu_abort_media')
          abortUploadIds.add(
            ((value['params'] as Map)['arguments'] as Map)['upload_id']
                as String,
          );
        operations.add(
          value['method'] == 'tools/call'
              ? (value['params'] as Map)['name'] as String
              : value['method'] as String,
        );
      } else {
        buffer.addByte(b);
      }
    }
    real.add(bytes);
  }

  @override
  Future<void> flush() => real.flush();
  @override
  Future<void> close() {
    closeCalls++;
    return real.close();
  }

  @override
  Future<void> get done {
    doneReads++;
    return real.done;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unused borrowed sink method');
}

final class Session {
  late Process process;
  late MediaStdioChannel channel;
  late CountingSink sink;
  final dropped = Completer<void>(), stderrDone = Completer<void>();
  final diagnostics = <String>[];
  final events = StreamController<String>.broadcast(sync: true);
  Future<void> open({
    String? descriptor,
    String? peerMode,
    String version = '2025-11-25',
    int? dropReplyId,
  }) async {
    final env = <String, String>{'CI': 'true'};
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
    if (descriptor != null) env['SHIYU_BRIDGE_DESCRIPTOR'] = descriptor;
    if (peerMode != null) env['SHIYU_SDK_PEER_MODE'] = peerMode;
    final script = peerMode == null
        ? 'bin/shiyu_agent_proxy.dart'
        : 'test/media_sdk_local.dart';
    process = await Process.start(
      vm,
      [
        '-Dshiyu_test_marker=sdk-author-${DateTime.now().microsecondsSinceEpoch}',
        '--packages=${package.path}${Platform.pathSeparator}.dart_tool${Platform.pathSeparator}package_config.json',
        script,
        if (peerMode != null) '--peer',
      ],
      workingDirectory: package.path,
      environment: env,
      includeParentEnvironment: false,
    );
    stdout.writeln('TASK_SDK_VM_PID ${process.pid}');
    process.stdin.done.ignore(); // Caller owns native pipe error observation.
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            diagnostics.add(line);
            if (!events.isClosed) events.add(line);
          },
          onDone: () {
            if (!stderrDone.isCompleted) stderrDone.complete();
          },
        );
    Stream<List<int>> responses = process.stdout;
    if (dropReplyId != null) {
      responses = responses
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .where((line) {
            final message = jsonDecode(line) as Map;
            if (message['id'] == dropReplyId && !dropped.isCompleted) {
              dropped.complete();
              return false;
            }
            return true;
          })
          .map((line) => utf8.encode('$line\n'));
    }
    sink = CountingSink(process.stdin);
    channel = MediaStdioChannel.attach(
      responseBytes: responses,
      requestSink: sink,
    );
    channel.run().ignore();
    final ready = await channel.initialize(protocolVersion: version);
    check(
      ready.tools.length == 8 &&
          {'2025-11-25', '2025-06-18'}.contains(ready.protocolVersion),
      'actual initialize and discovery',
    );
  }

  Future<void> close() async {
    await channel.close();
    Future<void>.sync(process.stdin.close).ignore();
    try {
      await process.exitCode.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      process.kill();
      await process.exitCode.timeout(const Duration(seconds: 3));
    }
    try {
      await stderrDone.future.timeout(const Duration(seconds: 2));
    } catch (_) {}
    await events.close();
  }
}

MediaTransferInput input(b.Host host, {String delivery = 'sdk-fixture'}) =>
    MediaTransferInput(
      binding: host.data.binding,
      deliveryId: delivery,
      sentences: host.data.sentences,
      textDeclaration: f.Fixture.textDeclaration,
      mediaDeclaration: f.Fixture.audioDeclaration,
      timings: [
        const SentenceTiming(sentenceIndex: 0, startMs: 0, endMs: 5000),
      ],
      timingDeclaration: 'Synthetic structural timing',
    );
MediaTransferInput fakeInput() => MediaTransferInput(
  binding: MediaIngestSourceBinding(
    materialId: 'a' * 32,
    materialVersionId: 'b' * 32,
    sourceTextSha256: 'c' * 64,
  ),
  deliveryId: 'sdk-fixture',
  sentences: [
    const LearningSentenceInput(
      english: 'Hello fixture.',
      translation: '合成结构测试。',
    ),
  ],
  textDeclaration: f.Fixture.textDeclaration,
  mediaDeclaration: f.Fixture.audioDeclaration,
  timings: [const SentenceTiming(sentenceIndex: 0, startMs: 0, endMs: 5000)],
  timingDeclaration: 'Synthetic structural timing',
);
Stream<List<int>> fragmented(
  List<int> bytes, {
  int size = 7777,
  bool empty = true,
}) async* {
  for (var offset = 0; offset < bytes.length;) {
    if (empty) yield <int>[];
    final end = offset + size < bytes.length ? offset + size : bytes.length;
    yield bytes.sublist(offset, end);
    offset = end;
  }
}

Future<void> realSdkCases() async {
  for (final cancel in [false, true]) {
    final invoked = Completer<void>(), host = b.Host();
    await host.open(
      onAbort: () {
        if (!invoked.isCompleted) invoked.complete();
      },
    );
    final session = Session();
    await session.open(descriptor: host.descriptorPath);
    try {
      var opens = 0;
      Stream<List<int>> source() async* {
        opens++;
        yield* fragmented(host.data.bytes, size: opens == 1 ? 1301 : 9973);
        if (opens == 1) {
          check(
            host.data.probe.registrations == 0 &&
                (await Directory(
                      '${host.data.root.path}/ingest',
                    ).list().toList()).length ==
                    1,
            'Pass1 no App staging or register',
          );
        }
      }

      if (cancel) host.pauseMaterial();
      final task = MediaTransfer.start(
        input: input(host),
        source: source,
        channel: session.channel,
      );
      if (cancel) {
        await host.data.probe.registrationEntered!.future;
        final stopped = task.abort();
        await invoked.future;
        host.releaseMaterial();
        final result = await stopped;
        await task.completion;
        check(
          result.status == MediaTransferStatus.terminal &&
              (await host.data.learning.listCandidates()).isEmpty,
          'SDK control went through real same stdin and stopped Learning',
        );
        final again = await task.resume(
          channel: session.channel,
          source: source,
        );
        check(
          again.status == MediaTransferStatus.needsReconcile &&
              task.progress.cancelRequested,
          'sticky cancel never resumes data',
        );
      } else {
        final result = await task.completion;
        check(
          result.status == MediaTransferStatus.delivered &&
              result.receipt?['payload_sha256'] is String,
          'actual SDK delivered semantic receipt',
        );
        check(
          (await host.data.learning.listCandidates()).single.state ==
                  LearningCandidateState.pendingReview &&
              host.data.probe.registrations == 1,
          'real Store only pending candidate',
        );
      }
      await task.drain();
      check(opens == 2, 'fresh transfer exactly two source passes');
      check(
        session.diagnostics.isEmpty &&
            !task.progress.toString().contains('capability'),
        'no SDK binary/cap diagnostics',
      );
      print(
        'PASS real SDK two source passes / fragmented code MCP pipe / actual Stores cancel=$cancel',
      );
    } finally {
      host.releaseMaterial();
      await session.close();
      await host.close();
    }
  }
}

Future<void> changedSourceCase() async {
  final session = Session();
  await session.open(peerMode: 'good');
  try {
    var opens = 0;
    final bytes = f.syntheticWave();
    Stream<List<int>> source() {
      opens++;
      final actual = Uint8List.fromList(bytes);
      if (opens == 2) actual[100] = 1;
      return fragmented(actual, size: 701);
    }

    final task = MediaTransfer.start(
          input: fakeInput(),
          source: source,
          channel: session.channel,
        ),
        result = await task.completion;
    check(
      result.status == MediaTransferStatus.needsReconcile &&
          result.code == MediaTransferCode.sourceChanged,
      'source change stops before bad chunk',
    );
    check(
      session.diagnostics.where((s) => s == 'REQ:media_begin').length == 1 &&
          !session.diagnostics.contains('REQ:media_chunk') &&
          !session.diagnostics.contains('REQ:media_submit'),
      'no bad source data or automatic cleanup sent',
    );
    final stopped = await task.abort();
    check(
      stopped.status == MediaTransferStatus.terminal,
      'caller explicit abort only',
    );
    print(
      'PASS second source changed / no bad chunk or blind submit / explicit abort',
    );
  } finally {
    await session.close();
  }
}

Future<void> peerMain() async {
  final mode = Platform.environment['SHIYU_SDK_PEER_MODE'] ?? 'good';
  final out = stdout.nonBlocking;
  out.done.ignore();
  Future<void> reply(Object? id, Object result) async {
    out.writeln(jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}));
    await out.flush();
  }

  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final request = jsonDecode(line) as Map;
    final id = request['id'], method = request['method'];
    if (id == null) continue;
    if (method == 'initialize') {
      if (mode == 'silent-init') {
        stderr.writeln('REQ:initialize');
        continue;
      }
      await reply(id, {
        'protocolVersion': mode == 'bad-version'
            ? '2099-01-01'
            : (request['params'] as Map)['protocolVersion'],
        'capabilities': {'tools': {}},
        'serverInfo': {'name': 'synthetic-peer', 'version': '1'},
      });
      continue;
    }
    if (method == 'tools/list') {
      final actual = await rpc.runBytes(
        rpc.lines([
          rpc.initialize(1),
          rpc.initialized,
          rpc.request(2, 'tools/list'),
        ]),
      );
      final result = Map<String, Object?>.from(
        actual.replies.last['result'] as Map,
      );
      if (mode == 'bad-schema') {
        final tools = result['tools'] as List;
        final tool = tools.singleWhere(
          (value) => (value as Map)['name'] == 'shiyu_put_media_chunk',
        ) as Map;
        final schema = tool['inputSchema'] as Map;
        (schema['properties'] as Map).remove('upload_id');
        (schema['required'] as List).remove('upload_id');
      }
      await reply(id, result);
      continue;
    }
    if (method != 'tools/call') continue;
    final params = request['params'] as Map, name = params['name'];
    final operation = MediaWireOperation.values.singleWhere(
      (op) => op.toolName == name,
    );
    final body = Map<String, Object?>.from(params['arguments'] as Map);
    final decoded = decodeMediaBridgePayload(
      operation.wireName,
      encodeAgentBridgeJson(body, maxBytes: 196608),
    );
    stderr.writeln('REQ:${operation.wireName}');
    if (mode == 'silent-begin' && operation == MediaWireOperation.begin)
      continue;
    late Map<String, Object?> result;
    switch (operation) {
      case MediaWireOperation.begin:
        result = {
          'upload_id': 'e' * 32,
          'raw_chunk_bytes': 65536,
          'next_index': 0,
          'status': 'receiving',
          'replayed': false,
        };
      case MediaWireOperation.chunk:
        final chunk = decoded as MediaWireChunk;
        result = {
          'upload_id': body['upload_id'],
          'index': chunk.index,
          'accepted_bytes': chunk.index * 65536 + chunk.bytes.length,
          'status': 'receiving',
          'replayed': false,
        };
      case MediaWireOperation.seal:
        result = {
          'upload_id': body['upload_id'],
          'sealed_receipt': 'f' * 64,
          'status': 'sealed',
          'replayed': false,
        };
      case MediaWireOperation.submit:
        result = {
          'candidate_id': 'd' * 32,
          'payload_sha256': mode == 'wrong-hash'
              ? '0' * 64
              : (decoded as MediaWireSubmit).submission.media.submissionSha256,
          'status': 'delivered',
          'replayed': false,
        };
      case MediaWireOperation.abort:
        result = {'upload_id': body['upload_id'], 'status': 'terminal'};
    }
    final wrapper = {
      'content': [
        {'type': 'text', 'text': jsonEncode(result)},
      ],
      'structuredContent': result,
      'isError': false,
    };
    await reply(id, wrapper);
    if (mode == 'duplicate' && operation == MediaWireOperation.begin)
      await reply(id, wrapper);
  }
}

Future<void> main(List<String> args) async {
  if (args.contains('--peer')) {
    await peerMain();
    return;
  }
  await realSdkCases();
  await changedSourceCase();
  await silentDeadlineStickyCase();
  await realAckGapResumeCases();
  await protocolContractCases();
  await sourceBoundsAndDeadlineCases();
  await semanticAckAndVersionCases();
  await actualAbortGapControlRebindCase();
  await silentInitializeCase();
  await lateIdAndApiOwnershipCase();
  await sdkScopeCase();
}

Future<void> silentDeadlineStickyCase() async {
  final timers = <b.CapturedTimer>[];
  await runZoned(
    () async {
      final session = Session();
      await session.open(peerMode: 'silent-begin');
      try {
        var opens = 0;
        Stream<List<int>> source() {
          opens++;
          return fragmented(f.syntheticWave(), size: 1001);
        }

        final seen = session.events.stream.firstWhere(
          (s) => s == 'REQ:media_begin',
        );
        final task = MediaTransfer.start(
          input: fakeInput(),
          source: source,
          channel: session.channel,
        );
        await seen;
        final stopped = await task.abort();
        check(
          stopped.status == MediaTransferStatus.needsReconcile &&
              task.progress.cancelRequested,
          'unknown begin without id only local stop',
        );
        final before = session.sink.operations.length;
        var exited = false;
        session.process.exitCode.then((_) => exited = true).ignore();
        var closed = false;
        final closing = session.channel.close().then((_) => closed = true);
        await b.eventTurn();
        check(!closed, 'silent child close waits its accepted finite deadline');
        final active = timers.where((t) => t.isActive).toList();
        check(active.length == 1, 'one actual 25s pending timer');
        active.single.fire();
        final result = await task.completion;
        await closing;
        await task.drain();
        check(
          result.status == MediaTransferStatus.unknown && !exited,
          'logical deadline settled without killing child',
        );
        check(
          session.sink.closeCalls == 0 && session.sink.doneReads == 0,
          'SDK never closes/awaits borrowed sink',
        );
        final resumed = await task.resume(
          channel: session.channel,
          source: source,
        );
        check(
          resumed.status == MediaTransferStatus.needsReconcile &&
              opens == 1 &&
              session.sink.operations.length == before,
          'cancelled begin never replays or starts data on resume',
        );
        print(
          'PASS actual silent child 25s logical deadline / borrowed ownership / sticky begin unknown no replay',
        );
      } finally {
        await session.close();
      }
    },
    zoneSpecification: ZoneSpecification(
      createTimer: (self, parent, zone, duration, callback) {
        if (duration == const Duration(seconds: 25)) {
          final timer = b.CapturedTimer(callback);
          timers.add(timer);
          return timer;
        }
        return parent.createTimer(zone, duration, callback);
      },
    ),
  );
}

Future<void> realAckGapResumeCases() async {
  for (final gap in ['chunk', 'seal', 'submit']) {
    final submitGap = gap == 'submit', dataGap = gap == 'chunk';
    final timers = <b.CapturedTimer>[];
    await runZoned(
      () async {
        final host = b.Host();
        await host.open();
        final first = Session();
        Session? second;
        await first.open(
          descriptor: host.descriptorPath,
          dropReplyId: submitGap
              ? 8
              : dataGap
              ? 4
              : 7,
        );
        try {
          var opens = 0;
          Stream<List<int>> source() {
            opens++;
            return fragmented(
              host.data.bytes,
              size: opens.isOdd ? 3011 : 10013,
            );
          }

          final task = MediaTransfer.start(
            input: input(host),
            source: source,
            channel: first.channel,
          );
          await first.dropped.future;
          final active = timers.where((timer) => timer.isActive).toList();
          check(active.length == 1, 'one actual dropped-ACK request deadline');
          active.single.fire();
          final failed = await task.completion;
          check(
            failed.status == MediaTransferStatus.unknown,
            'dropped real receipt projected unknown',
          );
          String? originalRef;
          if (submitGap) {
            originalRef = (await host.data.materials.findArtifactRegistration(
              host.data.operation('sdk-fixture'),
            ))!.artifactId;
            check(
              (await host.data.learning.listCandidates()).length == 1,
              'actual submit committed before lost ACK',
            );
          } else {
            check(
              host.data.probe.registrations == 0,
              'unknown chunk did not register',
            );
          }
          final before = first.sink.operations.length;
          await b.eventTurn();
          check(
            first.sink.operations.length == before,
            'unknown never retries automatically',
          );
          await first.close();
          second = Session();
          await second.open(descriptor: host.descriptorPath);
          final result = await task.resume(
            channel: second.channel,
            source: dataGap ? source : null,
          );
          check(
            result.status == MediaTransferStatus.delivered &&
                (await host.data.learning.listCandidates()).length == 1,
            'explicit same-stage actual resume delivered uniquely',
          );
          final ref = (await host.data.materials.findArtifactRegistration(
            host.data.operation('sdk-fixture'),
          ))!.artifactId;
          check(
            originalRef == null || ref == originalRef,
            'submit replay same operation ref',
          );
          check(
            opens == (dataGap ? 4 : 2),
            'resume reads source only for unknown data stage',
          );
          check(
            second.sink.operations
                .where((op) => op == 'shiyu_begin_media')
                .isEmpty,
            'known upload resume never recreates begin',
          );
          if (!dataGap)
            check(
              second.sink.operations
                  .where((op) => op == 'shiyu_put_media_chunk')
                  .isEmpty,
              'submit resume not a hidden reupload',
            );
          check(
            first.sink.closeCalls == 0 && second.sink.closeCalls == 0,
            'transfer did not close either borrowed pipe',
          );
          await task.drain();
          print(
            'PASS actual App ${gap} ACK gap / explicit same-stage new channel resume / unique ref-candidate',
          );
        } finally {
          if (second != null) await second.close();
          if (first.channel.state != MediaChannelState.terminal)
            await first.close();
          await host.close();
        }
      },
      zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, callback) {
          if (duration == const Duration(seconds: 25)) {
            final timer = b.CapturedTimer(callback);
            timers.add(timer);
            return timer;
          }
          return parent.createTimer(zone, duration, callback);
        },
      ),
    );
  }
}

Future<void> protocolContractCases() async {
  for (final mode in ['bad-version', 'bad-schema']) {
    final session = Session();
    try {
      final failure = await wFailure(() => session.open(peerMode: mode));
      check(
        failure is MediaChannelException &&
            session.channel.state == MediaChannelState.terminal,
        'bad metadata terminal before ready',
      );
      check(
        !session.sink.operations.any((op) => op.startsWith('shiyu_')),
        'bad metadata never sends media',
      );
      print(
        'PASS actual peer $mode rejected before media / required schema and version contracts',
      );
    } finally {
      await session.close();
    }
  }
  final duplicate = Session();
  await duplicate.open(peerMode: 'duplicate');
  try {
    final task = MediaTransfer.start(
      input: fakeInput(),
      source: () => fragmented(f.syntheticWave()),
      channel: duplicate.channel,
    );
    final result = await task.completion;
    check(
      duplicate.channel.state == MediaChannelState.terminal &&
          result.status != MediaTransferStatus.delivered,
      'duplicate response id terminal without fake success',
    );
    await duplicate.channel.close();
    print(
      'PASS duplicate response id finite terminal / no ID reuse or fake success',
    );
  } finally {
    await duplicate.close();
  }
}

Future<Object> wFailure(FutureOr<Object?> Function() action) async {
  try {
    await action();
  } catch (error) {
    return error;
  }
  throw StateError('expected typed failure');
}

Uint8List wave(int size) {
  final result = Uint8List(size)
    ..setRange(0, 44, f.syntheticWave().sublist(0, 44));
  final data = ByteData.sublistView(result);
  data.setUint32(4, size - 8, Endian.little);
  data.setUint32(40, size - 44, Endian.little);
  return result;
}

Future<void> sourceBoundsAndDeadlineCases() async {
  final host = b.Host();
  await host.open();
  final actual = Session();
  await actual.open(descriptor: host.descriptorPath);
  try {
    var opens = 0;
    final bytes = wave(1920044);
    Stream<List<int>> source() {
      opens++;
      return fragmented(bytes, size: 65536);
    }

    final task = MediaTransfer.start(
          input: input(host, delivery: 'max-sdk'),
          source: source,
          channel: actual.channel,
        ),
        result = await task.completion;
    check(
      result.status == MediaTransferStatus.delivered &&
          opens == 2 &&
          actual.sink.operations
                  .where((op) => op == 'shiyu_put_media_chunk')
                  .length ==
              30,
      'maximum actual PCM exactly30 chunks',
    );
    check(
      (await host.data.learning.listCandidates()).length == 1 &&
          host.data.probe.registrations == 1,
      'max real Store once and candidate',
    );
    print(
      'PASS maximum actual1920044 PCM / two source passes / exactly30 code chunks / real Stores',
    );
  } finally {
    await actual.close();
    await host.close();
  }
  for (final kind in [
    'tooLarge',
    'oddLength',
    'oversizeFragment',
    'negativeByte',
    'overflowByte',
    'sourceThrows',
  ]) {
    final session = Session();
    await session.open(peerMode: 'good');
    try {
      Stream<List<int>> source() => switch (kind) {
        'tooLarge' => fragmented(wave(1920045), size: 65536),
        'oddLength' => fragmented(wave(1920043), size: 65536),
        'oversizeFragment' => Stream.value(List<int>.filled(65537, 0)),
        'negativeByte' => Stream.value(<int>[-1]),
        'overflowByte' => Stream.value(<int>[256]),
        _ => Stream.error(FileSystemException('PRIVATE_SOURCE_SENTINEL')),
      };
      final task = MediaTransfer.start(
            input: fakeInput(),
            source: source,
            channel: session.channel,
          ),
          result = await task.completion;
      check(
        result.status == MediaTransferStatus.localFailure &&
            !session.sink.operations.any((op) => op.startsWith('shiyu_')),
        'invalid source before any mutation',
      );
      check(
        !result.toString().contains('PRIVATE_SOURCE_SENTINEL') &&
            !task.progress.toString().contains('PRIVATE_SOURCE_SENTINEL'),
        'source error not echoed',
      );
    } finally {
      await session.close();
    }
  }
  print(
    'PASS source length±1 / fragment64Ki+1 / int range / source exception no mutation or raw echo',
  );
  final timers = <b.CapturedTimer>[];
  await runZoned(
    () async {
      final session = Session();
      await session.open(peerMode: 'good');
      final listened = Completer<void>(),
          cancelled = Completer<void>(),
          never = Completer<void>();
      final source = StreamController<List<int>>(
        onListen: () => listened.complete(),
        onCancel: () {
          cancelled.complete();
          return never.future;
        },
      );
      try {
        final task = MediaTransfer.start(
          input: fakeInput(),
          source: () => source.stream,
          channel: session.channel,
        );
        await listened.future;
        await b.eventTurn();
        timers.lastWhere((timer) => timer.isActive).fire();
        await cancelled.future;
        await b.eventTurn();
        timers.lastWhere((timer) => timer.isActive).fire();
        final result = await task.completion;
        await task.drain();
        check(
          result.status == MediaTransferStatus.localFailure &&
              result.code == MediaTransferCode.sourceTimeout &&
              !never.isCompleted,
          'source timeout and never cancel logically settle once',
        );
        check(
          !session.sink.operations.any((op) => op.startsWith('shiyu_')),
          'source deadline before begin',
        );
        print(
          'PASS async source15s plus bounded cancel / no re-await hung original / no mutation',
        );
      } finally {
        Future<void>.sync(source.close).ignore();
        await session.close();
      }
    },
    zoneSpecification: ZoneSpecification(
      createTimer: (self, parent, zone, duration, callback) {
        if (duration >= const Duration(seconds: 14) &&
            duration <= const Duration(seconds: 15)) {
          final timer = b.CapturedTimer(callback);
          timers.add(timer);
          return timer;
        }
        return parent.createTimer(zone, duration, callback);
      },
    ),
  );
  final session = Session();
  await session.open(peerMode: 'good');
  try {
    var emissions = 0;
    Stream<List<int>> empty() async* {
      while (true) {
        emissions++;
        yield <int>[];
      }
    }

    final beat = Completer<void>();
    Timer.run(() => beat.complete());
    final task = MediaTransfer.start(
      input: fakeInput(),
      source: empty,
      channel: session.channel,
    );
    await beat.future;
    final stop = await task.abort();
    await task.completion;
    await task.drain();
    check(
      emissions <= 128 &&
          stop.status == MediaTransferStatus.needsReconcile &&
          !session.sink.operations.any((op) => op.startsWith('shiyu_')),
      'immediate empty emissions yield fairly and cancel locally',
    );
    print(
      'PASS cooperative empty emission fairness / local sticky stop before begin / bounded buffer',
    );
  } finally {
    await session.close();
  }
}

Future<void> semanticAckAndVersionCases() async {
  final old = Session();
  await old.open(peerMode: 'good', version: '2025-06-18');
  await old.close();
  print(
    'PASS exact supported old MCP protocol negotiation / ready without granting media',
  );
  final bad = Session();
  await bad.open(peerMode: 'wrong-hash');
  try {
    final task = MediaTransfer.start(
          input: fakeInput(),
          source: () => fragmented(f.syntheticWave()),
          channel: bad.channel,
        ),
        result = await task.completion;
    check(
      result.status == MediaTransferStatus.unknown &&
          bad.channel.state == MediaChannelState.terminal,
      'wrong valid semantic hash never delivered',
    );
    print(
      'PASS SDK wrong valid64hex semantic hash unknown / protocol terminal / no fake candidate binding',
    );
  } finally {
    await bad.close();
  }
}

Future<void> actualAbortGapControlRebindCase() async {
  final timers = <b.CapturedTimer>[];
  await runZoned(
    () async {
      final invoked = Completer<void>(), host = b.Host();
      await host.open(
        onAbort: () {
          if (!invoked.isCompleted) invoked.complete();
        },
      );
      host.pauseMaterial();
      final first = Session();
      Session? second;
      await first.open(descriptor: host.descriptorPath, dropReplyId: 9);
      try {
        var opens = 0;
        Stream<List<int>> source() {
          opens++;
          return fragmented(host.data.bytes, size: 9001);
        }

        final task = MediaTransfer.start(
          input: input(host),
          source: source,
          channel: first.channel,
        );
        await host.data.probe.registrationEntered!.future;
        final stopped = task.abort();
        await invoked.future;
        host.releaseMaterial();
        await first.dropped.future;
        timers.lastWhere((timer) => timer.isActive).fire();
        final result = await stopped;
        await task.completion;
        check(
          result.status == MediaTransferStatus.unknown &&
              task.progress.cancelRequested,
          'actual abort ACK lost remains sticky unknown',
        );
        final oldId = first.sink.abortUploadIds.single;
        final original = (await host.data.materials.findArtifactRegistration(
          host.data.operation('sdk-fixture'),
        ))!.artifactId;
        final dirs = await Directory('${host.data.root.path}/ingest')
            .list()
            .where((e) => e is Directory)
            .toList();
        final part = File('${dirs.single.path}/media.part');
        check(
          await part.length() == host.data.bytes.length,
          'registered original staging conservatively retained',
        );
        await first.close();
        second = Session();
        await second.open(descriptor: host.descriptorPath);
        final before = second.sink.operations.length;
        final rebound = await task.resume(
          channel: second.channel,
          source: source,
        );
        check(
          rebound.status == MediaTransferStatus.needsReconcile &&
              task.progress.cancelRequested &&
              second.sink.operations.length == before &&
              opens == 2,
          'cancelled resume only rebinds, no data/source/automatic abort',
        );
        final retried = await task.abort();
        check(
          retried.status == MediaTransferStatus.terminal &&
              second.sink.abortUploadIds.single == oldId,
          'caller explicit abort same upload on replacement channel',
        );
        check(
          (await host.data.learning.listCandidates()).isEmpty &&
              (await host.data.materials.findArtifactRegistration(
                    host.data.operation('sdk-fixture'),
                  ))!.artifactId ==
                  original &&
              await part.length() == host.data.bytes.length,
          'control replay preserves candidate/part/artifact identity facts',
        );
        await task.drain();
        print(
          'PASS actual abort ACK drop / cancelled resume control-only rebind / explicit same upload abort',
        );
      } finally {
        if (second != null) await second.close();
        await first.close();
        host.releaseMaterial();
        await host.close();
      }
    },
    zoneSpecification: ZoneSpecification(
      createTimer: (self, parent, zone, duration, callback) {
        if (duration == const Duration(seconds: 25)) {
          final timer = b.CapturedTimer(callback);
          timers.add(timer);
          return timer;
        }
        return parent.createTimer(zone, duration, callback);
      },
    ),
  );
}

Future<void> silentInitializeCase() async {
  final timers = <b.CapturedTimer>[];
  await runZoned(
    () async {
      final session = Session();
      final observed = session
          .open(peerMode: 'silent-init')
          .then<Object?>((_) => null, onError: (Object e) => e);
      // Wait for the caller-owned fixed diagnostic, not a timing sleep.
      while (session.diagnostics.isEmpty) {
        await b.eventTurn();
      }
      var exited = false;
      session.process.exitCode.then((_) => exited = true).ignore();
      final closing = session.channel.close();
      timers.lastWhere((timer) => timer.isActive).fire();
      final result = await observed;
      await closing;
      check(
        result is MediaChannelException &&
            !exited &&
            session.sink.closeCalls == 0 &&
            session.sink.doneReads == 0,
        'silent initialization deadline and borrowed ownership',
      );
      check(
        session.sink.operations.length == 1 &&
            session.sink.operations.single == 'initialize',
        'failed init no notification/discovery/media',
      );
      await session.close();
      print(
        'PASS silent initialize25s / exact handshake stops / close finite without owning child',
      );
    },
    zoneSpecification: ZoneSpecification(
      createTimer: (self, parent, zone, duration, callback) {
        if (duration == const Duration(seconds: 25)) {
          final timer = b.CapturedTimer(callback);
          timers.add(timer);
          return timer;
        }
        return parent.createTimer(zone, duration, callback);
      },
    ),
  );
}

final class MemoryPipeSink implements IOSink {
  final buffer = BytesBuilder(copy: false);
  void Function(Map<String, dynamic>)? onRequest;
  int closeCalls = 0, doneReads = 0;
  @override
  void add(List<int> bytes) {
    for (final byte in bytes) {
      if (byte == 10) {
        onRequest?.call(
          jsonDecode(utf8.decode(buffer.takeBytes())) as Map<String, dynamic>,
        );
      } else {
        buffer.addByte(byte);
      }
    }
  }

  @override
  Future<void> flush() => Future.value();
  @override
  Future<void> close() {
    closeCalls++;
    return Completer<void>().future;
  }

  @override
  Future<void> get done {
    doneReads++;
    return Completer<void>().future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unused memory pipe method');
}

Future<void> lateIdAndApiOwnershipCase() async {
  final discovered = await rpc.runBytes(
    rpc.lines([
      rpc.initialize(1),
      rpc.initialized,
      rpc.request(2, 'tools/list'),
    ]),
  );
  final timers = <b.CapturedTimer>[];
  await runZoned(
    () async {
      final responses = StreamController<List<int>>.broadcast(sync: true),
          sink = MemoryPipeSink();
      final seen = Completer<void>();
      Object? requestId;
      void reply(Object? id, Object value) => responses.add(
        utf8.encode(
          '${jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': value})}\n',
        ),
      );
      sink.onRequest = (request) {
        if (request['method'] == 'initialize')
          reply(request['id'], {
            'protocolVersion': '2025-11-25',
            'serverInfo': {'name': 'owned-memory-peer'},
            'capabilities': {'tools': {}},
          });
        else if (request['method'] == 'tools/list')
          reply(request['id'], discovered.replies.last['result']!);
        else if (request['method'] == 'tools/call') {
          requestId = request['id'];
          if (!seen.isCompleted) seen.complete();
        }
      };
      final channel = MediaStdioChannel.attach(
        responseBytes: responses.stream,
        requestSink: sink,
      );
      channel.run().ignore();
      await channel.initialize();
      final repeated = await wFailure(() => channel.initialize());
      check(
        repeated is MediaChannelException &&
            channel.state == MediaChannelState.ready,
        'duplicate initialize does not replace accepted lifetime',
      );
      final body = w.beginPacket(w.packet(fakeInput().binding)),
          pending = channel.invoke(MediaWireOperation.begin, body);
      await seen.future;
      timers.lastWhere((timer) => timer.isActive).fire();
      final failed = await pending;
      await channel.close();
      check(
        failed.kind == MediaToolReplyKind.unknown,
        'silent pending terminated before late response',
      );
      final result = {
        'upload_id': 'e' * 32,
        'raw_chunk_bytes': 65536,
        'next_index': 0,
        'status': 'receiving',
        'replayed': false,
      };
      final tool = {
        'content': [
          {'type': 'text', 'text': jsonEncode(result)},
        ],
        'structuredContent': result,
        'isError': false,
      };
      reply(requestId, tool);
      reply(requestId, tool);
      reply(999, tool);
      await b.eventTurn();
      check(
        channel.state == MediaChannelState.terminal &&
            failed.kind == MediaToolReplyKind.unknown &&
            !responses.isClosed &&
            sink.closeCalls == 0 &&
            sink.doneReads == 0,
        'late duplicate/future response never revives or owns borrowed resources',
      );
      await channel.close();
      await responses.close();
      print(
        'PASS late ID after deadline ignored / duplicate init guard / borrowed close-done untouched',
      );
    },
    zoneSpecification: ZoneSpecification(
      createTimer: (self, parent, zone, duration, callback) {
        if (duration == const Duration(seconds: 25)) {
          final timer = b.CapturedTimer(callback);
          timers.add(timer);
          return timer;
        }
        return parent.createTimer(zone, duration, callback);
      },
    ),
  );
}

Future<void> sdkScopeCase() async {
  final host = b.Host();
  await host.open(media: false);
  final session = Session();
  await session.open(descriptor: host.descriptorPath);
  try {
    var opens = 0;
    Stream<List<int>> source() {
      opens++;
      return fragmented(host.data.bytes);
    }

    final task = MediaTransfer.start(
          input: input(host),
          source: source,
          channel: session.channel,
        ),
        result = await task.completion;
    check(
      result.status == MediaTransferStatus.rejected &&
          result.remoteCode == 'forbidden' &&
          opens == 1 &&
          host.data.probe.registrations == 0 &&
          (await host.data.learning.listCandidates()).isEmpty,
      'protocol ready never grants media',
    );
    check(
      session.sink.operations
              .where((op) => op == 'shiyu_put_media_chunk')
              .isEmpty &&
          session.channel.state == MediaChannelState.ready,
      'no data or grant refresh after scope denial',
    );
    print(
      'PASS actual SDK protocol ready8 tools / default mediafalse remains denied / no automatic grant',
    );
  } finally {
    await session.close();
    await host.close();
  }
}
