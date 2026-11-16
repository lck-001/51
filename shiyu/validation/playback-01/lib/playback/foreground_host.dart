import 'dart:async';

import 'package:playback_core/playback_core.dart';

import 'playback_host.dart';

/// Conservative real fallback for platforms without a reviewed system host.
final class ForegroundPlaybackHost implements PlaybackHost {
  final _events = StreamController<PlaybackSystemEvent>.broadcast(sync: true);
  PlaybackController? _controller;
  bool _foreground = true;
  @override
  PlaybackCapabilities get capabilities => const PlaybackCapabilities();
  @override
  Stream<PlaybackSystemEvent> get events => _events.stream;
  @override
  void bind(PlaybackController controller) => _controller = controller;
  @override
  void appForeground(bool value) {
    _foreground = value;
    final c = _controller;
    if (c != null) _events.add(ForegroundChanged(c.current.token, value));
  }

  @override
  Future<bool> preparePlay(PlaybackToken token) async =>
      _foreground && _controller?.current.token == token;
  @override
  Future<void> publish(PlaybackSnapshot snapshot) async {}
  @override
  Future<bool> backgroundHostReady() async => false;
  @override
  Future<void> close() => _events.close();
}
