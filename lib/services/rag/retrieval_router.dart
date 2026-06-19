import '../database/database_service.dart';
import '../database/fts_query_sanitizer.dart';
import '../database/tables/manual_fts_table.dart' show normalizeFaultCode;

/// Which retrieval legs produced the entries in a [RetrievalResult].
///
/// This is an observation about a completed retrieval, not a plan chosen up
/// front: both legs run whenever they have input, and the route records which
/// of them actually returned rows.
enum RetrievalRoute {
  /// Neither leg returned anything. The prompt compiler emits its no-match
  /// document block for this case.
  none,

  /// Only the exact fault-code lookup returned rows.
  code,

  /// Only the sanitized FTS5 search returned rows.
  fullText,

  /// Both legs returned rows; the code hits rank first.
  hybrid,
}

/// The outcome of routing one piece of raw technician text.
///
/// Everything the router decided is exposed rather than folded into
/// [entries], because the interesting failures of a hybrid router are about
/// *which leg* found a document — a test that only inspects the merged list
/// cannot tell a code hit from a full-text hit that happened to land on the
/// same row.
class RetrievalResult {
  const RetrievalResult({
    required this.rawQuery,
    required this.entries,
    required this.codeHitIds,
    required this.resolvedCodes,
    required this.unresolvedCodes,
    required this.searchedTerms,
  });

  /// The text the router was given, unmodified. The prompt compiler quotes this
  /// back to the model as the user inquiry.
  final String rawQuery;

  /// Merged, de-duplicated documents: code hits first in extraction order, then
  /// full-text hits in `bm25()` rank order, skipping ids already present.
  final List<ManualEntryRow> entries;

  /// Ids in [entries] that the exact code lookup produced. A document found by
  /// *both* legs is listed here — the code leg is what guarantees it.
  final Set<String> codeHitIds;

  /// Canonical fault codes extracted from [rawQuery] that matched a manual row,
  /// in extraction order.
  final List<String> resolvedCodes;

  /// Canonical fault codes extracted from [rawQuery] that matched nothing.
  ///
  /// Kept because the code pattern is deliberately loose (see
  /// [RetrievalRouter.faultCodePattern]) — `Torx T20` reads as a candidate — and
  /// the router's answer to a miss is to leave those words in the full-text
  /// residual rather than to swallow them. This field is how a caller or a test
  /// can see that happened.
  final List<String> unresolvedCodes;

  /// The residual terms actually handed to FTS5, after resolved codes were
  /// removed from the text. Empty when the query was nothing but a fault code —
  /// the case that would otherwise build an empty `MATCH` expression.
  final List<String> searchedTerms;

  /// Which legs produced rows.
  RetrievalRoute get route {
    final hasCode = codeHitIds.isNotEmpty;
    final hasFts = entries.length > codeHitIds.length;
    if (hasCode && hasFts) return RetrievalRoute.hybrid;
    if (hasCode) return RetrievalRoute.code;
    if (hasFts) return RetrievalRoute.fullText;
    return RetrievalRoute.none;
  }

  /// True when nothing was retrieved and the prompt must say so.
  bool get isEmpty => entries.isEmpty;

  /// Ids of [entries], in merged order — the shape most assertions want.
  List<String> get entryIds => entries.map((e) => e.id).toList(growable: false);
}

/// Routes raw technician text to the two retrieval mechanisms the database
/// offers, and merges the results.
///
/// The decision this class owns, which Task 1.2 built the seams for but nothing
/// made:
///
/// 1. **Extract fault codes** from the free text and look each one up on the
///    structured, indexed `manual_entries.code` column — exact match, never
///    FTS. `E-102` tokenizes into the junk token `e` plus the number `102`, so
///    full-text search both dilutes the index and loses the identifier.
/// 2. **Search what remains.** The spans of codes that *resolved* are cut out of
///    the text before it reaches [FtsQuerySanitizer]; what is left is sanitized
///    and matched. A query that was nothing but a fault code leaves no residual
///    term, and the FTS leg is skipped — an empty `MATCH` expression is an FTS5
///    syntax error, not an empty result.
/// 3. **Merge and de-duplicate**, code hits first. A document both legs found
///    appears once, in the code leg's position.
///
/// **A code that resolves is removed from the residual; a code that does not is
/// left in it.** That asymmetry is the whole reason the lookup happens before
/// the residual is built, and it is what makes the loose code pattern safe: a
/// false positive such as `Torx T20` costs one indexed lookup that returns
/// `null`, and the words stay searchable. Removing candidates unconditionally
/// would silently delete real search terms.
class RetrievalRouter {
  const RetrievalRouter(this._db, {this.ftsLimit = 5, this.maxCodes = 4});

  final DatabaseService _db;

