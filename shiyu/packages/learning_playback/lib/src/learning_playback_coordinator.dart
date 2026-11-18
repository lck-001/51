import 'dart:async';

import 'package:learning_core/learning_core.dart';
import 'package:playback_core/playback_core.dart';

import '../learning_playback.dart';

final class LearningPlaybackCoordinator {
  LearningPlaybackCoordinator({
    required LearningStore learning,
    required Playback playback,
    required FilePlayableCache mediaCache,
    this.readinessTimeout = const Duration(seconds: 5),
  }) : _learning = learning,
       _playback = playback,
       _cache = mediaCache {
    if (learning.trustedOwnerId != mediaCache.trustedOwnerId ||
        readinessTimeout <= Duration.zero) {
      throw const LearningPlaybackException(
        LearningPlaybackErrorCode.invalidInput,
      );
    }
    _subscription = _playback.snapshots.listen(
      _onSnapshot,
      onError: (Object _) {
        _saveBlocked = true;
        _error = 'playback_stream_failed';
        _emit();
      },
    );
  }
  final LearningStore _learning;
  final Playback _playback;
  final FilePlayableCache _cache;
  final Duration readinessTimeout;
  final _changes = StreamController<LearningPlaybackSnapshot>.broadcast(
    sync: true,
  );
  final _wake = StreamController<void>.broadcast(sync: true);
  late StreamSubscription<PlaybackSnapshot> _subscription;
  LearningPlaybackSession? _session;
  LearningVersion? _version;
  PlaybackToken? _token;
  LearningPlaybackPhase _phase = LearningPlaybackPhase.idle;
  String? _error;
  int _generation = 0, _manual = 0, _revision = 0, _lastEpoch = 0;
  bool _closed = false,
      _saving = false,
      _restored = false,
      _saveBlocked = false;
  bool _protectCheckpoint = false;
  PlaybackToken? _manualSeekToken;
  int? _savedMs;
  String? _savedSentence;
  Future<void> _saveTail = Future<void>.value();
  LearningPlaybackSnapshot get current => LearningPlaybackSnapshot(
    phase: _phase,
    checkpointRevision: _revision,
    checkpointRestored: _restored,
    binding: _session?.binding,
    token: _token,
    error: _error,
  );
  Stream<LearningPlaybackSnapshot> get snapshots => _changes.stream;
  bool _own(int generation) => !_closed && _generation == generation;
  void _emit() {
    if (!_changes.isClosed) _changes.add(current);
  }

  void _signal() {
    if (!_wake.isClosed) _wake.add(null);
  }

  bool _matches(PlaybackSnapshot s) {
    final session = _session, token = _token, item = s.item;
    return session != null &&
        token != null &&
        item != null &&
        s.token.sameSession(token) &&
        item.ownerId == session.binding.ownerId &&
        item.itemId == session.item.itemId &&
        item.itemRevision == session.item.itemRevision &&
        item.kind == MediaKind.audio;
  }

  bool _loaded(PlaybackSnapshot s) {
    final duration = _version?.media?.durationMs;
    return _matches(s) &&
        s.engineAvailable &&
        s.error == null &&
        s.duration != null &&
        s.duration! > Duration.zero &&
        duration != null &&
        (s.duration!.inMilliseconds - duration).abs() <= 250 &&
        (s.actual == PlaybackActual.paused ||
            s.actual == PlaybackActual.playing ||
            s.actual == PlaybackActual.ended);
  }

  Future<bool> _wait(
    int generation,
    bool Function(PlaybackSnapshot) test, {
    bool Function()? abort,
  }) async {
    final done = Completer<bool>();
    void check() {
      if (done.isCompleted) return;
      final s = _playback.current;
      if (!_own(generation) ||
          (abort?.call() ?? false) ||
          (_token != null && !s.token.sameSession(_token!)) ||
          s.actual == PlaybackActual.failed ||
          !s.engineAvailable) {
        done.complete(false);
      } else if (test(s)) {
        done.complete(true);
      }
    }

    final snapshots = _playback.snapshots.listen(
      (_) => check(),
      onError: (Object _) {
        if (!done.isCompleted) done.complete(false);
      },
    );
    final wakes = _wake.stream.listen((_) => check());
    final timer = Timer(readinessTimeout, () {
      if (!done.isCompleted) done.complete(false);
    });
    check();
    try {
      return await done.future;
    } finally {
      timer.cancel();
      await snapshots.cancel();
      await wakes.cancel();
    }
  }

