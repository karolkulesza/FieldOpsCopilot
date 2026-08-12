/// The on-device [SttEngine]: a streaming zipformer running through sherpa-onnx
/// on a background isolate.
///
/// This class is only a state machine, for the reason `GemmaLlmEngine` is: every
/// native call lives in `SherpaRecognizerRuntime`, every isolate detail lives in
/// `IsolateSttHost`, and what is left here is what upstream code depends on —
/// when the engine is ready, what a transcription looks like, and what happens
/// when one fails. It takes an [SttHost] rather than building one, so the contract
/// is verified on the host and the device tests only have to prove the device part.
library;

import 'dart:async';

import '../../services/audio/mic_frame.dart';
import '../../services/audio/spoken_digits.dart';
import '../../services/audio/stt_config.dart';
import '../../services/audio/stt_isolate_worker.dart';
import '../../services/audio/stt_protocol.dart';
import '../stt_engine.dart';

/// [SttEngine] backed by real weights on the device.
class SherpaSttEngine implements SttEngine {
  SherpaSttEngine({required this.config, SttHost? host})
    // Defaulted rather than required so production reads
    // `SherpaSttEngine(config: …)` and only tests name a host.
    : _host = host ?? IsolateSttHost();

  /// The configuration this engine was built with — notably the model paths,
  /// which is what makes a load failure ("no such file") diagnosable from outside.
  final SttConfig config;

  final SttHost _host;

  SttReady? _ready;

  /// In-flight load, so overlapping `initialize()` calls share one model load.
  ///
  /// The same guard `GemmaLlmEngine` needs and for a weaker version of the same
  /// reason: 43MB is not 2.6GB, but two recognisers built concurrently is still
  /// two copies of the graphs resident and a second `load called twice` throwing
  /// out of the worker.
  Future<SttReady>? _loading;

  bool _disposed = false;

  /// True while a [transcribe] stream is being consumed.
  ///
  /// Recognition is serialised all the way down — `SherpaRecognizerRuntime` holds
  /// one `OnlineStream` — so overlapping transcriptions cannot be honoured.
  bool _transcribing = false;

  @override
  bool get isReady => _ready != null && !_disposed;

  /// What the worker reported at load: load time and the sample rate the
  /// recogniser was actually built at.
  ///
  /// Null until [initialize] completes. Exposed because TC-STT-INIT-01 is a claim
  /// about a handshake completing within a timeout, and a measurement nothing can
  /// read is a measurement nobody will check.
  SttReady? get ready => _ready;

  @override
  Future<void> initialize() async {
    if (_disposed) {
      throw StateError('SherpaSttEngine was disposed; create a new instance');
    }
    if (_ready != null) return;
    // Idempotent by sharing the in-flight future rather than by returning early:
    // returning early would let a second caller proceed as if the recogniser were
    // built while the first load is still running.
    _loading ??= _host.start(config);
    try {
      _ready = await _loading;
    } finally {
      _loading = null;
    }
  }

  @override
  Stream<SttTranscript> transcribe(Stream<MicFrame> frames) {
    if (_disposed) {
      throw StateError('SherpaSttEngine was disposed');
    }
    if (!isReady) {
      // Same failure mode as the fake, which throws when transcribe precedes
      // initialize. Matching it matters: everything upstream is written against
      // one contract and unit-tested against the fake.
      throw StateError('SherpaSttEngine.transcribe called before initialize()');
    }
    if (_transcribing) {
      throw StateError('a transcription is already in flight');
    }
    _transcribing = true;
    return _transcribe(frames);
  }

  Stream<SttTranscript> _transcribe(Stream<MicFrame> frames) async* {
    var begun = false;
    try {
      await _host.beginSession();
      begun = true;

      // `await for` is doing real work here, not just iterating. Each hand-off is
      // awaited until the worker answers, so the subscription stays paused while a
      // chunk decodes — which is what stops an unbounded queue forming in front of
      // the decoder, and what lets `MicCaptureSession`'s bounded backlog take the
      // strain instead. See the library doc of `stt_isolate_worker.dart`.
      await for (final frame in frames) {
        final produced = await _host.acceptAudio(
          SttAudioRequest(
            bytes: frame.bytes,
            precedingGapBytes: frame.precedingGapBytes,
          ),
        );
        for (final transcript in produced) {
          yield _toTranscript(transcript);
        }
      }

      for (final transcript in await _host.finishSession()) {
        yield _toTranscript(transcript);
      }
      begun = false;
    } finally {
      // A consumer that walks away mid-utterance, or an error out of the mic,
      // leaves a native `OnlineStream` open on the worker. Cancelling releases it;
      // without this the next `transcribe` is refused by "a recognition session is
      // already open" and the engine is unusable until it is disposed.
      //
      // Guarded by `begun` rather than run unconditionally: a `beginSession` that
      // itself failed has no session to cancel, and cancelling one that was never
      // opened would replace the real failure with a second, less informative one.
      if (begun) {
        try {
          await _host.cancelSession();
        } on Object {
          // The original failure is the one worth propagating; a cancel that also
          // failed adds nothing a caller can act on.
        }
      }
      _transcribing = false;
    }
  }

  /// Wire transcript → app transcript, applying spoken-digit normalisation.
  ///
  /// **This is where the model's missing digits are repaired**, and it happens on
  /// every transcript rather than only on finals. A partial that reads
  /// `… CODE IS E ONE OH` while the user is still speaking becomes `… CODE IS E 1`
  /// — mid-number, and briefly wrong, but consistent with the final. Normalising
  /// only finals would instead show digits appear all at once at the end of an
  /// utterance, which reads as the transcript being rewritten.
  ///
  /// [SttTranscript.rawText] carries the recogniser's verbatim output, so nothing
  /// is hidden by this and a caller comparing against a reference run has the
  /// untouched string.
  SttTranscript _toTranscript(SttTranscriptWire wire) => SttTranscript(
    normalizeSpokenDigits(wire.text),
    isFinal: wire.isFinal,
    segment: wire.segment,
    rawText: wire.text,
  );

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _ready = null;
    // A dispose racing an in-flight load must not leave the worker holding a
    // recogniser nobody will use, so the load is awaited out — failure and success
    // alike — before the host is torn down.
    final loading = _loading;
    _loading = null;
    if (loading != null) {
      try {
        await loading;
      } on Object {
        // Whatever went wrong with a load whose result is now unwanted is not
        // worth propagating out of dispose; the shutdown below is what matters.
      }
    }
    await _host.shutdown();
  }
}
