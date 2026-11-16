import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:playback_core/playback_core.dart';

import 'audio_material_store.dart';
import 'playback/android_audio_host.dart';
import 'playback/foreground_host.dart';
import 'playback/media_kit_engine.dart';
import 'playback/playback_host.dart';
import 'playback/windows_playback_host.dart';

Future<void> main(List<String> args) async {
  final silent =
      kDebugMode && Platform.isWindows && args.contains('--silent-validation');
  final fixtureArgs = args.where(
    (arg) => arg.startsWith('--synthetic-fixture='),
  );
  final syntheticFixture =
      kDebugMode && Platform.isWindows && fixtureArgs.isNotEmpty
      ? fixtureArgs.first.substring('--synthetic-fixture='.length)
      : null;
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final materials = AudioMaterialStore();
  try {
    final PlaybackHost host = Platform.isAndroid
        ? await AndroidAudioHost.create()
        : Platform.isWindows
        ? await WindowsPlaybackHost.create()
        : ForegroundPlaybackHost();
    late final PlaybackController playback;
    final engine = MediaKitEngine(
      resolve: materials.resolve,
      beforePlay: host.preparePlay,
      currentScope: () => playback.current.token,
      silentValidation: silent,
    );
    playback = PlaybackController(engine: engine, system: host);
    host.bind(playback);
    if (host is AndroidAudioHost) {
      host.beforeBackgroundStop = engine.releaseNative;
    }
    if (host is WindowsPlaybackHost) {
      host.beforeWindowClose = engine.releaseNative;
    }
    runApp(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed: const Color(0xFF2563A6),
          useMaterial3: true,
        ),
        home: PlaybackLab(
          playback: playback,
          host: host,
          materials: materials,
          releaseNative: engine.releaseNative,
          silentValidation: silent,
          syntheticFixture: syntheticFixture,
          playSynthetic:
              syntheticFixture != null && args.contains('--play-synthetic'),
        ),
      ),
    );
  } catch (_) {
    runApp(
      const MaterialApp(
        home: Scaffold(
          body: SafeArea(
            child: Center(child: Text('播放宿主初始化失败；未开放后台能力。请重新启动实验。')),
          ),
        ),
      ),
    );
  }
}

/// The app owns playback. Page disposal only removes its UI/lifecycle observer.
class PlaybackLab extends StatefulWidget {
  const PlaybackLab({
    super.key,
    required this.playback,
    required this.host,
    required this.materials,
    required this.releaseNative,
    this.silentValidation = false,
    this.syntheticFixture,
    this.playSynthetic = false,
  });
  final PlaybackController playback;
  final PlaybackHost host;
  final AudioMaterialStore materials;
  final Future<void> Function(PlaybackToken) releaseNative;
  final bool silentValidation;
  final String? syntheticFixture;
  final bool playSynthetic;
  @override
  State<PlaybackLab> createState() => _PlaybackLabState();
}