  LearningOpenResult _superseded() => const LearningOpenResult(
    LearningOpenStatus.superseded,
    reason: 'superseded',
  );
  Future<LearningOpenResult> open(
    String learningVersionId, {
    bool restorePosition = true,
  }) async {
    if (_closed)
      return const LearningOpenResult(
        LearningOpenStatus.rejected,
        reason: 'closed',
      );
    final generation = ++_generation, manual = _manual;
    _session = null;
    _version = null;
    _token = null;
    _revision = 0;
    _lastEpoch = 0;
    _saving = false;
    _restored = false;
    _saveBlocked = false;
    _protectCheckpoint = false;
    _savedMs = null;
    _savedSentence = null;
    _manualSeekToken = null;
    _error = null;
    _phase = LearningPlaybackPhase.preparing;
    _emit();
    _signal();
    try {
      final version = await _learning.readVersion(learningVersionId);
      if (!_own(generation)) return _superseded();
      if (version.state != LearningState.ready) {
        throw const LearningPlaybackException(
          LearningPlaybackErrorCode.notReady,
        );
      }
      final session = await _learning.openPlayback(learningVersionId);
      if (!_own(generation)) return _superseded();
      final prepared = await _cache.prepare(session.item);
      if (!_own(generation)) return _superseded();
      if (!prepared.binding.sameAs(session.binding)) {
        throw const LearningPlaybackException(
          LearningPlaybackErrorCode.bindingMismatch,
        );
      }
      final checkpoint = await _learning.restoreProgress(learningVersionId);
      if (!_own(generation)) return _superseded();
      if (checkpoint != null && !checkpoint.binding.sameAs(session.binding)) {
        throw const LearningPlaybackException(
          LearningPlaybackErrorCode.bindingMismatch,
        );
      }
      _session = session;
      _version = version;
      _revision = session.progressRevision;
      _savedMs = checkpoint?.position.inMilliseconds;
      _savedSentence = checkpoint?.sentenceId;
      _phase = LearningPlaybackPhase.opening;
      _emit();
      final accepted = await _playback.dispatch(Open(session.item));
      if (!_own(generation)) return _superseded();
      if (!accepted.accepted ||
          !_playback.current.token.sameSession(accepted.token)) {
        _phase = LearningPlaybackPhase.failed;
        _error = 'open_rejected';
        _emit();
        return LearningOpenResult(
          LearningOpenStatus.rejected,
          session: session,
          reason: _error,
        );
      }
      _token = accepted.token;
      _phase = LearningPlaybackPhase.awaitingLoad;
      _emit();
      final loaded = await _wait(generation, _loaded);
      if (!_own(generation)) return _superseded();
      if (!loaded) {
        _error = 'load_unconfirmed';
        _emit();
        return LearningOpenResult(
          LearningOpenStatus.pending,
          session: session,
          reason: _error,
        );
      }
      final canRestore =
          restorePosition &&
          checkpoint != null &&
          _manual == manual &&
          _playback.current.token.commandEpoch == accepted.token.commandEpoch;
      if (canRestore) {
        _phase = LearningPlaybackPhase.restoring;
        _emit();
        final seek = await _playback.dispatch(Seek(checkpoint.position));
        if (!_own(generation)) return _superseded();
        if (!seek.accepted) {
          _error = 'restore_rejected';
          _emit();
          return LearningOpenResult(
            LearningOpenStatus.pending,
            session: session,
            reason: _error,
          );
        }
        final settled = await _wait(
          generation,
          (s) =>
              _loaded(s) &&
              s.token == seek.token &&
              s.pendingSeek == null &&
              s.seekPositionApplied &&
              (s.position - checkpoint.position).abs() <=
                  const Duration(milliseconds: 250),
          abort: () =>
              _manual != manual ||
              _playback.current.token.commandEpoch != seek.token.commandEpoch,
        );
        if (!_own(generation)) return _superseded();
        if (settled) {
          _restored = true;
        } else if (_manual == manual &&
            _playback.current.token.commandEpoch == seek.token.commandEpoch) {
          _error = 'restore_unconfirmed';
          _emit();
          return LearningOpenResult(
            LearningOpenStatus.pending,
            session: session,
            reason: _error,
          );
        }
      }
      if (!_loaded(_playback.current)) {
        _error = 'load_unconfirmed';
        _emit();
        return LearningOpenResult(
          LearningOpenStatus.pending,
          session: session,
          reason: _error,
        );
      }
      _protectCheckpoint = checkpoint != null && !_restored;
      _saving = !_protectCheckpoint;
      _phase = LearningPlaybackPhase.ready;
      _error = null;
      _emit();
      _onSnapshot(_playback.current);
      return LearningOpenResult(
        LearningOpenStatus.ready,
        session: session,
        checkpointRestored: _restored,
      );
    } catch (_) {
      if (!_own(generation)) return _superseded();
      _saving = false;
      _phase = LearningPlaybackPhase.failed;
      _error = 'source_or_cache_unavailable';
      _emit();
      return LearningOpenResult(
        LearningOpenStatus.rejected,
        session: _session,
        reason: _error,
      );
    }
  }

  void _onSnapshot(PlaybackSnapshot s) {
    if (_closed || !_matches(s) || s.token.commandEpoch < _lastEpoch) return;
    _lastEpoch = s.token.commandEpoch;
    _token = s.token;
    if (_phase != LearningPlaybackPhase.ready) return;
    if (!s.engineAvailable ||
        s.actual == PlaybackActual.failed ||
        s.error != null) {
      _saving = false;
      _phase = LearningPlaybackPhase.failed;
      _error = !s.engineAvailable
          ? 'engine_unavailable'
          : s.pendingSeek != null
          ? 'seek_unconfirmed'
          : 'playback_unconfirmed';
      _emit();
      return;
    }
    if (_protectCheckpoint) {
      final manualSeek = _manualSeekToken;
      if ((s.intent == PlaybackIntent.playing &&
              s.actual == PlaybackActual.playing) ||
          (manualSeek != null &&
              s.token == manualSeek &&
              s.pendingSeek == null &&
              s.seekPositionApplied)) {
        _protectCheckpoint = false;
        _saving = true;
        _manualSeekToken = null;
      }
    }
    if (!_saving || _saveBlocked || !_loaded(s) || s.pendingSeek != null)
      return;
    _queueCheckpoint(s);
  }

