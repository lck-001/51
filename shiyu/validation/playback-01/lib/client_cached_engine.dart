import 'package:learning_playback/learning_playback.dart';
import 'package:playback_core/playback_core.dart';

import 'playback/media_kit_engine.dart';

/// App-private asynchronous cache resolution before the native synchronous seam.
/// A superseded resolve cannot adopt a new scope or replace its private source.
final class ClientCachedEngine implements PlaybackEngineAdapter {
  ClientCachedEngine({
    required this.cache,
    required PlaybackToken Function() currentScope,
    required Future<bool> Function(PlaybackToken) beforePlay,
    bool silentValidation = false,
  }) : _currentScope = currentScope {
    native = MediaKitEngine(
      resolve: _resolve,
      beforePlay: beforePlay,
      currentScope: currentScope,
      silentValidation: silentValidation,
    );
  }

  final FilePlayableCache cache;
  final PlaybackToken Function() _currentScope;
  late final MediaKitEngine native;
  ({PlaybackToken token, String source})? _prepared;
  bool _openAdmission = true;

  bool _matches(PlaybackItem item, PlaybackToken token) =>
      item.ownerId == token.ownerId &&
      item.itemId == token.itemId &&
      item.itemRevision == token.itemRevision &&
      item.kind == MediaKind.audio;

  String _resolve(PlaybackItem item) {
    final prepared = _prepared;
    if (!_openAdmission ||
        prepared == null ||
        !prepared.token.sameSession(_currentScope()) ||
        !_matches(item, prepared.token)) {
      throw StateError('private_media_scope_unconfirmed');
    }
    return prepared.source;
  }

  /// Synchronous shutdown barrier; Stop remains available for native cleanup.
  void retireOpenAdmission() {
    _openAdmission = false;
    _prepared = null;
  }

  @override
  Stream<EngineEvent> get events => native.events;

  @override
  Future<void> open(PlaybackItem item, PlaybackToken token) async {
    if (!_openAdmission || _currentScope() != token) return;
    if (!_matches(item, token)) throw StateError('media_binding_mismatch');
    final source = await cache.resolveForEngine(item);
    if (!_openAdmission || _currentScope() != token) return;
    _prepared = (token: token, source: source.toFilePath());
    await native.open(item, token);
  }

  @override
  Future<void> play(PlaybackToken token) => native.play(token);
  @override
  Future<void> pause(PlaybackToken token) => native.pause(token);
  @override
  Future<void> seek(Duration position, PlaybackToken token, int requestId) =>
      native.seek(position, token, requestId);
  @override
  Future<void> stop(PlaybackToken token) => native.stop(token);
}
