import 'dart:isolate';
import 'dart:typed_data';

import 'package:field_ops_copilot/services/audio/pcm_audio_format.dart';
import 'package:field_ops_copilot/services/audio/sherpa_recognizer.dart';
import 'package:field_ops_copilot/services/audio/stt_config.dart';
import 'package:field_ops_copilot/services/audio/stt_isolate_worker.dart';
import 'package:field_ops_copilot/services/audio/stt_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

const files = SttModelFiles(
  encoder: '/e.onnx',
  decoder: '/d.onnx',
  joiner: '/j.onnx',
  tokens: '/t.txt',
);

const config = SttConfig(files: files);

/// A [SttRecognizerRuntime] that records what it was fed and replays a script.
///
/// It is deliberately *not* a mock of sherpa's behaviour — that behaviour is
/// `SherpaRecognizerRuntime`'s to get right and the live test's to check. What
/// this stands in for is only the boundary the worker talks to, so the worker's
/// own rules (gap bridging, tail padding, ordering, failure scoping) can be
/// asserted without a native library.
class ScriptedRuntime implements SttRecognizerRuntime {
  ScriptedRuntime({
    this.onAccept,
    this.finalTranscripts = const [],
    this.failOnLoad = false,
    this.throwOnAccept,
  });

  /// Sample counts handed to [acceptSamples], in order.
  final List<int> accepted = [];

  /// The samples themselves, so a test can prove the silence really is silent.
  final List<Float32List> acceptedSamples = [];

  final List<String> calls = [];

  final List<SttRuntimeTranscript> Function(Float32List samples)? onAccept;
  final List<SttRuntimeTranscript> finalTranscripts;
  final bool failOnLoad;
  final Object? throwOnAccept;

  bool sessionOpen = false;
  bool closed = false;

  @override
  Future<SttReady> load(SttConfig config) async {
    calls.add('load');
    if (failOnLoad) throw StateError('scripted load failure');
    return SttReady(loadMillis: 1, sampleRate: config.format.sampleRate);
  }

  @override
  void beginSession() {
    calls.add('begin');
    sessionOpen = true;
  }

  @override
  List<SttRuntimeTranscript> acceptSamples(Float32List samples) {
    calls.add('accept');
    accepted.add(samples.length);
    acceptedSamples.add(samples);
    final failure = throwOnAccept;
    if (failure != null) throw failure;
    return onAccept?.call(samples) ?? const [];
  }

  @override
  List<SttRuntimeTranscript> finishSession() {
    calls.add('finish');
    sessionOpen = false;
    return finalTranscripts;
  }

  @override
  void cancelSession() {
    calls.add('cancel');
    sessionOpen = false;
  }

  @override
  Future<void> close() async {
    calls.add('close');
    closed = true;
  }
}

/// Drives [serveSttRequests] over a real [ReceivePort] pair, one request at a
/// time, exactly as the host does.
class WorkerHarness {
  WorkerHarness(SttRecognizerRuntime runtime)
    : _commands = ReceivePort('test.commands') {
    _served = serveSttRequests(commands: _commands, runtime: runtime);
    _sendPort = _commands.sendPort;
  }

  final ReceivePort _commands;
  late final SendPort _sendPort;
  late final Future<void> _served;

  /// Sends [request] and waits for its single reply.
  Future<SttReply> send(SttRequest request) async {
    final port = ReceivePort('test.reply');
    try {
      _sendPort.send([request.toWire(), port.sendPort]);
      final raw = await port.first;
      return SttReply.fromWire((raw as Map).cast<String, Object?>());
    } finally {
      port.close();
    }
  }

  /// Sends a raw message that never gets a reply, and lets the loop process it.
  void sendRaw(Object? message) => _sendPort.send(message);

  Future<void> get served => _served;
}

/// Bytes of 16-bit silence covering [duration] at 16 kHz mono.
Uint8List audioFor(Duration duration) =>
    Uint8List(PcmAudioFormat.sttMono16k.byteCountFor(duration));

int samplesFor(Duration duration) =>
    PcmAudioFormat.sttMono16k.byteCountFor(duration) ~/ 2;

