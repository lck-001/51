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
import 'package:path_provider/path_provider.dart';
import 'package:agent_bridge/agent_bridge.dart';

import 'client_cached_engine.dart';
import 'client_command_barrier.dart';
import 'client_material_import.dart';
import 'client_shutdown.dart';
import 'playback/android_audio_host.dart';
import 'playback/foreground_host.dart';
import 'playback/playback_host.dart';
import 'playback/windows_playback_host.dart';

/// App/process ownership, never page-owned native resources. This local preview
/// has no login, cloud sync, generated content, dictionary or scoring provider.
final class ClientApplicationOwner {
  ClientApplicationOwner._();

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
  Future<void>? _assistantEventCancellation;
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
    FileMaterialStore? materials;
    FileLearningStore? learning;
    PlaybackHost? host;
    ClientCachedEngine? engine;
    ClientMaterialImportController? materialImports;
    LearningRootLock? rootLock;
    AgentBridgeController? bridge;
    try {
      // This must precede both Store.open calls, including schema migration.
      rootLock = await LearningRootLock.acquire(root);
      owner.rootLock = rootLock;
      final ownedRoot = rootLock.rootDirectory;
      materials = await FileMaterialStore.open(
        root: Directory('${ownedRoot.path}/materials'),
        trustedOwnerId: 'local-device-only',
      );
      owner.materials = materials;
      learning = await FileLearningStore.open(
        root: Directory('${ownedRoot.path}/learning'),
        materials: materials,
      );
      owner.learning = learning;
      final binaryDirectory = File(Platform.resolvedExecutable).parent;
      bridge = AgentBridgeController.attach(
        materials: materials,
        candidates: learning,
        privateDirectory: Directory('${ownedRoot.path}/agent_bridge'),
        rootLock: rootLock,
        proxyCommand: ['${binaryDirectory.path}/tools/shiyu_agent_proxy.exe'],
      );
      owner.agentBridge = bridge;
      owner.assistantStatus.value = bridge.current;
      owner._assistantEvents = bridge.snapshots.listen((status) {
        owner.assistantStatus.value = status;
      });
      final temporary = await getTemporaryDirectory();
      materialImports = ClientMaterialImportController(
        materials: materials,
        stagingRoot: Directory('${temporary.path}/material_import_v1'),
      );
      owner.materialImports = materialImports;
      final cache = FilePlayableCache(
        root: Directory('${ownedRoot.path}/playable-cache'),
        materials: materials,
        learning: learning,
      );
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
      owner.coordinator = LearningPlaybackCoordinator(
        learning: learning,
        playback: owner.playback,
        mediaCache: cache,
      );
      owner.runtime = ShiyuClientRuntime.attach(
        materials: materials,
        learning: learning,
        playback: owner.playback,
        coordinator: owner.coordinator,
      );
      owner.shutdown = ClientShutdown(
        freezeBusiness: () {
          owner.frozen.value = true;
          FocusManager.instance.primaryFocus?.unfocus();
          owner.engine.retireOpenAdmission();
          owner.materialImports.retire();
          owner._assistantEventCancellation = owner._assistantEvents?.cancel();
          owner._assistantEvents = null;
          owner.agentBridge.retire();
          owner.assistantStatus.value = owner.agentBridge.current;
        },
        retireBookkeeping: () async {
          await Future.wait([
            owner.runtime.detach(),
            owner.coordinator.close(),
            owner.materialImports.close(),
            owner.agentBridge.close(),
            if (owner._assistantEventCancellation != null)
              owner._assistantEventCancellation!,
          ]);
        },
        stopAndRelease: owner._stopAndReleaseNative,
        closeLearning: owner.learning.close,
        closeMaterials: owner.materials.close,
        closeHost: owner.host.close,
        exitApplication: SystemNavigator.pop,
        // Store close success flags live in ClientShutdown, so a retry of this
        // OS release can never close non-idempotent Stores a second time.
        afterStoresClosed: owner.rootLock.release,
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
      // Startup has no selected media and cannot have started playback. Best
      // effort cleanup is not reported as confirmed hardware release.
      var authoritySafeToRelease = true;
      try {
        await bridge?.close();
      } catch (_) {
        authoritySafeToRelease = false;
      }
      try {
        await owner._assistantEvents?.cancel();
      } catch (_) {}
      try {
        await materialImports?.close();
      } catch (_) {}
      try {
        await engine?.native.dispose();
      } catch (_) {}
      try {
        await host?.close();
      } catch (_) {}
      try {
        await learning?.close();
      } catch (_) {
        authoritySafeToRelease = false;
      }
      try {
        await materials?.close();
      } catch (_) {
        authoritySafeToRelease = false;
      }
      if (authoritySafeToRelease) {
        try {
          await rootLock?.release();
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
