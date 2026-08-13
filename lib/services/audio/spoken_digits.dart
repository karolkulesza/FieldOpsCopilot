/// Turning spoken digit words back into digits.
///
/// **This exists because of a measurement, not a preference.** The pinned STT
/// model — `sherpa-onnx-streaming-zipformer-en-20M-2023-02-17` — ships a 502-entry
/// BPE vocabulary in which *no token contains a digit*; the only two entries with
/// digits in them are the `#0` and `#1` blank placeholders at ids 500 and 501. The
/// model therefore cannot emit the character `1` under any input. A technician
/// saying "E one oh two" is transcribed `E ONE OH TWO`, and it is not possible to
/// tune, prompt or configure that into `E-102`.
///
/// That is not a cosmetic problem. Task 1.4's [RetrievalRouter] is the reason this
/// app can answer about a fault code at all: it extracts codes from free text with
/// `faultCodePattern`, resolves each against the manual's indexed `code` column,
/// and puts those hits ahead of the full-text results. The pattern requires
/// **digits** (`\d{2,4}`). So without this step, every dictated inquiry would skip
/// the structured lookup entirely and fall through to full-text search — and it
/// would do so *silently*, returning a plausible answer grounded in whatever bm25
/// ranked first. Task 1.9's device run already recorded how reachable that failure
/// is: stop words match, so almost any English sentence is a full-text hit.
///
/// The scope is deliberately one job. Casing is left exactly as the recogniser
/// produced it (this model emits upper case with no punctuation), because nothing
/// downstream is case-sensitive — `faultCodePattern` accepts `[A-Za-z]`, the FTS5
/// index uses the `porter` tokenizer, and the fault `code` column is
/// `COLLATE NOCASE`. Changing case here would be a presentation decision taken in
/// the wrong layer, and one more thing to get wrong.
library;

/// Spoken forms this maps to digits.
///
/// `OH` and `O` both mean zero: read aloud, `E-102` is "E one oh two", and a
/// recogniser with no digits in its vocabulary has no other way to spell it. The
/// risk that the *letter* O is meant instead is handled by the run rule below
/// rather than by leaving `O` out — leaving it out would make the single most
/// common way to say this corpus's codes the one form that does not work.
const Map<String, String> spokenDigitWords = {
  'ZERO': '0',
  'OH': '0',
  'O': '0',
  'ONE': '1',
  'TWO': '2',
  'THREE': '3',
  'FOUR': '4',
  'FIVE': '5',
  'SIX': '6',
  'SEVEN': '7',
  'EIGHT': '8',
  'NINE': '9',
};

/// Shortest run of digit words that is treated as a number **on its own**.
///
/// **Three, raised from two by review finding R0-F3, and the earlier value came with
/// a false justification.** The comment here used to end "A run of two or more is not
/// prose. English says 'one oh two' only when spelling something out." The reviewer
/// ran the shipped function and refuted it in four inputs:
///
/// ```
/// OH TWO OF THEM ARE LOOSE   →  02 OF THEM ARE LOOSE
/// OH ONE MORE THING          →  01 MORE THING
/// NO ONE TWO WEEKS AGO       →  NO 12 WEEKS AGO
/// O ONE OF THE DOORS JAMMED  →  01 OF THE DOORS JAMMED
/// ```
///
/// And the harm was **worse than the one the floor was chosen to prevent**, not
/// milder. `faultCodePattern` is `\b([A-Za-z]{1,2})[\s…]?(\d{2,4})\b` — a *one or
/// two letter* prefix — so any short English word in front of a false-positive run
/// manufactures a code candidate: `IS O ONE OF THE GUIDE SHOES` → `IS-01`,
/// `NO ONE TWO WEEKS AGO` → `NO-12`. So the step written to stop a dictated inquiry
/// *silently skipping* the structured lookup was instead making it run that lookup on
/// a code nobody said. [minimumPrefixedDigitRun] is the other half of the fix.
///
/// Three is the corpus's own shape rather than a guess: every fault code in
/// `assets/elevator_manual_seed.json` is `E-\d{3}` (`E-102`, `E-204`, `E-305`), so a
/// spelled-out code is three digit words. It leaves the original hazard covered —
/// `ONE`, `TWO`, `FOUR` and `O` are ordinary English and "one of the guide shoes is
/// loose" must survive intact — while no longer inventing codes out of `OH TWO`.
const int minimumDigitRun = 3;

