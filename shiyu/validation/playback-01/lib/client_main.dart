import 'dart:io';
import 'dart:isolate';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:agent_bridge/agent_bridge_contracts.dart';

import 'client_application.dart';
import 'client_startup_retention.dart';
import 'client_ui_wire.dart';
import 'client_ui_validation_root.dart';
import 'client_ui_validation_session.dart';
import 'client_ui_validation_frame.dart';

/// Explicit client target. The original native playback probe remains unchanged.
Future<void> main(List<String> args) async {
  ClientUiArguments? validation;
  try {
    validation = ClientUiArguments.parse(
      args,
      debug: kDebugMode,
      windows: Platform.isWindows,
      validationOnly: const bool.fromEnvironment('SHIYU_UI_VALIDATION_ONLY'),
    );
  } catch (_) {
    stderr.writeln('ui_validation_entry_rejected');
    exit(64);
  }
  final startup = ClientStartupAttempt(
    id: validation?.attempt,
    validationOnly: validation != null,
  );
  WidgetsFlutterBinding.ensureInitialized();
  const proofSource = ClientUiNativeProofSource();
  ClientUiRootPlan? plan;
  if (validation != null) {
    try {
      plan = await ClientUiRootPlan.guard(validation, proofSource, ownPid: pid);
    } catch (_) {
      stderr.writeln('ui_validation_root_rejected');
      exit(64);
    }
  }
  try {
    startup.mediaLibraryAttempted = true;
    MediaKit.ensureInitialized();
    startup.mediaLibraryReturned = true;
    final root = plan == null
        ? Directory(
            '${(await getApplicationSupportDirectory()).path}/shiyu_client_local_v1',
          )
        : Directory(plan.profilePath);
    if (plan != null) {
      uiNeed(await proofSource.absent(plan.profilePath), 'profile-reentered');
    }
    final originalOwner = ClientApplicationOwner.open(
      root: root,
      silentValidation:
          plan != null || (kDebugMode && args.contains('--silent-validation')),
      startupAttempt: startup,
    );
    final owner = await startup.observe(
      ClientStartupOperation.ownerOpen,
      originalOwner,
    );
    final app = ShiyuLocalClient(owner: owner);
    if (plan == null) {
      runApp(app);
    } else {
      final isolateId = developer.Service.getIsolateId(Isolate.current);
      uiNeed(isolateId != null, 'main-isolate');
      final session = ClientUiValidationSession(
        plan,
        proofSource,
        isolateId!,
        phaseWriter: (bytes) async {
          stdout.add(bytes);
          await stdout.flush();
        },
      );
      await session.attachOwner(owner);
      owner.bindUiValidation(session);
      session.register();
      runApp(ClientUiFrameObserver(session: session, child: app));
    }
  } catch (error, stack) {
    final failure = startup.fail(error, stack);
    if (validation != null) {
      stderr.writeln('ui_validation_startup_retained');
      await startup.holdResident();
      return;
    }
    final primary = failure.primaryError;
    final message =
        primary is AgentBridgeException &&
            primary.code == AgentBridgeErrorCode.rootBusy
        ? '已有拾语进程正在使用这份本机资料。请先关闭原窗口后再试；未打开或重置资料。'
        : '本机资料或播放服务尚未初始化，请关闭后重试。原资料没有被重置。';
    runApp(
      MaterialApp(
        home: Scaffold(
          body: SafeArea(child: Center(child: Text(message))),
        ),
      ),
    );
    await startup.holdResident();
  }
}
