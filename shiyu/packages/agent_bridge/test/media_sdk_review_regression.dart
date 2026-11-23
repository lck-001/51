import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'media_socket_local.dart' as b;

import 'package:agent_bridge/agent_bridge.dart';

import 'media_sdk_local.dart' as sdk;
import 'media_wire_local.dart' as wire;
import 'mcp_proxy_local.dart' as rpc;

void check(bool v, String label) {
  if (!v) throw StateError(label);
}

final class DelayedSink implements IOSink {
  final buffer = BytesBuilder(copy: false), never = Completer<void>();
  bool hold = false;
  void Function(Map<String, dynamic>)? request;
  @override
  void add(List<int> bytes) {
    for (final b in bytes) {
      if (b == 10) {
        request?.call(
          jsonDecode(utf8.decode(buffer.takeBytes())) as Map<String, dynamic>,
        );
      } else {
        buffer.addByte(b);
      }
    }
  }

  @override
  Future<void> flush() => hold ? never.future : Future.value();
  @override
  Future<void> close() => never.future;
  @override
  Future<void> get done => never.future;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unused');
}

Future<void> knownAckFaults() async {
  final metadata = await rpc.runBytes(
    rpc.lines([
      rpc.initialize(1),
      rpc.initialized,
      rpc.request(2, 'tools/list'),
    ]),
  );
  for (final fault in ['eof', 'duplicate', 'badFrame']) {
    final responses = StreamController<List<int>>(sync: true),
        sink = DelayedSink();
    void reply(Object? id, Object value) => responses.add(
      utf8.encode(
        '${jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': value})}\n',
      ),
    );
    sink.request = (request) {
      if (request['method'] == 'initialize')
        reply(request['id'], {
          'protocolVersion': '2025-11-25',
          'serverInfo': {},
          'capabilities': {},
        });
      else if (request['method'] == 'tools/list')
        reply(request['id'], metadata.replies.last['result']!);
      else if (request['method'] == 'tools/call') {
        sink.hold = true;
        final body = Map<String, Object?>.from(
          (request['params'] as Map)['arguments'] as Map,
        );
        final parsed = decodeMediaBridgePayload(
          'media_submit',
          encodeAgentBridgeJson(body, maxBytes: 196608),
        ) as MediaWireSubmit;
        final result = {
          'candidate_id': 'd' * 32,
          'payload_sha256': parsed.submission.media.submissionSha256,
          'replayed': false,
          'status': 'delivered',
        };
        final wrapper = {
          'content': [
            {'type': 'text', 'text': jsonEncode(result)},
          ],
          'structuredContent': result,
          'isError': false,
        };
        reply(request['id'], wrapper);
        if (fault == 'eof') {
          responses.close().ignore();
        } else if (fault == 'duplicate') {
          reply(request['id'], wrapper);
        } else {
          responses.add(utf8.encode('{\n'));
        }
      }
    };
    final channel = MediaStdioChannel.attach(
      responseBytes: responses.stream,
      requestSink: sink,
    );
    channel.run().ignore();
    await channel.initialize();
    final result = await channel.invoke(
      MediaWireOperation.submit,
      wire.packet(sdk.fakeInput().binding),
    );
    check(
      result.kind == MediaToolReplyKind.success &&
          result.result?['status'] == 'delivered',
      'validated semantic ACK must survive $fault while flush pending',
    );
    check(
      channel.state == MediaChannelState.terminal && !sink.never.isCompleted,
      'terminal without reopening data or waiting flush',
    );
    await channel.close();
    responses.close().ignore();
    stdout.writeln(
      'PASS known semantic ACK / delayed flush / $fault remains known and terminal',
    );
  }
}

Future<void> main() async {
  await knownAckFaults();
  await defaultVmSourceGate();
}

Future<void> defaultVmSourceGate() async {
  final host = b.Host();
  await host.open();
  final session = sdk.Session();
  await session.open(descriptor: host.descriptorPath);
  try {
    var opens = 0, empty = 0;
    Future<Stream<List<int>>> source() async {
      final pass = ++opens;
      Stream<List<int>> produce() async* {
        // A finite large empty burst exercises the previously accumulating shared
        // cancellation future. Direct List/Uint8List variable patterns exercise the
        // default optimizing VM path reported by independent QA, without VM flags.
        for (var i = 0; i < 40000; i++) {
          empty++;
          yield const <int>[];
        }
        final pattern = pass.isOdd
            ? <int>[1, 8191, 65536, 4093]
            : <int>[65536, 17, 12345];
        var offset = 0, index = 0;
        while (offset < host.data.bytes.length) {
          yield const <int>[];
          final size = pattern[index++ % pattern.length],
              end = offset + size < host.data.bytes.length
                  ? offset + size
                  : host.data.bytes.length;
          yield Uint8List.fromList(host.data.bytes.sublist(offset, end));
          offset = end;
          await Future<void>.delayed(Duration.zero);
        }
      }

      return produce();
    }

    final task = MediaTransfer.start(
      input: sdk.input(host, delivery: 'source-gate-default-vm'),
      source: source,
      channel: session.channel,
    );
    final result = await task.completion;
    check(
      result.status == MediaTransferStatus.delivered &&
          opens == 2 &&
          empty == 80000,
      'bounded source read gate handles large cooperative empty bursts and variable typed fragments',
    );
    check(
      host.data.probe.registrations == 1 &&
          (await host.data.learning.listCandidates()).length == 1,
      'real source gate Store facts',
    );
    print(
      'PASS default optimizing VM / 80000 empty events / variable async typed fragments / real two-pass Store delivery',
    );
  } finally {
    await session.close();
    await host.close();
  }
}
