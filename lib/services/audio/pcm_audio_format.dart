/// The wire format of the raw audio that travels from the microphone to the STT
/// engine.
library;

/// Immutable description of a linear-PCM stream in the one encoding this app
/// moves audio in: **signed 16-bit little-endian samples, interleaved**.
///
/// Sample *depth* and byte order are deliberately not fields. They are constants
/// of the contract, not configuration: `SttEngine.transcribe` is declared over
/// "16-bit mono PCM frames", the streaming zipformer consumes 16-bit
/// samples, and `record`'s only raw stream encoder is `AudioEncoder.pcm16bits`.
/// A field nothing can vary is a field that invites a caller to vary it.
///
/// What this type is *for* is arithmetic. Byte counts and durations are the same
/// quantity in two units on every path that touches audio — a backlog bound, a
/// dropped-audio gap, an assertion about a capture's length — and computing that
/// conversion at each site is how the units drift apart.
class PcmAudioFormat {
  const PcmAudioFormat({required this.sampleRate, required this.numChannels})
    : assert(sampleRate > 0, 'sampleRate must be positive'),
      assert(numChannels > 0, 'numChannels must be positive');

  /// 16 kHz mono — the format the on-device STT path is built around.
  ///
  /// 16 kHz because the pinned recogniser
  /// (`sherpa-onnx-streaming-zipformer-en-20M-2023-02-17`) is a 16 kHz model, and
  /// mono because a single-channel stream is what an ASR front-end wants and half
  /// the bytes of the stereo default.
  static const sttMono16k = PcmAudioFormat(sampleRate: 16000, numChannels: 1);

  /// Samples per second, per channel.
  final int sampleRate;

  /// 1 for mono, 2 for stereo.
  final int numChannels;

  /// Bits in one sample of one channel. See the class doc for why this is not a
  /// field.
  static const bitsPerSample = 16;

  /// Bytes in one sample of one channel.
  static const bytesPerSample = bitsPerSample ~/ 8;

  /// Bytes in one *frame* — one sample for every channel.
  ///
  /// This is the granularity a PCM stream may be cut at. A byte offset that is
  /// not a multiple of [bytesPerSample] splits a sample; on a multi-channel
  /// stream an offset that is not a multiple of [bytesPerFrame] additionally
  /// swaps the channels for everything after it.
  int get bytesPerFrame => numChannels * bytesPerSample;

  /// Bytes one second of this audio occupies.
  int get bytesPerSecond => sampleRate * bytesPerFrame;

  /// How long [byteCount] bytes of this audio plays for.
  ///
  /// Truncates, so a byte count that is not a whole number of microseconds
  /// reports the shorter duration.
  Duration durationOf(int byteCount) => Duration(
    microseconds: byteCount * Duration.microsecondsPerSecond ~/ bytesPerSecond,
  );

  /// How many bytes [duration] of this audio occupies, **rounded down to a whole
  /// frame**.
  ///
  /// Rounding down rather than to the nearest frame keeps this usable as a bound:
  /// a caller asking for "at most 2 seconds" gets a count that is at most two
  /// seconds. Returns 0 for a negative duration rather than a negative count.
  int byteCountFor(Duration duration) {
    if (duration.isNegative) return 0;
    final raw =
        duration.inMicroseconds *
        bytesPerSecond ~/
        Duration.microsecondsPerSecond;
    return raw - raw.remainder(bytesPerFrame);
  }

  @override
  bool operator ==(Object other) =>
      other is PcmAudioFormat &&
      other.sampleRate == sampleRate &&
      other.numChannels == numChannels;

  @override
  int get hashCode => Object.hash(sampleRate, numChannels);

  @override
  String toString() =>
      'PcmAudioFormat(${sampleRate}Hz, $numChannels ch, $bitsPerSample-bit LE)';
}
