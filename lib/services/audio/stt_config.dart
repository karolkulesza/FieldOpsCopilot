/// Everything the STT worker needs to build a recogniser and run a session.
///
/// Expressed in this app's vocabulary rather than sherpa-onnx's, for the reason
/// `inference_config.dart` gives for the LLM: `OnlineRecognizerConfig`,
/// `OnlineModelConfig` and `FeatureConfig` are plugin types, and the repo's hard
/// rule is that every on-device capability sits behind a Dart interface. Keeping
/// them out of here means `sherpa_recognizer.dart` is the only file in `lib/` that
/// imports `package:sherpa_onnx`.
library;

import 'dart:typed_data';

import 'pcm_audio_format.dart';

/// Paths to the four files the streaming zipformer is made of.
///
/// A record rather than four loose strings because they are only ever meaningful
/// together: Task 2.0 provisions them as a set and reports `ready` only when every
/// one of them verifies, so a config holding three of them describes nothing.
class SttModelFiles {
  const SttModelFiles({
    required this.encoder,
    required this.decoder,
    required this.joiner,
    required this.tokens,
  });

  /// Absolute paths, always to files Task 2.0's provisioner has already hashed
  /// against its committed pins and installed by atomic rename. This task never
  /// fetches weights.
  final String encoder;
  final String decoder;
  final String joiner;
  final String tokens;

  /// File names as Task 2.0's catalog entry installs them.
  ///
  /// Written here so `SttConfig.forInstallDirectory` can compose a config from a
  /// directory, and deliberately **not** imported from `ModelCatalog`: this file
  /// belongs to the audio layer and a compile-time dependency on the provisioning
  /// catalog would invert that. `stt_config_test.dart` asserts these agree with
  /// the catalog's own `fileName`s, so the duplication is checked rather than
  /// trusted.
  static const encoderFileName = 'encoder-epoch-99-avg-1.int8.onnx';
  static const decoderFileName = 'decoder-epoch-99-avg-1.int8.onnx';
  static const joinerFileName = 'joiner-epoch-99-avg-1.int8.onnx';
  static const tokensFileName = 'tokens.txt';

  Map<String, Object?> toWire() => {
    'encoder': encoder,
    'decoder': decoder,
    'joiner': joiner,
    'tokens': tokens,
  };

  static SttModelFiles fromWire(Map<String, Object?> wire) => SttModelFiles(
    encoder: _path(wire['encoder'], 'encoder'),
    decoder: _path(wire['decoder'], 'decoder'),
    joiner: _path(wire['joiner'], 'joiner'),
    tokens: _path(wire['tokens'], 'tokens'),
  );

  static String _path(Object? raw, String field) {
    if (raw is String && raw.isNotEmpty) return raw;
    throw FormatException('stt config: missing $field path');
  }

  @override
  String toString() => 'SttModelFiles($encoder, …)';
}

/// Runtime configuration for the streaming recogniser.
class SttConfig {
  const SttConfig({
    required this.files,
    this.format = PcmAudioFormat.sttMono16k,
    this.numThreads = defaultThreads,
    this.decodingMethod = SttDecodingMethod.greedySearch,
    this.enableEndpoint = true,
    this.trailingSilenceSeconds = defaultTrailingSilenceSeconds,
    this.tailPadding = defaultTailPadding,
    this.maxGapBridge = defaultMaxGapBridge,
    this.debug = false,
    this.nativeLibraryPath,
    this.primer,
  });

  /// Builds a config for a Task 2.0 install directory (`…/models/<id>/`).
  ///
  /// The joining is `'$directory/$name'` rather than `package:path`'s `join`
  /// because the string crosses an isolate port and is handed to a C API that
  /// takes a POSIX path; both target platforms are POSIX. On a platform where that
  /// stopped being true this would need `path.join`, which is why it is stated.
  factory SttConfig.forInstallDirectory(String directory) => SttConfig(
    files: SttModelFiles(
      encoder: '$directory/${SttModelFiles.encoderFileName}',
      decoder: '$directory/${SttModelFiles.decoderFileName}',
      joiner: '$directory/${SttModelFiles.joinerFileName}',
      tokens: '$directory/${SttModelFiles.tokensFileName}',
    ),
  );

