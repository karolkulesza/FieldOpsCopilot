/// Every call this app makes into `sherpa_onnx`, and nothing else.
///
/// The same containment `gemma_runtime.dart` gives the LLM: this is the only file
/// in `lib/` that imports `package:sherpa_onnx`, so the plugin's types stop here
/// and swapping the recogniser never touches a caller. What is above it —
/// sessions, gaps, endpointing policy, the isolate — is app logic and is tested on
/// the host against [SttRecognizerRuntime] without any native library present.
///
/// **Everything in the plugin's Dart API is synchronous, blocking FFI.** That is
/// not an incidental detail, it is the reason the STT path owns an isolate at all:
///
/// * `OnlineRecognizer(config)` is a *constructor* that loads three ONNX graphs on
///   the calling thread — see [SherpaRecognizerRuntime.load] for the measurement
///   and the command that produced it.
/// * `decode(stream)` runs the encoder/decoder/joiner on the calling thread.
/// * `acceptWaveform` allocates native memory and copies the samples into it.
///
/// None of it hands work to a background thread the way `flutter_gemma`'s LiteRT-LM
/// path does. So where the inference isolate was insurance against a plugin changing
/// its threading, this one is load-bearing on the first call: run it on the UI
/// isolate and every decode step is a dropped frame.
///
/// **The bindings are per-isolate.** `sherpa_onnx.dart`'s own doc says so in
/// capitals — "This must be called in every isolate that uses sherpa-onnx. Each
/// isolate has its own FFI binding state" — and the mechanism is visible in the
/// source: `initBindings` writes into `SherpaOnnxBindings`' static fields, which
/// are per-isolate like every other Dart static. [SherpaRecognizerRuntime.load]
/// calls it, so the worker initialises itself and the UI isolate never touches the
/// library.
///
/// **No `RootIsolateToken` is needed here**, unlike the inference worker.
/// `initBindings` reaches the native library through `DynamicLibrary.open` — plain
/// `dart:ffi`, no platform channel — and this app resolves the model paths on the
/// root isolate before spawning, so the worker never calls `path_provider` either.
/// That is a deliberate difference from `inference_isolate.dart`, whose worker does
/// need the token, and it is worth knowing because the failure it avoids is a null
/// `RootIsolateToken.instance` inside the worker.
library;

import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'pcm_samples.dart';
import 'stt_config.dart';

/// One transcript as the runtime produces it.
class SttRuntimeTranscript {
  const SttRuntimeTranscript({
    required this.text,
    required this.isFinal,
    required this.segment,
  });

  /// The recogniser's verbatim hypothesis. Upper case, no punctuation, no digits —
  /// see `spoken_digits.dart` for why that last one matters.
  final String text;

  /// Whether the endpointer has closed this segment.
  final bool isFinal;

  /// Which utterance within the session this belongs to, from 0.
  ///
  /// Without it a consumer cannot tell the final transcript of one utterance from
  /// a partial of the next, and a dictation UI that guesses wrong either appends
  /// to the wrong line or overwrites a committed one.
  final int segment;

  @override
  String toString() =>
      'SttRuntimeTranscript("$text", final: $isFinal, segment: $segment)';
}

/// A place recognition can happen: sherpa-onnx in production, something scripted
/// in a test.
///
/// Exists for the reason `InferenceRuntime` does — the session contract (ready
/// states, one session at a time, gap bridging, tail padding, disposal) is app
/// logic, and app logic should not need a 43MB model and a native library to test.
abstract interface class SttRecognizerRuntime {
  /// Builds the recogniser described by [config].
  Future<SttReady> load(SttConfig config);

  /// Opens a recognition session. Only one may be open at a time.
  void beginSession();

  /// Feeds [samples] and returns whatever transcripts they produced.
  ///
  /// Returning a list rather than emitting is what makes the whole path
  /// request/response, and therefore self-pacing. Frequently empty.
  List<SttRuntimeTranscript> acceptSamples(Float32List samples);

