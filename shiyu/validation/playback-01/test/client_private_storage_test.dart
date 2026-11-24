import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:learning_core/learning_core.dart';
import 'package:learning_playback/learning_playback.dart';
import 'package:playback_core/playback_core.dart';
import 'package:material_import/material_import.dart';
import 'package:shiyu_playback_probe/client_retirement.dart';
import 'package:shiyu_playback_probe/client_material_import.dart';

import '../../../packages/material_import/test/extractor_independent.dart'
    as docx;

import 'package:flutter_test/flutter_test.dart';
import 'package:shiyu_playback_probe/client_private_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('real headless storage factory imports synthetic TXT and closes one authority safely', () async {
    final base = await Directory.systemTemp.createTemp('shiyu-g1-b-author-');
    final source = File('${base.path}/synthetic.txt');
    await source.writeAsString('合成工厂测试。\nSynthetic fixture only.', flush: true);
    final storage = await ClientPrivateStorage.open(
      root: Directory('${base.path}/profile'),
      proxyCommand: ['missing-proxy-not-started.exe'],
      selection: (_) async => source,
    );
    try {
      expect(storage.rootLock.isHeld, isTrue);
      expect(
        storage.mediaIngest!.isBoundTo(
          materials: storage.materials,
          learning: storage.learning,
          rootLock: storage.rootLock,
        ),
        isTrue,
      );
      expect(storage.agentBridge.current.allowMediaReceive, isFalse);
      await expectLater(
        storage.closeStoresAndAuthority(),
        throwsA(
          isA<ClientStorageException>().having(
            (e) => e.code,
            'code',
            ClientStorageErrorCode.notDrained,
          ),
        ),
      );
      expect(storage.rootLock.isHeld, isTrue);
      final session = storage.materialImports.start(),
          preview = await session.preview;
      expect(preview, isNotNull);
      expect(preview!.text, contains('Synthetic fixture only.'));
      expect(
        storage.materialImports.stagingRoot.path,
        contains('material-import-staging'),
      );
      final stages = await storage.materialImports.stagingRoot.list().toList();
      expect(stages.length, 1);
      await storage.materialImports.pathGuard!(stages.single);
      final refs = await session.prepareArtifacts();
      expect(refs.length, 2);
      final draft = await storage.materials.createDraft(
        title: preview.title,
        text: preview.text,
        artifacts: refs,
      );
      await session.finish(savedMaterialId: draft.materialId);
      expect(
        await storage.materialImports.stagingRoot.list().toList(),
        isEmpty,
      );
      expect(await source.readAsString(), contains('Synthetic fixture only.'));
      storage.retire();
      await storage.drainWriters();
      expect(storage.writersDrained, isTrue);
      expect(storage.rootLock.isHeld, isTrue);
      await storage.closeStoresAndAuthority();
      expect(storage.authorityReleased, isTrue);
      expect(storage.rootLock.isHeld, isFalse);
    } finally {
      await storage.drainWriters();
      await storage.closeStoresAndAuthority();
    }
  });
  for (final resolve in [false, true]) {
    test(
      'cache ${resolve ? 'resolve' : 'prepare'} guard await retire closes without new disk step',
      () async {
        final storage = await makeStorage();
        try {
          final item = await readyItem(storage),
              entered = Completer<void>(),
              release = Completer<void>();
          var guards = 0;
          final cache = FilePlayableCache(
            root: Directory(
              '${storage.rootLock.rootDirectory.path}/playable-cache',
            ),
            materials: storage.materials,
            learning: storage.learning,
            pathGuard: (entry) async {
              await storage.playableCache.pathGuard!(entry);
              guards++;
              if (!entered.isCompleted) {
                entered.complete();
                await release.future;
              }
            },
          );
          final operation = resolve
              ? cache.resolveForEngine(item)
              : cache.prepare(item);
          final observed = operation.then<Object?>(
            (value) => value,
            onError: (Object error) => error,
          );
          await entered.future;
          cache.retire();
          var drained = false;
          final draining = cache.drain().then((_) => drained = true);
          await Future<void>(() {});
          expect(drained, isFalse);
          release.complete();
          final result = await observed;
          expect(
            result,
            isA<LearningPlaybackException>().having(
              (e) => e.code,
              'closed',
              LearningPlaybackErrorCode.closed,
            ),
          );
          await draining;
          expect(guards, 1);
          expect(
            await Directory(
              '${storage.rootLock.rootDirectory.path}/playable-cache',
            ).list().toList(),
            isEmpty,
          );
          await expectLater(
            cache.prepare(item),
            throwsA(isA<LearningPlaybackException>()),
          );
          await expectLater(
            cache.resolveForEngine(item),
            throwsA(isA<LearningPlaybackException>()),
          );
        } finally {
          await storage.drainWriters();
          await storage.closeStoresAndAuthority();
        }
      },
    );
    test(
      'factory cache ${resolve ? 'resolve' : 'prepare'} real rename future holds storage lock through retire',
      () async {
        final parent = Zone.current;
        var pause = false;
        final entered = Completer<void>(), release = Completer<void>();
        await IOOverrides.runZoned(
          () async {
            final storage = await makeStorage();
            try {
              final item = await readyItem(storage);
              pause = true;
              final operation = resolve
                  ? storage.playableCache.resolveForEngine(item)
                  : storage.playableCache.prepare(item);
              final observed = operation.then<Object?>(
                (value) => value,
                onError: (Object error) => error,
              );
              await entered.future;
              storage.retire();
              var drained = false;
              final draining = storage.drainWriters().then(
                (_) => drained = true,
              );
              await Future<void>(() {});
              expect(drained, isFalse);
              expect(storage.rootLock.isHeld, isTrue);
              await expectLater(
                storage.closeStoresAndAuthority(),
                throwsA(isA<ClientStorageException>()),
              );
              release.complete();
              expect(
                await observed,
                isA<LearningPlaybackException>().having(
                  (e) => e.code,
                  'closed',
                  LearningPlaybackErrorCode.closed,
                ),
              );
              await draining;
              expect(storage.writersDrained, isTrue);
              await storage.closeStoresAndAuthority();
              expect(storage.rootLock.isHeld, isFalse);
            } finally {
              pause = false;
              if (!release.isCompleted) release.complete();
              try {
                await storage.drainWriters();
                await storage.closeStoresAndAuthority();
              } catch (_) {}
            }
          },
          createFile: (path) {
            final real = parent.run(() => File(path));
            return pause && path.endsWith('.wav.next')
                ? PausedRenameFile(real, entered, release)
                : real;
          },
        );
      },
    );
  }
  for (final throwing in [false, true]) {
    test(
      'native idle ${throwing ? 'throw' : 'false'} waits real artifact prepare then reports first error',
      () async {
        final parent = Zone.current;
        var pause = false;
        final entered = Completer<void>(), release = Completer<void>();
        await IOOverrides.runZoned(
          () async {
            final base = await Directory.systemTemp.createTemp(
                  'shiyu-g1-b-idle-',
                ),
                source = File('${base.path}/synthetic.txt');
            await source.writeAsString('Actual synthetic artifact body.');
            final storage = await ClientPrivateStorage.open(
              root: Directory('${base.path}/profile'),
              proxyCommand: [],
              selection: (_) async => source,
              nativeIdleProbe: (_) async {
                if (throwing) throw StateError('synthetic-native-idle');
                return false;
              },
            );
            final session = storage.materialImports.start();
            await session.preview;
            pause = true;
            final preparing = session.prepareArtifacts().then<Object?>(
              (value) => value,
              onError: (Object error) => error,
            );
            await entered.future;
            storage.retire();
            var done = false;
            final closing = storage.drainWriters().then<Object?>(
              (_) {
                done = true;
                return null;
              },
              onError: (Object error) {
                done = true;
                return error;
              },
            );
            await Future<void>(() {});
            expect(done, isFalse);
            expect(storage.rootLock.isHeld, isTrue);
            release.complete();
            await preparing;
            expect(await closing, isA<ClientStorageException>());
            expect(storage.writersDrained, isFalse);
            await expectLater(
              storage.closeStoresAndAuthority(),
              throwsA(isA<ClientStorageException>()),
            );
            expect(storage.rootLock.isHeld, isTrue);
            final blobs =
                await Directory(
                      '${storage.rootLock.rootDirectory.path}/materials',
                    )
                    .list(recursive: true, followLinks: false)
                    .where((e) => e is File && e.path.endsWith('.blob'))
                    .toList();
            expect(
              blobs.length,
              1,
              reason: 'real source artifact may commit, sidecar must not start after retire',
            );
            expect(await storage.learning.listCandidates(), isEmpty);
            pause = false; // Expected failed-close fixture intentionally retains authority until test process exit.
          },
          createFile: (path) {
            final real = parent.run(() => File(path));
            return pause && path.endsWith('.blob.next')
                ? PausedRenameFile(real, entered, release)
                : real;
          },
        );
      },
    );
  }
  test('actual retirement helper executes all synchronous gates despite first throw and waits accepted drains', () async {
    final gate = Completer<void>(), events = <String>[];
    final sequence = ClientRetirement(
      admissions: [
        () {
          events.add('first');
          throw StateError('synthetic');
        },
        () {
          events.add('cache');
        },
        () {
          events.add('importer');
        },
        () {
          events.add('bridge');
        },
      ],
      drains: [
        () => gate.future,
        () {
          events.add('other-drain');
        },
      ],
    );
    sequence.retire();
    expect(events, ['first', 'cache', 'importer', 'bridge', 'other-drain']);
    var done = false;
    final result = sequence.completion.then<Object?>(
      (_) {
        done = true;
        return null;
      },
      onError: (Object error) {
        done = true;
        return error;
      },
    );
    await Future<void>(() {});
    expect(done, isFalse);
    gate.complete();
    expect(await result, isA<ClientRetirementException>());
  });
  test(
    'actual headless DOCX staging source sidecar and close step guards',
    () async {
      final base = await Directory.systemTemp.createTemp('shiyu-g1-b-docx-'),
          source = File('${base.path}/synthetic.docx');
      final bytes = docx.package(
        docx.document('<w:p><w:r><w:t>Synthetic DOCX only.</w:t></w:r></w:p>'),
      );
      await source.writeAsBytes(bytes, flush: true);
      final storage = await ClientPrivateStorage.open(
        root: Directory('${base.path}/profile'),
        proxyCommand: [],
        selection: (_) async => source,
      );
      try {
        final session = storage.materialImports.start(),
            preview = (await session.preview)!;
        expect(preview.text, 'Synthetic DOCX only.');
        final refs = await session.prepareArtifacts();
        expect(refs, hasLength(2));
        expect(await storage.materials.readArtifact(refs[0]), bytes);
        final sidecar = jsonDecode(
          utf8.decode(await storage.materials.readArtifact(refs[1])),
        ) as Map;
        expect(sidecar['format'], 'docx');
        final draft = await storage.materials.createDraft(
          title: preview.title,
          text: preview.text,
          artifacts: refs,
        );
        await session.finish(savedMaterialId: draft.materialId);
        await expectLater(
          storage.closeLearning(),
          throwsA(isA<ClientStorageException>()),
        );
        await expectLater(
          storage.closeMaterials(),
          throwsA(isA<ClientStorageException>()),
        );
        await expectLater(
          storage.releaseAuthority(),
          throwsA(isA<ClientStorageException>()),
        );
        await storage.drainWriters();
        await expectLater(
          storage.closeMaterials(),
          throwsA(isA<ClientStorageException>()),
        );
        await expectLater(
          storage.releaseAuthority(),
          throwsA(isA<ClientStorageException>()),
        );
        await storage.closeLearning();
        await expectLater(
          storage.releaseAuthority(),
          throwsA(isA<ClientStorageException>()),
        );
        await storage.closeMaterials();
        await storage.releaseAuthority();
        await storage.closeStoresAndAuthority();
        expect(storage.authorityReleased, isTrue);
        expect(await source.readAsBytes(), bytes);
      } finally {
        await storage.drainWriters();
        await storage.closeStoresAndAuthority();
      }
    },
  );
  for (final cleanupThrows in [false, true]) {
    test(
      'native idle false drains tracked finish and coalesced cleaning cleanupThrows=$cleanupThrows',
      () async {
        final base = await Directory.systemTemp.createTemp(
              'shiyu-g1-b-finishing-',
            ),
            source = File('${base.path}/source.txt');
        await source.writeAsString('Synthetic finishing body.');
        final entered = Completer<void>(), release = Completer<void>();
        var cleanups = 0;
        final storage = await ClientPrivateStorage.open(
          root: Directory('${base.path}/profile'),
          proxyCommand: [],
          selection: (_) async => source,
          nativeIdleProbe: (_) async => false,
          removeStage: (file) async {
            cleanups++;
            await file.delete();
            if (!entered.isCompleted) entered.complete();
            await release.future;
            if (cleanupThrows) {
              throw StateError('synthetic cleanup result failure');
            }
          },
        );
        final session = storage.materialImports.start(),
            preview = (await session.preview)!;
        final refs = await session.prepareArtifacts();
        final draft = await storage.materials.createDraft(
          title: preview.title,
          text: preview.text,
          artifacts: refs,
        );
        final finishing = session
            .finish(savedMaterialId: draft.materialId)
            .then<Object?>((_) => null, onError: (Object error) => error);
        await entered.future;
        storage.retire();
        var closed = false;
        final closing = storage.drainWriters().then<Object?>(
          (_) {
            closed = true;
            return null;
          },
          onError: (Object error) {
            closed = true;
            return error;
          },
        );
        await Future<void>(() {});
        expect(closed, isFalse);
        expect(storage.rootLock.isHeld, isTrue);
        release.complete();
        expect(await finishing, isNotNull);
        expect(await closing, isA<ClientStorageException>());
        expect(
          cleanups,
          1,
          reason: 'finish and cancel must await one actual deletion',
        );
        expect(storage.writersDrained, isFalse);
        expect(storage.rootLock.isHeld, isTrue);
        expect(storage.materialImports.cleanupPending, isTrue);
        await expectLater(
          storage.closeStoresAndAuthority(),
          throwsA(isA<ClientStorageException>()),
        );
        expect(await storage.materials.readDraft(draft.materialId), isNotNull);
        expect(
          await storage.materialImports.stagingRoot.list().toList(),
          isEmpty,
        );
        // Expected failed-close fixture retains authority until this owned test process exits.
      },
    );
  }
  for (final pause in ['length', 'nextGuard', 'sourceGuard']) {
    test('import retirement after $pause await stops subsequent IO', () async {
      final storage = await makeStorage();
      final base = await Directory.systemTemp.createTemp('shiyu-g1-b-gate-');
      final source = File('${base.path}/source.txt');
      await source.writeAsString('Synthetic gate source.');
      final entered = Completer<void>(), release = Completer<void>();
      var creates = 0, opens = 0, renames = 0;
      final imports = ClientMaterialImportController(
        materials: storage.materials,
        stagingRoot: storage.materialImports.stagingRoot,
        selection: (_) async => pause == 'length'
            ? PausedLengthFile(source, entered, release)
            : source,
        nativeIdleProbe: (_) async => true,
        pathGuard: (entry) async {
          await storage.materialImports.pathGuard!(entry);
          final match =
              pause == 'nextGuard' && entry.path.endsWith('.next') ||
              pause == 'sourceGuard' && entry.path.endsWith('.source');
          if (match && !entered.isCompleted) {
            entered.complete();
            await release.future;
          }
        },
      );
      final parent = Zone.current;
      await IOOverrides.runZoned(
        () async {
          final session = imports.start();
          await entered.future;
          imports.retire();
          var closed = false;
          final closing = imports.close().then((_) {
            closed = true;
          });
          await Future<void>(() {});
          expect(closed, isFalse);
          release.complete();
          expect(await session.preview, isNull);
          await closing;
        },
        createFile: (path) {
          final real = parent.run(() => File(path));
          if (!path.startsWith(imports.stagingRoot.path)) return real;
          return ObservedStageFile(
            real,
            () {
              creates++;
            },
            () {
              opens++;
            },
            () {
              renames++;
            },
          );
        },
      );
      expect(
        creates,
        pause == 'length'
            ? 0
            : pause == 'nextGuard'
            ? 1
            : 2,
      );
      expect(opens, pause == 'sourceGuard' ? 1 : 0);
      expect(renames, 0);
      expect(await imports.stagingRoot.list().toList(), isEmpty);
      expect(await source.readAsString(), 'Synthetic gate source.');
      await storage.drainWriters();
      await storage.closeStoresAndAuthority();
    });
  }
  test('genuine cache rename failure makes storage drain fail and retains authority', () async {
    final storage = await makeStorage();
    final item = await readyItem(storage);
    final parent = Zone.current;
    await IOOverrides.runZoned(
      () async {
        await expectLater(
          storage.playableCache.prepare(item),
          throwsA(isA<LearningPlaybackException>()),
        );
      },
      createFile: (path) {
        final real = parent.run(() => File(path));
        return path.endsWith('.wav.next') ? FailingRenameFile(real) : real;
      },
    );
    await expectLater(
      storage.drainWriters(),
      throwsA(isA<ClientStorageException>()),
    );
    expect(storage.writersDrained, isFalse);
    expect(storage.rootLock.isHeld, isTrue);
    await expectLater(
      storage.closeStoresAndAuthority(),
      throwsA(isA<ClientStorageException>()),
    );
  });
  test('public close steps coalesce concurrent direct calls', () async {
    final storage = await makeStorage();
    await storage.drainWriters();
    final learning = storage.closeLearning();
    expect(identical(learning, storage.closeLearning()), isTrue);
    await learning;
    final materials = storage.closeMaterials();
    expect(identical(materials, storage.closeMaterials()), isTrue);
    await materials;
    final authority = storage.releaseAuthority();
    expect(identical(authority, storage.releaseAuthority()), isTrue);
    await authority;
    expect(storage.authorityReleased, isTrue);
  });
  for (final code in [
    MaterialImportErrorCode.sessionClosed,
    MaterialImportErrorCode.cancelled,
  ]) {
    for (final nativeFailure in [false, true]) {
      test(
        'typed $code from ${nativeFailure ? "native" : "cleanup"} holds authority',
        () async {
          final base = await Directory.systemTemp.createTemp(
            'shiyu-g1-b-typed-',
          );
          final source = File('${base.path}/source.txt');
          await source.writeAsString('Synthetic typed failure.');
          final storage = await ClientPrivateStorage.open(
            root: Directory('${base.path}/profile'),
            proxyCommand: [],
            selection: (_) async => source,
            nativeIdleProbe: (_) async {
              if (nativeFailure) throw MaterialImportException(code);
              return true;
            },
            removeStage: (file) async {
              if (!nativeFailure) throw MaterialImportException(code);
              await file.delete();
            },
          );
          await storage.materialImports.start().preview;
          await expectLater(
            storage.drainWriters(),
            throwsA(isA<ClientStorageException>()),
          );
          expect(storage.writersDrained, isFalse);
          expect(storage.rootLock.isHeld, isTrue);
          expect(storage.materialImports.cleanupPending, isTrue);
        },
      );
    }
  }
  test('startup real Learning open failure releases only after earlier Material close and pin cleanup', () async {
    final parent = Zone.current;
    final base = await Directory.systemTemp.createTemp('shiyu-g1-b-startup-');
    final root = Directory('${base.path}/profile');
    var injected = false;
    await IOOverrides.runZoned(
      () async {
        await expectLater(
          ClientPrivateStorage.open(root: root, proxyCommand: []),
          throwsA(isA<LearningStoreException>()),
        );
      },
      fseGetType: (path, follow) {
        if (path.replaceAll('\\', '/').contains('/learning/')) {
          injected = true;
          throw FileSystemException('synthetic learning startup');
        }
        return parent.run(
          () => FileSystemEntity.type(path, followLinks: follow),
        );
      },
    );
    expect(injected, isTrue);
    final renamed = await root.rename('${root.path}-closed-startup');
    expect(await renamed.exists(), isTrue);
    expect(
      await File('${renamed.path}/client-security.marker').exists(),
      isTrue,
      reason: 'no profile reset after failed startup',
    );
  });
}

