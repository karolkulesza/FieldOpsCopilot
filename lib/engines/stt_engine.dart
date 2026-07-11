/// Abstraction over an on-device speech-to-text engine.
library;

import 'dart:typed_data';

/// A transcription update. [isFinal] distinguishes a stable result from an
/// interim partial emitted while the technician is still speaking.
class SttTranscript {
  const SttTranscript(this.text, {this.isFinal = false});

  final String text;
  final bool isFinal;

  @override
  String toString() => 'SttTranscript($text, final: $isFinal)';
}

/// Contract implemented by every STT backend (fake or on-device).
abstract interface class SttEngine {
  Future<void> initialize();

  bool get isReady;

  /// Consumes a stream of 16-bit mono PCM frames and emits transcripts.
  Stream<SttTranscript> transcribe(Stream<Uint8List> pcmFrames);

  Future<void> dispose();
}
