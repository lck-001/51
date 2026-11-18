import 'dart:async';

import 'package:playback_core/playback_core.dart';

class EngineCall {
  EngineCall(this.name, this.token, {this.item, this.position, this.requestId});
  final String name;
  final PlaybackToken token;
  final PlaybackItem? item;
  final Duration? position;
  final int? requestId;
}

/// Work acknowledgements and native observations are intentionally separate.
/// No Player, audio device or platform API is created by these adapters.
class ControlledEngine implements PlaybackEngineAdapter {
  final source = StreamController<EngineEvent>.broadcast(sync: true);
  final calls = <EngineCall>[];
  Completer<void>? nextOpen, nextSeek;
  @override
  Stream<EngineEvent> get events => source.stream;
  @override
  Future<void> open(PlaybackItem item, PlaybackToken token) {
    calls.add(EngineCall('open', token, item: item));
    final gate = nextOpen;
    nextOpen = null;
    return gate?.future ?? Future<void>.value();
  }

  @override
  Future<void> play(PlaybackToken token) async {
    calls.add(EngineCall('play', token));
  }

  @override
  Future<void> pause(PlaybackToken token) async {
    calls.add(EngineCall('pause', token));
  }

  @override
  Future<void> stop(PlaybackToken token) async {
    calls.add(EngineCall('stop', token));
  }

  @override
  Future<void> seek(Duration position, PlaybackToken token, int requestId) {
    calls.add(
      EngineCall('seek', token, position: position, requestId: requestId),
    );
    final gate = nextSeek;
    nextSeek = null;
    return gate?.future ?? Future<void>.value();
  }

  int count(String name) => calls.where((call) => call.name == name).length;
  EngineCall last(String name) => calls.lastWhere((call) => call.name == name);
  void emit(EngineEvent event) => source.add(event);
}

class ControlledSystem implements SystemPlaybackAdapter {
  @override
  PlaybackCapabilities get capabilities =>
      const PlaybackCapabilities(seek: true);
  final source = StreamController<PlaybackSystemEvent>.broadcast(sync: true);
  final publications = <PlaybackSnapshot>[];
  @override
  Stream<PlaybackSystemEvent> get events => source.stream;
  @override
  Future<void> publish(PlaybackSnapshot snapshot) async {
    publications.add(snapshot);
  }
}

Future<void> settle([int turns = 12]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
