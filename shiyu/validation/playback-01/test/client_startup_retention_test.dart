import 'dart:async';

import 'package:agent_bridge/agent_bridge_contracts.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyu_playback_probe/client_startup_retention.dart';

void main() {
  test('same attempt carries inner refs and first rootBusy unchanged', () {
    final slot = ClientStartupResident();
    final token = ClientStartupAttempt(id: 'synthetic', resident: slot);
    final root = Object(), material = Object();
    token.retain(ClientStartupRef.rootLock, root);
    token.retain(ClientStartupRef.materials, material);
    final first = const AgentBridgeException(AgentBridgeErrorCode.rootBusy);
    final failure = token.fail(first, StackTrace.current);
    final outer = token.fail(failure, StackTrace.current);
    expect(identical(outer.token, token), isTrue);
    expect(identical(outer.primaryError, first), isTrue);
    expect(outer.isRootBusy, isTrue);
    expect(token.retains(ClientStartupRef.rootLock, root), isTrue);
    expect(token.retains(ClientStartupRef.materials, material), isTrue);
    expect(identical(slot.current, token), isTrue);
  });

  test('cleanup synchronous reentry cannot invoke second action', () async {
    final token = ClientStartupAttempt(resident: ClientStartupResident());
    var calls = 0;
    final first = token.cleanup(ClientStartupCleanup.closeMaterials, () {
      calls++;
      token.cleanup(ClientStartupCleanup.closeMaterials, () {
        calls++;
      });
    });
    await expectLater(first, throwsStateError);
    final same = token.cleanup(ClientStartupCleanup.closeMaterials, () {
      calls++;
    });
    expect(identical(first, same), isTrue);
    await expectLater(same, throwsStateError);
    expect(calls, 1);
    expect(token.cleanupFailed, isTrue);
  });

  test(
    'pending original survives caller timeout and cleanup starts once',
    () async {
      final token = ClientStartupAttempt(resident: ClientStartupResident());
      final reference = Object(), gate = Completer<void>();
      token.retain(ClientStartupRef.host, reference);
      final original = gate.future;
      expect(
        identical(
          token.observe(ClientStartupOperation.hostNativeCreate, original),
          original,
        ),
        isTrue,
      );
      await expectLater(
        original.timeout(Duration.zero),
        throwsA(isA<TimeoutException>()),
      );
      token.fail(StateError('synthetic startup'), StackTrace.current);
      expect(token.hasPending, isTrue);
      expect(token.retains(ClientStartupRef.host, reference), isTrue);
      var calls = 0;
      final cleanup = token.cleanup(ClientStartupCleanup.closeHost, () async {
        calls++;
        await token.operationSettled(ClientStartupOperation.hostNativeCreate);
      });
      expect(
        identical(
          token.cleanup(ClientStartupCleanup.closeHost, () {
            calls++;
          }),
          cleanup,
        ),
        isTrue,
      );
      gate.complete();
      await cleanup;
      expect(calls, 1);
      expect(
        token.failed,
        isTrue,
      ); // Late native completion is not startup success.
      expect(token.hasPending, isFalse);
    },
  );

  test('failed cleanup keeps same refs and never retries', () async {
    final token = ClientStartupAttempt(resident: ClientStartupResident());
    final lease = Object();
    token.retain(ClientStartupRef.lease, lease);
    token.fail(StateError('primary'), StackTrace.current);
    var calls = 0;
    final first = token.cleanup(ClientStartupCleanup.releaseAuthority, () {
      calls++;
      throw StateError('cleanup');
    });
    await expectLater(first, throwsStateError);
    await expectLater(
      token.cleanup(ClientStartupCleanup.releaseAuthority, () {
        calls++;
      }),
      throwsStateError,
    );
    expect(calls, 1);
    expect(token.retains(ClientStartupRef.lease, lease), isTrue);
    expect(() => token.releasedAfterCleanup(), throwsStateError);
    expect(token.snapshot()['cleanupFailed'], isTrue);
  });

  test('handoff waits original owner factory settlement', () async {
    final token = ClientStartupAttempt(resident: ClientStartupResident());
    final owner = Object(), returned = Completer<Object>();
    token.retain(ClientStartupRef.owner, owner);
    token.observe(ClientStartupOperation.ownerOpen, returned.future);
    token.handoff(ClientStartupRef.owner, owner);
    expect(token.retains(ClientStartupRef.owner, owner), isTrue);
    returned.complete(owner);
    await returned.future;
    await Future<void>.delayed(Duration.zero);
    expect(token.resourcesEnded, isTrue);
    expect(token.retains(ClientStartupRef.owner, owner), isFalse);
  });

  test('confirmed release can finish after failed owner future, without replacing failure', () async {
    final slot = ClientStartupResident();
    final token = ClientStartupAttempt(resident: slot);
    final pending = Completer<void>();
    token.observe(ClientStartupOperation.ownerOpen, pending.future);
    token.fail(StateError('first'), StackTrace.current);
    token.releasedAfterCleanup();
    expect(token.resourcesEnded, isFalse);
    pending.completeError(StateError('late'));
    await expectLater(pending.future, throwsStateError);
    await Future<void>.delayed(Duration.zero);
    expect(token.resourcesEnded, isTrue);
    expect(token.failed, isTrue);
    expect(slot.current, isNull);
  });

  test('different attempt cannot consume carrier or resident slot', () {
    final slot = ClientStartupResident();
    final one = ClientStartupAttempt(resident: slot),
        two = ClientStartupAttempt(resident: slot);
    final failure = one.fail(StateError('one'), StackTrace.current);
    expect(() => two.fail(failure, StackTrace.current), throwsStateError);
    expect(() => slot.retain(two), throwsStateError);
    expect(identical(slot.current, one), isTrue);
  });
  test(
    'handoff followed by failed UI setup retains that same complete Owner',
    () {
      final slot = ClientStartupResident(), owner = Object();
      final token = ClientStartupAttempt(resident: slot);
      token.retain(ClientStartupRef.owner, owner);
      token.handoff(ClientStartupRef.owner, owner);
      expect(token.resourcesEnded, isTrue);
      token.fail(StateError('synthetic UI setup'), StackTrace.current);
      expect(token.retains(ClientStartupRef.owner, owner), isTrue);
      expect(token.resourcesEnded, isFalse);
      expect(identical(slot.current, token), isTrue);
    },
  );
  test('static MediaKit fact cannot be mislabeled released or admit another startup', () {
    final slot = ClientStartupResident();
    final token = ClientStartupAttempt(resident: slot);
    token.mediaLibraryAttempted = true;
    token.mediaLibraryReturned = true;
    token.fail(StateError('synthetic'), StackTrace.current);
    token.releasedAfterCleanup();
    expect(token.snapshot()['mediaLibraryReleaseVerified'], isFalse);
    expect(token.snapshot()['unknown'], isTrue);
    expect(identical(slot.current, token), isTrue);
    expect(() => ClientStartupAttempt(resident: slot), throwsStateError);
  });
}
