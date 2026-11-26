import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiyu_playback_probe/client_ui_wire.dart';
import 'package:shiyu_playback_probe/client_ui_validation_root.dart';
import 'package:shiyu_playback_probe/client_ui_validation_session.dart';

import 'client_ui_wire_root_test.dart'
    show vector, fixtureArgs, FixtureUiSource;

class Owner implements ClientUiOwner {
  Owner(this.uiRootPath);
  @override
  final String uiRootPath;
  @override
  bool get uiRootHeld => true;
  @override
  String get uiTrustedOwnerId => 'local-device-only';
  int closes = 0;
  final closeDone = Completer<void>();
  @override
  Future<Map<String, Object?>> uiActualFacts() async => {
    'g1Held': true,
    'learningCount': 0,
    'materialCount': 0,
    'hasSelection': false,
    'hasSource': false,
  };
  @override
  Future<void> uiRequestExit() {
    closes++;
    return closeDone.future;
  }
}

class PendingGrantSource extends FixtureUiSource {
  PendingGrantSource() : super(vector('nativeReadonlyProof'));
  final pendingGrant = Completer<String>();
  @override
  Future<String> closeGrantProof() => pendingGrant.future;
}

const frame = {
  'frameCount': 1,
  'viewportWidth': 800,
  'viewportHeight': 600,
  'dprMilli': 1000,
  'bandLeft': 0,
  'bandTop': 0,
  'bandWidth': 800,
  'bandHeight': 30,
};
Future<(ClientUiValidationSession, FixtureUiSource, Owner)> ready({
  FixtureUiSource? proofSource,
}) async {
  final source = proofSource ?? FixtureUiSource(vector('nativeReadonlyProof'));
  final plan = ClientUiRootPlan.decode(
    uiCanonical(source.proof),
    fixtureArgs(),
    vector('c0')['appPid'] as int,
  );
  final owner = Owner(plan.profilePath);
  final session = ClientUiValidationSession(
    plan,
    source,
    'isolates/main',
    phaseWriter: (_) async {},
  );
  await session.attachOwner(owner);
  await session.frame(frame, shellMounted: true, loading: false);
  return (session, source, owner);
}

String grant(
  ClientUiValidationSession session,
  FixtureUiSource source,
  int seq, {
  Map<String, Object?>? override,
}) {
  final record = {
    ...vector('closeGrant'),
    'context': session.context,
    'contextHash': session.contextHash,
    'seq': seq,
    ...?override,
  };
  final raw = uiBytes(record, lf: true);
  source.grantResponse = uiCanonical({
    ...vector('nativeReadonlyGrant'),
    'rawBase64': base64.encode(raw),
  });
  return uiSha(raw);
}

void main() {
  test('status only real ready owner facts full method context seq', () async {
    final (session, _, owner) = await ready();
    final result = await session.handle('ext.shiyu.validation.status', {
      'contextHash': session.contextHash!,
      'seq': '1',
      'phase': 'observe',
    });
    expect(result['method'], 'ext.shiyu.validation.status');
    expect(result['seq'], 1);
    final facts = result['facts'] as Map;
    expect(facts['ownerReady'], true);
    expect(facts['g1Held'], true);
    expect(facts['materialCount'], 0);
    expect(facts['bandWidth'], 800);
    expect(owner.closes, 0);
  });
  test('early owner/frame close never creates shutdown authority', () async {
    final source = FixtureUiSource(vector('nativeReadonlyProof'));
    final plan = ClientUiRootPlan.decode(
      uiCanonical(source.proof),
      fixtureArgs(),
      vector('c0')['appPid'] as int,
    );
    final session = ClientUiValidationSession(
      plan,
      source,
      'isolates/main',
      phaseWriter: (_) async {},
    );
    await expectLater(
      session.handle('ext.shiyu.validation.close', {
        'contextHash': 'a' * 64,
        'seq': '1',
        'phase': 'close',
        'grantSha256': 'b' * 64,
      }),
      throwsA(anything),
    );
    expect(session.phase, 'failed');
  });
  test('valid grant consumes once accepted never means completed', () async {
    final (session, source, owner) = await ready();
    final digest = grant(session, source, 1);
    final result = await session.handle('ext.shiyu.validation.close', {
      'contextHash': session.contextHash!,
      'seq': '1',
      'phase': 'close',
      'grantSha256': digest,
    });
    expect(result['facts'], {'accepted': true});
    expect(owner.closes, 1);
    await expectLater(
      session.handle('ext.shiyu.validation.close', {
        'contextHash': session.contextHash!,
        'seq': '1',
        'phase': 'close',
        'grantSha256': digest,
      }),
      throwsA(anything),
    );
    expect(owner.closes, 1);
    owner.closeDone.complete();
  });
  test(
    'unknown fields wrong context phase malformed or skipped seq sticky reject',
    () async {
      for (final wrong in [
        {'observerDone': 'true'},
        {'contextHash': '0' * 64},
        {'phase': 'close'},
        {'seq': '2'},
        {'seq': '01'},
        {'seq': '1.0'},
      ]) {
        final (session, _, owner) = await ready();
        await expectLater(
          session.handle('ext.shiyu.validation.status', {
            'contextHash': session.contextHash!,
            'seq': '1',
            'phase': 'observe',
            ...wrong,
          }),
          throwsA(anything),
        );
        expect(session.phase, 'failed');
        expect(owner.closes, 0);
        await expectLater(
          session.handle('ext.shiyu.validation.status', {
            'contextHash': session.contextHash!,
            'seq': '1',
            'phase': 'observe',
          }),
          throwsA(anything),
        );
      }
    },
  );
  test('old grant scope cannot trigger owner exit', () async {
    final (session, source, owner) = await ready();
    grant(session, source, 1, override: {'contextHash': '0' * 64});
    final decoded =
        uiDecode(ascii.encode(source.grantResponse!), limit: 16384) as Map;
    final digest = uiSha(uiBase64(decoded['rawBase64'], 4096));
    await expectLater(
      session.handle('ext.shiyu.validation.close', {
        'contextHash': session.contextHash!,
        'seq': '1',
        'phase': 'close',
        'grantSha256': digest,
      }),
      throwsA(anything),
    );
    expect(owner.closes, 0);
    expect(session.phase, 'failed');
  });
  test(
    'concurrent RPC invalidates pending grant and late proof cannot exit',
    () async {
      final source = PendingGrantSource();
      final (session, _, owner) = await ready(proofSource: source);
      final digest = grant(session, source, 1);
      final pending = session.handle('ext.shiyu.validation.close', {
        'contextHash': session.contextHash!,
        'seq': '1',
        'phase': 'close',
        'grantSha256': digest,
      });
      final rejected = expectLater(pending, throwsA(anything));
      await expectLater(
        session.handle('ext.shiyu.validation.status', {
          'contextHash': session.contextHash!,
          'seq': '1',
          'phase': 'observe',
        }),
        throwsA(anything),
      );
      expect(owner.closes, 0);
      expect(session.acceptedOwnerExit, isNull);
      source.pendingGrant.complete(source.grantResponse!);
      await rejected;
      expect(owner.closes, 0);
      expect(session.acceptedOwnerExit, isNull);
      expect(session.phase, 'failed');
    },
  );
  test(
    'drain proof requires close admission and all actual barriers',
    () async {
      final (session, _, owner) = await ready();
      await expectLater(
        session.ownerDrained(
          stopped: true,
          storesDrained: true,
          storesClosed: true,
          released: true,
        ),
        throwsA(anything),
      );
      expect(owner.closes, 0);
    },
  );
}