  void _queueCheckpoint(PlaybackSnapshot s) {
    final session = _session, version = _version;
    if (session == null || version == null || s.position < Duration.zero)
      return;
    final anchors = version.sentences.where(
      (a) =>
          a.startMs != null &&
          a.endMs != null &&
          s.position.inMilliseconds >= a.startMs! &&
          (s.position.inMilliseconds < a.endMs! ||
              (s.position.inMilliseconds == version.media!.durationMs &&
                  s.position.inMilliseconds == a.endMs!)),
    );
    if (anchors.isEmpty) return;
    final sentence = anchors.first.sentenceId, generation = _generation;
    _saveTail = _saveTail.then((_) async {
      if (!_own(generation) ||
          _session?.sessionId != session.sessionId ||
          _saveBlocked ||
          !_saving ||
          !_matches(s) ||
          s.token.commandEpoch != _playback.current.token.commandEpoch ||
          _playback.current.pendingSeek != null ||
          !_loaded(_playback.current))
        return;
      if (_savedMs == s.position.inMilliseconds && _savedSentence == sentence)
        return;
      try {
        final checkpoint = await _learning.saveProgress(
          session: session,
          expectedRevision: _revision,
          sentenceId: sentence,
          position: s.position,
        );
        if (!_own(generation) || _session?.sessionId != session.sessionId)
          return;
        if (!checkpoint.binding.sameAs(session.binding)) {
          throw const LearningPlaybackException(
            LearningPlaybackErrorCode.bindingMismatch,
          );
        }
        _revision = checkpoint.revision;
        _savedMs = checkpoint.position.inMilliseconds;
        _savedSentence = checkpoint.sentenceId;
        _emit();
      } catch (_) {
        if (!_own(generation) || _session?.sessionId != session.sessionId)
          return;
        _saveBlocked = true;
        _error = 'checkpoint_failed';
        _emit();
      }
    });
  }

  /// Open must use open(); explicit user playback commands share the Playback Interface.
  Future<CommandResult> dispatch(PlaybackCommand command) async {
    CommandResult rejected(String reason) => CommandResult(
      CommandStatus.rejected,
      token: _playback.current.token,
      reason: reason,
    );
    if (_closed) return rejected('closed');
    if (command is Open) return rejected('use_learning_open');
    if (command is Play || command is Seek) {
      final observed = _playback.current;
      // Native Stop unloads its source and reports idle. Fresh explicit Play is
      // allowed to reload that same verified session; Seek still requires load.
      // This is only admission, never evidence of actual playing or progress.
      final stoppedReplay = command is Play &&
          _matches(observed) &&
          observed.engineAvailable &&
          observed.error == null &&
          observed.pendingSeek == null &&
          observed.intent == PlaybackIntent.stopped &&
          observed.actual == PlaybackActual.idle;
      if (_phase != LearningPlaybackPhase.ready ||
          (!_loaded(observed) && !stoppedReplay))
        return rejected('not_ready');
    }
    _manual++;
    _manualSeekToken = null;
    _signal();
    if (command is Stop) {
      if (_saving && _loaded(_playback.current))
        _queueCheckpoint(_playback.current);
      // Retain the last valid checkpoint across the stop/reset observation.
      // A subsequent confirmed manual seek or actual fresh playing can resume
      // saving; the Stop acknowledgement or its zero position cannot do so.
      _protectCheckpoint = true;
      _saving = false;
    }
    final result = await _playback.dispatch(command);
    if (_closed) return result;
    if (command is Seek && result.accepted) {
      _manualSeekToken = result.token;
      _onSnapshot(_playback.current);
    }
    return result;
  }

  Future<void> flushProgress() async {
    if (_closed)
      throw const LearningPlaybackException(LearningPlaybackErrorCode.closed);
    if (_phase != LearningPlaybackPhase.ready ||
        !_saving ||
        !_loaded(_playback.current) ||
        _playback.current.pendingSeek != null) {
      throw const LearningPlaybackException(LearningPlaybackErrorCode.notReady);
    }
    await _saveTail;
    if (_saveBlocked)
      throw const LearningPlaybackException(
        LearningPlaybackErrorCode.checkpointFailed,
      );
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _generation++;
    _saving = false;
    _session = null;
    _phase = LearningPlaybackPhase.closed;
    _emit();
    _signal();
    await _subscription.cancel();
    await _saveTail;
    await _changes.close();
    await _wake.close();
    // Playback, native resources and caller-owned stores remain the app's responsibility.
  }
}
