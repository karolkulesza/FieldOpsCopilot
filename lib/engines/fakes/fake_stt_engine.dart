import 'dart:async';

import '../../services/audio/mic_frame.dart';
import '../stt_engine.dart';

/// Deterministic [SttEngine] that replays a scripted transcript, ignoring the
/// incoming audio. Used for unit tests and the skeleton UI.
///
/// **Its refusals mirror `SherpaSttEngine`'s, including when they fire — and so does
/// its stream lifecycle.** Task 1.8 recorded the rule the hard way: a rule enforced
/// in the real backend but not in the fake is a rule that does not exist, because
/// every downstream task is unit-tested against the fake. So this fake refuses a
/// second concurrent transcription, refuses use after disposal, refuses to be
/// re-initialised after disposal, and — the part review finding **R0-F1** caught —
/// **releases on cancel instead of hanging.**
///
/// That last one is why this class owns a subscription rather than being the four-line
/// `async*` it obviously wants to be:
///
/// ```dart
/// Stream<SttTranscript> _transcribe(Stream<MicFrame> frames) async* {
///   await frames.drain<void>();          // ← cancel() never completes here
///   for (final transcript in _script) yield transcript;
/// }
/// ```
///
/// Cancelling an `async*` subscription awaits the body's termination, and the body
/// cannot terminate while it awaits a stream nobody has closed — so a consumer that
/// stops dictating mid-utterance deadlocks. `sherpa_stt_engine.dart` documents that
/// exact hazard at length and avoids it; this file asserted parity with it while
/// containing it, and **`sttEngineProvider` binds this class**, so the deadlock was in
/// the engine the app actually ships. The lesson is the one 1.8 already recorded, one
/// level further in: the parity claim was prose, and the asymmetry that made it false
/// was in the *tests* — the real engine's suite had a cancel test and this one had
/// none.
class FakeSttEngine implements SttEngine {
  FakeSttEngine({List<SttTranscript>? script})
    : _script = script ?? const [SttTranscript('E-102 error', isFinal: true)];

  final List<SttTranscript> _script;
  bool _ready = false;
  bool _disposed = false;
  bool _transcribing = false;

  @override
  bool get isReady => _ready && !_disposed;

  @override
  Future<void> initialize() async {
    if (_disposed) {
      throw StateError('FakeSttEngine was disposed; create a new instance');
    }
    _ready = true;
  }

  @override
  Stream<SttTranscript> transcribe(Stream<MicFrame> frames) {
    if (_disposed) {
      throw StateError('FakeSttEngine was disposed');
    }
    if (!isReady) {
      throw StateError('FakeSttEngine.transcribe called before initialize()');
    }
    if (_transcribing) {
      throw StateError('a transcription is already in flight');
    }
    return _transcribe(frames);
  }

  /// The same shape as `SherpaSttEngine._transcribe`, for the reason in the class doc.
  ///
  /// The in-flight slot is taken in `onListen` rather than in [transcribe] — review
  /// finding **R0-F6** — so a stream that is built and never listened to does not
  /// wedge the engine until disposal.
  Stream<SttTranscript> _transcribe(Stream<MicFrame> frames) {
    final out = StreamController<SttTranscript>();
    StreamSubscription<MicFrame>? input;
    var settled = false;

    void release() {
      if (!_transcribing) return;
      _transcribing = false;
    }

    Future<void> emitScript() async {
      if (settled) return;
      settled = true;
      for (final transcript in _script) {
        if (out.isClosed) break;
        out.add(transcript);
      }
      release();
      if (!out.isClosed) await out.close();
    }

    Future<void> fail(Object error, StackTrace stack) async {
      if (settled) return;
      settled = true;
      await input?.cancel();
      release();
      if (!out.isClosed) {
        out.addError(error, stack);
        await out.close();
      }
    }

    out.onListen = () {
      if (_transcribing) {
        // Only reachable when two streams were built before either was listened to;
        // the synchronous refusal in [transcribe] covers the ordinary case. Reported
        // on the stream rather than thrown, because `onListen` has no caller to throw
        // at.
        settled = true;
        out.addError(StateError('a transcription is already in flight'));
        out.close();
        return;
      }
      _transcribing = true;
      // The audio is consumed to completion before anything is emitted, exactly as
      // the real engine does: closing the frame stream is what ends the utterance, so
      // a script emitted before the audio ran out would let a consumer's test pass
      // against an ordering the device never produces.
      input = frames.listen(
        (_) {},
        onError: fail,
        onDone: emitScript,
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
      release();
    };

    return out.stream;
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _ready = false;
  }
}
