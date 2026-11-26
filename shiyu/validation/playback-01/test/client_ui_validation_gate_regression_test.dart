import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiyu_playback_probe/client_ui_validation_root.dart';

import 'client_ui_wire_root_test.dart'
    show FixtureUiSource, vector, fixtureArgs;
import 'client_ui_validation_session_test.dart' as session_fixture;

class GateLogSource extends FixtureUiSource {
  GateLogSource() : super(vector('nativeReadonlyProof'));
  List<int> stderrBytes = [];
  @override
  Future<List<int>> read(String path, int limit) async {
    if (path.endsWith('stderr.log')) return stderrBytes;
    return super.read(path, limit);
  }
}

void main() {
  test('legacy case-sensitive prefixes reject before normal resources on either platform', () {
    for (final windows in [true, false]) {
      for (final flag in [
        '--silent-validation',
        '--silent-validation=true',
        '--silent-validation-tail',
        '--background-regression',
        '--background-regression=true',
        '--background-regression-tail',
      ]) {
        var normalResources = 0;
        expect(
          () {
            final result = ClientUiArguments.parse(
              [flag],
              debug: true,
              windows: windows,
              validationOnly: false,
            );
            if (result == null) {
              normalResources++; // main's KnownFolder/MediaKit branch
            }
          },
          throwsFormatException,
          reason: '$windows $flag',
        );
        expect(normalResources, 0);
      }
      expect(
        ClientUiArguments.parse(
          [],
          debug: true,
          windows: windows,
          validationOnly: false,
        ),
        isNull,
      );
      expect(
        ClientUiArguments.parse(
          ['--ordinary-user-option'],
          debug: true,
          windows: windows,
          validationOnly: false,
        ),
        isNull,
      );
    }
  });
  test('full malformed zero and identifiable partial diagnostics reject in both logs', () async {
    for (final stderr in [false, true]) {
      for (final suffix in [
        'SHIYU_UI_FAILURE {"api":"native-startup","win32Code":5}\n',
        'SHIYU_UI_FAILURE {"api":"native-startup","win32Code":0}\n',
        'SHIYU_UI_FAILURE malformed\n',
        'SHIYU_UI_FAILURE {"api":',
        'SHIYU_UI_FAILURE',
        'SHIYU_UI_F',
        'SHIYU_UI_',
        'SHIYU_UI_PHASE {',
        'SHIYU_UI_PHASE malformed\n',
      ]) {
        final source = GateLogSource();
        final original = await source.read('stdout.log', 262144);
        if (stderr) {
          source.stderrBytes = ascii.encode(suffix);
        } else {
          source.stdoutOverride = [...original, ...ascii.encode(suffix)];
        }
        var admitted = 0;
        await expectLater(
          ClientUiRootPlan.guard(
            fixtureArgs(),
            source,
            ownPid: vector('c0')['appPid'] as int,
          ).then((_) {
            admitted++;
          }),
          throwsFormatException,
          reason: '$stderr $suffix',
        );
        expect(admitted, 0);
      }
    }
  });
  test(
    'ordinary stdout and stderr including short tails remain admissible',
    () async {
      final source = GateLogSource();
      final original = await source.read('stdout.log', 262144);
      source.stdoutOverride = [
        ...original,
        ...utf8.encode('ordinary Flutter line\nS'),
      ];
      source.stderrBytes = utf8.encode('ordinary diagnostic\nS');
      expect(
        await ClientUiRootPlan.guard(
          fixtureArgs(),
          source,
          ownPid: vector('c0')['appPid'] as int,
        ),
        isNotNull,
      );
    },
  );
  test('native failure marker after valid raw gate rejects before resource admission', () async {
    final source = FixtureUiSource(vector('nativeReadonlyProof'));
    final original = await source.read('stdout.log', 262144);
    source.stdoutOverride = [
      ...original,
      ...ascii.encode(
        'SHIYU_UI_FAILURE {"api":"native-startup","win32Code":5}\n',
      ),
    ];
    var admitted = 0;
    await expectLater(
      ClientUiRootPlan.guard(
        fixtureArgs(),
        source,
        ownPid: vector('c0')['appPid'] as int,
      ).then((_) {
        admitted++;
      }),
      throwsA(isA<FormatException>()),
    );
    expect(admitted, 0);
  });

  test(
    'accepted owner close that actually fails remains failed without retry',
    () async {
      final (session, source, owner) = await session_fixture.ready();
      final digest = session_fixture.grant(session, source, 1);
      final reply = await session.handle('ext.shiyu.validation.close', {
        'contextHash': session.contextHash!,
        'seq': '1',
        'phase': 'close',
        'grantSha256': digest,
      });
      expect(reply['facts'], {'accepted': true});
      expect(owner.closes, 1);
      final observed = expectLater(
        session.acceptedOwnerExit!,
        throwsStateError,
      );
      owner.closeDone.completeError(StateError('actual drain failed'));
      await observed;
      await Future<void>.delayed(Duration.zero);
      expect(session.phase, 'failed');
      await expectLater(
        session.handle('ext.shiyu.validation.close', {
          'contextHash': session.contextHash!,
          'seq': '2',
          'phase': 'close',
          'grantSha256': digest,
        }),
        throwsA(anything),
      );
      expect(owner.closes, 1);
    },
  );
}
