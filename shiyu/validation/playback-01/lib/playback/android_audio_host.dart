import 'dart:async';

import 'package:audio_service/audio_service.dart' as audio;
import 'package:audio_session/audio_session.dart' as session;
import 'package:flutter/services.dart';
import 'package:playback_core/playback_core.dart';

import 'playback_host.dart';

/// Android-only system seam. This owns focus, never the engine or its sources.
final class AndroidAudioHost extends audio.BaseAudioHandler
    implements PlaybackHost {
  AndroidAudioHost._();

  static const _native = MethodChannel('shiyu/playback_host');
  final _events = StreamController<PlaybackSystemEvent>.broadcast(sync: true);
  PlaybackController? _controller;
  late session.AudioSession _session;
  StreamSubscription<session.AudioInterruptionEvent>? _interruptions;
  StreamSubscription<void>? _noisy;
  StreamSubscription<Object>? _errors;
  Timer? _hostTimer;
  Future<void> _focusTail = Future.value();
  Future<void> _publishTail = Future.value();
  PlaybackSnapshot? _latest;
  PlaybackToken? _publishedToken, _focusToken, _interruptionToken;
  PlaybackToken? _startPermitToken;
  PlaybackToken? _submittedIdleToken;
  String? _mediaId;
  Duration? _mediaDuration;
  bool _initialized = false;
  bool _foreground = true;
  bool _hostFault = false;
  bool _backgroundRetired = true;
  bool _probePending = false;
  bool _closing = false;
  bool _closed = false;
  bool? _observedReady;
  int _focusOperation = 0;

  /// Safe diagnostic only: no native exception payload, file name or URI.
  String? lastFailure;

  /// The audio_service host may destroy its cached engine after background
  /// Stop. Native callbacks must be released before publishing idle there.
  Future<void> Function(PlaybackToken token)? beforeBackgroundStop;

  static Future<AndroidAudioHost> create() async {
    final host = await audio.AudioService.init<AndroidAudioHost>(
      builder: AndroidAudioHost._,
      config: const audio.AudioServiceConfig(
        androidNotificationChannelId: 'shiyu.playback.audio',
        androidNotificationChannelName: '拾语音频播放',
        androidNotificationIcon: 'drawable/ic_audio_notification',
        androidShowNotificationBadge: false,
        androidStopForegroundOnPause: false,
        androidResumeOnClick: false,
        preloadArtwork: false,
      ),
    );
    try {
      host._session = await session.AudioSession.instance;
      await host._session.configure(
        const session.AudioSessionConfiguration.speech(),
      );
      host._errors = audio.AudioService.asyncError.listen(
        (_) => host._failHost('系统播放状态发布失败，请回前台重试。'),
      );
      host._interruptions = host._session.interruptionEventStream.listen(
        host._onInterruption,
        onError: (Object _) => host._failHost('音频焦点事件不可用。'),
      );
      host._noisy = host._session.becomingNoisyEventStream.listen((_) {
        final token = host._currentToken;
        if (token == null) return;
        host._interruptionToken = null;
        host._events.add(RouteDisconnected(token));
      });
      // Configuration and service registration are not proof of an active FGS.
      final status = await host._status();
      host._initialized = status?['configured'] == true;
      if (!host._initialized) {
        throw StateError('android_playback_host_not_configured');
      }
      host._hostTimer = Timer.periodic(
        const Duration(milliseconds: 500),
        (_) => host._scheduleProbe(),
      );
      return host;
    } catch (_) {
      await host.close();
      rethrow;
    }
  }

  @override
  PlaybackCapabilities get capabilities => PlaybackCapabilities(
    backgroundAudio: _initialized && !_hostFault && !_closed,
    systemControls: _initialized && !_hostFault && !_closed,
    seek: true,
    rate: false,
  );

  @override
  Stream<PlaybackSystemEvent> get events => _events.stream;

  PlaybackToken? get _currentToken => _controller?.current.token;

  bool _current(PlaybackToken token) =>
      !_closed && !_closing && _currentToken == token;

  @override
  void bind(PlaybackController controller) {
    if (_controller != null && !identical(_controller, controller)) {
      throw StateError('playback_host_already_bound');
    }
    _controller = controller;
    _foreground = controller.current.foreground;
    _latest = controller.current;
    _events.add(CapabilitiesChanged(controller.current.token, capabilities));
    _scheduleProbe();
  }

  @override
  void appForeground(bool foreground) {
    if (_closed || _closing) return;
    _foreground = foreground;
    final token = _currentToken;
    if (token != null) _events.add(ForegroundChanged(token, foreground));
    _scheduleProbe();
  }

  @override
  Future<bool> backgroundHostReady() async {
    final token = _currentToken;
    if (token == null || !_current(token) || !_initialized) return false;
    if (_hostFault || _backgroundRetired) {
      _reportHost(token, false);
      return false;
    }
    final status = await _status();
    if (!_current(token)) return false;
    final ready =
        !_hostFault &&
        !_backgroundRetired &&
        status?['configured'] == true &&
        status?['foreground'] == true;
    _reportHost(token, ready);
    return ready && _current(token);
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

  void _reportHost(PlaybackToken token, bool ready) {
    if (!_current(token)) return;
    final current = _controller!.current;
    final changed = _observedReady != ready;
    _observedReady = ready;
    // In particular, initial foreground false -> false cannot pause first Play.
    if ((!changed && current.hostReady == ready) ||
        (!ready && !current.hostReady && _foreground)) {
      return;
    }
    _events.add(SystemHostChanged(token, ready));
  }

  void _scheduleProbe() {
    final token = _currentToken;
    if (token == null || _closed || _closing || _probePending) return;
    _probePending = true;
    unawaited(() async {
      try {
        final status = await _status();
        if (!_current(token)) return;
        final ready =
            !_hostFault && !_backgroundRetired && status?['foreground'] == true;
        _reportHost(token, ready);
      } finally {
        _probePending = false;
      }
    }());
  }

  Future<T> _focusSerial<T>(Future<T> Function() work) {
    final result = _focusTail.then((_) => work());
    _focusTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  @override
  Future<bool> preparePlay(PlaybackToken token) {
    final operation = ++_focusOperation;
    return _focusSerial(() async {
      if (!_current(token) || !_initialized) return false;
      if (!_foreground && _backgroundRetired) {
        lastFailure = '本次播放会话已结束，请回前台重新播放。';
        return false;
      }
      if (_controller!.current.resources.values.any(
        (state) => state != ResourceState.closed,
      )) {
        return false;
      }
      // Query native reality before every background request, never restart it.
      final status = await _status();
      if (!_current(token) || operation != _focusOperation) return false;
      if (status?['configured'] != true ||
          (!_foreground && status?['foreground'] != true)) {
        _reportHost(token, false);
        lastFailure = '后台播放宿主尚未确认，请回前台播放。';
        return false;
      }
      if (_hostFault) {
        if (!_foreground) return false;
        // Only a fresh legal foreground Play may clear a previous host fault.
        _hostFault = false;
        lastFailure = null;
        _events.add(CapabilitiesChanged(token, capabilities));
        if (!_current(token)) return false;
      }
      bool granted;
      try {
        granted = await _session.setActive(true);
      } catch (_) {
        granted = false;
      }
      if (!_current(token) || operation != _focusOperation) {
        // Serialized with the next request: cannot abandon a newer focus grant.
        if (granted) await _session.setActive(false);
        return false;
      }
      if (!_foreground) {
        final latest = await _status();
        if (!_current(token) ||
            operation != _focusOperation ||
            latest?['foreground'] != true) {
          if (granted) await _session.setActive(false);
          return false;
        }
      }
      if (!granted) {
        lastFailure = '系统未允许音频焦点，尚未开始播放。';
        return false;
      }
      _focusToken = token;
      _startPermitToken = token;
      _backgroundRetired = false;
      return true;
    });
  }

  Future<void> _releaseFocus() {
    ++_focusOperation;
    _focusToken = null;
    _startPermitToken = null;
    _interruptionToken = null;
    return _focusSerial(() async {
      if (!_initialized) return;
      await _session.setActive(false);
    });
  }

  void _onInterruption(session.AudioInterruptionEvent event) {
    if (_closed || _closing) return;
    if (event.begin) {
      final acquired = _focusToken;
      final token = _currentToken;
      // A fresh OS loss belongs to the current command of the same focus
      // session, even after manual Pause advanced its epoch. Never adopt an
      // old item's focus event into a different material/account session.
      if (acquired == null ||
          token == null ||
          !acquired.sameSession(token) ||
          !_current(token)) {
        return;
      }
      _interruptionToken = token;
      final permanent = event.type == session.AudioInterruptionType.unknown;
      _events.add(
        FocusChanged(
          token,
          permanent ? FocusState.permanentLoss : FocusState.transientLoss,
          holdId: 'android_audio_focus',
          mayResume: !permanent,
        ),
      );
      if (permanent) {
        _focusToken = null;
        _startPermitToken = null;
      }
    } else {
      final token = _interruptionToken;
      _interruptionToken = null;
      if (token == null) return;
      // Preserve the original interruption token. Do not retag an old gain.
      _events.add(
        FocusChanged(
          token,
          FocusState.gained,
          holdId: 'android_audio_focus',
          mayResume: event.type != session.AudioInterruptionType.unknown,
        ),
      );
    }
  }

  void _failHost(String reason) {
    if (_closed || _closing) return;
    _hostFault = true;
    _startPermitToken = null;
    _backgroundRetired = true;
    lastFailure = reason;
    final token = _currentToken;
    if (token == null) return;
    _observedReady = false;
    _events.add(SystemHostChanged(token, false));
    final next = _currentToken;
    if (next != null && _controller!.current.intent != PlaybackIntent.stopped) {
      _events.add(CapabilitiesChanged(next, capabilities));
      final suspended = _currentToken;
      if (suspended != null) _events.add(SystemSuspended(suspended));
    }
    unawaited(_releaseFocus().catchError((Object _) {}));
  }

  bool _terminal(PlaybackSnapshot s) =>
      s.engineAvailable &&
      s.intent == PlaybackIntent.stopped &&
      s.actual == PlaybackActual.idle;

  audio.AudioProcessingState _processing(PlaybackSnapshot s) {
    if (!s.engineAvailable) return audio.AudioProcessingState.error;
    if (_terminal(s) || s.item == null) return audio.AudioProcessingState.idle;
    return switch (s.actual) {
      PlaybackActual.loading => audio.AudioProcessingState.loading,
      PlaybackActual.buffering => audio.AudioProcessingState.buffering,
      PlaybackActual.ended => audio.AudioProcessingState.completed,
      PlaybackActual.failed => audio.AudioProcessingState.error,
      _ => audio.AudioProcessingState.ready,
    };
  }

  void _publishDraining(PlaybackSnapshot snapshot) {
    // Actual engine idle is confirmed, but its native callbacks/timers are
    // still draining. Keep the host alive without reporting either sound or
    // a completed system teardown. No new Play/Seek can race this cleanup.
    _publishedToken = snapshot.token;
    playbackState.add(
      audio.PlaybackState(
        processingState: audio.AudioProcessingState.ready,
        playing: false,
        controls: const [audio.MediaControl.stop],
        androidCompactActionIndices: const [0],
        systemActions: const {},
        updatePosition: snapshot.position,
        speed: snapshot.rate,
      ),
    );
  }

  @override
  Future<void> publish(PlaybackSnapshot snapshot) {
    if (_closed || _closing) return Future.value();
    final previous = _latest;
    _latest = snapshot;
    if (snapshot.intent == PlaybackIntent.stopped) {
      // stopSelf/notification teardown are asynchronous. A stale positive OS
      // observation must not allow background restart of a retired session.
      _backgroundRetired = true;
      _startPermitToken = null;
    }
    if (previous == null || !previous.token.sameSession(snapshot.token)) {
      _observedReady = null;
    }
    final result = _publishTail.then((_) async {
      if (!_current(snapshot.token)) return;
      if (snapshot.engineAvailable &&
          snapshot.actual == PlaybackActual.ended &&
          snapshot.intent == PlaybackIntent.paused &&
          snapshot.requiresFreshPlay) {
        // Natural completion must release the retained FGS/wakelock. Wait for
        // actual engine idle; never destroy the background Dart engine early.
        await _controller!.dispatch(const Stop());
        return;
      }
      final terminal = _terminal(snapshot);
      if (terminal && _submittedIdleToken == snapshot.token) {
        // A host observation/progress echo can republish the same terminal.
        // Never re-enter Ready/draining after submitting idle for this command.
        // This is submission dedupe, not proof that Android retired the FGS.
        return;
      }
      if (terminal && !_foreground) {
        final release = beforeBackgroundStop;
        if (release == null) {
          throw StateError('background_native_release_not_bound');
        }
        _publishDraining(snapshot);
        await release(snapshot.token).timeout(const Duration(seconds: 15));
        final current = _controller!.current;
        if (!_current(snapshot.token) ||
            current.actual != PlaybackActual.idle ||
            current.intent != PlaybackIntent.stopped) {
          return;
        }
      }
      final opaqueId = 'shiyu-audio-${snapshot.generation}';
      if (snapshot.item != null &&
          (_mediaId != opaqueId || _mediaDuration != snapshot.duration)) {
        mediaItem.add(
          audio.MediaItem(
            id: opaqueId,
            title: '拾语音频',
            duration: snapshot.duration,
          ),
        );
        _mediaId = opaqueId;
        _mediaDuration = snapshot.duration;
      }
      var reallyPlaying = false;
      if (snapshot.engineAvailable &&
          snapshot.actual == PlaybackActual.playing) {
        // Publishing true can start/re-enter an FGS in audio_service. Separate
        // this qualification from observation: a pending Pause must not turn
        // an actually-playing, legal existing session into a fake paused one.
        final status = await _status();
        if (!_current(snapshot.token)) return;
        final current = _controller!.current;
        if (current.actual != snapshot.actual ||
            current.engineAvailable != snapshot.engineAvailable) {
          return;
        }
        final existingHost =
            !_hostFault &&
            !_backgroundRetired &&
            current.hostReady &&
            status?['configured'] == true &&
            status?['foreground'] == true;
        final initialForegroundPlay =
            !_hostFault &&
            !_backgroundRetired &&
            _foreground &&
            current.foreground &&
            current.intent == PlaybackIntent.playing &&
            !current.requiresFreshPlay &&
            current.pauseCauses.isEmpty &&
            current.resources.values.every(
              (state) => state == ResourceState.closed,
            ) &&
            _startPermitToken == snapshot.token &&
            _focusToken == snapshot.token &&
            status?['configured'] == true;
        if (!existingHost && !initialForegroundPlay) {
          // Retired/faulted/unconfirmed playing must neither fake pause success
          // nor publish true and recreate a background FGS. Keep the last OS
          // observation until native paused/idle, or explicit engine-unknown
          // error arrives. The core independently requests safe pausing.
          if (status?['foreground'] != true) {
            _reportHost(snapshot.token, false);
          }
          _scheduleProbe();
          return;
        }
        reallyPlaying = true;
        _startPermitToken = null;
      }
      _publishedToken = snapshot.token;
      if (reallyPlaying) _focusToken = snapshot.token;
      playbackState.add(
        audio.PlaybackState(
          processingState: _processing(snapshot),
          playing: reallyPlaying,
          controls: snapshot.item == null || terminal
              ? const []
              : !snapshot.engineAvailable
              ? const [audio.MediaControl.stop]
              : [
                  reallyPlaying
                      ? audio.MediaControl.pause
                      : audio.MediaControl.play,
                  audio.MediaControl.stop,
                ],
          systemActions:
              snapshot.duration == null || terminal || !snapshot.engineAvailable
              ? const {}
              : const {audio.MediaAction.seek},
          androidCompactActionIndices: snapshot.item == null || terminal
              ? const []
              : !snapshot.engineAvailable
              ? const [0]
              : const [0, 1],
          updatePosition: snapshot.position,
          speed: snapshot.rate,
          errorCode:
              !snapshot.engineAvailable ||
                  snapshot.actual == PlaybackActual.failed
              ? 1
              : null,
          errorMessage: !snapshot.engineAvailable
              ? '引擎播放状态未确认，请停止后回前台重试。'
              : snapshot.actual == PlaybackActual.failed
              ? '播放暂不可用，请停止后回前台重试。'
              : null,
        ),
      );
      if (terminal) {
        _submittedIdleToken = snapshot.token;
        _reportHost(snapshot.token, false);
        await _releaseFocus();
      } else {
        // add() only queues an asynchronous native publication; probe it later.
        _scheduleProbe();
      }
    });
    _publishTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {
        _failHost('系统播放状态同步失败，请回前台重试。');
      },
    );
    return result;
  }

  Future<void> _command(PlaybackCommand command) async {
    final token = _publishedToken;
    if (token == null || !_current(token)) return;
    _events.add(SystemMediaCommand(token, command));
  }

  @override
  Future<void> play() => _command(const Play());
  @override
  Future<void> pause() => _command(const Pause());
  @override
  Future<void> seek(Duration position) => _command(Seek(position));
  @override
  Future<void> stop() => _command(const Stop());
  @override
  Future<void> onTaskRemoved() => _command(const Stop());
  @override
  Future<void> onNotificationDeleted() => _command(const Stop());

  @override
  Future<void> close() async {
    if (_closed || _closing) return;
    _closing = true;
    _hostTimer?.cancel();
    var safeToEndHost = _foreground || _controller == null;
    try {
      final controller = _controller;
      if (controller != null) await controller.dispatch(const Stop());
      await _publishTail.timeout(const Duration(seconds: 15));
      if (!_foreground && controller != null) {
        final token = controller.current.token;
        var current = controller.current;
        if (current.actual != PlaybackActual.idle ||
            current.intent != PlaybackIntent.stopped) {
          await controller.snapshots
              .firstWhere(
                (s) =>
                    s.token == token &&
                    s.actual == PlaybackActual.idle &&
                    s.intent == PlaybackIntent.stopped,
              )
              .timeout(const Duration(seconds: 8));
        }
        final release = beforeBackgroundStop;
        if (release == null) {
          throw StateError('background_native_release_not_bound');
        }
        current = controller.current;
        if (current.token == token &&
            _terminal(current) &&
            _submittedIdleToken != token) {
          _publishDraining(current);
        }
        await release(token).timeout(const Duration(seconds: 15));
        current = controller.current;
        safeToEndHost =
            current.token == token &&
            current.actual == PlaybackActual.idle &&
            current.intent == PlaybackIntent.stopped;
      }
    } catch (_) {
      lastFailure = '关闭播放时有操作未确认。';
    }
    if (!safeToEndHost) {
      try {
        await _releaseFocus();
      } catch (_) {
        // Do not turn a failed native cleanup into a successful host shutdown.
      }
      _backgroundRetired = true;
      _hostFault = true;
      _closing = false;
      lastFailure = '后台原生播放释放未确认，未提前关闭系统宿主。';
      throw StateError('background_native_cleanup_unconfirmed');
    }
    // This terminates system ownership, not a claim that the engine was disposed.
    playbackState.add(
      audio.PlaybackState(
        processingState: audio.AudioProcessingState.idle,
        playing: false,
      ),
    );
    try {
      await _releaseFocus();
    } catch (_) {
      lastFailure = '系统音频焦点释放未确认。';
    }
    await Future.wait([
      if (_interruptions != null) _interruptions!.cancel(),
      if (_noisy != null) _noisy!.cancel(),
      if (_errors != null) _errors!.cancel(),
    ]);
    _closed = true;
    _initialized = false;
    await _events.close();
  }
}
