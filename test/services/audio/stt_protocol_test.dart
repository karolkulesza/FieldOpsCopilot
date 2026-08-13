import 'dart:typed_data';

import 'package:field_ops_copilot/services/audio/stt_config.dart';
import 'package:field_ops_copilot/services/audio/stt_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

const files = SttModelFiles(
  encoder: '/e.onnx',
  decoder: '/d.onnx',
  joiner: '/j.onnx',
  tokens: '/t.txt',
);

/// Encodes then decodes, which is the only thing worth asserting about a codec
/// whose two halves are the only users of each other.
SttRequest roundTripRequest(SttRequest request) =>
    SttRequest.fromWire(request.toWire());

SttReply roundTripReply(SttReply reply) => SttReply.fromWire(reply.toWire());

void main() {
  group('requests', () {
    test('load carries the config map through unchanged', () {
      const config = SttConfig(files: files, numThreads: 3);
      final decoded = roundTripRequest(SttLoadRequest(config.toWire()));

      expect(decoded, isA<SttLoadRequest>());
      // Decoded through `SttConfig` rather than compared as maps, because the map
      // being equal is not the property anyone depends on — the worker rebuilding
      // the same config is.
      final restored = SttConfig.fromWire((decoded as SttLoadRequest).config);
      expect(restored.numThreads, 3);
      expect(restored.files.encoder, '/e.onnx');
    });

    test('audio carries bytes and the gap', () {
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      final decoded =
          roundTripRequest(
                SttAudioRequest(bytes: bytes, precedingGapBytes: 640),
              )
              as SttAudioRequest;

      expect(decoded.bytes, bytes);
      expect(decoded.precedingGapBytes, 640);
    });

    test('audio defaults the gap to zero', () {
      final decoded =
          roundTripRequest(SttAudioRequest(bytes: Uint8List(2)))
              as SttAudioRequest;
      expect(decoded.precedingGapBytes, 0);
    });

    test('the valueless requests survive the trip as themselves', () {
      expect(roundTripRequest(const SttBeginRequest()), isA<SttBeginRequest>());
      expect(
        roundTripRequest(const SttFinishRequest()),
        isA<SttFinishRequest>(),
      );
      expect(
        roundTripRequest(const SttCancelRequest()),
        isA<SttCancelRequest>(),
      );
      expect(
        roundTripRequest(const SttShutdownRequest()),
        isA<SttShutdownRequest>(),
      );
    });

    test('every request kind is distinct', () {
      // Two variants sharing a `kind` would make one of them undecodable — and
      // the failure would be a wrong *behaviour*, not an error, because the
      // switch would simply pick the first arm.
      const kinds = [
        SttLoadRequest.kind,
        SttBeginRequest.kind,
        SttAudioRequest.kind,
        SttFinishRequest.kind,
        SttCancelRequest.kind,
        SttShutdownRequest.kind,
      ];
      expect(kinds.toSet(), hasLength(kinds.length));
    });

    test('an unknown kind is refused, not ignored', () {
      expect(
        () => SttRequest.fromWire(const {sttKindKey: 'transcribe-please'}),
        throwsFormatException,
      );
    });

    test('audio with non-byte payload is refused', () {
      expect(
        () => SttRequest.fromWire({
          sttKindKey: SttAudioRequest.kind,
          'bytes': [1, 2, 3],
          'precedingGapBytes': 0,
        }),
        throwsFormatException,
      );
    });

    test('a negative gap is refused', () {
      expect(
        () => SttRequest.fromWire({
          sttKindKey: SttAudioRequest.kind,
          'bytes': Uint8List(2),
          'precedingGapBytes': -1,
        }),
        throwsFormatException,
      );
    });
  });

  group('replies', () {
    test('ready carries the load measurement', () {
      final decoded =
          roundTripReply(
                const SttReadyReply(
                  SttReady(loadMillis: 466, sampleRate: 16000),
                ),
              )
              as SttReadyReply;

      expect(decoded.ready.loadMillis, 466);
      expect(decoded.ready.sampleRate, 16000);
    });

    test('transcripts round trip in order, with all three fields', () {
      final decoded =
          roundTripReply(
                const SttTranscriptsReply([
                  SttTranscriptWire(text: 'E ONE', isFinal: false, segment: 0),
                  SttTranscriptWire(
                    text: 'E ONE OH TWO',
                    isFinal: true,
                    segment: 0,
                  ),
                  SttTranscriptWire(text: 'PLEASE', isFinal: false, segment: 1),
                ]),
              )
              as SttTranscriptsReply;

      expect(decoded.transcripts.map((t) => t.text).toList(), [
        'E ONE',
        'E ONE OH TWO',
        'PLEASE',
      ]);
      expect(decoded.transcripts.map((t) => t.isFinal).toList(), [
        false,
        true,
        false,
      ]);
      // The segment is the field a positional triple is most likely to lose by
      // being written in the wrong order, and the only one whose absence would
      // still produce a plausible transcript.
      expect(decoded.transcripts.map((t) => t.segment).toList(), [0, 0, 1]);
    });

    test('an empty transcript list is a legitimate answer', () {
      // Most audio chunks produce nothing; the reply still has to arrive, because
      // it is the sender's permission to send again.
      final decoded =
          roundTripReply(const SttTranscriptsReply([])) as SttTranscriptsReply;
      expect(decoded.transcripts, isEmpty);
    });

    test('failure carries the recognizer-lost distinction', () {
      final lost =
          roundTripReply(
                const SttFailureReply(message: 'gone', recognizerLost: true),
              )
              as SttFailureReply;
      final scoped =
          roundTripReply(const SttFailureReply(message: 'chunk'))
              as SttFailureReply;

      expect(lost.recognizerLost, isTrue);
      expect(scoped.recognizerLost, isFalse);
      expect(scoped.message, 'chunk');
    });

    test('ack survives as itself', () {
      expect(roundTripReply(const SttAckReply()), isA<SttAckReply>());
    });

    test('every reply kind is distinct', () {
      const kinds = [
        SttReadyReply.kind,
        SttAckReply.kind,
        SttTranscriptsReply.kind,
        SttFailureReply.kind,
      ];
      expect(kinds.toSet(), hasLength(kinds.length));
    });

    test('an unknown reply kind is refused', () {
      expect(
        () => SttReply.fromWire(const {sttKindKey: 'maybe'}),
        throwsFormatException,
      );
    });

    test('a transcript that is not a triple is refused', () {
      expect(
        () => SttReply.fromWire({
          sttKindKey: SttTranscriptsReply.kind,
          'transcripts': [
            ['text', true],
          ],
        }),
        throwsFormatException,
      );
    });

    test('a transcript with a mistyped member is refused', () {
      expect(
        () => SttReply.fromWire({
          sttKindKey: SttTranscriptsReply.kind,
          'transcripts': [
            ['text', 'true', 0],
          ],
        }),
        throwsFormatException,
      );
    });
  });
}
