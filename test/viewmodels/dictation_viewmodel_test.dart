import 'dart:async';
import 'dart:typed_data';

import 'package:field_ops_copilot/engines/stt_engine.dart';
import 'package:field_ops_copilot/services/audio/mic_capture.dart';
import 'package:field_ops_copilot/services/audio/pcm_audio_format.dart';
import 'package:field_ops_copilot/services/audio/providers.dart';
import 'package:field_ops_copilot/viewmodels/dictation_viewmodel.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The voice half of dictation at the unit tier: the microphone and the
/// recogniser, already built and already tested, finally joined to something
/// that shows words on a screen.
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

  /// Starts a capture and lets one frame arrive, which is what a real microphone
  /// does the moment it is open.
  ///
  /// **`DictationPhase.listening` now means "audio is arriving"** rather than "the
  /// input was asked for" — the demo device takes 1227ms to open one, and a
  /// technician talking over that window loses the start of their sentence. So a
  /// scripted input that never delivers a frame can no longer reach `listening`,
  /// and that is right: neither can a real microphone that never delivers one.
  Future<void> startListening(ProviderContainer c) async {
    await controllerOf(c).start();
    input.emit(List<int>.filled(320, 1));
    await pumpEventQueue();
  }

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

    test('a model that will not load is unavailable, and frees the mic', () async {
      engine.initializeError = Exception('encoder-epoch-99: no such file');
      final c = container();

      await controllerOf(c).start();

      expect(stateOf(c).phase, DictationPhase.unavailable);
      expect(stateOf(c).message, contains('no such file'));
      // **This assertion is inverted from what it was, deliberately.** It used to
      // read `startStreamCalls == 0`, which was true only because the microphone
      // opened *after* the load — the ordering that cost a technician the first
      // word of every session. The mic now opens first, so the property worth
      // holding is not that it stayed shut but that a failed load **gives it
      // back**: an input left live with nothing reading it is the one outcome here
      // that costs something real.
      expect(input.startStreamCalls, 1);
      expect(input.stopCalls, greaterThanOrEqualTo(1));
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

      await startListening(c);

      expect(stateOf(c).phase, DictationPhase.listening);
      expect(engine.initializeCalls, 1);
      expect(input.startStreamCalls, 1);
      expect(input.requestedFormat, PcmAudioFormat.sttMono16k);
    });

    test('a partial shows immediately and is replaced by the next', () async {
      final c = container();
      await startListening(c);

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
      await startListening(c);

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
      await startListening(c);

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
      await startListening(c);

      await engine.push(
        const SttTranscript('E 102', isFinal: true, segment: 2),
      );

      expect(stateOf(c).committed, ['', '', 'E 102']);
      expect(stateOf(c).text, 'E 102');
    });

    test('a second start while listening is refused, not restarted', () async {
      final c = container();
      await startListening(c);

      await controllerOf(c).start();

      expect(input.startStreamCalls, 1);
      expect(stateOf(c).phase, DictationPhase.listening);
    });
  });

  // Typing stops the capture, and that half never fired during
  // `DictationPhase.starting`: `stop()` returned at its first line while
  // `_session` was null, and `_session` is assigned only at the *end* of
  // `start()`. The window is the recogniser load — 359–530ms, measured on the
  // demo device — which is exactly when a technician who tapped the mic by
  // accident reaches for the keyboard.
  group('a stop during the load', () {
    /// Holds `initialize()` open so the whole test sits in `starting`.
    Completer<void> gateTheLoad() {
      final gate = Completer<void>();
      engine.initializeGate = gate;
      return gate;
    }

    test('releases the microphone the start had already opened', () async {
      final c = container();
      final gate = gateTheLoad();

      unawaited(controllerOf(c).start());
      await pumpEventQueue();
      expect(stateOf(c).phase, DictationPhase.starting);
      // The microphone is *already open* here, and that is the point of the
      // ordering rather than a leak — see the capture-during-the-load group below.
      expect(input.startStreamCalls, 1);

      await controllerOf(c).stop();
      gate.complete();
      await pumpEventQueue();

      expect(
        stateOf(c).phase,
        DictationPhase.idle,
        reason: 'a cancelled start must not leave the UI saying "starting"',
      );
      expect(
        input.stopCalls,
        greaterThanOrEqualTo(1),
        reason:
            'the input was open before the stop landed, so the stop has to hand '
            'it back rather than only bump the generation',
      );
    });

    test('a start after the cancelled one still works', () async {
      final c = container();
      final gate = gateTheLoad();
      unawaited(controllerOf(c).start());
      await pumpEventQueue();
      await controllerOf(c).stop();
      gate.complete();
      await pumpEventQueue();

      engine.initializeGate = null;
      await startListening(c);

      expect(stateOf(c).phase, DictationPhase.listening);
      // Two, not one: the cancelled start opened the input and gave it back, and
      // this one opened it again. Counting them is what shows the first was
      // genuinely released rather than reused.
      expect(input.startStreamCalls, 2);
      expect(input.stopCalls, greaterThanOrEqualTo(1));
    });

    // **The defect this ordering exists to fix, reported from the demo iPad:
    // "cabin vibrating" came back as "IN VIBRATING".** The microphone used to
    // open *after* `initialize()`, so the 359–530ms of ONNX loading (measured
    // on that device) happened with no input open — and every word
    // spoken in that window was never recorded. The second utterance of a session
    // was always clean, because `initialize()` returns immediately once ready,
    // which is exactly the asymmetry the report described.
    //
    // Asserted on the *bytes*, not on a transcript: the double does not
    // transcribe, and what was in question was never recognition.
    test(
      'audio spoken while the model loads still reaches the recogniser',
      () async {
        final c = container();
        final gate = gateTheLoad();

        unawaited(controllerOf(c).start());
        await pumpEventQueue();

        // The input is open before the recogniser is — that is the fix.
        expect(stateOf(c).phase, DictationPhase.starting);
        expect(
          input.startStreamCalls,
          1,
          reason: 'the microphone must already be capturing during the load',
        );

        // "CAB" — the syllable the demo device lost.
        input.emit(List<int>.filled(320, 7));
        await pumpEventQueue();

        gate.complete();
        await pumpEventQueue();

        expect(stateOf(c).phase, DictationPhase.listening);
        final bytes = engine.receivedFrames.fold<int>(
          0,
          (total, frame) => total + frame.bytes.length,
        );
        expect(
          bytes,
          320,
          reason:
              'the capture backlog built for this must replay what was captured '
              'before the recogniser attached',
        );
        expect(
          engine.receivedFrames.first.precedingGapBytes,
          0,
          reason:
              'and nothing may be dropped on the way — a gap here is lost audio',
        );
      },
    );

    test(
      'audio after the load arrives too, so the join is not one-shot',
      () async {
        final c = container();
        final gate = gateTheLoad();
        unawaited(controllerOf(c).start());
        await pumpEventQueue();
        input.emit(List<int>.filled(320, 7));
        gate.complete();
        await pumpEventQueue();

        input.emit(List<int>.filled(160, 9));
        await pumpEventQueue();

        final bytes = engine.receivedFrames.fold<int>(
          0,
          (total, frame) => total + frame.bytes.length,
        );
        expect(bytes, 480);
      },
    );

    // **The device measurement that made `listening` mean something.** On the demo
    // iPad `MicCapture.start()` takes **1227ms** to return and the recogniser load
    // after it is 458ms — so for over a second after the tap there is no input at
    // all, and a technician who starts talking loses the front of the sentence.
    // That is what survived the first fix: moving the microphone ahead of the
    // model load recovered 458ms of a 1685ms gap and the report did not change.
    test('the phase says listening only once audio is arriving', () async {
      final c = container();

      await controllerOf(c).start();

      // The whole start chain has completed — engine resolved, input open,
      // recogniser loaded, stream attached — and it is still not listening,
      // because nothing has been heard.
      expect(input.startStreamCalls, 1);
      expect(
        stateOf(c).phase,
        DictationPhase.starting,
        reason:
            'attaching is not hearing; claiming otherwise is what invites a '
            'technician to talk into an input that is not delivering yet',
      );

      input.emit(List<int>.filled(320, 1));
      await pumpEventQueue();

      expect(stateOf(c).phase, DictationPhase.listening);
    });

    // **A crash the doubles had been hiding.** Every `emit` above now arrives at
    // an odd `offsetInBytes`, as the device's frames did; this is the one test
    // that says so out loud, so the next person to reach for an `Int16List` view
    // on this path finds the reason rather than just a red bar.
    test('a frame at an odd offset is audio, not a crash', () async {
      final c = container();
      await controllerOf(c).start();

      final frame = _ScriptedAudioInput.platformBufferFor(
        List<int>.filled(320, 7),
      );
      expect(
        frame.offsetInBytes.isOdd,
        isTrue,
        reason: 'the property under test is the misalignment itself',
      );

      input.emit(List<int>.filled(320, 7));
      await pumpEventQueue();

      expect(
        stateOf(c).phase,
        DictationPhase.listening,
        reason:
            'reading the frame must not throw — a RangeError here reached the '
            'frame handler and stopped dictation on the first frame of every '
            'session, under a red "Dictation stopped" line',
      );
      expect(engine.receivedFrames.single.bytes.length, 320);
    });

    // And the state it must not get stuck in: an input that opens and never
    // delivers is faulted by `MicCapture.stallTimeout`, not left on `starting`
    // for ever. Bound here because the phase change created the possibility.
    test('an input that never delivers is not left on starting', () async {
      final c = container();
      await controllerOf(c).start();
      expect(stateOf(c).phase, DictationPhase.starting);

      // The watchdog's own suite owns the timing; what matters here is that the
      // fault reaches the phase rather than stranding it.
      await engine.crash(
        const MicCaptureFault('the microphone delivered no audio'),
      );

      expect(stateOf(c).phase, DictationPhase.failed);
      expect(stateOf(c).message, contains('no audio'));
    });

    // The cancellation counter used to be read only on the way *forward*, after
    // each await — but three of `start`'s exits report a failure and return
    // before the next such check, so a cancelled start
    // still repainted. A device with no verified STT set is exactly the device the
    // message is written for, and `dictationEngineProvider` awaits a status
    // provider that hashes files, so the window is real rather than theoretical.
    test(
      'a cancelled start does not report on a capture that is gone',
      () async {
        final gate = Completer<SttEngine?>();
        final c = ProviderContainer(
          overrides: [
            micCaptureProvider.overrideWith((ref) {
              final capture = MicCapture(input: input, stallTimeout: null);
              ref.onDispose(capture.dispose);
              return capture;
            }),
            // Held open, so the stop lands while the engine is still resolving.
            dictationEngineProvider.overrideWith((ref) => gate.future),
          ],
        );
        addTearDown(c.dispose);

        unawaited(controllerOf(c).start());
        await pumpEventQueue();
        expect(stateOf(c).phase, DictationPhase.starting);

        await controllerOf(c).stop();
        expect(stateOf(c).phase, DictationPhase.idle);

        // The device answers: there are no verified weights.
        gate.complete(null);
        await pumpEventQueue();

        expect(
          stateOf(c).phase,
          DictationPhase.idle,
          reason:
              'a red "dictation is unavailable" line under an idle microphone, '
              'about a capture the technician cancelled',
        );
        expect(stateOf(c).message, isNull);
      },
    );

    test(
      'a load failure on a cancelled start is not reported either',
      () async {
        final c = container();
        final gate = Completer<void>();
        engine.initializeGate = gate;
        engine.initializeError = Exception('encoder-epoch-99: no such file');

        unawaited(controllerOf(c).start());
        await pumpEventQueue();
        await controllerOf(c).stop();
        gate.complete();
        await pumpEventQueue();

        expect(stateOf(c).phase, DictationPhase.idle);
        expect(stateOf(c).message, isNull);
      },
    );

    // The control that keeps both of the above from passing on a controller that
    // has simply stopped reporting: with no stop, the same failure *is* reported.
    test('control: an uncancelled start still reports the failure', () async {
      final c = container(stt: () => null);

      await controllerOf(c).start();

      expect(stateOf(c).phase, DictationPhase.unavailable);
      expect(stateOf(c).message, contains('No verified speech model'));
    });

    // **The half of that guard the control above cannot bind.**
    // The control settles "it has not simply stopped
    // reporting", but it runs on a fresh controller where the generation is 1 and
    // matches trivially — so it cannot catch a guard comparing against something
    // staler than the live counter. The case that can: cancel a capture, then let a
    // *new* one genuinely fail. A real error after any number of cancellations still
    // has to reach the technician.
    test('a real failure after a cancelled capture is still reported', () async {
      final gate = Completer<SttEngine?>();
      final c = ProviderContainer(
        overrides: [
          micCaptureProvider.overrideWith((ref) {
            final capture = MicCapture(input: input, stallTimeout: null);
            ref.onDispose(capture.dispose);
            return capture;
          }),
          // **One resolution, not two.** This was written as a counter and a
          // ternary, under a comment claiming the second capture got a fresh
          // answer. It does not: `start()` reads
          // `dictationEngineProvider.future`, which creates no lasting subscription
          // and is served the *cached, already-completed* future the second time.
          // Measured two ways — the body ran once across both captures, and
          // handing the phantom second branch a working engine changed nothing.
          // An inert fixture argument reads as coverage, and this one did.
          //
          // What actually happens, and it is still exactly the case the property
          // needs: held open so the stop lands inside it, completed with `null`, and
          // re-served from cache to a second capture nobody cancelled.
          dictationEngineProvider.overrideWith((ref) => gate.future),
        ],
      );
      addTearDown(c.dispose);

      unawaited(controllerOf(c).start());
      await pumpEventQueue();
      await controllerOf(c).stop();
      gate.complete(null);
      await pumpEventQueue();
      expect(stateOf(c).phase, DictationPhase.idle);

      // Capture two, cancelled by nobody.
      await controllerOf(c).start();

      expect(
        stateOf(c).phase,
        DictationPhase.unavailable,
        reason:
            'the counter must be read live at the write; a guard comparing '
            'against a stale generation would silence this forever',
      );
      expect(stateOf(c).message, contains('No verified speech model'));
    });

    // The microphone is a real resource, so "abandoned" has to mean released. If
    // the stop lands while `MicCapture.start` is in flight, the session that opens
    // must be closed rather than forgotten.
    test('a session that opens after the stop is released', () async {
      final c = container();
      final gate = Completer<void>();
      input.startGate = gate;

      unawaited(controllerOf(c).start());
      await pumpEventQueue();
      await controllerOf(c).stop();
      gate.complete();
      await pumpEventQueue();

      expect(
        input.startStreamCalls,
        1,
        reason: 'it had already been asked for',
      );
      expect(
        input.stopCalls,
        greaterThanOrEqualTo(1),
        reason: 'and it must not be left open with nobody reading it',
      );
      expect(stateOf(c).phase, DictationPhase.idle);
    });
  });

  group('ending a dictation', () {
    test('stop closes the microphone and keeps what was said', () async {
      final c = container();
      await startListening(c);
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
    // (the engine's tail padding), so returning at the session's stop hands a
    // caller a state one utterance short of what was said.
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
      await startListening(c);
      await controllerOf(c).stop();

      await startListening(c);

      expect(stateOf(c).phase, DictationPhase.listening);
      expect(input.startStreamCalls, 2);
    });

    test('starting again clears the previous line', () async {
      final c = container();
      await startListening(c);
      await engine.push(
        const SttTranscript('THE CABIN IS VIBRATING', isFinal: true),
      );
      await controllerOf(c).stop();

      await startListening(c);

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
      await startListening(c);
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
      await startListening(c);
      await engine.crash(const MicCaptureFault('gone'));
      await pumpEventQueue();

      await startListening(c);

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

  /// Every frame handed to [transcribe]'s stream, in order.
  ///
  /// Recorded rather than discarded because the question "did the audio spoken
  /// while the model was loading reach the recogniser" cannot be asked of a
  /// transcript — the double does not transcribe. It is asked of the bytes.
  final receivedFrames = <MicFrame>[];

  Object? initializeError;

  /// Held open to keep `initialize()` pending, so a test can sit inside the
  /// recogniser load the way a device does for 359–530ms.
  Completer<void>? initializeGate;

  int initializeCalls = 0;
  bool _ready = false;

  @override
  bool get isReady => _ready;

  @override
  Future<void> initialize() async {
    initializeCalls++;
    final gate = initializeGate;
    if (gate != null) await gate.future;
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
      receivedFrames.add,
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

  /// Held open to keep `startStream` pending — the other window a stop can land
  /// in while a start is in flight.
  Completer<void>? startGate;

  /// Pushes raw PCM as the plugin would. Even-length only: `MicCapture` emits
  /// whole frames and carries a partial one over, so an odd buffer would be held
  /// back and the test would be measuring the carry rather than the ordering.
  void emit(List<int> bytes) {
    assert(bytes.length.isEven, 'whole 16-bit samples only');
    _raw?.add(_asPlatformBuffer(bytes));
  }

  /// A view into a larger buffer at an **odd** `offsetInBytes`, which is what the
  /// device actually delivered and what `Uint8List.fromList` never produces.
  ///
  /// `fromList` allocates its own backing store, so its `offsetInBytes` is always
  /// 0 and every typed-data view over it is two-byte aligned. A real frame is a
  /// slice of a platform message and carries whatever offset the allocator gave
  /// it — on the demo iPad, **5**. Reading one with `Int16List.sublistView` threw
  /// `RangeError: Offset (5) must be a multiple of BYTES_PER_ELEMENT (2)`, the
  /// throw reached the frame handler, and dictation stopped on the first frame of
  /// every session. Every test in this file passed while that shipped, for the
  /// single reason that `fromList` is kinder than a microphone.
  ///
  /// So the offset is now a property of the double rather than a case one test
  /// remembers to cover: `pcm16ToFloat32` already documents why nothing on this
  /// path may assume alignment, and this is what makes the rest of the path
  /// answer for it.
  /// Exposed so one test can assert the misalignment is real rather than trust
  /// a private helper to keep being unkind.
  static Uint8List platformBufferFor(List<int> bytes) =>
      _asPlatformBuffer(bytes);

  static Uint8List _asPlatformBuffer(List<int> bytes) {
    const offset = 5;
    final backing = Uint8List(offset + bytes.length)
      ..setRange(offset, offset + bytes.length, bytes);
    return Uint8List.sublistView(backing, offset);
  }

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
    final gate = startGate;
    if (gate != null) await gate.future;
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
