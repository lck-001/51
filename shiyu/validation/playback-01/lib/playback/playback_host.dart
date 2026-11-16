import 'package:playback_core/playback_core.dart';

abstract interface class PlaybackHost implements SystemPlaybackAdapter {
  void bind(PlaybackController controller);
  void appForeground(bool foreground);
  Future<bool> preparePlay(PlaybackToken token);
  Future<bool> backgroundHostReady();
  Future<void> close();
}
