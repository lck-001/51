import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const MaterialApp(home: MediaProbe()));
}

enum Capture { none, audio, video }

class MediaProbe extends StatefulWidget {
  const MediaProbe({super.key});
  @override
  State<MediaProbe> createState() => _MediaProbeState();
}

class _MediaProbeState extends State<MediaProbe> with WidgetsBindingObserver {
  final _recorder = AudioRecorder();
  final _player = Player();
  late final _video = VideoController(_player);
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final List<String> _files = [];
  Future<void> _tail = Future<void>.value();
  CameraController? _camera;
  Capture _capture = Capture.none;
  int _pending = 0;
  bool get _busy => _pending > 0;
  bool _closed = false;
  bool _background = false;
  String _status = '请选择导入、录音或录像；素材保存在本机。';
  String? _current;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double? _seekPreview;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Constructing controllers does not request capture permission or start capture.
    _subscriptions.add(
      _player.stream.position.listen((v) {
        _position = v;
        _refresh();
      }),
    );
    _subscriptions.add(
      _player.stream.duration.listen((v) {
        _duration = v;
        _refresh();
      }),
    );
    _subscriptions.add(_player.stream.error.listen((v) => _message('播放错误：$v')));
    _subscriptions.add(
      _recorder.onStateChanged().listen((v) {
        // An OS-originated stop must not leave the UI claiming to record.
        if (v == RecordState.stop && _capture == Capture.audio && !_busy) {
          _capture = Capture.none;
          _message('录音已被系统停止；请检查本地文件，不会自动重新开麦。');
        }
      }),
    );
  }

  void _refresh() {
    if (mounted && !_closed) setState(() {});
  }

  void _message(String value) {
    _status = value;
    _refresh();
  }

  // Serialize native calls, including lifecycle cleanup. Errors do not poison queue.
  void _run(Future<void> Function() action) {
    if (_closed) return;
    _pending++;
    _refresh();
    _tail = _tail.then((_) async {
      try {
        if (_closed) return;
        await action();
      } catch (e) {
        _message('操作失败：$e\n请检查设备、系统隐私设置及文件权限。');
      } finally {
        _pending--;
        _refresh();
      }
    });
  }

  Future<String> _path(String suffix) async {
    final root = await getApplicationSupportDirectory();
    final dir = Directory('${root.path}${Platform.pathSeparator}media_probe');
    await dir.create(recursive: true);
    return '${dir.path}${Platform.pathSeparator}${DateTime.now().microsecondsSinceEpoch}$suffix';
  }

  Future<void> _remember(String path) async {
    final file = File(path);
    if (!await file.exists() || await file.length() == 0) {
      throw StateError('媒体文件不存在或为空；未记作成功。');
    }
    if (!_files.contains(path)) _files.insert(0, path);
    _message('已保存本地文件：$path\n请点击文件回放，验证声音、画面与时长。');
  }

  Future<void> _closeCamera() async {
    final controller = _camera;
    _camera = null;
    _refresh();
    if (controller != null) {
      await controller.dispose();
      _message('相机预览已关闭。');
    }
  }

  Future<void> _stopCapture() async {
    final kind = _capture;
    if (kind == Capture.audio) {
      final path = await _recorder.stop();
      _capture = Capture.none;
      if (path != null) await _remember(path);
    } else if (kind == Capture.video) {
      final controller = _camera;
      if (controller != null && controller.value.isRecordingVideo) {
        final take = await controller.stopVideoRecording();
        _capture = Capture.none;
        final path = await _path('.mp4');
        await take.saveTo(path);
        await _remember(path);
      }
      _capture = Capture.none;
    }
  }

  Future<void> _import() async {
    final selected = await openFile();
    if (selected == null) {
      _message('已取消选文件。');
      return;
    }
    final dot = selected.name.lastIndexOf('.');
    final ext = dot < 0 ? '' : selected.name.substring(dot);
    // Preserve safe suffix only; do not let supplied names introduce paths.
    final suffix = RegExp(r'^\.[a-zA-Z0-9]{1,10}$').hasMatch(ext)
        ? ext
        : '.bin';
    final path = await _path(suffix);
    await selected.saveTo(path);
    await _remember(path);
    _message('导入完成：${selected.name}\n文档只验证导入；音视频可点击下方文件验证播放。');
  }

  Future<void> _play(String path) async {
    await _stopCapture();
    await _closeCamera();
    if (_background || _closed) return;
    _current = path;
    _position = Duration.zero;
    _duration = Duration.zero;
    await _player.open(Media(File(path).uri.toString()));
    _message('已请求播放：$path\n能否解码以实际画面、声音和错误回报为准。');
  }

  Future<void> _startAudio() async {
    await _player.pause();
    await _closeCamera();
    if (!await _recorder.hasPermission()) {
      _message('未获得麦克风权限；可继续导入和播放。');
      return;
    }
    if (_background || _closed) return;
    if (!await _recorder.isEncoderSupported(AudioEncoder.aacLc)) {
      throw UnsupportedError('此设备未确认支持 AAC-LC，本轮不自动换编码。');
    }
    final path = await _path('.m4a');
    if (_background || _closed) return;
    await _recorder.start(
      const RecordConfig(encoder: AudioEncoder.aacLc),
      path: path,
    );
    _capture = Capture.audio;
    _message('正在录音；点击停止保存。切后台会尝试停止，不自动恢复录音。');
  }

  Future<void> _preview() async {
    await _player.pause();
    await _closeCamera();
    final cameras = await availableCameras();
    if (cameras.isEmpty) throw StateError('未发现摄像头。');
    if (_background || _closed) return;
    final controller = CameraController(
      cameras.first,
      ResolutionPreset.medium,
      enableAudio: true,
    );
    _camera = controller;
    controller.addListener(_cameraChanged);
    try {
      await controller.initialize();
      _message('相机预览已开启（含录像麦克风权限）；点击开始录像才保存视频。');
    } catch (_) {
      await _closeCamera();
      rethrow;
    }
  }

  void _cameraChanged() {
    final value = _camera?.value;
    if (value != null && value.hasError) {
      _message('相机错误：${value.errorDescription}；请关闭预览后重试。');
    }
  }

  Future<void> _startVideo() async {
    if (_background || _closed) return;
    final controller = _camera;
    if (controller == null || !controller.value.isInitialized) {
      throw StateError('请先明确点击开启相机预览。');
    }
    await controller.startVideoRecording(enablePersistentRecording: false);
    _capture = Capture.video;
    _message('正在录像；本实验仅开始/停止，不提供暂停续录。');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _background = false;
      return; // Never automatically reopen capture devices.
    }
    // Permission dialogs may cause inactive; do not tear down during that dialog.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _background = true;
      _run(() async {
        final hadCapture = _capture != Capture.none;
        final hadPreview = _camera != null;
        try {
          await _stopCapture();
        } finally {
          await _closeCamera();
          await _player.pause();
        }
        if (hadCapture) {
          _message('应用进入后台，已停止录制。请回放检查保存结果；返回后需手动继续。');
        } else if (hadPreview) {
          _message('应用进入后台，已关闭相机预览并暂停播放。返回后需手动开启。');
        } else {
          _message('播放已暂停；返回后可手动继续。');
        }
      });
    }
  }

  @override
  void dispose() {
    _closed = true;
    WidgetsBinding.instance.removeObserver(this);
    // Wait for an in-flight native operation, then stop before disposing devices.
    unawaited(
      _tail
          .then((_) async {
            for (final subscription in _subscriptions) {
              await subscription.cancel();
            }
            try {
              await _stopCapture();
            } finally {
              try {
                await _closeCamera();
              } finally {
                await _recorder.dispose();
                await _player.dispose();
              }
            }
          })
          .catchError((Object error) {
            // Lifecycle teardown cannot update a disposed UI.
            debugPrint('Media probe cleanup failed: $error');
          }),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final idle = !_busy && _capture == Capture.none && !_background;
    final durationMs = _duration.inMilliseconds.toDouble();
    final maxMs = durationMs > 0 ? durationMs : 1.0;
    return Scaffold(
      appBar: AppBar(title: const Text('拾语 · 媒体隔离验证')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            '媒体能力验证 · 素材保存在本机',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          SelectableText(_status),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: idle ? () => _run(_import) : null,
                child: const Text('导入本地文件'),
              ),
              FilledButton(
                onPressed: idle ? () => _run(_startAudio) : null,
                child: const Text('开始录音'),
              ),
              OutlinedButton(
                onPressed: !_busy && _capture != Capture.none
                    ? () => _run(_stopCapture)
                    : null,
                child: const Text('停止并保存录制'),
              ),
              OutlinedButton(
                onPressed: idle ? () => _run(_preview) : null,
                child: const Text('开启相机预览（请求相机/麦克风）'),
              ),
              FilledButton(
                onPressed: idle && (_camera?.value.isInitialized ?? false)
                    ? () => _run(_startVideo)
                    : null,
                child: const Text('开始录像'),
              ),
              OutlinedButton(
                onPressed: idle && _camera != null
                    ? () => _run(_closeCamera)
                    : null,
                child: const Text('关闭相机预览'),
              ),
            ],
          ),
          if (_camera?.value.isInitialized ?? false)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: SizedBox(height: 220, child: CameraPreview(_camera!)),
            ),
          const SizedBox(height: 12),
          SizedBox(
            height: 200,
            child: Video(controller: _video, controls: NoVideoControls),
          ),
          Slider(
            value: (_seekPreview ?? _position.inMilliseconds.toDouble()).clamp(
              0,
              maxMs,
            ),
            max: maxMs,
            onChanged: idle && _current != null && durationMs > 0
                ? (v) {
                    _seekPreview = v;
                    _refresh();
                  }
                : null,
            onChangeEnd: idle && _current != null && durationMs > 0
                ? (v) {
                    _seekPreview = null;
                    _run(() => _player.seek(Duration(milliseconds: v.round())));
                  }
                : null,
          ),
          Text('${_position.inSeconds}s / ${_duration.inSeconds}s'),
          OutlinedButton(
            onPressed: idle && _current != null
                ? () => _run(() => _player.playOrPause())
                : null,
            child: const Text('播放 / 暂停'),
          ),
          const Divider(),
          const Text('本次会话文件（仅存本机；重启后列表不恢复）'),
          for (final path in _files)
            ListTile(
              title: Text(path.split(Platform.pathSeparator).last),
              subtitle: Text(path),
              trailing: const Icon(Icons.play_arrow),
              onTap: idle ? () => _run(() => _play(path)) : null,
            ),
        ],
      ),
    );
  }
}
