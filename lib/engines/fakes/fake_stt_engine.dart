import 'dart:typed_data';

import '../stt_engine.dart';

/// Deterministic [SttEngine] that replays a scripted transcript, ignoring the
/// incoming audio. Used for unit tests and the skeleton UI.
class FakeSttEngine implements SttEngine {
  FakeSttEngine({List<SttTranscript>? script})
    : _script = script ?? const [SttTranscript('E-102 error', isFinal: true)];

  final List<SttTranscript> _script;
  bool _ready = false;

  @override
  bool get isReady => _ready;

  @override
  Future<void> initialize() async {
    _ready = true;
  }

  @override
  Stream<SttTranscript> transcribe(Stream<Uint8List> pcmFrames) async* {
    if (!_ready) {
      throw StateError('FakeSttEngine.transcribe called before initialize()');
    }
    // Drain the audio stream so callers can complete, then emit the script.
    await pcmFrames.drain<void>();
    for (final transcript in _script) {
      yield transcript;
    }
  }

  @override
  Future<void> dispose() async {
    _ready = false;
  }
}
