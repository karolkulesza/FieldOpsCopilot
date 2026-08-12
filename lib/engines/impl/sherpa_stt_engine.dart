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
    return _transcribe(frames);
  }

  /// Drives one transcription.
  ///
  /// **Deliberately not an `async*` with an `await for`, and the reason is a
  /// defect that shape has.** The obvious version reads better:
  ///
  /// ```dart
  /// await for (final frame in frames) { … }   // then a `finally` that releases
  /// ```
  ///
  /// but an `async*` body only observes its consumer cancelling when it reaches a
  /// `yield`. Suspended inside `await for` on a microphone that is still open, it
  /// never reaches one — so the `finally` never runs, the worker keeps a native
  /// `OnlineStream` open, and the next `transcribe` is refused by "a recognition
  /// session is already open" for the life of the engine. A consumer walking away
  /// mid-utterance is not a corner case here; it is the user tapping away from a
  /// dictation field.
  ///
  /// Owning the subscription fixes it: [StreamController.onCancel] fires
  /// immediately, cancels the input, and releases the session. The back-pressure
  /// that `await for` gave for free is kept explicitly — the subscription is
  /// **paused for the duration of every hand-off** and resumed by the reply, so at
  /// most one chunk is ever in flight and the pressure propagates up to
  /// `MicCaptureSession`'s pause-aware pump exactly as before.
  Stream<SttTranscript> _transcribe(Stream<MicFrame> frames) {
    final out = StreamController<SttTranscript>();
    StreamSubscription<MicFrame>? input;
    var begun = false;
    var settled = false;

    /// Releases the session and the engine's in-flight slot. Idempotent, because
    /// both a normal close and the consumer's cancel land here.
    Future<void> release({required bool cancelSession}) async {
      if (!_transcribing) return;
      _transcribing = false;
      // Guarded by `begun`: a `beginSession` that itself failed has no session to
      // cancel, and cancelling one that was never opened would replace the real
      // failure with a second, less informative one.
      if (cancelSession && begun) {
        begun = false;
        try {
          await _host.cancelSession();
        } on Object {
          // The original failure is the one worth propagating; a cancel that also
          // failed adds nothing a caller can act on.
        }
      }
    }

    Future<void> fail(Object error, StackTrace stack) async {
      if (settled) return;
      settled = true;
      await input?.cancel();
      await release(cancelSession: true);
      if (!out.isClosed) {
        out.addError(error, stack);
        await out.close();
      }
    }

    Future<void> flush() async {
      if (settled) return;
      settled = true;
      try {
        for (final transcript in await _host.finishSession()) {
          if (!out.isClosed) out.add(_toTranscript(transcript));
        }
        // Finishing *is* the release — the worker freed the native stream on its
        // way out — so there is nothing left to cancel.
        begun = false;
        await release(cancelSession: false);
        if (!out.isClosed) await out.close();
      } on Object catch (error, stack) {
        settled = false;
        await fail(error, stack);
      }
    }

    void onFrame(MicFrame frame) {
      final subscription = input;
      if (subscription == null || settled) return;
      // Paused for the whole hand-off. This is the back-pressure: nothing else is
      // read from the microphone until the worker has answered for this chunk.
      subscription.pause();
      // An `async` closure rather than `.then(onError:)`: the error handler of
      // `Future.then` has to return the future's own value type, so reporting a
      // failure from there means either inventing a `List<SttTranscriptWire>` or
      // throwing out of a callback nobody awaits.
      unawaited(() async {
        try {
          final produced = await _host.acceptAudio(
            SttAudioRequest(
              bytes: frame.bytes,
              precedingGapBytes: frame.precedingGapBytes,
            ),
          );
          if (settled) return;
          for (final transcript in produced) {
            if (!out.isClosed) out.add(_toTranscript(transcript));
          }
          if (subscription.isPaused) subscription.resume();
        } on Object catch (error, stack) {
          await fail(error, stack);
        }
      }());
    }

    out.onListen = () async {
      // **The in-flight slot is taken here, not in [transcribe] — review finding
      // R0-F6.** Taking it at the call site meant a stream that was built and never
      // listened to held it forever: nothing leaks on the worker (no session was ever
      // opened), but the engine refuses every later `transcribe` until it is disposed,
      // recoverable only by rebuilding the provider graph.
      //
      // This is a deliberate divergence from `IsolateInferenceHost.generate`, which
      // sends its request eagerly and says why — "that is what actually happens on
      // device: asking for a turn starts the decode". The asymmetry is real and the
      // reason is that the two costs are opposite. A generation turn *has already
      // begun* on the accelerator, so the events must be buffered for a late
      // listener; a recognition session has nothing to begin until audio arrives, so
      // there is nothing to lose by waiting and a wedged engine to gain by not.
      if (_transcribing) {
        // Only reachable when two streams were built before either was listened to;
        // the synchronous refusal in [transcribe] covers the ordinary case. Reported
        // on the stream rather than thrown, because `onListen` has no caller to throw
        // at.
        settled = true;
        out.addError(StateError('a transcription is already in flight'));
        await out.close();
        return;
      }
      _transcribing = true;

      try {
        await _host.beginSession();
        begun = true;
      } on Object catch (error, stack) {
        await fail(error, stack);
        return;
      }
      if (settled) return;
      input = frames.listen(
        onFrame,
        onError: fail,
        onDone: flush,
        // A frame stream that errors still has a session to release, and `flush`
        // must not run after it. `fail` handles both, so the subscription is kept
        // alive rather than torn down under it.
        cancelOnError: false,
      );
    };

    out.onCancel = () async {
      if (settled) {
        // Ordinary completion: `close()` cancels the subscriber, which lands here
        // after everything has already been released.
        await input?.cancel();
        return;
      }
      settled = true;
      await input?.cancel();
      await release(cancelSession: true);
    };

    return out.stream;
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
