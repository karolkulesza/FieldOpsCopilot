import 'package:field_ops_copilot/services/audio/pcm_audio_format.dart';
import 'package:field_ops_copilot/services/audio/stt_config.dart';
import 'package:field_ops_copilot/services/models/model_descriptor.dart';
import 'package:flutter_test/flutter_test.dart';

const files = SttModelFiles(
  encoder: '/models/stt/encoder.onnx',
  decoder: '/models/stt/decoder.onnx',
  joiner: '/models/stt/joiner.onnx',
  tokens: '/models/stt/tokens.txt',
);

void main() {
  group('wire round trip', () {
    test('every field survives, including the ones with defaults', () {
      const original = SttConfig(
        files: files,
        format: PcmAudioFormat(sampleRate: 8000, numChannels: 2),
        numThreads: 4,
        decodingMethod: SttDecodingMethod.modifiedBeamSearch,
        enableEndpoint: false,
        trailingSilenceSeconds: 2.5,
        tailPadding: Duration(milliseconds: 111),
        maxGapBridge: Duration(milliseconds: 222),
        debug: true,
      );

      // Every value here differs from its default, so a field the codec forgets
      // to carry comes back as the default and fails rather than coincidentally
      // matching. A round trip built from defaults would pass with half the codec
      // deleted.
      final restored = SttConfig.fromWire(original.toWire());

      expect(restored.files.encoder, original.files.encoder);
      expect(restored.files.decoder, original.files.decoder);
      expect(restored.files.joiner, original.files.joiner);
      expect(restored.files.tokens, original.files.tokens);
      expect(restored.format, original.format);
      expect(restored.numThreads, 4);
      expect(restored.decodingMethod, SttDecodingMethod.modifiedBeamSearch);
      expect(restored.enableEndpoint, isFalse);
      expect(restored.trailingSilenceSeconds, 2.5);
      expect(restored.tailPadding, const Duration(milliseconds: 111));
      expect(restored.maxGapBridge, const Duration(milliseconds: 222));
      expect(restored.debug, isTrue);
    });

    test('an int where a double is expected is accepted', () {
      // JSON-shaped maps lose the int/double distinction on a whole number, and a
      // config that refused `1` for 1.0 would fail only for round trailing-silence
      // values — the ones a person is most likely to type.
      final wire = const SttConfig(files: files).toWire()
        ..['trailingSilenceSeconds'] = 2;
      expect(SttConfig.fromWire(wire).trailingSilenceSeconds, 2.0);
    });
  });

  group('the codec refuses rather than defaults', () {
    Map<String, Object?> wireWith(String key, Object? value) =>
        const SttConfig(files: files).toWire()..[key] = value;

    test('a missing files map', () {
      expect(
        () => SttConfig.fromWire(wireWith('files', null)),
        throwsFormatException,
      );
    });

    test('an empty path inside the file set', () {
      final wire = const SttConfig(files: files).toWire();
      (wire['files']! as Map<String, Object?>)['joiner'] = '';
      expect(() => SttConfig.fromWire(wire), throwsFormatException);
    });

    for (final field in const ['sampleRate', 'numChannels', 'numThreads']) {
      test('a non-int $field', () {
        expect(
          () => SttConfig.fromWire(wireWith(field, 'many')),
          throwsFormatException,
        );
      });
    }

    test('an unknown decoding method', () {
      expect(
        () => SttConfig.fromWire(wireWith('decodingMethod', 'beam')),
        throwsFormatException,
      );
    });

    test('a non-bool enableEndpoint', () {
      expect(
        () => SttConfig.fromWire(wireWith('enableEndpoint', 'yes')),
        throwsFormatException,
      );
    });

    test('a non-numeric trailingSilenceSeconds', () {
      expect(
        () => SttConfig.fromWire(wireWith('trailingSilenceSeconds', 'long')),
        throwsFormatException,
      );
    });
  });

  group('forInstallDirectory', () {
    test('composes the four paths Task 2.0 installs', () {
      final config = SttConfig.forInstallDirectory(
        '/data/models/stt-zipformer',
      );

      expect(
        config.files.encoder,
        '/data/models/stt-zipformer/encoder-epoch-99-avg-1.int8.onnx',
      );
      expect(
        config.files.decoder,
        '/data/models/stt-zipformer/decoder-epoch-99-avg-1.int8.onnx',
      );
      expect(
        config.files.joiner,
        '/data/models/stt-zipformer/joiner-epoch-99-avg-1.int8.onnx',
      );
      expect(config.files.tokens, '/data/models/stt-zipformer/tokens.txt');
    });

    test('the file names agree with the catalog that installs them', () {
      // The duplication is deliberate — the audio layer does not import the
      // provisioning catalog — so it is checked here instead of trusted. A
      // renamed artifact in `ModelCatalog` fails this rather than producing a
      // recogniser pointed at four paths that do not exist.
      final descriptor = ModelCatalog.byId(ModelCatalog.sttZipformerId)!;
      final catalogNames = descriptor.files.map((f) => f.fileName).toSet();

      expect(catalogNames, {
        SttModelFiles.encoderFileName,
        SttModelFiles.decoderFileName,
        SttModelFiles.joinerFileName,
        SttModelFiles.tokensFileName,
      });
    });
  });

  group('defaults', () {
    test('the audio format is the one Task 2.1 captures', () {
      const config = SttConfig(files: files);
      expect(config.format, PcmAudioFormat.sttMono16k);
      expect(config.format.sampleRate, 16000);
      expect(config.format.numChannels, 1);
    });

    test('tail padding is non-zero — the measured defect it answers', () {
      // Not a style assertion. Running this model over the unpadded fixture
      // produced a transcript missing its last words entirely; the padding is
      // what makes them appear. A default of `Duration.zero` would silently
      // restore that.
      expect(SttConfig.defaultTailPadding, greaterThan(Duration.zero));
      expect(
        const SttConfig(files: files).tailPadding,
        greaterThan(Duration.zero),
      );
    });

    test('the gap-bridge cap is longer than the endpoint rule', () {
      // If the cap were shorter, a gap long enough to have ended the utterance
      // would be truncated to one that does not — so the recogniser would join
      // two utterances that a listener heard as separate.
      const config = SttConfig(files: files);
      final endpoint = Duration(
        milliseconds: (config.trailingSilenceSeconds * 1000).round(),
      );
      expect(config.maxGapBridge, greaterThan(endpoint));
    });
  });

  group('SttReady', () {
    test('round trips', () {
      const ready = SttReady(loadMillis: 471, sampleRate: 16000);
      final restored = SttReady.fromWire(ready.toWire());
      expect(restored.loadMillis, 471);
      expect(restored.sampleRate, 16000);
    });

    test('refuses a malformed payload', () {
      expect(
        () => SttReady.fromWire(const {'loadMillis': '471'}),
        throwsFormatException,
      );
    });
  });
}
