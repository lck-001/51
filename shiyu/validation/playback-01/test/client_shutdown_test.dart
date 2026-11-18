import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:shiyu_playback_probe/client_command_barrier.dart';
import 'package:shiyu_playback_probe/client_shutdown.dart';

class ControlledClose {
  final events = <String>[];
  int freezes = 0, retirements = 0, stops = 0, learnings = 0;
  int materials = 0, hosts = 0, exits = 0;
  bool failStop = false, failMaterial = false, failExit = false;
  bool failRetirement = false, failHost = false;
  Completer<void>? retirementGate, learningGate, stopGate;

  late final sequence = ClientShutdown(
    freezeBusiness: () {
      freezes++;
      events.add('freeze');
    },
    retireBookkeeping: () async {
      retirements++;
      if (failRetirement) throw StateError('controlled-retirement-failure');
      await retirementGate?.future;
      events.add('retired');
    },
    stopAndRelease: () async {
      stops++;
      await stopGate?.future;
      if (failStop) throw StateError('controlled-stop-failure');
      events.add('stopped-and-released');
    },
    closeLearning: () async {
      learnings++;
      await learningGate?.future;
      events.add('learning-drained');
    },
    closeMaterials: () async {
      materials++;
      if (failMaterial) throw StateError('controlled-material-failure');
      events.add('materials-drained');
    },
    closeHost: () async {
      hosts++;
      if (failHost) throw StateError('controlled-host-failure');
      events.add('host-closed');
    },
    exitApplication: () async {
      exits++;
      if (failExit) throw StateError('controlled-exit-failure');
      events.add('exited');
    },
  );
}

Future<void> microtasks() => Future<void>.delayed(Duration.zero);

void main() {
  test('failed stop can retry while business stays retired', () async {
    final c = ControlledClose()..failStop = true;
    await expectLater(c.sequence.requestExit(), throwsStateError);
    expect(c.exits, 0);
    c.failStop = false;
    await c.sequence.requestExit();
    expect(c.freezes, 1);
    expect(c.retirements, 1);
    expect(c.stops, 2);
    expect(c.exits, 1);
  });

  test('retry skips stores whose non-idempotent close succeeded', () async {
    final c = ControlledClose()..failMaterial = true;
    await expectLater(c.sequence.requestExit(), throwsStateError);
    expect(c.learnings, 1);
    expect(c.exits, 0);
    c.failMaterial = false;
    await c.sequence.requestExit();
    expect(c.learnings, 1);
    expect(c.materials, 2);
    expect(c.hosts, 1);
    expect(c.exits, 1);
  });

  test(
    'Windows drain awaits bookkeeping and actual queued store work',
    () async {
      final c = ControlledClose()
        ..retirementGate = Completer<void>()
        ..learningGate = Completer<void>();
      var releaseReached = false;
      final closeReady = () async {
        await c.sequence.drainStores();
        releaseReached = true;
      }();
      final duplicateDrain = c.sequence.drainStores();
      await microtasks();
      expect(c.learnings, 0);
      expect(releaseReached, isFalse);
      c.retirementGate!.complete();
      await microtasks();
      expect(c.learnings, 1);
      expect(c.materials, 0);
      expect(releaseReached, isFalse);
      c.learningGate!.complete();
      await Future.wait([closeReady, duplicateDrain]);
      expect(releaseReached, isTrue);
      expect(c.learnings, 1);
      expect(c.materials, 1);
      expect(c.events, [
        'freeze',
        'retired',
        'learning-drained',
        'materials-drained',
      ]);
    },
  );

  test('parallel exit does not duplicate cleanup or exit', () async {
    final c = ControlledClose()..stopGate = Completer<void>();
    final first = c.sequence.requestExit();
    await microtasks();
    await c.sequence.requestExit();
    expect(c.stops, 1);
    expect(c.exits, 0);
    c.stopGate!.complete();
    await first;
    expect(c.exits, 1);
  });

  test(
    'failed platform exit retries without closing host/stores twice',
    () async {
      final c = ControlledClose()..failExit = true;
      await expectLater(c.sequence.requestExit(), throwsStateError);
      c.failExit = false;
      await c.sequence.requestExit();
      expect(c.learnings, 1);
      expect(c.materials, 1);
      expect(c.hosts, 1);
      expect(c.exits, 2);
      expect(c.freezes, 1);
    },
  );

  test(
    'retirement failure cannot be converted into a successful exit',
    () async {
      final c = ControlledClose()..failRetirement = true;
      await expectLater(c.sequence.requestExit(), throwsStateError);
      await expectLater(c.sequence.requestExit(), throwsStateError);
      expect(c.freezes, 1);
      expect(c.stops, 2);
      expect(c.exits, 0);
    },
  );

  test('pending bookkeeping still permits safety Stop before drain', () async {
    final c = ControlledClose()..retirementGate = Completer<void>();
    final closing = c.sequence.requestExit();
    await microtasks();
    try {
      expect(c.stops, 1);
      expect(c.learnings, 0);
      expect(c.hosts, 0);
      expect(c.exits, 0);
    } finally {
      c.retirementGate!.complete();
      await closing;
    }
    expect(c.learnings, 1);
    expect(c.exits, 1);
  });

  test(
    'failed host close is not mistaken for closed on second attempt',
    () async {
      final c = ControlledClose()..failHost = true;
      await expectLater(c.sequence.requestExit(), throwsStateError);
      await expectLater(c.sequence.requestExit(), throwsStateError);
      expect(c.hosts, 1);
      expect(c.learnings, 1);
      expect(c.materials, 1);
      expect(c.exits, 0);
    },
  );

  testWidgets('retired barrier blocks pointer, keyboard and semantic actions', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final focus = FocusNode();
    var frozen = false, saves = 0;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (_, setState) {
              update = setState;
              return ClientCommandBarrier(
                frozen: frozen,
                child: FilledButton(
                  focusNode: focus,
                  autofocus: true,
                  onPressed: () {
                    saves++;
                  },
                  child: const Text('保存材料'),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(focus.hasFocus, isTrue);
    expect(find.semantics.byLabel('保存材料'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(saves, 1);
    update(() {
      frozen = true;
    });
    await tester.pumpAndSettle();
    expect(focus.hasFocus, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.tap(find.text('保存材料'), warnIfMissed: false);
    await tester.pump();
    expect(saves, 1);
    expect(find.semantics.byLabel('保存材料'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    focus.dispose();
    semantics.dispose();
  });
}
