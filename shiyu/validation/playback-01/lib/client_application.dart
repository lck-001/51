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
import 'package:path_provider/path_provider.dart';

import 'client_cached_engine.dart';
import 'client_command_barrier.dart';
import 'client_preview_frame.dart';
import 'client_material_import.dart';
import 'client_shutdown.dart';
import 'client_private_storage.dart';
import 'client_startup_retention.dart';
import 'client_ui_validation_session.dart';
import 'client_retirement.dart';
import 'playback/android_audio_host.dart';
import 'playback/foreground_host.dart';
import 'playback/playback_host.dart';
import 'playback/windows_playback_host.dart';

/// App/process ownership, never page-owned native resources. This local preview
/// has no login, cloud sync, generated content, dictionary or scoring provider.
final class ClientApplicationOwner implements ClientUiOwner {
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
  bool _uiValidationAllowed = false;
  ClientUiValidationSession? _uiValidation;

  static Future<ClientApplicationOwner> open({
    required Directory root,
    bool silentValidation = false,
    ClientStartupAttempt? startupAttempt,
  }) async {
    final attempt = startupAttempt ?? ClientStartupAttempt();
    final owner = ClientApplicationOwner._();
    attempt.retain(ClientStartupRef.owner, owner);
    owner._uiValidationAllowed = attempt.validationOnly;
    ClientPrivateStorage? storage;
    PlaybackHost? host;
    ClientCachedEngine? engine;
    LearningPlaybackCoordinator? coordinator;
    ShiyuClientRuntime? runtime;
    try {
      final binaryDirectory = File(Platform.resolvedExecutable).parent;
      final androidImportCache = Platform.isAndroid
          ? AndroidMaterialImportCache(
              cacheDirectory: await getTemporaryDirectory(),
            )
          : null;
      storage = await ClientPrivateStorage.open(
        root: root,
        proxyCommand: ['${binaryDirectory.path}/tools/shiyu_agent_proxy.exe'],
        androidImportCache: androidImportCache,
        startupAttempt: attempt,
      );
      attempt.retain(ClientStartupRef.storage, storage);
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
      attempt.retain(ClientStartupRef.assistantEvents, owner._assistantEvents!);
      host = Platform.isAndroid
          ? await AndroidAudioHost.create()
          : Platform.isWindows
          ? await WindowsPlaybackHost.create(startupAttempt: attempt)
          : ForegroundPlaybackHost();
      attempt.retain(ClientStartupRef.host, host);
      owner.host = host;
      engine = ClientCachedEngine(
        cache: cache,
        currentScope: () => owner.playback.current.token,
        beforePlay: host.preparePlay,
        silentValidation: silentValidation,
      );
      attempt.retain(ClientStartupRef.engine, engine);
      owner.engine = engine;
      owner.playback = PlaybackController(engine: engine, system: host);
      attempt.retain(ClientStartupRef.playback, owner.playback);
      owner.coordinator = coordinator = LearningPlaybackCoordinator(
        learning: learning,
        playback: owner.playback,
        mediaCache: cache,
      );
      attempt.retain(ClientStartupRef.coordinator, owner.coordinator);
      owner.runtime = runtime = ShiyuClientRuntime.attach(
        materials: materials,
        learning: learning,
        playback: owner.playback,
        coordinator: owner.coordinator,
      );
      attempt.retain(ClientStartupRef.runtime, owner.runtime);
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
        exitApplication: owner._exitAfterDrain,
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
      attempt.handoff(ClientStartupRef.owner, owner);
      return owner;
    } catch (error, stack) {
      final failure = attempt.fail(error, stack);
      final partialHost =
          host ?? attempt.retained<PlaybackHost>(ClientStartupRef.host);
      // Inner factory failure carries this same token even if storage never returned.
      // No second authority or factory is opened for recovery.
      var safe = true;
      Future<void> settle(
        ClientStartupCleanup step,
        FutureOr<void> Function() action,
      ) async {
        try {
          await attempt.cleanup(step, action);
        } catch (_) {
          safe = false;
        }
      }

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
            // Native create may have timed out at its caller, but that exact
            // original operation must settle before close/detach can be issued.
            () async {
              await attempt.operationSettled(
                ClientStartupOperation.hostNativeCreate,
              );
              final partialPlayback = attempt.retained<PlaybackController>(
                ClientStartupRef.playback,
              );
              if (partialPlayback != null) {
                await attempt.cleanup(
                  ClientStartupCleanup.disposePlayback,
                  partialPlayback.dispose,
                );
              }
              if (engine != null) {
                await attempt.cleanup(
                  ClientStartupCleanup.disposeEngine,
                  engine.native.dispose,
                );
              }
              if (partialHost != null) {
                await attempt.cleanup(
                  ClientStartupCleanup.closeHost,
                  partialHost.close,
                );
              }
            },
          ],
        );
        await settle(ClientStartupCleanup.retireApplication, () {
          cleanup.retire();
          return cleanup.completion;
        });
        if (safe) {
          await settle(
            ClientStartupCleanup.closeLearning,
            current.closeLearning,
          );
          if (safe) {
            await settle(
              ClientStartupCleanup.closeMaterials,
              current.closeMaterials,
            );
          }
          if (safe) {
            await settle(
              ClientStartupCleanup.releaseAuthority,
              current.releaseAuthority,
            );
          }
          if (safe && partialHost is WindowsPlaybackHost) {
            await settle(
              ClientStartupCleanup.detachFailedHost,
              partialHost.detachDrainedFailedStartup,
            );
          }
        }
      }
      await settle(ClientStartupCleanup.disposeOwnerSignals, () {
        owner.assistantStatus.dispose();
        owner.frozen.dispose();
        owner.notice.dispose();
      });
      if (safe && !attempt.cleanupFailed) attempt.releasedAfterCleanup();
      Error.throwWithStackTrace(failure, failure.primaryStack);
    }
  }

  Future<void> _exitAfterDrain() async {
    final validation = _uiValidation;
    if (validation != null) {
      await validation.ownerDrained(
        stopped: _stopped(playback.current),
        storesDrained: storage.writersDrained,
        storesClosed: storage.storesClosed,
        released: storage.authorityReleased && !rootLock.isHeld,
      );
    }
    final currentHost = host;
    if (currentHost is WindowsPlaybackHost) {
      if (!_stopped(playback.current) ||
          !storage.writersDrained ||
          !storage.authorityReleased ||
          rootLock.isHeld) {
        throw StateError('windows_exit_drain_unconfirmed');
      }
      await currentHost.requestProgrammaticExitAfterDrain();
      return;
    }
    await SystemNavigator.pop();
  }

  void bindUiValidation(ClientUiValidationSession session) {
    if (!_uiValidationAllowed || _uiValidation != null) {
      throw StateError('validation_binding_rejected');
    }
    _uiValidation = session;
  }

  @override
  String get uiTrustedOwnerId => materials.trustedOwnerId;
  @override
  bool get uiRootHeld => rootLock.isHeld;
  @override
  String get uiRootPath => rootLock.rootDirectory.path;
  @override
  Future<Map<String, Object?>> uiActualFacts() async => {
    'g1Held': rootLock.isHeld,
    'learningCount': (await learning.listVersions()).length,
    'materialCount': (await materials.listDrafts()).length,
    'hasSelection': playback.current.item != null,
    'hasSource': engine.native.diagnosticSummary()['hasSource'] == true,
  };
  @override
  Future<void> uiRequestExit() => shutdown.requestExit();

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
    home: ClientPreviewFrame(notice: widget.owner.notice, child: _shell),
  );
}
