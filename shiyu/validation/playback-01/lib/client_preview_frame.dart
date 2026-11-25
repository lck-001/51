import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:client_shell/client_shell.dart';

/// Local-preview notice and content, without owning app or native resources.
class ClientPreviewFrame extends StatelessWidget {
  const ClientPreviewFrame({
    super.key,
    required this.notice,
    required this.child,
  });

  final ValueListenable<String?> notice;
  final Widget child;

  @override
  Widget build(BuildContext context) => Material(
    color: ShiyuClientTokens.paper,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SafeArea(
          bottom: false,
          child: Material(
            color: ShiyuClientTokens.hint,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: ValueListenableBuilder<String?>(
                valueListenable: notice,
                builder: (_, notice, _) => Text(
                  notice ?? '本机预览 · 仅此设备保存，尚未接入翻译、配音和发音评分',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ),
          ),
        ),
        Expanded(child: child),
      ],
    ),
  );
}
