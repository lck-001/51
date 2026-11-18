import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:agent_bridge/agent_bridge.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:learning_core/learning_core.dart';
import 'package:media_kit/media_kit.dart';
import 'package:playback_core/playback_core.dart';

import 'client_application.dart';
import 'playback/windows_playback_host.dart';

/// Debug-render boundary. Normal App focus semantics are deliberately untouched.
Widget agentDemoFocusBoundary(Widget child) => ExcludeFocus(child: child);

/// Separate debug-only target. The native runner must already suppress first
/// Show/SetFocus via --background-regression. This entry seeds only ORIGINAL
/// Chinese material, never an English candidate, a confirmation or a selection.
Future<void> main(List<String> args) async {
  String? value(String prefix) {
    final matches = args.where((arg) => arg.startsWith(prefix)).toList();
    return matches.length == 1 ? matches.single.substring(prefix.length) : null;
  }

  final control = value('--demo-control='), id = value('--demo-id=');
  if (!kDebugMode ||
      !Platform.isWindows ||
      !args.contains('--background-regression') ||
      !args.contains('--silent-validation') ||
      control == null ||
      id == null ||
      !RegExp(r'^[a-f0-9]{32}$').hasMatch(id)) {
    stdout.writeln(
      'SHIYU_AGENT_DEMO_REJECTED debug_hidden_silent_control_required',
    );
    exit(64);
  }
  final runner = _AgentDemo(Directory(control), id);
  await runner.run();
}

final class _DemoFailure implements Exception {
  const _DemoFailure(this.code);
  final String code;
}

final class _AgentDemo {
  _AgentDemo(this.control, this.id);
  final Directory control;
  final String id;
  final boundary = GlobalKey(debugLabel: 'controlled-agent-app-boundary');
  Directory? temporary;
  String? resolvedRoot, failure;
  ClientApplicationOwner? owner;
  String? sourceMaterialId, sourceVersionId, sourceHash, candidateId;
  bool sampled = false, cleanupConfirmed = false, temporaryRemoved = false;
  bool startupAttempted = false;
  Map<String, Object?>? lastNative;
  final nativeClock = Stopwatch()..start();
  final nativeHistory = <Map<String, Object?>>[];
  ClientApplicationOwner get app => owner!;
  WindowsPlaybackHost get host => app.host as WindowsPlaybackHost;
  String get marker => 'shiyu-controlled-agent-demo-v1:$id';
  File file(String name) => File('${control.path}/$name');
  void check(bool ok, String code) {
    if (!ok) throw _DemoFailure(code);
  }

  Future<void> save(String name, Map<String, Object?> value) async {
    await file(name).writeAsString(jsonEncode(value), flush: true);
  }

