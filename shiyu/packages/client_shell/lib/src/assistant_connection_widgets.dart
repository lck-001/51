import 'package:agent_bridge/agent_bridge_contracts.dart';
import 'package:flutter/services.dart';
import 'package:material_core/material_core.dart';
import 'package:material_ui/material_ui.dart';

Widget _privateSurface(
  BuildContext context,
  void Function(BuildContext)? onRoute,
  Widget child,
) {
  onRoute?.call(context);
  return child;
}

/// Local UI choice. The two permissions never imply one another.
final class AssistantGrantChoice {
  const AssistantGrantChoice({
    required this.allowSourceRead,
    required this.allowMediaReceive,
  });
  final bool allowSourceRead, allowMediaReceive;
}

Future<AssistantGrantChoice?> showAssistantGrantDialog(
  BuildContext context,
  MaterialVersion source, {
  void Function(BuildContext)? onPrivateRoute,
}) {
  var allowRead = false;
  var allowMedia = false;
  var submitted = false;
  return showDialog<AssistantGrantChoice>(
    context: context,
    builder: (ctx) => _privateSurface(
      ctx,
      onPrivateRoute,
      StatefulBuilder(
        builder: (ctx, update) => AlertDialog(
          title: const Text('允许助手整理这一版？'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${source.title} · 第 ${source.versionNumber} 版',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                const Text('只开放这一版的本机接收通道。请在你连接的助手里让它整理并送入英文；拾语不会代调翻译或配音服务。'),
                const SizedBox(height: 8),
                CheckboxListTile(
                  key: const Key('assistant-allow-source-read'),
                  contentPadding: EdgeInsets.zero,
                  value: allowRead,
                  onChanged: (value) =>
                      update(() => allowRead = value ?? false),
                  title: const Text('允许助手读取这一版原文'),
                ),
                const Text(
                  '默认只提供材料引用。若已把原文交给助手，可不勾选；否则需要开启正文读取。原文将交给该助手按其服务规则处理。',
                  style: TextStyle(fontSize: 12, height: 1.7),
                ),
                CheckboxListTile(
                  key: const Key('assistant-allow-media-receive'),
                  contentPadding: EdgeInsets.zero,
                  value: allowMedia,
                  onChanged: (value) =>
                      update(() => allowMedia = value ?? false),
                  title: const Text('允许接收配套音频'),
                  subtitle: const Text('音频接收与原文读取分别授权。收到后仍需本人校对确认，不会自动播放。'),
                ),
                const SizedBox(height: 12),
                const Text('临时授权只针对这一版，15 分钟后或关闭应用时结束；不能自动确认学习或公开，随时可撤销。'),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('assistant-authorize-confirm'),
              onPressed: () {
                if (submitted) return;
                submitted = true;
                Navigator.of(ctx).pop(
                  AssistantGrantChoice(
                    allowSourceRead: allowRead,
                    allowMediaReceive: allowMedia,
                  ),
                );
              },
              child: const Text('开启本机授权'),
            ),
          ],
        ),
      ),
    ),
  );
}

Future<void> showAssistantSetupDialog(
  BuildContext context,
  AgentBridgeSetup setup, {
  void Function(BuildContext)? onPrivateRoute,
}) => showDialog<void>(
  context: context,
  builder: (ctx) => _privateSurface(
    ctx,
    onPrivateRoute,
    AlertDialog(
      title: const Text('外部助手 · 高级连接说明'),
      content: SizedBox(
        width: 580,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '配置后，可以让已有助手把整理好的文字送入本 App。首次使用需在助手侧完成工具连接；下面的配置片段不包含密钥。',
              ),
              const SizedBox(height: 12),
              SelectableText(setup.instructions),
              const SizedBox(height: 16),
              const Text(
                '本机 MCP 配置片段',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              SelectableText(
                setup.configurationToml,
                key: const Key('assistant-setup-configuration'),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('assistant-copy-setup'),
          onPressed: () async {
            // Only an explicit in-app action copies the secret-free template. No
            // automatic clipboard write or account/configuration mutation occurs.
            await Clipboard.setData(
              ClipboardData(text: setup.configurationToml),
            );
          },
          child: const Text('复制配置片段'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('关闭'),
        ),
      ],
    ),
  ),
);

class AssistantConnectionCard extends StatelessWidget {
  const AssistantConnectionCard({
    super.key,
    required this.status,
    required this.sourceLabel,
    required this.busy,
    this.onRevoke,
    this.onSetup,
  });
  final AgentBridgeStatus? status;
  final String? sourceLabel;
  final bool busy;
  final VoidCallback? onRevoke, onSetup;

  String _time(DateTime value) {
    final local = value.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final state = status;
    final enabled = state?.phase == AgentBridgePhase.enabled;
    final draining = state?.phase == AgentBridgePhase.draining;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '外部助手连接',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              state == null
                  ? '此端尚未开放本机助手连接。'
                  : switch (state.phase) {
                      AgentBridgePhase.disabled => '本机授权未开启。',
                      AgentBridgePhase.enabled => '指定原文的临时授权已开启。',
                      AgentBridgePhase.draining => '正在结束授权，请等待已开始的保存完成。',
                      AgentBridgePhase.closed => '本机连接已结束。',
                    },
            ),
            if (enabled) ...[
              if (sourceLabel != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(sourceLabel!),
                ),
              const SizedBox(height: 6),
              Text(
                state!.allowSourceRead
                    ? '允许读取此版本原文，并送入待校对内容。'
                    : '只允许送入候选，未开放原文正文读取。',
              ),
              Text(
                state.allowMediaReceive ? '允许接收配套音频，收到后仍需校对确认。' : '未开放配套音频接收。',
              ),
              if (state.expiresAtUtc != null)
                Text('${_time(state.expiresAtUtc!)} 到期'),
              const SizedBox(height: 6),
              const Text(
                '来源信息可在收到的学习候选中查看。',
                style: TextStyle(fontSize: 12, height: 1.6),
              ),
            ],
            if ((state?.inFlight ?? 0) > 0)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('正在处理助手送入的内容…'),
              ),
            if (state?.lastCandidateId != null)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('已收到候选，请到学习页校对。'),
              ),
            Wrap(
              spacing: 8,
              children: [
                if (onRevoke != null && (enabled || draining))
                  TextButton(
                    key: const Key('assistant-revoke'),
                    onPressed: busy || draining ? null : onRevoke,
                    child: const Text('撤销本机授权'),
                  ),
                if (onSetup != null)
                  TextButton(
                    key: const Key('assistant-setup'),
                    onPressed: busy || draining ? null : onSetup,
                    child: const Text('高级连接说明'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
