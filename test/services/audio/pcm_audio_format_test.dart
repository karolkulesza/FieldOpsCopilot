import 'package:field_ops_copilot/services/audio/pcm_audio_format.dart';
import 'package:flutter_test/flutter_test.dart';

/// Unit-tier coverage for the byte/duration arithmetic every audio path shares.
///
/// Small, and worth having anyway: this is the type the backlog bound, the
/// dropped-audio gap and Task 2.2's recogniser configuration all read their
/// numbers from, so an off-by-one here is an off-by-one everywhere at once.
void main() {
  group('the STT format', () {
    test('is 16 kHz mono, 16-bit', () {
      const format = PcmAudioFormat.sttMono16k;

      expect(format.sampleRate, 16000);
      expect(format.numChannels, 1);
      expect(PcmAudioFormat.bitsPerSample, 16);
      expect(PcmAudioFormat.bytesPerSample, 2);
    });

    test('occupies 32000 bytes per second', () {
      const format = PcmAudioFormat.sttMono16k;

      expect(format.bytesPerFrame, 2, reason: 'one 16-bit sample per frame');
      expect(format.bytesPerSecond, 32000);
    });
  });

  group('frame size', () {
    test('scales with the channel count', () {
      const stereo = PcmAudioFormat(sampleRate: 16000, numChannels: 2);

      expect(stereo.bytesPerFrame, 4);
      expect(stereo.bytesPerSecond, 64000);
    });
  });

  group('durationOf', () {
    test('converts a byte count to playing time', () {
      const format = PcmAudioFormat.sttMono16k;

      expect(format.durationOf(32000), const Duration(seconds: 1));
      expect(format.durationOf(16000), const Duration(milliseconds: 500));
      expect(format.durationOf(0), Duration.zero);
    });

    test('truncates rather than rounding up', () {
      // One byte is half a sample: 31.25µs, so 31µs after truncation. Asserted
      // because a bound that reports *more* audio than it holds is a bound that
      // silently misses its target.
      expect(
        PcmAudioFormat.sttMono16k.durationOf(1),
        const Duration(microseconds: 31),
      );
    });
  });

  group('byteCountFor', () {
    test('converts playing time to a byte count', () {
      const format = PcmAudioFormat.sttMono16k;

      expect(format.byteCountFor(const Duration(seconds: 2)), 64000);
      expect(format.byteCountFor(const Duration(milliseconds: 1)), 32);
    });

    test('rounds down to a whole frame', () {
      const stereo = PcmAudioFormat(sampleRate: 16000, numChannels: 2);

      // 100µs of stereo is 6.4 bytes — 6 before frame alignment, and a frame is
      // 4 bytes, so 4. A count that is not a whole frame is not a usable bound:
      // splitting a frame swaps the channels for everything after it.
      expect(stereo.byteCountFor(const Duration(microseconds: 100)), 4);
      expect(
        stereo.byteCountFor(const Duration(microseconds: 100)).remainder(4),
        0,
      );
    });

    test('never returns a negative count', () {
      expect(
        PcmAudioFormat.sttMono16k.byteCountFor(const Duration(seconds: -1)),
        0,
        reason: 'a negative bound would drop every buffer forever',
      );
    });

    test('round-trips a whole number of seconds through durationOf', () {
      const format = PcmAudioFormat.sttMono16k;
      const original = Duration(seconds: 3);

      expect(format.durationOf(format.byteCountFor(original)), original);
    });
  });

  group('value semantics', () {
    test('equal formats compare and hash equal', () {
      const a = PcmAudioFormat(sampleRate: 16000, numChannels: 1);

      expect(a, PcmAudioFormat.sttMono16k);
      expect(a.hashCode, PcmAudioFormat.sttMono16k.hashCode);
    });

    test('a different rate or channel count is a different format', () {
      // Load-bearing: the format-coercion tripwire decides whether to fault a
      // live capture by comparing two of these.
      expect(
        const PcmAudioFormat(sampleRate: 48000, numChannels: 1),
        isNot(PcmAudioFormat.sttMono16k),
      );
      expect(
        const PcmAudioFormat(sampleRate: 16000, numChannels: 2),
        isNot(PcmAudioFormat.sttMono16k),
      );
    });

    test('describes itself with rate, channels and depth', () {
      expect(
        PcmAudioFormat.sttMono16k.toString(),
        'PcmAudioFormat(16000Hz, 1 ch, 16-bit LE)',
      );
    });
  });
}
