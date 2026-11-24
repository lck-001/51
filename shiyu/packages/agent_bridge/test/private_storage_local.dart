// G1-A only: own synthetic directories/files. No Store/import/cache/App opens.
import 'dart:async';
import 'dart:io';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:agent_bridge/private_storage.dart';
import 'package:agent_bridge/agent_bridge.dart' show LearningRootLock;
import 'package:agent_bridge/src/windows_privacy.dart';

void check(bool value, String label) {
  if (!value) throw StateError(label);
}

Future<Object> failed(FutureOr<Object?> Function() action, String label) async {
  try {
    await action();
  } catch (error) {
    return error;
  }
  throw StateError('Expected failure: $label');
}

String join(String parent, String leaf) =>
    '$parent${Platform.pathSeparator}$leaf';

final class FixtureAcl {
  FixtureAcl(this.owned);
  final Directory owned;
  final kernel = DynamicLibrary.open('kernel32.dll'),
      adv = DynamicLibrary.open('advapi32.dll');
  late final from = adv
      .lookupFunction<
        Int32 Function(
          Pointer<Utf16>,
          Uint32,
          Pointer<Pointer<Void>>,
          Pointer<Uint32>,
        ),
        int Function(
          Pointer<Utf16>,
          int,
          Pointer<Pointer<Void>>,
          Pointer<Uint32>,
        )
      >('ConvertStringSecurityDescriptorToSecurityDescriptorW');
  late final set = adv
      .lookupFunction<
        Int32 Function(Pointer<Utf16>, Uint32, Pointer<Void>),
        int Function(Pointer<Utf16>, int, Pointer<Void>)
      >('SetFileSecurityW');
  late final free = kernel
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>),
        Pointer<Void> Function(Pointer<Void>)
      >('LocalFree');
  late final read = adv
      .lookupFunction<
        Int32 Function(
          Pointer<Utf16>,
          Uint32,
          Pointer<Void>,
          Uint32,
          Pointer<Uint32>,
        ),
        int Function(Pointer<Utf16>, int, Pointer<Void>, int, Pointer<Uint32>)
      >('GetFileSecurityW');
  late final encode = adv
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Uint32,
          Uint32,
          Pointer<Pointer<Utf16>>,
          Pointer<Uint32>,
        ),
        int Function(
          Pointer<Void>,
          int,
          int,
          Pointer<Pointer<Utf16>>,
          Pointer<Uint32>,
        )
      >('ConvertSecurityDescriptorToStringSecurityDescriptorW');
  String snapshot(String path) => using((arena) {
    final count = arena<Uint32>();
    read(path.toNativeUtf16(allocator: arena), 5, nullptr, 0, count);
    check(count.value > 0 && count.value <= 65536, 'owned descriptor bounded');
    final data = arena<Uint8>(count.value);
    check(
      read(
            path.toNativeUtf16(allocator: arena),
            5,
            data.cast<Void>(),
            count.value,
            count,
          ) !=
          0,
      'owned readonly descriptor',
    );
    final text = arena<Pointer<Utf16>>();
    check(
      encode(data.cast<Void>(), 1, 5, text, nullptr) != 0,
      'descriptor readback',
    );
    try {
      return text.value.toDartString();
    } finally {
      free(text.value.cast<Void>());
    }
  });
  void replace(String path, String flags, {bool extra = false}) {
    WindowsPrivacy.instance.rejectReparse(path);
    final base = WindowsPrivacy.instance
            .canonicalPath(owned.absolute.path)
            .toLowerCase()
            .replaceAll('/', '\\'),
        target = WindowsPrivacy.instance
            .canonicalPath(File(path).absolute.path)
            .toLowerCase()
            .replaceAll('/', '\\');
    if (!target.startsWith('$base\\'))
      throw StateError('outside-owned-fixture');
    final sid = WindowsPrivacy.instance.currentSid;
    using((arena) {
      final sd = arena<Pointer<Void>>();
      final sddl =
          'O:${sid}D:P(A;$flags;FA;;;$sid)(A;$flags;FA;;;SY)${extra ? '(A;OICI;FA;;;WD)' : ''}';
      check(
        from(sddl.toNativeUtf16(allocator: arena), 1, sd, nullptr) != 0,
        'fixture descriptor parsed',
      );
      try {
        check(
          set(path.toNativeUtf16(allocator: arena), 0x80000005, sd.value) != 0,
          'fixture ACL applied only owned path',
        );
      } finally {
        free(sd.value);
      }
    });
  }
}

