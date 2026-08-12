import 'package:field_ops_copilot/services/audio/spoken_digits.dart';
import 'package:field_ops_copilot/services/rag/retrieval_router.dart';
import 'package:flutter_test/flutter_test.dart';

/// The transcript the real recognizer produced for `test/fixtures/e102_utterance.wav`
/// on the macOS host (sherpa_onnx 1.13.5, streaming-zipformer-en-20M, int8, greedy).
///
/// Copied verbatim, warts included — `U K` for "okay", `FALK CODE` for "fault
/// code". A cleaned-up version would make these tests pass for reasons the device
/// will not reproduce.
const measuredTranscript =
    'U K THE CABIN IS VIBRATING BADLY IN THE PANEL IS SHOWING AN ERROR '
    'THE FALK CODE IS E ONE OH TWO PLEASE ADVISE';

void main() {
  group('normalizeSpokenDigits', () {
    test('rewrites a run of digit words as digits', () {
      expect(normalizeSpokenDigits('E ONE OH TWO'), 'E 102');
    });

    test('OH and O both mean zero', () {
      expect(normalizeSpokenDigits('ONE OH FIVE'), '105');
      expect(normalizeSpokenDigits('ONE O FIVE'), '105');
    });

    test('a lone digit word stays a word', () {
      // The whole point of the run floor: this sentence must survive intact,
      // because it is the inquiry the retrieval path then runs on.
      expect(
        normalizeSpokenDigits('ONE OF THE GUIDE SHOES IS LOOSE'),
        'ONE OF THE GUIDE SHOES IS LOOSE',
      );
    });

    test('a lone O is a letter, not a zero', () {
      expect(normalizeSpokenDigits('THE O RING'), 'THE O RING');
    });

    test('a run of exactly the floor is rewritten', () {
      expect(minimumDigitRun, 2);
      expect(normalizeSpokenDigits('LEVEL TWO ONE'), 'LEVEL 21');
    });

    test('whitespace and punctuation outside a run survive verbatim', () {
      expect(
        normalizeSpokenDigits('  code:  E   ONE  OH  TWO,  ok  '),
        '  code:  E   102,  ok  ',
      );
    });

    test('a rejected run is written back exactly as it arrived', () {
      // A single digit word surrounded by unusual spacing is where a rebuild
      // would show up as lost whitespace.
      const input = 'a\t\tONE\n\nb';
      expect(normalizeSpokenDigits(input), input);
    });

    test('two runs separated by prose are handled independently', () {
      expect(
        normalizeSpokenDigits('E ONE OH TWO AND B THREE FOUR'),
        'E 102 AND B 34',
      );
    });

    test('the run ends at the first non-digit word', () {
      expect(normalizeSpokenDigits('ONE TWO PLEASE THREE'), '12 PLEASE THREE');
    });

    test('is case-insensitive on input and leaves other casing alone', () {
      expect(normalizeSpokenDigits('e one oh two'), 'e 102');
      expect(normalizeSpokenDigits('E One Oh Two'), 'E 102');
    });

    test('an empty transcript is returned unchanged', () {
      expect(normalizeSpokenDigits(''), '');
    });

    test('text with no digit words is returned unchanged', () {
      expect(
        normalizeSpokenDigits(measuredTranscript.split(' IS E ').first),
        measuredTranscript.split(' IS E ').first,
      );
    });
  });

  group('the transcript this model actually produces', () {
    test('carries no digit before normalisation', () {
      // Not a property of this string but of the model: the vocabulary has no
      // digit tokens. If this ever fails, the model was swapped and the whole
      // rationale in spoken_digits.dart needs re-reading.
      expect(measuredTranscript, isNot(matches(RegExp(r'\d'))));
    });

    test('normalises to text containing 102', () {
      expect(normalizeSpokenDigits(measuredTranscript), contains('102'));
    });

    test('TC-STT-STRM-01 containment holds after normalisation', () {
      final normalized = normalizeSpokenDigits(
        measuredTranscript,
      ).toLowerCase();
      expect(normalized, contains('102'));
      expect(normalized, contains('error'));
    });
  });

  group('the router is what has to accept the output — so ask it', () {
    test("the real faultCodePattern resolves the normalised text to E-102", () {
      // The claim in `spoken_digits.dart` is that joining `E 102` into `E-102`
      // would be cosmetic, because the router's own pattern already spans the
      // space. This runs that pattern rather than restating the claim.
      final normalized = normalizeSpokenDigits(measuredTranscript);
      final match = RetrievalRouter.faultCodePattern.firstMatch(normalized);

      expect(match, isNotNull);
      expect(match!.group(1), 'E');
      expect(match.group(2), '102');
    });

    test('the un-normalised transcript matches no fault code at all', () {
      // The counterfactual, which is the finding this file exists for: without
      // this step a dictated inquiry skips the structured lookup silently.
      expect(
        RetrievalRouter.faultCodePattern.hasMatch(measuredTranscript),
        isFalse,
      );
    });
  });
}
