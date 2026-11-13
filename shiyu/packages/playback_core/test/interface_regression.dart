import 'dart:async';

import '../lib/playback_core.dart';
import 'support.dart';

const audio = PlaybackItem(
  ownerId: 'owner-a',
  itemId: 'synthetic-a',
  itemRevision: 'r1',
  kind: MediaKind.audio,
);
const other = PlaybackItem(
  ownerId: 'owner-b',
  itemId: 'synthetic-b',
  itemRevision: 'r2',
  kind: MediaKind.audio,
);
const video = PlaybackItem(
  ownerId: 'owner-a',
  itemId: 'synthetic-v',
  itemRevision: 'r1',
  kind: MediaKind.video,
);

class EngineCall {
  EngineCall(this.name, this.token, [this.position, this.requestId]);
  final String name;
  final PlaybackToken token;
  final Duration? position;
  final int? requestId;
}

class Engine implements PlaybackEngineAdapter {
  final source = StreamController<EngineEvent>.broadcast(sync: true);
  final calls = <EngineCall>[];
  Completer<void>? nextPlay;
  Completer<void>? nextOpen;
  Completer<void>? nextSeek;
  @override
  Stream<EngineEvent> get events => source.stream;
  @override
  Future<void> open(PlaybackItem item, PlaybackToken token) {
    calls.add(EngineCall('open', token));
    final gate = nextOpen;
    nextOpen = null;
    return gate?.future ?? Future<void>.value();
  }

  @override
  Future<void> play(PlaybackToken token) {
    calls.add(EngineCall('play', token));
    final gate = nextPlay;
    nextPlay = null;
    return gate?.future ?? Future<void>.value();
  }

  @override
  Future<void> pause(PlaybackToken token) async {
    calls.add(EngineCall('pause', token));
  }

  @override
  Future<void> stop(PlaybackToken token) async {
    calls.add(EngineCall('stop', token));
  }

  @override
  Future<void> seek(Duration position, PlaybackToken token, int requestId) {
    calls.add(EngineCall('seek', token, position, requestId));
    final gate = nextSeek;
    nextSeek = null;
    return gate?.future ?? Future<void>.value();
  }

  int count(String name) => calls.where((c) => c.name == name).length;
}

class System implements SystemPlaybackAdapter {
  System(this.capabilities);
  @override
  final PlaybackCapabilities capabilities;
  final source = StreamController<PlaybackSystemEvent>.broadcast(sync: true);
  final publications = <PlaybackSnapshot>[];
  @override
  Stream<PlaybackSystemEvent> get events => source.stream;
  @override
  Future<void> publish(PlaybackSnapshot snapshot) async {
    publications.add(snapshot);
  }
}

class Rig {
  Rig({
    bool background = true,
    Duration seekTimeout = const Duration(seconds: 5),
  }) : system = System(
         PlaybackCapabilities(
           backgroundAudio: background,
           systemControls: true,
         ),
       ) {
    controller = PlaybackController(
      engine: engine,
      system: system,
      seekConfirmationTimeout: seekTimeout,
    );
    playback = controller;
    subscription = playback.snapshots.listen(seen.add);
    cleanupSubscription = controller.captureCleanupRequests.listen(
      cleanups.add,
    );
  }
  final engine = Engine();
  final System system;
  late final PlaybackController controller;
  late final Playback playback;
  late final StreamSubscription<PlaybackSnapshot> subscription;
  late final StreamSubscription<CaptureCleanupRequest> cleanupSubscription;
  final seen = <PlaybackSnapshot>[];
  final cleanups = <CaptureCleanupRequest>[];
  PlaybackSnapshot get last {
    expectThat(seen.isNotEmpty, 'Interface must publish a snapshot');
    return seen.last;
  }

  PlaybackToken get token => last.token;
  void emit(EngineEvent event) => engine.source.add(event);
  void send(PlaybackSystemEvent event) => system.source.add(event);
  Future<CommandResult> command(PlaybackCommand command) =>
      playback.dispatch(command);
  Future<void> open([PlaybackItem item = audio]) async {
    final result = await command(Open(item));
    expectThat(result.accepted, 'synthetic material should open');
    await settle();
    emit(EngineStateChanged(result.token, PlaybackActual.paused));
    emit(
      EngineProgress(
        result.token,
        position: Duration.zero,
        duration: const Duration(seconds: 12),
      ),
    );
  }

  Future<void> play() async {
    final result = await command(const Play());
    expectThat(result.accepted, 'explicit Play should be accepted');
    emit(EngineStateChanged(result.token, PlaybackActual.playing));
    await settle();
    expectThat(
      last.actual == PlaybackActual.playing,
      'engine-confirmed playback should be playing',
    );
  }

  Future<void> pause() async {
    final result = await command(const Pause());
    emit(EngineStateChanged(result.token, PlaybackActual.paused));
    await settle();
  }

  Future<void> close() async {
    await subscription.cancel();
    await cleanupSubscription.cancel();
    await controller.dispose();
    await engine.source.close();
    await system.source.close();
  }
}

Future<void> using(
  Future<void> Function(Rig) body, {
  bool background = true,
}) async {
  final rig = Rig(background: background);
  try {
    await body(rig);
  } finally {
    await rig.close();
  }
}

