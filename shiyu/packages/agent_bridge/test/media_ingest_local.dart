// Synthetic-only public executable tests. Run with an explicit offline package config.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_bridge/agent_bridge.dart';
import 'package:crypto/crypto.dart';
import 'package:learning_core/learning_core.dart';
import 'package:material_core/material_core.dart';

String hash(List<int> b) => sha256.convert(b).toString();
void expect(bool value, String label) {
  if (!value) throw StateError(label);
}

Future<void> rejects(Future<Object?> Function() action, String label) async {
  var failed = false;
  try {
    await action();
  } catch (_) {
    failed = true;
  }
  expect(failed, label);
}

Uint8List syntheticWave() {
  final b = Uint8List(160044), d = ByteData.sublistView(b);
  void tag(int p, String s) => b.setRange(p, p + 4, ascii.encode(s));
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
  d.setUint32(40, b.length - 44, Endian.little);
  return b;
}

final class MaterialProbe implements MaterialStore, IdempotentArtifactStore {
  MaterialProbe(this.real);
  final FileMaterialStore real;
  int registrations = 0;
  bool failLookup = false;
  Completer<void>? registrationEntered, registrationRelease;
  @override
  String get trustedOwnerId => real.trustedOwnerId;
  @override
  RecoveryReport get recoveryReport => real.recoveryReport;
  @override
  Future<MaterialVersion> readVersion(String id) => real.readVersion(id);
  @override
  Future<Uint8List> readArtifact(ArtifactRef ref) => real.readArtifact(ref);
  @override
  Future<ArtifactRef?> findArtifactRegistration(String key) {
    if (failLookup) throw StateError('synthetic authority unavailable');
    return real.findArtifactRegistration(key);
  }

  @override
  Future<ArtifactRef> registerArtifactOnce({
    required String operationKey,
    required String expectedSha256,
    required Uint8List bytes,
  }) async {
    registrations++;
    final result = await real.registerArtifactOnce(
      operationKey: operationKey,
      expectedSha256: expectedSha256,
      bytes: bytes,
    );
    registrationEntered?.complete();
    if (registrationRelease != null) await registrationRelease!.future;
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Unused Material probe method: ${invocation.memberName}',
  );
}

final class Fixture {
  late Directory root;
  late LearningRootLock lock;
  late FileMaterialStore materials;
  late MaterialProbe probe;
  late FileLearningStore learning;
  late MediaIngest ingest;
  late MediaIngestSourceBinding binding;
  late MediaIngestGrant grant;
  bool valid = true;
  final bytes = syntheticWave();
  static const textDeclaration = SourceDeclaration(
    preparation: 'synthetic text',
    provider: 'author',
  );
  static const audioDeclaration = SourceDeclaration(
    preparation: 'synthetic PCM',
    provider: 'fixture',
  );
  final sentences = [
    const LearningSentenceInput(
      english: 'Hello fixture.',
      translation: '合成结构测试。',
    ),
  ];
  Future<void> open() async {
    root = await Directory.systemTemp.createTemp('shiyu-media-author-');
    lock = await LearningRootLock.acquire(root);
    materials = await FileMaterialStore.open(
      root: Directory('${root.path}/materials'),
      trustedOwnerId: 'author',
    );
    probe = MaterialProbe(materials);
    learning = await FileLearningStore.open(
      root: Directory('${root.path}/learning'),
      materials: probe,
    );
    final draft = await materials.createDraft(
      title: 'Synthetic',
      text: 'Fixture source.',
    );
    final source = await materials.confirmVersion(
      materialId: draft.materialId,
      expectedRevision: draft.revision,
    );
    binding = MediaIngestSourceBinding(
      materialId: source.materialId,
      materialVersionId: source.versionId,
      sourceTextSha256: hash(utf8.encode(source.text)),
    );
    grant = newGrant();
    ingest = await module();
  }

