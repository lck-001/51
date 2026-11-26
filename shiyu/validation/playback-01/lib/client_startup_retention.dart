import 'dart:async';
import 'dart:math';

import 'package:agent_bridge/agent_bridge_contracts.dart';

/// One startup attempt, not an authority/Store registry. RootLock owns its A.
enum ClientStartupRef {
  owner,
  storage,
  lease,
  rootLock,
  materials,
  learning,
  media,
  bridge,
  cache,
  importer,
  host,
  engine,
  playback,
  coordinator,
  runtime,
  assistantEvents,
}

enum ClientStartupOperation {
  mediaKit,
  privateRootOpen,
  materialsOpen,
  learningOpen,
  mediaOpen,
  hostNativeCreate,
  hostNativeRetire,
  ownerOpen,
}

enum ClientStartupCleanup {
  retireCache,
  retireImporter,
  retireBridge,
  closeImporter,
  drainCache,
  closeBridge,
  closeMedia,
  closeLearning,
  closeMaterials,
  releaseAuthority,
  retireApplication,
  disposePlayback,
  disposeEngine,
  closeHost,
  detachFailedHost,
  cancelEvents,
  disposeOwnerSignals,
}

enum ClientStartupWorkState { pending, returned, failed }

final class _StartupWork {
  _StartupWork(this.original);
  final Future<dynamic> original;
  Object? error;
  StackTrace? errorStack;
  ClientStartupWorkState state = ClientStartupWorkState.pending;
}

final class RetainedStartupFailure implements Exception {
  RetainedStartupFailure(this.primaryError, this.primaryStack, this.token);
  final Object primaryError;
  final StackTrace primaryStack;
  final ClientStartupAttempt token;
  bool get isRootBusy =>
      primaryError is AgentBridgeException &&
      (primaryError as AgentBridgeException).code ==
          AgentBridgeErrorCode.rootBusy;
  @override
  String toString() => 'RetainedStartupFailure(startupUnconfirmed)';
}

final class ClientStartupAttempt {
  ClientStartupAttempt({
    String? id,
    this.validationOnly = false,
    ClientStartupResident? resident,
  }) : id = id ?? _newId(),
       _resident = resident ?? ClientStartupResident.process {
    if (_resident.current != null) {
      throw StateError('startup failure still resident');
    }
  }
  final bool validationOnly;
  final ClientStartupResident _resident;
  final String id;
  static String _newId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  final _refs = <ClientStartupRef, Object>{};
  final _operations = <ClientStartupOperation, _StartupWork>{};
  final _cleanups = <ClientStartupCleanup, _StartupWork>{};
  final _cleanupEntering = <ClientStartupCleanup>{};
  Object? _primary;
  StackTrace? _stack;
  bool _released = false, _handedOff = false, _releaseRequested = false;
  final _knownReleased = <ClientStartupRef>{};
  (ClientStartupRef, Object)? _requestedHandoff;
  bool mediaLibraryAttempted = false, mediaLibraryReturned = false;
  Timer? _residentTimer;
  final _residentWait = Completer<void>();

  void retain(ClientStartupRef kind, Object value) {
    if (_released || _handedOff) throw StateError('startup ownership ended');
    final old = _refs[kind];
    if (old != null && !identical(old, value)) {
      throw StateError('startup reference replaced');
    }
    _refs[kind] = value;
  }

  bool retains(ClientStartupRef kind, Object value) =>
      identical(_refs[kind], value);
  bool get failed => _primary != null;
  bool get hasPending => [
    ..._operations.values,
    ..._cleanups.values,
  ].any((w) => w.state == ClientStartupWorkState.pending);
  bool get cleanupFailed =>
      _cleanups.values.any((w) => w.state == ClientStartupWorkState.failed);
  bool get resourcesEnded => _released || _handedOff;

  Future<T> observe<T>(ClientStartupOperation step, Future<T> original) {
    final existing = _operations[step];
    if (existing != null) {
      if (!identical(existing.original, original)) {
        throw StateError('startup original future replaced');
      }
      return original;
    }
    final work = _StartupWork(original);
    _operations[step] = work;
    _watch(work);
    return original; // Never substitute a timeout or cancellation Future.
  }

  Future<void> cleanup(
    ClientStartupCleanup step,
    FutureOr<void> Function() action,
  ) {
    final existing = _cleanups[step];
    if (existing != null) return existing.original as Future<void>;
    if (!_cleanupEntering.add(step)) {
      throw StateError('startup cleanup reentrant admission rejected');
    }
    late Future<void> original;
    try {
      original = Future<void>.sync(action);
    } finally {
      _cleanupEntering.remove(step);
    }
    final work = _StartupWork(original);
    _cleanups[step] = work;
    _watch(work);
    return original;
  }

