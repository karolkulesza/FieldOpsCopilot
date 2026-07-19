/// The message vocabulary spoken across the STT isolate boundary.
///
/// Same shape and the same reasoning as `inference_protocol.dart`: requests and
/// replies encode to plain maps of JSON-compatible values so the codec is
/// testable on the host, and [SendPort]s never go through it — the transport pairs
/// an encoded request with its reply port as a two-element list.
///
/// One difference from the LLM protocol, and it is the reason this is worth
/// reading rather than skimming. Inference is *one request, many replies*: a turn
/// streams tokens back over a port until it emits `LlmDone`. Recognition is **one
/// request, one reply, every time** — a chunk of audio goes over, and the
/// transcripts that chunk produced come back. That is not a stylistic choice. The
/// reply is what paces the sender: `SttRecognitionSession` does not hand over the
/// next chunk until the previous one is answered, so an unbounded port queue
/// cannot form in front of a decoder that has fallen behind, and the back-pressure
/// propagates all the way up to `MicCaptureSession`'s pause-aware pump. See
/// `stt_isolate_worker.dart`.
library;

import 'dart:typed_data';

import 'pcm_samples.dart';
import 'stt_config.dart';

/// Wire key naming the variant of a request or reply.
const String sttKindKey = 'kind';

/// A request sent from the app to the STT worker.
sealed class SttRequest {
  const SttRequest();

  Map<String, Object?> toWire();

  /// Decodes a request, throwing [FormatException] on anything unrecognised.
  static SttRequest fromWire(Map<String, Object?> wire) {
    final kind = wire[sttKindKey];
    return switch (kind) {
      SttLoadRequest.kind => SttLoadRequest.fromWire(wire),
      SttBeginRequest.kind => const SttBeginRequest(),
      SttAudioRequest.kind => SttAudioRequest.fromWire(wire),
      SttFinishRequest.kind => const SttFinishRequest(),
      SttCancelRequest.kind => const SttCancelRequest(),
      SttShutdownRequest.kind => const SttShutdownRequest(),
      _ => throw FormatException('unknown stt request "$kind"'),
    };
  }
}

/// Build the recogniser. Answered with [SttReadyReply] or [SttFailureReply].
final class SttLoadRequest extends SttRequest {
  const SttLoadRequest(this.config);

  static const String kind = 'load';

  /// The encoded [SttConfig] — carried as its wire map rather than as the object,
  /// so this file does not have to know how the config encodes itself.
  final Map<String, Object?> config;

  @override
  Map<String, Object?> toWire() => {sttKindKey: kind, 'config': config};

  static SttLoadRequest fromWire(Map<String, Object?> wire) {
    final config = wire['config'];
    if (config is! Map) {
      throw const FormatException('stt load request: missing config');
    }
    return SttLoadRequest(config.cast<String, Object?>());
  }
}

/// Open a recognition session. Answered with [SttAckReply] or [SttFailureReply].
final class SttBeginRequest extends SttRequest {
  const SttBeginRequest();

  static const String kind = 'begin';

  @override
  Map<String, Object?> toWire() => {sttKindKey: kind};
}

/// Feed one chunk of audio.
///
/// Answered with a [SttTranscriptsReply] carrying whatever this chunk produced,
/// which is frequently nothing — a streaming recogniser emits on its own schedule.
/// The reply arrives either way, because it is the sender's permission to send
/// again.
final class SttAudioRequest extends SttRequest {
  const SttAudioRequest({required this.bytes, this.precedingGapBytes = 0});

  static const String kind = 'audio';

  /// Signed 16-bit little-endian mono PCM, exactly as the microphone captured it.
  ///
  /// **Sent as bytes and decoded to floats on the far side**, which is the cheaper
  /// direction whatever the port does with typed data: 16-bit samples are half the
  /// size of the 32-bit floats they decode to, so converting before the hop could
  /// only ever put more across it. (This does *not* claim to know whether a
  /// `SendPort` copies typed data or transfers it — the argument holds under
  /// either, which is why it is stated as a ratio rather than as a mechanism.)
  ///
  /// It also keeps [pcm16ToFloat32]'s odd-length rule in exactly one place. A
  /// buffer cut mid-sample comes back as an [SttFailureReply] naming it, rather
  /// than being rejected here by a second copy of the same rule that could drift
  /// from the first.
  final Uint8List bytes;

  /// Audio dropped immediately before [bytes], in bytes.
  ///
  /// Bytes rather than samples so the unit does not change at the boundary: this
  /// is `MicFrame.precedingGapBytes` travelling unmodified, and the worker turns
  /// it into a sample count with the same [SttConfig.format] it decodes the audio
  /// with. It travels *with* the audio for the reason [MicFrame] attaches it to the
  /// frame — a counter someone has to remember to read is a counter nobody reads.
  final int precedingGapBytes;

  @override
  Map<String, Object?> toWire() => {
    sttKindKey: kind,
    'bytes': bytes,
    'precedingGapBytes': precedingGapBytes,
  };

  static SttAudioRequest fromWire(Map<String, Object?> wire) {
    final bytes = wire['bytes'];
    final gap = wire['precedingGapBytes'];
    if (bytes is! Uint8List) {
      throw FormatException(
        'stt audio request: bytes is not a Uint8List (${bytes.runtimeType})',
      );
    }
    if (gap is! int || gap < 0) {
      throw FormatException('stt audio request: bad precedingGapBytes ($gap)');
    }
    return SttAudioRequest(bytes: bytes, precedingGapBytes: gap);
  }
}

/// End of input: pad, flush, and answer with the session's final transcript.
final class SttFinishRequest extends SttRequest {
  const SttFinishRequest();

