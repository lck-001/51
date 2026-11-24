import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:client_runtime/client_runtime.dart';
import 'package:client_shell/client_shell.dart';
import 'package:learning_core/learning_core.dart';
import 'package:learning_playback/learning_playback.dart';
import 'package:material_core/material_core.dart';
import 'package:playback_core/playback_core.dart';
import 'package:agent_bridge/agent_bridge.dart';

import 'client_cached_engine.dart';
import 'client_command_barrier.dart';
import 'client_material_import.dart';
import 'client_shutdown.dart';
import 'client_private_storage.dart';
import 'client_retirement.dart';
import 'playback/android_audio_host.dart';
import 'playback/foreground_host.dart';
import 'playback/playback_host.dart';
import 'playback/windows_playback_host.dart';

/// App/process ownership, never page-owned native resources. This local preview
/// has no login, cloud sync, generated content, dictionary or scoring provider.
final class ClientApplicationOwner {
  ClientApplicationOwner._();

  late final ClientPrivateStorage storage;
  late final FileMaterialStore materials;
  late final FileLearningStore learning;
  late final PlaybackHost host;
  late final ClientCachedEngine engine;
  late final PlaybackController playback;
  late final LearningPlaybackCoordinator coordinator;
  late final ShiyuClientRuntime runtime;
  late final ClientMaterialImportController materialImports;
  late final LearningRootLock rootLock;
  late final AgentBridgeController agentBridge;
  StreamSubscription<AgentBridgeStatus>? _assistantEvents;
  late final ClientRetirement _retirement;
  final assistantStatus = ValueNotifier<AgentBridgeStatus>(
    const AgentBridgeStatus(phase: AgentBridgePhase.disabled),
  );
  final frozen = ValueNotifier<bool>(false);
  final notice = ValueNotifier<String?>(null);
  late final ClientShutdown shutdown;

  static Future<ClientApplicationOwner> open({
    required Directory root,
    bool silentValidation = false,
  }) async {
    final owner = ClientApplicationOwner._();
    ClientPrivateStorage? storage;
    PlaybackHost? host;
    ClientCachedEngine? engine;
    LearningPlaybackCoordinator? coordinator;
    ShiyuClientRuntime? runtime;
    try {
      final binaryDirectory = File(Platform.resolvedExecutable).parent;
      storage = await ClientPrivateStorage.open(
        root: root,
        proxyCommand: ['${binaryDirectory.path}/tools/shiyu_agent_proxy.exe'],
      );
      owner.storage = storage;
      owner.rootLock = storage.rootLock;
      owner.materials = storage.materials;
      owner.learning = storage.learning;
      owner.agentBridge = storage.agentBridge;
      owner.materialImports = storage.materialImports;
      final materials = storage.materials,
          learning = storage.learning,
          cache = storage.playableCache;
      owner.assistantStatus.value = owner.agentBridge.current;
      owner._assistantEvents = owner.agentBridge.snapshots.listen((status) {
        owner.assistantStatus.value = status;
      });
      host = Platform.isAndroid
          ? await AndroidAudioHost.create()
          : Platform.isWindows
          ? await WindowsPlaybackHost.create()
          : ForegroundPlaybackHost();
      owner.host = host;
      engine = ClientCachedEngine(
        cache: cache,
        currentScope: () => owner.playback.current.token,
        beforePlay: host.preparePlay,
        silentValidation: silentValidation,
      );
      owner.engine = engine;
      owner.playback = PlaybackController(engine: engine, system: host);
      owner.coordinator = coordinator = LearningPlaybackCoordinator(
        learning: learning,
        playback: owner.playback,
        mediaCache: cache,
      );
      owner.runtime = runtime = ShiyuClientRuntime.attach(
        materials: materials,
        learning: learning,
        playback: owner.playback,
        coordinator: owner.coordinator,
      );
      owner._retirement = ClientRetirement(
        admissions: [
          () {
            owner.frozen.value = true;
          },
          () {
            FocusManager.instance.primaryFocus?.unfocus();
          },
          owner.engine.retireOpenAdmission,
          owner.storage.retire,
        ],
        drains: [
          owner.runtime.detach,
          owner.coordinator.close,
          owner.storage.drainWriters,
          () {
            final events = owner._assistantEvents;
            owner._assistantEvents = null;
            return events?.cancel() ?? Future<void>.value();
          },
          () {
            owner.assistantStatus.value = owner.agentBridge.current;
          },
        ],
      );
      owner.shutdown = ClientShutdown(
        freezeBusiness: owner._retirement.retire,
        retireBookkeeping: () => owner._retirement.completion,
        stopAndRelease: owner._stopAndReleaseNative,
        closeLearning: owner.storage.closeLearning,
        closeMaterials: owner.storage.closeMaterials,
        closeHost: owner.host.close,
        exitApplication: SystemNavigator.pop,
        // Store close success flags live in ClientShutdown, so a retry of this
        // OS release can never close non-idempotent Stores a second time.
        afterStoresClosed: owner.storage.releaseAuthority,
      );
      if (host is AndroidAudioHost) {
        host.beforeBackgroundStop = engine.native.releaseNative;
      }
      if (host is WindowsPlaybackHost) {
        host.beforeWindowClose = (token) async {
          // Native callback draining is not a storage flush barrier.
          await owner.shutdown.drainStores();
          await engine!.native.releaseNative(token);
        };
        host.onClosingChanged = (closing) {
          if (closing) {
            owner.retireCommands();
          } else {
            // Failed cleanup is not a license to reopen a retired coordinator.
            // Keep admission closed; the native close button can retry cleanup.
            owner.notice.value = '关闭尚未完成，已暂停操作；请重试关闭窗口。';
          }
        };
      }
      host.bind(owner.playback);
      return owner;
    } catch (_) {
      // Headless storage safety is symmetric. No native acknowledgement is
      // reinterpreted as a Store flush, and a failed cleanup retains authority.
      if (storage != null) {
        final current = storage;
        final cleanup = ClientRetirement(
          admissions: [
            if (engine != null) engine.retireOpenAdmission,
            current.retire,
          ],
          drains: [
            if (runtime != null) runtime.detach,
            if (coordinator != null) coordinator.close,
            current.drainWriters,
            if (owner._assistantEvents != null) owner._assistantEvents!.cancel,
            if (engine != null) engine.native.dispose,
            if (host != null) host.close,
          ],
        );
        cleanup.retire();
        try {
          await cleanup.completion;
          await current.closeStoresAndAuthority();
        } catch (_) {}
      }
      rethrow;
    }
  }