  /// Flushes the session and returns its final transcripts.
  List<SttRuntimeTranscript> finishSession();

  /// Abandons the session without flushing.
  void cancelSession();

  /// Releases the recogniser and everything under it.
  Future<void> close();
}

/// [SttRecognizerRuntime] backed by the real native library.
class SherpaRecognizerRuntime implements SttRecognizerRuntime {
  SherpaRecognizerRuntime({this.nativeLibraryPath});

  /// Root the plugin composes its per-platform library path **under**, or `null` for
  /// the platform default.
  ///
  /// Not the directory the library is in: `init_native.dart` appends a per-platform
  /// suffix, so on macOS the framework binary sits five directories below this value,
  /// and on **iOS the parameter is ignored entirely** — that branch returns the
  /// bare-name open whatever is passed. See [SttConfig.nativeLibraryPath], which
  /// carries this across the isolate boundary and spells the suffixes out.
  ///
  /// Production always passes `null`. It is settable only so the host can point at the
  /// `sherpa_onnx_macos` framework in the pub cache, which is what makes it possible
  /// to run this class — the real one, against the real weights — without a device.
  /// See `test/services/audio/sherpa_recognizer_live_test.dart`.
  final String? nativeLibraryPath;

  sherpa.OnlineRecognizer? _recognizer;
  sherpa.OnlineStream? _stream;
  SttConfig? _config;

  int _segment = 0;
  String _lastEmitted = '';

  /// Builds the recogniser, synchronously, on this isolate.
  ///
  /// **Load is 359–530 ms, median 384**, over ten consecutive runs on one
  /// Apple-silicon macOS host, against 371–476 ms over four runs on a second:
  ///
  /// ```sh
  /// flutter test test/services/audio/sherpa_recognizer_live_test.dart \
  ///   --dart-define=FIELDOPS_STT_MODEL_DIR=… --dart-define=FIELDOPS_SHERPA_LIB=…
  /// ```
  ///
  /// **One figure with its command beside it.** Two ranges for
  /// one quantity were once in circulation, `466–471ms` in two source comments and
  /// `456–773ms` in the README, neither with a command recorded and the narrow band a
  /// far tighter claim than its runs could support. Individual runs during development
  /// reached 773 ms, but those were taken while other suites were running; the ten
  /// above are consecutive and unloaded, which is why the range is quoted with how it
  /// was produced rather than as a bare number. The spread within it is dominated by
  /// the first read of 43MB off flash.
  @override
  Future<SttReady> load(SttConfig config) async {
    if (_recognizer != null) {
      throw StateError('SherpaRecognizerRuntime.load called twice');
    }

    // Per-isolate, and this is the isolate that will do the decoding. Cheap to
    // repeat — it re-opens an already-open dynamic library.
    //
    // **Idempotent in its effect but not in its argument.**
    // `sherpa_onnx.dart:107` is `_path ??= p`, so the *first* `initBindings` call in
    // an isolate fixes that isolate's search root for its lifetime and every later
    // argument is silently discarded. Harmless here, because a worker loads once; it
    // matters to anyone who tries to load twice with different paths in one isolate,
    // where the second `dlopen` fails with nothing in this file pointing at why.
    sherpa.initBindings(nativeLibraryPath);

    final watch = Stopwatch()..start();
    final recognizer = sherpa.OnlineRecognizer(
      sherpa.OnlineRecognizerConfig(
        feat: sherpa.FeatureConfig(sampleRate: config.format.sampleRate),
        model: sherpa.OnlineModelConfig(
          transducer: sherpa.OnlineTransducerModelConfig(
            encoder: config.files.encoder,
            decoder: config.files.decoder,
            joiner: config.files.joiner,
          ),
          tokens: config.files.tokens,
          numThreads: config.numThreads,
          debug: config.debug,
          // **Left empty on purpose, and the empty string is the correct value.**
          // sherpa reads `model_type` out of the encoder's own ONNX metadata when
          // this is blank. That artifact reports `model_type=zipformer` (v1) —
          // while the example in the plugin's own `online_recognizer.dart`
          // docstring passes `'zipformer2'`, which is a *different* architecture
          // and wrong for these weights. Copying the example would have hard-coded
          // a value contradicted by the file it describes; reading the metadata
          // out of the encoder is how that was established.
          modelType: '',
        ),
        decodingMethod: switch (config.decodingMethod) {
          SttDecodingMethod.greedySearch => 'greedy_search',
          SttDecodingMethod.modifiedBeamSearch => 'modified_beam_search',
        },
        enableEndpoint: config.enableEndpoint,
        rule2MinTrailingSilence: config.trailingSilenceSeconds,
      ),
    );
    watch.stop();

    _recognizer = recognizer;
    _config = config;
    return SttReady(
      loadMillis: watch.elapsedMilliseconds,
      sampleRate: config.format.sampleRate,
    );
  }

