import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

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
  } catch (_) {
    runApp(
      const MaterialApp(
        home: Scaffold(
          body: SafeArea(
            child: Center(child: Text('本机资料或播放服务尚未初始化，请关闭后重试。原资料没有被重置。')),
          ),
        ),
      ),
    );
  }
}
