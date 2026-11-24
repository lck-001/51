import 'dart:async';

import 'package:flutter/services.dart';
import 'package:playback_core/playback_core.dart';

import 'playback_host.dart';

/// Win32 HWND-bound SMTC. No OS media object, path or native Player reaches UI.
/// A live HWND/SMTC binding is a host observation, not lock/sleep acceptance.
final class WindowsPlaybackHost implements PlaybackHost {
  WindowsPlaybackHost._({this.beforeWindowClose, this.onClosingChanged});

  static const _native = MethodChannel('shiyu/windows_playback_host');
  final _events = StreamController<PlaybackSystemEvent>.broadcast(sync: true);
  PlaybackController? _controller;
  PlaybackToken? _publishedToken;
  Future<void> _publishTail = Future.value();
  Timer? _probeTimer;
  Future<void>? _closeFuture, _programmaticExit, _failedStartupDetach;
  bool _closeCompleted = false;
  bool _supported = false,
      _foreground = true,
      _retired = true,
      _suspended = false,
      _closed = false,
      _closing = false,
      _windowClosing = false,
      _probePending = false;

  /// Root binds MediaKitEngine.releaseNative. Required before own HWND closes.
  Future<void> Function(PlaybackToken expected)? beforeWindowClose;

  /// Root synchronously freezes all UI commands and invalidates late imports.
  /// true remains latched through native window destruction; false is emitted
  /// only after cancellation of that native close ticket is confirmed.
  void Function(bool closing)? onClosingChanged;
  String? lastFailure;

  static Future<WindowsPlaybackHost> create({
    Future<void> Function(PlaybackToken expected)? beforeWindowClose,
    void Function(bool closing)? onClosingChanged,
  }) async {
    final host = WindowsPlaybackHost._(
      beforeWindowClose: beforeWindowClose,
      onClosingChanged: onClosingChanged,
    );
    _native.setMethodCallHandler(host._nativeEvent);
    try {
      final status = await _native
          .invokeMapMethod<String, dynamic>('create')
          .timeout(const Duration(seconds: 2));
      host._supported = status?['configured'] == true;
      if (!host._supported) {
        host.lastFailure = '系统媒体控件不可用，当前仅支持前台播放。';
      }
    } catch (_) {
      host.lastFailure = 'Windows 播放宿主未确认，当前仅支持前台播放。';
    }
    host._probeTimer = Timer.periodic(
      const Duration(milliseconds: 750),
      (_) => host._scheduleProbe(),
    );
    return host;
  }

  @override
  PlaybackCapabilities get capabilities => PlaybackCapabilities(
    backgroundAudio: _supported && !_closed,
    systemControls: _supported && !_closed,
    seek: true,
    rate: false,
  );
  @override
  Stream<PlaybackSystemEvent> get events => _events.stream;
  PlaybackToken? get _token => _controller?.current.token;
  bool _current(PlaybackToken token) =>
      !_closed && !_closing && !_windowClosing && _token == token;

  @override
  void bind(PlaybackController controller) {
    if (_controller != null && !identical(controller, _controller)) {
      throw StateError('windows_playback_host_already_bound');
    }
    _controller = controller;
    _foreground = controller.current.foreground;
    _events.add(CapabilitiesChanged(controller.current.token, capabilities));
    _scheduleProbe();
  }

  @override
  void appForeground(bool foreground) {
    if (_closed || _closing || _windowClosing) return;
    _foreground = foreground;
    final token = _token;
    if (token != null) _events.add(ForegroundChanged(token, foreground));
    _scheduleProbe();
  }

  Future<Map<String, dynamic>?> _status() async {
    try {
      return await _native
          .invokeMapMethod<String, dynamic>('hostStatus')
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      return null;
    }
  }

  /// Read-only own-HWND/SMTC diagnostics. Never returns source paths, owners,
  /// display text, artwork, or controls belonging to another process.
  Future<Map<String, Object?>> diagnosticStatus() async {
    final native = await _status();
    bool? flag(String key) =>
        native?[key] is bool ? native![key] as bool : null;
    final status = native?['playbackStatus'];
    const allowedStatuses = {
      'closed',
      'changing',
      'stopped',
      'playing',
      'paused',
    };
    const statusNames = ['closed', 'changing', 'stopped', 'playing', 'paused'];
    final String? statusName =
        status is int && status >= 0 && status < statusNames.length
        ? statusNames[status]
        : status is String && allowedStatuses.contains(status)
        ? status
        : null;
    return {
      'supported': _supported,
      'controlledForeground': _foreground,
      'retired': _retired,
      'closed': _closed,
      'windowClosing': _windowClosing,
      'configured': flag('configured'),
      'windowAlive': flag('windowAlive'),
      'windowVisible': flag('windowVisible'),
      'windowFocused': flag('windowFocused'),
      'nativeForeground': flag('foreground'),
      'enabled': flag('enabled'),
      'suspended': flag('suspended'),
      'genericMetadata': flag('genericMetadata'),
      'metadataCleared': flag('metadataCleared'),
      'metadataReadable': flag('metadataReadable'),
      'metadataErrorCode': native?['metadataErrorCode'] is int
          ? native!['metadataErrorCode'] as int
          : null,
      'playbackStatus': statusName,
      'nativePlaybackStatusCode': status is int && status >= 0 && status <= 4
          ? status
          : null,
    };
  }

