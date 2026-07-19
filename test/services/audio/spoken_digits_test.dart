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

    test('a run of exactly the unprefixed floor is rewritten', () {
      expect(minimumDigitRun, 3);
      expect(normalizeSpokenDigits('LEVEL TWO ONE FIVE'), 'LEVEL 215');
    });

    test('one word short of the unprefixed floor is left alone', () {
      // `LEVEL TWO ONE` used to become `LEVEL 21`. It no longer does, because a
      // two-word run with an ordinary English word in front of it is
      // where the fabricated codes came from.
      expect(normalizeSpokenDigits('LEVEL TWO ONE'), 'LEVEL TWO ONE');
    });

    test('a single-letter designator lowers the floor to two', () {
      expect(minimumPrefixedDigitRun, 2);
      expect(normalizeSpokenDigits('B THREE FOUR'), 'B 34');
      expect(normalizeSpokenDigits('E OH ONE'), 'E 01');
    });

    test('a two-letter word does not lower the floor', () {
      // The asymmetry with `faultCodePattern`'s `[A-Za-z]{1,2}` is deliberate: `NO`,
      // `IS`, `AT`, `IN` and `OF` are all two-letter English words, and it was
      // exactly a two-letter word in front of a two-word run that produced `NO-12`.
      expect(
        normalizeSpokenDigits('NO ONE TWO WEEKS AGO'),
        'NO ONE TWO WEEKS AGO',
      );
      expect(
        normalizeSpokenDigits('IS O ONE OF THE DOORS'),
        'IS O ONE OF THE DOORS',
      );
    });

    test('a designator separated by punctuation does not lower the floor', () {
      // `precededBySingleLetter` walks back over whitespace only: a comma between a
      // letter and its digits is a list, not a code.
      expect(normalizeSpokenDigits('E, ONE TWO'), 'E, ONE TWO');
      expect(normalizeSpokenDigits('E   ONE TWO'), 'E   12');
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
      expect(
        normalizeSpokenDigits('ONE TWO FIVE PLEASE THREE'),
        '125 PLEASE THREE',
      );
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

  group('the false positives that refuted the old rule', () {
    // Every input here came from running the *shipped* function, and
    // every one of them produced digits under the old floor of two. Two of them then
    // produced a fault-code candidate through the router's real pattern — which is
    // strictly worse than the harm the floor existed to prevent, because it turns
    // "silently skips the structured lookup" into "runs the structured lookup on a
    // code nobody said".
    const wasRewritten = {
      'OH TWO OF THEM ARE LOOSE': '02 OF THEM ARE LOOSE',
      'OH ONE MORE THING': '01 MORE THING',
      'NO ONE TWO WEEKS AGO': 'NO 12 WEEKS AGO',
      'O ONE OF THE DOORS JAMMED': '01 OF THE DOORS JAMMED',
      'IS O ONE OF THE DOORS JAMMED': 'IS 01 OF THE DOORS JAMMED',
      'THE DOOR IS O ONE OF THE GUIDE SHOES':
          'THE DOOR IS 01 OF THE GUIDE SHOES',
    };

    for (final entry in wasRewritten.entries) {
      test('"${entry.key}" survives verbatim', () {
        expect(
          normalizeSpokenDigits(entry.key),
          entry.key,
          reason: 'under the old floor of two this became "${entry.value}"',
        );
      });
    }

    test('none of them produces a fault-code candidate any more', () {
      // The half that actually caused harm. `IS-01` and `NO-12` were real candidates
      // the router would have spent a lookup on.
      for (final input in wasRewritten.keys) {
        expect(
          RetrievalRouter.faultCodePattern.hasMatch(
            normalizeSpokenDigits(input),
          ),
          isFalse,
          reason: '"$input" must not manufacture a code',
        );
      }
    });

    // **The residue, pinned at the width it has.** This group
    // used to be one line asserting `A ONE TWO` → `A 12`, which described the leak as
    // a curiosity about the article "a". Measured, it is a class: the approximation
    // idiom of the measurement register this app is used in, the *other* single-letter
    // English word, and the two-letter hazard surviving at run length three.
    //
    // These are pinned as *current behaviour*, not as desired behaviour. They are kept
    // on a bound rather than a hope — `RetrievalRouter` verifies every candidate by
    // lookup, so one resolving to no row costs a lookup and not an answer — and they
    // are here so a future narrowing cannot widen the residue unnoticed, and so nobody
    // has to rediscover the class by accident.
    const residue = {
      'THERE WAS A FOUR FIVE SECOND DELAY': 'THERE WAS A 45 SECOND DELAY',
      'I SAW A TWO THREE MILLIMETRE GAP': 'I SAW A 23 MILLIMETRE GAP',
      'MOVE IT A ONE TWO INCHES': 'MOVE IT A 12 INCHES',
      'A ONE TWO': 'A 12',
      // `I` is a single-letter English word too, and the earlier write-up named only
      // `A`.
      'I FOUR TWO': 'I 42',
      // The two-letter narrowing is closed at run length two and *not* at three —
      // raising the unprefixed floor to 3 admits exactly these.
      'NO ONE TWO THREE OF THEM WORK': 'NO 123 OF THEM WORK',
      'IS O ONE TWO OF THE DOORS': 'IS 012 OF THE DOORS',
    };

    for (final entry in residue.entries) {
      test('residue: "${entry.key}" normalises to "${entry.value}"', () {
        expect(normalizeSpokenDigits(entry.key), entry.value);
      });
    }

    test('the residue does manufacture candidates, and that is recorded', () {
      // Asserted rather than hoped: each of these produces a `faultCodePattern`
      // candidate that did not exist before normalisation. If a future rule closes
      // one, this fails and the docs get corrected with it.
      for (final input in residue.keys) {
        expect(
          RetrievalRouter.faultCodePattern.hasMatch(input),
          isFalse,
          reason: '"$input" has no code before normalisation',
        );
        expect(
          RetrievalRouter.faultCodePattern.hasMatch(
            normalizeSpokenDigits(input),
          ),
          isTrue,
          reason:
              '"$input" is known residue — it does produce a candidate, which is '
              'bounded by the router resolving it to nothing, not prevented',
        );
      }
    });
  });

  group('nothing inside an accepted run is deleted', () {
    // The doc says everything outside an accepted run survives verbatim. It used to
    // say "everything", and these three inputs were the counter-examples: a run
    // swallowed the separators between its digit words whatever they were.
    test('a digit already in the text is not swallowed', () {
      expect(normalizeSpokenDigits('ONE 5 TWO'), 'ONE 5 TWO');
      expect(normalizeSpokenDigits('E ONE 5 TWO'), 'E ONE 5 TWO');
    });

    test('sentence punctuation between digit words is not swallowed', () {
      expect(normalizeSpokenDigits('TWO. OH.'), 'TWO. OH.');
      expect(normalizeSpokenDigits('ONE, TWO'), 'ONE, TWO');
      expect(normalizeSpokenDigits('E ONE, OH, TWO'), 'E ONE, OH, TWO');
    });

    test('a run still spans ordinary whitespace, including newlines', () {
      expect(normalizeSpokenDigits('E ONE\n OH\tTWO'), 'E 102');
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
