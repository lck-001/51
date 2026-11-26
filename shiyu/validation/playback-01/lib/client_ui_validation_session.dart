import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'client_ui_wire.dart';
import 'client_ui_validation_root.dart';

abstract interface class ClientUiOwner {
  String get uiTrustedOwnerId;
  bool get uiRootHeld;
  String get uiRootPath;
  Future<Map<String, Object?>> uiActualFacts();
  Future<void> uiRequestExit();
}

const _frameKeys = {
  'frameCount',
  'viewportWidth',
  'viewportHeight',
  'dprMilli',
  'bandLeft',
  'bandTop',
  'bandWidth',
  'bandHeight',
};
const _statusKeys = {
  'ownerReady',
  'g1Held',
  'loading',
  'learningCount',
  'materialCount',
  'hasSelection',
  'hasSource',
  ..._frameKeys,
};

final class ClientUiValidationSession {
  ClientUiValidationSession(
    this.plan,
    this.source,
    this.mainIsolateId, {
    Future<void> Function(List<int>)? phaseWriter,
  }) : _phaseWriter = phaseWriter ?? _stdoutPhase {
    uiNeed(mainIsolateId.isNotEmpty, 'isolate');
  }
  final ClientUiRootPlan plan;
  final ClientUiProofSource source;
  final String mainIsolateId;
  final Future<void> Function(List<int>) _phaseWriter;
  ClientUiOwner? _owner;
  Map<String, Object?>? _context, _frame;
  String _phase = 'guarded';
  int _seq = 1;
  bool _failed = false,
      _busy = false,
      _closeStarted = false,
      _readyWritten = false,
      _loading = true;
  Future<void>? _closeFuture;
  String? _grantId;
  Future<void>? get acceptedOwnerExit => _closeFuture;
  String get phase => _failed ? 'failed' : _phase;
  String? get contextHash => _context == null ? null : uiSha(uiBytes(_context));
  Map<String, Object?>? get context =>
      _context == null ? null : Map.unmodifiable(_context!);
  static Future<void> _stdoutPhase(List<int> bytes) async {
    // Kept here to avoid a general output/command interface; real implementation is injected only by entry.
    throw StateError('validation phase writer not bound');
  }

  void fail() {
    _failed = true;
  }

  Future<void> attachOwner(ClientUiOwner owner) async {
    uiNeed(!_failed && _owner == null && _phase == 'guarded', 'owner-phase');
    uiNeed(
      owner.uiRootHeld &&
          await source.sameDirectory(owner.uiRootPath, plan.profilePath),
      'owner-root',
    );
    final scope = uiSha(uiBytes([plan.rootScope, owner.uiTrustedOwnerId]));
    _owner = owner;
    _context = {
      ...plan.c0,
      'ownerScope': scope,
      'mainIsolateId': mainIsolateId,
    };
    _phase = 'owner-ready';
  }

  Future<void> frame(
    Map<String, Object?> measurement, {
    required bool shellMounted,
    required bool loading,
  }) async {
    if (_failed || _closeStarted) return;
    uiNeed(_owner != null && shellMounted, 'actual-shell');
    uiObject(measurement, _frameKeys);
    for (final key in _frameKeys) {
      uiNeed(
        uiInt(
          measurement[key],
          positive: {
            'frameCount',
            'viewportWidth',
            'viewportHeight',
            'dprMilli',
          }.contains(key),
        ),
        'frame-integer',
      );
    }
    _frame = Map.of(measurement);
    _loading = loading;
    if (loading || _readyWritten) return;
    final facts = await _owner!.uiActualFacts();
    uiNeed(
      !_failed &&
          facts['g1Held'] == true &&
          facts['learningCount'] == 0 &&
          facts['materialCount'] == 0 &&
          facts['hasSelection'] == false &&
          facts['hasSource'] == false,
      'empty-owner',
    );
    _phase = 'shell-frame-ready';
    _readyWritten = true;
    await _emit('ordinary-shell-frame-ready', {
      'nativeGateLineSha256': plan.gateSha,
      'ownerScope': _context!['ownerScope'],
      'rootMatches': true,
      'g1Held': true,
      'shellMounted': true,
      'frameRendered': true,
      'silent': true,
      ...measurement,
    });
  }

  Future<void> _emit(String name, Map<String, Object?> proof) => _phaseWriter([
    ...ascii.encode(uiPhasePrefix),
    ...uiBytes({'phase': name, 'context': plan.c0, 'proof': proof}, lf: true),
  ]);

  void register() {
    for (final method in [
      'ext.shiyu.validation.status',
      'ext.shiyu.validation.close',
    ]) {
      developer.registerExtension(method, (method, parameters) async {
        try {
          return developer.ServiceExtensionResponse.result(
            uiCanonical(await handle(method, parameters)),
          );
        } catch (_) {
          fail();
          return developer.ServiceExtensionResponse.error(
            developer.ServiceExtensionResponse.extensionError,
            'ui_validation_rejected',
          );
        }
      });
    }
  }

