import '../database/database_service.dart';
import 'retrieval_router.dart';

/// Builds the grounded prompt the on-device model sees.
///
/// The layout is the one the product spec fixes in §5.2 — a system preamble,
/// a `[MANUAL DOCUMENT]` block carrying the retrieved manual text, and a
/// `[USER INQUIRY]` block carrying the technician's words. Those two markers are
/// the grounding contract: the preamble tells the model to answer *only* from
/// the document block, so the boundary between trusted manual text and
/// untrusted user text has to be legible in the string itself.
///
/// Three decisions are worth reading before changing anything here.
///
/// **The no-match block is a document, not an absence.** When retrieval finds
/// nothing the `[MANUAL DOCUMENT]` header still appears, followed by an explicit
/// statement that there is no entry and an instruction not to invent one.
/// Omitting the block entirely would leave a prompt whose preamble refers to a
/// document that is not there — which is precisely the shape that invites the
/// model to supply the missing content from its weights. That is the failure
/// this whole retrieval path exists to prevent.
///
/// **The user inquiry is untrusted and is neutralised.** Manual text comes from
/// the bundled, verified asset; the inquiry does not. A technician who types
/// (or, from Tier 2, dictates something transcribed as) `[MANUAL DOCUMENT]` can
/// otherwise open a second, fabricated document block inside the inquiry and
/// have the model treat it as verified content. [neutralizeMarkers] rewrites
/// **every square bracket** in the inquiry to a round one.
///
/// The blunt rule is deliberate and it replaces a narrower one that did not
/// hold. Matching the marker spellings — even case-insensitively — only excludes
/// the spellings someone enumerated: review round 0 broke the original with one
/// extra space (`[MANUAL  DOCUMENT]`), and a leading space, a tab and a newline
/// did the same. Widening the pattern to absorb whitespace would still have left
/// the zero-width and homoglyph variants, every one of which reads as the marker
/// to a language model — which is the same argument that already made the guard
/// case-insensitive. Removing the delimiter instead makes the property
/// structural rather than enumerative: **every character Unicode classifies as
/// opening or closing punctuation** (`\p{Ps}` / `\p{Pe}`) is rewritten, so the
/// only bracket characters an inquiry can contain are the plain round ones this
/// rule emits. No bracketed marker can be spelled inside it whatever its
/// spacing, casing, invisible characters, or bracket homoglyph — `［`, `【`,
/// `⟦`, `〔` are all `Ps` and all rewritten.
///
/// The residual is named rather than hidden, because the first two versions of
/// this paragraph both claimed more than the code did. A look-alike *outside*
/// those categories is not covered: `⎡` (U+23A1, a bracket **piece**, category
/// `So`) survives, and there is a test asserting that it does. So does a header
/// written with no brackets at all. Neither is a forgery of this compiler's
/// delimiters; both are the general look-alike case, which is the same bucket as
/// the disclaimer below.
///
/// It is still a **block-boundary** defence and not a general prompt-injection
/// cure: nothing stops a user from simply *asking* the model to ignore its
/// instructions, and nothing here should be described as if it did.
///
/// **Documents are capped.** Task 1.8 measured a ~400-token grounded prompt for
/// a single entry against a 2B-parameter model, and the router can return one
/// row per resolved code plus its full-text hits. [maxDocuments] is the prompt
/// budget, and it truncates from the *end* — so the code hits, which the router
/// puts first, are the last thing to be dropped.
class PromptCompiler {
  const PromptCompiler({this.maxDocuments = 2});

  /// Maximum manual entries embedded in one prompt. See the class doc for why
  /// this is a budget rather than a preference.
  ///
  /// Values below one are clamped to one by [compile] rather than rejected. The
  /// constructor used to `assert` instead, and review round 0 showed why that
  /// was the wrong mechanism: an `assert` is compiled out in release, so it
  /// crashed the build where the mistake is cheap and permitted the one where it
  /// is expensive. It also made the clamp unreachable from a debug test — a line
  /// no test could bind, which is the same defect class as the rest of that
  /// round. One mechanism, live in every build.
  final int maxDocuments;

  /// Opening line of the manual block. Kept as a constant because it is both
  /// the thing tests assert on and the thing [neutralizeMarkers] defends.
  static const String manualDocumentMarker = '[MANUAL DOCUMENT]';

  /// Opening line of the inquiry block.
  static const String userInquiryMarker = '[USER INQUIRY]';

  /// What the model is told when retrieval came back empty.
  static const String noMatchNotice =
      'No matching entry was found in the local service manual for this '
      'inquiry.\n'
      'Do not invent a procedure, a part number, a tool or a fault code, and do '
      'not call any tool. Tell the technician that the offline manual has no '
      'entry for this fault and ask for the exact fault code shown on the '
      'controller.';