Future<void> main(List<String> args) async {
  if (args.length == 3 && args.first == '--contender') {
    try {
      final lease = await WindowsPrivateAppRoot.open(
        supportParent: Directory(args[1]),
        leaf: args[2],
      );
      await lease.close();
      stdout.writeln('UNEXPECTED_OPEN');
      exitCode = 1;
    } catch (error) {
      stdout.writeln(error.toString().contains('rootBusy') ? 'BUSY' : 'FAILED');
    }
    return;
  }
  if (!Platform.isWindows) throw StateError('Windows-only-author-check');
  final base = await Directory.systemTemp.createTemp('shiyu-g1-a-author-');
  final acl = FixtureAcl(base);
  final lease = await WindowsPrivateAppRoot.open(
    supportParent: base,
    leaf: 'safe-profile',
  );
  final root = lease.root;
  check(lease.rootLock.isHeld, 'real root authority held');
  lease.verifySameRoot(lease.rootLock);
  final audit = await lease.verifyPrivateDescendants();
  check(
    audit.directories == 6 && audit.files == 0,
    'six protected roots prepared',
  );
  WindowsPrivacy.instance.verify(root.path);
  for (final child in [
    'materials',
    'learning',
    'playable-cache',
    'material-import-staging',
    'agent_bridge',
    'media_ingest',
  ])
    WindowsPrivacy.instance.verify(lease.childDirectory(child).path);
  print(
    'PASS atomic private root and six children / strict P plus propagation / real RootLock',
  );
  final dir = await Directory(
    join(lease.childDirectory('materials').path, 'synthetic-intermediate'),
  ).create();
  final evidence = lease.verifyEffectivePath(dir.path);
  check(
    evidence.kind == PrivateAclKind.inheritedPrivate && evidence.propagates,
    'ordinary inherited directory separately classified',
  );
  await failed(
    () => WindowsPrivacy.instance.verify(dir.path),
    'ordinary inherited not protected',
  );
  final file = File(join(dir.path, 'synthetic.next'));
  await file.writeAsString('synthetic-only', flush: true);
  check(
    lease.verifyEffectivePath(file.path).kind ==
        PrivateAclKind.inheritedPrivate,
    'inherited file privately effective',
  );
  final ready = await file.rename(join(dir.path, 'synthetic.data'));
  check(
    lease.verifyEffectivePath(ready.path).kind ==
        PrivateAclKind.inheritedPrivate,
    'rename preserves private effective ACL',
  );
  print(
    'PASS readonly inherited domain evidence / strict verify not weakened / synthetic file rename',
  );
  await failed(
    () => root.rename('${root.path}-moved'),
    'root pinned no share delete',
  );
  await failed(
    () => lease.childDirectory('agent_bridge').delete(),
    'empty child pinned no share delete',
  );
  final wrongRoot = await Directory(join(base.path, 'wrong-lock')).create();
  final wrong = await LearningRootLock.acquire(wrongRoot);
  await failed(
    () => lease.verifySameRoot(wrong),
    'different held root refused',
  );
  await wrong.release();
  print(
    'PASS actual root rename and empty child delete refused while pinned / mismatched lock rejected',
  );
  await lease.close();
  check(!lease.rootLock.isHeld, 'close released real lock');
  final reopened = await WindowsPrivateAppRoot.open(
    supportParent: base,
    leaf: 'safe-profile',
  );
  check(
    (await ready.readAsString()) == 'synthetic-only',
    'reopen preserved data',
  );
  await reopened.close();
  await Directory(root.path).rename('${root.path}-renamed');
  check(
    await ready
        .readAsString()
        .then((_) => false)
        .catchError((Object _) => true),
    'old path changed only after pins closed',
  );
  print(
    'PASS marked profile reopen readonly validation / original synthetic bytes preserved',
  );
  for (final flags in ['', 'OI', 'CI', 'OICIIO', 'OICINP']) {
    final path = Directory(
      join(base.path, 'bad-flags-${flags.isEmpty ? 'none' : flags}'),
    );
    await path.create();
    acl.replace(path.path, flags);
    final originalAcl = acl.snapshot(path.path);

    await failed(
      () => WindowsPrivateAppRoot.open(
        supportParent: base,
        leaf: path.uri.pathSegments.where((p) => p.isNotEmpty).last,
      ),
      'unsafe propagation flags',
    );
    check(
      !await File(join(path.path, '.shiyu-owner.lock')).exists() &&
          !await File(join(path.path, 'client-security.marker')).exists(),
      'unsafe domain got no marker/lock writes',
    );
    check(
      acl.snapshot(path.path) == originalAcl,
      'unsafe domain ACL not modified',
    );
  }
  print(
    'PASS P without OI-CI / inherit-only / no-propagate rejected before bytes or layout writes',
  );
  final legacy = Directory(join(base.path, 'legacy-data'));
  await legacy.create();
  acl.replace(legacy.path, 'OICI');
  final original = File(join(legacy.path, 'untouched.txt'));
  await original.writeAsString('do-not-adopt');
  final legacyAcl = acl.snapshot(legacy.path);
  await failed(
    () => WindowsPrivateAppRoot.open(supportParent: base, leaf: 'legacy-data'),
    'unmarked nonempty',
  );
  check(
    await original.readAsString() == 'do-not-adopt' &&
        (await legacy.list().toList()).length == 1,
    'legacy content no extra writes',
  );
  check(acl.snapshot(legacy.path) == legacyAcl, 'legacy ACL unchanged');
  final wide = Directory(join(base.path, 'wide-root'));
  await wide.create();
  acl.replace(wide.path, 'OICI', extra: true);
  final wideAcl = acl.snapshot(wide.path);
  await failed(
    () => WindowsPrivateAppRoot.open(supportParent: base, leaf: 'wide-root'),
    'extra principal',
  );
  check(
    (await wide.list().toList()).isEmpty && acl.snapshot(wide.path) == wideAcl,
    'wide root unchanged',
  );
  print(
    'PASS unmarked legacy nonempty and wide existing root failclosed without changing data',
  );
  await concurrencyAndPartial(base, acl);
  await reparseAndDepth(base, acl);
}

