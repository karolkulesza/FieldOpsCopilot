import 'package:field_ops_copilot/engines/impl/sherpa_stt_engine.dart';
import 'package:field_ops_copilot/engines/stt_engine.dart';
import 'package:field_ops_copilot/services/audio/mic_frame.dart';
import 'package:field_ops_copilot/services/audio/pcm_audio_format.dart';
import 'package:field_ops_copilot/services/audio/stt_config.dart';
import 'package:field_ops_copilot/services/models/model_descriptor.dart';
import 'package:field_ops_copilot/services/models/model_provisioner.dart';
import 'package:field_ops_copilot/services/models/model_storage.dart';
import 'package:field_ops_copilot/services/rag/retrieval_router.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// TC-STT-INIT-01 and TC-STT-STRM-01 — the streaming recogniser on real hardware.
///
/// Run manually on a device:
///
/// ```sh
/// flutter test integration_test/stt_test.dart -d <device>
/// ```
///
/// **No `--dart-define` is needed.** The STT model's source and its four SHA-256
/// pins are committed on the catalog entry (Task 2.0), because the repository is
/// ungated `apache-2.0` — unlike the LLM, whose URI and hash are build-time
/// defines. If the weights are not installed yet this test provisions them first,
/// which takes as long as 43.65MB takes on the device's network.
///
/// **What this proves that the host cannot.** `sherpa_recognizer_live_test.dart`
/// already runs this whole stack against the real weights on the macOS host and
/// TC-STT-STRM-01's containment criterion passes there, so the *logic* is not what
/// is in question here. What only a device can answer:
///
/// 1. The native library resolves **by bare name from inside the app bundle** —
///    `DynamicLibrary.open('SherpaOnnxC.framework/SherpaOnnxC')` on iOS,
///    `libsherpa-onnx-c-api.so` on Android — with `SttConfig.nativeLibraryPath`
///    left null, which is the only configuration production uses. The host test
///    has to supply a path because macOS cannot resolve the bare name, so that
///    path is *exactly* the thing it cannot verify.
/// 2. `initBindings` works on a **spawned background isolate** on a real engine
///    build. The plugin documents that FFI binding state is per-isolate; the host
///    exercises it too, but on the host the loader is the desktop dyld.
/// 3. It loads and decodes within a usable time on arm64 mobile silicon, next to
///    whatever the LLM has resident. Task 1.8 measured process RSS reaching
///    1.67GB with Gemma loaded, so this is the run that says whether a 43MB
///    recogniser alongside it is free or not.
///
/// The audio is the committed fixture rather than the microphone. That is
/// deliberate and it is what makes the assertion an assertion: TC-MIC-01 owns
/// "real hardware produces real PCM", and a live microphone here would make the
/// transcript depend on the room. Wiring the two together is Task 2.3's.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'TC-STT-INIT-01 — the weights load and the engine reports ready',
    (tester) async {
      final config = await _installedSttConfig();

      final engine = SherpaSttEngine(config: config);
      addTearDown(engine.dispose);

      final watch = Stopwatch()..start();
      await engine.initialize();
      watch.stop();

      expect(engine.isReady, isTrue);
      expect(engine.ready, isNotNull);
      expect(
        engine.ready!.sampleRate,
        16000,
        reason: 'the recognizer must be built at the rate MicCapture delivers',
      );
      debugPrint(
        '[TC-STT-INIT-01] handshake+load ${watch.elapsedMilliseconds}ms '
        '(worker reported ${engine.ready!.loadMillis}ms)',
      );

      // A handshake bound rather than a performance target. The host measured
      // 359–530ms; 30s is loose enough that a slow first read off flash cannot make
      // this flaky, and tight enough that a wedged handshake fails instead of
      // hanging until the harness times out.
      expect(watch.elapsedMilliseconds, lessThan(30000));
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );

  testWidgets(
    'TC-STT-STRM-01 — the fixture transcribes, fuzzily, on device',
    (tester) async {
      final config = await _installedSttConfig();
      final pcm = await _fixturePcm();

      final engine = SherpaSttEngine(config: config);
      addTearDown(engine.dispose);
      await engine.initialize();

      final frames = _framesOf(pcm, const Duration(milliseconds: 100));
      final watch = Stopwatch()..start();
      final transcripts = <SttTranscript>[];
      await for (final transcript in engine.transcribe(
        Stream.fromIterable(frames),
      )) {
        transcripts.add(transcript);
      }
      watch.stop();

      expect(transcripts, isNotEmpty);
      final last = transcripts.last;

      debugPrint(
        '[TC-STT-STRM-01] ${frames.length} frames, '
        '${transcripts.length} transcripts, ${watch.elapsedMilliseconds}ms',
      );
      debugPrint('[TC-STT-STRM-01] raw:  "${last.rawText}"');
      debugPrint('[TC-STT-STRM-01] text: "${last.text}"');

      // **Fuzzy containment, not exact equality** — the sprint plan's own
      // instruction, and the right one: a 20M int8 model mis-hears "okay" as
      // "U K" and "fault code" as "FALK CODE" on this fixture, and pinning the
      // whole string would turn a library upgrade into a failure.
      final text = last.text.toLowerCase();
      expect(text, contains('102'), reason: 'the fault code must survive');
      expect(text, contains('error'));
      expect(last.isFinal, isTrue);

      // The stream ends with a final, and the partials that preceded it were
      // fewer than the frames — the filter in `_drain` doing its job.
      expect(transcripts.length, lessThan(frames.length));

      // `102` is supplied by normalisation, because the model's vocabulary has no
      // digit tokens at all. Asserting the *raw* text lacks it is what makes that
      // a property of the model rather than a story about it — and if a future
      // model does emit digits, this failing is the signal to delete
      // `spoken_digits.dart` rather than to keep it running blind.
      expect(
        last.rawText,
        isNot(matches(RegExp(r'\d'))),
        reason: 'this model cannot emit digits; normalisation supplies them',
      );

      // And the end of the chain that motivates the whole normalisation step: the
      // transcript has to resolve to a fault code through Task 1.4's real pattern,
      // or the dictated path silently skips the structured lookup.
      final match = RetrievalRouter.faultCodePattern.firstMatch(last.text);
      expect(match, isNotNull);
      expect(match!.group(2), '102');
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );

  testWidgets(
    'a second transcription works after the first — the session is released',
    (tester) async {
      // Not an AC, but the failure it catches is the one that would ruin a demo:
      // a native `OnlineStream` left open makes every dictation after the first
      // refuse. The host binds this against a scripted host; this is the same
      // property over real native state, where a leak is a real leak.
      final config = await _installedSttConfig();
      final pcm = await _fixturePcm();
      final frames = _framesOf(pcm, const Duration(milliseconds: 100));

      final engine = SherpaSttEngine(config: config);
      addTearDown(engine.dispose);
      await engine.initialize();

      final first = await engine
          .transcribe(Stream.fromIterable(frames))
          .toList();
      final second = await engine
          .transcribe(Stream.fromIterable(frames))
          .toList();

      expect(first.last.text.toLowerCase(), contains('102'));
      expect(
        second.last.text.toLowerCase(),
        contains('102'),
        reason:
            'the same audio must transcribe the same way twice; a carried-over '
            'decoder state or a leaked stream shows up here',
      );
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

/// Ensures the STT weights are installed and returns a config pointing at them.
///
/// `nativeLibraryPath` is left **null**, which is the whole point of running on a
/// device: the bundled library has to resolve by name.
Future<SttConfig> _installedSttConfig() async {
  final descriptor = ModelCatalog.byId(ModelCatalog.sttZipformerId)!;
  expect(
    descriptor.configurationIssue,
    isNull,
    reason: 'the STT source and pins are committed; no defines are needed',
  );

  final storage = await ModelStorage.openDefault();
  await storage.prepare();
  final provisioner = ModelProvisioner(storage: storage);
  addTearDown(provisioner.dispose);

  var status = await provisioner.statusOf(descriptor);
  debugPrint('[stt] install status: ${status.name}');
  if (status != ModelInstallStatus.ready) {
    debugPrint('[stt] provisioning ${descriptor.files.length} files…');
    await provisioner.provision(descriptor);
    status = await provisioner.statusOf(descriptor);
  }
  expect(
    status,
    ModelInstallStatus.ready,
    reason:
        'every file must be present and hash-verified before the recognizer is '
        'pointed at them — a "ready" model with a missing file is not ready',
  );

  return SttConfig.forInstallDirectory(storage.installDir(descriptor).path);
}

/// The recorded fixture's PCM payload, read out of the app's asset bundle.
///
/// Loaded through the asset bundle rather than off the filesystem: an integration
/// test runs *inside the app*, on the device, where the repository's `test/`
/// directory does not exist. `pubspec.yaml` declares this path as an asset for
/// exactly that reason, and declares it in place rather than copying the file, so
/// the host suite and this one cannot drift onto different audio.
Future<Uint8List> _fixturePcm() async {
  final data = await rootBundle.load('test/fixtures/e102_utterance.wav');
  final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  return _wavPayload(bytes);
}

/// The `data` chunk of a 16-bit mono 16 kHz WAV.
///
/// Parses the RIFF chunk table rather than assuming a 44-byte header, and asserts
/// the format: a fixture regenerated at another rate would otherwise be fed to the
/// recogniser unchanged and transcribe as plausible nonsense.
Uint8List _wavPayload(Uint8List bytes) {
  final view = ByteData.sublistView(bytes);
  expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
  expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WAVE');

  var offset = 12;
  while (offset + 8 <= bytes.length) {
    final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final size = view.getUint32(offset + 4, Endian.little);
    final body = offset + 8;
    if (id == 'fmt ') {
      expect(view.getUint16(body + 2, Endian.little), 1, reason: 'mono');
      expect(view.getUint32(body + 4, Endian.little), 16000, reason: '16 kHz');
      expect(view.getUint16(body + 14, Endian.little), 16, reason: '16-bit');
    } else if (id == 'data') {
      return Uint8List.sublistView(bytes, body, body + size);
    }
    // Word-aligned: an odd chunk size is followed by a pad byte.
    offset = body + size + (size.isOdd ? 1 : 0);
  }
  fail('the fixture has no RIFF data chunk');
}

/// Cuts [pcm] into the frame size `MicCapture` delivers, so the recogniser sees
/// the same cadence a live capture would.
List<MicFrame> _framesOf(Uint8List pcm, Duration each) {
  final size = PcmAudioFormat.sttMono16k.byteCountFor(each);
  return [
    for (var offset = 0; offset < pcm.length; offset += size)
      MicFrame(
        bytes: Uint8List.sublistView(
          pcm,
          offset,
          offset + size > pcm.length ? pcm.length : offset + size,
        ),
      ),
  ];
}
