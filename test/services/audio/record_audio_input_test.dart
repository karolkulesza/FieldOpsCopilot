import 'package:field_ops_copilot/services/audio/mic_capture.dart';
import 'package:field_ops_copilot/services/audio/pcm_audio_format.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// What `RecordAudioInput` actually asks the plugin for.
///
/// **This suite exists because nothing else bound the recording configuration.**
/// No test constructed a
/// `RecordAudioInput` at all — only its static `describeFormatMismatch` was
/// covered — and six mutations to the configuration survived the whole suite,
/// including `AudioEncoder.pcm16bits` → `aacLc`. That one matters more than any
/// other single token in the file: `aacLc` is `RecordConfig`'s **default**, it *is*
/// accepted by both platforms in streaming mode, and it streams encoded AAC frames.
/// Handed to a PCM recogniser those are noise — and nothing anywhere would have
/// failed, while the README gave the configuration a paragraph claiming every field
/// was deliberate.
///
/// It needs no device, because `record` is a pure method-channel plugin: a mock
/// handler on `com.llfbandit.record/messages` captures the exact arguments the
/// platform would have received. That is the whole of what this repository can
/// check about the request; whether the *hardware* honours it is TC-MIC-01's job.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.llfbandit.record/messages');

  late List<MethodCall> calls;
  late bool permissionAnswer;

  setUp(() {
    calls = <MethodCall>[];
    permissionAnswer = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'hasPermission' => permissionAnswer,
            'stop' => null,
            _ => null,
          };
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Map<Object?, Object?> argumentsOf(String method) =>
      calls.firstWhere((call) => call.method == method).arguments
          as Map<Object?, Object?>;

  group('the stream configuration', () {
    test('requests raw 16-bit PCM, 16 kHz, mono', () async {
      final input = RecordAudioInput();

      await input.startStream(PcmAudioFormat.sttMono16k);

      final arguments = argumentsOf('startStream');
      expect(
        arguments['encoder'],
        'pcm16bits',
        reason:
            "RecordConfig's default is aacLc, which streams *encoded* frames "
            'and is accepted by both platforms — so this is the one field whose '
            'default is both plausible and ruinous',
      );
      expect(arguments['sampleRate'], 16000);
      expect(arguments['numChannels'], 1);
    });

    test('leaves streamBufferSize unset', () async {
      // Deliberate, and the reason is that the field's unit differs between the
      // platforms: `record_ios` 2.1.1 passes it to `installTap` as an
      // `AVAudioFrameCount` (sample frames, default 1024), `record_android` 2.1.2
      // passes it to `AudioRecord` as `bufferSizeInBytes`. One number cannot mean
      // both, so each platform keeps its own default.
      final input = RecordAudioInput();

      await input.startStream(PcmAudioFormat.sttMono16k);

      expect(argumentsOf('startStream')['streamBufferSize'], isNull);
    });

    test('does not ask for effects the demo platform would ignore', () async {
      // Noise suppression is deliberately out of scope. `record_ios` 2.1.1 parses
      // `noiseSuppress` and never reads it again, so requesting it would be a flag
      // that looks like a feature on the device this is demoed from.
      final input = RecordAudioInput();

      await input.startStream(PcmAudioFormat.sttMono16k);

      final arguments = argumentsOf('startStream');
      expect(arguments['noiseSuppress'], isFalse);
      expect(arguments['echoCancel'], isFalse);
      expect(arguments['autoGain'], isFalse);
    });

    test(
      'passes through a non-default format rather than a hardcoded one',
      () async {
        // Guards the seam's contract: `startStream` must honour its argument. A
        // version that ignored it and always sent the STT constants would pass every
        // test above.
        final input = RecordAudioInput();

        await input.startStream(
          const PcmAudioFormat(sampleRate: 48000, numChannels: 2),
        );

        final arguments = argumentsOf('startStream');
        expect(arguments['sampleRate'], 48000);
        expect(arguments['numChannels'], 2);
      },
    );
  });

  group('permission', () {
    test('asks the platform, and requests when not yet granted', () async {
      final input = RecordAudioInput();

      expect(await input.hasPermission(), isTrue);
      expect(argumentsOf('hasPermission')['request'], isTrue);
    });

    test('a platform denial is reported as a denial', () async {
      permissionAnswer = false;
      final input = RecordAudioInput();

      expect(await input.hasPermission(), isFalse);
    });

    test('request can be suppressed', () async {
      final input = RecordAudioInput();

      await input.hasPermission(request: false);

      expect(argumentsOf('hasPermission')['request'], isFalse);
    });
  });

  group('teardown', () {
    test('stop reaches the platform', () async {
      final input = RecordAudioInput();
      await input.startStream(PcmAudioFormat.sttMono16k);

      await input.stop();

      expect(calls.map((call) => call.method), contains('stop'));
    });

    test('dispose reaches the platform', () async {
      final input = RecordAudioInput();
      await input.startStream(PcmAudioFormat.sttMono16k);

      await input.dispose();

      expect(calls.map((call) => call.method), contains('dispose'));
    });
  });

  group('the coercion watcher, end to end', () {
    // Closes the other half of the same coverage gap:
    // the *decision* was pure and tested, but the wiring from
    // `setOnConfigChanged` through the callback to `onCoerced` was bound by
    // nothing, on the grounds that only a platform can trigger it. A platform can
    // be impersonated — the plugin registers its handler on
    // `com.llfbandit.record/configChanged/<recorderId>`, and the recorder id is in
    // the arguments of every call it makes.
    late RecordAudioInput input;
    late List<String> coercions;
    late String recorderId;

    Future<void> deliverConfig({
      required String encoder,
      required int sampleRate,
      required int numChannels,
      int bitRate = 128000,
    }) async {
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            'com.llfbandit.record/configChanged/$recorderId',
            const StandardMethodCodec().encodeMethodCall(
              MethodCall('onConfigChanged', <String, dynamic>{
                'encoder': encoder,
                'bitRate': bitRate,
                'sampleRate': sampleRate,
                'numChannels': numChannels,
                'autoGain': false,
                'echoCancel': false,
                'noiseSuppress': false,
                'audioInterruption': 0,
                'streamBufferSize': null,
              }),
            ),
            (_) {},
          );
    }

    setUp(() async {
      input = RecordAudioInput();
      coercions = <String>[];
      await input.watchFormat(coercions.add);
      await input.startStream(PcmAudioFormat.sttMono16k);
      recorderId = argumentsOf('startStream')['recorderId']! as String;
    });

    test('a substituted channel count reaches the caller', () async {
      // The reachable case, and it is Android's: `FormatCodecSelector` calls
      // `adjustToDeviceCapabilities` before its raw-PCM early return, which
      // rewrites `numChannels` from the routed input's advertised counts. An
      // earlier claim that neither platform mutates the format was false here.
      await deliverConfig(
        encoder: 'pcm16bits',
        sampleRate: 16000,
        numChannels: 2,
      );

      expect(coercions, ['2 channels rather than 1']);
    });

    test('a bit-rate-only adjustment reaches nobody', () async {
      // The load-bearing filter, now bound through the real wiring rather than
      // only through the pure function. The plugin fires this callback whenever
      // *any* of bit rate, sample rate or channel count was adjusted, and bit rate
      // does not exist for a raw PCM stream — neither platform's PCM encoder reads
      // it. Faulting a good capture over it would make the tripwire worse than not
      // watching at all.
      await deliverConfig(
        encoder: 'pcm16bits',
        sampleRate: 16000,
        numChannels: 1,
        bitRate: 64000,
      );

      expect(coercions, isEmpty);
    });

    test(
      'the comparison is against what was requested, not a constant',
      () async {
        // Binds the `_requestedFormat` assignment: a version that never wrote it
        // would compare an Android coercion against the STT default forever.
        await input.startStream(
          const PcmAudioFormat(sampleRate: 48000, numChannels: 2),
        );

        // Now 48kHz stereo is correct and must not be reported...
        await deliverConfig(
          encoder: 'pcm16bits',
          sampleRate: 48000,
          numChannels: 2,
        );
        expect(coercions, isEmpty);

        // ...while the old STT format has become a mismatch.
        await deliverConfig(
          encoder: 'pcm16bits',
          sampleRate: 16000,
          numChannels: 1,
        );
        expect(coercions, [
          '16000Hz rather than 48000Hz, 1 channels rather than 2',
        ]);
      },
    );

    test('an encoder substitution reaches the caller', () async {
      await deliverConfig(encoder: 'aacLc', sampleRate: 16000, numChannels: 1);

      expect(coercions, ['encoder aacLc']);
    });
  });
}
