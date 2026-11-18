/// App-owned shutdown sequencing. Business retirement is permanent; a failed
/// exit attempt can retry uncompleted steps without closing a store twice.
/// No callback acknowledgement here is a substitute for native Stop evidence.
final class ClientShutdown {
  ClientShutdown({
    required this.freezeBusiness,
    required this.retireBookkeeping,
    required this.stopAndRelease,
    required this.closeLearning,
    required this.closeMaterials,
    required this.closeHost,
    required this.exitApplication,
    this.afterStoresClosed,
  });

  final void Function() freezeBusiness;
  final Future<void> Function() retireBookkeeping;
  final Future<void> Function() stopAndRelease;
  final Future<void> Function() closeLearning, closeMaterials, closeHost;
  final Future<void> Function() exitApplication;
  final Future<void> Function()? afterStoresClosed;
  bool _retired = false, _exitInFlight = false;
  bool _learningClosed = false, _materialsClosed = false;
  bool _authorityReleased = false;
  Future<void>? _retirement, _draining, _hostClose;

  void retire() {
    if (_retired) return;
    _retired = true;
    freezeBusiness();
    _retirement = retireBookkeeping();
    // The original failed Future remains observable to the close path. Retain
    // failure rather than pretending repeated dispose on a closed object works.
    _retirement!.ignore();
  }

  Future<void> _drain() async {
    await _retirement;
    if (!_learningClosed) {
      await closeLearning();
      _learningClosed = true;
    }
    if (!_materialsClosed) {
      await closeMaterials();
      _materialsClosed = true;
    }
    if (!_authorityReleased) {
      await afterStoresClosed?.call();
      _authorityReleased = true;
    }
  }

  /// Windows must await this before native release/closeReady. A callback delay
  /// in a media library cannot prove queued disk writes finished.
  Future<void> drainStores() async {
    retire();
    final inFlight = _draining;
    if (inFlight != null) return inFlight;
    final attempt = _drain();
    _draining = attempt;
    try {
      await attempt;
    } finally {
      if (identical(_draining, attempt)) _draining = null;
    }
  }

  Future<void> requestExit() async {
    if (_exitInFlight) return;
    _exitInFlight = true;
    try {
      retire();
      // Slow/failed bookkeeping must not prevent the first safety Stop.
      // drainStores still requires successful retirement before host/app exit.
      await stopAndRelease();
      await drainStores();
      // A timeout does not cancel closeHost. Keep that exact operation so a
      // second exit never treats a host's internal _closing no-op as success.
      _hostClose ??= closeHost();
      await _hostClose!.timeout(const Duration(seconds: 15));
      await exitApplication();
    } finally {
      _exitInFlight = false;
    }
  }
}
