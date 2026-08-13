import 'dart:typed_data';

import 'package:field_ops_copilot/services/audio/pcm_audio_format.dart';
import 'package:field_ops_copilot/services/audio/pcm_samples.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a little-endian 16-bit buffer from [samples].
Uint8List pcm16(List<int> samples) {
  final bytes = Uint8List(samples.length * 2);
  final view = ByteData.sublistView(bytes);
  for (var i = 0; i < samples.length; i++) {
    view.setInt16(i * 2, samples[i], Endian.little);
  }
  return bytes;
}

void main() {
  group('pcm16ToFloat32', () {
    test('decodes little-endian, not the host order', () {
      // 0x0100 little-endian is 1; big-endian it would be 256. Asserting on a
      // value that differs between the two is the only way this test can fail if
      // the endianness is dropped — a symmetric sample like 0x0101 could not.
      final samples = pcm16ToFloat32(Uint8List.fromList([0x01, 0x00]));
      expect(samples.single * int16FullScale, closeTo(1, 1e-6));
    });

    test('normalises the full range into [-1, 1] inclusive at the bottom', () {
      final samples = pcm16ToFloat32(pcm16([-32768, -1, 0, 1, 32767]));
      expect(samples[0], -1.0);
      expect(samples[2], 0.0);
      expect(samples[4], lessThan(1.0));
      expect(samples[4], closeTo(0.99997, 1e-5));
    });

    test('the most negative sample does not leave the documented range', () {
      // The whole reason `int16FullScale` is 32768: with 32767 this is -1.000031,
      // and sherpa's `acceptWaveform` neither clamps nor checks. Pinning the
      // *bound* rather than the constant means changing the divisor fails here.
      final samples = pcm16ToFloat32(pcm16([-32768]));
      expect(samples.single, greaterThanOrEqualTo(-1.0));
    });

    test(
      'rejects an odd-length buffer rather than dropping the half sample',
      () {
        expect(
          () => pcm16ToFloat32(Uint8List.fromList([1, 2, 3])),
          throwsA(isA<ArgumentError>()),
        );
      },
    );

    test('an empty buffer decodes to no samples', () {
      expect(pcm16ToFloat32(Uint8List(0)), isEmpty);
    });

    test('decodes a buffer whose view is not two-byte aligned', () {
      // The alignment case the doc cites as the reason for `ByteData` over
      // `Int16List.view`. A `Uint8List` carved out of a larger buffer at an odd
      // offset is exactly what a platform message delivers, and `Int16List.view`
      // throws on it.
      final backing = Uint8List(5);
      final view = ByteData.sublistView(backing);
      view.setInt16(1, 4242, Endian.little);
      final misaligned = Uint8List.sublistView(backing, 1, 3);

      expect(
        () => Int16List.sublistView(misaligned),
        throwsA(anything),
        reason:
            'if this stops throwing the alignment hazard is gone and the '
            'comment in pcm_samples.dart is stale',
      );
      expect(
        pcm16ToFloat32(misaligned).single * int16FullScale,
        closeTo(4242, 1e-3),
      );
    });
  });

  group('silentSamples', () {
    test('is zero-filled and the requested length', () {
      final silence = silentSamples(3);
      expect(silence, hasLength(3));
      expect(silence.every((s) => s == 0.0), isTrue);
    });

    test('rejects a negative count', () {
      expect(() => silentSamples(-1), throwsA(isA<ArgumentError>()));
    });
  });

  group('sampleCountFor', () {
    test('mono is one sample per frame', () {
      expect(sampleCountFor(PcmAudioFormat.sttMono16k, 3200), 1600);
    });

    test('a stereo buffer carries half as many samples per channel', () {
      // The reason this goes through the format instead of dividing by two: on
      // stereo, `byteCount ~/ 2` would report twice the audio there is.
      const stereo = PcmAudioFormat(sampleRate: 16000, numChannels: 2);
      expect(sampleCountFor(stereo, 3200), 800);
      expect(sampleCountFor(PcmAudioFormat.sttMono16k, 3200), 1600);
    });
  });
}
