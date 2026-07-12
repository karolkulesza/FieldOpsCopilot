/// Abstraction over an on-device speech-to-text engine.
library;

import '../services/audio/mic_frame.dart';

/// A transcription update. [isFinal] distinguishes a stable result from an
/// interim partial emitted while the technician is still speaking.
class SttTranscript {
  const SttTranscript(
    this.text, {
    this.isFinal = false,
    this.segment = 0,
    String? rawText,
  }) : rawText = rawText ?? text;

  /// The transcript as a caller should use it.
  ///
  /// Post-processed — for the on-device backend that means spoken digit runs have
  /// been rewritten as digits (`E ONE OH TWO` → `E 102`). That is not cosmetic:
  /// the pinned model's vocabulary contains no digit tokens at all, and Task 1.4's
  /// fault-code lookup needs digits, so without it every dictated inquiry would
  /// silently skip the structured lookup. See `spoken_digits.dart`.
  final String text;

  /// The recogniser's verbatim output, before any post-processing.
  ///
  /// Defaults to [text], so a backend that does no post-processing — the fake —
  /// needs to say nothing. It exists so the normalisation above cannot hide the
  /// model's actual behaviour from a device test or from anyone comparing a run
  /// against a reference.
  final String rawText;

  final bool isFinal;

  /// Which utterance within the transcription this belongs to, counting from 0.
  ///
  /// A streaming recogniser segments continuous audio at silences, so one call to
  /// [transcribe] can produce several completed utterances. Without this a
  /// consumer cannot tell the final transcript of one from a partial of the next,
  /// and a dictation UI that guesses wrong either appends to the wrong line or
  /// overwrites a committed one.
  final int segment;

  @override
  String toString() =>
      'SttTranscript($text, final: $isFinal, segment: $segment)';
}

/// Contract implemented by every STT backend (fake or on-device).
abstract interface class SttEngine {
  Future<void> initialize();

  bool get isReady;

  /// Consumes captured audio and emits transcripts.
  ///
  /// **Takes [MicFrame], not a bare `Uint8List` — widened by Task 2.2.** Task 0.2
  /// declared this over raw buffers, before Task 2.1 established that the capture
  /// backlog is bounded and that dropped audio has to travel *with* the audio. A
  /// caller bridging the two with `.map((f) => f.bytes)` would be discarding
  /// `precedingGapBytes` in one inconspicuous line — and the whole reason 2.1
  /// carries that field is that a recogniser fed a silent splice returns a fluent
  /// transcript of a sentence nobody said. Taking the frame makes the lossy
  /// conversion something a caller has to write on purpose rather than the path of
  /// least resistance.
  ///
  /// The stream is consumed to completion; closing it is what ends the utterance
  /// and produces the final transcript.
  ///
  /// **One transcription at a time, and the refusal arrives by two different channels
  /// depending on when the caller listens.** Implementations take the in-flight slot
  /// at `onListen`, not here, so that a stream which is built and never listened to
  /// costs nothing. The consequence is worth stating on the interface rather than
  /// leaving to be discovered: calling this while a transcription is *running* throws
  /// a [StateError] synchronously, whereas building two streams before listening to
  /// either gives the second one a [StateError] **on the stream**. Both are the same
  /// refusal; only the delivery differs.
  ///
  /// Cancelling the returned subscription releases the session — it does not leave the
  /// backend holding one — so a consumer that stops dictating mid-utterance may simply
  /// cancel.
  Stream<SttTranscript> transcribe(Stream<MicFrame> frames);

  Future<void> dispose();
}
