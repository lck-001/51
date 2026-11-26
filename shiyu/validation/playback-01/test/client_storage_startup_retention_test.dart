import 'dart:io';
import 'dart:async';

import 'package:learning_core/learning_core.dart';
import 'package:agent_bridge/agent_bridge.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiyu_playback_probe/client_private_storage.dart';
import 'package:shiyu_playback_probe/client_startup_retention.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final explicitToken in [false, true]) {
    test(
      'real Learning failure preserves ${explicitToken ? 'explicit carrier' : 'standalone original error and stack'} after safe cleanup',
      () async {
        final parent = Zone.current;
        final base = await Directory.systemTemp.createTemp(
          'startup-compat-owned-',
        );
        final root = Directory('${base.path}/profile');
        final token = ClientStartupAttempt(resident: ClientStartupResident());
        Object? observed;
        StackTrace? observedStack;
        try {
          await IOOverrides.runZoned(
            () async {
              try {
                await ClientPrivateStorage.open(
                  root: root,
                  proxyCommand: [],
                  startupAttempt: explicitToken ? token : null,
                );
              } catch (error, stack) {
                observed = error;
                observedStack = stack;
              }
            },
            fseGetType: (path, follow) {
              if (path.replaceAll('\\', '/').contains('/learning/')) {
                throw FileSystemException('synthetic Learning startup');
              }
              return parent.run(
                () => FileSystemEntity.type(path, followLinks: follow),
              );
            },
          );
          if (explicitToken) {
            expect(observed, isA<RetainedStartupFailure>());
            final carrier = observed! as RetainedStartupFailure;
            expect(identical(carrier.token, token), isTrue);
            expect(carrier.primaryError, isA<LearningStoreException>());
            expect(
              token
                  .retained<LearningRootLock>(ClientStartupRef.rootLock)!
                  .isHeld,
              isFalse,
            );
            expect(
              token.resourcesEnded,
              isFalse,
              reason: 'upper owner still owns token handoff',
            );
            expect(token.cleanupFailed, isFalse);
            expect(token.hasPending, isFalse);
            expect(
              carrier.primaryStack.toString(),
              contains('FileLearningStore.open'),
            );
            token.releasedAfterCleanup(); // isolated test acts as the upper owner
          } else {
            expect(observed, isA<LearningStoreException>());
            expect(
              observedStack.toString(),
              contains('FileLearningStore.open'),
            );
          }
          final renamed = await root.rename('${root.path}-closed');
          expect(
            await File('${renamed.path}/client-security.marker').exists(),
            isTrue,
            reason:
                'safe close does not reset the existing failed-startup profile',
          );
        } finally {
          expect(
            base.absolute.path.startsWith(Directory.systemTemp.absolute.path),
            isTrue,
          );
          await base.delete(recursive: true);
        }
      },
    );
  }
  test('second real storage open keeps original rootBusy classification and first A', () async {
    final base = await Directory.systemTemp.createTemp(
      'ordinary-startup-owned-',
    );
    final root = Directory('${base.path}/profile');
    final first = await ClientPrivateStorage.open(
      root: root,
      proxyCommand: ['absent-proxy-not-started.exe'],
    );
    try {
      final slot = ClientStartupResident();
      final token = ClientStartupAttempt(resident: slot);
      try {
        await ClientPrivateStorage.open(
          root: root,
          proxyCommand: ['absent-proxy-not-started.exe'],
          startupAttempt: token,
        );
        fail('second root opened');
      } on RetainedStartupFailure catch (error) {
        expect(identical(error.token, token), isTrue);
        expect(error.isRootBusy, isTrue);
        expect(token.retained(ClientStartupRef.lease), isNull);
      }
      expect(first.rootLock.isHeld, isTrue);
      await first.drainWriters();
      await first.closeStoresAndAuthority();
      final reopened = await ClientPrivateStorage.open(
        root: root,
        proxyCommand: ['absent-proxy-not-started.exe'],
      );
      expect(reopened.rootLock.isHeld, isTrue);
      await reopened.drainWriters();
      await reopened.closeStoresAndAuthority();
    } finally {
      if (first.rootLock.isHeld) {
        await first.drainWriters();
        await first.closeStoresAndAuthority();
      }
      expect(
        base.absolute.path.startsWith(Directory.systemTemp.absolute.path),
        isTrue,
      );
      await base.delete(recursive: true);
    }
  });
}
