import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter_test/flutter_test.dart';
import 'package:shiyu_playback_probe/client_ui_validation_session.dart';

import 'client_ui_validation_session_test.dart' as fixture;

Map<String, developer.ServiceExtensionHandler> registered(
  ClientUiValidationSession session,
) {
  final handlers = <String, developer.ServiceExtensionHandler>{};
  session.register(
    registerWith: (method, handler) {
      expect(handlers.containsKey(method), false);
      handlers[method] = handler;
    },
  );
  expect(handlers.keys.toSet(), {
    'ext.shiyu.validation.status',
    'ext.shiyu.validation.close',
  });
  return handlers;
}

void main() {
  test(
    'actual registered callback accepts SDK route key and keeps raw map',
    () async {
      final (session, _, owner) = await fixture.ready();
      final callbacks = registered(session);
      final raw = {
        'isolateId': session.mainIsolateId,
        'contextHash': session.contextHash!,
        'seq': '1',
        'phase': 'observe',
      };
      final original = Map<String, String>.from(raw);
      final response = await callbacks['ext.shiyu.validation.status']!(
        'ext.shiyu.validation.status',
        raw,
      );
      expect(response.isError(), false);
      final result = jsonDecode(response.result!) as Map;
      expect(result['seq'], 1);
      expect((result['facts'] as Map)['g1Held'], true);
      expect(session.phase, 'observing');
      expect(raw, original);
      expect(owner.closes, 0);
    },
  );

  test('registered missing or wrong isolate rejects sticky', () async {
    for (final route in <String?>[null, 'isolates/old']) {
      final (session, _, owner) = await fixture.ready();
      final callbacks = registered(session);
      final raw = {
        if (route != null) 'isolateId': route,
        'contextHash': session.contextHash!,
        'seq': '1',
        'phase': 'observe',
      };
      final rejected = await callbacks['ext.shiyu.validation.status']!(
        'ext.shiyu.validation.status',
        raw,
      );
      expect(rejected.isError(), true);
      expect(session.phase, 'failed');
      final late = await callbacks['ext.shiyu.validation.status']!(
        'ext.shiyu.validation.status',
        {...raw, 'isolateId': session.mainIsolateId},
      );
      expect(late.isError(), true);
      expect(owner.closes, 0);
    }
  });

  test('registered route removes no unknown business fields', () async {
    final (session, _, owner) = await fixture.ready();
    final callbacks = registered(session);
    final response = await callbacks['ext.shiyu.validation.status']!(
      'ext.shiyu.validation.status',
      {
        'isolateId': session.mainIsolateId,
        'contextHash': session.contextHash!,
        'seq': '1',
        'phase': 'observe',
        'observerDone': 'true',
      },
    );
    expect(response.isError(), true);
    expect(session.phase, 'failed');
    expect(owner.closes, 0);
  });

  test('direct business handler still rejects a transport key', () async {
    final (session, _, owner) = await fixture.ready();
    await expectLater(
      session.handle('ext.shiyu.validation.status', {
        'isolateId': session.mainIsolateId,
        'contextHash': session.contextHash!,
        'seq': '1',
        'phase': 'observe',
      }),
      throwsA(isA<FormatException>()),
    );
    expect(owner.closes, 0);
  });

  test(
    'registered close keeps grant gate and consumes shutdown only once',
    () async {
      final (session, source, owner) = await fixture.ready();
      final callbacks = registered(session);
      final raw = {
        'isolateId': session.mainIsolateId,
        'contextHash': session.contextHash!,
        'seq': '1',
        'phase': 'close',
        'grantSha256': fixture.grant(session, source, 1),
      };
      final response = await callbacks['ext.shiyu.validation.close']!(
        'ext.shiyu.validation.close',
        raw,
      );
      expect(response.isError(), false);
      expect((jsonDecode(response.result!) as Map)['facts'], {
        'accepted': true,
      });
      expect(owner.closes, 1);
      final repeated = await callbacks['ext.shiyu.validation.close']!(
        'ext.shiyu.validation.close',
        raw,
      );
      expect(repeated.isError(), true);
      expect(owner.closes, 1);
      owner.closeDone.complete();
    },
  );
}
