// Cooperative RootLock QA with real OS locks and separate owned Dart processes.
// This is not a production identity test or proof against an unsupported writer.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_bridge/agent_bridge.dart';

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

String directVm() {
  final current = File(Platform.resolvedExecutable);
  final vm = File('${current.parent.path}/dartvm${Platform.isWindows ? '.exe' : ''}');
  return vm.existsSync() ? vm.path : current.path;
}

Future<ProcessResult> probe(Directory root) => Process.run(
    directVm(),
    [File.fromUri(Platform.script).absolute.path, 'probe', root.path]);

Future<void> child(List<String> args) async {
  try {
    final lock = await LearningRootLock.acquire(Directory(args[1]));
    if (args.first == 'hold') {
      stdout.writeln('LOCKED:$pid');
      await stdout.flush();
      // Keep only this task-owned child alive; parent closes stdin or kills it.
      await stdin.drain<void>();
    } else {
      stdout.writeln(jsonEncode({'acquired': true}));
    }
    await lock.release();
  } on AgentBridgeException catch (error) {
    stdout.writeln(jsonEncode({'acquired': false, 'code': error.code.name}));
  }
}

Future<void> main(List<String> args) async {
  if (args.isNotEmpty) return child(args);
  final root = await Directory.systemTemp.createTemp('shiyu-root-lock-independent-');
  var passed = 0;
  LearningRootLock? held;
  Process? ownedChild;
  try {
    held = await LearningRootLock.acquire(root);
    check(held.isHeld, 'first instance must own its OS lock');
    var deniedSameProcess = false;
    try { await LearningRootLock.acquire(root); }
    on AgentBridgeException catch (error) {
      deniedSameProcess = error.code == AgentBridgeErrorCode.rootBusy;
    }
    check(deniedSameProcess, 'same-process second acquire must reject before opening the inode');
    final stillBusy = await probe(root);
    final busy = jsonDecode(stillBusy.stdout as String) as Map<String, dynamic>;
    check(stillBusy.exitCode == 0 && busy['acquired'] == false && busy['code'] == 'rootBusy',
        'failed same-process acquisition must not release the original OS lock');
    passed++;
    stdout.writeln('PASS same-process rejection preserves real cross-process exclusion');

    await held.release();
    await held.release();
    check(!held.isHeld, 'released authority must not still report held');
    final sentinel = File('${held.rootDirectory.path}/.shiyu-owner.lock');
    check(await sentinel.exists(), 'release must not unlink and replace the sentinel inode');
    final afterRelease = await probe(root);
    check(afterRelease.exitCode == 0 &&
        (jsonDecode(afterRelease.stdout as String) as Map<String, dynamic>)['acquired'] == true,
        'a new process must acquire after actual release');
    passed++;
    stdout.writeln('PASS release permits a fresh process and keeps the sentinel');

    ownedChild = await Process.start(directVm(),
        [File.fromUri(Platform.script).absolute.path, 'hold', root.path]);
    // Consume bounded diagnostics without reflecting private path/OS strings.
    ownedChild.stderr.listen((_) {});
    final ready = await ownedChild.stdout.transform(utf8.decoder)
        .transform(const LineSplitter()).first.timeout(const Duration(seconds: 5));
    check(ready == 'LOCKED:${ownedChild.pid}',
        'the Process handle must identify the actual holder VM, not an SDK launcher');
    final second = await probe(root);
    check(second.exitCode == 0 &&
        (jsonDecode(second.stdout as String) as Map<String, dynamic>)['code'] == 'rootBusy',
        'two actual new processes must not both acquire');
    passed++;
    stdout.writeln('PASS two separate new processes cannot own one root');

    check(ownedChild.kill(ProcessSignal.sigkill), 'terminate only the exact child spawned here');
    await ownedChild.exitCode.timeout(const Duration(seconds: 5));
    ownedChild = null;
    final afterCrash = await probe(root);
    check(afterCrash.exitCode == 0 &&
        (jsonDecode(afterCrash.stdout as String) as Map<String, dynamic>)['acquired'] == true,
        'OS must release the crashed process lock without deleting its sentinel');
    passed++;
    stdout.writeln('PASS task-owned process crash releases OS authority');
  } catch (error) {
    stdout.writeln('FAIL root lock (${error.runtimeType})');
    exitCode = 1;
  } finally {
    if (ownedChild != null) {
      ownedChild.kill(ProcessSignal.sigkill);
      await ownedChild.exitCode;
    }
    await held?.release();
    final resolved = await root.resolveSymbolicLinks();
    final temp = await Directory.systemTemp.resolveSymbolicLinks();
    check(resolved.startsWith('$temp${Platform.pathSeparator}') &&
        root.uri.pathSegments.where((part) => part.isNotEmpty).last
            .startsWith('shiyu-root-lock-independent-'), 'refuse cleanup outside owned temp root');
    await root.delete(recursive: true);
  }
  stdout.writeln('RESULT passed=$passed total=4');
  if (passed != 4) exitCode = 1;
}