  void _watch(_StartupWork work) {
    work.original
        .then<void>(
          (_) {
            work.state = ClientStartupWorkState.returned;
            _completeRequestedRelease();
            _completeRequestedHandoff();
          },
          onError: (Object error, StackTrace stack) {
            work.error = error;
            work.errorStack = stack;
            work.state = ClientStartupWorkState.failed;
            _completeRequestedRelease();
          },
        )
        .ignore();
  }

  RetainedStartupFailure fail(Object error, StackTrace stack) {
    if (_handedOff && _requestedHandoff != null) {
      _handedOff = false;
      _refs[_requestedHandoff!.$1] = _requestedHandoff!.$2;
    }
    if (error is RetainedStartupFailure) {
      if (!identical(error.token, this)) {
        throw StateError('startup attempt changed');
      }
      _primary ??= error.primaryError;
      _stack ??= error.primaryStack;
    } else {
      _primary ??= error;
      _stack ??= stack;
    }
    _resident.retain(this);
    return RetainedStartupFailure(_primary!, _stack!, this);
  }

  T? retained<T>(ClientStartupRef kind) => _refs[kind] as T?;

  Future<void> operationSettled(ClientStartupOperation step) async {
    final work = _operations[step];
    if (work != null) {
      await work.original.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      );
    }
  }

  void markReleased(ClientStartupRef kind) => _knownReleased.add(kind);

  void releasedAfterCleanup() {
    if (cleanupFailed) throw StateError('startup cleanup failed');
    _releaseRequested = true;
    _completeRequestedRelease(); // ownerOpen may still be the current async frame; observe its original settlement.
  }

  void _completeRequestedRelease() {
    if (_releaseRequested && !hasPending && !cleanupFailed) {
      _released = true;
      _refs.clear();
      _maybeLeaveResident();
    }
  }

  void handoff(ClientStartupRef kind, Object completeOwner) {
    if (failed || !retains(kind, completeOwner)) {
      throw StateError('startup handoff unconfirmed');
    }
    _requestedHandoff = (kind, completeOwner);
    _completeRequestedHandoff();
  }

  void _completeRequestedHandoff() {
    if (_requestedHandoff != null && !failed && !hasPending && !cleanupFailed) {
      _handedOff = true;
      _refs.clear();
      _maybeLeaveResident();
    }
  }

  void _maybeLeaveResident() {
    if (resourcesEnded && !hasPending && !mediaLibraryAttempted) {
      _residentTimer?.cancel();
      _residentTimer = null;
      _resident.release(this);
    }
  }

  Future<void> holdResident() {
    _resident.retain(this);
    _residentTimer ??= Timer.periodic(const Duration(seconds: 30), (_) {});
    return _residentWait.future; // Real timer + slot + caller control frame retain unknown startup.
  }

  Map<String, Object?> snapshot() => {
    'attempt': id,
    'failed': failed,
    'primaryFailure': _primary == null
        ? null
        : {
            'type': _primary.runtimeType.toString(),
            'rootBusy':
                _primary is AgentBridgeException &&
                (_primary as AgentBridgeException).code ==
                    AgentBridgeErrorCode.rootBusy,
          },
    'cleanupFailures': [
      for (final e in _cleanups.entries)
        if (e.value.state == ClientStartupWorkState.failed)
          {'step': e.key.name, 'type': e.value.error.runtimeType.toString()},
    ],
    'rootBusy':
        _primary is AgentBridgeException &&
        (_primary as AgentBridgeException).code ==
            AgentBridgeErrorCode.rootBusy,
    'actualRefsRetained': _refs.keys.map((r) => r.name).toList(growable: false),
    'mediaLibraryAttempted': mediaLibraryAttempted,
    'mediaLibraryReturned': mediaLibraryReturned,
    'mediaLibraryReleaseVerified': false,
    'resourcesEnded': resourcesEnded,
    'handoffComplete': _handedOff,
    'cleanupReleased': _released,
    'knownReleased': _knownReleased.map((r) => r.name).toList(growable: false),
    'unknown': failed && (!resourcesEnded || mediaLibraryAttempted),
    'pending': hasPending,
    'cleanupFailed': cleanupFailed,
    'operations': {
      for (final e in _operations.entries) e.key.name: e.value.state.name,
    },
    'cleanup': {
      for (final e in _cleanups.entries) e.key.name: e.value.state.name,
    },
  };
}

/// Single process resident failure slot, never a second A/Store/supervisor.
final class ClientStartupResident {
  ClientStartupResident();
  static final process = ClientStartupResident();
  ClientStartupAttempt? _attempt;
  ClientStartupAttempt? get current => _attempt;
  void retain(ClientStartupAttempt attempt) {
    if (_attempt != null && !identical(_attempt, attempt)) {
      throw StateError('unresolved startup attempt already resident');
    }
    _attempt = attempt;
  }

  void release(ClientStartupAttempt attempt) {
    if (identical(_attempt, attempt) &&
        attempt.resourcesEnded &&
        !attempt.hasPending &&
        !attempt.mediaLibraryAttempted) {
      _attempt = null;
    }
  }
}