  final SttModelFiles files;

  /// The audio the recogniser is fed. 16 kHz mono, matching both the model's own
  /// `FeatureConfig` default and what Task 2.1 captures.
  final PcmAudioFormat format;

  /// Threads the ONNX runtime may use for one decode step.
  final int numThreads;

  final SttDecodingMethod decodingMethod;

  /// Whether the recogniser segments continuous audio into utterances.
  final bool enableEndpoint;

  /// Speech fed to a fresh stream before the technician's audio, and discarded.
  ///
  /// **This is a workaround for the model, and it is here because the alternative
  /// was a demo that mis-hears the first word of every session.** A technician
  /// said "cabin vibrating" and read back "IN VIBRATING"; "testing cabin
  /// vibrating" gave the same. Reproduced on the host in
  /// `sherpa_recognizer_live_test.dart` — real weights, synthetic audio, the
  /// runtime called directly, no microphone anywhere in it — so it is the
  /// recogniser and not this app's capture.
  ///
  /// It is not the word: *"the cabin is vibrating"* transcribes perfectly, because
  /// "the" absorbs the damage. It is the **opening of a stream**, and what fixes
  /// it is one second of real speech ahead of the utterance:
  ///
  /// ```text
  /// bare    "IN VIBRATING"
  /// primed  "CABIN VIBRATING"
  /// ```
  ///
  /// Measured and rejected, each by running it rather than reasoning about it:
  /// leading silence from 0 to 5000ms, room noise at four amplitudes, a 220Hz
  /// tone, and a larger model (the 2023-06-26 zipformer answers "HAVE BEEN
  /// VIBRATING" on the same clip). Only speech works, which suggests the encoder
  /// needs acoustic content to condition on and zeros are not that.
  ///
  /// Signed 16-bit little-endian at [format], the same encoding [MicFrame] carries
  /// — so the primer travels as bytes and is decoded by the same
  /// `pcm16ToFloat32` the microphone's audio goes through, rather than by a second
  /// path that could disagree with it about scaling.
  ///
  /// `null` disables priming, which is what every host test gets: the scripted
  /// runtime has no first-word weakness to work around, and a 32KB field on a
  /// config that dozens of tests construct would be noise in all of them.
  final Uint8List? primer;

  /// Trailing silence, in seconds, that ends an utterance.
  ///
  /// Maps onto sherpa's `rule2MinTrailingSilence` — the rule that fires *after*
  /// something has been decoded, which is the one a dictation UI cares about.
  /// `rule1MinTrailingSilence` (silence with nothing decoded yet) and
  /// `rule3MinUtteranceLength` are left at the library's defaults, because this
  /// app has no reason to hold an opinion about them and a value copied into our
  /// config would be one more number to keep in step with a dependency.
  final double trailingSilenceSeconds;

  /// Silence appended after the last real audio, before the input is closed.
  ///
  /// A streaming zipformer decodes with right context (this artifact's own ONNX
  /// metadata reports `decode_chunk_len=32`, `T=39`), and `inputFinished()` does
  /// *not* synthesise the frames the encoder is still waiting for — it only stops the
  /// stream accepting more. So without this the last word of an utterance is dropped
  /// silently, which is the same defect Task 2.1 found in its own `stop()` and for a
  /// completely different reason.
  ///
  /// **Measured — and measured at a narrower width than an earlier version of this
  /// comment claimed, which is why the claim is stated with its scope attached.** That
  /// version said the padding was worth 0.8s because an unpadded run "produced
  /// `IS VIBRATING EWAIN O` and stopped". Review finding **R0-F4** re-ran both
  /// configurations over the committed fixture and got **identical** transcripts, with
  /// neither quoted string reproducible in either — the fixture ends in 0.8s of
  /// silence of its own, so this padding had nothing left to add to it.
  ///
  /// What holds is the live-microphone case: audio that ends **at** the last word,
  /// which is what `MicCapture.stop()` produces when the technician releases the
  /// button. Reproducible, over the fixture with its trailing silence stripped
  /// (`sherpa_recognizer_live_test.dart`, `flutter test … --dart-define=FIELDOPS_STT_MODEL_DIR=…`):
  ///
  /// ```
  /// unpadded  "… THE FALK CODE IS E ONE OH TWO PLEASE"
  /// padded    "… THE FALK CODE IS E ONE OH TWO PLEASE ADVISE"
  /// ```
  ///
  /// Exactly one word, and it is the last one. That test asserts the *difference*
  /// rather than the padded run alone, so deleting the padding fails it.
  final Duration tailPadding;