  Future<Map<String, Object?>> handle(
    String method,
    Map<String, String> parameters,
  ) async {
    if (_busy) {
      fail();
      uiReject('rpc-concurrent');
    }
    _busy = true;
    try {
      final close = method == 'ext.shiyu.validation.close';
      uiNeed(close || method == 'ext.shiyu.validation.status', 'rpc-method');
      uiObject(
        parameters,
        close
            ? {'contextHash', 'seq', 'phase', 'grantSha256'}
            : {'contextHash', 'seq', 'phase'},
      );
      uiNeed(
        !_failed &&
            _owner != null &&
            _readyWritten &&
            {'shell-frame-ready', 'observing'}.contains(_phase),
        'rpc-phase',
      );
      uiNeed(
        parameters['contextHash'] == contextHash &&
            parameters['phase'] == (close ? 'close' : 'observe'),
        'rpc-context',
      );
      final rawSeq = parameters['seq'];
      uiNeed(uiDecimal(rawSeq) && rawSeq!.length <= 16, 'rpc-seq');
      final seq = int.tryParse(rawSeq!);
      uiNeed(uiInt(seq, positive: true) && seq == _seq, 'rpc-seq');
      Map<String, Object?> facts;
      if (close) {
        uiNeed(
          uiHash(parameters['grantSha256']) && !_closeStarted,
          'close-admission',
        );
        final grantProof = uiObject(
          uiDecode(ascii.encode(await source.closeGrantProof()), limit: 16384),
          {
            'protocol',
            'attempt',
            'rootScope',
            'runIdentity',
            'fileIdentity',
            'plain',
            'private',
            'ownerMatches',
            'rawBase64',
          },
        );
        uiNeed(
          grantProof['protocol'] == 1 &&
              grantProof['attempt'] == plan.arguments.attempt &&
              grantProof['rootScope'] == plan.rootScope &&
              grantProof['runIdentity'] == plan.metadata['runIdentity'] &&
              uiIdentity(grantProof['fileIdentity']) &&
              grantProof['plain'] == true &&
              grantProof['private'] == true &&
              grantProof['ownerMatches'] == true,
          'grant-domain',
        );
        final raw = uiBase64(grantProof['rawBase64'], 4096);
        uiNeed(uiSha(raw) == parameters['grantSha256'], 'grant-digest');
        final grant = uiObject(uiDecode(raw, limit: 4096, lf: true), {
          'protocol',
          'role',
          'context',
          'contextHash',
          'grantId',
          'seq',
          'phase',
          'observerReceiptSha256',
        });
        uiNeed(
          grant['protocol'] == 1 &&
              grant['role'] == 'ordinary-empty-ui' &&
              uiCanonical(grant['context']) == uiCanonical(_context) &&
              grant['contextHash'] == contextHash &&
              grant['seq'] == seq &&
              grant['phase'] == 'close' &&
              uiHash(grant['observerReceiptSha256']) &&
              grant['grantId'] is String &&
              RegExp(r'^[0-9a-f]{32}$').hasMatch(grant['grantId'] as String),
          'grant-record',
        );
        // No await between final admission check, consumption and creation of the sole actual shutdown Future.
        uiNeed(!_failed && !_closeStarted && _grantId == null, 'close-once');
        _grantId = grant['grantId'] as String;
        _seq++;
        _closeStarted = true;
        _phase = 'close-accepted';
        _phase = 'draining';
        _closeFuture = Future<void>.sync(_owner!.uiRequestExit);
        _closeFuture!
            .then<void>(
              (_) {},
              onError: (Object _, StackTrace _) {
                fail();
              },
            )
            .ignore();
        facts = {'accepted': true};
      } else {
        _seq++;
        _phase = 'observing';
        final actual = await _owner!.uiActualFacts();
        uiNeed(!_failed && _frame != null, 'status-failed');
        facts = {
          'ownerReady': true,
          'g1Held': actual['g1Held'],
          'loading': _loading,
          'learningCount': actual['learningCount'],
          'materialCount': actual['materialCount'],
          'hasSelection': actual['hasSelection'],
          'hasSource': actual['hasSource'],
          ..._frame!,
        };
        uiObject(facts, _statusKeys);
      }
      return {
        'method': method,
        'contextHash': contextHash,
        'seq': seq,
        'childPhase': phase,
        'observedAtMicros': DateTime.now().microsecondsSinceEpoch.toString(),
        'facts': facts,
      };
    } catch (_) {
      fail();
      rethrow;
    } finally {
      _busy = false;
    }
  }

  Future<void> ownerDrained({
    required bool stopped,
    required bool storesDrained,
    required bool storesClosed,
    required bool released,
  }) async {
    uiNeed(
      _closeStarted && stopped && storesDrained && storesClosed && released,
      'actual-drain',
    );
    await _emit('owner-drained', {
      'ownerScope': _context!['ownerScope'],
      'stopConfirmed': true,
      'storesDrained': true,
      'storesClosed': true,
      'authorityReleased': true,
    });
    _phase = 'native-closing';
  }
}