  @override
  void beginSession() {
    final recognizer = _requireRecognizer();
    if (_stream != null) {
      throw StateError('a recognition session is already open');
    }
    final stream = recognizer.createStream();
    _stream = stream;
    _prime(recognizer, stream);
    _segment = 0;
    _lastEmitted = '';
  }

  /// Warms a fresh stream with [SttConfig.primer] and throws away what it decodes.
  ///
  /// The *why* is on `SttConfig.primer` and is not repeated here; what this owns is
  /// making sure none of it reaches a caller. Three things do that:
  ///
  /// * the samples go in through `acceptWaveform` and are drained with the raw
  ///   `isReady`/`decode` loop rather than through [acceptSamples], so no
  ///   `SttRuntimeTranscript` is ever constructed from them;
  /// * `reset` closes the primer's segment, so the technician's first word starts a
  ///   fresh hypothesis instead of being appended to "THE ELEVATOR IS…";
  /// * [beginSession] zeroes `_segment` and `_lastEmitted` *after* this returns, so
  ///   the first utterance a caller sees is segment 0 whether priming ran or not —
  ///   a consumer keying commits off the segment number cannot tell the difference,
  ///   which is the point.
  ///
  /// The trailing silence is what makes the reset land on a closed utterance rather
  /// than mid-word. It is [SttConfig.trailingSilenceSeconds] and not a number of its
  /// own, because the quantity being cleared is exactly what the endpointer calls an
  /// utterance boundary; a separate constant here would be a second opinion about
  /// the same thing.
  ///
  /// This costs one decode of roughly two and a half seconds of audio per capture,
  /// on the isolate, before the first frame arrives. It is not free and it is not
  /// paced by real time — the samples are pushed as fast as the encoder consumes
  /// them.
  void _prime(sherpa.OnlineRecognizer recognizer, sherpa.OnlineStream stream) {
    final config = _config!;
    final primer = config.primer;
    if (primer == null) return;

    final rate = config.format.sampleRate;
    stream.acceptWaveform(samples: pcm16ToFloat32(primer), sampleRate: rate);
    stream.acceptWaveform(
      samples: silentSamples((rate * config.trailingSilenceSeconds).round()),
      sampleRate: rate,
    );
    while (recognizer.isReady(stream)) {
      recognizer.decode(stream);
    }
    recognizer.reset(stream);
  }

  @override
  List<SttRuntimeTranscript> acceptSamples(Float32List samples) {
    final recognizer = _requireRecognizer();
    final stream = _requireStream();
    if (samples.isEmpty) return const [];

    stream.acceptWaveform(
      samples: samples,
      sampleRate: _config!.format.sampleRate,
    );
    return _drain(recognizer, stream, flushing: false);
  }