  void _reportHost(PlaybackToken token, bool ready) {
    if (!_current(token)) return;
    final actual = _controller!.current;
    // No duplicate false at foreground startup: lack of readiness is not loss.
    if (actual.hostReady == ready) return;
    _events.add(SystemHostChanged(token, ready));
  }

  void _unsupported(String reason) {
    if (_closed || _closing || _windowClosing) return;
    _supported = false;
    _retired = true;
    _publishedToken = null;
    lastFailure = reason;
    unawaited(
      _native
          .invokeMethod<void>('retire')
          .timeout(const Duration(seconds: 2))
          .catchError((Object _) {}),
    );
    final token = _token;
    if (token == null) return;
    _reportHost(token, false);
    final next = _token;
    if (next != null) _events.add(CapabilitiesChanged(next, capabilities));
  }

  @override
  Future<bool> backgroundHostReady() async {
    final token = _token;
    if (token == null ||
        !_current(token) ||
        !_supported ||
        _retired ||
        _suspended) {
      return false;
    }
    final status = await _status();
    if (!_current(token)) return false;
    final ready =
        status?['configured'] == true &&
        status?['windowAlive'] == true &&
        status?['enabled'] == true &&
        status?['suspended'] == false &&
        !_retired &&
        !_suspended;
    _reportHost(token, ready);
    return ready && _current(token);
  }

  void _scheduleProbe() {
    if (_closed ||
        _closing ||
        _windowClosing ||
        _probePending ||
        !_supported ||
        _token == null) {
      return;
    }
    _probePending = true;
    unawaited(() async {
      try {
        final token = _token!;
        final status = await _status();
        if (!_current(token)) return;
        if (status?['configured'] != true || status?['windowAlive'] != true) {
          _unsupported('Windows 媒体绑定未确认，请回前台重新播放。');
          return;
        }
        _reportHost(
          token,
          !_retired &&
              !_suspended &&
              status?['enabled'] == true &&
              status?['suspended'] == false,
        );
      } finally {
        _probePending = false;
      }
    }());
  }

  @override
  Future<bool> preparePlay(PlaybackToken token) async {
    if (!_current(token) || _suspended) return false;
    final current = _controller!.current;
    if (current.resources.values.any(
          (state) => state != ResourceState.closed,
        ) ||
        !current.engineAvailable) {
      return false;
    }
    // Unsupported SMTC degrades to a real foreground-only engine; do not fake
    // readiness or create a system session from an old background command.
    if (!_supported) return _foreground;
    if (!_foreground) return !_retired && await backgroundHostReady();
    final status = await _status();
    if (!_current(token) || !_foreground) return false;
    if (status?['configured'] != true || status?['windowAlive'] != true) {
      _unsupported('Windows 系统媒体控件不可用，仅前台播放。');
      return _current(token) && _foreground;
    }
    if (status?['suspended'] == true) return false;
    _retired = false;
    try {
      await _publishNative(_controller!.current, activate: true);
    } catch (_) {
      _unsupported('Windows 媒体会话未确认，仅支持前台播放。');
      return _current(token) && _foreground;
    }
    if (!_current(token) || !_foreground) return false;
    await backgroundHostReady();
    return _current(token);
  }

  Map<String, Object?> _scope(PlaybackToken token) => {
    'ownerId': token.ownerId,
    'itemId': token.itemId,
    'itemRevision': token.itemRevision,
    'generation': token.generation,
    'commandEpoch': token.commandEpoch,
  };
  PlaybackToken? _decodeScope(Object? raw) {
    if (raw is! Map) return null;
    if (raw['ownerId'] is! String ||
        raw['itemId'] is! String ||
        raw['itemRevision'] is! String ||
        raw['generation'] is! int ||
        raw['commandEpoch'] is! int) {
      return null;
    }
    return PlaybackToken(
      ownerId: raw['ownerId'] as String,
      itemId: raw['itemId'] as String,
      itemRevision: raw['itemRevision'] as String,
      generation: raw['generation'] as int,
      commandEpoch: raw['commandEpoch'] as int,
    );
  }

