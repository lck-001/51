library;

import 'dart:async';

enum PlaybackIntent { playing, paused, stopped }

enum PlaybackActual { idle, loading, buffering, playing, paused, ended, failed }

enum PauseCause {
  user,
  focusTransient,
  focusLoss,
  routeDisconnected,
  capture,
  backgroundUnsupported,
  videoPolicy,
  systemSuspended,
  engineUnavailable,
  error,
}

enum MediaKind { audio, video }

enum ResourceState { starting, active, stopping, closed, unknown }

enum FocusState { transientLoss, gained, permanentLoss }

enum CommandStatus { accepted, rejected, unsupported }

/// Opaque identity only. Resolution to a file/SDK source belongs to the adapter.
final class PlaybackItem {
  const PlaybackItem({
    required this.ownerId,
    required this.itemId,
    required this.itemRevision,
    required this.kind,
  });
  final String ownerId, itemId, itemRevision;
  final MediaKind kind;
}

final class PlaybackToken {
  const PlaybackToken({
    required this.ownerId,
    required this.itemId,
    required this.itemRevision,
    required this.generation,
    required this.commandEpoch,
  });
  final String ownerId, itemId, itemRevision;
  final int generation, commandEpoch;
  bool sameSession(PlaybackToken other) =>
      ownerId == other.ownerId &&
      itemId == other.itemId &&
      itemRevision == other.itemRevision &&
      generation == other.generation;
  @override
  bool operator ==(Object other) =>
      other is PlaybackToken &&
      sameSession(other) &&
      commandEpoch == other.commandEpoch;
  @override
  int get hashCode =>
      Object.hash(ownerId, itemId, itemRevision, generation, commandEpoch);
}

final class PlaybackCapabilities {
  const PlaybackCapabilities({
    this.backgroundAudio = false,
    this.systemControls = false,
    this.seek = true,
    this.rate = false,
  });
  final bool backgroundAudio, systemControls, seek, rate;
}

final class PendingSeek {
  const PendingSeek({
    required this.requestId,
    required this.target,
    required this.token,
  });
  final int requestId;
  final Duration target;
  final PlaybackToken token;
}

final class PlaybackSnapshot {
  PlaybackSnapshot({
    required this.item,
    required this.token,
    required this.intent,
    required this.actual,
    required Set<PauseCause> pauseCauses,
    required Map<String, ResourceState> resources,
    required this.requiresFreshPlay,
    required this.foreground,
    required this.position,
    required this.duration,
    required this.rate,
    required this.capabilities,
    required this.pendingSeek,
    required this.error,
    required this.hostReady,
    required this.captureEpoch,
    required this.seekPositionApplied,
    required this.seekFrameReady,
    this.engineAvailable = true,
  }) : pauseCauses = Set.unmodifiable(pauseCauses),
       resources = Map.unmodifiable(resources);
  final PlaybackItem? item;
  final PlaybackToken token;
  final PlaybackIntent intent;
  final PlaybackActual actual;
  final Set<PauseCause> pauseCauses;
  final Map<String, ResourceState> resources;
  final bool requiresFreshPlay, foreground;
  final bool hostReady, seekPositionApplied, seekFrameReady;
  final bool engineAvailable;
  final int captureEpoch;
  final Duration position;
  final Duration? duration;
  final double rate;
  final PlaybackCapabilities capabilities;
  final PendingSeek? pendingSeek;
  final String? error;
  String get ownerId => token.ownerId;
  String get itemRevision => token.itemRevision;
  int get generation => token.generation;
  int get commandEpoch => token.commandEpoch;
}

sealed class PlaybackCommand {
  const PlaybackCommand();
}

final class Open extends PlaybackCommand {
  const Open(this.item);
  final PlaybackItem item;
}

final class Play extends PlaybackCommand {
  const Play();
}

final class Pause extends PlaybackCommand {
  const Pause();
}

final class Stop extends PlaybackCommand {
  const Stop();
}

final class Seek extends PlaybackCommand {
  const Seek(this.position);
  final Duration position;
}

final class SetRate extends PlaybackCommand {
  const SetRate(this.rate);
  final double rate;
}

final class CommandResult {
  const CommandResult(this.status, {required this.token, this.reason});
  final CommandStatus status;
  final PlaybackToken token;
  final String? reason;
  bool get accepted => status == CommandStatus.accepted;
}