  MediaIngestGrant newGrant() => MediaIngestGrant(
    ownerId: 'author',
    integrationId: 'author-fixture',
    binding: binding,
    allowMedia: true,
    isValid: () => valid,
  );
  Future<MediaIngest> module() => MediaIngest.open(
    privateRoot: Directory('${root.path}/ingest'),
    rootLock: lock,
    materials: probe,
    learning: learning,
    ownerId: 'author',
  );
  MediaIngestBegin manifest(String delivery, {String? commitment}) =>
      MediaIngestBegin(
        binding: binding,
        deliveryId: delivery,
        submissionSha256: commitment ?? '0' * 64,
        englishSha256: hash(
          utf8.encode(jsonEncode(sentences.map((s) => s.english).toList())),
        ),
        mediaSha256: hash(bytes),
        mediaBytes: bytes.length,
        timings: [
          const SentenceTiming(sentenceIndex: 0, startMs: 0, endMs: 5000),
        ],
        declaration: audioDeclaration,
        timingDeclaration: 'Synthetic structural timing',
      );
  MediaIngestSubmission submission(MediaIngestBegin b) => MediaIngestSubmission(
    binding: binding,
    deliveryId: b.deliveryId,
    sentences: sentences,
    declaration: textDeclaration,
    media: b,
  );
  MediaIngestBegin input(String delivery) => manifest(
    delivery,
    commitment: mediaIngestPayloadSha256(submission(manifest(delivery))),
  );
  String operation(String delivery) => hash(
    utf8.encode(
      jsonEncode([
        'shiyu-media-ingest-artifact:v1',
        'author',
        'author-fixture',
        delivery,
      ]),
    ),
  );
  Future<String> upload(MediaIngestBegin b, {bool seal = true}) async {
    final start = await ingest.begin(grant, b);
    for (var offset = 0, index = 0; offset < bytes.length; index++) {
      final end = offset + 65536 < bytes.length ? offset + 65536 : bytes.length;
      final part = Uint8List.fromList(bytes.sublist(offset, end));
      await ingest.chunk(
        grant,
        binding,
        start.uploadId,
        index,
        part,
        hash(part),
      );
      offset = end;
    }
    if (seal)
      return (await ingest.seal(grant, binding, start.uploadId)).sealedReceipt!;
    return start.uploadId;
  }

  Future<void> close() async {
    await ingest.close();
    await learning.close();
    await materials.close();
    await lock.release();
  }
}

Future<void> main() async {
  final f = Fixture();
  await f.open();
  try {
    final b = f.input('normal');
    final first = await f.ingest.begin(f.grant, b);
    final envelope = jsonDecode(
      await File('${f.root.path}/ingest/${first.uploadId}/journal.json')
          .readAsString(),
    ) as Map<String, dynamic>;
    final record = envelope['record'] as Map<String, dynamic>;
    expect(
      record['businessKey'] ==
          'e85e7fa93215c2a468e0f93a1df41e58d04689996169db0caa8c705ec5dae3c1',
      'independent Python business-key vector',
    );
    expect(
      record['operationKey'] ==
          'f36c3bf60ac523ef933035ae841959c7f4234e2977b93f045ed7503fabfd1f18',
      'independent Python operation-key vector',
    );
    final repeated = await f.ingest.begin(f.grant, b);
    expect(
      repeated.uploadId == first.uploadId && repeated.replayed,
      'begin idempotent',
    );
    final part = Uint8List.fromList(f.bytes.sublist(0, 65536));
    await f.ingest.chunk(
      f.grant,
      f.binding,
      first.uploadId,
      0,
      part,
      hash(part),
    );
    expect(
      (await f.ingest.chunk(
        f.grant,
        f.binding,
        first.uploadId,
        0,
        part,
        hash(part),
      )).replayed,
      'real chunk replay',
    );
    final corrupted = Uint8List.fromList(part)..[0] = 0;
    await rejects(
      () => f.ingest.chunk(
        f.grant,
        f.binding,
        first.uploadId,
        0,
        corrupted,
        hash(part),
      ),
      'lying hash rejected',
    );
    await rejects(
      () => f.ingest.seal(f.grant, f.binding, first.uploadId),
      'missing chunks rejected',
    );
    for (var offset = 65536, index = 1; offset < f.bytes.length; index++) {
      final end = offset + 65536 < f.bytes.length
          ? offset + 65536
          : f.bytes.length;
      final chunk = Uint8List.fromList(f.bytes.sublist(offset, end));
      await f.ingest.chunk(
        f.grant,
        f.binding,
        first.uploadId,
        index,
        chunk,
        hash(chunk),
      );
      offset = end;
    }
    final seal = await f.ingest.seal(f.grant, f.binding, first.uploadId);
    expect(
      (await f.ingest.seal(f.grant, f.binding, first.uploadId)).sealedReceipt ==
          seal.sealedReceipt,
      'seal stable',
    );
    final result = await f.ingest.submit(
      f.grant,
      f.binding,
      seal.sealedReceipt!,
      f.submission(b),
    );
    expect(result.status == 'delivered', 'actual delivery');
    final registration = await f.materials.findArtifactRegistration(
      f.operation('normal'),
    );
    expect(registration != null, 'actual registration');
    final replay = await f.ingest.submit(
      f.grant,
      f.binding,
      seal.sealedReceipt!,
      f.submission(b),
    );
    expect(
      replay.replayed && replay.candidateId == result.candidateId,
      'submit replay authority',
    );
    expect((await f.learning.listCandidates()).length == 1, 'one candidate');
    await f.ingest.close();
    expect(
      (await f.materials.readVersion(f.binding.materialVersionId)).text ==
          'Fixture source.',
      'module close leaves Stores open',
    );
    print('PASS normal multi-chunk / replay / actual Stores / module close');
  } finally {
    await f.close();
  }
  await recoveryCases();
  await invalidAndHoldCases();
  await drainCases();
  await persistenceFaultCases();
  await backupCases();
  await recordQuotaCase();
}

