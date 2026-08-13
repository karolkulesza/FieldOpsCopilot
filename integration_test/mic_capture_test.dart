import 'package:field_ops_copilot/services/audio/mic_capture.dart';
import 'package:field_ops_copilot/services/audio/pcm_audio_format.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// **TC-MIC-01** — a real microphone produces real PCM, on a device.
///
/// Run manually, on hardware:
///
/// ```sh
/// flutter test integration_test/mic_capture_test.dart -d <device>
/// ```
///
/// No `--dart-define`s: unlike Task 1.7's provisioning test there is nothing
/// licensed or gated here. What it does need is the **microphone permission**,
/// and that cannot be granted from inside the test — the OS dialog is not part of
/// the Flutter view hierarchy, so no `WidgetTester` gesture can reach it. The
/// first run therefore raises the prompt and skips with the remedy; grant it and
/// run again. A skip rather than a failure, for the reason Task 1.7 gives: a test
/// that did not execute must say so, not report red as though the code were
/// wrong.
///
/// **What this asserts that the host suite cannot.** Every host test drives
/// [MicCapture] over a scripted [AudioInput], so each is a statement about this
/// app's logic and none is a statement about audio hardware. Four things only a
/// device can answer:
///
/// 1. buffers arrive at all, from a real `AVAudioEngine` tap or `AudioRecord`;
/// 2. they arrive at the **cadence 16 kHz mono implies** — 32000 bytes per second
///    of wall clock, an end-to-end sanity check on the whole request-to-bytes
///    path (see the assertion itself for what that does and does not catch);
/// 3. the samples are **not all zero** — a plugin can hand back correctly shaped
///    buffers of silence when the input is dead, which passes every structural
///    check there is;
/// 4. and the whole capture closes cleanly, which is what Task 2.2's
///    `SttEngine.transcribe` needs in order to ever emit a final transcript.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const format = PcmAudioFormat.sttMono16k;
  const captureFor = Duration(seconds: 3);

  testWidgets(
    'captures non-empty 16-bit mono PCM at the expected cadence',
    (tester) async {
      final input = RecordAudioInput();
      final capture = MicCapture(input: input, format: format);
      addTearDown(capture.dispose);

      final started = await capture.start();
      switch (started) {
        case MicPermissionDenied():
          markTestSkipped(
            'microphone permission is not granted. The prompt this run raised '
            'cannot be dismissed from inside the test — the OS dialog is outside '
            'the Flutter view hierarchy. Grant it, then run this test again.',
          );
          return;
        case MicCaptureUnavailable(:final message):
          fail(
            'the microphone could not be opened: $message\n'
            'On iOS check NSMicrophoneUsageDescription; on Android check the '
            'RECORD_AUDIO manifest entry. Both are asserted by '
            'test/services/audio/mic_permission_declaration_test.dart.',
          );
        case MicCaptureBusy():
          fail('nothing else can be capturing: this is a fresh MicCapture');
        case MicCaptureStarted(:final session):
          final frames = <MicFrame>[];
          Object? fault;
          final subscription = session.frames.listen(
            frames.add,
            onError: (Object error) => fault = error,
          );

          // Wall clock, not `tester.pump`: the quantity under test is a *rate*, and
          // the fake async clock a widget test would otherwise use does not make
          // audio hardware produce bytes.
          final stopwatch = Stopwatch()..start();
          await Future<void>.delayed(captureFor);
          stopwatch.stop();
          await session.stop();
          await subscription.asFuture<void>();

          expect(
            fault,
            isNull,
            reason: 'the capture must survive three seconds',
          );
          expect(
            frames,
            isNotEmpty,
            reason: 'a live microphone produces buffers',
          );

          // 1. Shape. Every frame is audio, and every frame is whole samples.
          for (final frame in frames) {
            expect(frame.bytes, isNotEmpty);
            expect(
              frame.bytes.length.remainder(format.bytesPerFrame),
              0,
              reason:
                  'a 16-bit mono frame is two bytes; $frame is not a whole '
                  'number of them',
            );
          }

          // 2. Cadence. This is the AC's "assert byte cadence/format on device",
          // and the tolerance is wide on purpose: the first buffer arrives some
          // milliseconds after the engine starts, and `stop` is asked for after the
          // delay rather than at the last sample.
          //
          // **Narrowed by review finding R0-F3 and its companion note.** An earlier
          // version called this "the failure it exists to catch", meaning a
          // silently substituted format. That claim was wider than the code: a
          // silent rate substitution is not a state either platform reaches — iOS
          // resamples to the requested rate through `AVAudioConverter` and throws if
          // it cannot, Android constructs `AudioRecord` at the requested rate or
          // throws — and the one coercion that *is* reachable (Android rewriting
          // `numChannels`) surfaces as a `MicCaptureFault` before this line is ever
          // evaluated. So this is a broad sanity check on request-to-bytes, not the
          // sole guard against a specific failure.
          final captured = frames.fold(
            0,
            (sum, frame) => sum + frame.bytes.length,
          );
          final expected = format.byteCountFor(stopwatch.elapsed);
          debugPrint(
            'TC-MIC-01: ${frames.length} frames, $captured bytes in '
            '${stopwatch.elapsedMilliseconds}ms '
            '(expected ~$expected for ${format.sampleRate}Hz × '
            '${format.numChannels}ch); '
            'measured ${(captured / stopwatch.elapsedMicroseconds * 1e6).round()} '
            'bytes/s against ${format.bytesPerSecond}',
          );
          expect(
            captured,
            inInclusiveRange(
              (expected * 0.75).floor(),
              (expected * 1.25).ceil(),
            ),
            reason:
                'bytes must arrive at 16 kHz mono cadence; a rate or channel '
                'count other than the one requested lands far outside this '
                '(48kHz ~3x, stereo ~2x)',
          );

          // 3. Live input. Correctly shaped silence passes every check above.
          expect(
            _hasNonZeroSample(frames),
            isTrue,
            reason:
                'every sample in three seconds was exactly zero, which a real '
                'ADC does not produce even in a quiet room — the input is dead '
                'rather than quiet',
          );

          // 4. A consumer that keeps up loses nothing, so the bound never fired.
          expect(session.droppedByteCount, 0);
          expect(frames.every((frame) => !frame.followsGap), isTrue);
          expect(session.isCapturing, isFalse);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

/// Whether any sample in [frames] is non-zero.
///
/// Checked byte-wise rather than by decoding `Int16List`s: a sample is non-zero
/// exactly when one of its two bytes is, so the byte form is equivalent and does
/// not depend on host endianness being the little-endian the format specifies.
bool _hasNonZeroSample(Iterable<MicFrame> frames) =>
    frames.any((frame) => frame.bytes.any((byte) => byte != 0));