Future<void> main() async {
  final tests = Cases();
  await tests.run(
    'Open and Play acknowledgements are not actual playback',
    () => using((r) async {
      await r.open();
      expectThat(
        r.last.intent == PlaybackIntent.paused,
        'Open must not autoplay',
      );
      final result = await r.command(const Play());
      expectThat(result.accepted, 'Play accepted');
      await settle();
      expectThat(
        r.last.actual != PlaybackActual.playing,
        'ack must not fabricate actual playing',
      );
      r.emit(EngineStateChanged(result.token, PlaybackActual.playing));
      expectThat(
        r.last.actual == PlaybackActual.playing,
        'actual follows current engine evidence',
      );
    }),
  );

  await tests.run(
    'Pause before focus-gain defeats old resume permission',
    () => using((r) async {
      await r.open();
      await r.play();
      final old = r.token;
      r.send(FocusChanged(old, FocusState.transientLoss));
      await r.pause();
      final count = r.engine.count('play');
      r.send(FocusChanged(old, FocusState.gained));
      await settle();
      expectThat(
        r.engine.count('play') == count,
        'old focus gain must not play after Pause',
      );
      expectThat(
        r.last.intent == PlaybackIntent.paused &&
            r.last.actual == PlaybackActual.paused,
        'manual pause remains',
      );
    }),
  );

  await tests.run(
    'Focus-gain pending Play loses to later Pause',
    () => using((r) async {
      await r.open();
      await r.play();
      final old = r.token;
      final stops = r.engine.calls
          .where((c) => c.name == 'stop' && c.token.sameSession(old))
          .length;
      r.send(FocusChanged(old, FocusState.transientLoss));
      final gate = Completer<void>();
      r.engine.nextPlay = gate;
      r.send(FocusChanged(old, FocusState.gained));
      await r.pause();
      gate.complete();
      r.emit(EngineStateChanged(old, PlaybackActual.playing));
      await settle();
      expectThat(
        r.last.intent == PlaybackIntent.paused &&
            r.last.actual == PlaybackActual.paused,
        'late restore must not override Pause',
      );
      expectThat(
        r.engine.calls.any((c) => c.name == 'pause' && c.token == r.token),
        'late same-session Play is compensated by current-context Pause',
      );
      expectThat(
        r.engine.calls
                .where((c) => c.name == 'stop' && c.token.sameSession(old))
                .length ==
            stops,
        'same-session pause compensation must preserve loaded source',
      );
    }),
  );

  await tests.run(
    'All independent interruption holds must clear',
    () => using((r) async {
      await r.open();
      await r.play();
      final t = r.token;
      final count = r.engine.count('play');
      r.send(FocusChanged(t, FocusState.transientLoss, holdId: 'call'));
      r.send(FocusChanged(t, FocusState.transientLoss, holdId: 'navigation'));
      r.send(FocusChanged(t, FocusState.gained, holdId: 'call'));
      await settle();
      expectThat(
        r.engine.count('play') == count,
        'one remaining hold blocks restore',
      );
      r.send(FocusChanged(t, FocusState.gained, holdId: 'navigation'));
      await settle();
      expectThat(
        r.engine.count('play') == count + 1,
        'eligible final release restores once',
      );
    }),
  );

  await tests.run(
    'No auto-resume without observed actual playback',
    () => using((r) async {
      await r.open();
      await r.command(const Play());
      final t = r.token;
      final count = r.engine.count('play');
      r.send(FocusChanged(t, FocusState.transientLoss));
      r.send(FocusChanged(t, FocusState.gained));
      await settle();
      expectThat(
        r.engine.count('play') == count,
        'accepted Play without actual cannot grant restore',
      );
    }),
  );

  await tests.run(
    'System denies resume even when focus returns',
    () => using((r) async {
      await r.open();
      await r.play();
      final t = r.token;
      final count = r.engine.count('play');
      r.send(FocusChanged(t, FocusState.transientLoss));
      r.send(FocusChanged(t, FocusState.gained, mayResume: false));
      await settle();
      expectThat(
        r.engine.count('play') == count,
        'mayResume=false forbids restore',
      );
    }),
  );

  await tests.run(
    'New material and owner reject stale callbacks and commands',
    () => using((r) async {
      await r.open();
      await r.play();
      final stale = r.token;
      r.send(FocusChanged(stale, FocusState.transientLoss));
      await r.open(other);
      final current = r.token;
      final plays = r.engine.count('play');
      r.emit(EngineProgress(stale, position: const Duration(seconds: 11)));
      r.emit(EngineFailure(stale, 'synthetic old failure'));
      r.emit(EngineStateChanged(stale, PlaybackActual.ended));
      r.send(FocusChanged(stale, FocusState.gained));
      r.send(SystemMediaCommand(stale, const Play()));
      await settle();
      expectThat(
        r.last.token == current &&
            r.last.position == Duration.zero &&
            r.last.error == null,
        'old item cannot pollute current state',
      );
      expectThat(
        r.engine.count('play') == plays,
        'old notification/focus cannot start new material',
      );
    }),
  );

  await tests.run(
    'Permanent focus loss cannot be undone by focus gain',
    () => using((r) async {
      await r.open();
      await r.play();
      final t = r.token;
      r.send(FocusChanged(t, FocusState.permanentLoss));
      final count = r.engine.count('play');
      r.send(FocusChanged(t, FocusState.gained));
      await settle();
      expectThat(
        r.last.requiresFreshPlay && r.last.intent == PlaybackIntent.paused,
        'permanent loss revokes resume',
      );
      expectThat(
        r.engine.count('play') == count,
        'no auto-play on focus regain',
      );
    }),
  );

  await tests.run(
    'Route disconnect remains paused after focus regain',
    () => using((r) async {
      await r.open();
      await r.play();
      final t = r.token;
      r.send(RouteDisconnected(t));
      final count = r.engine.count('play');
      r.send(FocusChanged(t, FocusState.gained));
      await settle();
      expectThat(
        r.last.requiresFreshPlay && r.last.intent == PlaybackIntent.paused,
        'route disconnect needs new Play',
      );
      expectThat(
        r.engine.count('play') == count,
        'no unintended speaker playback',
      );
    }),
  );

  await tests.run(
    'Capture request immediately revokes playback and requires new Play',
    () => using((r) async {
      await r.open();
      await r.play();
      final request = r.token;
      r.send(CaptureRequested(request, 'mic'));
      expectThat(
        r.last.intent == PlaybackIntent.paused && r.last.requiresFreshPlay,
        'capture request synchronously revokes intent',
      );
      expectThat(
        !(await r.command(const Play())).accepted,
        'pending capture blocks UI Play',
      );
      r.send(SystemMediaCommand(r.token, const Play()));
      await settle();
      expectThat(
        r.last.intent == PlaybackIntent.paused,
        'pending capture blocks system Play',
      );
      r.send(CaptureResourceChanged(request, 'mic', ResourceState.closed));
      final count = r.engine.count('play');
      r.send(FocusChanged(r.token, FocusState.gained));
      await settle();
      expectThat(
        r.engine.count('play') == count && r.last.requiresFreshPlay,
        'closed capture does not resurrect old intention',
      );
      expectThat(
        (await r.command(const Play())).accepted,
        'fresh explicit Play accepted only after closed',
      );
    }),
  );

  await tests.run(
    'Unknown preview resource blocks playback across material changes',
    () => using((r) async {
      await r.open();
      final request = r.token;
      r.send(CaptureRequested(request, 'preview'));
      r.send(CaptureResourceChanged(request, 'preview', ResourceState.unknown));
      await r.open(other);
      expectThat(
        !(await r.command(const Play())).accepted,
        'new material must not erase unknown input resource',
      );
      expectThat(
        r.last.resources['preview'] == ResourceState.unknown,
        'unknown remains visible until genuine close',
      );
    }),
  );

  await tests.run(
    'Permission denial represented as closed still requires explicit Play',
    () => using((r) async {
      await r.open();
      await r.play();
      final request = r.token;
      r.send(CaptureRequested(request, 'denied-mic'));
      r.send(
        CaptureResourceChanged(request, 'denied-mic', ResourceState.closed),
      );
      final count = r.engine.count('play');
      r.send(ForegroundChanged(r.token, true));
      r.send(FocusChanged(r.token, FocusState.gained));
      await settle();
      expectThat(
        r.last.requiresFreshPlay && r.last.intent == PlaybackIntent.paused,
        'denial/foreground must not replay',
      );
      expectThat(
        r.engine.count('play') == count,
        'no adapter Play until new explicit command',
      );
    }),
  );

  await tests.run(
    'Video background pauses and foreground never auto-resumes',
    () => using((r) async {
      await r.open(video);
      await r.play();
      r.send(ForegroundChanged(r.token, false));
      expectThat(
        r.last.pauseCauses.contains(PauseCause.videoPolicy) &&
            r.last.intent == PlaybackIntent.paused,
        'background video blocked',
      );
      expectThat(
        !(await r.command(const Play())).accepted,
        'background video Play is not accepted',
      );
      final count = r.engine.count('play');
      r.send(ForegroundChanged(r.token, true));
      await settle();
      expectThat(
        r.last.requiresFreshPlay && r.engine.count('play') == count,
        'foreground does not start video',
      );
    }),
  );

  await tests.run(
    'Audio foreground-only capability pauses on background',
    () => using((r) async {
      await r.open();
      await r.play();
      r.send(ForegroundChanged(r.token, false));
      expectThat(
        r.last.intent == PlaybackIntent.paused &&
            r.last.pauseCauses.contains(PauseCause.backgroundUnsupported),
        'host unavailable must degrade explicitly',
      );
      final count = r.engine.count('play');
      r.send(ForegroundChanged(r.token, true));
      await settle();
      expectThat(
        r.engine.count('play') == count && r.last.requiresFreshPlay,
        'foreground-only recovery is manual',
      );
    }, background: false),
  );

  await tests.run(
    'Background-ready audio continues without duplicate play',
    () => using((r) async {
      await r.open();
      r.send(SystemHostChanged(r.token, true));
      await r.play();
      final count = r.engine.count('play');
      r.send(ForegroundChanged(r.token, false));
      await settle();
      expectThat(
        r.last.intent == PlaybackIntent.playing &&
            r.last.actual == PlaybackActual.playing,
        'ready host may continue active audio',
      );
      expectThat(
        r.engine.count('play') == count,
        'background transition is not a new Play',
      );
    }),
  );

  await tests.run(
    'Seek accepted does not fabricate position or rendered arrival',
    () => using((r) async {
      await r.open(video);
      final result = await r.command(const Seek(Duration(seconds: 3)));
      await settle();
      expectThat(
        result.accepted &&
            r.last.position == Duration.zero &&
            r.last.pendingSeek != null,
        'seek ack must remain pending',
      );
      final pending = r.last.pendingSeek!;
      r.emit(
        EngineSeekSettled(
          pending.token,
          requestId: pending.requestId,
          position: pending.target,
          frameReady: false,
        ),
      );
      expectThat(
        r.last.pendingSeek != null,
        'video position without frame is insufficient',
      );
      r.emit(
        EngineSeekSettled(
          pending.token,
          requestId: pending.requestId,
          position: pending.target,
          frameReady: true,
        ),
      );
      expectThat(
        r.last.pendingSeek == null &&
            r.last.position == const Duration(seconds: 3),
        'current settled frame confirms seek',
      );
    }),
  );

  await tests.run(
    'New seek ignores older receipt and coalesces same-turn targets',
    () => using((r) async {
      await r.open(video);
      final a = r.command(const Seek(Duration(seconds: 3)));
      final old = r.last.pendingSeek!;
      final b = r.command(const Seek(Duration(seconds: 9)));
      final latest = r.last.pendingSeek!;
      await Future.wait([a, b]);
      await settle();
      expectThat(
        r.engine.count('seek') == 1 &&
            r.engine.calls.lastWhere((c) => c.name == 'seek').position ==
                const Duration(seconds: 9),
        'same-turn seek commands merge to last target',
      );
      r.emit(
        EngineSeekSettled(
          old.token,
          requestId: old.requestId,
          position: old.target,
        ),
      );
      expectThat(
        r.last.pendingSeek?.requestId == latest.requestId &&
            r.last.position == Duration.zero,
        'old seek receipt cannot satisfy new request',
      );
      r.emit(
        EngineSeekSettled(
          latest.token,
          requestId: latest.requestId,
          position: latest.target,
          frameReady: true,
        ),
      );
      expectThat(
        r.last.pendingSeek == null && r.last.position == latest.target,
        'latest receipt confirms',
      );
    }),
  );

  await tests.run(
    'Seek validation and rate capability never pretend support',
    () => using((r) async {
      await r.open();
      expectThat(
        !(await r.command(const Seek(Duration(seconds: -1)))).accepted,
        'negative seek rejected',
      );
      expectThat(
        !(await r.command(const Seek(Duration(seconds: 13)))).accepted,
        'beyond-duration seek rejected',
      );
      expectThat(
        (await r.command(const SetRate(1.25))).status ==
            CommandStatus.unsupported,
        'unimplemented rate explicitly unsupported',
      );
    }),
  );

  await tests.run(
    'Engine failure is not cleared by ordinary foreground callback',
    () => using((r) async {
      await r.open();
      await r.play();
      r.emit(EngineFailure(r.token, 'synthetic failure'));
      final count = r.engine.count('play');
      r.send(ForegroundChanged(r.token, true));
      await settle();
      expectThat(
        r.last.actual == PlaybackActual.failed &&
            r.last.error != null &&
            r.last.requiresFreshPlay,
        'error remains observable',
      );
      expectThat(
        r.engine.count('play') == count,
        'lifecycle is not a retry command',
      );
    }),
  );

  await tests.run(
    'Process reconstruction with same material defaults paused',
    () async {
      await using((r) async {
        await r.open();
        await r.play();
      });
      await using((r) async {
        await r.open();
        await settle();
        expectThat(
          r.last.intent == PlaybackIntent.paused && r.last.requiresFreshPlay,
          'new controller does not restore old playing intent',
        );
        expectThat(
          r.engine.count('play') == 0,
          'no automatic engine Play after reconstruction',
        );
      });
    },
  );
  await tests.run(
    'Capability without ready host never permits background continuation',
    () => using((r) async {
      await r.open();
      await r.play();
      expectThat(!r.last.hostReady, 'new host defaults unconfirmed');
      r.send(ForegroundChanged(r.token, false));
      expectThat(
        r.last.intent == PlaybackIntent.paused && r.last.requiresFreshPlay,
        'capability alone cannot keep background audio playing',
      );
      expectThat(
        !(await r.command(const Play())).accepted,
        'background Play needs ready host',
      );
    }),
  );

  await tests.run(
    'Host loss pauses and readiness return requires new Play',
    () => using((r) async {
      await r.open();
      r.send(SystemHostChanged(r.token, true));
      await r.play();
      r.send(ForegroundChanged(r.token, false));
      final old = r.token;
      r.send(SystemHostChanged(old, false));
      final count = r.engine.count('play');
      r.emit(EngineStateChanged(old, PlaybackActual.playing));
      await settle();
      expectThat(
        r.last.intent == PlaybackIntent.paused &&
            !r.last.hostReady &&
            r.last.requiresFreshPlay,
        'missing host revokes intent and resume',
      );
      r.send(SystemHostChanged(r.token, true));
      await settle();
      expectThat(
        r.engine.count('play') == count,
        'new ready host cannot auto-replay',
      );
      expectThat(
        (await r.command(const Play())).accepted,
        'new explicit command may use ready host',
      );
    }),
  );

  await tests.run(
    'Capability revoked while background cannot silently resume later',
    () => using((r) async {
      await r.open();
      r.send(SystemHostChanged(r.token, true));
      await r.play();
      r.send(ForegroundChanged(r.token, false));
      r.send(
        CapabilitiesChanged(
          r.token,
          const PlaybackCapabilities(backgroundAudio: false),
        ),
      );
      final count = r.engine.count('play');
      expectThat(
        r.last.intent == PlaybackIntent.paused && r.last.requiresFreshPlay,
        'capability loss pauses',
      );
      r.send(
        CapabilitiesChanged(
          r.token,
          const PlaybackCapabilities(backgroundAudio: true),
        ),
      );
      await settle();
      expectThat(
        r.engine.count('play') == count,
        'capability restoration is not user intent',
      );
    }),
  );

  await tests.run(
    'Manual pause allows fresh Play after old focus hold clears',
    () => using((r) async {
      await r.open();
      await r.play();
      final t = r.token;
      r.send(FocusChanged(t, FocusState.transientLoss));
      await r.pause();
      r.send(FocusChanged(t, FocusState.gained));
      await settle();
      expectThat(
        (await r.command(const Play())).accepted,
        'stale restore privilege must clear its hold without deadlocking explicit Play',
      );
    }),
  );

  await tests.run(
    'Any interruption denial revokes whole multi-hold resume privilege',
    () => using((r) async {
      await r.open();
      await r.play();
      final t = r.token;
      final count = r.engine.count('play');
      r.send(FocusChanged(t, FocusState.transientLoss, holdId: 'a'));
      r.send(FocusChanged(t, FocusState.transientLoss, holdId: 'b'));
      r.send(FocusChanged(t, FocusState.gained, holdId: 'a', mayResume: false));
      r.send(FocusChanged(t, FocusState.gained, holdId: 'b'));
      await settle();
      expectThat(
        r.engine.count('play') == count,
        'a denied restore cannot be revived by another hold',
      );
    }),
  );

  await tests.run(
    'Background invalidates pending capture and asks owner to compensate',
    () => using((r) async {
      await r.open();
      final request = r.token;
      r.send(CaptureRequested(request, 'pending-camera'));
      final epoch = r.last.captureEpoch;
      r.send(ForegroundChanged(r.token, false));
      expectThat(
        r.last.captureEpoch > epoch && !r.last.foreground,
        'background synchronously revokes pending capture epoch',
      );
      expectThat(
        r.cleanups.any(
          (c) => c.resourceId == 'pending-camera' && c.requestToken == request,
        ),
        'original resource owner receives cleanup request',
      );
      r.send(
        CaptureResourceChanged(request, 'pending-camera', ResourceState.active),
      );
      await settle();
      expectThat(
        r.last.resources['pending-camera'] != ResourceState.closed,
        'requesting cleanup is not proof of closed hardware',
      );
      expectThat(
        !(await r.command(const Play())).accepted,
        'late active capture keeps Play blocked',
      );
    }),
  );

  await tests.run(
    'Late initialization after returning foreground is still invalid',
    () => using((r) async {
      await r.open();
      final request = r.token;
      r.send(CaptureRequested(request, 'late-preview'));
      r.send(ForegroundChanged(r.token, false));
      r.send(ForegroundChanged(r.token, true));
      final count = r.cleanups.length;
      r.send(
        CaptureResourceChanged(request, 'late-preview', ResourceState.active),
      );
      await settle();
      expectThat(
        r.cleanups.length > count,
        'expired initialize success needs compensation even after foreground return',
      );
      expectThat(
        r.last.resources['late-preview'] != ResourceState.active,
        'old capture must not become valid on foreground return',
      );
      expectThat(
        !(await r.command(const Play())).accepted,
        'compensation not yet confirmed keeps playback blocked',
      );
    }),
  );

  await tests.run(
    'Old capture closes after material switch without clearing fresh-Play latch',
    () => using((r) async {
      await r.open();
      final request = r.token;
      r.send(CaptureRequested(request, 'mic'));
      r.send(CaptureResourceChanged(request, 'mic', ResourceState.unknown));
      await r.open(other);
      final count = r.engine.count('play');
      r.send(CaptureResourceChanged(request, 'mic', ResourceState.closed));
      await settle();
      expectThat(
        r.last.resources['mic'] == ResourceState.closed &&
            r.last.requiresFreshPlay,
        'original owner may resolve resource after material switch',
      );
      expectThat(
        r.engine.count('play') == count,
        'cleanup never restores old Play',
      );
      expectThat(
        (await r.command(const Play())).accepted,
        'known closed resources permit new explicit Play',
      );
    }),
  );

  await tests.run(
    'Previous capture callback cannot overwrite reused resource id',
    () => using((r) async {
      await r.open();
      final old = r.token;
      r.send(CaptureRequested(old, 'mic'));
      r.send(CaptureResourceChanged(old, 'mic', ResourceState.closed));
      final current = r.token;
      r.send(CaptureRequested(current, 'mic'));
      r.send(CaptureResourceChanged(old, 'mic', ResourceState.closed));
      expectThat(
        r.last.resources['mic'] == ResourceState.starting,
        'old close must not release new pending capture',
      );
      expectThat(
        !(await r.command(const Play())).accepted,
        'new capture still blocks playback',
      );
    }),
  );

  await tests.run(
    'Delayed engine Open is compensated only for its own obsolete session',
    () => using((r) async {
      final gate = Completer<void>();
      r.engine.nextOpen = gate;
      final old = (await r.command(const Open(audio))).token;
      await r.open(other);
      await r.play();
      final current = r.token;
      final count = r.engine.calls
          .where((c) => c.name == 'stop' && c.token.sameSession(current))
          .length;
      gate.complete();
      r.emit(EngineStateChanged(old, PlaybackActual.playing));
      await settle();
      expectThat(
        r.last.token == current && r.last.intent == PlaybackIntent.playing,
        'old Open completion cannot stop new intent',
      );
      expectThat(
        r.engine.calls
                .where((c) => c.name == 'stop' && c.token.sameSession(current))
                .length ==
            count,
        'compensation never targets newer item',
      );
    }),
  );

  await tests.run(
    'Seek position application without video frame is partial evidence',
    () => using((r) async {
      await r.open(video);
      await r.command(const Seek(Duration(seconds: 3)));
      await settle();
      final pending = r.last.pendingSeek!;
      r.emit(
        EngineSeekSettled(
          pending.token,
          requestId: pending.requestId,
          position: pending.target,
          frameReady: false,
        ),
      );
      expectThat(
        r.last.seekPositionApplied &&
            !r.last.seekFrameReady &&
            r.last.pendingSeek != null,
        'position application must not impersonate rendered frame',
      );
    }),
  );

  await tests.run(
    'Unconfirmed seek times out explicitly rather than succeeding',
    () async {
      final r = Rig(seekTimeout: const Duration(milliseconds: 20));
      try {
        await r.open(video);
        final failure = r.playback.snapshots.firstWhere((s) => s.error != null);
        await r.command(const Seek(Duration(seconds: 3)));
        final snapshot = await failure;
        expectThat(
          !snapshot.seekFrameReady && snapshot.error != null,
          'missing frame produces observable incomplete result',
        );
        expectThat(
          snapshot.position == Duration.zero,
          'timeout must not jump to requested position',
        );
      } finally {
        await r.close();
      }
    },
  );

  await tests.run(
    'System suspension needs explicit Play after wake',
    () => using((r) async {
      await r.open();
      await r.play();
      r.send(SystemSuspended(r.token));
      final count = r.engine.count('play');
      r.send(ForegroundChanged(r.token, true));
      await settle();
      expectThat(
        r.last.requiresFreshPlay && r.engine.count('play') == count,
        'wake cannot auto-resume',
      );
      expectThat(
        (await r.command(const Play())).accepted,
        'explicit foreground Play can leave suspension',
      );
    }),
  );
  await tests.run(
    'Command epoch change revokes old interruption restore',
    () => using((r) async {
      await r.open();
      await r.play();
      final old = r.token;
      r.send(FocusChanged(old, FocusState.transientLoss));
      r.emit(EngineStateChanged(old, PlaybackActual.paused));
      await r.command(const Seek(Duration(seconds: 3)));
      final count = r.engine.count('play');
      r.send(FocusChanged(old, FocusState.gained));
      await settle();
      expectThat(
        r.engine.count('play') == count,
        'same material with changed command epoch cannot use old resume grant',
      );
      expectThat(
        (await r.command(const Play())).accepted,
        'cleared old hold still permits new explicit Play',
      );
    }),
  );

  await tests.run(
    'Every input resource must close, including cleanup unknown',
    () => using((r) async {
      await r.open();
      final mic = r.token;
      r.send(CaptureRequested(mic, 'mic'));
      final preview = r.token;
      r.send(CaptureRequested(preview, 'preview'));
      r.send(ForegroundChanged(r.token, false));
      r.send(ForegroundChanged(r.token, true));
      r.send(CaptureResourceChanged(mic, 'mic', ResourceState.closed));
      r.send(CaptureResourceChanged(preview, 'preview', ResourceState.unknown));
      expectThat(
        !(await r.command(const Play())).accepted,
        'one closed resource cannot erase another unknown cleanup',
      );
      expectThat(
        r.last.resources['preview'] == ResourceState.unknown &&
            r.last.requiresFreshPlay,
        'cleanup failure remains public and blocking',
      );
      r.send(CaptureResourceChanged(preview, 'preview', ResourceState.closed));
      expectThat(
        (await r.command(const Play())).accepted,
        'all real close receipts allow fresh explicit Play',
      );
    }),
  );

  await tests.run(
    'Failure of delayed old Play cannot poison a newer item',
    () => using((r) async {
      await r.open();
      final gate = Completer<void>();
      r.engine.nextPlay = gate;
      final old = (await r.command(const Play())).token;
      await r.open(other);
      await r.play();
      final current = r.token;
      gate.completeError(StateError('synthetic obsolete native failure'));
      await settle();
      expectThat(
        r.last.token == current &&
            r.last.error == null &&
            r.last.intent == PlaybackIntent.playing,
        'stale Future failure must not rewrite new item',
      );
      expectThat(
        r.engine.calls.any((c) => c.name == 'stop' && c.token == old),
        'failed old operation cleanup stays scoped',
      );
    }),
  );

  await tests.run(
    'Current Play failure is observable and never automatically retried',
    () => using((r) async {
      await r.open();
      final gate = Completer<void>();
      r.engine.nextPlay = gate;
      final result = await r.command(const Play());
      expectThat(result.accepted, 'submitted command is initially accepted');
      gate.completeError(StateError('synthetic adapter refusal'));
      await settle();
      expectThat(
        r.last.actual == PlaybackActual.failed &&
            r.last.intent == PlaybackIntent.paused &&
            r.last.requiresFreshPlay,
        'async failure must not remain fake playing',
      );
      final count = r.engine.count('play');
      r.send(ForegroundChanged(r.token, true));
      await settle();
      expectThat(
        r.engine.count('play') == count,
        'foreground cannot hide adapter failure with retry',
      );
    }),
  );

  await tests.run(
    'In-flight native Seek serializes and retains only newest waiting target',
    () => using((r) async {
      await r.open(video);
      final gate = Completer<void>();
      r.engine.nextSeek = gate;
      await r.command(const Seek(Duration(seconds: 3)));
      await settle();
      expectThat(r.engine.count('seek') == 1, 'first native seek has started');
      final old = r.last.pendingSeek!;
      await r.command(const Seek(Duration(seconds: 6)));
      await r.command(const Seek(Duration(seconds: 9)));
      await settle();
      expectThat(r.engine.count('seek') == 1, 'native seeks must not overlap');
      final latest = r.last.pendingSeek!;
      gate.complete();
      await settle();
      expectThat(
        r.engine.count('seek') == 2 &&
            r.engine.calls.lastWhere((c) => c.name == 'seek').position ==
                latest.target,
        'only latest queued seek is submitted',
      );
      r.emit(
        EngineSeekSettled(
          old.token,
          requestId: old.requestId,
          position: old.target,
          frameReady: true,
        ),
      );
      expectThat(
        r.last.pendingSeek?.requestId == latest.requestId &&
            !r.last.seekFrameReady,
        'obsolete rendered receipt cannot finish latest seek',
      );
      r.emit(
        EngineSeekSettled(
          latest.token,
          requestId: latest.requestId,
          position: latest.target,
          frameReady: true,
        ),
      );
      expectThat(
        r.last.pendingSeek == null && r.last.seekFrameReady,
        'latest frame receipt closes latest seek',
      );
    }),
  );

  await tests.run(
    'Old snapshot collections remain immutable across later events',
    () => using((r) async {
      await r.open();
      final before = r.last;
      var immutable = false;
      try {
        before.pauseCauses.add(PauseCause.capture);
      } on UnsupportedError {
        immutable = true;
      }
      expectThat(
        immutable,
        'public snapshot causes cannot be mutated by UI consumers',
      );
      final t = r.token;
      r.send(CaptureRequested(t, 'mic'));
      expectThat(
        before.resources.isEmpty &&
            !before.pauseCauses.contains(PauseCause.capture),
        'new events must not alter older snapshots',
      );
    }),
  );
  await tests.run(
    'Late Play acknowledgement under transient hold preserves loaded source',
    () => using((r) async {
      await r.open();
      final gate = Completer<void>();
      r.engine.nextPlay = gate;
      final t = (await r.command(const Play())).token;
      r.emit(EngineStateChanged(t, PlaybackActual.playing));
      r.send(FocusChanged(t, FocusState.transientLoss));
      r.emit(EngineStateChanged(t, PlaybackActual.paused));
      final stops = r.engine.calls
          .where((c) => c.name == 'stop' && c.token.sameSession(t))
          .length;
      gate.complete();
      await settle();
      expectThat(
        r.engine.calls
                .where((c) => c.name == 'stop' && c.token.sameSession(t))
                .length ==
            stops,
        'transient hold compensation cannot unload current media',
      );
      final plays = r.engine.count('play');
      r.send(FocusChanged(t, FocusState.gained));
      await settle();
      expectThat(
        r.engine.count('play') == plays + 1,
        'eligible focus return can still play loaded source',
      );
      r.emit(EngineStateChanged(r.token, PlaybackActual.playing));
      expectThat(
        r.last.actual == PlaybackActual.playing,
        'current observed recovery accepted',
      );
    }),
  );

  await tests.run(
    'Stop abandons old focus hold but requires new explicit Play',
    () => using((r) async {
      await r.open();
      await r.play();
      final old = r.token;
      r.send(FocusChanged(old, FocusState.transientLoss));
      final stopped = await r.command(const Stop());
      r.emit(EngineStateChanged(stopped.token, PlaybackActual.idle));
      expectThat(
        r.last.intent == PlaybackIntent.stopped &&
            r.last.actual == PlaybackActual.idle &&
            r.last.requiresFreshPlay,
        'Stop ends previous resume intent',
      );
      final count = r.engine.count('play');
      r.send(FocusChanged(old, FocusState.gained));
      await settle();
      expectThat(
        r.engine.count('play') == count,
        'late gain after Stop cannot resume',
      );
      expectThat(
        (await r.command(const Play())).accepted,
        'abandoned focus need not send gain before new explicit Play',
      );
    }),
  );

  await tests.run(
    'Host release observation preserves Stop epoch and idle acknowledgement',
    () => using((r) async {
      await r.open();
      r.send(SystemHostChanged(r.token, true));
      await r.play();
      final result = await r.command(const Stop());
      r.send(SystemHostChanged(result.token, false));
      r.emit(EngineStateChanged(result.token, PlaybackActual.idle));
      expectThat(
        r.last.token == result.token &&
            r.last.intent == PlaybackIntent.stopped &&
            r.last.actual == PlaybackActual.idle,
        'host release must not invalidate Stop acknowledgement',
      );
      expectThat(!r.last.hostReady, 'Stop releases background readiness');
    }),
  );

  await tests.run(
    'Stop preserves unsafe capture ledger while abandoning focus hold',
    () => using((r) async {
      await r.open();
      await r.play();
      final t = r.token;
      r.send(FocusChanged(t, FocusState.transientLoss));
      final capture = r.token;
      r.send(CaptureRequested(capture, 'mic'));
      r.send(CaptureResourceChanged(capture, 'mic', ResourceState.unknown));
      await r.command(const Stop());
      expectThat(
        r.last.resources['mic'] == ResourceState.unknown,
        'Stop cannot fake closing input',
      );
      expectThat(
        !(await r.command(const Play())).accepted,
        'Stop must not erase capture blocking',
      );
    }),
  );

  await tests.run(
    'Foreground not-ready observation permits host bootstrap from explicit Play',
    () => using((r) async {
      await r.open();
      final result = await r.command(const Play());
      r.send(SystemHostChanged(result.token, false));
      expectThat(
        r.last.token == result.token &&
            r.last.intent == PlaybackIntent.playing &&
            !r.last.requiresFreshPlay,
        'false-to-false foreground observation cannot veto requested bootstrap',
      );
      r.send(SystemHostChanged(result.token, true));
      r.emit(EngineStateChanged(result.token, PlaybackActual.playing));
      expectThat(
        r.last.hostReady && r.last.actual == PlaybackActual.playing,
        'real host can acknowledge same authorized start',
      );
    }),
  );

  await tests.run(
    'Stopped background session cannot reuse stale ready host',
    () => using((r) async {
      await r.open();
      r.send(SystemHostChanged(r.token, true));
      await r.play();
      r.send(ForegroundChanged(r.token, false));
      await r.command(const Stop());
      expectThat(
        !r.last.hostReady,
        'Stop synchronously invalidates host readiness before native release callback',
      );
      expectThat(
        !(await r.command(const Play())).accepted,
        'no background restart while release still pending',
      );
    }),
  );

  await tests.run(
    'Denied resume cannot be reacquired by a later transient interruption',
    () => using((r) async {
      await r.open();
      await r.play();
      final first = r.token;
      r.send(FocusChanged(first, FocusState.transientLoss));
      r.send(FocusChanged(first, FocusState.gained, mayResume: false));
      expectThat(
        r.last.intent == PlaybackIntent.paused && r.last.requiresFreshPlay,
        'denial explicitly requires new user intent',
      );
      final count = r.engine.count('play');
      final second = r.token;
      r.send(FocusChanged(second, FocusState.transientLoss, holdId: 'later'));
      r.send(FocusChanged(second, FocusState.gained, holdId: 'later'));
      await settle();
      expectThat(
        r.engine.count('play') == count,
        'later focus event cannot mint revoked resume grant',
      );
    }),
  );
  await tests.run(
    'Physical engine unknown survives material switch without fake actual',
    () => using((r) async {
      await r.open();
      await r.play();
      final origin = r.token;
      await r.open(other);
      final observed = r.last.actual;
      r.emit(EngineAvailabilityChanged(origin, sequence: 1, available: false));
      expectThat(
        !r.last.engineAvailable &&
            r.last.pauseCauses.contains(PauseCause.engineUnavailable),
        'global pipeline health is independent of item token',
      );
      expectThat(
        r.last.actual == observed,
        'unknown availability is not native pause confirmation',
      );
      expectThat(
        !(await r.command(const Play())).accepted,
        'new item cannot bypass physical engine unknown',
      );
      await r.command(const Open(audio));
      expectThat(
        !r.last.engineAvailable && !(await r.command(const Play())).accepted,
        'Open cannot clear physical health hold',
      );
    }),
  );

  await tests.run(
    'Older engine-ready sequence cannot clear newer unknown fact',
    () => using((r) async {
      await r.open();
      final origin = r.token;
      r.emit(EngineAvailabilityChanged(origin, sequence: 4, available: false));
      r.emit(EngineAvailabilityChanged(origin, sequence: 3, available: true));
      r.emit(EngineAvailabilityChanged(origin, sequence: 4, available: true));
      expectThat(
        !r.last.engineAvailable,
        'older or duplicate sequence cannot overwrite latest health',
      );
      expectThat(
        !(await r.command(const Play())).accepted,
        'stale ready never authorizes native work',
      );
    }),
  );

  await tests.run(
    'Confirmed engine recovery clears hold but never auto-plays',
    () => using((r) async {
      await r.open();
      await r.play();
      final origin = r.token;
      r.emit(EngineAvailabilityChanged(origin, sequence: 1, available: false));
      final count = r.engine.count('play');
      r.emit(EngineAvailabilityChanged(origin, sequence: 2, available: true));
      await settle();
      expectThat(
        r.last.engineAvailable &&
            r.last.requiresFreshPlay &&
            r.last.intent == PlaybackIntent.paused,
        'recovered engine still needs new Play',
      );
      expectThat(
        r.engine.count('play') == count,
        'ready health event must not restore old intent',
      );
      expectThat(
        (await r.command(const Play())).accepted,
        'fresh command may use confirmed recovered engine',
      );
    }),
  );

  await tests.run(
    'Engine recovery after Stop preserves stopped session',
    () => using((r) async {
      await r.open();
      await r.play();
      final origin = r.token;
      r.emit(EngineAvailabilityChanged(origin, sequence: 1, available: false));
      final stopped = (await r.command(const Stop())).token;
      r.emit(EngineStateChanged(stopped, PlaybackActual.idle));
      final count = r.engine.count('play');
      r.emit(EngineAvailabilityChanged(origin, sequence: 2, available: true));
      await settle();
      expectThat(
        r.last.intent == PlaybackIntent.stopped &&
            r.last.actual == PlaybackActual.idle &&
            r.last.requiresFreshPlay,
        'confirmed cleanup must not resurrect stopped session',
      );
      expectThat(
        r.engine.count('play') == count &&
            (await r.command(const Play())).accepted,
        'new explicit foreground Play alone can restart',
      );
    }),
  );
  await tests.run(
    'Focus gain retains original loss identity across user Pause',
    () => using((r) async {
      await r.open();
      await r.play();
      final origin = r.token;
      r.send(
        FocusChanged(origin, FocusState.transientLoss, holdId: 'os-focus'),
      );
      await r.pause();
      final current = r.token;
      final plays = r.engine.count('play');
      r.send(FocusChanged(current, FocusState.gained, holdId: 'os-focus'));
      await settle();
      expectThat(
        !(await r.command(const Play())).accepted,
        'retagged gain cannot clear interruption owned by original token',
      );
      r.send(FocusChanged(origin, FocusState.gained, holdId: 'os-focus'));
      await settle();
      expectThat(
        r.engine.count('play') == plays &&
            r.last.intent == PlaybackIntent.paused &&
            r.last.requiresFreshPlay,
        'original gain clears old hold without overriding user Pause',
      );
      expectThat(
        (await r.command(const Play())).accepted,
        'old hold release allows new explicit Play',
      );
    }),
  );

  await tests.run(
    'Reused focus hold id cannot be released by obsolete gain',
    () => using((r) async {
      await r.open();
      await r.play();
      final old = r.token;
      r.send(
        FocusChanged(old, FocusState.transientLoss, holdId: 'reused-focus'),
      );
      await r.pause();
      final latest = r.token;
      r.send(
        FocusChanged(latest, FocusState.transientLoss, holdId: 'reused-focus'),
      );
      final plays = r.engine.count('play');
      r.send(FocusChanged(old, FocusState.gained, holdId: 'reused-focus'));
      await settle();
      expectThat(
        !(await r.command(const Play())).accepted,
        'old gain cannot erase replacement hold with same id',
      );
      r.send(FocusChanged(latest, FocusState.gained, holdId: 'reused-focus'));
      await settle();
      expectThat(
        r.engine.count('play') == plays && r.last.requiresFreshPlay,
        'current hold release still cannot revive paused intent',
      );
      expectThat(
        (await r.command(const Play())).accepted,
        'matching current gain permits new explicit command',
      );
    }),
  );
  tests.finish();
}