abstract interface class Playback {
  PlaybackSnapshot get current;
  Stream<PlaybackSnapshot> get snapshots;
  Future<CommandResult> dispatch(PlaybackCommand command);
}

sealed class EngineEvent {
  const EngineEvent(this.token);
  final PlaybackToken token;
}

/// Health of the one physical engine pipeline, not an item-scoped callback.
/// token identifies the originating operation; sequence orders health evidence.
final class EngineAvailabilityChanged extends EngineEvent {
  const EngineAvailabilityChanged(
    super.token, {
    required this.sequence,
    required this.available,
  });
  final int sequence;
  final bool available;
}

final class EngineStateChanged extends EngineEvent {
  const EngineStateChanged(super.token, this.actual);
  final PlaybackActual actual;
}

final class EngineProgress extends EngineEvent {
  const EngineProgress(super.token, {required this.position, this.duration});
  final Duration position;
  final Duration? duration;
}

/// Only send after observing the requested position (and video frame if needed).
final class EngineSeekSettled extends EngineEvent {
  const EngineSeekSettled(
    super.token, {
    required this.requestId,
    required this.position,
    this.frameReady = false,
  });
  final int requestId;
  final Duration position;
  final bool frameReady;
}

final class EngineFailure extends EngineEvent {
  const EngineFailure(super.token, this.message);
  final String message;
}

/// Every operation/event is scoped. stop(oldToken) MUST NOT stop a newer session.
/// Futures acknowledge submitted work; they do not prove playback or a rendered seek.
abstract interface class PlaybackEngineAdapter {
  Stream<EngineEvent> get events;
  Future<void> open(PlaybackItem item, PlaybackToken token);
  Future<void> play(PlaybackToken token);
  Future<void> pause(PlaybackToken token);
  Future<void> seek(Duration position, PlaybackToken token, int requestId);
  Future<void> stop(PlaybackToken token);
}

sealed class PlaybackSystemEvent {
  const PlaybackSystemEvent(this.token);
  final PlaybackToken token;
}

final class ForegroundChanged extends PlaybackSystemEvent {
  const ForegroundChanged(super.token, this.foreground);
  final bool foreground;
}

final class FocusChanged extends PlaybackSystemEvent {
  const FocusChanged(
    super.token,
    this.state, {
    this.holdId = 'focus',
    this.mayResume = true,
  });
  final FocusState state;
  final String holdId;
  final bool mayResume;
}

final class RouteDisconnected extends PlaybackSystemEvent {
  const RouteDisconnected(super.token);
}

final class SystemSuspended extends PlaybackSystemEvent {
  const SystemSuspended(super.token);
}

final class SystemHostChanged extends PlaybackSystemEvent {
  const SystemHostChanged(super.token, this.ready);
  final bool ready;
}

final class SystemMediaCommand extends PlaybackSystemEvent {
  const SystemMediaCommand(super.token, this.command);
  final PlaybackCommand command;
}

final class CaptureRequested extends PlaybackSystemEvent {
  const CaptureRequested(super.token, this.resourceId);
  final String resourceId;
}

final class CaptureResourceChanged extends PlaybackSystemEvent {
  const CaptureResourceChanged(super.token, this.resourceId, this.state);
  final String resourceId;
  final ResourceState state;
}

final class CapabilitiesChanged extends PlaybackSystemEvent {
  const CapabilitiesChanged(super.token, this.capabilities);
  final PlaybackCapabilities capabilities;
}

/// Policy request only. Capture owner must perform cleanup and report real state.
final class CaptureCleanupRequest {
  const CaptureCleanupRequest({
    required this.resourceId,
    required this.requestToken,
    required this.captureEpoch,
  });
  final String resourceId;
  final PlaybackToken requestToken;
  final int captureEpoch;
}

abstract interface class SystemPlaybackAdapter {
  PlaybackCapabilities get capabilities;
  Stream<PlaybackSystemEvent> get events;

  /// Publish generic metadata only; no raw file name, source path or private text.
  Future<void> publish(PlaybackSnapshot snapshot);
}