  static const String kind = 'finish';

  @override
  Map<String, Object?> toWire() => {sttKindKey: kind};
}

/// Abandon the session without flushing.
///
/// Distinct from [SttFinishRequest] because the two mean opposite things to the
/// user: finishing wants the last word, cancelling has stopped caring and wants
/// the native stream released now. Answered with [SttAckReply].
final class SttCancelRequest extends SttRequest {
  const SttCancelRequest();

  static const String kind = 'cancel';

  @override
  Map<String, Object?> toWire() => {sttKindKey: kind};
}

/// Release the recogniser and end the worker.
final class SttShutdownRequest extends SttRequest {
  const SttShutdownRequest();

  static const String kind = 'shutdown';

  @override
  Map<String, Object?> toWire() => {sttKindKey: kind};
}

/// A reply sent from the STT worker back to the app.
sealed class SttReply {
  const SttReply();

  Map<String, Object?> toWire();

  static SttReply fromWire(Map<String, Object?> wire) {
    final kind = wire[sttKindKey];
    return switch (kind) {
      SttReadyReply.kind => SttReadyReply.fromWire(wire),
      SttAckReply.kind => const SttAckReply(),
      SttTranscriptsReply.kind => SttTranscriptsReply.fromWire(wire),
      SttFailureReply.kind => SttFailureReply.fromWire(wire),
      _ => throw FormatException('unknown stt reply "$kind"'),
    };
  }
}

/// The recogniser exists and is loaded.
final class SttReadyReply extends SttReply {
  const SttReadyReply(this.ready);

  static const String kind = 'ready';

  final SttReady ready;

  @override
  Map<String, Object?> toWire() => {sttKindKey: kind, 'ready': ready.toWire()};

  static SttReadyReply fromWire(Map<String, Object?> wire) {
    final ready = wire['ready'];
    if (ready is! Map) {
      throw const FormatException('stt ready reply: missing payload');
    }
    return SttReadyReply(SttReady.fromWire(ready.cast<String, Object?>()));
  }
}

/// "Done, nothing to report" — the answer to begin and cancel.
final class SttAckReply extends SttReply {
  const SttAckReply();

  static const String kind = 'ack';

  @override
  Map<String, Object?> toWire() => {sttKindKey: kind};
}

/// Transcripts produced by the request being answered. Often empty.
final class SttTranscriptsReply extends SttReply {
  const SttTranscriptsReply(this.transcripts);

  static const String kind = 'transcripts';

  /// In the order the recogniser produced them.
  ///
  /// Each entry is `[text, isFinal, segment]`. A list of positional triples
  /// rather than a list of maps because this is the one message on the hot path —
  /// one per audio chunk for the whole of a capture — and the shape is fixed.
  final List<SttTranscriptWire> transcripts;

  @override
  Map<String, Object?> toWire() => {
    sttKindKey: kind,
    'transcripts': [
      for (final t in transcripts) [t.text, t.isFinal, t.segment],
    ],
  };

  static SttTranscriptsReply fromWire(Map<String, Object?> wire) {
    final raw = wire['transcripts'];
    if (raw is! List) {
      throw const FormatException('stt transcripts reply: missing list');
    }
    return SttTranscriptsReply([
      for (final entry in raw) SttTranscriptWire.fromWire(entry),
    ]);
  }
}

/// One transcript as it crosses the port.
///
/// Deliberately *not* `SttTranscript` itself: this file belongs to the audio
/// service layer and `SttTranscript` belongs to `lib/engines/`, which the no-fake
/// production guard confines. The engine converts, which is one line and keeps the
/// direction of the dependency the same as every other engine in this app.
class SttTranscriptWire {
  const SttTranscriptWire({
    required this.text,
    required this.isFinal,
    required this.segment,
  });

  final String text;
  final bool isFinal;
  final int segment;

  static SttTranscriptWire fromWire(Object? entry) {
    if (entry is! List || entry.length != 3) {
      throw FormatException('stt transcript: expected a triple, got $entry');
    }
    final text = entry[0];
    final isFinal = entry[1];
    final segment = entry[2];
    if (text is! String || isFinal is! bool || segment is! int) {
      throw FormatException('stt transcript: malformed triple ($entry)');
    }
    return SttTranscriptWire(text: text, isFinal: isFinal, segment: segment);
  }

  @override
  String toString() =>
      'SttTranscriptWire("$text", final: $isFinal, segment: $segment)';
}

/// Something went wrong, in the worker or below it.
final class SttFailureReply extends SttReply {
  const SttFailureReply({required this.message, this.recognizerLost = false});

  static const String kind = 'failure';

  final String message;

  /// Whether the recogniser itself is gone, as opposed to this session failing.
  ///
  /// The same distinction `InferenceFailure.enginePresumedLost` draws and for the
  /// same reason: one is worth retrying, the other needs a reload, and confusing
  /// them either drops a transcript or rebuilds a model for nothing. It costs much
  /// less here — this model loads in under half a second — but a caller that
  /// cannot tell the difference cannot report the difference either.
  final bool recognizerLost;

  @override
  Map<String, Object?> toWire() => {
    sttKindKey: kind,
    'message': message,
    'recognizerLost': recognizerLost,
  };

  static SttFailureReply fromWire(Map<String, Object?> wire) {
    final message = wire['message'];
    final lost = wire['recognizerLost'];
    if (message is! String) {
      throw const FormatException('stt failure reply: missing message');
    }
    return SttFailureReply(
      message: message,
      recognizerLost: lost is bool && lost,
    );
  }
}
