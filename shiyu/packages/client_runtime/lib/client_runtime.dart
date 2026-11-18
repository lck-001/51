library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:client_shell/client_shell.dart';
import 'package:learning_core/learning_core.dart';
import 'package:learning_playback/learning_playback.dart';
import 'package:material_core/material_core.dart';
import 'package:playback_core/playback_core.dart';

enum ClientRuntimeErrorCode {
  ownerMismatch,
  bindingMismatch,
  notReady,
  openPending,
  openRejected,
  closed,
}

final class ClientRuntimeException implements Exception {
  const ClientRuntimeException(this.code);
  final ClientRuntimeErrorCode code;
  @override
  String toString() => 'ClientRuntimeException(${code.name})';
}

/// The app owns all injected stores, coordinator and native playback host.
/// This bridge owns only subscriptions and a read-only atomic view notifier.
final class ShiyuClientRuntime {
  ShiyuClientRuntime.attach({
    required this.materials,
    required this.learning,
    required this.playback,
    required this.coordinator,
  }) {
    if (materials.trustedOwnerId != learning.trustedOwnerId) {
      throw const ClientRuntimeException(ClientRuntimeErrorCode.ownerMismatch);
    }
    _coordinatorEvents = coordinator.snapshots.listen(
      (_) => _publish(),
      onError: (Object _) => _clear(),
    );
    _playbackEvents = playback.snapshots.listen(
      (_) => _publish(),
      onError: (Object _) => _clear(),
    );
  }
  final MaterialStore materials;
  final LearningStore learning;
  final Playback playback;
  final LearningPlaybackCoordinator coordinator;
  final _view = ValueNotifier<ClientPlaybackView>(const ClientPlaybackView());
  late final StreamSubscription<LearningPlaybackSnapshot> _coordinatorEvents;
  late final StreamSubscription<PlaybackSnapshot> _playbackEvents;
  LearningBinding? _requested;
  bool _closed = false, _opening = false;
  int _epoch = 0;
  ValueListenable<ClientPlaybackView> get playbackView => _view;

  void _clear() {
    if (!_closed) _view.value = const ClientPlaybackView();
  }

  bool _bound(LearningBinding expected, {PlaybackToken? expectedToken}) {
    final state = coordinator.current,
        snapshot = playback.current,
        item = snapshot.item,
        token = state.token;
    return !_closed &&
        _requested != null &&
        _requested!.sameAs(expected) &&
        expected.ownerId == materials.trustedOwnerId &&
        state.binding != null &&
        state.binding!.sameAs(expected) &&
        token != null &&
        snapshot.token == token &&
        (expectedToken == null || snapshot.token == expectedToken) &&
        item != null &&
        item.ownerId == expected.ownerId &&
        item.itemId == expected.learningVersionId &&
        item.itemRevision == expected.mediaVersionId &&
        item.kind == MediaKind.audio;
  }

  void _publish() {
    if (_closed) return;
    final binding = _requested;
    if (_opening ||
        binding == null ||
        coordinator.current.phase != LearningPlaybackPhase.ready ||
        coordinator.current.error != null ||
        !_bound(binding) ||
        !playback.current.engineAvailable) {
      _clear();
      return;
    }
    // Read both current values synchronously; never relabel the callback payload
    // of an older event with a newly selected learning version.
    _view.value = ClientPlaybackView(
      learningVersionId: binding.learningVersionId,
      snapshot: playback.current,
    );
  }

  Future<void> openLearning(LearningVersion expected) async {
    if (_closed)
      throw const ClientRuntimeException(ClientRuntimeErrorCode.closed);
    final epoch = ++_epoch;
    _opening = true;
    _requested = null;
    _clear();
    try {
      if (expected.binding.ownerId != materials.trustedOwnerId) {
        throw const ClientRuntimeException(
          ClientRuntimeErrorCode.ownerMismatch,
        );
      }
      final actual = await learning.readVersion(
        expected.binding.learningVersionId,
      );
      if (_closed || epoch != _epoch) return;
      if (!actual.binding.sameAs(expected.binding)) {
        throw const ClientRuntimeException(
          ClientRuntimeErrorCode.bindingMismatch,
        );
      }
      if (actual.state != LearningState.ready) {
        throw const ClientRuntimeException(ClientRuntimeErrorCode.notReady);
      }
      _requested = actual.binding;
      final result = await coordinator.open(actual.binding.learningVersionId);
      if (_closed || epoch != _epoch) return;
      if (result.status == LearningOpenStatus.pending) {
        throw const ClientRuntimeException(ClientRuntimeErrorCode.openPending);
      }
      if (result.status != LearningOpenStatus.ready ||
          result.session == null ||
          !result.session!.binding.sameAs(actual.binding) ||
          !_bound(actual.binding)) {
        throw const ClientRuntimeException(ClientRuntimeErrorCode.openRejected);
      }
    } on ClientRuntimeException {
      rethrow;
    } catch (_) {
      throw const ClientRuntimeException(ClientRuntimeErrorCode.openRejected);
    } finally {
      if (!_closed && epoch == _epoch) {
        _opening = false;
        _publish();
      }
    }
  }

  Future<CommandResult> command(
    LearningVersion expected,
    PlaybackCommand command, {
    PlaybackToken? expectedToken,
  }) async {
    CommandResult reject(String reason) => CommandResult(
      CommandStatus.rejected,
      token: playback.current.token,
      reason: reason,
    );
    if (_closed) return reject('runtime_closed');
    if (command is Open) return reject('use_learning_open');
    if (_opening || !_bound(expected.binding, expectedToken: expectedToken)) {
      return reject('learning_context_mismatch');
    }
    if ((command is Play || command is Seek) &&
        (coordinator.current.phase != LearningPlaybackPhase.ready ||
            coordinator.current.error != null)) {
      return reject('not_ready');
    }
    final epoch = _epoch;
    CommandResult result;
    try {
      result = await coordinator.dispatch(command);
    } catch (_) {
      return reject('command_unconfirmed');
    }
    if (_closed ||
        epoch != _epoch ||
        !_bound(expected.binding) ||
        !playback.current.token.sameSession(result.token))
      return reject('superseded');
    _publish();
    return result;
  }

  /// Actual Widget assembly; the Widget receives only stores/callbacks/view.
  /// Optional dictionary/practice callbacks remain explicitly supplied by the app.
  ShiyuClientShell createShell({
    Key? key,
    WordLookupCallback? onLookupWord,
    PracticeCallback? onPractice,
    Future<void> Function()? onRootBack,
  }) {
    if (_closed)
      throw const ClientRuntimeException(ClientRuntimeErrorCode.closed);
    return ShiyuClientShell(
      key: key,
      materials: materials,
      learning: learning,
      playback: playbackView,
      onOpenLearning: openLearning,
      onPlaybackCommand: (expected, command) => this.command(
        expected,
        command,
        expectedToken: _view.value.snapshot?.token,
      ),
      onLookupWord: onLookupWord,
      onPractice: onPractice,
      onRootBack: onRootBack,
    );
  }

  Future<void> detach() async {
    if (_closed) return;
    _epoch++;
    _requested = null;
    _closed = true;
    await _coordinatorEvents.cancel();
    await _playbackEvents.cancel();
    _view.dispose();
    // No Stop/dispose/close on injected objects: native shutdown belongs to the
    // app's reviewed host lifecycle, not ordinary page unsubscribe.
  }
}
