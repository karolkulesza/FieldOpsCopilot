/// Converting the bytes the microphone produces into the samples the recogniser
/// consumes.
///
/// Capture delivers audio as **signed 16-bit little-endian** bytes, because that
/// is what `record` emits and what `SttEngine.transcribe` is declared over.
/// sherpa-onnx wants **`Float32List` normalised to `[-1, 1]`** — read in
/// `sherpa_onnx-1.13.5/lib/src/online_stream.dart`, whose `acceptWaveform` doc
/// says exactly that and whose implementation copies the list straight into a
/// native `Pointer<Float>` without inspecting it.
///
/// So this conversion is the seam between the two halves of the audio path, and it
/// lives in its own file for the reason [PcmAudioFormat] does: doing it inline at
/// each call site is how the scaling constant drifts, and the scaling constant is
/// the one number here that is easy to get subtly wrong.
library;

import 'dart:typed_data';

import 'pcm_audio_format.dart';

/// Full-scale divisor for signed 16-bit samples.
///
/// **32768, not 32767**, and the difference is not rounding noise — it decides
/// whether the output can leave the range the recogniser documents.
///
/// Two's-complement 16-bit runs from −32768 to +32767: the negative side has one
/// more step than the positive side. Dividing by 32768 maps that range onto
/// `[-1.0, +0.999969…]` — inside `[-1, 1]` at both ends, with the encoding's own
/// asymmetry preserved rather than corrected. Dividing by 32767 instead maps the
/// most negative sample to **−1.000031**, which is outside the documented range;
/// sherpa's `acceptWaveform` neither clamps nor checks, so those samples would
/// reach the feature extractor as out-of-range floats.
///
/// It also matches what sherpa-onnx's own examples do, which matters less than the
/// argument above but is worth knowing when comparing this app's transcripts to a
/// reference run.
const double int16FullScale = 32768.0;

/// Decodes signed 16-bit little-endian PCM [bytes] into normalised samples.
///
/// [bytes] must contain a whole number of samples. An odd length is a
/// [ArgumentError] rather than a silently dropped trailing byte: half a sample is
/// evidence that a buffer was cut at the wrong offset somewhere upstream, and
/// every byte after that cut decodes as noise — which reaches the transcript as
/// confident nonsense rather than as an error anyone can see.
///
/// The [ByteData] view is deliberate. `Int16List.view` would be faster but it
/// requires the underlying buffer to be two-byte aligned, and the buffers arriving
/// here are `Uint8List`s carved out of a platform message with no such guarantee —
/// on a misaligned offset the view constructor throws. `getInt16` has no alignment
/// requirement, and it makes the little-endian choice explicit at the call rather
/// than inheriting the host's byte order.
Float32List pcm16ToFloat32(Uint8List bytes) {
  if (bytes.length.isOdd) {
    throw ArgumentError.value(
      bytes.length,
      'bytes',
      'a 16-bit PCM buffer must have an even length; an odd one has been cut '
          'mid-sample and everything after the cut decodes as noise',
    );
  }
  final view = ByteData.sublistView(bytes);
  final samples = Float32List(bytes.length ~/ 2);
  for (var i = 0; i < samples.length; i++) {
    samples[i] = view.getInt16(i * 2, Endian.little) / int16FullScale;
  }
  return samples;
}

/// [count] samples of digital silence.
///
/// Used for two different jobs, and both are explained where they happen rather
/// than here: bridging a gap the capture backlog dropped
/// (`SttRecognitionSession`), and the tail padding a streaming zipformer needs
/// before it will emit its last word (`SttConfig.tailPadding`).
///
/// Returns a zero-filled list, which is what `Float32List` already guarantees; the
/// function exists so the *reason* has somewhere to be named at each call site.
Float32List silentSamples(int count) {
  if (count < 0) {
    throw ArgumentError.value(count, 'count', 'cannot be negative');
  }
  return Float32List(count);
}

/// How many samples [byteCount] bytes of [format] audio carries, per channel.
///
/// Distinct from [PcmAudioFormat.byteCountFor] and its inverse, which speak in
/// *frames* — a frame is one sample for every channel, so the two agree only on
/// mono. The recogniser is fed mono, but going through the format rather than
/// assuming it keeps a future stereo capture from quietly reporting twice the
/// audio it has.
int sampleCountFor(PcmAudioFormat format, int byteCount) =>
    byteCount ~/ (PcmAudioFormat.bytesPerSample * format.numChannels);
