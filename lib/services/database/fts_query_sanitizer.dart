/// Turns raw technician text into a safe FTS5 `MATCH` expression.
///
/// FTS5's query language is not a plain word list: bare `AND`/`OR`/`NOT`/`NEAR`
/// are operators, `(` `)` group, `"` quotes phrases, `*` is a prefix wildcard,
/// `:` binds a column filter and `-`/`^` carry meaning too. Feeding raw dictated
/// text such as `door won't close - "stuck" (E-305)` straight into `MATCH`
/// therefore doesn't just return the wrong rows — it raises
/// `SqliteException: fts5: syntax error near "..."` and takes the query down.
///
/// The sanitizer strips every character that could be syntax, wraps each
/// surviving term in a double-quoted phrase (so it can only ever be read as
/// text), and joins the terms with `OR`.
///
/// **Why `OR` and not `AND`:** field-service input is a noisy symptom
/// description, not a boolean query — `"squealing noise"` must still find the
/// squealing-belt entry even though the manual never says "noise". Recall comes
/// from `OR`; precision comes from ranking, because `bm25()` scores a row that
/// matches more terms (and matches them in the title) above a row that matches
/// one. Strict `AND` would turn a single unmatched word into zero results.
class FtsQuerySanitizer {
  const FtsQuerySanitizer._();

  /// Upper bound on terms forwarded to FTS5. A dictated paragraph would
  /// otherwise build a very large `OR` chain that scans most of the index; the
  /// leading terms carry the signal.
  static const int maxTerms = 24;

  /// Characters kept inside a term: any Unicode letter, digit or combining mark,
  /// plus the intra-word apostrophe and hyphen (`won't`, `E-305`,
  /// `lockout-tagout`). Everything else — quotes, parentheses, colons, asterisks,
  /// carets, commas — is dropped before it can be parsed as FTS5 syntax.
  ///
  /// Combining marks (`\p{M}`) are kept so decomposed or non-Latin text is not
  /// silently split into different tokens than the same word in composed form.
  static final RegExp _disallowed = RegExp(
    r"[^\p{L}\p{N}\p{M}'\-]+",
    unicode: true,
  );

  /// Trailing/leading punctuation left over once separators are stripped, e.g.
  /// the term `-` from a bare dash, or `close-` from `close - stuck`.
  static final RegExp _edgePunctuation = RegExp(r"^[-']+|[-']+$");

  /// True when a term still carries at least one letter or digit.
  static final RegExp _hasAlphanumeric = RegExp(r'[\p{L}\p{N}]', unicode: true);

  /// Converts [raw] into an FTS5 `MATCH` expression, or returns an empty string
  /// when [raw] holds no searchable term.
  ///
  /// An empty result **must not** be handed to `MATCH`: FTS5 rejects an empty
  /// query with a syntax error. Callers treat it as "no query" — see
  /// `DatabaseService.searchManualEntries`.
  static String sanitize(String raw) => sanitizeTerms(terms(raw));

  /// Extracts the sanitized, still-unquoted terms from [raw], in input order and
  /// capped at [maxTerms]. Exposed so the retrieval router (Task 1.4) can drop
  /// terms it has already handled — e.g. an extracted fault code — before
  /// building the expression with [sanitizeTerms].
  static List<String> terms(String raw) {
    final out = <String>[];
    for (final chunk in raw.split(_disallowed)) {
      final term = chunk.replaceAll(_edgePunctuation, '');
      if (term.isEmpty || !_hasAlphanumeric.hasMatch(term)) continue;
      out.add(term);
      if (out.length == maxTerms) break;
    }
    return out;
  }

  /// Builds an `OR`-joined FTS5 expression from a list of terms.
  ///
  /// Each entry of [rawTerms] is put through [terms] first, so a caller-supplied
  /// list gets exactly the same treatment as raw text: syntax characters are
  /// stripped, a chunk with nothing searchable in it disappears entirely, and the
  /// [maxTerms] cap applies. That keeps this method safe for the retrieval router
  /// (Task 1.4) to call with terms it assembled itself, and it is idempotent on
  /// output from [terms] — re-normalising an already-normalised term is a no-op.
  ///
  /// Each surviving term becomes a quoted phrase. Inside an FTS5 string literal
  /// the only special character is `"`, escaped by doubling it; normalisation
  /// already removes quotes, so the escape below is belt-and-braces.
  ///
  /// Returns an empty string when nothing searchable survives — see [sanitize]
  /// for why the caller must not pass that to `MATCH`.
  static String sanitizeTerms(Iterable<String> rawTerms) => rawTerms
      .expand(terms)
      .take(maxTerms)
      .map((t) => '"${t.replaceAll('"', '""')}"')
      .join(' OR ');
}