/// Shortest run accepted when a **single-letter** token immediately precedes it.
///
/// Two, so `B THREE FOUR` still reads as `B 34` — a two-digit code spelled out after
/// its designator, which `faultCodePattern`'s `\d{2,4}` accepts and which this corpus
/// could plausibly grow.
///
/// **One letter, not the one-or-two the router allows.** `NO`, `IS`, `AT`, `IN` and
/// `OF` are all two-letter English words, and it was a two-letter word in front of a
/// two-word run that produced `NO-12` and `IS-01`.
///
/// **What remains, stated at the width it has — review finding R1-F2.** An earlier
/// version of this paragraph described the residue as one artificial input ("the
/// counter-example is the article 'a', which is why `A ONE TWO` still becomes
/// `A 12`"). Measured, it is a *class*, and it is the approximation idiom of the
/// measurement register this app is actually used in — every one of these
/// manufactures a candidate that did not exist before normalisation:
///
/// ```
/// THERE WAS A FOUR FIVE SECOND DELAY  →  … A 45 SECOND DELAY    → A-45
/// I SAW A TWO THREE MILLIMETRE GAP    →  … A 23 MILLIMETRE GAP  → A-23
/// MOVE IT A ONE TWO INCHES            →  … A 12 INCHES          → A-12
/// I FOUR TWO                          →  I 42                   → I-42
/// ```
///
/// **`I` is a single-letter English word too**, and the earlier write-up named only
/// `A`. And the two-letter hazard above is closed only at run length **2** — raising
/// the floor did not close it at 3:
///
/// ```
/// NO ONE TWO THREE OF THEM WORK  →  NO 123 OF THEM WORK  → NO-123
/// IS O ONE TWO OF THE DOORS      →  IS 012 OF THE DOORS  → IS-012
/// ```
///
/// This is kept rather than chased, and the reason is a bound rather than a hope:
/// `RetrievalRouter` verifies every candidate by lookup, so one that resolves to no
/// row lands in `unresolved` and the text survives in the residual — the cost is a
/// wasted lookup, not a wrong answer. R0-F3's actual harm (a *silent* skip of the
/// structured lookup, and codes fabricated from bare `OH TWO`) is gone. What is not
/// acceptable is describing this as one funny input, so the cases above are pinned in
/// `spoken_digits_test.dart`'s residue group and a future narrowing cannot widen it
/// unnoticed.
const int minimumPrefixedDigitRun = 2;