Future<void> recoveryCases() async {
  for (final registered in [false, true]) {
    final f = Fixture();
    await f.open();
    try {
      final b = f.input('sealed-reopen');
      final receipt = await f.upload(b);
      ArtifactRef? before;
      if (registered) {
        before = await f.materials.registerArtifactOnce(
          operationKey: f.operation(b.deliveryId),
          expectedSha256: b.mediaSha256,
          bytes: f.bytes,
        );
      }
      await f.ingest.close();
      f.ingest = await f.module();
      f.grant = f.newGrant();
      final same = await f.ingest.begin(f.grant, b);
      expect(
        same.sealedReceipt == receipt && same.replayed,
        'sealed journal reconstructs original receipt',
      );
      final delivered = await f.ingest.submit(
        f.grant,
        f.binding,
        receipt,
        f.submission(b),
      );
      expect(delivered.status == 'delivered', 'reopened actual delivery');
      if (before != null)
        expect(
          (await f.materials.findArtifactRegistration(
                f.operation(b.deliveryId),
              ))!.artifactId ==
              before.artifactId,
          'registration ACK gap uses original authority',
        );
      expect(
        (await f.learning.listCandidates()).length == 1,
        'reopened candidate unique',
      );
      print('PASS sealed reopen registered=$registered');
    } finally {
      await f.close();
    }
  }
  final f = Fixture();
  await f.open();
  try {
    final b = f.input('receiving-reopen');
    final id = await f.upload(b, seal: false);
    await f.ingest.close();
    f.ingest = await f.module();
    f.grant = f.newGrant();
    expect(
      (await f.ingest.begin(f.grant, b)).status == 'terminal',
      'receiving restart terminal',
    );
    await rejects(
      () => f.ingest.chunk(
        f.grant,
        f.binding,
        id,
        0,
        Uint8List.fromList(f.bytes.sublist(0, 65536)),
        hash(f.bytes.sublist(0, 65536)),
      ),
      'receiving restart cannot resume',
    );
    await f.ingest.begin(f.grant, f.input('fresh-after-cleanup'));
    expect(f.probe.registrations == 0, 'receiving recovery no register');
    print('PASS receiving reopen cleanup / fresh admission');
  } finally {
    await f.close();
  }
}

