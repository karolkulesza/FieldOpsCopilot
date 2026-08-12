import '../../services/audio/mic_frame.dart';
import '../stt_engine.dart';

/// Deterministic [SttEngine] that replays a scripted transcript, ignoring the
/// incoming audio. Used for unit tests and the skeleton UI.
///
/// **Its refusals mirror `SherpaSttEngine`'s exactly, including when they fire.**
/// Task 1.8 recorded the rule the hard way: a rule enforced in the real backend
/// but not in the fake is a rule that does not exist, because every downstream
/// task is unit-tested against the fake. So this fake refuses a second concurrent
/// transcription, refuses use after disposal, and refuses to be re-initialised
/// after disposal — not because a fake needs to, but because the device does, and
/// a host suite that tolerates them is testing a more forgiving world than the
/// one the app ships into.
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
    _transcribing = true;
    return _transcribe(frames);
  }

  Stream<SttTranscript> _transcribe(Stream<MicFrame> frames) async* {
    try {
      // Drain the audio to completion first, exactly as the real engine does:
      // closing the frame stream is what ends the utterance, so a script emitted
      // before the audio ran out would let a consumer's test pass against an
      // ordering the device never produces.
      await frames.drain<void>();
      for (final transcript in _script) {
        yield transcript;
      }
    } finally {
      _transcribing = false;
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _ready = false;
  }
}