/// Owns intent, causal holds and stale-operation safety; adapters own native work.
final class PlaybackController implements Playback {
  PlaybackController({
    required PlaybackEngineAdapter engine,
    required SystemPlaybackAdapter system,
    this.seekConfirmationTimeout = const Duration(seconds: 5),
  }) : _engine = engine,
       _system = system,
       _capabilities = system.capabilities {
    _engineSubscription = _engine.events.listen(
      _onEngine,
      onError: (Object e) => _fail('engine stream: $e'),
    );
    _systemSubscription = _system.events.listen(
      _onSystem,
      onError: (Object e) => _fail('system stream: $e'),
    );
  }
  final PlaybackEngineAdapter _engine;
  final SystemPlaybackAdapter _system;
  final _changes = StreamController<PlaybackSnapshot>.broadcast(sync: true);
  final _cleanupRequests = StreamController<CaptureCleanupRequest>.broadcast(
    sync: true,
  );
  Stream<CaptureCleanupRequest> get captureCleanupRequests =>
      _cleanupRequests.stream;
  final Duration seekConfirmationTimeout;
  late final StreamSubscription<EngineEvent> _engineSubscription;
  late final StreamSubscription<PlaybackSystemEvent> _systemSubscription;
  PlaybackItem? _item;
  PlaybackIntent _intent = PlaybackIntent.stopped;
  PlaybackActual _actual = PlaybackActual.idle;
  final Set<PauseCause> _causes = {};
  final Map<String, ResourceState> _resources = {};
  final Map<String, PlaybackToken> _resourceTokens = {};
  final Set<String> _invalidCaptureRequests = {};
  final Map<String, PlaybackToken> _focusHolds = {};
  PlaybackToken? _resume;
  PlaybackCapabilities _capabilities;
  int _generation = 0,
      _epoch = 0,
      _seekId = 0,
      _captureEpoch = 0,
      _engineAvailabilitySequence = -1;
  bool _fresh = false,
      _foreground = true,
      _closed = false,
      _seekScheduled = false,
      _seekExecuting = false,
      _hostReady = false,
      _seekPositionApplied = false,
      _seekFrameReady = false;
  bool _engineAvailable = true;
  Timer? _seekTimer;
  Duration _position = Duration.zero;
  Duration? _duration;
  PendingSeek? _pendingSeek;
  String? _error;
  PlaybackToken get _token => PlaybackToken(
    ownerId: _item?.ownerId ?? '',
    itemId: _item?.itemId ?? '',
    itemRevision: _item?.itemRevision ?? '',
    generation: _generation,
    commandEpoch: _epoch,
  );
  @override
  PlaybackSnapshot get current => PlaybackSnapshot(
    item: _item,
    token: _token,
    intent: _intent,
    actual: _actual,
    pauseCauses: _causes,
    resources: _resources,
    requiresFreshPlay: _fresh,
    foreground: _foreground,
    position: _position,
    duration: _duration,
    rate: 1,
    capabilities: _capabilities,
    pendingSeek: _pendingSeek,
    error: _error,
    hostReady: _hostReady,
    captureEpoch: _captureEpoch,
    seekPositionApplied: _seekPositionApplied,
    seekFrameReady: _seekFrameReady,
    engineAvailable: _engineAvailable,
  );
  @override
  Stream<PlaybackSnapshot> get snapshots => _changes.stream;
  bool _session(PlaybackToken t) => !_closed && _token.sameSession(t);
  bool _exact(PlaybackToken t) => !_closed && _token == t;
  bool get _captureBlocked =>
      _resources.values.any((s) => s != ResourceState.closed);
  bool get _policyBlocked =>
      _captureBlocked ||
      _focusHolds.isNotEmpty ||
      _causes.any((c) => c != PauseCause.user);
  void _emit() {
    if (_closed) return;
    final snapshot = current;
    _changes.add(snapshot);
    // Publication errors are observable, but cannot recursively republish forever.
    Future.sync(() => _system.publish(snapshot)).catchError((Object e) {
      if (_closed || snapshot.token != _token) return;
      _error = 'system publication failed: $e';
      _changes.add(current);
    });
  }

  void _fail(String message) {
    if (_closed) return;
    _error = message;
    _actual = PlaybackActual.failed;
    _intent = PlaybackIntent.paused;
    _fresh = true;
    _resume = null;
    _causes.add(PauseCause.error);
    _epoch++;
    _pendingSeek = null;
    _emit();
  }

