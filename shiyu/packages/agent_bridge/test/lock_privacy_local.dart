import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:agent_bridge/agent_bridge.dart';
import 'package:agent_bridge/src/private_descriptor.dart';

Future<void> main(List<String> args) async {
  if(args.isNotEmpty) {
    try {
      final lock=await LearningRootLock.acquire(Directory(args[1]));
      if(args[0]=='--hold') { stdout.writeln('HOLDING:$pid'); await stdin.drain<void>(); }
      await lock.release(); exitCode=0;
    } on AgentBridgeException catch(error) { exitCode=error.code==AgentBridgeErrorCode.rootBusy?11:12; }
    return;
  }
  var phase='begin',checks=0;
  final root=await Directory.systemTemp.createTemp('shiyu-bridge-lock-');
  LearningRootLock? lock;
  Process? holder;
  void check(bool value) { if(!value) throw StateError('controlled_check'); checks++; }
  Future<int> child(String path) async => (await Process.run(Platform.resolvedExecutable,
      [Platform.script.toFilePath(),'--try',path])).exitCode;
  try {
    phase='first-root-lock'; lock=await LearningRootLock.acquire(root); check(lock.isHeld);
    phase='same-process-guard';
    try { await LearningRootLock.acquire(root); throw StateError('duplicate_allowed'); }
    on AgentBridgeException catch(error) { check(error.code==AgentBridgeErrorCode.rootBusy); }
    phase='second-process-blocked'; check(await child(root.path)==11);
    phase='new-private-descriptor';
    final storage=PrivateDescriptorStore(rootLock:lock,directory:Directory('${root.path}/private'));
    final random=Random.secure();
    String hex(int n)=>List.generate(n,(_)=>random.nextInt(256).toRadixString(16).padLeft(2,'0')).join();
    final desc=BridgeDescriptor(port:12345,session:hex(16),capability:hex(32),proofKey:hex(32),
      integrationId:'controlled-local',materialId:hex(16),materialVersionId:hex(16),
      sourceTextSha256:hex(32),expiresAtUtc:DateTime.now().toUtc().add(const Duration(minutes:15)),allowSourceRead:false);
    await storage.write(desc);
    final read=await readPrivateDescriptor(storage.path);
    check(read.session==desc.session && read.capability==desc.capability);
    phase='existing-broad-directory-denied';
    final broad=await Directory('${root.path}/broad').create();
    final invalid=PrivateDescriptorStore(rootLock:lock,directory:broad);
    try { await invalid.write(desc); throw StateError('broad_directory_allowed'); }
    on AgentBridgeException catch(error) { check(error.code==AgentBridgeErrorCode.privateStorageUnavailable); }
    check(!await File('${broad.path}/descriptor.json').exists());
    phase='root-release-reacquire'; await lock.release(); check(await child(root.path)==0);
    check(await File('${root.path}/.shiyu-owner.lock').exists());
    phase='crash-releases-os-lock';
    final actualVm=Platform.isWindows
        ? File('${File(Platform.resolvedExecutable).parent.path}/dartvm.exe').path
        : Platform.resolvedExecutable;
    holder=await Process.start(actualVm,[Platform.script.toFilePath(),'--hold',root.path]);
    final ready=await holder.stdout.transform(utf8.decoder).transform(const LineSplitter()).first;
    check(ready=='HOLDING:${holder.pid}'); check(await child(root.path)==11);
    check(holder.kill(ProcessSignal.sigkill)); await holder.exitCode; holder=null;
    check(await child(root.path)==0);
    stdout.writeln('PASS lock/privacy native checks=$checks');
  } catch(error) {
    stderr.writeln('FAIL phase=$phase code=${error is AgentBridgeException?error.code.name:error.runtimeType}');
    exitCode=1;
  } finally {
    if(holder!=null) { holder.kill(ProcessSignal.sigkill); await holder.exitCode; }
    try { await lock?.release(); } catch(_) {}
    await root.delete(recursive:true);
  }
}
