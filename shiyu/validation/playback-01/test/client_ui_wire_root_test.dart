import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiyu_playback_probe/client_ui_wire.dart';
import 'package:shiyu_playback_probe/client_ui_validation_root.dart';

Map<String, dynamic> vectors() =>
    (jsonDecode(
          File('test/fixtures/startup_validation_wire_v1.json')
              .readAsStringSync(),
        ) as Map)['vectors']
        as Map<String, dynamic>;
Map<String, Object?> vector(String name) =>
    Map<String, Object?>.from((vectors()[name] as Map)['value'] as Map);
ClientUiArguments fixtureArgs() {
  final c = vector('c0');
  return ClientUiArguments(
    c['runId'] as String,
    c['attempt'] as String,
    c['desktopNonce'] as String,
  );
}

class FixtureUiSource implements ClientUiProofSource {
  FixtureUiSource(this.proof);
  Map<String, Object?> proof;
  bool fresh = true, same = true;
  int proofCalls = 0;
  String? grantResponse;
  List<int>? stdoutOverride;
  @override
  String get currentDirectory => proof['basePath'] as String;
  @override
  Future<String> startupProof() async {
    proofCalls++;
    return uiCanonical(proof);
  }

  @override
  Future<String> closeGrantProof() async => grantResponse!;
  @override
  Future<bool> sameDirectory(String a, String b) async => same;
  @override
  Future<bool> absent(String path) async => fresh;
  @override
  Future<List<int>> read(String path, int limit) async {
    if (path.endsWith('anchor.m')) {
      return uiBase64(proof['anchorRawBase64'], 2048);
    }
    if (path.endsWith('intent.json')) {
      return uiBase64(proof['intentRawBase64'], 8192);
    }
    if (path.endsWith('stderr.log')) return [];
    return stdoutOverride ??
        [
          ...utf8.encode('ordinary Flutter private line\n'),
          ...uiBase64(proof['nativeGateLineRawBase64'], 4096),
        ];
  }
}

void main() {
  test('all canonical shared vectors retain exact LF bytes and hashes', () {
    final data = vectors();
    for (final entry in data.entries) {
      final m = entry.value as Map;
      if (m.containsKey('fileAscii') &&
          !entry.key.toLowerCase().contains('failure')) {
        final expected = m['fileAscii'] as String;
        final bytes = <int>[
          if (expected.startsWith(uiPhasePrefix))
            ...ascii.encode(uiPhasePrefix),
          ...uiBytes(m['value'], lf: true),
        ];
        expect(ascii.decode(bytes), expected, reason: entry.key);
        expect(uiSha(bytes), m['fileSha256'], reason: entry.key);
        expect(
          uiSha(uiBytes(m['value'])),
          m['canonicalSha256'],
          reason: entry.key,
        );
      }
    }
  });
  test('codec rejects duplicate keys doubles exponent negativezero and lone surrogate', () {
    for (final text in [
      '{"a":1,"a":1}',
      '{"a":1.0}',
      '{"a":1e0}',
      '{"a":-0}',
    ]) {
      expect(
        () => uiDecode(ascii.encode(text), limit: 100),
        throwsA(isA<FormatException>()),
      );
    }
    expect(
      () => uiCanonical(String.fromCharCode(0xd800)),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => uiCanonical(uiWireMaxInt + 1),
      throwsA(isA<FormatException>()),
    );
  });
  test(
    'validation-only and legacy intention never fall through normal profile',
    () {
      final c = vector('c0');
      final good = [
        '--shiyu-ui-validation=ordinary-empty-ui',
        '--shiyu-ui-run=${c['runId']}',
        '--shiyu-ui-attempt=${c['attempt']}',
        '--shiyu-ui-desktop=${c['desktopNonce']}',
        '--shiyu-ui-silent=true',
      ];
      expect(
        ClientUiArguments.parse(
          good,
          debug: true,
          windows: true,
          validationOnly: true,
        ),
        isNotNull,
      );
      expect(
        ClientUiArguments.parse(
          [],
          debug: true,
          windows: true,
          validationOnly: false,
        ),
        isNull,
      );
      for (final args in [
        <String>[],
        good.sublist(1),
        [...good, '--root=C:/other'],
        ['--background-regression'],
        ['--silent-validation'],
      ]) {
        expect(
          () => ClientUiArguments.parse(
            args,
            debug: true,
            windows: true,
            validationOnly: true,
          ),
          throwsA(isA<FormatException>()),
        );
      }
      expect(
        () => ClientUiArguments.parse(
          good,
          debug: false,
          windows: true,
          validationOnly: true,
        ),
        throwsFormatException,
      );
      expect(
        () => ClientUiArguments.parse(
          good,
          debug: true,
          windows: false,
          validationOnly: true,
        ),
        throwsFormatException,
      );
      expect(
        () => ClientUiArguments.parse(
          good,
          debug: true,
          windows: true,
          validationOnly: false,
        ),
        throwsFormatException,
      );
    },
  );
  test('actual raw native prefix and independently read files guard the fresh plan', () async {
    final source = FixtureUiSource(vector('nativeReadonlyProof'));
    final plan = await ClientUiRootPlan.guard(
      fixtureArgs(),
      source,
      ownPid: vector('c0')['appPid'] as int,
    );
    expect(source.proofCalls, 2);
    expect(plan.rootScope, vector('c0')['rootScope']);
    expect(plan.profilePath.length, lessThanOrEqualTo(104));
    expect(
      ClientUiRootPlan.worstCache(plan.profilePath).length,
      lessThanOrEqualTo(259),
    );
  });
  test('cwd identity profile reentry wrong self and changed raw bytes reject before resources', () async {
    final pid = vector('c0')['appPid'] as int;
    for (final kind in ['cwd', 'fresh', 'pid', 'raw']) {
      final source = FixtureUiSource(vector('nativeReadonlyProof'));
      if (kind == 'cwd') source.same = false;
      if (kind == 'fresh') source.fresh = false;
      if (kind == 'raw') {
        source.stdoutOverride = utf8.encode('SHIYU_UI_PHASE {}\n');
      }
      var resourceCalls = 0;
      await expectLater(
        ClientUiRootPlan.guard(
          fixtureArgs(),
          source,
          ownPid: kind == 'pid' ? pid + 1 : pid,
        ).then((_) {
          resourceCalls++;
        }),
        throwsA(anything),
      );
      expect(resourceCalls, 0);
    }
  });
  test('partial duplicated or reencoded native gate is not proof', () async {
    final source = FixtureUiSource(vector('nativeReadonlyProof'));
    final raw = uiBase64(source.proof['nativeGateLineRawBase64'], 4096);
    for (final bytes in [
      raw.sublist(0, raw.length - 1),
      [...raw, ...raw],
      utf8.encode('$uiPhasePrefix{"phase":"native-gate-accepted"}\n'),
    ]) {
      source.stdoutOverride = bytes;
      await expectLater(
        ClientUiRootPlan.guard(
          fixtureArgs(),
          source,
          ownPid: vector('c0')['appPid'] as int,
        ),
        throwsA(anything),
      );
    }
  });
  test('UTF16 root104 and105 budgets do not use alias byte length', () {
    expect(ClientUiRootPlan.pathBudgetAllowed('x' * 104), isTrue);
    expect(ClientUiRootPlan.pathBudgetAllowed('x' * 105), isFalse);
    expect(ClientUiRootPlan.pathBudgetAllowed('${'x' * 102}😀'), isTrue);
    expect(ClientUiRootPlan.pathBudgetAllowed('${'x' * 103}😀'), isFalse);
  });
}