  /// Most silence that will be inserted to stand in for dropped audio.
  ///
  /// Task 2.1's capture backlog is bounded and drops oldest, reporting what it
  /// lost as `MicFrame.precedingGapBytes`. Feeding the recogniser a splice would
  /// make it transcribe two non-adjacent moments as one phrase — 2.1's stated
  /// reason for carrying the gap at all. Substituting silence of the gap's own
  /// duration keeps the timeline honest instead.
  ///
  /// It is capped because past the endpoint rule, more silence changes nothing: the
  /// utterance has already been closed, so a 40-second gap and a 3-second gap have
  /// the same effect on the transcript while the first allocates thirteen times the
  /// samples. The default is comfortably above [trailingSilenceSeconds].
  final Duration maxGapBridge;

  /// Whether the native library logs. Off, because it logs per decode step.
  final bool debug;

  /// Root the plugin composes its per-platform library path **under**, or `null` for
  /// the platform default.
  ///
  /// **Not "the directory the library is in" — review finding R0-F8.** Read in
  /// `sherpa_onnx-1.13.5/lib/src/init_native.dart`, the plugin appends a different
  /// suffix per platform, so on macOS the library sits five directories below the
  /// value passed:
  ///
  /// ```
  /// macOS   $path/sherpa_onnx_macos/SherpaOnnxC.xcframework/macos-arm64_x86_64/SherpaOnnxC.framework/SherpaOnnxC
  /// Android $path/libsherpa-onnx-c-api.so
  /// iOS     ignored — the iOS branch returns the bare-name open whatever `path` is
  /// ```
  ///
  /// **Production always leaves this null.** On Android that is the only value that
  /// works (the bare `libsherpa-onnx-c-api.so` resolves from the app's lib
  /// directory); on iOS it is the only value that *means* anything, since the
  /// parameter is discarded there. An earlier version of this comment said "on iOS and
  /// Android that is the only value that works", which was true of Android and false
  /// of iOS for that second reason.
  ///
  /// It is on the config — rather than only on `SherpaRecognizerRuntime`, where it
  /// started — because the worker builds its own runtime after the isolate hop, so a
  /// path that lives only on the host side cannot reach it. Without it the whole-stack
  /// path (engine → isolate → real weights) is untestable anywhere except a device,
  /// since macOS cannot resolve the framework by bare name and the worker's `dlopen`
  /// fails before anything else runs.
  ///
  /// It is deliberately *not* a general "load the library from anywhere" feature: it
  /// is the same seam `SherpaRecognizerRuntime.nativeLibraryPath` already was, carried
  /// across the boundary that separated it from its only user.
  final String? nativeLibraryPath;

  /// Two threads.
  ///
  /// One decode step of this model over 100ms of audio measured 86ms for the whole
  /// 10s fixture on the macOS host at this setting — roughly 0.01 real-time — so
  /// the constraint is not throughput. It is that this runs on a phone alongside a
  /// 2.6GB LLM, and every thread here is a core not decoding tokens. Two is enough
  /// to stay far ahead of a microphone and small enough to stay out of the way.
  static const int defaultThreads = 2;

  /// 1.2 seconds, which is sherpa's own `rule2MinTrailingSilence` default.
  ///
  /// Named here rather than left implicit so that changing it is a visible edit,
  /// but deliberately the same value: a technician pausing mid-sentence to look at
  /// a panel should not have the utterance closed under them, and 1.2s is already
  /// long for a pause between words.
  static const double defaultTrailingSilenceSeconds = 1.2;