void main() {
  group('load', () {
    test('answers with the runtime measurement', () async {
      final runtime = ScriptedRuntime();
      final harness = WorkerHarness(runtime);

      final reply = await harness.send(SttLoadRequest(config.toWire()));

      expect(reply, isA<SttReadyReply>());
      expect((reply as SttReadyReply).ready.sampleRate, 16000);
      await harness.send(const SttShutdownRequest());
      await harness.served;
    });

    test(
      'a load failure is reported as recognizer-lost, not as a crash',
      () async {
        // `on Object` in the worker is what makes this an answer rather than a dead
        // isolate. An `Error` out of the FFI layer is the realistic case, so the
        // scripted failure is a `StateError` rather than an `Exception`.
        final harness = WorkerHarness(ScriptedRuntime(failOnLoad: true));

        final reply = await harness.send(SttLoadRequest(config.toWire()));

        expect(reply, isA<SttFailureReply>());
        expect((reply as SttFailureReply).recognizerLost, isTrue);
        expect(reply.message, contains('scripted load failure'));
        await harness.send(const SttShutdownRequest());
        await harness.served;
      },
    );

    test(
      'an undecodable config is refused without killing the worker',
      () async {
        final harness = WorkerHarness(ScriptedRuntime());

        final reply = await harness.send(
          SttLoadRequest(const {'files': 'not a map'}),
        );
        expect(reply, isA<SttFailureReply>());

        // Still alive: the point of answering instead of throwing.
        final second = await harness.send(SttLoadRequest(config.toWire()));
        expect(second, isA<SttReadyReply>());
        await harness.send(const SttShutdownRequest());
        await harness.served;
      },
    );
  });

  group('audio', () {
    late ScriptedRuntime runtime;
    late WorkerHarness harness;

    Future<void> loadAndBegin() async {
      await harness.send(SttLoadRequest(config.toWire()));
      await harness.send(const SttBeginRequest());
    }

    tearDown(() async {
      await harness.send(const SttShutdownRequest());
      await harness.served;
    });

    test(
      'a chunk with no gap is forwarded once, unmodified in length',
      () async {
        runtime = ScriptedRuntime();
        harness = WorkerHarness(runtime);
        await loadAndBegin();

        await harness.send(
          SttAudioRequest(bytes: audioFor(const Duration(milliseconds: 100))),
        );

        expect(runtime.accepted, [
          samplesFor(const Duration(milliseconds: 100)),
        ]);
      },
    );

    test(
      'a gap is bridged with silence of its own duration, before the audio',
      () async {
        runtime = ScriptedRuntime();
        harness = WorkerHarness(runtime);
        await loadAndBegin();

        final gapBytes = PcmAudioFormat.sttMono16k.byteCountFor(
          const Duration(milliseconds: 500),
        );
        await harness.send(
          SttAudioRequest(
            bytes: audioFor(const Duration(milliseconds: 100)),
            precedingGapBytes: gapBytes,
          ),
        );

        // Two calls, and the silence is the *first* of them. Order is the property:
        // bridging after the audio would move the pause past the words it separated
        // and change where the endpointer splits them.
        expect(runtime.accepted, [
          samplesFor(const Duration(milliseconds: 500)),
          samplesFor(const Duration(milliseconds: 100)),
        ]);
        expect(
          runtime.acceptedSamples.first.every((s) => s == 0.0),
          isTrue,
          reason: 'the bridge has to be silence, not a repeat of the audio',
        );
      },
    );

    test('a gap longer than the cap is truncated to the cap', () async {
      runtime = ScriptedRuntime();
      harness = WorkerHarness(runtime);
      await loadAndBegin();

      await harness.send(
        SttAudioRequest(
          bytes: audioFor(const Duration(milliseconds: 100)),
          precedingGapBytes: PcmAudioFormat.sttMono16k.byteCountFor(
            const Duration(minutes: 1),
          ),
        ),
      );

      expect(runtime.accepted.first, samplesFor(config.maxGapBridge));
    });

    test('a zero gap adds no call at all', () async {
      // Not the same as "adds a zero-length call": an empty `acceptSamples` would
      // still be a native round trip on every chunk of every capture.
      runtime = ScriptedRuntime();
      harness = WorkerHarness(runtime);
      await loadAndBegin();

      await harness.send(
        SttAudioRequest(bytes: audioFor(const Duration(milliseconds: 100))),
      );

      expect(runtime.calls.where((c) => c == 'accept'), hasLength(1));
    });

    test('transcripts the chunk produced come back with it', () async {
      runtime = ScriptedRuntime(
        onAccept: (_) => const [
          SttRuntimeTranscript(text: 'E ONE', isFinal: false, segment: 0),
        ],
      );
      harness = WorkerHarness(runtime);
      await loadAndBegin();

      final reply =
          await harness.send(
                SttAudioRequest(
                  bytes: audioFor(const Duration(milliseconds: 100)),
                ),
              )
              as SttTranscriptsReply;

      expect(reply.transcripts.single.text, 'E ONE');
      expect(reply.transcripts.single.isFinal, isFalse);
    });

    test('audio before a load is refused by name', () async {
      runtime = ScriptedRuntime();
      harness = WorkerHarness(runtime);

      final reply = await harness.send(
        SttAudioRequest(bytes: audioFor(const Duration(milliseconds: 100))),
      );

      expect(reply, isA<SttFailureReply>());
      expect(
        (reply as SttFailureReply).message,
        contains('before the recognizer'),
      );
      // And nothing reached the runtime, which is the part that matters: the
      // format used to size the bridge does not exist yet.
      expect(runtime.calls, isEmpty);

      await harness.send(SttLoadRequest(config.toWire()));
    });

    test('a decode failure is session-scoped, not recognizer-lost', () async {
      // A chunk that failed says nothing about whether the model is still loaded,
      // and declaring it lost would cost a needless reload.
      runtime = ScriptedRuntime(throwOnAccept: StateError('bad chunk'));
      harness = WorkerHarness(runtime);
      await loadAndBegin();

      final reply =
          await harness.send(
                SttAudioRequest(
                  bytes: audioFor(const Duration(milliseconds: 100)),
                ),
              )
              as SttFailureReply;

      expect(reply.recognizerLost, isFalse);
      expect(reply.message, contains('bad chunk'));
    });

    test('an odd-length buffer is reported, not silently trimmed', () async {
      runtime = ScriptedRuntime();
      harness = WorkerHarness(runtime);
      await loadAndBegin();

      final reply =
          await harness.send(SttAudioRequest(bytes: Uint8List(3)))
              as SttFailureReply;

      expect(reply.message, contains('mid-sample'));
      expect(runtime.calls.contains('accept'), isFalse);
    });
  });

  group('finish', () {
    test(
      'pads before flushing, and the padding is the configured length',
      () async {
        // The order is the whole point. `inputFinished` stops the stream accepting
        // samples, so padding sent afterwards would be discarded — and the padding
        // is why the last word of an utterance survives at all.
        final runtime = ScriptedRuntime(
          finalTranscripts: const [
            SttRuntimeTranscript(
              text: 'E ONE OH TWO ERROR',
              isFinal: true,
              segment: 0,
            ),
          ],
        );
        final harness = WorkerHarness(runtime);
        await harness.send(SttLoadRequest(config.toWire()));
        await harness.send(const SttBeginRequest());

        final reply =
            await harness.send(const SttFinishRequest()) as SttTranscriptsReply;

        expect(runtime.calls, ['load', 'begin', 'accept', 'finish']);
        expect(runtime.accepted.single, samplesFor(config.tailPadding));
        expect(
          runtime.acceptedSamples.single.every((s) => s == 0.0),
          isTrue,
          reason: 'the tail padding has to be silence',
        );
        expect(reply.transcripts.single.text, 'E ONE OH TWO ERROR');

        await harness.send(const SttShutdownRequest());
        await harness.served;
      },
    );

    test(
      'transcripts the padding produced come before the flush results',
      () async {
        final runtime = ScriptedRuntime(
          onAccept: (_) => const [
            SttRuntimeTranscript(
              text: 'FROM PADDING',
              isFinal: false,
              segment: 0,
            ),
          ],
          finalTranscripts: const [
            SttRuntimeTranscript(text: 'FROM FLUSH', isFinal: true, segment: 0),
          ],
        );
        final harness = WorkerHarness(runtime);
        await harness.send(SttLoadRequest(config.toWire()));
        await harness.send(const SttBeginRequest());

        final reply =
            await harness.send(const SttFinishRequest()) as SttTranscriptsReply;

        expect(reply.transcripts.map((t) => t.text).toList(), [
          'FROM PADDING',
          'FROM FLUSH',
        ]);

        await harness.send(const SttShutdownRequest());
        await harness.served;
      },
    );

    test(
      'zero tail padding skips the call rather than sending nothing',
      () async {
        final runtime = ScriptedRuntime();
        final harness = WorkerHarness(runtime);
        await harness.send(
          SttLoadRequest(config.copyWith(tailPadding: Duration.zero).toWire()),
        );
        await harness.send(const SttBeginRequest());
        await harness.send(const SttFinishRequest());

        expect(runtime.calls, ['load', 'begin', 'finish']);

        await harness.send(const SttShutdownRequest());
        await harness.served;
      },
    );

    test('finish before a load is refused by name', () async {
      final runtime = ScriptedRuntime();
      final harness = WorkerHarness(runtime);

      final reply = await harness.send(const SttFinishRequest());

      expect(reply, isA<SttFailureReply>());
      expect(
        (reply as SttFailureReply).message,
        contains('before the recognizer'),
      );
      expect(runtime.calls, isEmpty);

      await harness.send(SttLoadRequest(config.toWire()));
      await harness.send(const SttShutdownRequest());
      await harness.served;
    });
  });

  group('lifecycle', () {
    test('cancel releases the session without flushing', () async {
      final runtime = ScriptedRuntime(
        finalTranscripts: const [
          SttRuntimeTranscript(text: 'NEVER', isFinal: true, segment: 0),
        ],
      );
      final harness = WorkerHarness(runtime);
      await harness.send(SttLoadRequest(config.toWire()));
      await harness.send(const SttBeginRequest());

      final reply = await harness.send(const SttCancelRequest());

      expect(reply, isA<SttAckReply>());
      expect(runtime.sessionOpen, isFalse);
      expect(
        runtime.calls.contains('finish'),
        isFalse,
        reason: 'cancelling must not produce a transcript the user abandoned',
      );

      await harness.send(const SttShutdownRequest());
      await harness.served;
    });

    test('a begin that the runtime refuses is answered, not thrown', () async {
      final runtime = ScriptedRuntime();
      final harness = WorkerHarness(runtime);
      await harness.send(SttLoadRequest(config.toWire()));
      await harness.send(const SttBeginRequest());

      // `SherpaRecognizerRuntime` throws on a second `beginSession`; the scripted
      // one does not, so this asserts the *worker's* guard rather than the
      // runtime's — using a runtime that does throw.
      final strict = _StrictBeginRuntime();
      final strictHarness = WorkerHarness(strict);
      await strictHarness.send(SttLoadRequest(config.toWire()));
      await strictHarness.send(const SttBeginRequest());
      final reply = await strictHarness.send(const SttBeginRequest());

      expect(reply, isA<SttFailureReply>());
      expect((reply as SttFailureReply).recognizerLost, isFalse);

      await harness.send(const SttShutdownRequest());
      await harness.served;
      await strictHarness.send(const SttShutdownRequest());
      await strictHarness.served;
    });

    test('shutdown cancels first, then closes, then returns', () async {
      final runtime = ScriptedRuntime();
      final harness = WorkerHarness(runtime);
      await harness.send(SttLoadRequest(config.toWire()));
      await harness.send(const SttBeginRequest());

      final reply = await harness.send(const SttShutdownRequest());

      expect(reply, isA<SttAckReply>());
      // Cancel before close: a live native stream while the recogniser under it is
      // destroyed is a crash rather than an exit.
      expect(runtime.calls.sublist(runtime.calls.length - 2), [
        'cancel',
        'close',
      ]);
      expect(runtime.closed, isTrue);
      // The loop returns, which is what frees the isolate's entry point.
      await harness.served;
    });

    test(
      'a cancel that throws during shutdown does not stop the close',
      () async {
        final runtime = _CancelThrowsRuntime();
        final harness = WorkerHarness(runtime);
        await harness.send(SttLoadRequest(config.toWire()));

        await harness.send(const SttShutdownRequest());
        await harness.served;

        expect(
          runtime.closed,
          isTrue,
          reason:
              'a runtime that cannot cancel still has to be released, or the '
              'native recognizer leaks for the life of the process',
        );
      },
    );
  });

  group('malformed commands', () {
    test('a non-list message is ignored and the loop survives', () async {
      final runtime = ScriptedRuntime();
      final harness = WorkerHarness(runtime)..sendRaw('hello');

      // The proof it survived: a real request after it still gets an answer.
      final reply = await harness.send(SttLoadRequest(config.toWire()));
      expect(reply, isA<SttReadyReply>());

      await harness.send(const SttShutdownRequest());
      await harness.served;
    });

    test(
      'an undecodable request map is ignored and the loop survives',
      () async {
        final runtime = ScriptedRuntime();
        final harness = WorkerHarness(runtime)
          ..sendRaw([
            {sttKindKey: 'nonsense'},
            null,
          ]);

        final reply = await harness.send(SttLoadRequest(config.toWire()));
        expect(reply, isA<SttReadyReply>());

        await harness.send(const SttShutdownRequest());
        await harness.served;
      },
    );

    test('a request with no reply port does not advance the runtime', () async {
      // Running the body with nobody to answer would move the recogniser's state
      // where no caller could observe it — worse than dropping the request.
      final runtime = ScriptedRuntime();
      final harness = WorkerHarness(runtime);
      await harness.send(SttLoadRequest(config.toWire()));

      harness.sendRaw([const SttBeginRequest().toWire(), null]);
      // Force the loop to process the portless message before the next one.
      await harness.send(const SttCancelRequest());

      expect(runtime.calls.contains('begin'), isFalse);

      await harness.send(const SttShutdownRequest());
      await harness.served;
    });
  });
}

class _StrictBeginRuntime extends ScriptedRuntime {
  bool _open = false;

  @override
  void beginSession() {
    if (_open) throw StateError('a recognition session is already open');
    _open = true;
    super.beginSession();
  }
}

class _CancelThrowsRuntime extends ScriptedRuntime {
  @override
  void cancelSession() => throw StateError('cancel exploded');
}