Future<void> invalidAndHoldCases() async {
  final f = Fixture();
  await f.open();
  try {
    final b = f.input('invalid');
    final receipt = await f.upload(b);
    final invalid = MediaIngestSubmission(
      binding: f.binding,
      deliveryId: b.deliveryId,
      sentences: [
        const LearningSentenceInput(english: '\ud800', translation: 'fixture'),
      ],
      declaration: Fixture.textDeclaration,
      media: b,
    );
    await rejects(
      () => f.ingest.submit(f.grant, f.binding, receipt, invalid),
      'bad Unicode rejected',
    );
    expect(f.probe.registrations == 0, 'known invalid Unicode before once');
    final empty = MediaIngestSubmission(
      binding: f.binding,
      deliveryId: b.deliveryId,
      sentences: f.sentences,
      declaration: const SourceDeclaration(preparation: ' '),
      media: b,
    );
    await rejects(
      () => f.ingest.submit(f.grant, f.binding, receipt, empty),
      'empty declaration rejected',
    );
    expect(f.probe.registrations == 0, 'empty declaration before once');
    final wrong = MediaIngestSourceBinding(
      materialId: 'f' * 32,
      materialVersionId: f.binding.materialVersionId,
      sourceTextSha256: f.binding.sourceTextSha256,
    );
    final stranger = MediaIngestGrant(
      ownerId: 'author',
      integrationId: 'author-fixture',
      binding: wrong,
      allowMedia: true,
      isValid: () => true,
    );
    final id = (await f.ingest.begin(f.grant, b)).uploadId;
    await rejects(
      () => f.ingest.abort(stranger, wrong, id),
      'wrong-source abort refused',
    );
    expect(
      (await f.ingest.submit(
            f.grant,
            f.binding,
            receipt,
            f.submission(b),
          )).status ==
          'delivered',
      'wrong abort does not stop upload',
    );
    await f.ingest.close();
    final part = File('${f.root.path}/ingest/$id/media.part');
    await part.writeAsBytes([1], mode: FileMode.append, flush: true);
    await rejects(() => f.module(), 'extra tail holds recovery');
    await rejects(() => f.module(), 'hold persists on second reopen');
    print(
      'PASS invalid preflight before once / wrong abort / persistent residue hold',
    );
  } finally {
    await f.close();
  }
}

Future<void> drainCases() async {
  for (final mode in ['abort', 'retire', 'close']) {
    final f = Fixture();
    await f.open();
    try {
      final b = f.input('drain-$mode');
      final receipt = await f.upload(b);
      final id = (await f.ingest.begin(f.grant, b)).uploadId;
      f.probe.registrationEntered = Completer<void>();
      f.probe.registrationRelease = Completer<void>();
      final submit = f.ingest.submit(
        f.grant,
        f.binding,
        receipt,
        f.submission(b),
      );
      final observed = submit.then<Object?>((v) => v, onError: (Object e) => e);
      await f.probe.registrationEntered!.future;
      final Future<Object?> stopped;
      if (mode == 'abort') {
        stopped = f.ingest.abort(f.grant, f.binding, id);
      } else if (mode == 'retire') {
        stopped = f.ingest.retireGrant(f.grant);
      } else {
        stopped = f.ingest.close();
      }
      var drained = false;
      final completion = stopped.then((v) {
        drained = true;
        return v;
      });
      await Future<void>.delayed(Duration.zero);
      expect(!drained, '$mode drains actual Material Future');
      await rejects(
        () => f.ingest.seal(f.grant, f.binding, id),
        '$mode immediate stop admission',
      );
      f.probe.registrationRelease!.complete();
      expect(
        await observed is StateError,
        '$mode prevents continuation after Material',
      );
      await completion;
      expect(
        (await f.learning.listCandidates()).isEmpty,
        '$mode Learning receive not entered',
      );
      expect(
        await f.materials.findArtifactRegistration(f.operation(b.deliveryId)) !=
            null,
        '$mode preserves registered artifact',
      );
      print(
        'PASS $mode synchronous stop / actual Material drain / no Learning delivery',
      );
    } finally {
      await f.close();
    }
  }
}

