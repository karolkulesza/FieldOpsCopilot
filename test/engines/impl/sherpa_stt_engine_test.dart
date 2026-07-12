import 'dart:async';
import 'dart:typed_data';

import 'package:field_ops_copilot/engines/impl/sherpa_stt_engine.dart';
import 'package:field_ops_copilot/services/audio/mic_frame.dart';
import 'package:field_ops_copilot/services/audio/stt_config.dart';
import 'package:field_ops_copilot/services/audio/stt_isolate_worker.dart';
import 'package:field_ops_copilot/services/audio/stt_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

const config = SttConfig(
  files: SttModelFiles(
    encoder: '/e.onnx',
    decoder: '/d.onnx',
    joiner: '/j.onnx',
    tokens: '/t.txt',
  ),
);

/// An [SttHost] that records the traffic and replays a script.
///
/// Stands in for the isolate, not for the recogniser: what is under test here is
/// the engine's own contract — ready states, one transcription at a time, session
/// release, disposal — which is app logic and should not need a native library.
class ScriptedHost implements SttHost {
  ScriptedHost({
    this.onAudio,
    this.finalTranscripts = const [],
    this.failStart,
    this.failBegin = false,
    this.failAudio = false,
  });

  final List<String> calls = [];
  final List<SttAudioRequest> audio = [];

  final List<SttTranscriptWire> Function(SttAudioRequest request)? onAudio;
  final List<SttTranscriptWire> finalTranscripts;
  final Object? failStart;
  final bool failBegin;
  final bool failAudio;

  /// Completes when [acceptAudio] is entered, and is awaited before it answers —
  /// the seam a back-pressure test needs.
  Completer<void>? gate;

  int started = 0;

  @override
  Future<SttReady> start(SttConfig config) async {
    calls.add('start');
    started++;
    final failure = failStart;
    if (failure != null) throw failure;
    return const SttReady(loadMillis: 12, sampleRate: 16000);
  }

  @override
  Future<void> beginSession() async {
    calls.add('begin');
    if (failBegin) throw const SttFailure('scripted begin failure');
  }

  @override
  Future<List<SttTranscriptWire>> acceptAudio(SttAudioRequest request) async {
    calls.add('audio');
    audio.add(request);
    if (gate != null) await gate!.future;
    if (failAudio) throw const SttFailure('scripted audio failure');
    return onAudio?.call(request) ?? const [];
  }

  @override
  Future<List<SttTranscriptWire>> finishSession() async {
    calls.add('finish');
    return finalTranscripts;
  }

  @override
  Future<void> cancelSession() async => calls.add('cancel');

  @override
  Future<void> shutdown() async => calls.add('shutdown');
}

MicFrame frame(int bytes, {int gap = 0}) =>
    MicFrame(bytes: Uint8List(bytes), precedingGapBytes: gap);

