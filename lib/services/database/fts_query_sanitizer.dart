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

  /// Characters kept inside a term: any Unicode letter or digit, plus the
  /// intra-word apostrophe and hyphen (`won't`, `E-305`, `lockout-tagout`).
  /// Everything else — quotes, parentheses, colons, asterisks, carets, commas —
  /// is dropped before it can be parsed as FTS5 syntax.
  static final RegExp _disallowed = RegExp(r"[^\p{L}\p{N}'\-]+", unicode: true);

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

  /// Builds an `OR`-joined FTS5 expression from already-extracted [terms].
  ///
  /// Each term becomes a quoted phrase. Inside an FTS5 string literal the only
  /// special character is `"`, escaped by doubling it; [terms] never produces
  /// one, but the escape is applied anyway so a hand-built term list cannot
  /// inject syntax.
  static String sanitizeTerms(Iterable<String> terms) => terms
      .where((t) => t.isNotEmpty)
      .map((t) => '"${t.replaceAll('"', '""')}"')
      .join(' OR ');
}