  void _run(
    Future<void> Function() work,
    PlaybackToken token, {
    bool compensate = false,
    bool openOperation = false,
  }) {
    Future.sync(work).then(
      (_) {
        final staleOpen =
            !_session(token) ||
            _intent == PlaybackIntent.stopped ||
            _captureBlocked ||
            (!_foreground &&
                (_item?.kind == MediaKind.video ||
                    !_capabilities.backgroundAudio ||
                    !_hostReady));
        final stalePlay =
            !_exact(token) ||
            _intent != PlaybackIntent.playing ||
            _fresh ||
            _policyBlocked;
        if (compensate && (openOperation ? staleOpen : stalePlay)) {
          _compensate(token, preserveSource: !openOperation);
        }
      },
      onError: (Object error, StackTrace stack) {
        if (_exact(token)) _fail('adapter operation failed: $error');
        if (compensate) _compensate(token, preserveSource: !openOperation);
      },
    );
  }

  void _compensate(PlaybackToken token, {bool preserveSource = false}) {
    // Keep the current source loaded across transient-focus pause/recovery.
    final sameSession = _session(token);
    if (sameSession &&
        preserveSource &&
        _intent == PlaybackIntent.playing &&
        !_fresh &&
        !_policyBlocked)
      return;
    final cleanupToken = sameSession && preserveSource ? _token : token;
    Future.sync(
      () => sameSession && preserveSource
          ? _engine.pause(cleanupToken)
          : _engine.stop(cleanupToken),
    ).catchError((Object e) {
      if (_closed) return;
      // Never rewrite a new item's actual/intent using an old failure.
      if (_exact(cleanupToken)) {
        _error = 'late operation cleanup unknown: $e';
        _fresh = true;
        _causes.add(PauseCause.error);
        _emit();
      }
    });
  }

  void _pauseEngine() {
    final t = _token;
    _run(() => _engine.pause(t), t);
  }

  CommandResult _result(CommandStatus status, [String? reason]) =>
      CommandResult(status, token: _token, reason: reason);

