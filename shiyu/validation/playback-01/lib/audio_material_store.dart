import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:path_provider/path_provider.dart';
import 'package:playback_core/playback_core.dart';

/// Resolution is private to the application; playback and OS metadata see IDs.
final class AudioMaterialStore {
  final Map<String, String> _paths = {};
  final Map<String, String> _names = {};
  String resolve(PlaybackItem item) {
    if (item.ownerId != 'local-device' || item.itemRevision != '1') {
      throw StateError('material_scope_mismatch');
    }
    final path = _paths[item.itemId];
    if (path == null) throw StateError('material_not_available');
    return File(path).uri.toString();
  }

  String name(PlaybackItem? item) =>
      item == null ? '尚未选择材料' : _names[item.itemId] ?? '个人音频';
  Future<PlaybackItem?> select() async {
    final selected = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: '音频',
          extensions: ['wav', 'm4a', 'mp3', 'aac', 'ogg', 'flac'],
          mimeTypes: ['audio/*'],
        ),
      ],
    );
    if (selected == null) return null;
    return _copy(selected);
  }

  Future<PlaybackItem> importSyntheticFixture(String path) async {
    if (File(path).uri.pathSegments.last != 'english-playback-check.wav') {
      throw StateError('synthetic_fixture_name_required');
    }
    return _copy(XFile(path));
  }

  Future<PlaybackItem> _copy(XFile selected) async {
    if (await selected.length() <= 0) throw StateError('音频文件为空');
    final root = await getApplicationSupportDirectory();
    final dir = Directory('${root.path}/playback_probe');
    await dir.create(recursive: true);
    final dot = selected.name.lastIndexOf('.');
    final ext = dot < 0 ? '.bin' : selected.name.substring(dot);
    final suffix = RegExp(r'^\.[a-zA-Z0-9]{1,10}$').hasMatch(ext)
        ? ext
        : '.bin';
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final path = '${dir.path}/$id$suffix';
    await selected.saveTo(path);
    if (!await File(path).exists() || await File(path).length() <= 0) {
      throw StateError('未确认本地副本');
    }
    _paths[id] = path;
    _names[id] = selected.name;
    return PlaybackItem(
      ownerId: 'local-device',
      itemId: id,
      itemRevision: '1',
      kind: MediaKind.audio,
    );
  }
}