Future<ClientPrivateStorage> makeStorage() async {
  final base = await Directory.systemTemp.createTemp('shiyu-g1-b-cache-');
  return ClientPrivateStorage.open(
    root: Directory('${base.path}/profile'),
    proxyCommand: [],
  );
}

Uint8List syntheticWave() {
  final b = Uint8List(32044), d = ByteData.sublistView(b);
  void tag(int p, String text) => b.setRange(p, p + 4, ascii.encode(text));
  tag(0, 'RIFF');
  d.setUint32(4, b.length - 8, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  d.setUint32(16, 16, Endian.little);
  d.setUint16(20, 1, Endian.little);
  d.setUint16(22, 1, Endian.little);
  d.setUint32(24, 16000, Endian.little);
  d.setUint32(28, 32000, Endian.little);
  d.setUint16(32, 2, Endian.little);
  d.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  d.setUint32(40, 32000, Endian.little);
  return b;
}

Future<PlaybackItem> readyItem(ClientPrivateStorage storage) async {
  final draft = await storage.materials.createDraft(
    title: 'Synthetic cache fixture',
    text: 'Original fixture.',
  );
  final fixed = await storage.materials.confirmVersion(
        materialId: draft.materialId,
        expectedRevision: draft.revision,
      ),
      artifact = await storage.materials.importArtifact(syntheticWave());
  const provenance = ContentProvenance(
    origin: ContentOrigin.synthetic,
    reference: 'g1-cache-fixture',
  );
  final version = await storage.learning.createVersion(
    materialVersionId: fixed.versionId,
    sentences: [const LearningSentenceInput(english: 'Fixture.')],
    textProvenance: provenance,
    media: LearningMediaInput(
      artifact: artifact,
      provenance: provenance,
      timings: [
        const SentenceTiming(sentenceIndex: 0, startMs: 0, endMs: 1000),
      ],
    ),
  );
  return (await storage.learning.openPlayback(
    version.binding.learningVersionId,
  )).item;
}

final class PausedRenameFile implements File {
  PausedRenameFile(this.real, this.entered, this.release);
  final File real;
  final Completer<void> entered, release;
  @override
  String get path => real.path;
  @override
  Directory get parent => real.parent;
  @override
  Future<int> length() => real.length();
  @override
  Future<Uint8List> readAsBytes() => real.readAsBytes();
  @override
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) => real.writeAsBytes(bytes, mode: mode, flush: flush);
  @override
  Future<File> rename(String path) async {
    final result = await real.rename(path);
    if (!entered.isCompleted) entered.complete();
    await release.future;
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unused synthetic file probe');
}

final class FailingRenameFile implements File {
  FailingRenameFile(this.real);
  final File real;
  @override
  String get path => real.path;
  @override
  Directory get parent => real.parent;
  @override
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) => real.writeAsBytes(bytes, mode: mode, flush: flush);
  @override
  Future<File> rename(String path) async =>
      throw FileSystemException('synthetic genuine cache rename failure');
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unused failure probe');
}

final class PausedLengthFile implements File {
  PausedLengthFile(this.real, this.entered, this.release);
  final File real;
  final Completer<void> entered, release;
  @override
  Future<int> length() async {
    final value = await real.length();
    entered.complete();
    await release.future;
    return value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unused length probe');
}

final class ObservedStageFile implements File {
  ObservedStageFile(this.real, this.onCreate, this.onOpen, this.onRename);
  final File real;
  final void Function() onCreate, onOpen, onRename;
  @override
  String get path => real.path;
  @override
  Future<File> create({bool recursive = false, bool exclusive = false}) {
    onCreate();
    return real.create(recursive: recursive, exclusive: exclusive);
  }

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) {
    onOpen();
    return real.open(mode: mode);
  }

  @override
  Future<File> rename(String path) {
    onRename();
    return real.rename(path);
  }

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      real.delete(recursive: recursive);
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unused stage probe');
}