  bool _terminal(PlaybackSnapshot snapshot) =>
      snapshot.engineAvailable &&
      snapshot.intent == PlaybackIntent.stopped &&
      snapshot.actual == PlaybackActual.idle;

  Future<void> _publishNative(
    PlaybackSnapshot snapshot, {
    bool activate = false,
  }) async {
    if (!_current(snapshot.token) || !_supported) return;
    if (_terminal(snapshot) && !activate) {
      await _native
          .invokeMethod<void>('retire')
          .timeout(const Duration(seconds: 2));
      if (_current(snapshot.token)) {
        _publishedToken = null;
        _reportHost(snapshot.token, false);
      }
      return;
    }
    final noCapture = snapshot.resources.values.every(
      (s) => s == ResourceState.closed,
    );
    final enabled =
        snapshot.item != null &&
        (!_retired ||
            activate ||
            snapshot.intent == PlaybackIntent.stopped &&
                snapshot.actual != PlaybackActual.idle);
    final ready = snapshot.engineAvailable && noCapture && !_suspended;
    final reallyPlaying =
        snapshot.engineAvailable && snapshot.actual == PlaybackActual.playing;
    await _native
        .invokeMapMethod<String, dynamic>('publish', {
          'scope': _scope(snapshot.token),
          'enabled': enabled,
          'allowPlay':
              ready &&
              !_retired &&
              snapshot.intent != PlaybackIntent.stopped &&
              !reallyPlaying,
          'allowPause': reallyPlaying,
          'allowStop': snapshot.item != null,
          'allowSeek':
              ready &&
              snapshot.duration != null &&
              snapshot.capabilities.seek &&
              !_retired,
          'reallyPlaying': reallyPlaying,
          'engineAvailable': snapshot.engineAvailable,
          'actual': snapshot.actual.name,
          'positionMs': snapshot.position.inMilliseconds,
          'durationMs': snapshot.duration?.inMilliseconds,
        })
        .timeout(const Duration(seconds: 2));
    if (_current(snapshot.token)) _publishedToken = snapshot.token;
  }