Future<void> concurrencyAndPartial(Directory base, FixtureAcl acl) async {
  final lease = await WindowsPrivateAppRoot.open(
    supportParent: base,
    leaf: 'concurrency-profile',
  );
  try {
    final before = acl.snapshot(lease.root.path);
    final local = await failed(
      () => WindowsPrivateAppRoot.open(
        supportParent: base,
        leaf: 'concurrency-profile',
      ),
      'same process writer',
    );
    check(
      local.toString().contains('rootBusy') && lease.rootLock.isHeld,
      'same-process guard preserves original authority',
    );
    final sdk = File(Platform.resolvedExecutable).parent,
        vm = File(join(sdk.path, 'dartvm.exe'));
    final package = Directory.fromUri(Platform.script.resolve('../'));
    final child = await Process.start(
      vm.existsSync() ? vm.path : Platform.resolvedExecutable,
      [
        '-Dshiyu_test_marker=g1-a-contender-${DateTime.now().microsecondsSinceEpoch}',
        '--packages=${join(package.path, '.dart_tool/package_config.json')}',
        'test/private_storage_local.dart',
        '--contender',
        base.path,
        'concurrency-profile',
      ],
      workingDirectory: package.path,
    );
    stdout.writeln('TASK_G1_VM_PID ${child.pid}');
    final output = child.stdout.transform(SystemEncoding().decoder).join(),
        errors = child.stderr.transform(SystemEncoding().decoder).join();
    final code = await child.exitCode.timeout(const Duration(seconds: 10));
    check(
      code == 0 && (await output).trim() == 'BUSY' && (await errors).isEmpty,
      'actual second VM refused by real RootLock',
    );
    check(
      acl.snapshot(lease.root.path) == before && lease.rootLock.isHeld,
      'busy checks no root ACL modification',
    );
  } finally {
    await lease.close();
  }
  print(
    'PASS same process and marked second VM writer refused / original lock and ACL preserved',
  );
  for (final mode in [
    'missing-child',
    'missing-lock',
    'bad-marker',
    'bad-middle',
    'wide-child',
    'inherited-credential',
  ]) {
    final leaf = 'partial-$mode',
        owner = await WindowsPrivateAppRoot.open(
          supportParent: base,
          leaf: 'partial-$mode',
        );
    final root = owner.root, materials = owner.childDirectory('materials');
    await owner.close();
    String? changedPath;
    if (mode == 'missing-child') {
      await Directory(join(root.path, 'learning')).delete();
    } else if (mode == 'missing-lock') {
      await File(join(root.path, '.shiyu-owner.lock')).delete();
    } else if (mode == 'bad-marker') {
      await File(join(root.path, 'client-security.marker'))
          .writeAsString('synthetic-bad-marker', flush: true);
    } else if (mode == 'bad-middle') {
      final dir = await Directory(join(materials.path, 'existing-middle'))
          .create();
      acl.replace(dir.path, '');
      changedPath = dir.path;
    } else if (mode == 'inherited-credential') {
      final file = File(join(root.path, 'agent_bridge/synthetic-descriptor'));
      await file.writeAsString('synthetic-private-but-not-P');
      changedPath = file.path;
    } else {
      acl.replace(materials.path, 'OICI', extra: true);
      changedPath = materials.path;
    }
    final before = (await root.list().toList())
        .map((e) => e.uri.pathSegments.where((v) => v.isNotEmpty).last)
        .toSet();
    final rootAcl = acl.snapshot(root.path),
        childAcl = changedPath == null ? null : acl.snapshot(changedPath),
        marker = await File(join(root.path, 'client-security.marker'))
            .readAsBytes();
    await failed(
      () => WindowsPrivateAppRoot.open(supportParent: base, leaf: leaf),
      'partial unsafe layout',
    );
    final after = (await root.list().toList())
        .map((e) => e.uri.pathSegments.where((v) => v.isNotEmpty).last)
        .toSet();
    check(
      before.length == after.length &&
          before.every(after.contains) &&
          acl.snapshot(root.path) == rootAcl,
      'partial profile no root/ACL edits',
    );
    check(
      marker.toString() ==
          (await File(
            join(root.path, 'client-security.marker'),
          ).readAsBytes()).toString(),
      'bad marker preserved not healed',
    );
    if (changedPath != null)
      check(
        acl.snapshot(changedPath) == childAcl,
        'unsafe child/domain ACL preserved',
      );
    // Only a task-owned synthetic profile: successful rename after rejection
    // proves failed open did not leak a no-share-delete pin or file authority.
    await root.rename('${root.path}-after-failure');
  }
  print(
    'PASS partial marker-child-lock / nonpropagating middle / wide child readonly failclosed preservation',
  );
}

