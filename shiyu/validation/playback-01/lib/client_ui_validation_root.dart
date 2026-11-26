import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'client_ui_wire.dart';

const uiReadonlyKeys = {
  'protocol',
  'c0',
  'workspacePath',
  'basePath',
  'runPath',
  'profilePath',
  'workspaceIdentity',
  'baseIdentity',
  'runIdentity',
  'stdoutIdentity',
  'stderrIdentity',
  'ownerSid',
  'cwdMatches',
  'plain',
  'private',
  'profileAbsent',
  'anchorRawBase64',
  'intentRawBase64',
  'nativeGateLineRawBase64',
};
const uiAnchorKeys = {
  'protocol',
  'purpose',
  'ownerSid',
  'workspacePath',
  'basePath',
  'workspaceIdentity',
  'baseIdentity',
  'sourceSha256',
  'bundleSha256',
  'commonSha256',
};
const uiIntentKeys = {
  'protocol',
  'role',
  'runId',
  'attempt',
  'desktopNonce',
  'ownerSid',
  'workspaceIdentity',
  'baseIdentity',
  'runIdentity',
  'profileLeaf',
  'stdoutIdentity',
  'stderrIdentity',
  'anchorSha256',
  'imageSha256',
  'bundleSha256',
  'commonSha256',
};
const uiNativeGateKeys = {
  'nativeTid',
  'desktopName',
  'station',
  'grantedAccess',
  'intentSha256',
  'workspaceIdentity',
  'baseIdentity',
  'runIdentity',
  'stdoutIdentity',
  'stderrIdentity',
};

final class ClientUiArguments {
  ClientUiArguments(this.runId, this.attempt, this.desktopNonce);
  final String runId, attempt, desktopNonce;
  static bool intended(List<String> args) => args.any(
    (a) =>
        a.startsWith('--shiyu-ui') ||
        a.startsWith('--background-regression') ||
        a.startsWith('--silent-validation'),
  );
  static ClientUiArguments? parse(
    List<String> args, {
    required bool debug,
    required bool windows,
    required bool validationOnly,
  }) {
    if (!validationOnly && !intended(args)) return null;
    uiNeed(validationOnly && debug && windows && args.length == 5, 'entry');
    String one(String key) {
      final values = args.where((a) => a.startsWith('--$key=')).toList();
      uiNeed(values.length == 1, 'argument');
      return values.single.substring(key.length + 3);
    }

    uiNeed(
      one('shiyu-ui-validation') == 'ordinary-empty-ui' &&
          one('shiyu-ui-silent') == 'true',
      'mode',
    );
    final run = one('shiyu-ui-run'),
        attempt = one('shiyu-ui-attempt'),
        desktop = one('shiyu-ui-desktop');
    uiNeed(
      RegExp(r'^ui-[0-9a-f]{8}$').hasMatch(run) &&
          RegExp(r'^[0-9a-f]{32}$').hasMatch(attempt) &&
          RegExp(r'^ShiyuIso_[0-9a-f]{32}$').hasMatch(desktop),
      'ids',
    );
    return ClientUiArguments(run, attempt, desktop);
  }
}

abstract interface class ClientUiProofSource {
  String get currentDirectory;
  Future<String> startupProof();
  Future<String> closeGrantProof();
  Future<bool> sameDirectory(String a, String b);
  Future<bool> absent(String path);
  Future<List<int>> read(String path, int limit);
}

final class ClientUiNativeProofSource implements ClientUiProofSource {
  const ClientUiNativeProofSource();
  static const channel = MethodChannel('shiyu/windows_playback_host');
  @override
  String get currentDirectory => Directory.current.path;
  @override
  Future<String> startupProof() async {
    final value = await channel.invokeMethod<String>('startupValidationProof');
    uiNeed(value != null, 'native-proof');
    return value!;
  }

  @override
  Future<String> closeGrantProof() async {
    final value = await channel.invokeMethod<String>(
      'startupValidationCloseGrantProof',
    );
    uiNeed(value != null, 'native-grant');
    return value!;
  }

