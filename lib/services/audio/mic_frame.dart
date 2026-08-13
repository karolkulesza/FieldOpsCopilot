/// The unit of audio that travels from the microphone to the STT engine.
///
/// **Moved here by Task 2.2, out of `mic_capture.dart` where Task 2.1 wrote it.**
/// The type itself is unchanged; what changed is who needs to name it.
/// `SttEngine.transcribe` is now declared over `Stream<MicFrame>`, and
/// `lib/engines/` may not depend on `mic_capture.dart` — that file imports
/// `package:record` and holds `RecordAudioInput`, so an engine *interface*
/// importing it would put a recorder plugin in the import graph of the layer whose
/// whole purpose is to keep plugins out. This file has no dependency beyond
/// `dart:typed_data`, so both sides can name the shared vocabulary without either
/// reaching into the other. `mic_capture.dart` re-exports it, so every Task 2.1
/// import still resolves.
library;

import 'dart:typed_data';

import 'pcm_audio_format.dart';

/// One buffer of captured audio, plus what was lost immediately before it.
///
/// [precedingGapBytes] is why this is a class and not a bare `Uint8List`. The
/// capture backlog is bounded (see `MicCapture.maxBacklogBytes`), so a consumer
/// that stalls loses audio — and audio lost *silently* is the worst outcome
/// available here: a streaming recogniser fed a spliced stream returns a fluent,
/// well-formed transcript of a sentence nobody said. Attaching the gap to the
/// frame that follows it puts the fact in the consumer's hands at the moment it
/// becomes relevant, rather than in a counter someone has to remember to read.
///
/// Task 2.2 is the consumer that was anticipated, and it does act on it: the STT
/// worker bridges the gap with silence of its own duration before decoding the
/// frame, so the recogniser sees a pause rather than two non-adjacent moments
/// spliced into one phrase.
class MicFrame {
  const MicFrame({required this.bytes, this.precedingGapBytes = 0});

  /// Signed 16-bit little-endian samples, a whole number of frames (see
  /// [PcmAudioFormat.bytesPerFrame]). Never empty.
  final Uint8List bytes;

  /// Bytes of audio dropped between the previous [MicFrame] and this one, or 0
  /// when the stream is continuous.
  final int precedingGapBytes;

  /// Whether audio was lost immediately before this frame.
  bool get followsGap => precedingGapBytes > 0;

  @override
  String toString() => 'MicFrame(${bytes.length}B, gap: ${precedingGapBytes}B)';
}