Future<void> reparseAndDepth(Directory base, FixtureAcl acl) async {
  final target = await Directory(join(base.path, 'link-target')).create(),
      sentinel = File(join(base.path, 'link-target/sentinel.txt'));
  await sentinel.writeAsString('synthetic-target-preserved', flush: true);
  final targetAcl = acl.snapshot(target.path),
      link = Link(join(base.path, 'linked-profile'));
  await link.create(target.path);
  await failed(
    () =>
        WindowsPrivateAppRoot.open(supportParent: base, leaf: 'linked-profile'),
    'linked root rejected',
  );
  check(
    acl.snapshot(target.path) == targetAcl &&
        await sentinel.readAsString() == 'synthetic-target-preserved',
    'root link did not mutate target',
  );
  final owner = await WindowsPrivateAppRoot.open(
    supportParent: base,
    leaf: 'linked-interior',
  );
  final materials = owner.childDirectory('materials'), root = owner.root;
  await owner.close();
  await Link(join(materials.path, 'external-link')).create(target.path);
  await failed(
    () => WindowsPrivateAppRoot.open(
      supportParent: base,
      leaf: 'linked-interior',
    ),
    'linked owned tree rejected',
  );
  check(
    acl.snapshot(target.path) == targetAcl &&
        (await root.list().toList()).length == 8,
    'linked tree no target or layout mutation',
  );
  final parentLink = Link(join(base.path, 'linked-parent'));
  await parentLink.create(target.path);
  await failed(
    () => WindowsPrivateAppRoot.open(
      supportParent: Directory(parentLink.path),
      leaf: 'not-created',
    ),
    'support parent reparse',
  );
  check(
    !await Directory(join(target.path, 'not-created')).exists(),
    'reparse support parent not followed',
  );
  print(
    'PASS root-child-support reparse refused / external synthetic target ACL and bytes unchanged',
  );
  final deep = await WindowsPrivateAppRoot.open(
    supportParent: base,
    leaf: 'depth-profile',
  );
  var current = deep.childDirectory('materials');
  for (var i = 0; i < 13; i++) {
    current = await Directory(join(current.path, 'd$i')).create();
  }
  await failed(deep.verifyPrivateDescendants, 'depth audit bounded');
  await deep.close();
  await failed(
    () =>
        WindowsPrivateAppRoot.open(supportParent: base, leaf: 'depth-profile'),
    'deep marked profile bounded',
  );
  print(
    'PASS bounded depth audit failclosed / no recursive cleanup or implicit profile replacement',
  );
}