  /// 0.8 seconds — the value [tailPadding]'s measurement used.
  ///
  /// Recorded as "the padding that was observed to recover the last word", not as a
  /// minimum: the experiment compared 0.8s against *none*, so the shortest sufficient
  /// padding is unmeasured. It costs 0.8s of silent decoding at the end of a capture,
  /// which at this model's speed is single-digit milliseconds.
  static const Duration defaultTailPadding = Duration(milliseconds: 800);

  /// 3 seconds.
  static const Duration defaultMaxGapBridge = Duration(seconds: 3);

  SttConfig copyWith({
    SttModelFiles? files,
    PcmAudioFormat? format,
    int? numThreads,
    SttDecodingMethod? decodingMethod,
    bool? enableEndpoint,
    double? trailingSilenceSeconds,
    Duration? tailPadding,
    Duration? maxGapBridge,
    bool? debug,
    String? nativeLibraryPath,
    Uint8List? primer,
  }) => SttConfig(
    files: files ?? this.files,
    format: format ?? this.format,
    numThreads: numThreads ?? this.numThreads,
    decodingMethod: decodingMethod ?? this.decodingMethod,
    enableEndpoint: enableEndpoint ?? this.enableEndpoint,
    trailingSilenceSeconds:
        trailingSilenceSeconds ?? this.trailingSilenceSeconds,
    tailPadding: tailPadding ?? this.tailPadding,
    maxGapBridge: maxGapBridge ?? this.maxGapBridge,
    debug: debug ?? this.debug,
    nativeLibraryPath: nativeLibraryPath ?? this.nativeLibraryPath,
    primer: primer ?? this.primer,
  );

  Map<String, Object?> toWire() => {
    'files': files.toWire(),
    'sampleRate': format.sampleRate,
    'numChannels': format.numChannels,
    'numThreads': numThreads,
    'decodingMethod': decodingMethod.name,
    'enableEndpoint': enableEndpoint,
    'trailingSilenceSeconds': trailingSilenceSeconds,
    'tailPaddingMs': tailPadding.inMilliseconds,
    'maxGapBridgeMs': maxGapBridge.inMilliseconds,
    'debug': debug,
    'nativeLibraryPath': nativeLibraryPath,
    // Sent as bytes rather than as a path: the worker cannot reach `rootBundle`
    // (no `BackgroundIsolateBinaryMessenger`, and this isolate deliberately never
    // takes a `RootIsolateToken` — see the library doc on `sherpa_recognizer.dart`),
    // so the asset is read on the root isolate and travels with the config. It
    // crosses once per load, not once per utterance.
    'primer': primer,
  };

  /// Rebuilds a config from [wire].
  ///
  /// Throws [FormatException] on anything it cannot read rather than defaulting,
  /// for `inference_config.dart`'s reason: this decodes a message this app just
  /// encoded, so a mismatch is a protocol bug — and a recogniser quietly built at
  /// the wrong sample rate does not fail, it transcribes nonsense.
  static SttConfig fromWire(Map<String, Object?> wire) {
    final files = wire['files'];
    if (files is! Map) {
      throw const FormatException('stt config: missing files');
    }
    return SttConfig(
      files: SttModelFiles.fromWire(files.cast<String, Object?>()),
      format: PcmAudioFormat(
        sampleRate: _int(wire['sampleRate'], 'sampleRate'),
        numChannels: _int(wire['numChannels'], 'numChannels'),
      ),
      numThreads: _int(wire['numThreads'], 'numThreads'),
      decodingMethod: _enumByName(
        SttDecodingMethod.values,
        wire['decodingMethod'],
        'decodingMethod',
      ),
      enableEndpoint: _bool(wire['enableEndpoint'], 'enableEndpoint'),
      trailingSilenceSeconds: _double(
        wire['trailingSilenceSeconds'],
        'trailingSilenceSeconds',
      ),
      tailPadding: Duration(
        milliseconds: _int(wire['tailPaddingMs'], 'tailPaddingMs'),
      ),
      maxGapBridge: Duration(
        milliseconds: _int(wire['maxGapBridgeMs'], 'maxGapBridgeMs'),
      ),
      debug: _bool(wire['debug'], 'debug'),
      nativeLibraryPath: _optionalString(
        wire['nativeLibraryPath'],
        'nativeLibraryPath',
      ),
      primer: _optionalBytes(wire['primer'], 'primer'),
    );
  }