  /// Upper bound on full-text hits. The merged list can hold one more row per
  /// resolved code on top of this.
  final int ftsLimit;

  /// Upper bound on distinct code candidates looked up, so a paragraph full of
  /// numbers cannot turn one query into dozens of round-trips. Candidates past
  /// the cap are simply never extracted, so their words stay in the residual and
  /// remain searchable.
  final int maxCodes;

  /// Candidate fault codes in free text.
  ///
  /// Matches one or two letters, an optional separator (space, ASCII hyphen or
  /// a Unicode dash), then two to four digits: `E-102`, `E102`, `e 102`,
  /// `E–102`. Deliberately looser than the corpus's own `E-\d{3}` convention,
  /// because the text arriving here is typed with one thumb or (from Tier 2)
  /// dictated, and a code written `E 102` must still reach the structured
  /// column.
  ///
  /// Looseness is affordable **only** because every candidate is verified by
  /// lookup before it changes anything — see the class doc. Two exclusions are
  /// worth stating because they are load-bearing rather than incidental: the
  /// leading word boundary plus the mandatory one-or-two-letter prefix means a
  /// digit run without one (`10mm`, `0.5mm`, `Aisle 4`) is not a candidate, and
  /// requiring at least two digits keeps `breaker 4A` out.
  static final RegExp faultCodePattern = RegExp(
    r'\b([A-Za-z]{1,2})[\s‐-―-]?(\d{2,4})\b',
  );

  /// Retrieves grounding documents for [rawText].
  Future<RetrievalResult> retrieve(String rawText) async {
    final candidates = _extractCandidates(rawText);

    final resolved = <String>[];
    final unresolved = <String>[];
    final codeHits = <ManualEntryRow>[];
    for (final entry in candidates.entries) {
      final row = await _db.manualEntryByCode(entry.key);
      if (row == null) {
        unresolved.add(entry.key);
        continue;
      }
      resolved.add(entry.key);
      codeHits.add(row);
    }

    final residual = _withoutSpans(
      rawText,
      resolved.expand((code) => candidates[code]!),
    );
    final terms = FtsQuerySanitizer.terms(residual);
    // `searchManualEntriesByTerms` carries the empty-expression guard, so this
    // stays correct even if `terms` is empty; the explicit branch is here so a
    // code-only query costs no query at all.
    final ftsHits = terms.isEmpty
        ? const <ManualEntryRow>[]
        : await _db.searchManualEntriesByTerms(terms, limit: ftsLimit);

    final merged = <ManualEntryRow>[];
    final seen = <String>{};
    for (final row in codeHits) {
      if (seen.add(row.id)) merged.add(row);
    }
    for (final row in ftsHits) {
      if (seen.add(row.id)) merged.add(row);
    }

    return RetrievalResult(
      rawQuery: rawText,
      entries: List.unmodifiable(merged),
      codeHitIds: Set.unmodifiable(codeHits.map((e) => e.id)),
      resolvedCodes: List.unmodifiable(resolved),
      unresolvedCodes: List.unmodifiable(unresolved),
      searchedTerms: List.unmodifiable(terms),
    );
  }

  /// Canonical code → every span in [raw] that produced it, in first-appearance
  /// order and capped at [maxCodes] distinct codes.
  ///
  /// All spans are kept, not just the first, so a code repeated in the text
  /// ("E-102 … still E-102") is cut out of the residual everywhere rather than
  /// leaving a stray copy behind for FTS to tokenize into `e` and `102`.
  Map<String, List<RegExpMatch>> _extractCandidates(String raw) {
    final byCode = <String, List<RegExpMatch>>{};
    for (final match in faultCodePattern.allMatches(raw)) {
      final canonical = normalizeFaultCode(
        '${match.group(1)!}-${match.group(2)!}',
      );
      final spans = byCode[canonical];
      if (spans != null) {
        spans.add(match);
      } else {
        if (byCode.length == maxCodes) continue;
        byCode[canonical] = [match];
      }
    }
    return byCode;
  }

  /// [raw] with every span in [spans] replaced by a single space.
  ///
  /// A space rather than nothing, so cutting the code out of `vibration,E-102on
  /// controller` cannot fuse two words into a term that matches neither.
  static String _withoutSpans(String raw, Iterable<RegExpMatch> spans) {
    final ordered = spans.toList()..sort((a, b) => a.start.compareTo(b.start));
    if (ordered.isEmpty) return raw;

    final buffer = StringBuffer();
    var cursor = 0;
    for (final span in ordered) {
      if (span.start < cursor) continue; // defensive: overlapping spans
      buffer
        ..write(raw.substring(cursor, span.start))
        ..write(' ');
      cursor = span.end;
    }
    buffer.write(raw.substring(cursor));
    return buffer.toString();
  }
}
