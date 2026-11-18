import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:agent_bridge/agent_bridge_contracts.dart';

import 'client_application.dart';

/// Explicit client target. The original native playback probe remains unchanged.
Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    MediaKit.ensureInitialized();
    final support = await getApplicationSupportDirectory();
    final owner = await ClientApplicationOwner.open(
      root: Directory('${support.path}/shiyu_client_local_v1'),
      silentValidation: kDebugMode && args.contains('--silent-validation'),
    );
    runApp(ShiyuLocalClient(owner: owner));
  } catch (error) {
    final message =
        error is AgentBridgeException &&
            error.code == AgentBridgeErrorCode.rootBusy
        ? '已有拾语进程正在使用这份本机资料。请先关闭原窗口后再试；未打开或重置资料。'
        : '本机资料或播放服务尚未初始化，请关闭后重试。原资料没有被重置。';
    runApp(
      MaterialApp(
        home: Scaffold(
          body: SafeArea(child: Center(child: Text(message))),
        ),
      ),
    );
  }
}
