import 'package:field_ops_copilot/views/components/answer_markdown.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

/// Unit coverage for the answer formatter — review finding R0-F5.
///
/// The formatter exists because Gemma 4 E2B emits Markdown unprompted and the demo
/// screen was rendering it with a plain `Text`, so the screen recording showed raw
/// `**asterisks**`. Its scope is deliberately two constructs; these tests bind both
/// the scope and its **boundary**, because a formatter that silently ate an
/// unsupported construct would be worse than one that showed it.
void main() {
  /// The visible text: every span's characters, concatenated.
  String rendered(String input) =>
      answerSpans(input).map((s) => (s as TextSpan).text ?? '').join();

  /// Which substrings came back bold.
  List<String> boldParts(String input) => answerSpans(input)
      .cast<TextSpan>()
      .where((s) => s.style?.fontWeight == FontWeight.bold)
      .map((s) => s.text!)
      .toList();

  group('the two supported constructs', () {
    test('paired ** becomes bold and the delimiters are consumed', () {
      const input = 'The required part is **BRK-990-XP**.';

      expect(rendered(input), 'The required part is BRK-990-XP.');
      expect(boldParts(input), ['BRK-990-XP']);
    });

    test('several runs on one line each bold independently', () {
      const input = '**Parts Check:** you need **BRK-990-XP** today.';

      expect(boldParts(input), ['Parts Check:', 'BRK-990-XP']);
      expect(rendered(input), 'Parts Check: you need BRK-990-XP today.');
    });

    test('a bullet marker becomes a bullet, keeping its spacing', () {
      // Exactly the shape both device runs produced.
      expect(rendered('*   Torx T20 driver'), '•   Torx T20 driver');
      expect(rendered('-   Digital Caliper'), '•   Digital Caliper');
    });

    test('indentation is preserved so a nested list keeps its shape', () {
      expect(rendered('    * inner'), '    • inner');
    });

    test('bold survives inside a bullet line', () {
      const input = '*   **Isolate Power:** kill the bus';

      expect(rendered(input), '•   Isolate Power: kill the bus');
      expect(boldParts(input), ['Isolate Power:']);
    });

    // The device answer's real structure: bold headers, a numbered list whose items
    // start with bold labels, and asterisk bullets.
    test('the shape the model actually emits comes out clean', () {
      const input =
          '**Repair Procedure:**\n'
          '1.  **Isolate Power:** Isolate the main elevator power bus.\n'
          '*   Torx T20 driver';

      expect(
        rendered(input),
        'Repair Procedure:\n'
        '1.  Isolate Power: Isolate the main elevator power bus.\n'
        '•   Torx T20 driver',
      );
      expect(boldParts(input), ['Repair Procedure:', 'Isolate Power:']);
    });
  });

  group('the boundary — what it deliberately leaves alone', () {
    // The whitespace requirement is the property that makes the bullet rule safe.
    // Without it, every line opening with a bold header would lose its first
    // asterisk and gain a bullet.
    test('a line opening with **bold** is not a bullet', () {
      const input = '**Diagnosis based on Manual:**';

      expect(rendered(input), 'Diagnosis based on Manual:');
      expect(rendered(input), isNot(startsWith('•')));
      expect(boldParts(input), ['Diagnosis based on Manual:']);
    });

    test('a bare * with no following space is left alone', () {
      expect(rendered('*emphasis* stays'), '*emphasis* stays');
    });

    test(
      'an unpaired ** stays literal rather than guessing where it closes',
      () {
        expect(rendered('a **partial answer'), 'a **partial answer');
        expect(boldParts('a **partial answer'), isEmpty);
      },
    );

    // Mid-stream, the tail of the text is routinely an unpaired delimiter. It must
    // render stably rather than flickering as the closing pair arrives.
    test('a token stream mid-**bold** renders without dropping text', () {
      expect(rendered('Isolate the **main'), 'Isolate the **main');
      expect(rendered('Isolate the **main pow'), 'Isolate the **main pow');
      expect(
        rendered('Isolate the **main power bus**'),
        'Isolate the main power bus',
      );
    });

    test('unsupported constructs pass through verbatim', () {
      for (final input in [
        '# A heading',
        '`inline code`',
        '_italic_',
        '[a link](https://example.invalid)',
        '> a quote',
      ]) {
        expect(rendered(input), input, reason: input);
        expect(boldParts(input), isEmpty, reason: input);
      }
    });
  });

  group('the invariant', () {
    // **No non-marker character is ever lost.** Checked by deleting every marker
    // character — `*`, `-`, `•` — from both sides and requiring equality, so the
    // comparison is blind to *which* delimiters were consumed or rewritten and
    // sensitive only to text going missing. That is the width this can honestly
    // claim: which delimiters got consumed is bound by the per-case tests above,
    // and trying to reconstruct the input here would mean reimplementing the
    // function inside its own test.
    //
    // The first version tried the reconstruction and was wrong rather than the code
    // was: it undid `•` to `*` unconditionally, so a `- x` bullet reconstructed as
    // `* x` and failed on an input the code had handled correctly.
    test('no non-marker character is lost, for any shape', () {
      String withoutMarkers(String s) => s.replaceAll(RegExp(r'[*\-•]'), '');

      for (final input in [
        '',
        'plain',
        '**bold**',
        'a **b** c **d** e',
        '*   bullet',
        '- x',
        '    * indented',
        'a **partial',
        '****',
        'a****b',
        '**a**b**c**',
        '*emphasis* stays',
        'line1\n*   line2\n**line3**',
        // The real device answer's opening, which is the input that matters most.
        '**Parts Check:**\nThe required part is the **BRK-990-XP**.\n*   Torx T20',
      ]) {
        expect(
          withoutMarkers(rendered(input)),
          withoutMarkers(input),
          reason: 'input: ${input.replaceAll('\n', r'\n')}',
        );
      }
    });

    // `****` is an empty run: consuming it would produce an invisible bold span, so
    // it is left literal. The first version of `_boldSpans` used one index for both
    // "emit from" and "search from" and dropped everything before such a run —
    // `a****b` rendered as `**b`. Bound here because the invariant test above would
    // have caught it only via this exact input.
    test('an empty ** run loses nothing', () {
      expect(rendered('a****b'), 'a****b');
      expect(rendered('****'), '****');
      expect(boldParts('a****b'), isEmpty);
    });

    // **The invariant above strips `-` from both sides, so it cannot see a hyphen
    // being eaten inside a bullet's content** — review finding R1-F5 measured that:
    // making the bullet rewrite delete every `-` from the rest of the line survived
    // the whole suite, and a SKU is `BRK-990-XP`. This case preserves markers, so it
    // is the one that would catch it.
    test('a hyphen inside a bullet line survives the rewrite', () {
      expect(
        rendered('*   BRK-990-XP, 2 in stock'),
        '•   BRK-990-XP, 2 in stock',
      );
      // Only the *leading* marker is rewritten; a later `- ` is content.
      expect(rendered('*   a - b'), '•   a - b');
      expect(rendered('- BRK-990-XP'), '• BRK-990-XP');
    });

    test('empty input yields one empty span rather than no spans', () {
      final spans = answerSpans('');

      expect(spans, hasLength(1));
      expect((spans.single as TextSpan).text, isEmpty);
    });
  });
}
