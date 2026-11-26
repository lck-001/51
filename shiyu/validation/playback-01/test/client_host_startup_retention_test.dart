import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyu_playback_probe/client_startup_retention.dart';
import 'package:shiyu_playback_probe/playback/windows_playback_host.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('shiyu/windows_playback_host');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final success = <String, Object?>{
    'configured': true,
    'startupBindAttempted': true,
    'startupBindSucceeded': true,
    'startupBindStage': 'bound',
    'startupBindHresult': 0,
    'startupBindErrorKnown': false,
  };
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('factory retains original create and local host before timeout, closes only after actual settle', () async {
    final calls = <String>[], gate = Completer<Map<String, Object?>>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'create') return gate.future;
      if (call.method == 'retire') return null;
      throw StateError('unexpected fake method');
    });
    final slot = ClientStartupResident();
    final token = ClientStartupAttempt(resident: slot, validationOnly: true);
    final create = WindowsPlaybackHost.create(startupAttempt: token);
    await expectLater(create, throwsA(isA<RetainedStartupFailure>()));
    final partial = token.retained<WindowsPlaybackHost>(ClientStartupRef.host);
    expect(partial, isNotNull);
    expect(token.hasPending, isTrue);
    expect(identical(slot.current, token), isTrue);
    expect(calls, ['create']);
    var originalSettled = false;
    final settle = token
        .operationSettled(ClientStartupOperation.hostNativeCreate)
        .then((_) {
          originalSettled = true;
        });
    await Future<void>.delayed(Duration.zero);
    expect(originalSettled, isFalse);
    gate.complete(success);
    await settle;
    await token.cleanup(ClientStartupCleanup.closeHost, partial!.close);
    expect(calls, ['create', 'retire']);
    expect(token.failed, isTrue);
    token.releasedAfterCleanup();
    expect(slot.current, isNull);
  });

  test(
    'known unsupported is not promoted to validation Owner startup',
    () async {
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => call.method == 'create' ? {'configured': false} : null,
      );
      final slot = ClientStartupResident();
      final token = ClientStartupAttempt(resident: slot, validationOnly: true);
      await expectLater(
        WindowsPlaybackHost.create(startupAttempt: token),
        throwsA(isA<RetainedStartupFailure>()),
      );
      final partial = token.retained<WindowsPlaybackHost>(
        ClientStartupRef.host,
      )!;
      await token.cleanup(ClientStartupCleanup.closeHost, partial.close);
      token.releasedAfterCleanup();
      expect(token.failed, isTrue);
      expect(slot.current, isNull);
    },
  );

  test(
    'failed original Host close stays same Future and resources retained',
    () async {
      var retireCount = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'create') return success;
        if (call.method == 'retire') {
          retireCount++;
          throw PlatformException(code: 'synthetic-close-failed');
        }
        return null;
      });
      final token = ClientStartupAttempt(resident: ClientStartupResident());
      final host = await WindowsPlaybackHost.create(startupAttempt: token);
      token.fail(StateError('after host returned'), StackTrace.current);
      final first = token.cleanup(ClientStartupCleanup.closeHost, host.close);
      await expectLater(first, throwsA(isA<PlatformException>()));
      await expectLater(
        token.cleanup(ClientStartupCleanup.closeHost, host.close),
        throwsA(isA<PlatformException>()),
      );
      expect(retireCount, 1);
      expect(token.retains(ClientStartupRef.host, host), isTrue);
      expect(() => token.releasedAfterCleanup(), throwsStateError);
    },
  );
}