  @override
  Future<CommandResult> dispatch(PlaybackCommand command) {
    if (_closed)
      return Future.value(_result(CommandStatus.rejected, 'disposed'));
    final CommandResult result;
    switch (command) {
      case Open(:final item):
        if (item.ownerId.isEmpty ||
            item.itemId.isEmpty ||
            item.itemRevision.isEmpty) {
          return Future.value(
            _result(
              CommandStatus.rejected,
              'owner and material revision required',
            ),
          );
        }
        final old = _token;
        _generation++;
        _epoch++;
        _item = item;
        _hostReady = false;
        _intent = PlaybackIntent.paused;
        _actual = PlaybackActual.loading;
        _resume = null;
        _fresh = true;
        _pendingSeek = null;
        _seekTimer?.cancel();
        _seekPositionApplied = false;
        _seekFrameReady = false;
        _position = Duration.zero;
        _duration = null;
        _error = null;
        _focusHolds.clear();
        _causes.clear();
        _causes.add(PauseCause.user);
        if (!_engineAvailable) _causes.add(PauseCause.engineUnavailable);
        if (_captureBlocked) _causes.add(PauseCause.capture);
        for (final resourceId in _resources.keys.toList()) {
          _requestCaptureCleanup(resourceId);
        }
        _applyBackground();
        final t = _token;
        _run(() => _engine.stop(old), old);
        _run(
          () => _engine.open(item, t),
          t,
          compensate: true,
          openOperation: true,
        );
        result = _result(CommandStatus.accepted);
      case Play():
        if (_item == null)
          return Future.value(_result(CommandStatus.rejected, 'no item'));
        if (!_engineAvailable)
          return Future.value(
            _result(
              CommandStatus.rejected,
              'physical engine availability unknown',
            ),
          );
        if (_captureBlocked)
          return Future.value(
            _result(
              CommandStatus.rejected,
              'capture or preview resource not closed',
            ),
          );
        if (!_foreground &&
            (_item!.kind == MediaKind.video ||
                !_capabilities.backgroundAudio ||
                !_hostReady))
          return Future.value(
            _result(
              CommandStatus.unsupported,
              'foreground-only playback or host not ready',
            ),
          );
        if (_focusHolds.isNotEmpty)
          return Future.value(_result(CommandStatus.rejected, 'system hold'));
        _epoch++;
        _resume = null;
        _pendingSeek = null;
        _fresh = false;
        _intent = PlaybackIntent.playing;
        _causes.removeAll({
          PauseCause.user,
          PauseCause.focusLoss,
          PauseCause.routeDisconnected,
          PauseCause.error,
          PauseCause.systemSuspended,
        });
        _error = null;
        final t = _token;
        _run(() => _engine.play(t), t, compensate: true);
        result = _result(CommandStatus.accepted);
      case Pause():
        _epoch++;
        _intent = PlaybackIntent.paused;
        _fresh = true;
        _resume = null;
        _pendingSeek = null;
        _causes.add(PauseCause.user);
        _pauseEngine();
        result = _result(CommandStatus.accepted);
      case Stop():
        _epoch++;
        _intent = PlaybackIntent.stopped;
        _fresh = true;
        _resume = null;
        _pendingSeek = null;
        _hostReady = false;
        _focusHolds.clear();
        _causes.remove(PauseCause.focusTransient);
        _causes.add(PauseCause.user);
        final t = _token;
        _run(() => _engine.stop(t), t);
        result = _result(CommandStatus.accepted);
      case Seek(:final position):
        if (_item == null || !_capabilities.seek)
          return Future.value(
            _result(CommandStatus.unsupported, 'seek unavailable'),
          );
        if (_duration == null ||
            position < Duration.zero ||
            position > _duration!)
          return Future.value(
            _result(CommandStatus.rejected, 'seek outside known duration'),
          );
        _epoch++;
        _seekTimer?.cancel();
        _seekPositionApplied = false;
        _seekFrameReady = false;
        _pendingSeek = PendingSeek(
          requestId: ++_seekId,
          target: position,
          token: _token,
        );
        if (!_seekScheduled) {
          _seekScheduled = true;
          scheduleMicrotask(_flushSeek);
        }
        result = _result(CommandStatus.accepted);
      case SetRate():
        return Future.value(
          _result(CommandStatus.unsupported, 'rate adapter not implemented'),
        );
    }
    _emit();
    return Future.value(result);
  }

  void _flushSeek() {
    _seekScheduled = false;
    final request = _pendingSeek;
    if (_closed || _seekExecuting || request == null || !_exact(request.token))
      return;
    _seekExecuting = true;
    Future.sync(
          () => _engine.seek(request.target, request.token, request.requestId),
        )
        .then<void>(
          (_) {},
          onError: (Object error, StackTrace stack) {
            if (_exact(request.token)) _fail('seek submission failed: $error');
          },
        )
        .whenComplete(() {
          _seekExecuting = false;
          final next = _pendingSeek;
          if (!_closed &&
              next != null &&
              next.requestId != request.requestId &&
              _exact(next.token))
            _flushSeek();
        });
    _seekTimer?.cancel();
    _seekTimer = Timer(seekConfirmationTimeout, () {
      if (!_closed &&
          _pendingSeek?.requestId == request.requestId &&
          _exact(request.token)) {
        _error = _seekPositionApplied
            ? 'seek frame not confirmed'
            : 'seek position not confirmed';
        _emit();
      }
    });
  }

  void _applyBackground() {
    _causes.removeAll({
      PauseCause.videoPolicy,
      PauseCause.backgroundUnsupported,
    });
    if (!_foreground && _item != null) {
      if (_item!.kind == MediaKind.video) {
        _causes.add(PauseCause.videoPolicy);
      } else if (!_capabilities.backgroundAudio || !_hostReady) {
        _causes.add(PauseCause.backgroundUnsupported);
      }
    }
  }