  @override
  Future<bool> sameDirectory(String a, String b) =>
      FileSystemEntity.identical(a, b);
  @override
  Future<bool> absent(String path) async =>
      await FileSystemEntity.type(path, followLinks: false) ==
      FileSystemEntityType.notFound;
  @override
  Future<List<int>> read(String path, int limit) async {
    uiNeed(
      await FileSystemEntity.type(path, followLinks: false) ==
          FileSystemEntityType.file,
      'file-type',
    );
    final file = File(path);
    uiNeed(await file.length() <= limit, 'file-bound');
    final bytes = await file
        .openRead(0, limit + 1)
        .fold<List<int>>([], (a, b) => a..addAll(b));
    uiNeed(bytes.length <= limit, 'file-growth');
    return bytes;
  }
}

String _join(String parent, String leaf) =>
    '${parent.endsWith(r'\') ? parent.substring(0, parent.length - 1) : parent}\\$leaf';
void _physical(Object? path) {
  uiNeed(
    path is String &&
        RegExp(r'^[a-zA-Z]:\\').hasMatch(path) &&
        !path.contains('/') &&
        !path.contains('\\..\\') &&
        !path.contains('\\.\\') &&
        path.codeUnits.every((c) => c >= 32) &&
        (path.length == 3 || !path.endsWith(r'\')),
    'physical-path',
  );
}

bool _starts(List<int> bytes, List<int> prefix) =>
    bytes.length >= prefix.length &&
    List.generate(prefix.length, (i) => bytes[i] == prefix[i]).every((v) => v);

Iterable<List<int>> _lines(List<int> bytes) sync* {
  var start = 0;
  for (var n = 0; n < bytes.length; n++) {
    if (bytes[n] != 10) continue;
    yield bytes.sublist(start, n + 1);
    start = n + 1;
  }
  if (start < bytes.length) yield bytes.sublist(start);
}

final class ClientUiRootPlan {
  ClientUiRootPlan._(
    this.arguments,
    this.c0,
    this.metadata,
    this.anchorBytes,
    this.intentBytes,
    this.gateLine,
  );
  final ClientUiArguments arguments;
  final Map<String, Object?> c0, metadata;
  final List<int> anchorBytes, intentBytes, gateLine;
  String get profilePath => metadata['profilePath'] as String;
  String get basePath => metadata['basePath'] as String;
  String get runPath => metadata['runPath'] as String;
  String get rootScope => c0['rootScope'] as String;
  String get gateSha => uiSha(gateLine);
  static String worstCache(String root) => _join(
    _join(_join(root, 'playable-cache'), 'f' * 64),
    '${'e' * 32}-${'d' * 32}.wav.next',
  );

  static bool pathBudgetAllowed(String root) =>
      root.length <= 104 && worstCache(root).length <= 259;

  static ClientUiRootPlan decode(
    String raw,
    ClientUiArguments args,
    int ownPid,
  ) {
    final m = uiObject(
      uiDecode(ascii.encode(raw), limit: 32768),
      uiReadonlyKeys,
    );
    uiNeed(m['protocol'] == 1 && m['protocol'] is int, 'proof-protocol');
    for (final key in ['cwdMatches', 'plain', 'private', 'profileAbsent']) {
      uiNeed(m[key] is bool && m[key] == true, 'proof-$key');
    }
    for (final key in ['workspacePath', 'basePath', 'runPath', 'profilePath']) {
      _physical(m[key]);
    }
    uiNeed(
      m['basePath'] == _join(m['workspacePath'] as String, '.ui-runs') &&
          m['runPath'] == _join(m['basePath'] as String, args.runId) &&
          m['profilePath'] == _join(m['runPath'] as String, 'profile'),
      'fixed-domain',
    );
    final profile = m['profilePath'] as String;
    uiNeed(pathBudgetAllowed(profile), 'legacy-path-bound');
    for (final key in [
      'workspaceIdentity',
      'baseIdentity',
      'runIdentity',
      'stdoutIdentity',
      'stderrIdentity',
    ]) {
      uiNeed(uiIdentity(m[key]), 'identity');
    }
    uiNeed(
      m['ownerSid'] is String &&
          RegExp(r'^S-1-[0-9]+(?:-[0-9]+)+$').hasMatch(m['ownerSid'] as String),
      'owner-sid',
    );
    final c = uiObject(m['c0'], uiContext0Keys);
    uiCheckContext0(c);
    uiNeed(
      c['runId'] == args.runId &&
          c['attempt'] == args.attempt &&
          c['desktopNonce'] == args.desktopNonce &&
          c['appPid'] == ownPid,
      'self-context',
    );
    final anchorBytes = uiBase64(m['anchorRawBase64'], 2048),
        intentBytes = uiBase64(m['intentRawBase64'], 8192),
        line = uiBase64(m['nativeGateLineRawBase64'], 4096);
    final anchor = uiObject(
      uiDecode(anchorBytes, limit: 2048, lf: true),
      uiAnchorKeys,
    );
    final intent = uiObject(
      uiDecode(intentBytes, limit: 8192, lf: true),
      uiIntentKeys,
    );
    uiNeed(
      anchor['protocol'] == 1 &&
          anchor['purpose'] == 'ordinary-empty-ui-anchor' &&
          intent['protocol'] == 1 &&
          intent['role'] == 'ordinary-empty-ui' &&
          intent['profileLeaf'] == 'profile',
      'anchor-intent',
    );
    for (final key in ['ownerSid', 'workspaceIdentity', 'baseIdentity']) {
      uiNeed(anchor[key] == m[key] && intent[key] == m[key], 'binding-$key');
    }
    for (final key in ['workspacePath', 'basePath']) {
      uiNeed(anchor[key] == m[key], 'anchor-path');
    }
    for (final key in ['runIdentity', 'stdoutIdentity', 'stderrIdentity']) {
      uiNeed(intent[key] == m[key], 'run-binding');
    }
    for (final key in [
      'runId',
      'attempt',
      'desktopNonce',
      'imageSha256',
      'bundleSha256',
    ]) {
      uiNeed(intent[key] == c[key], 'intent-context');
    }
    for (final key in ['sourceSha256', 'bundleSha256', 'commonSha256']) {
      uiNeed(uiHash(anchor[key]), 'anchor-hash');
    }
    uiNeed(
      intent['anchorSha256'] == uiSha(anchorBytes) &&
          intent['commonSha256'] == anchor['commonSha256'] &&
          intent['bundleSha256'] == anchor['bundleSha256'],
      'intent-hashes',
    );
    final expectedScope = uiSha(
      uiBytes([
        'ordinary-empty-scope:1',
        m['ownerSid'],
        m['workspaceIdentity'],
        m['baseIdentity'],
        m['runIdentity'],
        profile,
        args.attempt,
      ]),
    );
    uiNeed(c['rootScope'] == expectedScope, 'scope');
    final prefix = ascii.encode(uiPhasePrefix);
    uiNeed(_starts(line, prefix), 'native-prefix');
    final phase = uiObject(
      uiDecode(line.sublist(prefix.length), limit: 4096, lf: true),
      {'phase', 'context', 'proof'},
    );
    uiNeed(
      phase['phase'] == 'native-gate-accepted' &&
          uiCanonical(phase['context']) == uiCanonical(c),
      'native-context',
    );
    final proof = uiObject(phase['proof'], uiNativeGateKeys);
    final access = proof['grantedAccess'];
    uiNeed(
      uiInt(proof['nativeTid'], positive: true) &&
          access is int &&
          (access & 0x83) == 0x83 &&
          (access & ~0x20087) == 0 &&
          proof['station'] == 'WinSta0' &&
          proof['desktopName'] == args.desktopNonce &&
          proof['intentSha256'] == uiSha(intentBytes),
      'native-proof',
    );
    for (final key in [
      'workspaceIdentity',
      'baseIdentity',
      'runIdentity',
      'stdoutIdentity',
      'stderrIdentity',
    ]) {
      uiNeed(proof[key] == m[key], 'native-file');
    }
    return ClientUiRootPlan._(args, c, m, anchorBytes, intentBytes, line);
  }

  static Future<ClientUiRootPlan> guard(
    ClientUiArguments args,
    ClientUiProofSource source, {
    required int ownPid,
  }) async {
    final first = decode(await source.startupProof(), args, ownPid);
    uiNeed(
      await source.sameDirectory(source.currentDirectory, first.basePath),
      'cwd-identity',
    );
    uiNeed(await source.absent(first.profilePath), 'profile-exists');
    final a = await source.read(_join(first.basePath, 'anchor.m'), 2048),
        i = await source.read(_join(first.runPath, 'intent.json'), 8192),
        stdout = await source.read(_join(first.runPath, 'stdout.log'), 262144),
        stderr = await source.read(_join(first.runPath, 'stderr.log'), 262144);
    uiNeed(
      uiSha(a) == uiSha(first.anchorBytes) &&
          uiSha(i) == uiSha(first.intentBytes),
      'independent-bytes',
    );
    // These bounded byte snapshots complement the native pinned-identity proof;
    // they do not atomically pin either path or observe future writes. Native
    // proof/parent readers retain identity and terminal-log authority.
    final namespace = ascii.encode('SHIYU_UI_');
    final phasePrefix = ascii.encode(uiPhasePrefix);
    for (final line in _lines(stderr)) {
      // Native diagnostics belong on stderr. Any identifiable protocol on this
      // stream (full, malformed or partial) cannot grant resource admission.
      uiNeed(!_starts(line, namespace), 'stderr-protocol');
    }
    var matched = 0, protocolBytes = 0;
    final seen = <String>{};
    var start = 0;
    for (var n = 0; n < stdout.length; n++) {
      if (stdout[n] != 10) continue;
      final line = stdout.sublist(start, n + 1);
      start = n + 1;
      if (!_starts(line, namespace)) continue;
      // A failure marker rejects regardless of schema or error code. Unknown
      // and malformed namespace lines are likewise never ordinary log bytes.
      uiNeed(_starts(line, phasePrefix), 'stdout-protocol');
      protocolBytes += line.length;
      uiNeed(line.length <= 4096 && protocolBytes <= 65536, 'protocol-bound');
      final record = uiObject(
        uiDecode(line.sublist(uiPhasePrefix.length), limit: 4096, lf: true),
        {'phase', 'context', 'proof'},
      );
      uiNeed(
        uiCanonical(record['context']) == uiCanonical(first.c0) &&
            seen.add(record['phase'] as String),
        'prefix-context-duplicate',
      );
      if (record['phase'] == 'native-gate-accepted') {
        uiNeed(uiSha(line) == first.gateSha, 'original-native-line');
        matched++;
      } else {
        uiNeed(
          seen.contains('native-gate-accepted') &&
              record['phase'] == 'native-window-created',
          'early-phase',
        );
        final w = uiObject(record['proof'], {
          'mainHwnd',
          'mainTid',
          'windowClass',
        });
        uiNeed(
          uiInt(w['mainHwnd'], positive: true) &&
              uiInt(w['mainTid'], positive: true) &&
              w['windowClass'] == 'FLUTTER_RUNNER_WIN32_WINDOW',
          'window-proof',
        );
      }
    }
    // An identifiable unterminated protocol tail is pending, never readiness.
    // This one-shot pre-resource guard rejects instead of waiting/admitting.
    uiNeed(!_starts(stdout.sublist(start), namespace), 'partial-protocol');
    uiNeed(matched == 1, 'missing-original-proof');
    final again = decode(await source.startupProof(), args, ownPid);
    uiNeed(
      uiCanonical(first.metadata) == uiCanonical(again.metadata),
      'proof-changed',
    );
    uiNeed(
      await source.sameDirectory(source.currentDirectory, first.basePath) &&
          await source.absent(first.profilePath),
      'adjacent-fresh',
    );
    return first;
  }
}