  /// Compiles [result] into the grounded prompt string.
  String compile(RetrievalResult result) {
    // The cap is clamped to at least one, so the no-match branch below can only
    // be reached by a retrieval that genuinely found nothing. Without the clamp,
    // `maxDocuments: 0` empties the list *after* retrieval succeeded, and the
    // prompt then tells the model "No matching entry was found … do not call any
    // tool" about documents it did find.
    final documents = result.entries
        .take(maxDocuments < 1 ? 1 : maxDocuments)
        .toList(growable: false);

    final buffer = StringBuffer()
      ..writeln(_preamble)
      ..writeln();

    if (documents.isEmpty) {
      buffer
        ..writeln(manualDocumentMarker)
        ..writeln(noMatchNotice)
        ..writeln();
    } else {
      for (var i = 0; i < documents.length; i++) {
        buffer
          ..writeln(_documentHeader(i, documents.length))
          ..writeln(_renderDocument(documents[i]))
          ..writeln();
      }
    }

    // The inquiry is wrapped in unescaped double quotes, so a `"` in the
    // technician's text closes the quoted region early. That is tolerable only
    // because this block is **last** — there is nothing after it to break into,
    // and what remains is the general injection case disclaimed above. Task 1.9
    // appends tool results for a second model turn; if anything ever follows the
    // inquiry, this needs escaping before it does.
    buffer
      ..writeln(userInquiryMarker)
      ..write('"${neutralizeMarkers(result.rawQuery.trim())}"');

    return buffer.toString();
  }

  /// A single document's header. A lone document keeps the spec's exact
  /// `[MANUAL DOCUMENT]` line; several are numbered so the model can tell them
  /// apart and a reader can tell how many were withheld by [maxDocuments].
  String _documentHeader(int index, int total) => total == 1
      ? manualDocumentMarker
      : '[MANUAL DOCUMENT ${index + 1} of $total]';

  /// Renders one manual entry.
  ///
  /// Manual text is **not** neutralised, unlike the inquiry. That is correct only
  /// while the sole writer of `manual_entries` is the bundled asset that
  /// `SeedBundle.parse` validates — `DatabaseService.upsertManualEntries` is the
  /// trust boundary. A downloaded manual pack or an OTA content update would put
  /// attacker-influenced text on the trusted side of this method, and the
  /// asymmetry would have to be revisited rather than inherited.
  ///
  /// Field order follows the spec's example (title first, then the procedure and
  /// what it needs). `Required Parts` is emitted before `Required Tools` because
  /// the parts line is what the preamble's tool instruction acts on — Task 1.5's
  /// `get_local_parts_inventory` takes a SKU, and the SKU has to be the thing the
  /// model just read.
  ///
  /// Empty lists are written as `None` rather than omitted: a missing line is
  /// ambiguous between "this procedure needs no parts" and "the field was not
  /// included", and only one of those should stop the model calling the
  /// inventory tool.
  String _renderDocument(ManualEntryRow entry) {
    final lines = <String>[
      'Title: ${entry.title} (Code: ${entry.code})',
      'Section: ${entry.section}',
      'Symptoms: ${entry.symptoms}',
      'Procedure: ${entry.procedure}',
      'Required Parts: ${_list(entry.requiredPartsList)}',
      'Required Tools: ${_list(entry.requiredToolsList)}',
    ];
    return lines.join('\n');
  }

  static String _list(List<String> values) =>
      values.isEmpty ? 'None' : values.join(', ');

  /// Rewrites every Unicode opening/closing punctuation character in [text] to
  /// a round bracket, so untrusted input cannot spell a bracketed section
  /// marker.
  ///
  /// See the class doc for why this is a character rule rather than a match on
  /// the marker spellings, and for the residual it does *not* cover. The
  /// property this version has, and neither previous one did, is checkable
  /// without enumerating attacks: the output's only `Ps`/`Pe` characters are the
  /// `(` and `)` this rule emits.
  ///
  /// Matching on the general categories rather than a list of bracket codepoints
  /// is the same choice one level down. A curated list of homoglyphs would be
  /// exactly the enumeration this rewrite exists to stop relying on — the review
  /// round that produced it caught the previous version claiming to handle
  /// homoglyphs while knowing a single codepoint.
  ///
  /// Closers are rewritten too, not only openers: leaving `(MANUAL DOCUMENT]`
  /// puts mismatched punctuation in the middle of the technician's own sentence,
  /// which is noise the model has to spend attention on. The words themselves
  /// survive — they are evidence for the diagnosis, and dropping them would
  /// change the question being asked.
  static String neutralizeMarkers(String text) => text
      .replaceAll(_openingPunctuation, '(')
      .replaceAll(_closingPunctuation, ')');

  /// Every codepoint Unicode gives General_Category `Ps` — `[`, `(`, `{`, and
  /// the fullwidth/CJK/mathematical bracket homoglyphs.
  static final RegExp _openingPunctuation = RegExp(r'\p{Ps}', unicode: true);

  /// The `Pe` counterpart.
  static final RegExp _closingPunctuation = RegExp(r'\p{Pe}', unicode: true);

  static const String _preamble =
      'You are an offline Field Service Assistant.\n'
      'Based ONLY on the verified technical manual document below, answer the '
      "user's inquiry and formulate a repair plan.\n"
      'If parts are required, you MUST call the '
      '"get_local_parts_inventory(sku)" tool to check warehouse stock.';
}