class _PlaybackLabState extends State<PlaybackLab> with WidgetsBindingObserver {
  bool _importing = false;
  bool _leaving = false;
  int _inputEpoch = 0;
  double? _seekPreview;
  String _message = '请选择合成音频。加载后需明确点击播放。';
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final host = widget.host;
    if (host is WindowsPlaybackHost) host.onClosingChanged = _windowClosing;
    if (widget.syntheticFixture != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => unawaited(_bootstrapSynthetic()),
      );
    }
  }

  Future<void> _bootstrapSynthetic() async {
    if (!mounted || _leaving || _importing) return;
    final epoch = _inputEpoch;
    setState(() => _importing = true);
    try {
      final item = await widget.materials.importSyntheticFixture(
        widget.syntheticFixture!,
      );
      if (!mounted || _leaving || epoch != _inputEpoch) return;
      await _command(Open(item));
      if (!mounted || _leaving || epoch != _inputEpoch) return;
      if (widget.playSynthetic) await _command(const Play());
    } catch (_) {
      if (mounted && !_leaving) setState(() => _message = '合成验证素材未加载；未替换其他资料。');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  void _windowClosing(bool closing) {
    _inputEpoch++;
    if (mounted) {
      setState(() => _leaving = closing);
    } else {
      _leaving = closing;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed ||
        (Platform.isWindows && state == AppLifecycleState.inactive)) {
      widget.host.appForeground(true);
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      widget.host.appForeground(false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _command(PlaybackCommand command) async {
    if (_leaving) return;
    final result = await widget.playback.dispatch(command);
    if (!mounted) return;
    setState(
      () => _message = result.accepted
          ? '请求已接收，以下方实际状态为准。'
          : '当前无法执行：${result.reason ?? result.status.name}',
    );
  }

  Future<void> _import() async {
    if (!mounted || _leaving || _importing) return;
    final inputEpoch = _inputEpoch;
    setState(() => _importing = true);
    try {
      final item = await widget.materials.select();
      if (!mounted || _leaving || inputEpoch != _inputEpoch) return;
      if (item == null) {
        setState(() => _message = '已取消选择。');
        return;
      }
      await _command(Open(item));
    } catch (_) {
      if (mounted) setState(() => _message = '音频导入未完成，请检查文件后重试。');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _leave() async {
    if (_leaving || _importing) return;
    setState(() => _leaving = true);
    try {
      if (!await widget.host.backgroundHostReady()) {
        // No legal system host will retain the engine. Retire commands while
        // still attached, wait for native facts, then release callbacks.
        await widget.playback.dispatch(const Stop());
        await widget.host.close().timeout(const Duration(seconds: 15));
        bool stopped(PlaybackSnapshot s) =>
            s.intent == PlaybackIntent.stopped &&
            s.actual == PlaybackActual.idle &&
            s.engineAvailable;
        if (!stopped(widget.playback.current)) {
          await widget.playback.snapshots
              .firstWhere(stopped)
              .timeout(const Duration(seconds: 15));
        }
        await widget
            .releaseNative(widget.playback.current.token)
            .timeout(const Duration(seconds: 15));
      }
      if (mounted) await SystemNavigator.pop();
    } catch (_) {
      if (mounted) setState(() => _message = '退出清理尚未确认，请从系统结束实验；未冒称资源已释放。');
      // Keep the shell disabled: an incomplete close is not a reusable host.
    }
  }

  String _time(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
  String _actual(PlaybackActual a) => switch (a) {
    PlaybackActual.idle => '未播放',
    PlaybackActual.loading => '加载中',
    PlaybackActual.buffering => '缓冲中',
    PlaybackActual.playing => '播放中',
    PlaybackActual.paused => '已暂停',
    PlaybackActual.ended => '已结束',
    PlaybackActual.failed => '暂不可用',
  };
  @override
  Widget build(BuildContext context) => PopScope<Object?>(
    canPop: !Platform.isAndroid,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && Platform.isAndroid) unawaited(_leave());
    },
    child: Scaffold(
      appBar: AppBar(
        title: Text(widget.silentValidation ? '拾语 · 静音验证' : '拾语 · 播放验证'),
      ),
      body: SafeArea(
        child: StreamBuilder<PlaybackSnapshot>(
          stream: widget.playback.snapshots,
          initialData: widget.playback.current,
          builder: (context, data) {
            final s = data.data!;
            final max = (s.duration?.inMilliseconds ?? 0).toDouble();
            final canPlay =
                s.item != null && !_importing && !_leaving && s.engineAvailable;
            return ListView(
              padding: const EdgeInsets.all(20),
              children: [
                const Text(
                  '独立播放验证',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                const Text('只使用合成材料；尚非完整学习 App。系统面板只显示通用标题。'),
                const SizedBox(height: 20),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.materials.name(s.item),
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          s.engineAvailable
                              ? '实际状态：${_actual(s.actual)}'
                              : '当前状态未确认，上次观察：${_actual(s.actual)}',
                          style: const TextStyle(fontSize: 20),
                        ),
                        Text(
                          '播放意图：${s.intent == PlaybackIntent.playing
                              ? '继续播放'
                              : s.intent == PlaybackIntent.stopped
                              ? '已停止'
                              : '保持暂停'}',
                        ),
                        const SizedBox(height: 12),
                        Slider(
                          value:
                              (_seekPreview ??
                                      s.position.inMilliseconds.toDouble())
                                  .clamp(0, max > 0 ? max : 1),
                          max: max > 0 ? max : 1,
                          onChanged: max > 0 && s.engineAvailable && !_leaving
                              ? (v) => setState(() => _seekPreview = v)
                              : null,
                          onChangeEnd: max > 0 && s.engineAvailable && !_leaving
                              ? (v) {
                                  setState(() => _seekPreview = null);
                                  unawaited(
                                    _command(
                                      Seek(Duration(milliseconds: v.round())),
                                    ),
                                  );
                                }
                              : null,
                        ),
                        Text(
                          '${_time(s.position)} / ${s.duration == null ? '--:--' : _time(s.duration!)}',
                        ),
                        if (s.pendingSeek != null)
                          Text(
                            s.seekPositionApplied ? '进度已确认，画面到位尚未确认' : '正在定位…',
                          ),
                        if (!s.engineAvailable)
                          const Text('原生操作未确认；已禁止新的播放，请先停止。'),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            FilledButton(
                              onPressed: canPlay
                                  ? () => _command(const Play())
                                  : null,
                              child: const Text('播放'),
                            ),
                            OutlinedButton(
                              onPressed: s.item != null && !_leaving
                                  ? () => _command(const Pause())
                                  : null,
                              child: const Text('暂停'),
                            ),
                            OutlinedButton(
                              onPressed: s.item != null && !_leaving
                                  ? () => _command(const Stop())
                                  : null,
                              child: const Text('停止并结束会话'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.tonal(
                  onPressed: _importing || _leaving ? null : _import,
                  child: Text(_importing ? '导入中…' : '导入音频'),
                ),
                const SizedBox(height: 16),
                Text(_message),
                if (s.error != null) const Text('播放或定位尚未确认，请暂停/停止后重试。'),
                OutlinedButton(
                  onPressed: _leaving
                      ? null
                      : () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (pageContext) => Scaffold(
                              appBar: AppBar(title: const Text('页面切换验证')),
                              body: Padding(
                                padding: const EdgeInsets.all(24),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text('这里不会创建或销毁播放器。返回后仍可控制同一段音频。'),
                                    const SizedBox(height: 20),
                                    FilledButton(
                                      onPressed: () =>
                                          Navigator.of(pageContext).pop(),
                                      child: const Text('返回播放页'),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                  child: const Text('切换页面验证'),
                ),
                const Divider(height: 32),
                Text(
                  '后台能力：${s.capabilities.backgroundAudio ? '已接入，待设备验收' : '仅前台播放'}',
                ),
                Text('后台宿主：${s.hostReady ? '当前已确认' : '尚未确认'}'),
                if (s.pauseCauses.isNotEmpty)
                  Text('暂停原因：${s.pauseCauses.map((e) => e.name).join(', ')}'),
                const SizedBox(height: 16),
                const Text('页面离开不等于结束播放。使用“停止并结束会话”主动结束；实验不自动恢复进程中的播放。'),
              ],
            );
          },
        ),
      ),
    ),
  );
}