Future<void> persistenceFaultCases() async {
  final f = Fixture();
  await f.open();
  try {
    final b = f.input('journal-failure');
    final id = (await f.ingest.begin(f.grant, b)).uploadId;
    final bad = Directory('${f.root.path}/ingest/$id/journal.json.next');
    await bad.create();
    final chunk = Uint8List.fromList(f.bytes.sublist(0, 65536));
    await rejects(
      () => f.ingest.chunk(f.grant, f.binding, id, 0, chunk, hash(chunk)),
      'journal failure surfaced',
    );
    // This is exactly the injected empty directory, never a user directory.
    await bad.delete();
    await rejects(
      () => f.ingest.chunk(f.grant, f.binding, id, 0, chunk, hash(chunk)),
      'failed journal cannot become volatile replay ACK',
    );
    await f.ingest.close();
    await rejects(() => f.module(), 'journal failure persists across reopen');
    expect(f.probe.registrations == 0, 'journal failure cannot register');
    print(
      'PASS deterministic post-append journal failure / replay refusal / persistent hold',
    );
  } finally {
    await f.close();
  }
  final g = Fixture();
  await g.open();
  try {
    final b = g.input('lookup-failure');
    final receipt = await g.upload(b);
    g.probe.failLookup = true;
    await rejects(
      () => g.ingest.submit(g.grant, g.binding, receipt, g.submission(b)),
      'authority failure is unknown',
    );
    g.probe.failLookup = false;
    await rejects(
      () => g.ingest.submit(g.grant, g.binding, receipt, g.submission(b)),
      'authority recovery cannot clear persistent hold',
    );
    expect(g.probe.registrations == 0, 'lookup failure not absence');
    await g.ingest.close();
    await rejects(() => g.module(), 'authority hold persists');
    print('PASS authority query failure / no register / persistent hold');
  } finally {
    await g.close();
  }
  final h = Fixture();
  await h.open();
  try {
    final b = h.input('abort-race');
    final id = (await h.ingest.begin(h.grant, b)).uploadId;
    final stop = h.ingest.abort(h.grant, h.binding, id);
    final replay = await h.ingest.begin(h.grant, b);
    expect(
      replay.status == 'terminal',
      'begin cannot clear synchronous abort stop',
    );
    await stop;
    await rejects(
      () => h.ingest.chunk(
        h.grant,
        h.binding,
        id,
        0,
        Uint8List.fromList(h.bytes.sublist(0, 65536)),
        hash(h.bytes.sublist(0, 65536)),
      ),
      'terminal remains stopped',
    );
    print('PASS same-business begin cannot reopen aborted session');
  } finally {
    await h.close();
  }
}

Future<void> backupCases() async {
  for (final fault in [
    'phase',
    'chunks',
    'receipt',
    'extra',
    'missing-primary',
  ]) {
    final f = Fixture();
    await f.open();
    try {
      final b = f.input('backup-$fault');
      await f.upload(b);
      final id = (await f.ingest.begin(f.grant, b)).uploadId;
      await f.ingest.close();
      final main = File('${f.root.path}/ingest/$id/journal.json');
      if (fault == 'missing-primary') {
        await main.delete();
      } else {
        final bak = File('${main.path}.bak');
        final envelope =
            jsonDecode(await bak.readAsString()) as Map<String, dynamic>;
        final record = envelope['record'] as Map<String, dynamic>;
        if (fault == 'phase') record['phase'] = 'invented';
        if (fault == 'chunks') record['chunks'] = {'5': '0' * 64};
        if (fault == 'receipt') record['receipt'] = 'bad';
        if (fault == 'extra') record['unexpected'] = true;
        envelope['sha256'] = hash(utf8.encode(jsonEncode(record)));
        await bak.writeAsString(jsonEncode(envelope), flush: true);
      }
      await rejects(
        () => f.module(),
        'backup $fault rejected despite intact main or valid older backup',
      );
      expect(f.probe.registrations == 0, 'backup fault never registers');
      print('PASS backup full-shape / no fallback $fault');
    } finally {
      await f.close();
    }
  }
}

Future<void> recordQuotaCase() async {
  final f = Fixture();
  await f.open();
  try {
    for (var i = 0; i < 128; i++) {
      final b = f.input('terminal-$i');
      final id = (await f.ingest.begin(f.grant, b)).uploadId;
      await f.ingest.abort(f.grant, f.binding, id);
    }
    await rejects(
      () => f.ingest.begin(f.grant, f.input('terminal-over-limit')),
      'terminal record quota persists',
    );
    expect(f.probe.registrations == 0, 'record quota preflight no register');
    await f.ingest.close();
    f.ingest = await f.module();
    f.grant = f.newGrant();
    await rejects(
      () => f.ingest.begin(f.grant, f.input('terminal-over-limit')),
      'record quota after restart',
    );
    print('PASS 128 terminal records / quota+1 / restart accounting');
  } finally {
    await f.close();
  }
}
