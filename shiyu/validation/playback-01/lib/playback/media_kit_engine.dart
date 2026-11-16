import 'dart:async';
import 'dart:io';

import 'package:media_kit/media_kit.dart';
import 'package:playback_core/playback_core.dart';

/// Single app-owned native pipeline. Raw callbacks never acquire newer tokens.
final class MediaKitEngine implements PlaybackEngineAdapter {
  MediaKitEngine({
    required this.resolve,
    required this.beforePlay,
    this.currentScope,
    this.silentValidation = false,
  }) {
    _timer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => _scheduleSample(),
    );
  }

  final String Function(PlaybackItem) resolve;
  final Future<bool> Function(PlaybackToken) beforePlay;
  final PlaybackToken Function()? currentScope;

  /// Lab-only per-player mute. Never changes system volume or other sessions.
  final bool silentValidation;
  Player? _player;
  Player get _ensurePlayer => _player ??= Player();
  final _events = StreamController<EngineEvent>.broadcast(sync: true);
  Future<void> _tail = Future.value();
  late final Timer _timer;
  PlaybackToken? _latest, _physical;
  PlaybackItem? _item;
  String? _source;
  bool _closed = false,
      _stopped = true,
      _stopConfirmed = false,
      _samplePending = false,
      _tainted = false,
      _pathConfirmed = false;
  int _availabilitySequence = 0;
  Timer? _loadDeadline;
  final Map<String, Object?> _diagnosticFacts = {};
  ({PlaybackToken token, int id, Duration target, bool submitted})? _seek;

  @override
  Stream<EngineEvent> get events => _events.stream;

  /// Read-only lab diagnostics: no source string, owner, material text or URL.
  /// Whitelisted native facts permit diagnosis without walking private heaps.
  Map<String, Object?> diagnosticSummary() {
    var hasFile = false;
    int? fileMtimeMs;
    try {
      final source = _source;
      if (source != null) {
        final file = source.startsWith('file:')
            ? File.fromUri(Uri.parse(source))
            : File(source);
        hasFile = file.existsSync();
        if (hasFile) {
          fileMtimeMs = file.lastModifiedSync().millisecondsSinceEpoch;
        }
      }
    } catch (_) {}
    return {
      ..._diagnosticFacts,
      'silentValidation': silentValidation,
      'stopped': _stopped,
      'pathConfirmed': _pathConfirmed,
      'engineAvailable': !_tainted,
      'hasSource': _source != null,
      'hasFile': hasFile,
      'fileMtimeMs': fileMtimeMs,
    };
  }

  bool _fileIdentityEqual(String left, String right) {
    try {
      final l = left.startsWith('file:')
          ? File.fromUri(Uri.parse(left)).path
          : left;
      final r = right.startsWith('file:')
          ? File.fromUri(Uri.parse(right)).path
          : right;
      return FileSystemEntity.identicalSync(l, r);
    } catch (_) {
      return false;
    }
  }

  bool _sourceMatches(String actual, String expected) {
    if (_normalize(actual) == _normalize(expected)) return true;
    // mpv can canonicalize a Windows SUBST/alias path. Require OS file identity,
    // never basename/duration similarity; retain scope and before/after checks.
    return Platform.isWindows && _fileIdentityEqual(actual, expected);
  }

  bool? _nativeBoolean(String value) => value == 'yes'
      ? true
      : value == 'no'
      ? false
      : null;
  double? _nativeNumber(String value) {
    final number = double.tryParse(value);
    return number != null && number.isFinite ? number : null;
  }

  bool _current(PlaybackToken token) => !_closed && _latest == token;
  bool _adopt(PlaybackToken token) {
    if (_closed) return false;
    final previous = _latest;
    if (previous != null &&
        (token.generation < previous.generation ||
            (token.generation == previous.generation &&
                (!token.sameSession(previous) ||
                    token.commandEpoch < previous.commandEpoch)))) {
      return false;
    }
    _latest = token;
    return true;
  }

  void _emit(EngineEvent event) {
    if (!_closed) _events.add(event);
  }

  void _unknown(PlaybackToken origin) {
    _tainted = true;
    _emit(
      EngineAvailabilityChanged(
        origin,
        sequence: ++_availabilitySequence,
        available: false,
      ),
    );
  }

  Future<void> _serial(Future<void> Function() work) {
    final result = _tail.then((_) => work());
    _tail = result.catchError((Object _) {});
    return result;
  }

  /// A deadline reports unknown but never releases the serial queue early.
  /// Only a physically confirmed Stop clears unknown. No timeout cancellation
  /// is inferred: the original call remains awaited, with no competing calls.
  Future<T> _native<T>(
    PlaybackToken origin,
    Future<T> Function() work, {
    bool recoveryStop = false,
  }) async {
    if (_tainted && !recoveryStop) {
      throw StateError('native_operation_unconfirmed');
    }
    final timer = Timer(const Duration(seconds: 8), () => _unknown(origin));
    try {
      final result = await work();
      if (_tainted && !recoveryStop) {
        throw StateError('native_operation_unconfirmed');
      }
      return result;
    } catch (_) {
      if (!_tainted) _unknown(origin);
      rethrow;
    } finally {
      timer.cancel();
    }
  }

  String _normalize(String value) {
    final path = value.startsWith('file:')
        ? File.fromUri(Uri.parse(value)).path
        : value;
    return Platform.isWindows ? path.replaceAll(r'\', '/').toLowerCase() : path;
  }

  bool _itemMatches(PlaybackItem item, PlaybackToken token) =>
      item.ownerId == token.ownerId &&
      item.itemId == token.itemId &&
      item.itemRevision == token.itemRevision;

  Future<void> _pauseNative(PlaybackToken token) =>
      _native<void>(token, () async {
        final player = _player;
        if (player != null) await player.pause();
      });

  void _watchLoad(PlaybackToken origin) {
    _loadDeadline?.cancel();
    _loadDeadline = Timer(const Duration(seconds: 8), () {
      final latest = _latest;
      // Source-readiness evidence is material-generation scoped, never owner B
      // relabeled from an old owner A failure.
      if (!_closed &&
          !_tainted &&
          !_pathConfirmed &&
          latest != null &&
          origin.sameSession(latest)) {
        _emit(EngineFailure(latest, '音频加载未确认，请检查材料后重试。'));
      }
    });
  }

  Future<void> _load(PlaybackItem item, PlaybackToken token) async {
    // Even resolve() can throw: silence old A before trying to resolve B.
    if (!_stopped || _physical != null) {
      await _pauseNative(token);
      if (!_current(token)) return;
    }
    final source = resolve(item);
    await _native<void>(
      token,
      () => _ensurePlayer.open(Media(source), play: false),
    );
    _physical = token;
    _source = source;
    _stopped = false;
    _stopConfirmed = false;
    _pathConfirmed = false;
    _diagnosticFacts.clear();
    if (!_current(token)) {
      await _pauseNative(token);
      return;
    }
    _watchLoad(token);
  }

  @override
  Future<void> open(PlaybackItem item, PlaybackToken token) {
    if (!_adopt(token)) return Future.value();
    _item = item;
    _seek = null;
    _loadDeadline?.cancel();
    return _serial(() async {
      if (!_current(token)) return;
      await _load(item, token);
      if (_current(token)) await _sample(token);
    });
  }

  @override
  Future<void> play(PlaybackToken token) {
    if (!_adopt(token)) return Future.value();
    return _serial(() async {
      if (!_current(token)) return;
      if (!await _native<bool>(token, () => beforePlay(token))) {
        throw StateError('focus_or_host_unavailable');
      }
      if (!_current(token)) return;
      // Immediate Play(B) can supersede queued Open(B). A still-loaded A must
      // not be treated as B merely because stopped=false.
      if (_stopped || _physical == null || !token.sameSession(_physical!)) {
        final item = _item;
        if (item == null || !_itemMatches(item, token)) {
          throw StateError('no_loaded_item');
        }
        await _load(item, token);
      }
      if (!_current(token)) return;
      if (silentValidation) {
        // Apply on every real Play, including replacement native players.
        // Same-player seeks/replays retain this volume; no system mixer call.
        await _native<void>(token, () => _ensurePlayer.setVolume(0));
        if (!_current(token)) return;
      }
      _stopConfirmed = false;
      await _native<void>(token, () => _ensurePlayer.play());
      if (!_current(token)) {
        await _pauseNative(token);
        return;
      }
      await _sample(token);
    });
  }

  @override
  Future<void> pause(PlaybackToken token) {
    if (!_adopt(token)) return Future.value();
    return _serial(() async {
      if (!_current(token)) return;
      await _pauseNative(token);
      if (!_current(token)) return;
      if (_stopped && _stopConfirmed) {
        final player = _player;
        String idle = 'yes';
        if (player != null) {
          final native = player.platform;
          if (native is! NativePlayer) {
            throw UnsupportedError('native_player_required');
          }
          idle = await _native<String>(
            token,
            () => native.getProperty('core-idle'),
          );
        }
        if (_current(token) && idle == 'yes') {
          _emit(EngineStateChanged(token, PlaybackActual.idle));
          _emit(EngineProgress(token, position: Duration.zero));
        }
      } else {
        await _sample(token);
      }
    });
  }

  @override
  Future<void> seek(Duration position, PlaybackToken token, int requestId) {
    if (!_adopt(token)) return Future.value();
    _seek = (token: token, id: requestId, target: position, submitted: false);
    return _serial(() async {
      if (!_current(token) || _seek?.id != requestId) return;
      if (_stopped || _physical == null || !token.sameSession(_physical!)) {
        throw StateError('no_loaded_seek_source');
      }
      await _native<void>(token, () => _ensurePlayer.seek(position));
      if (!_current(token) || _seek?.id != requestId) return;
      _seek = (token: token, id: requestId, target: position, submitted: true);
      await _sample(token);
    });
  }

  @override
  Future<void> stop(PlaybackToken token) {
    if (!_adopt(token)) return Future.value();
    _loadDeadline?.cancel();
    _seek = null;
    return _serial(() async {
      if (!_current(token)) return;
      await _native<void>(token, () async {
        final player = _player;
        if (player != null) await player.stop();
      }, recoveryStop: true);
      _tainted = false;
      _stopped = true;
      _stopConfirmed = true;
      _physical = null;
      _source = null;
      _pathConfirmed = false;
      _emit(
        EngineAvailabilityChanged(
          token,
          sequence: ++_availabilitySequence,
          available: true,
        ),
      );
      if (!_current(token)) return;
      // Stop may have caused a Core epoch change through a timed-out native
      // call. Requery idle only in the unchanged material/session and only if
      // no newer adapter command was adopted while Stop was in flight.
      final scope = currentScope?.call() ?? token;
      if (!scope.sameSession(token) ||
          scope.commandEpoch < token.commandEpoch) {
        return;
      }
      final player = _player;
      String idle = 'yes';
      if (player != null) {
        final native = player.platform;
        if (native is! NativePlayer) {
          throw UnsupportedError('native_player_required');
        }
        idle = await _native<String>(
          scope,
          () => native.getProperty('core-idle'),
        );
      }
      if (!_current(token) ||
          (currentScope?.call() ?? scope) != scope ||
          idle != 'yes') {
        return;
      }
      if (!_adopt(scope)) return;
      _emit(EngineStateChanged(scope, PlaybackActual.idle));
      _emit(EngineProgress(scope, position: Duration.zero));
    });
  }

  /// Release native callbacks before a background host destroys its Flutter
  /// engine. Keep this adapter and its event stream alive for a later explicit
  /// foreground Open/Play. New commands queue behind this release and can then
  /// create one replacement Player; an old release never disposes that player.
  Future<void> releaseNative(PlaybackToken expected) => _serial(() async {
    if (!_current(expected) || !_stopped || !_stopConfirmed) return;
    final player = _player;
    if (player == null) return;
    await _disposeAndDrain(player, origin: expected, recoveryStop: true);
    if (identical(_player, player)) {
      _player = null;
      _physical = null;
      _source = null;
      _pathConfirmed = false;
    }
  });

  /// Pinned media_kit 1.2.6 NativePlayer.dispose resolves after scheduling an
  /// unawaited five-second Dart timer that calls mpv_terminate_destroy. It has
  /// no public completion future for that callback. Keep this isolate's event
  /// loop and the serial seam alive for six seconds after dispose resolves.
  /// This is a pinned-library timer drain, NOT proof that all hardware/native
  /// resources are released, nor a guarantee under suspension or process kill.
  /// Re-audit this workaround whenever the pinned media_kit version changes.
  Future<void> _disposeAndDrain(
    Player player, {
    PlaybackToken? origin,
    bool recoveryStop = false,
  }) async {
    if (origin != null) {
      await _native<void>(origin, player.dispose, recoveryStop: recoveryStop);
    } else {
      await player.dispose();
    }
    await Future<void>.delayed(const Duration(seconds: 6));
  }

  void _scheduleSample() {
    final origin = _latest;
    if (_closed || _samplePending || _stopped || _tainted || origin == null) {
      return;
    }
    _samplePending = true;
    unawaited(
      _serial(() => _sample(origin))
          .catchError((Object _) {
            if (_current(origin) && !_tainted) {
              _emit(EngineFailure(origin, '引擎状态查询失败，请停止后重试。'));
            }
          })
          .whenComplete(() => _samplePending = false),
    );
  }

  Future<void> _sample(PlaybackToken token) async {
    final physical = _physical, source = _source, player = _player;
    if (!_current(token) ||
        _stopped ||
        _tainted ||
        player == null ||
        physical == null ||
        source == null ||
        !token.sameSession(physical)) {
      return;
    }
    final native = player.platform;
    if (native is! NativePlayer) {
      throw UnsupportedError('native_player_required');
    }
    final pathBefore = await _native<String>(
      token,
      () => native.getProperty('path'),
    );
    if (!_current(token)) return;
    _diagnosticFacts.addAll({
      'pathEqual': _normalize(pathBefore) == _normalize(source),
      'fileIdentityEqual': _fileIdentityEqual(pathBefore, source),
      'nativeHasPath': pathBefore.isNotEmpty,
    });
    final values = await _native<List<String>>(
      token,
      () => Future.wait([
        native.getProperty('time-pos'),
        native.getProperty('duration'),
        native.getProperty('pause'),
        native.getProperty('core-idle'),
        native.getProperty('paused-for-cache'),
        native.getProperty('eof-reached'),
        native.getProperty('seeking'),
        native.getProperty('path'),
      ]),
    );
    if (!_current(token)) return;
    _diagnosticFacts.addAll({
      'pathEqualAfter': _normalize(values[7]) == _normalize(source),
      'fileIdentityEqualAfter': _fileIdentityEqual(values[7], source),
      'hasTimePosition': values[0].isNotEmpty,
      'positionSeconds': _nativeNumber(values[0]),
      'durationSeconds': _nativeNumber(values[1]),
      'nativePaused': _nativeBoolean(values[2]),
      'nativeCoreIdle': _nativeBoolean(values[3]),
      'nativeCachePaused': _nativeBoolean(values[4]),
      'nativeEof': _nativeBoolean(values[5]),
      'nativeSeeking': _nativeBoolean(values[6]),
      'sampleGeneration': token.generation,
      'sampleEpoch': token.commandEpoch,
    });
    if (!_sourceMatches(pathBefore, source) ||
        !_sourceMatches(values[7], source)) {
      return;
    }
    final seconds = double.tryParse(values[0]);
    final length = double.tryParse(values[1]);
    final hasPosition = seconds != null && seconds.isFinite && seconds >= 0;
    final hasPause = values[2] == 'yes' || values[2] == 'no';
    final hasIdle = values[3] == 'yes' || values[3] == 'no';
    final hasCache = values[4] == 'yes' || values[4] == 'no';
    final hasEof = values[5] == 'yes' || values[5] == 'no';
    _pathConfirmed = hasPosition && hasPause && hasIdle;
    final position = hasPosition
        ? Duration(milliseconds: (seconds * 1000).round())
        : null;
    final duration = length == null || !length.isFinite || length <= 0
        ? null
        : Duration(milliseconds: (length * 1000).round());
    final PlaybackActual actual;
    if (values[5] == 'yes') {
      actual = PlaybackActual.ended;
    } else if (values[2] == 'yes') {
      actual = PlaybackActual.paused;
    } else if (hasPosition &&
        hasPause &&
        hasIdle &&
        hasCache &&
        hasEof &&
        values[2] == 'no' &&
        values[3] == 'no' &&
        values[4] == 'no' &&
        values[5] == 'no' &&
        values[6] == 'no') {
      actual = PlaybackActual.playing;
    } else {
      actual = PlaybackActual.buffering;
    }
    _emit(EngineStateChanged(token, actual));
    if (position != null) {
      _emit(EngineProgress(token, position: position, duration: duration));
    }
    final seek = _seek;
    if (seek != null &&
        seek.submitted &&
        seek.token == token &&
        values[6] == 'no' &&
        position != null &&
        (position - seek.target).abs() <= const Duration(milliseconds: 250)) {
      _emit(EngineSeekSettled(token, requestId: seek.id, position: position));
      _seek = null;
    }
  }

  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    _timer.cancel();
    _loadDeadline?.cancel();
    await _tail;
    final origin = _latest;
    final player = _player;
    if (player != null) {
      if (origin != null) {
        await _native<void>(origin, player.stop, recoveryStop: true);
        _tainted = false;
        await _disposeAndDrain(player, origin: origin);
      } else {
        await _disposeAndDrain(player);
      }
      _player = null;
    }
    await _events.close();
  }
}
