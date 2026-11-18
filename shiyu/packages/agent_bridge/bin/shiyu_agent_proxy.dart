import 'dart:io';

import 'package:agent_bridge/src/client.dart';
import 'package:agent_bridge/src/mcp_proxy.dart';

/// Fixed executable entry. The descriptor locator is startup-only, never a tool
/// parameter, URL or secret in argv. Does not install/reload any host MCP config.
Future<void> main(List<String> args) async {
  final descriptor = Platform.environment['SHIYU_BRIDGE_DESCRIPTOR'];
  if (args.isNotEmpty ||
      descriptor == null ||
      descriptor.isEmpty ||
      descriptor.length > 4096 ||
      descriptor.codeUnits.any((u) => u < 32 || u == 127)) {
    stderr.writeln('shiyu_proxy_startup_unavailable');
    exitCode = 2;
    return;
  }
  try {
    final proxy = AgentBridgeMcpProxy(
      client: AgentBridgeClient(descriptorPath: descriptor),
    );
    exitCode = await proxy.run(input: stdin, output: stdout);
  } catch (_) {
    // No descriptor/path, credential, raw response or stack trace is echoed.
    stderr.writeln('shiyu_proxy_unavailable');
    exitCode = 1;
  }
}