/// Rewrites runs of spoken digit words in [transcript] as digit strings.
///
/// A run is rewritten when it is at least [minimumDigitRun] words long, or at least
/// [minimumPrefixedDigitRun] when a single-letter designator immediately precedes it.
/// Shorter runs are left as words.
///
/// Everything **outside an accepted run** is preserved verbatim, whitespace included,
/// so the result is the recogniser's transcript with substitutions applied rather than
/// a re-rendering of it. Inside an accepted run only whitespace separates the digit
/// words — a run stops at any other separator (review finding R0-F7), so there is
/// nothing else in it to lose.
///
/// ```
/// AN ERROR THE FALK CODE IS E ONE OH TWO PLEASE ADVISE
///                            → AN ERROR THE FALK CODE IS E 102 PLEASE ADVISE
/// ```
///
/// The `E 102` that comes out is deliberately **not** joined into `E-102`.
/// `faultCodePattern` already accepts an optional separator — `E-102`, `E102`,
/// `E 102` and `E–102` all canonicalise to the same code — so inserting a hyphen
/// would change how the transcript *reads* without changing what it *resolves to*.
/// `spoken_digits_test.dart` binds that claim by running the router's real pattern
/// over this function's real output rather than by asserting it here.
String normalizeSpokenDigits(String transcript) {
  if (transcript.isEmpty) return transcript;

  final tokens = _tokenize(transcript);
  final out = StringBuffer();

  /// Whether the last word emitted before [index] was a single letter.
  ///
  /// Walks back over separators only, so `E   ONE` counts and `E, ONE` does not —
  /// a comma between a designator and its digits is a list, not a code.
  bool precededBySingleLetter(int index) {
    for (var back = index - 1; back >= 0; back--) {
      final previous = tokens[back];
      if (previous.isWord) return previous.text.length == 1;
      if (previous.text.trim().isNotEmpty) return false;
    }
    return false;
  }

  var i = 0;
  while (i < tokens.length) {
    final token = tokens[i];
    if (!token.isWord) {
      out.write(token.text);
      i++;
      continue;
    }

    // Collect the maximal run of digit words starting here, remembering the
    // separators between them so a run that turns out to be too short can be
    // written back exactly as it arrived.
    final run = <_Token>[];
    var scan = i;
    while (scan < tokens.length) {
      final candidate = tokens[scan];
      if (!candidate.isWord) {
        // A separator only continues a run if a digit word follows it; trailing
        // whitespace belongs to whatever comes next.
        if (run.isEmpty) break;
        if (scan + 1 >= tokens.length) break;
        if (!_isDigitWord(tokens[scan + 1])) break;
        // **Whitespace only** — review finding R0-F7. A separator carrying anything
        // else is not whitespace between the digits of one number, and swallowing it
        // deleted content the doc promised to preserve: `ONE 5 TWO` became `12` and
        // `TWO. OH.` became `20.`. Ending the run here keeps "everything outside an
        // accepted run survives verbatim" true by making the run stop at the thing
        // that would otherwise be lost.
        if (candidate.text.trim().isNotEmpty) break;
        run.add(candidate);
        scan++;
        continue;
      }
      if (!_isDigitWord(candidate)) break;
      run.add(candidate);
      scan++;
    }

    final digitWords = run.where((t) => t.isWord).toList();
    final floor = precededBySingleLetter(i)
        ? minimumPrefixedDigitRun
        : minimumDigitRun;
    if (digitWords.length >= floor) {
      for (final word in digitWords) {
        out.write(spokenDigitWords[word.text.toUpperCase()]!);
      }
      i = scan;
    } else {
      // Too short to be a number: emit the run untouched, separators and all.
      // Emitting only `token` here would drop a `run` of length one that had
      // collected nothing else, which is the same thing — but writing the whole
      // run keeps the two branches symmetrical and makes the "verbatim" claim in
      // the doc true by construction rather than by a case analysis.
      for (final piece in run.isEmpty ? [token] : run) {
        out.write(piece.text);
      }
      i = run.isEmpty ? i + 1 : scan;
    }
  }

  return out.toString();
}

bool _isDigitWord(_Token token) =>
    token.isWord && spokenDigitWords.containsKey(token.text.toUpperCase());

/// Splits [text] into alternating word and non-word pieces, losing nothing.
///
/// "Word" is a run of letters. Everything else — spaces, punctuation, digits the
/// transcript somehow already contains — is a separator piece and is copied
/// through untouched. Concatenating every piece reproduces [text] exactly, which
/// is what lets the caller write a rejected run back verbatim.
List<_Token> _tokenize(String text) {
  final tokens = <_Token>[];
  final buffer = StringBuffer();
  bool? buffering;

  void flush() {
    final kind = buffering;
    if (kind == null) return;
    tokens.add(_Token(buffer.toString(), isWord: kind));
    buffer.clear();
  }

  for (final rune in text.runes) {
    final isLetter = _isLetter(rune);
    if (buffering != isLetter) {
      flush();
      buffering = isLetter;
    }
    buffer.writeCharCode(rune);
  }
  flush();
  return tokens;
}

/// ASCII letters only.
///
/// The vocabulary this runs over is 502 upper-case ASCII BPE pieces, so a
/// Unicode-aware letter test would be answering a question the input cannot ask.
/// Anything outside `A–Z` / `a–z` is a separator and survives untouched, which is
/// the behaviour that matters if this is ever pointed at a different model.
bool _isLetter(int rune) =>
    (rune >= 0x41 && rune <= 0x5A) || (rune >= 0x61 && rune <= 0x7A);

class _Token {
  const _Token(this.text, {required this.isWord});

  final String text;
  final bool isWord;
}