void main() {
  group('initialize', () {
    test('reports the load measurement and becomes ready', () async {
      final host = ScriptedHost();
      final engine = SherpaSttEngine(config: config, host: host);

      expect(engine.isReady, isFalse);
      await engine.initialize();

      expect(engine.isReady, isTrue);
      expect(engine.ready!.loadMillis, 12);
      expect(engine.ready!.sampleRate, 16000);
    });

    test('overlapping initialize calls share one load', () async {
      // Two loads would be two recognisers resident and a `load called twice` out
      // of the worker. The readiness banner and a "dictate" tap can both want the
      // engine at once, so this is a real race rather than a defensive one.
      final host = ScriptedHost();
      final engine = SherpaSttEngine(config: config, host: host);

      await Future.wait([engine.initialize(), engine.initialize()]);

      expect(host.started, 1);
    });

    test('a second initialize after success is a no-op', () async {
      final host = ScriptedHost();
      final engine = SherpaSttEngine(config: config, host: host);

      await engine.initialize();
      await engine.initialize();

      expect(host.started, 1);
    });

    test('a failed load leaves the engine retryable, not wedged', () async {
      // The in-flight future has to be cleared on failure as well as on success,
      // or every later attempt awaits a future that already threw.
      var fail = true;
      final host = _RetryableHost(() => fail);
      final engine = SherpaSttEngine(config: config, host: host);

      await expectLater(engine.initialize(), throwsA(isA<SttFailure>()));
      expect(engine.isReady, isFalse);

      fail = false;
      await engine.initialize();
      expect(engine.isReady, isTrue);
      expect(host.started, 2);
    });
  });

  group('transcribe', () {
    test('throws before initialize, at the call site', () {
      final engine = SherpaSttEngine(config: config, host: ScriptedHost());
      // Asserted without draining: the throw is synchronous, where the caller is.
      // Draining would pass either way and so would not notice it being deferred.
      expect(
        () => engine.transcribe(const Stream<MicFrame>.empty()),
        throwsStateError,
      );
    });

    test('forwards each frame once, carrying its gap', () async {
      final host = ScriptedHost();
      final engine = SherpaSttEngine(config: config, host: host);
      await engine.initialize();

      await engine
          .transcribe(
            Stream.fromIterable([frame(320), frame(320, gap: 640), frame(160)]),
          )
          .toList();

      expect(host.audio.map((r) => r.bytes.length).toList(), [320, 320, 160]);
      expect(host.audio.map((r) => r.precedingGapBytes).toList(), [0, 640, 0]);
    });

    test('closing the frame stream is what flushes', () async {
      final host = ScriptedHost(
        finalTranscripts: const [
          SttTranscriptWire(
            text: 'E ONE OH TWO ERROR',
            isFinal: true,
            segment: 0,
          ),
        ],
      );
      final engine = SherpaSttEngine(config: config, host: host);
      await engine.initialize();

      final results = await engine
          .transcribe(Stream.fromIterable([frame(320)]))
          .toList();

      expect(host.calls, ['start', 'begin', 'audio', 'finish']);
      expect(results.single.isFinal, isTrue);
    });

    test('a chunk is not sent until the previous one is answered', () async {
      // The back-pressure property, and the reason the protocol is
      // request/response at all: without it a decoder falling behind grows an
      // unbounded port queue instead of letting 2.1's bounded backlog drop oldest.
      final host = ScriptedHost()..gate = Completer<void>();
      final engine = SherpaSttEngine(config: config, host: host);
      await engine.initialize();

      final frames = StreamController<MicFrame>();
      final done = engine.transcribe(frames.stream).toList();

      frames
        ..add(frame(320))
        ..add(frame(320));
      await pumpEventQueue();

      expect(
        host.audio,
        hasLength(1),
        reason: 'the second frame must wait on the first reply',
      );

      host.gate!.complete();
      host.gate = null;
      await pumpEventQueue();
      expect(host.audio, hasLength(2));

      await frames.close();
      await done;
    });

    test(
      'transcripts are yielded in the order the host produced them',
      () async {
        final host = ScriptedHost(
          onAudio: (_) => const [
            SttTranscriptWire(text: 'E', isFinal: false, segment: 0),
            SttTranscriptWire(text: 'E ONE', isFinal: false, segment: 0),
          ],
          finalTranscripts: const [
            SttTranscriptWire(text: 'E ONE OH TWO', isFinal: true, segment: 0),
          ],
        );
        final engine = SherpaSttEngine(config: config, host: host);
        await engine.initialize();

        final results = await engine
            .transcribe(Stream.fromIterable([frame(320)]))
            .toList();

        expect(results.map((t) => t.rawText).toList(), [
          'E',
          'E ONE',
          'E ONE OH TWO',
        ]);
      },
    );

    test('the segment index survives to the caller', () async {
      final host = ScriptedHost(
        onAudio: (_) => const [
          SttTranscriptWire(text: 'FIRST', isFinal: true, segment: 0),
          SttTranscriptWire(text: 'SECOND', isFinal: false, segment: 1),
        ],
      );
      final engine = SherpaSttEngine(config: config, host: host);
      await engine.initialize();

      final results = await engine
          .transcribe(Stream.fromIterable([frame(320)]))
          .toList();

      expect(results.map((t) => t.segment).toList(), [0, 1]);
    });

    test('refuses a second concurrent transcription', () async {
      final host = ScriptedHost();
      final engine = SherpaSttEngine(config: config, host: host);
      await engine.initialize();

      final frames = StreamController<MicFrame>();
      final first = engine.transcribe(frames.stream);
      first.listen(null);
      await pumpEventQueue();

      expect(
        () => engine.transcribe(const Stream<MicFrame>.empty()),
        throwsStateError,
      );

      await frames.close();
    });

    test('a stream that is never listened to does not wedge the engine', () async {
      // **Review finding R0-F6.** The slot used to be taken synchronously in
      // `transcribe`, so a stream built and discarded held it forever: nothing leaked
      // on the worker — no session was ever opened — but the engine refused every
      // later transcription until it was disposed, recoverable only by rebuilding the
      // provider graph.
      final host = ScriptedHost();
      final engine = SherpaSttEngine(config: config, host: host);
      await engine.initialize();

      engine.transcribe(Stream.fromIterable([frame(320)]));
      await pumpEventQueue();

      // Nothing was begun, because nothing listened.
      expect(host.calls, ['start']);
      expect(
        () => engine.transcribe(const Stream<MicFrame>.empty()),
        returnsNormally,
      );
    });

    test('two streams built before either is listened to: the second errors', () async {
      // The case the synchronous refusal can no longer catch, now that the slot is
      // taken in `onListen`. It is reported on the stream rather than thrown, because
      // `onListen` has no caller to throw at — and it must be reported rather than
      // silently sharing a session, since the runtime holds one `OnlineStream`.
      final host = ScriptedHost();
      final engine = SherpaSttEngine(config: config, host: host);
      await engine.initialize();

      final first = engine.transcribe(StreamController<MicFrame>().stream);
      final second = engine.transcribe(const Stream<MicFrame>.empty());

      first.listen(null);
      await pumpEventQueue();

      await expectLater(second.toList(), throwsStateError);
    });

    test('a completed transcription releases the slot', () async {
      final host = ScriptedHost();
      final engine = SherpaSttEngine(config: config, host: host);
      await engine.initialize();

      await engine.transcribe(Stream.fromIterable([frame(320)])).toList();
      await engine.transcribe(Stream.fromIterable([frame(320)])).toList();

      expect(host.calls.where((c) => c == 'begin'), hasLength(2));
    });
  });

  group('normalisation', () {
    test('spoken digits are rewritten in text and kept in rawText', () async {
      final host = ScriptedHost(
        finalTranscripts: const [
          SttTranscriptWire(
            text: 'THE FALK CODE IS E ONE OH TWO PLEASE ADVISE',
            isFinal: true,
            segment: 0,
          ),
        ],
      );
      final engine = SherpaSttEngine(config: config, host: host);
      await engine.initialize();

      final result =
          (await engine.transcribe(Stream.fromIterable([frame(320)])).toList())
              .single;

      expect(result.text, 'THE FALK CODE IS E 102 PLEASE ADVISE');
      expect(result.rawText, 'THE FALK CODE IS E ONE OH TWO PLEASE ADVISE');
    });

    test('partials are normalised too, not only finals', () async {
      // Normalising only finals would make digits appear all at once at the end of
      // an utterance, which reads as the transcript being rewritten under the user.
      final host = ScriptedHost(
        onAudio: (_) => const [
          SttTranscriptWire(text: 'CODE E ONE OH', isFinal: false, segment: 0),
        ],
      );
      final engine = SherpaSttEngine(config: config, host: host);
      await engine.initialize();

      final result =
          (await engine.transcribe(Stream.fromIterable([frame(320)])).toList())
              .single;

      expect(result.isFinal, isFalse);
      expect(result.text, 'CODE E 10');
    });
  });

  group('the session is always released', () {
    test('when the consumer walks away mid-utterance', () async {
      // Without the cancel, a native `OnlineStream` stays open on the worker and
      // the next transcription is refused by "a recognition session is already
      // open" — the engine is unusable until it is disposed.
      final host = ScriptedHost()..gate = Completer<void>();
      final engine = SherpaSttEngine(config: config, host: host);
      await engine.initialize();

      final frames = StreamController<MicFrame>();
      final subscription = engine.transcribe(frames.stream).listen(null);
      frames.add(frame(320));
      await pumpEventQueue();

      host.gate!.complete();
      host.gate = null;
      await subscription.cancel();
      await pumpEventQueue();

      expect(host.calls, contains('cancel'));
      expect(host.calls.contains('finish'), isFalse);
    });

    test('when the frame stream errors', () async {
      final host = ScriptedHost();
      final engine = SherpaSttEngine(config: config, host: host);
      await engine.initialize();

      await expectLater(
        engine.transcribe(Stream.error(const SttFailure('mic died'))).toList(),
        throwsA(isA<SttFailure>()),
      );

      expect(host.calls, contains('cancel'));
      // And the slot is free again, which is the part a `finally` buys.
      expect(
        () => engine.transcribe(const Stream<MicFrame>.empty()),
        returnsNormally,
      );
    });

    test('when a chunk fails to decode', () async {
      final host = ScriptedHost(failAudio: true);
      final engine = SherpaSttEngine(config: config, host: host);
      await engine.initialize();

      await expectLater(
        engine.transcribe(Stream.fromIterable([frame(320)])).toList(),
        throwsA(isA<SttFailure>()),
      );

      expect(host.calls, contains('cancel'));
    });

    test('a begin that failed is not cancelled', () async {
      // Cancelling a session that was never opened would replace the real failure
      // with a second, less informative one — and on the real worker it would be
      // answered with "no recognition session is open".
      final host = ScriptedHost(failBegin: true);
      final engine = SherpaSttEngine(config: config, host: host);
      await engine.initialize();

      await expectLater(
        engine.transcribe(const Stream<MicFrame>.empty()).toList(),
        throwsA(isA<SttFailure>()),
      );

      expect(host.calls, ['start', 'begin']);
    });

    test(
      'a cancel that itself fails does not mask the original error',
      () async {
        final host = _CancelFailsHost();
        final engine = SherpaSttEngine(config: config, host: host);
        await engine.initialize();

        await expectLater(
          engine
              .transcribe(Stream.error(const SttFailure('mic died')))
              .toList(),
          throwsA(
            isA<SttFailure>().having((f) => f.message, 'message', 'mic died'),
          ),
        );
      },
    );
  });

  group('dispose', () {
    test('shuts the host down and refuses further use', () async {
      final host = ScriptedHost();
      final engine = SherpaSttEngine(config: config, host: host);
      await engine.initialize();

      await engine.dispose();

      expect(host.calls, contains('shutdown'));
      expect(engine.isReady, isFalse);
      expect(
        () => engine.transcribe(const Stream<MicFrame>.empty()),
        throwsStateError,
      );
      await expectLater(engine.initialize(), throwsStateError);
    });

    test('is idempotent', () async {
      final host = ScriptedHost();
      final engine = SherpaSttEngine(config: config, host: host);
      await engine.initialize();

      await engine.dispose();
      await engine.dispose();

      expect(host.calls.where((c) => c == 'shutdown'), hasLength(1));
    });

    test('a dispose racing a load still shuts the host down', () async {
      // Otherwise the worker finishes building a recogniser nobody will use and
      // holds it for the life of the process.
      final host = _SlowStartHost();
      final engine = SherpaSttEngine(config: config, host: host);

      final loading = engine.initialize();
      final disposing = engine.dispose();
      host.release.complete();

      await loading;
      await disposing;

      expect(host.calls, contains('shutdown'));
    });

    test('a dispose racing a *failing* load still shuts the host down', () async {
      // The `on Object` in `dispose`: a load whose result is now unwanted must not
      // turn a teardown into a thrown error.
      final host = _SlowStartHost(fail: true);
      final engine = SherpaSttEngine(config: config, host: host);

      final loading = engine.initialize();
      final disposing = engine.dispose();
      host.release.complete();

      await expectLater(loading, throwsA(isA<SttFailure>()));
      await expectLater(disposing, completes);
      expect(host.calls, contains('shutdown'));
    });
  });
}

class _RetryableHost extends ScriptedHost {
  _RetryableHost(this.shouldFail);

  final bool Function() shouldFail;

  @override
  Future<SttReady> start(SttConfig config) async {
    calls.add('start');
    started++;
    if (shouldFail()) throw const SttFailure('scripted load failure');
    return const SttReady(loadMillis: 1, sampleRate: 16000);
  }
}

class _CancelFailsHost extends ScriptedHost {
  @override
  Future<void> cancelSession() async {
    calls.add('cancel');
    throw const SttFailure('cancel also failed');
  }
}

class _SlowStartHost extends ScriptedHost {
  _SlowStartHost({this.fail = false});

  final bool fail;
  final Completer<void> release = Completer<void>();

  @override
  Future<SttReady> start(SttConfig config) async {
    calls.add('start');
    started++;
    await release.future;
    if (fail) throw const SttFailure('scripted load failure');
    return const SttReady(loadMillis: 1, sampleRate: 16000);
  }
}