  void _onEngine(EngineEvent event) {
    if (_closed) return;
    if (event is EngineAvailabilityChanged) {
      if (event.sequence <= _engineAvailabilitySequence) return;
      _engineAvailabilitySequence = event.sequence;
      _engineAvailable = event.available;
      if (!event.available) {
        _causes.add(PauseCause.engineUnavailable);
        _fresh = true;
        _resume = null;
        if (_intent != PlaybackIntent.stopped) _intent = PlaybackIntent.paused;
        _epoch++;
        _pendingSeek = null;
        _seekTimer?.cancel();
      } else {
        _causes.remove(PauseCause.engineUnavailable);
      }
      // Do not claim idle/paused: the physical operation is still unconfirmed.
      _emit();
      return;
    }
    if (!_exact(event.token)) {
      if (event is EngineStateChanged && event.actual == PlaybackActual.playing)
        _compensate(event.token, preserveSource: true);
      return;
    }
    switch (event) {
      case EngineAvailabilityChanged():
        return; // Global availability has been handled before item filtering.
      case EngineStateChanged(:final actual):
        if (actual == PlaybackActual.failed) {
          _fail('engine reported failed state');
          _pauseEngine();
          return;
        }
        if (actual == PlaybackActual.playing &&
            (_intent != PlaybackIntent.playing || _fresh || _policyBlocked)) {
          _pauseEngine();
          return;
        }
        _actual = actual;
        if (actual == PlaybackActual.ended) {
          _intent = PlaybackIntent.paused;
          _fresh = true;
          _resume = null;
        }
      case EngineProgress(:final position, :final duration):
        _position = position;
        if (duration != null && duration >= Duration.zero) _duration = duration;
      case EngineSeekSettled(
        :final requestId,
        :final position,
        :final frameReady,
      ):
        final pending = _pendingSeek;
        if (pending == null ||
            pending.requestId != requestId ||
            (position - pending.target).abs() >
                const Duration(milliseconds: 250))
          return;
        _position = position;
        _seekPositionApplied = true;
        _seekFrameReady = frameReady;
        if (_item?.kind != MediaKind.video || frameReady) {
          _pendingSeek = null;
          _seekTimer?.cancel();
          _error = null;
        }
      case EngineFailure(:final message):
        _fail(message);
        _pauseEngine();
        return;
    }
    _emit();
  }

  void _requestCaptureCleanup(String resourceId) {
    final token = _resourceTokens[resourceId];
    if (token == null || _resources[resourceId] == ResourceState.closed) return;
    _invalidCaptureRequests.add(resourceId);
    if (_resources[resourceId] != ResourceState.unknown)
      _resources[resourceId] = ResourceState.stopping;
    _cleanupRequests.add(
      CaptureCleanupRequest(
        resourceId: resourceId,
        requestToken: token,
        captureEpoch: _captureEpoch,
      ),
    );
  }

