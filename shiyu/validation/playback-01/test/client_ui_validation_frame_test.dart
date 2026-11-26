import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shiyu_playback_probe/client_application.dart';
import 'package:shiyu_playback_probe/client_startup_retention.dart';
import 'package:shiyu_playback_probe/client_ui_validation_frame.dart';
import 'package:shiyu_playback_probe/client_ui_validation_root.dart';
import 'package:shiyu_playback_probe/client_ui_validation_session.dart';
import 'package:shiyu_playback_probe/client_ui_wire.dart';

import 'client_ui_wire_root_test.dart'
    show FixtureUiSource, vector, fixtureArgs;
import 'client_ui_validation_session_test.dart' as pure;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('shiyu/windows_playback_host');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  Directory? base;
  ClientApplicationOwner? owner;
  var fixtureDisposed = false;
  setUpAll(() async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'create') {
        return {
          'configured': true,
          'startupBindAttempted': true,
          'startupBindSucceeded': true,
          'startupBindStage': 'bound',
          'startupBindHresult': 0,
          'startupBindErrorKnown': false,
        };
      }
      if (call.method == 'beginProgrammaticClose') return {'ticket': 37};
      if (call.method == 'hostStatus') {
        return {
          'configured': true,
          'windowAlive': true,
          'windowVisible': true,
          'windowFocused': true,
          'foreground': false,
          'genericMetadata': true,
          'metadataCleared': true,
          'playbackStatus': 'stopped',
          'enabled': false,
          'suspended': false,
        };
      }
      return null; // Native calls are all fake; no COM/SMTC/MediaKit initialization.
    });
    base = await Directory.systemTemp.createTemp('ui-headless-owned-');
    owner = await ClientApplicationOwner.open(
      root: Directory('${base!.path}/profile'),
      startupAttempt: ClientStartupAttempt(
        validationOnly: true,
        resident: ClientStartupResident(),
      ),
      silentValidation: true,
    );
  });
  tearDownAll(() async {
    final target = owner;
    if (target != null && !fixtureDisposed) {
      target.retireCommands();
      await target.playback.dispose();
      await target.engine.native.dispose();
      if (target.rootLock.isHeld) await target.shutdown.drainStores();
      await target.host.close();
    }
    messenger.setMockMethodCallHandler(channel, null);
    if (base != null && target != null && !target.rootLock.isHeld) {
      expect(
        base!.absolute.path.startsWith(Directory.systemTemp.absolute.path),
        true,
      );
      await base!.delete(recursive: true);
    }
  });
  testWidgets('error/loading page cannot replace actual owner Shell Frame', (
    tester,
  ) async {
    final source = FixtureUiSource(vector('nativeReadonlyProof'));
    final plan = ClientUiRootPlan.decode(
      uiCanonical(source.proof),
      fixtureArgs(),
      vector('c0')['appPid'] as int,
    );
    final lines = <List<int>>[];
    final session = ClientUiValidationSession(
      plan,
      source,
      'isolates/headless',
      phaseWriter: (v) async {
        lines.add(v);
      },
    );
    await session.attachOwner(pure.Owner(plan.profilePath));
    await tester.pumpWidget(
      ClientUiFrameObserver(
        session: session,
        child: const MaterialApp(home: Text('Startup error')),
      ),
    );
    await tester.pump();
    expect(lines, isEmpty);
    expect(session.phase, 'owner-ready');
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'real empty Shell renders band then actual owner barrier close with fake native',
    (tester) async {
      final target = owner!;
      final source = FixtureUiSource(vector('nativeReadonlyProof'));
      final plan = ClientUiRootPlan.decode(
        uiCanonical(source.proof),
        fixtureArgs(),
        vector('c0')['appPid'] as int,
      );
      final lines = <List<int>>[];
      final session = ClientUiValidationSession(
        plan,
        source,
        'isolates/headless',
        phaseWriter: (v) async {
          lines.add(v);
        },
      );
      await session.attachOwner(target);
      target.bindUiValidation(session);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 600);
      addTearDown(() {
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
      });
      await tester.pumpWidget(
        ClientUiFrameObserver(
          session: session,
          child: ShiyuLocalClient(owner: target),
        ),
      );
      for (var i = 0; i < 20 && session.phase != 'shell-frame-ready'; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(session.phase, 'shell-frame-ready');
      expect(lines.length, 1);
      final phase = jsonDecode(
        ascii.decode(lines.single).substring(uiPhasePrefix.length),
      ) as Map;
      final proof = phase['proof'] as Map;
      expect(proof['bandLeft'], 0);
      expect(proof['bandWidth'], 800);
      expect(proof['shellMounted'], true);
      expect(find.text('学习'), findsWidgets);
      expect(find.text('材料'), findsWidgets);
      expect(find.text('添加'), findsWidgets);
      final digest = pure.grant(session, source, 1);
      final close = session.handle('ext.shiyu.validation.close', {
        'contextHash': session.contextHash!,
        'seq': '1',
        'phase': 'close',
        'grantSha256': digest,
      });
      await tester.pump();
      await close;
      var ownerExitReturned = false;
      Object? exitError;
      session.acceptedOwnerExit!
          .then<void>(
            (_) {
              ownerExitReturned = true;
            },
            onError: (Object error, StackTrace _) {
              exitError = error;
              ownerExitReturned = true;
            },
          )
          .ignore();
      for (var i = 0; i < 50 && !ownerExitReturned; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(
        ownerExitReturned,
        isTrue,
        reason: 'actual owner Future must settle, not just A release',
      );
      expect(exitError, isNull);
      expect(target.storage.writersDrained, true);
      expect(target.storage.storesClosed, true);
      expect(target.rootLock.isHeld, false);
      expect(lines.length, 2);
      expect(session.phase, 'native-closing');
      await tester.pumpWidget(const SizedBox.shrink());
      // Dispose the real fixture while its widget clock is still serviced.
      // Stream close callbacks created by the Shell may belong to this zone.
      var disposed = false;
      Object? disposeError;
      Future<void>(() async {
            target.retireCommands();
            await target.playback.dispose();
            await target.engine.native.dispose();
            await target.host.close();
          })
          .then<void>(
            (_) {
              disposed = true;
            },
            onError: (Object error, StackTrace _) {
              disposeError = error;
              disposed = true;
            },
          )
          .ignore();
      for (var i = 0; i < 50 && !disposed; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(disposed, isTrue, reason: 'fixture disposal must settle');
      expect(disposeError, isNull);
      fixtureDisposed = true;
    },
  );
}