  @override
  List<SttRuntimeTranscript> finishSession() {
    final recognizer = _requireRecognizer();
    final stream = _requireStream();

    stream.inputFinished();
    final transcripts = _drain(recognizer, stream, flushing: true);

    stream.free();
    _stream = null;
    return transcripts;
  }

  @override
  void cancelSession() {
    _stream?.free();
    _stream = null;
    _lastEmitted = '';
  }

  @override
  Future<void> close() async {
    // Order matters: the stream is owned by the recogniser, so releasing the
    // recogniser first would leave `destroyOnlineStream` pointing at freed native
    // state.
    _stream?.free();
    _stream = null;
    _recognizer?.free();
    _recognizer = null;
    _config = null;
  }

  /// Decodes everything currently available and reports what changed.
  ///
  /// The `isReady`/`decode` loop is the shape sherpa's own examples use: `isReady`
  /// answers "are there enough buffered frames for another step", so this drains
  /// rather than decoding once.
  List<SttRuntimeTranscript> _drain(
    sherpa.OnlineRecognizer recognizer,
    sherpa.OnlineStream stream, {
    required bool flushing,
  }) {
    final out = <SttRuntimeTranscript>[];
    while (recognizer.isReady(stream)) {
      recognizer.decode(stream);
    }

    final endpoint = !flushing && recognizer.isEndpoint(stream);
    final text = recognizer.getResult(stream).text.trim();

    if (endpoint) {
      // An endpoint closes the segment whether or not any text landed in it. A
      // silent segment emits nothing — a `SttTranscript('')` marked final would
      // reach a dictation UI as "the user finished saying nothing", which is
      // indistinguishable from a cleared field.
      if (text.isNotEmpty) {
        out.add(
          SttRuntimeTranscript(text: text, isFinal: true, segment: _segment),
        );
      }
      // `reset` is what starts the next utterance; without it `getResult` keeps
      // returning the closed segment's text and every later partial repeats it.
      recognizer.reset(stream);
      if (text.isNotEmpty) _segment++;
      _lastEmitted = '';
      return out;
    }

    if (flushing) {
      if (text.isNotEmpty) {
        out.add(
          SttRuntimeTranscript(text: text, isFinal: true, segment: _segment),
        );
      }
      _lastEmitted = text;
      return out;
    }

    // Partials are emitted only when the hypothesis actually moved. A streaming
    // recogniser is asked for its result once per chunk and most chunks do not
    // change it, so re-emitting an identical partial makes a UI rebuild for
    // nothing and makes a transcript stream that looks busy while saying the same
    // thing.
    //
    // Measured on the committed fixture, whole stack, macOS host:
    // **101 frames in, 25 transcripts out** — three quarters of the chunks produced
    // nothing new. Printed by `sherpa_recognizer_live_test.dart`'s whole-stack test on
    // every run, so the figure can be re-derived rather than trusted.
    //
    // **What holds this line in place is that test's *property* assertion** — no
    // partial repeats its predecessor within a segment — plus a bound below **half**
    // the frame count. A ratio "below 1:1" would not hold it: that claim was
    // refuted by deleting this clause and
    // watching all five tests pass at 101 → 90: a chunk emits nothing until decoding
    // begins, so the count is structurally under the frame count whatever this does.
    // Deleting the clause now fails at partial 1.
    if (text.isNotEmpty && text != _lastEmitted) {
      _lastEmitted = text;
      out.add(
        SttRuntimeTranscript(text: text, isFinal: false, segment: _segment),
      );
    }
    return out;
  }

  sherpa.OnlineRecognizer _requireRecognizer() {
    final recognizer = _recognizer;
    if (recognizer == null) {
      throw StateError('SherpaRecognizerRuntime used before load()');
    }
    return recognizer;
  }

  sherpa.OnlineStream _requireStream() {
    final stream = _stream;
    if (stream == null) {
      throw StateError('no recognition session is open');
    }
    return stream;
  }
}
