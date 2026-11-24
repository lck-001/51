import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyu_playback_probe/client_shutdown.dart';
import 'package:shiyu_playback_probe/playback/windows_playback_host.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('shiyu/windows_playback_host');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  bool configured = true;
  Completer<void>? retireGate;
  Completer<int>? ticketGate;
  Completer<void>? ackGate;
  Object? ackFailure;
  Object? retireFailure;
  int? returnedTicket = 37;
  setUp(() {
    calls = [];
    configured = true;
    retireGate = null;
    ticketGate = null;
    ackGate = null;
    ackFailure = null;
    retireFailure = null;
    returnedTicket = 37;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'create':
          return {'configured': configured};
        case 'retire':
          await retireGate?.future;
          if (retireFailure != null) throw retireFailure!;
          return null;
        case 'beginProgrammaticClose':
          return {
            'ticket': ticketGate == null
                ? returnedTicket
                : await ticketGate!.future,
          };
        case 'closeReady':
          await ackGate?.future;
          if (ackFailure != null) throw ackFailure!;
          return null;
        case 'detachDrainedFailedStartup':
          return null;
        default:
          throw PlatformException(code: 'unexpected_${call.method}');
      }
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  Future<void> tick() => Future<void>.delayed(Duration.zero);
  List<String> methods() => calls.map((c) => c.method).toList();
  Future<void> exit(WindowsPlaybackHost host) =>
      host.requestProgrammaticExitAfterDrain();

  test(
    'real host cannot begin programmatic exit before successful close',
    () async {
      final host = await WindowsPlaybackHost.create();
      await expectLater(exit(host), throwsStateError);
      expect(methods(), ['create']);
      await host.close();
    },
  );
  test(
    'unsupported SMTC still closes with the native returned ticket',
    () async {
      configured = false;
      final host = await WindowsPlaybackHost.create();
      await host.close();
      await exit(host);
      expect(methods(), [
        'create',
        'retire',
        'beginProgrammaticClose',
        'closeReady',
      ]);
      expect(calls.last.arguments, {'ticket': 37});
    },
  );
  test(
    'close shares exact pending operation and exit cannot pass its gate',
    () async {
      final host = await WindowsPlaybackHost.create();
      retireGate = Completer<void>();
      final closing = host.close();
      final duplicate = host.close();
      expect(identical(closing, duplicate), isTrue);
      await tick();
      await expectLater(exit(host), throwsStateError);
      expect(methods(), ['create', 'retire']);
      retireGate!.complete();
      await Future.wait([closing, duplicate]);
      await exit(host);
    },
  );
  test(
    'failed close stays failed and never permits native exit or detach',
    () async {
      final host = await WindowsPlaybackHost.create();
      retireFailure = PlatformException(code: 'controlled_retire_failure');
      final closing = host.close();
      await expectLater(closing, throwsA(isA<PlatformException>()));
      expect(identical(closing, host.close()), isTrue);
      await expectLater(host.close(), throwsA(isA<PlatformException>()));
      await expectLater(exit(host), throwsStateError);
      await expectLater(host.detachDrainedFailedStartup(), throwsStateError);
      expect(methods(), ['create', 'retire']);
    },
  );
  test(
    'pending native begin survives caller timeout without new ticket request',
    () async {
      final host = await WindowsPlaybackHost.create();
      await host.close();
      ticketGate = Completer<int>();
      final pending = exit(host);
      await expectLater(
        pending.timeout(Duration.zero),
        throwsA(isA<TimeoutException>()),
      );
      final again = exit(host);
      expect(identical(pending, again), isTrue);
      expect(methods().where((m) => m == 'beginProgrammaticClose').length, 1);
      expect(methods().contains('closeReady'), isFalse);
      ticketGate!.complete(91);
      await again;
      expect(calls.last.arguments, {'ticket': 91});
      expect(identical(pending, exit(host)), isTrue);
    },
  );
  test('invalid native ticket is rejected without closeReady', () async {
    final host = await WindowsPlaybackHost.create();
    await host.close();
    returnedTicket = 0;
    await expectLater(exit(host), throwsStateError);
    expect(methods().contains('closeReady'), isFalse);
  });
  test('drained failed startup detach requires completed host close', () async {
    final host = await WindowsPlaybackHost.create();
    await expectLater(host.detachDrainedFailedStartup(), throwsStateError);
    await host.close();
    final detached = host.detachDrainedFailedStartup();
    await detached;
    expect(identical(detached, host.detachDrainedFailedStartup()), isTrue);
    expect(methods(), ['create', 'retire', 'detachDrainedFailedStartup']);
  });
  test(
    'ClientShutdown plus real host waits Stop Stores authority before ticket',
    () async {
      final host = await WindowsPlaybackHost.create();
      final stopped = Completer<void>(),
          stores = Completer<void>(),
          authority = Completer<void>();
      final order = <String>[];
      final shutdown = ClientShutdown(
        freezeBusiness: () => order.add('freeze'),
        retireBookkeeping: () async {},
        stopAndRelease: () async {
          await stopped.future;
          order.add('stop');
        },
        closeLearning: () async {
          await stores.future;
          order.add('learning');
        },
        closeMaterials: () async {
          order.add('materials');
        },
        afterStoresClosed: () async {
          await authority.future;
          order.add('authority');
        },
        closeHost: () async {
          await host.close();
          order.add('host');
        },
        exitApplication: () async {
          expect(order, [
            'freeze',
            'stop',
            'learning',
            'materials',
            'authority',
            'host',
          ]);
          await exit(host);
        },
      );
      final closing = shutdown.requestExit();
      await tick();
      expect(methods(), ['create']);
      stopped.complete();
      await tick();
      expect(methods(), ['create']);
      stores.complete();
      await tick();
      expect(methods(), ['create']);
      authority.complete();
      await closing;
      expect(methods(), [
        'create',
        'retire',
        'beginProgrammaticClose',
        'closeReady',
      ]);
    },
  );
  test(
    'closed flag before event stream completion does not authorize exit',
    () async {
      final host = await WindowsPlaybackHost.create();
      final listener = host.events.listen((_) {})..pause();
      final closing = host.close();
      await tick();
      await expectLater(exit(host), throwsStateError);
      expect(methods(), ['create', 'retire']);
      listener.resume();
      await closing;
      await exit(host);
      await listener.cancel();
    },
  );
  test('known close_post_failed allows only a later explicit retry', () async {
    final host = await WindowsPlaybackHost.create();
    await host.close();
    ackFailure = PlatformException(code: 'close_post_failed');
    final failed = exit(host);
    await expectLater(
      failed,
      throwsA(
        isA<PlatformException>().having(
          (e) => e.code,
          'code',
          'close_post_failed',
        ),
      ),
    );
    await tick();
    expect(methods().where((m) => m == 'beginProgrammaticClose').length, 1);
    ackFailure = null;
    returnedTicket = 38;
    final retried = exit(host);
    expect(identical(failed, retried), isFalse);
    await retried;
    expect(calls.last.arguments, {'ticket': 38});
    await expectLater(failed, throwsA(isA<PlatformException>()));
    expect(methods().where((m) => m == 'beginProgrammaticClose').length, 2);
  });
  test('unknown closeReady failure remains cached and never retries', () async {
    final host = await WindowsPlaybackHost.create();
    await host.close();
    ackFailure = PlatformException(code: 'channel_error');
    final failed = exit(host);
    await expectLater(failed, throwsA(isA<PlatformException>()));
    ackFailure = null;
    expect(identical(failed, exit(host)), isTrue);
    await expectLater(exit(host), throwsA(isA<PlatformException>()));
    expect(methods().where((m) => m == 'beginProgrammaticClose').length, 1);
  });
  test(
    'pending closeReady survives timeout and parallel calls without repost',
    () async {
      final host = await WindowsPlaybackHost.create();
      await host.close();
      ackGate = Completer<void>();
      final pending = exit(host);
      await tick();
      await expectLater(
        pending.timeout(Duration.zero),
        throwsA(isA<TimeoutException>()),
      );
      expect(identical(pending, exit(host)), isTrue);
      expect(methods().where((m) => m == 'closeReady').length, 1);
      ackGate!.complete();
      await pending;
    },
  );
  for (final failing in [
    'stop',
    'learning',
    'materials',
    'authority',
    'host',
  ]) {
    test(
      'ClientShutdown $failing failure sends no begin or closeReady',
      () async {
        final host = await WindowsPlaybackHost.create();
        Future<void> stage(String name) async {
          if (failing == name) throw StateError('controlled_$name');
        }

        final shutdown = ClientShutdown(
          freezeBusiness: () {},
          retireBookkeeping: () async {},
          stopAndRelease: () => stage('stop'),
          closeLearning: () => stage('learning'),
          closeMaterials: () => stage('materials'),
          afterStoresClosed: () => stage('authority'),
          closeHost: () async {
            await stage('host');
            await host.close();
          },
          exitApplication: () => exit(host),
        );
        await expectLater(shutdown.requestExit(), throwsStateError);
        expect(methods(), ['create']);
        await host.close();
      },
    );
  }
}