  @override
  Future<void> publish(PlaybackSnapshot snapshot) {
    if (_closed || _closing || _windowClosing) return Future.value();
    if (snapshot.intent == PlaybackIntent.stopped) {
      _retired = true;
      _publishedToken = null;
    }
    final result = _publishTail.then((_) async {
      if (!_current(snapshot.token) || !_supported) return;
      await _publishNative(snapshot);
      if (_current(snapshot.token)) _scheduleProbe();
    });
    _publishTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {
        _unsupported('Windows 系统播放状态发布失败，已降级前台播放。');
      },
    );
    return result;
  }

  Future<void> _nativeEvent(MethodCall call) async {
    if (_closed) return;
    if (call.method == 'windowCloseRequested') {
      final args = call.arguments;
      if (args is Map && args['ticket'] is int) {
        await _closeOwnWindow(args['ticket'] as int);
      }
      return;
    }
    if (_closing || _windowClosing) return;
    if (call.method == 'suspended') {
      _suspended = true;
      _retired = true;
      _publishedToken = null;
      final token = _token;
      if (token != null) _events.add(SystemSuspended(token));
      return;
    }
    if (call.method == 'resumed') {
      _suspended = false;
      // A new explicit foreground Play is still needed. Never resume here.
      _scheduleProbe();
      return;
    }
    if (call.method != 'systemCommand') return;
    final args = call.arguments;
    if (args is! Map) return;
    final token = _decodeScope(args['scope']);
    if (token == null || token != _publishedToken || !_current(token)) return;
    final PlaybackCommand command;
    switch (args['action']) {
      case 'play':
        if (_retired || _suspended) return;
        command = const Play();
      case 'pause':
        command = const Pause();
      case 'stop':
        command = const Stop();
      case 'seek':
        if (_retired || args['positionMs'] is! int) return;
        command = Seek(Duration(milliseconds: args['positionMs'] as int));
      default:
        return; // No recording, material access, volume or arbitrary calls.
    }
    _events.add(SystemMediaCommand(token, command));
  }

  Future<void> _closeOwnWindow(int ticket) async {
    if (_closed || _windowClosing) return;
    // Synchronous barrier: Root must stop UI commands and invalidate all
    // in-flight imports before any Stop/cleanup await can yield to another task.
    _windowClosing = true;
    _probeTimer?.cancel();
    try {
      final freeze = onClosingChanged;
      if (freeze == null) throw StateError('window_command_barrier_not_bound');
      freeze(true);
      final controller = _controller;
      final release = beforeWindowClose;
      if (controller == null || release == null) {
        throw StateError('window_cleanup_not_bound');
      }
      await controller.dispatch(const Stop());
      final token = controller.current.token;
      if (!_terminal(controller.current)) {
        await controller.snapshots
            .firstWhere((s) => s.token.sameSession(token) && _terminal(s))
            .timeout(const Duration(seconds: 15));
      }
      final expected = controller.current.token;
      if (!_terminal(controller.current)) {
        throw StateError('stop_not_confirmed');
      }
      await release(expected).timeout(const Duration(seconds: 15));
      final current = controller.current;
      if (current.token != expected || !_terminal(current)) {
        throw StateError('window_cleanup_superseded');
      }
      await _native
          .invokeMethod<void>('retire')
          .timeout(const Duration(seconds: 2));
      final finalScope = controller.current;
      if (finalScope.token != expected || !_terminal(finalScope)) {
        throw StateError('window_close_scope_changed');
      }
      // Root's command barrier remains held across this final asynchronous
      // commit. Native independently verifies the pending own-window ticket.
      await _native
          .invokeMethod<void>('closeReady', {'ticket': ticket})
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      lastFailure = '播放停止或原生释放尚未确认，未提前关闭窗口。';
      await _cancelOwnWindowClose(ticket);
    }
  }

  Future<void> _cancelOwnWindowClose(int ticket) async {
    try {
      final result = await _native
          .invokeMapMethod<String, dynamic>('cancelClose', {'ticket': ticket})
          .timeout(const Duration(seconds: 2));
      if (result?['cancelled'] != true) {
        throw StateError('close_cancel_unconfirmed');
      }
      _windowClosing = false;
      onClosingChanged?.call(false);
      _probeTimer = Timer.periodic(
        const Duration(milliseconds: 750),
        (_) => _scheduleProbe(),
      );
    } catch (_) {
      // The native close ticket may still commit. Do not reopen UI admission
      // just because a timeout/exception ended the Dart cleanup path.
      _windowClosing = true;
      lastFailure = '关闭取消或界面恢复未确认，已保留关闭门闩。';
    }
  }

  @override
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closing = true;
    _probeTimer?.cancel();
    await _publishTail.timeout(const Duration(seconds: 15));
    await _native
        .invokeMethod<void>('retire')
        .timeout(const Duration(seconds: 2));
    _publishedToken = null;
    _retired = true;
    _closed = true;
    _native.setMethodCallHandler(null);
    await _events.close();
    _closeCompleted = true;
  }

  /// Only the application owner may call this after real Stop, Store drain and
  /// authority release. Closing SMTC publication is not that storage proof.
  /// Keep the exact operation even when a caller times out: timeout cannot
  /// cancel native work or authorize a second ticket/WM_CLOSE.
  Future<void> requestProgrammaticExitAfterDrain() {
    if (!_closeCompleted ||
        !_closed ||
        !_retired ||
        _failedStartupDetach != null) {
      return Future.error(StateError('windows_host_close_unconfirmed'));
    }
    final existing = _programmaticExit;
    if (existing != null) return existing;
    final attempt = _requestProgrammaticExit();
    _programmaticExit = attempt;
    attempt.then<void>(
      (_) {},
      onError: (Object error, StackTrace _) {
        // Native explicitly says PostMessage failed and restored its guard.
        // Only a later explicit request may start a new ticket. This observer
        // never retries, and the old Future retains its original failure.
        if (error is PlatformException &&
            error.code == 'close_post_failed' &&
            identical(_programmaticExit, attempt)) {
          _programmaticExit = null;
        }
      },
    );
    return attempt;
  }

  Future<void> _requestProgrammaticExit() async {
    final result = await _native.invokeMapMethod<String, dynamic>(
      'beginProgrammaticClose',
    );
    final ticket = result?['ticket'];
    if (ticket is! int || ticket <= 0) {
      throw StateError('windows_close_ticket_invalid');
    }
    // PlatformException(close_post_failed) is a known native rejection; a
    // pending Future/caller timeout remains unknown. Neither is physical exit.
    // Unknown outcomes stay cached and never authorize a fresh native ticket.
    await _native.invokeMethod<void>('closeReady', {'ticket': ticket});
  }

  /// Failed startup only: AppOwner must first await every cleanup and close
  /// Stores/authority successfully. No caller-provided "drained" flag is used.
  Future<void> detachDrainedFailedStartup() {
    if (!_closeCompleted ||
        !_closed ||
        !_retired ||
        _programmaticExit != null) {
      return Future.error(StateError('windows_host_close_unconfirmed'));
    }
    return _failedStartupDetach ??= _native.invokeMethod<void>(
      'detachDrainedFailedStartup',
    );
  }
}
