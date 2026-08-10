/// The smallest formatter that makes the model's answer readable on screen.
///
/// **Why this exists.** Task 1.11's deliverable is a screen recording, and the
/// answer was being rendered with a plain `Text`. Gemma 4 E2B emits Markdown
/// unprompted — the two device runs of TC-UI-DEMO-01 both returned an answer built
/// out of `**Diagnosis based on Manual:**`, `1.  **Isolate Power:**` and
/// `*   Torx T20 driver` — so the artefact showed the raw syntax. Review finding
/// R0-F5, and the acceptance test could not have caught it: it compares the
/// rendered `Text` against the same raw string, so it confirmed the asterisks
/// rather than noticing them.
///
/// **Why not the two obvious alternatives.**
///
/// * *A Markdown package.* `flutter_markdown` was discontinued in 2025, and pulling
///   a general CommonMark renderer in to handle bold spans and bullets would be a
///   dependency and a parser far larger than the input.
/// * *Telling the model to write plain prose.* That means editing
///   `PromptCompiler`'s preamble, which changes the prompt — and the prompt is what
///   Task 1.10's six committed goldens snapshot. Regenerating them needs
///   `test/golden/`, which exists only on that task's unmerged branch. So this fix
///   is deliberately in the **view** layer: it changes nothing any golden can see.
///
/// **The scope is deliberately narrow, and it was chosen by counting rather than
/// guessing.** Parsing the answer out of `device-run-2.log` and tallying it gives
/// **14 paired bold runs, 3 asterisk bullet
/// lines, 6 numbered lines and no unpaired delimiters** across 1401 characters. So [answerSpans] handles exactly two
/// constructs, and they are the two that account for all of it — the numbered lines
/// need nothing, because `1.  ` already reads as a list:
///
/// 1. `**bold**` inline, paired. An unpaired `**` is left literal — guessing where
///    the author meant it to close would invent emphasis.
/// 2. A leading `*` or `-` **followed by whitespace** becomes a `•` bullet. The
///    whitespace requirement is what keeps a line opening with `**bold**` from
///    being eaten as a bullet, and it is a property rather than a special case.
///
/// Everything else — headings, links, code fences, nested lists, `_italic_` — is
/// passed through verbatim. That is a decision, not an oversight: a half-implemented
/// renderer that silently drops a construct is worse than one that shows it, because
/// the dropped text is invisible.
///
/// The invariant that makes this safe, **stated at the width the test actually
/// asserts it** — review finding R1-F5: *no non-marker character is lost.* The test
/// deletes every `*`, `-` and `•` from both the input and the rendered output and
/// requires equality, so it is blind to *which* delimiters were consumed or
/// rewritten and sensitive only to text going missing.
///
/// The wider sentence this used to carry — "the input with paired `**` removed and
/// leading bullet markers rewritten, **and nothing else changed**" — does appear to
/// be true of the code, but it is not what any test says, and the gap is reachable:
/// making [_rewriteBullet] strip every `-` from the rest of a bullet line (so
/// `*   BRK-990-XP` renders as `•   BRK990XP`) survived the whole suite, because
/// hyphens are stripped from both sides of that comparison. There is now a
/// marker-preserving case for exactly that, so the narrower statement above is the
/// honest one *and* the hyphen hole is closed. Which delimiters get consumed is
/// bound by the per-construct tests rather than by the invariant.
library;

import 'package:flutter/painting.dart';

/// Splits [text] into spans, bolding paired `**…**` and bulleting `* ` / `- `.
///
/// Returns a single plain span for text containing neither, so the common case
/// costs one allocation.
List<InlineSpan> answerSpans(String text) {
  if (text.isEmpty) return const [TextSpan(text: '')];

  // Bullet rewriting is per line and has to happen before the inline scan, so a
  // bullet marker cannot be mistaken for the opening of an emphasis run.
  final normalized = text.split('\n').map(_rewriteBullet).join('\n');

  return _boldSpans(normalized);
}

/// `*   Torx T20` → `•   Torx T20`; `**Bold**` and `*emphasis*` are left alone.
///
/// The marker must be followed by whitespace. `**Diagnosis:**` therefore does not
/// match (the character after `*` is `*`), which is the whole reason this is a
/// pattern and not a list of prefixes.
String _rewriteBullet(String line) {
  final match = _bulletPattern.firstMatch(line);
  if (match == null) return line;
  // The captured indent is preserved so nested lists keep their shape even though
  // nothing here interprets the nesting.
  return '${match.group(1)}•${match.group(2)}${line.substring(match.end)}';
}

/// Leading indent, a `*` or `-`, then at least one space or tab.
final RegExp _bulletPattern = RegExp(r'^([ \t]*)[*-]([ \t]+)');

/// Splits on paired `**`, alternating plain and bold.
List<InlineSpan> _boldSpans(String text) {
  final spans = <InlineSpan>[];
  // Two indices, not one, and the distinction is load-bearing: [cursor] is the
  // start of text not yet emitted, while [searchFrom] is where to look for the
  // next delimiter. Collapsing them into one — which the first version of this
  // function did — silently drops the text before a `****` run, because skipping
  // the empty run also moved the emit point past it. `a****b` rendered as `**b`.
  var cursor = 0;
  var searchFrom = 0;

  while (true) {
    final open = text.indexOf('**', searchFrom);
    if (open < 0) break;
    final close = text.indexOf('**', open + 2);
    // Unpaired: everything from here is literal, including this `**`.
    if (close < 0) break;
    // `****` — an empty run. Emitting an empty bold span would be invisible while
    // still consuming the delimiters, so it is left literal: search past it
    // without moving the emit point.
    if (close == open + 2) {
      searchFrom = open + 2;
      continue;
    }

    if (open > cursor) {
      spans.add(TextSpan(text: text.substring(cursor, open)));
    }
    spans.add(
      TextSpan(
        text: text.substring(open + 2, close),
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
    );
    cursor = close + 2;
    searchFrom = cursor;
  }

  if (cursor < text.length) {
    spans.add(TextSpan(text: text.substring(cursor)));
  }
  return spans.isEmpty ? const [TextSpan(text: '')] : spans;
}