  void _onSystem(PlaybackSystemEvent event) {
    if (_closed) return;
    // Resource cleanup can finish after item/account changed. Never lose its ledger.
    if (event is CaptureResourceChanged) {
      if (_resourceTokens[event.resourceId] != event.token) return;
      if (_resources[event.resourceId] == ResourceState.closed &&
          event.state != ResourceState.closed)
        return;
      _resources[event.resourceId] = event.state;
      if ((!_foreground ||
              _invalidCaptureRequests.contains(event.resourceId)) &&
          event.state != ResourceState.closed)
        _requestCaptureCleanup(event.resourceId);
      if (_captureBlocked)
        _causes.add(PauseCause.capture);
      else
        _causes.remove(PauseCause.capture);
      _emit();
      return;
    }
    if (!_session(event.token)) return;
    switch (event) {
      case SystemMediaCommand(:final command):
        if (!_exact(event.token)) return;
        if (command is Open) return;
        unawaited(dispatch(command));
        return;
      case CaptureRequested(:final resourceId):
        if (!_exact(event.token)) return;
        if (_resources.containsKey(resourceId) &&
            _resources[resourceId] != ResourceState.closed)
          return;
        _resourceTokens[resourceId] = event.token;
        _invalidCaptureRequests.remove(resourceId);
        _resources[resourceId] = ResourceState.starting;
        _epoch++;
        _captureEpoch++;
        _intent = PlaybackIntent.paused;
        _fresh = true;
        _resume = null;
        _pendingSeek = null;
        _causes.add(PauseCause.capture);
        _pauseEngine();
        if (!_foreground) _requestCaptureCleanup(resourceId);
      case CaptureResourceChanged(:final resourceId, :final state):
        // A resource update matches its request identity, not the current play epoch.
        if (_resourceTokens[resourceId] != event.token) return;
        _resources[resourceId] = state;
        if (_captureBlocked)
          _causes.add(PauseCause.capture);
        else
          _causes.remove(PauseCause.capture);
      case ForegroundChanged(:final foreground):
        if (!_exact(event.token)) return;
        _foreground = foreground;
        _applyBackground();
        if (!foreground) {
          _captureEpoch++;
          for (final id in _resources.keys.toList()) {
            _requestCaptureCleanup(id);
          }
        }
        if (_causes.contains(PauseCause.videoPolicy) ||
            _causes.contains(PauseCause.backgroundUnsupported)) {
          _epoch++;
          _intent = PlaybackIntent.paused;
          _fresh = true;
          _resume = null;
          _pauseEngine();
        }
      case FocusChanged(:final state, :final holdId, :final mayResume):
        switch (state) {
          case FocusState.transientLoss:
            if (!_exact(event.token)) return;
            if (_focusHolds.isEmpty &&
                _actual == PlaybackActual.playing &&
                _intent == PlaybackIntent.playing &&
                !_fresh)
              _resume = _token;
            _focusHolds[holdId] = event.token;
            _causes.add(PauseCause.focusTransient);
            _pauseEngine();
          case FocusState.permanentLoss:
            final ownsHold = _focusHolds[holdId] == event.token;
            if (!_exact(event.token) && !ownsHold) return;
            // A corresponding old interruption may finish after user Pause,
            // but it cannot delete a newer interruption that reused this id.
            if (ownsHold) _focusHolds.remove(holdId);
            if (_focusHolds.isEmpty) _causes.remove(PauseCause.focusTransient);
            _epoch++;
            _intent = PlaybackIntent.paused;
            _fresh = true;
            _resume = null;
            _causes.add(PauseCause.focusLoss);
            _pauseEngine();
          case FocusState.gained:
            if (_focusHolds[holdId] != event.token) return;
            _focusHolds.remove(holdId);
            if (_focusHolds.isEmpty) _causes.remove(PauseCause.focusTransient);
            final resume = _resume;
            if (!mayResume) {
              _resume = null;
              _fresh = true;
              _intent = PlaybackIntent.paused;
              _epoch++;
              _causes.add(PauseCause.focusLoss);
              _pauseEngine();
            }
            if (mayResume &&
                resume != null &&
                _exact(resume) &&
                _intent == PlaybackIntent.playing &&
                !_fresh &&
                !_policyBlocked) {
              _resume = null;
              final t = _token;
              _run(() => _engine.play(t), t, compensate: true);
            }
        }
      case RouteDisconnected():
        if (!_exact(event.token)) return;
        _epoch++;
        _intent = PlaybackIntent.paused;
        _fresh = true;
        _resume = null;
        _causes.add(PauseCause.routeDisconnected);
        _pauseEngine();
      case SystemSuspended():
        if (!_exact(event.token)) return;
        _epoch++;
        _intent = PlaybackIntent.paused;
        _fresh = true;
        _resume = null;
        _causes.add(PauseCause.systemSuspended);
        _pauseEngine();
      case SystemHostChanged(:final ready):
        if (!_exact(event.token)) return;
        final wasReady = _hostReady;
        _hostReady = ready;
        _applyBackground();
        if (!ready && (wasReady || !_foreground)) {
          _fresh = true;
          _resume = null;
          if (_intent == PlaybackIntent.playing) {
            _epoch++;
            _intent = PlaybackIntent.paused;
            _pauseEngine();
          }
        }
      case CapabilitiesChanged(:final capabilities):
        if (!_exact(event.token)) return;
        _capabilities = capabilities;
        _applyBackground();
        if (_causes.contains(PauseCause.backgroundUnsupported)) {
          _epoch++;
          _intent = PlaybackIntent.paused;
          _fresh = true;
          _resume = null;
          _pauseEngine();
        }
    }
    _emit();
  }

  Future<void> dispose() async {
    if (_closed) return;
    final t = _token;
    _closed = true;
    _resume = null;
    _seekTimer?.cancel();
    await Future.wait([
      _engineSubscription.cancel(),
      _systemSubscription.cancel(),
    ]);
    try {
      await _engine.stop(t).timeout(const Duration(seconds: 2));
    } catch (_) {
      /* disposed cannot claim native cleanup succeeded */
    }
    await _changes.close();
    await _cleanupRequests.close();
  }
}
