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

/// Shortest run of digit words that is treated as a number.
///
/// **Two, and it is the same floor Task 1.4 chose for the same reason.**
/// `faultCodePattern` requires `\d{2,4}` because a one- or two-letter word
/// followed by a *single* digit is overwhelmingly prose — "torque to 8 Nm" is the
/// example that file records. Here the equivalent hazard is one step earlier and
/// much more likely: `ONE`, `TWO`, `FOUR` and `O` are ordinary English words, and
/// rewriting "one of the guide shoes is loose" into "1 of the guide shoes"
/// would corrupt the inquiry that the whole retrieval path then runs on.
///
/// A run of two or more is not prose. English says "one oh two" only when
/// spelling something out.
const int minimumDigitRun = 2;

/// Rewrites runs of spoken digit words in [transcript] as digit strings.
///
/// Runs shorter than [minimumDigitRun] are left as words. Everything that is not a
/// digit word — including the whitespace between tokens — is preserved verbatim,
/// so the result is the recogniser's transcript with substitutions applied rather
/// than a re-rendering of it.
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
        run.add(candidate);
        scan++;
        continue;
      }
      if (!_isDigitWord(candidate)) break;
      run.add(candidate);
      scan++;
    }

    final digitWords = run.where((t) => t.isWord).toList();
    if (digitWords.length >= minimumDigitRun) {
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
    if (buffering == null) return;
    tokens.add(_Token(buffer.toString(), isWord: buffering!));
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