  void retireCommands() {
    shutdown.retire();
  }

  bool _stopped(PlaybackSnapshot s) =>
      s.intent == PlaybackIntent.stopped &&
      s.actual == PlaybackActual.idle &&
      s.engineAvailable;

  Future<void> _stopAndReleaseNative() async {
    await playback.dispatch(const Stop());
    final token = playback.current.token;
    if (!_stopped(playback.current)) {
      await playback.snapshots
          .firstWhere((s) => s.token.sameSession(token) && _stopped(s))
          .timeout(const Duration(seconds: 15));
    }
    final expected = playback.current.token;
    await engine.native
        .releaseNative(expected)
        .timeout(const Duration(seconds: 15));
    if (playback.current.token != expected || !_stopped(playback.current)) {
      throw StateError('shutdown_superseded');
    }
  }

  /// Explicit Android exit, distinct from ordinary background playback.
  Future<void> closeAndExit() async {
    try {
      await shutdown.requestExit();
    } catch (_) {
      notice.value = '停止或资源释放尚未确认，未提前退出；可再次返回重试退出。';
    }
  }
}

class ShiyuLocalClient extends StatefulWidget {
  const ShiyuLocalClient({super.key, required this.owner});
  final ClientApplicationOwner owner;
  @override
  State<ShiyuLocalClient> createState() => _ShiyuLocalClientState();
}

class _ShiyuLocalClientState extends State<ShiyuLocalClient>
    with WidgetsBindingObserver {
  late final Widget _shell;
  @override
  void initState() {
    super.initState();
    _shell = widget.owner.runtime.createShell(
      onRootBack: Platform.isAndroid ? widget.owner.closeAndExit : null,
      onStartImport: widget.owner.materialImports.start,
      assistantStatus: widget.owner.assistantStatus,
      applicationRetired: widget.owner.frozen,
      onAuthorizeAssistant: Platform.isWindows
          ? (request) async {
              await widget.owner.agentBridge.authorize(request);
            }
          : null,
      onRevokeAssistant: Platform.isWindows
          ? widget.owner.agentBridge.revoke
          : null,
      onAssistantSetup: Platform.isWindows
          ? widget.owner.agentBridge.setup
          : null,
    );
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed ||
        (Platform.isWindows && state == AppLifecycleState.inactive)) {
      widget.owner.host.appForeground(true);
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      widget.owner.host.appForeground(false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Ordinary UI teardown never destroys app-owned native playback.
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '拾语 · 本机预览',
    debugShowCheckedModeBanner: false,
    theme: ShiyuClientTokens.lightTheme(),
    // Above the Navigator, so dialogs/sheets/route overlays are retired too.
    // Guarding only the home shell leaves their focused actions reachable.
    builder: (_, child) => ValueListenableBuilder<bool>(
      valueListenable: widget.owner.frozen,
      builder: (_, frozen, navigator) => ClientCommandBarrier(
        frozen: frozen,
        child: navigator ?? const SizedBox.shrink(),
      ),
      child: child,
    ),
    home: Column(
      children: [
        SafeArea(
          bottom: false,
          child: Material(
            color: ShiyuClientTokens.hint,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: ValueListenableBuilder<String?>(
                valueListenable: widget.owner.notice,
                builder: (_, notice, _) => Text(
                  notice ?? '本机预览 · 仅此设备保存，尚未接入翻译、配音和发音评分',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ),
          ),
        ),
        Expanded(child: _shell),
      ],
    ),
  );
}
