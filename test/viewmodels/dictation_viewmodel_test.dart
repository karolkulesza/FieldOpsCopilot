import 'dart:async';
import 'dart:typed_data';

import 'package:field_ops_copilot/engines/stt_engine.dart';
import 'package:field_ops_copilot/services/audio/mic_capture.dart';
import 'package:field_ops_copilot/services/audio/pcm_audio_format.dart';
import 'package:field_ops_copilot/services/audio/providers.dart';
import 'package:field_ops_copilot/viewmodels/dictation_viewmodel.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Task 2.3's voice half at the unit tier: the microphone and the recogniser,
/// already built and already tested, finally joined to something that shows words
/// on a screen.
///
/// Both seams are scripted here — a `_ScriptedAudioInput` in place of `record`, a
/// `_ScriptedSttEngine` in place of sherpa — because what this file is about is the
/// *composition*, and the two things underneath it have their own suites (78 tests
/// for the capture, 152 for the engine). What has never been tested before is that
/// a transcript reaches a consumer at all.
void main() {
  late _ScriptedAudioInput input;
  late _ScriptedSttEngine engine;

  setUp(() {
    input = _ScriptedAudioInput();
    engine = _ScriptedSttEngine();
  });

  /// A container with both device seams scripted. [sttEngine] is `null` by
  /// default only where a test asks for it.
  ProviderContainer container({SttEngine? Function()? stt}) {
    final c = ProviderContainer(
      overrides: [
        micCaptureProvider.overrideWith((ref) {
          final capture = MicCapture(input: input);
          ref.onDispose(capture.dispose);
          return capture;
        }),
        dictationEngineProvider.overrideWith(
          (ref) async => stt == null ? engine : stt(),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  DictationController controllerOf(ProviderContainer c) =>
      c.read(dictationControllerProvider.notifier);
  DictationState stateOf(ProviderContainer c) =>
      c.read(dictationControllerProvider);

  group('a capture that cannot start', () {
    test('no verified weights is unavailable, not a failure', () async {
      final c = container(stt: () => null);

      await controllerOf(c).start();

      expect(stateOf(c).phase, DictationPhase.unavailable);
      expect(stateOf(c).message, contains('No verified speech model'));
      expect(
        input.startStreamCalls,
        0,
        reason: 'the microphone must not open with nothing to transcribe',
      );
    });

    test('a denied permission is unavailable, and names Settings', () async {
      input.permission = false;
      final c = container();

      await controllerOf(c).start();

      expect(stateOf(c).phase, DictationPhase.unavailable);
      expect(stateOf(c).message, contains('Settings'));
      expect(input.startStreamCalls, 0);
    });

    test('a microphone that will not open is unavailable', () async {
      input.startError = Exception('no input route');
      final c = container();

      await controllerOf(c).start();

      expect(stateOf(c).phase, DictationPhase.unavailable);
      expect(stateOf(c).message, contains('no input route'));
    });

    test('a model that will not load is unavailable', () async {
      engine.initializeError = Exception('encoder-epoch-99: no such file');
      final c = container();

      await controllerOf(c).start();

      expect(stateOf(c).phase, DictationPhase.unavailable);
      expect(stateOf(c).message, contains('no such file'));
      expect(input.startStreamCalls, 0);
    });

    test('nothing has been transcribed in any of those states', () async {
      final c = container(stt: () => null);
      await controllerOf(c).start();

      expect(stateOf(c).text, '');
      expect(stateOf(c).isEmpty, isTrue);
    });
  });

  group('a live dictation', () {
    test('starting opens the microphone and loads the model', () async {
      final c = container();

      await controllerOf(c).start();

      expect(stateOf(c).phase, DictationPhase.listening);
      expect(engine.initializeCalls, 1);
      expect(input.startStreamCalls, 1);
      expect(input.requestedFormat, PcmAudioFormat.sttMono16k);
    });

    test('a partial shows immediately and is replaced by the next', () async {
      final c = container();
      await controllerOf(c).start();

      await engine.push(const SttTranscript('THE CABIN IS'));
      expect(stateOf(c).text, 'THE CABIN IS');

      await engine.push(const SttTranscript('THE CABIN IS VIBRATING'));
      expect(
        stateOf(c).text,
        'THE CABIN IS VIBRATING',
        reason: 'a partial is a better guess at the same words, not a new line',
      );
    });

    test('a final commits its utterance and clears the partial', () async {
      final c = container();
      await controllerOf(c).start();

      await engine.push(const SttTranscript('THE CABIN IS VIBRATING'));
      await engine.push(
        const SttTranscript('THE CABIN IS VIBRATING', isFinal: true),
      );

      expect(stateOf(c).committed, ['THE CABIN IS VIBRATING']);
      expect(stateOf(c).partial, '');
      expect(stateOf(c).text, 'THE CABIN IS VIBRATING');
    });

    // What `SttTranscript.segment` exists for, and the reason `text` joins with a
    // space: two utterances concatenated raw give `VIBRATINGTHE`, which reaches
    // the router's full-text query as a word that is in no manual.
    test(
      'a second utterance is a second segment, joined with a space',
      () async {
        final c = container();
        await controllerOf(c).start();

        await engine.push(
          const SttTranscript('THE CABIN IS VIBRATING', isFinal: true),
        );
        await engine.push(
          const SttTranscript(
            'THE FAULT CODE IS E 102',
            isFinal: true,
            segment: 1,
          ),
        );

        expect(
          stateOf(c).text,
          'THE CABIN IS VIBRATING THE FAULT CODE IS E 102',
        );
      },
    );

    test('a partial trails the committed utterances', () async {
      final c = container();
      await controllerOf(c).start();

      await engine.push(
        const SttTranscript('THE CABIN IS VIBRATING', isFinal: true),
      );
      await engine.push(const SttTranscript('THE FAULT', segment: 1));

      expect(stateOf(c).text, 'THE CABIN IS VIBRATING THE FAULT');
    });

    // A streaming recogniser is entitled to re-emit a final for a segment it has
    // already closed. Appending would then say the sentence twice.
    test(
      'a re-emitted final replaces its segment rather than appending',
      () async {
        final c = container();
        await controllerOf(c).start();

        await engine.push(
          const SttTranscript('THE CABIN IS VIBRATING', isFinal: true),
        );
        await engine.push(
          const SttTranscript('THE CABIN IS VIBRATING BADLY', isFinal: true),
        );

        expect(stateOf(c).committed, ['THE CABIN IS VIBRATING BADLY']);
        expect(stateOf(c).text, 'THE CABIN IS VIBRATING BADLY');
      },
    );

    // A recogniser that opens at segment 1 (the first utterance endpointed out of
    // an empty leading segment) must not produce a leading space or a crash.
    test('a segment gap does not leave a blank in the line', () async {
      final c = container();
      await controllerOf(c).start();

      await engine.push(
        const SttTranscript('E 102', isFinal: true, segment: 2),
      );

      expect(stateOf(c).committed, ['', '', 'E 102']);
      expect(stateOf(c).text, 'E 102');
    });

    test('a second start while listening is refused, not restarted', () async {
      final c = container();
      await controllerOf(c).start();

      await controllerOf(c).start();

      expect(input.startStreamCalls, 1);
      expect(stateOf(c).phase, DictationPhase.listening);
    });
  });

  group('ending a dictation', () {
    test('stop closes the microphone and keeps what was said', () async {
      final c = container();
      await controllerOf(c).start();
      await engine.push(
        const SttTranscript('THE CABIN IS VIBRATING', isFinal: true),
      );

      await controllerOf(c).stop();

      expect(input.stopCalls, greaterThanOrEqualTo(1));
      expect(stateOf(c).phase, DictationPhase.idle);
      expect(stateOf(c).text, 'THE CABIN IS VIBRATING');
    });

    // The reason `stop` awaits the transcript stream and not only the session: a
    // streaming zipformer will not emit its last words until the input closes
    // (Task 2.2's tail padding), so returning at the session's stop hands a caller
    // a state one utterance short of what was said.
    test('stop waits for the final transcript the flush produces', () async {
      final c = container();
      await controllerOf(c).start();
      engine.emitOnFinish(
        const SttTranscript(
          'THE CABIN IS VIBRATING PLEASE ADVISE',
          isFinal: true,
        ),
      );

      await controllerOf(c).stop();

      expect(stateOf(c).text, 'THE CABIN IS VIBRATING PLEASE ADVISE');
    });

    test('stop with nothing running is a no-op', () async {
      final c = container();

      await controllerOf(c).stop();

      expect(stateOf(c).phase, DictationPhase.idle);
      expect(input.stopCalls, 0);
    });

    test('a capture can be started again after stopping', () async {
      final c = container();
      await controllerOf(c).start();
      await controllerOf(c).stop();

      await controllerOf(c).start();

      expect(stateOf(c).phase, DictationPhase.listening);
      expect(input.startStreamCalls, 2);
    });

    test('starting again clears the previous line', () async {
      final c = container();
      await controllerOf(c).start();
      await engine.push(
        const SttTranscript('THE CABIN IS VIBRATING', isFinal: true),
      );
      await controllerOf(c).stop();

      await controllerOf(c).start();

      expect(
        stateOf(c).text,
        '',
        reason:
            'the screen keeps the old words in the inquiry field; keeping them '
            'here too would append them to themselves',
      );
    });

    test('clear empties the line but is refused mid-capture', () async {
      final c = container();
      await controllerOf(c).start();
      await engine.push(
        const SttTranscript('THE CABIN IS VIBRATING', isFinal: true),
      );

      controllerOf(c).clear();
      expect(stateOf(c).text, 'THE CABIN IS VIBRATING');

      await controllerOf(c).stop();
      controllerOf(c).clear();
      expect(stateOf(c).text, '');
      expect(stateOf(c).phase, DictationPhase.idle);
    });
  });

  group('a capture that goes wrong', () {
    test('a microphone fault fails the dictation and quotes it', () async {
      final c = container();
      await controllerOf(c).start();
      await engine.push(
        const SttTranscript('THE CABIN IS VIBRATING', isFinal: true),
      );
      await engine.push(const SttTranscript('AND THE'));

      await engine.crash(
        const MicCaptureFault('the microphone delivered no audio'),
      );
      await pumpEventQueue();

      expect(stateOf(c).phase, DictationPhase.failed);
      expect(stateOf(c).message, 'the microphone delivered no audio');
      // The finals survive and the partial does not: a partial is a guess at an
      // utterance that was never finished being heard.
      expect(stateOf(c).text, 'THE CABIN IS VIBRATING');
    });

    test('a fault releases the microphone', () async {
      final c = container();
      await controllerOf(c).start();

      await engine.crash(const MicCaptureFault('gone'));
      await pumpEventQueue();

      expect(input.stopCalls, greaterThanOrEqualTo(1));
    });

    test('a dictation can be restarted after a fault', () async {
      final c = container();
      await controllerOf(c).start();
      await engine.crash(const MicCaptureFault('gone'));
      await pumpEventQueue();

      await controllerOf(c).start();

      expect(stateOf(c).phase, DictationPhase.listening);
    });
  });

  group('teardown', () {
    // A container disposed mid-capture must not leave the input open with nobody
    // reading it — the failure is a microphone that stays live after the screen
    // is gone, which no test of either seam alone can see.
    test('disposing the graph stops the microphone', () async {
      final c = ProviderContainer(
        overrides: [
          micCaptureProvider.overrideWith((ref) {
            final capture = MicCapture(input: input);
            ref.onDispose(capture.dispose);
            return capture;
          }),
          dictationEngineProvider.overrideWith((ref) async => engine),
        ],
      );
      await c.read(dictationControllerProvider.notifier).start();
      expect(input.startStreamCalls, 1);

      c.dispose();
      await pumpEventQueue();

      expect(input.stopCalls, greaterThanOrEqualTo(1));
    });
  });

  group('DictationState', () {
    test('an empty state has no text', () {
      const state = DictationState();
      expect(state.text, '');
      expect(state.isEmpty, isTrue);
      expect(state.isActive, isFalse);
    });

    test('blank utterances and partials contribute nothing', () {
      const state = DictationState(
        committed: ['', '  ', 'E 102'],
        partial: '   ',
      );
      expect(state.text, 'E 102');
    });

    test('starting and listening are both active', () {
      for (final phase in const [
        DictationPhase.starting,
        DictationPhase.listening,
      ]) {
        expect(DictationState(phase: phase).isActive, isTrue, reason: '$phase');
      }
      for (final phase in const [
        DictationPhase.idle,
        DictationPhase.unavailable,
        DictationPhase.failed,
      ]) {
        expect(
          DictationState(phase: phase).isActive,
          isFalse,
          reason: '$phase',
        );
      }
    });
  });
}

/// An [SttEngine] a test pushes transcripts through.
///
/// It consumes the frame stream the way `SherpaSttEngine` does — subscribing, and
/// flushing on close — because the controller's `stop()` depends on that ordering:
/// the final transcript arrives *after* the frames end.
class _ScriptedSttEngine implements SttEngine {
  /// One controller per [transcribe], as `SherpaSttEngine._transcribe` builds
  /// one per call. Sharing a single controller across captures would make the
  /// engine single-use, which is a permissiveness in the *opposite* direction to
  /// the one that matters — it would fail restarts the real engine allows.
  StreamController<SttTranscript>? _out;
  StreamSubscription<MicFrame>? _frames;
  SttTranscript? _onFinish;

  Object? initializeError;
  int initializeCalls = 0;
  bool _ready = false;

  @override
  bool get isReady => _ready;

  @override
  Future<void> initialize() async {
    initializeCalls++;
    final error = initializeError;
    if (error != null) throw error;
    _ready = true;
  }

  /// Queues a transcript to emit when the frame stream closes — the flush a real
  /// recogniser performs on `inputFinished()`.
  void emitOnFinish(SttTranscript transcript) => _onFinish = transcript;

  void emit(SttTranscript transcript) {
    final out = _out;
    if (out != null && !out.isClosed) out.add(transcript);
  }

  /// [emit], then let the stream deliver it. Every assertion in this file is
  /// about state the controller sets from a stream callback, so a bare `add`
  /// asserts against the frame before the one it is about.
  Future<void> push(SttTranscript transcript) async {
    emit(transcript);
    await pumpEventQueue();
  }

  void fail(Object error) {
    final out = _out;
    if (out != null && !out.isClosed) {
      out.addError(error);
      out.close();
    }
  }

  /// [fail], then let it be delivered.
  Future<void> crash(Object error) async {
    fail(error);
    await pumpEventQueue();
  }

  @override
  Stream<SttTranscript> transcribe(Stream<MicFrame> frames) {
    final out = StreamController<SttTranscript>();
    _out = out;
    _frames = frames.listen(
      (_) {},
      onError: fail,
      onDone: () {
        final last = _onFinish;
        _onFinish = null;
        if (last != null) emit(last);
        if (!out.isClosed) out.close();
      },
    );
    return out.stream;
  }

  @override
  Future<void> dispose() async {
    await _frames?.cancel();
    final out = _out;
    if (out != null && !out.isClosed) await out.close();
  }
}

/// The same shape `mic_capture_test.dart` uses, trimmed to what this file drives.
class _ScriptedAudioInput implements AudioInput {
  bool permission = true;
  Object? startError;

  int startStreamCalls = 0;
  int stopCalls = 0;
  PcmAudioFormat? requestedFormat;

  /// One controller per capture, as `record` gives one stream per `startStream`,
  /// and closed by [stop] — which is what makes `MicCaptureSession.stop` prompt
  /// rather than paying the full 250ms drain grace on every utterance.
  StreamController<Uint8List>? _raw;

  @override
  Future<bool> hasPermission({bool request = true}) async => permission;

  @override
  Future<Stream<Uint8List>> startStream(PcmAudioFormat format) async {
    final error = startError;
    if (error != null) throw error;
    startStreamCalls++;
    requestedFormat = format;
    final raw = StreamController<Uint8List>.broadcast();
    _raw = raw;
    return raw.stream;
  }

  @override
  Future<void> watchFormat(void Function(String description) onCoerced) async {}

  @override
  Future<void> stop() async {
    stopCalls++;
    final raw = _raw;
    _raw = null;
    if (raw != null && !raw.isClosed) await raw.close();
  }

  @override
  Future<void> dispose() async {
    await stop();
  }
}