  @override
  String toString() =>
      'SttConfig(${format.sampleRate}Hz, ${decodingMethod.name}, '
      'threads: $numThreads, endpoint: $enableEndpoint)';

  static T _enumByName<T extends Enum>(
    List<T> values,
    Object? raw,
    String field,
  ) {
    for (final value in values) {
      if (value.name == raw) return value;
    }
    throw FormatException('stt config: unknown $field "$raw"');
  }

  static int _int(Object? raw, String field) {
    if (raw is int) return raw;
    throw FormatException('stt config: $field is not an int ($raw)');
  }

  static double _double(Object? raw, String field) {
    if (raw is double) return raw;
    if (raw is int) return raw.toDouble();
    throw FormatException('stt config: $field is not a number ($raw)');
  }

  /// A string field that is allowed to be absent.
  ///
  /// Null and a non-null non-string are different failures: the first is the
  /// documented "use the platform default", the second is a protocol bug. An
  /// *empty* string is refused rather than treated as null — it would reach
  /// `dlopen` as a relative path and fail somewhere much less legible.
  static String? _optionalString(Object? raw, String field) {
    if (raw == null) return null;
    if (raw is String && raw.isNotEmpty) return raw;
    throw FormatException(
      'stt config: $field is not a non-empty string ($raw)',
    );
  }

  /// An odd length is rejected rather than trimmed, for `pcm16ToFloat32`'s reason:
  /// half a sample means the buffer was cut mid-sample, and every sample after the
  /// cut decodes as noise. Priming the encoder with noise is worse than not
  /// priming it, and it would present as the very defect the primer exists to fix.
  static Uint8List? _optionalBytes(Object? raw, String field) {
    if (raw == null) return null;
    if (raw is Uint8List && raw.isNotEmpty && raw.length.isEven) return raw;
    throw FormatException(
      'stt config: $field is not a non-empty, even-length byte list ($raw)',
    );
  }

  static bool _bool(Object? raw, String field) {
    if (raw is bool) return raw;
    throw FormatException('stt config: $field is not a bool ($raw)');
  }
}

/// How the transducer turns encoder output into tokens.
enum SttDecodingMethod {
  /// Argmax at every step. The default, and deliberately so: the device
  /// acceptance test asserts on transcript content, and a beam search would make
  /// it vary with a library upgrade for reasons unrelated to this app.
  greedySearch,

  /// Modified beam search over `maxActivePaths` hypotheses. Slower, and only
  /// worth reaching for if dictation accuracy turns out to be the demo's limit.
  modifiedBeamSearch,
}

/// What the worker reports once the recogniser exists.
///
/// The load time is here for the reason `LoadedRuntime`'s is: TC-STT-INIT-01 is a
/// statement about a handshake completing within a timeout, and a measurement
/// nothing can read is a measurement nobody will check.
class SttReady {
  const SttReady({required this.loadMillis, required this.sampleRate});

  final int loadMillis;
  final int sampleRate;

  Map<String, Object?> toWire() => {
    'loadMillis': loadMillis,
    'sampleRate': sampleRate,
  };

  static SttReady fromWire(Map<String, Object?> wire) {
    final loadMillis = wire['loadMillis'];
    final sampleRate = wire['sampleRate'];
    if (loadMillis is! int || sampleRate is! int) {
      throw FormatException('stt ready: malformed payload ($wire)');
    }
    return SttReady(loadMillis: loadMillis, sampleRate: sampleRate);
  }

  @override
  String toString() => 'SttReady(${loadMillis}ms, ${sampleRate}Hz)';
}