  Future<bool> signal(String name) async {
    final target = file(name);
    if (await FileSystemEntity.type(target.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return false;
    }
    if (await target.length() > 128) return false;
    return (await target.readAsString()).trim() == id;
  }

  Future<void> hidden({required String phase}) async {
    final state = await host.diagnosticStatus();
    lastNative = state;
    const keys = {
      'supported',
      'controlledForeground',
      'retired',
      'closed',
      'windowClosing',
      'configured',
      'windowAlive',
      'windowVisible',
      'windowFocused',
      'nativeForeground',
      'enabled',
      'suspended',
      'metadataCleared',
      'metadataReadable',
      'metadataErrorCode',
      'playbackStatus',
      'nativePlaybackStatusCode',
    };
    final observation = <String, Object?>{
      'sequence': nativeHistory.length + 1,
      'phase': phase,
      'elapsed_ms': nativeClock.elapsedMilliseconds,
      for (final key in keys) key: state[key],
    };
    if (nativeHistory.length < 64) nativeHistory.add(observation);
    await save('native-status-history.local.json', {
      'schema': 'shiyu.controlled-agent-demo-native-status.v1',
      'demo_id': id,
      'observations': nativeHistory,
    });
    // A real positive visibility/focus observation is never retried away or
    // relabelled initialization. Null is a distinct, still failing, observation.
    check(state['windowVisible'] != true, 'own_window_visible_observed');
    check(state['windowFocused'] != true, 'own_window_focused_observed');
    check(state['nativeForeground'] != true, 'own_window_foreground_observed');
    check(
      state['configured'] == true && state['windowAlive'] == true,
      'own_native_host_unconfirmed',
    );
    check(state['windowVisible'] == false, 'own_window_visibility_unconfirmed');
    check(state['windowFocused'] == false, 'own_window_focus_unconfirmed');
    check(
      state['nativeForeground'] == false,
      'own_window_foreground_unconfirmed',
    );
  }

  Future<void> frame() async {
    // Public SDK warm-up scheduling ignores Vsync/lifecycle, without showing or
    // activating any HWND. We capture the actual app display list, not a mock.
    WidgetsBinding.instance.scheduleWarmUpFrame();
    await WidgetsBinding.instance.endOfFrame.timeout(
      const Duration(seconds: 3),
    );
  }

  bool treeHas(String key) {
    var found = false;
    void visit(Element element) {
      if (element.widget.key == ValueKey<String>(key)) found = true;
      element.visitChildElements(visit);
    }

    final element = WidgetsBinding.instance.rootElement;
    if (element != null) visit(element);
    return found;
  }

  Future<void> capture() async {
    final candidates = await app.learning.listCandidates();
    check(
      candidates.length == 1,
      'expected_one_externally_delivered_candidate',
    );
    final candidate = await app.learning.readCandidate(
      candidates.single.candidateId,
    );
    check(
      candidate.state == LearningCandidateState.pendingReview,
      'demo_must_not_confirm_candidate',
    );
    check(
      candidate.materialId == sourceMaterialId &&
          candidate.materialVersionId == sourceVersionId &&
          candidate.sourceTextSha256 == sourceHash,
      'external_candidate_binding_mismatch',
    );
    check(
      (await app.learning.listVersions()).isEmpty,
      'learning_version_must_not_be_seeded',
    );
    candidateId = candidate.candidateId;
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (!treeHas('candidate-inbox')) {
      check(
        DateTime.now().isBefore(deadline),
        'actual_candidate_inbox_not_rendered',
      );
      await frame();
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
    await frame();
    await hidden(phase: 'candidate-sample');
    final rendered = boundary.currentContext?.findRenderObject();
    check(rendered is RenderRepaintBoundary, 'actual_app_boundary_missing');
    final paint = rendered! as RenderRepaintBoundary;
    check(!paint.debugNeedsPaint, 'actual_app_boundary_not_painted');
    final image = await paint.toImage(pixelRatio: 1);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      check(bytes != null, 'app_png_encoding_failed');
      await file('candidate-inbox.local.png')
          .writeAsBytes(bytes!.buffer.asUint8List(), flush: true);
    } finally {
      image.dispose();
    }
    await save('candidate-received.local.json', {
      'schema': 'shiyu.controlled-app-external-candidate.v1',
      'demo_id': id,
      'candidate_id': candidate.candidateId,
      'revision': candidate.revision,
      'state': candidate.state.name,
      'material_id': candidate.materialId,
      'material_version_id': candidate.materialVersionId,
      'source_text_sha256': candidate.sourceTextSha256,
      'user_edited': candidate.userEdited,
      'sentences': [
        for (final sentence in candidate.sentences)
          {'english': sentence.english, 'translation': sentence.translation},
      ],
      'declaration': {
        'preparation': candidate.declaration.preparation,
        'provider': candidate.declaration.provider,
        'model': candidate.declaration.model,
        'model_version': candidate.declaration.modelVersion,
        'notes': candidate.declaration.notes,
      },
      'submission': {
        'integration_id': candidate.submission.integrationId,
        'transport': candidate.submission.transport.name,
        'payload_sha256': candidate.submission.payloadSha256,
        'transport_payload_sha256': candidate.submission.transportPayloadSha256,
        'received_at': candidate.submission.receivedAtUtc.toIso8601String(),
      },
      'candidate_seeded_by_entry': false,
      'candidate_confirmed_by_entry': false,
      'real_codex_native_mcp_registration': false,
    });
    sampled = true;
    await save('sampled.local.json', {
      'schema': 'shiyu.controlled-app-agent-demo-sample.v1',
      'demo_id': id,
      'sampled': true,
      'candidate_inbox_key_in_actual_tree': true,
      'candidate_count': 1,
      'candidate_state': 'pendingReview',
      'learning_version_count': 0,
      'screenshot': 'candidate-inbox.local.png',
      'candidate_record': 'candidate-received.local.json',
      'native_hidden': true,
      'native_focused': false,
      'play_requested': false,
      'controlled_app_bootstrap': true,
      'external_candidate_not_seeded': true,
    });
  }

  Future<void> stop() async {
    if (owner == null) {
      cleanupConfirmed = !startupAttempted;
      return;
    }
    app.retireCommands();
    await app.playback.dispatch(const Stop());
    bool stopped(PlaybackSnapshot s) =>
        s.intent == PlaybackIntent.stopped &&
        s.actual == PlaybackActual.idle &&
        s.engineAvailable;
    if (!stopped(app.playback.current)) {
      await app.playback.snapshots
          .firstWhere(stopped)
          .timeout(const Duration(seconds: 15));
    }
    final expected = app.playback.current.token;
    await app.shutdown
        .drainStores(); // Real bridge commits, Stores, then OS Root lock.
    check(!app.rootLock.isHeld, 'root_authority_release_unconfirmed');
    await app.engine.native
        .releaseNative(expected)
        .timeout(const Duration(seconds: 15));
    check(
      app.playback.current.token == expected && stopped(app.playback.current),
      'native_stop_scope_changed',
    );
    await host.close();
    await hidden(phase: 'cleanup-after-host-close');
    check(
      lastNative?['enabled'] == false && lastNative?['metadataCleared'] == true,
      'native_retirement_unconfirmed',
    );
    runApp(const SizedBox.shrink());
    await frame();
    await app.playback.dispose();
    await app.engine.native.dispose();
    app.frozen.dispose();
    app.notice.dispose();
    app.assistantStatus.dispose();
    cleanupConfirmed = true;
  }

  Future<void> removeOwnTemporaryRoot() async {
    if (!cleanupConfirmed || temporary == null) return;
    final actual = await temporary!.resolveSymbolicLinks();
    final base = await Directory.systemTemp.resolveSymbolicLinks();
    check(
      actual == resolvedRoot &&
          actual.startsWith('$base${Platform.pathSeparator}shiyu-agent-demo-'),
      'temporary_root_identity_changed',
    );
    final ownMarker = File('${temporary!.path}/DEMO.OWNER');
    check(
      await ownMarker.readAsString() == marker,
      'temporary_root_marker_changed',
    );
    await temporary!.delete(recursive: true);
    temporaryRemoved = true;
  }

  Future<void> run() async {
    try {
      check(
        await FileSystemEntity.type(control.path, followLinks: false) ==
            FileSystemEntityType.directory,
        'control_directory_missing',
      );
      check(
        await file('OWNER.marker').readAsString() == marker,
        'control_marker_mismatch',
      );
      check(
        !await file('ready.local.json').exists(),
        'control_directory_must_be_new',
      );
      WidgetsFlutterBinding.ensureInitialized();
      MediaKit.ensureInitialized();
      temporary = await Directory.systemTemp.createTemp('shiyu-agent-demo-');
      resolvedRoot = await temporary!.resolveSymbolicLinks();
      await File('${temporary!.path}/DEMO.OWNER')
          .writeAsString(marker, flush: true);
      startupAttempted = true;
      owner = await ClientApplicationOwner.open(
        root: temporary!,
        silentValidation: true,
      );
      await hidden(phase: 'owner-open');
      const title = '原创演示：讲清今天的计划';
      const text = '今天我会先核对需求，再运行测试。确认没有问题后，保存这轮修改。这份演示只验证文字送入和阅读练习，不包含发音评分。';
      final draft = await app.materials.createDraft(title: title, text: text);
      final original = await app.materials.confirmVersion(
        materialId: draft.materialId,
        expectedRevision: draft.revision,
      );
      sourceMaterialId = original.materialId;
      sourceVersionId = original.versionId;
      sourceHash = sha256.convert(utf8.encode(original.text)).toString();
      check(
        (await app.learning.listCandidates()).isEmpty &&
            (await app.learning.listVersions()).isEmpty,
        'demo_bootstrap_must_have_no_candidate_or_learning',
      );
      await app.agentBridge.authorize(
        AgentBridgeGrantRequest(
          materialVersionId: original.versionId,
          allowSourceRead: true,
        ),
      );
      final setup = await app.agentBridge.setup();
      runApp(
        agentDemoFocusBoundary(
          RepaintBoundary(
            key: boundary,
            child: ShiyuLocalClient(owner: app),
          ),
        ),
      );
      await frame();
      await hidden(phase: 'rendered-before-ready');
      await save('ready.local.json', {
        'schema': 'shiyu.windows.controlled-agent-demo.v1',
        'demo_id': id,
        'ready': true,
        'pid': pid,
        'descriptor_path': setup.descriptorPath,
        'source_reference': {
          'material_id': original.materialId,
          'material_version_id': original.versionId,
          'source_text_sha256': sourceHash,
        },
        'controlled_app_bootstrap': true,
        'source_is_original_demo_not_user_data': true,
        'read_source_grant_is_controlled': true,
        'candidate_count': 0,
        'learning_version_count': 0,
        'entry_will_not_receive_or_confirm':
            'waiting for current conversation standard MCP tools/call',
        'normal_app_default_bridge_closed': true,
        'native_hidden': true,
        'native_focused': false,
      });
      final deadline = DateTime.now().add(const Duration(minutes: 10));
      var stopRequested = false;
      while (DateTime.now().isBefore(deadline)) {
        if (await signal('stop.request')) {
          stopRequested = true;
          break;
        }
        if (!sampled && await signal('sample.request')) await capture();
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      check(stopRequested, 'demo_control_deadline');
      check(sampled, 'stopped_before_external_candidate_sample');
    } on _DemoFailure catch (error) {
      failure = error.code;
    } catch (_) {
      failure = 'controlled_demo_initialization_or_sampling_failed';
    }
    try {
      await stop();
    } catch (_) {
      failure ??= 'cleanup_native_or_store_drain_unconfirmed';
    }
    if (failure == null && sampled && cleanupConfirmed) {
      try {
        await removeOwnTemporaryRoot();
      } catch (_) {
        failure = 'temporary_root_cleanup_unconfirmed';
      }
    }
    final result = <String, Object?>{
      'schema': 'shiyu.windows.controlled-agent-demo-result.v1',
      'demo_id': id,
      'passed':
          failure == null && sampled && cleanupConfirmed && temporaryRemoved,
      'failure': failure,
      'sampled': sampled,
      'candidate_id': candidateId,
      'candidate_confirmed': false,
      'learning_version_count': 0,
      'cleanup_confirmed': cleanupConfirmed,
      'root_lock_released': owner == null ? null : !app.rootLock.isHeld,
      'temporary_root_removed': temporaryRemoved,
      'owner_cleanup_required': !cleanupConfirmed,
      'retained_own_temporary_root': temporaryRemoved ? null : resolvedRoot,
      'controlled_app_bootstrap': true,
      'current_conversation_tool_delivery_required': true,
      'native_codex_mcp_registration_proven': false,
      'official_brand_authenticated': false,
      'play_requested': false,
      'user_material_accessed': false,
      'all_hardware_release_guarantee': false,
      'last_native_status': lastNative,
      'native_status_history': 'native-status-history.local.json',
    };
    try {
      await save('result.local.json', result);
    } catch (_) {}
    stdout.writeln(
      'SHIYU_AGENT_DEMO_RESULT ${jsonEncode({'passed': result['passed'], 'sampled': sampled, 'cleanupConfirmed': cleanupConfirmed, 'temporaryRootRemoved': temporaryRemoved, 'ownerCleanupRequired': !cleanupConfirmed})}',
    );
    // Unknown cleanup retains this own process/root for Root inspection instead
    // of falsely asserting native release or deleting an unverified directory.
    if (cleanupConfirmed) exit(result['passed'] == true ? 0 : 1);
  }
}
