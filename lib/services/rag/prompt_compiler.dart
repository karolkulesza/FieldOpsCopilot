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
/// **every bracket character** in the inquiry — every codepoint Unicode
/// classifies as opening or closing punctuation, not only `[` and `]` — to a
/// plain round one. `{`, `（`, `「` and the rest go the same way.
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
/// this paragraph both claimed more than the code did. Delimiters *outside*
/// those two categories are not rewritten, and they are a broader set than one
/// example suggests: bracket **pieces** and corner brackets (`⎡` U+23A1, `⌜`
/// U+231C), the quotation-class guillemets (`«` `»`), and plain `<` `>`. A
/// header written with no delimiter at all survives too. Each is pinned by a
/// test, which is where the boundary actually lives.
///
/// Those survivors are deliberately listed **without** their general-category
/// names. Round 3 carried `So` for U+23A1 through this doc, the README, a test
/// comment and a review turn before anyone ran `unicodedata` on it — it is `Sm`,
/// the same category as the `<` `>` in the same sentence. Nothing in the code
/// reads a category name; the rule asks one question, `Ps`/`Pe` membership, and
/// the test asserts the answer behaviourally. Four decorative facts had already
/// rotted once, so they are gone rather than corrected.
///
/// None of them is a homoglyph of `[`, which is the class that actually forges
/// *this* compiler's delimiters and is closed. The rest is the general
/// look-alike case — the same bucket as the disclaimer below, and not something
/// this function should be read as covering.
///
/// It is still a **block-boundary** defence and not a general prompt-injection
/// cure: nothing stops a user from simply *asking* the model to ignore its
/// instructions, and nothing here should be described as if it did.
///
/// **The inquiry's own quotes are escaped** ([escapeQuotes]), which is a
/// separate and much smaller property than the one above. It was not always
/// so: the inquiry used to be wrapped in *unescaped* quotes, which was safe
/// only while this block was the last thing in the prompt. Task 1.9's agent
/// loop appends tool-call and tool-result blocks after it, so it no longer is.
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
  ///
  /// **"Do not call any tool" was narrowed to the lookup by Task 2.3, and the
  /// sentence had to change because the *registry* did** — review finding R0-F6.
  /// When it was written there was one tool and the instruction meant "do not look
  /// up a part you have no SKU for", which is right: with no manual entry there is
  /// no part number to check, and a lookup would be the model inventing one. Adding
  /// `record_work_order_fields` silently widened it to "do not fill in the work
  /// order either" — on the one path where the technician's own words are the *only*
  /// source of work-order data, which is where auto-fill is worth most.
  ///
  /// The grounding rule is unchanged and is what the rest of the sentence carries:
  /// nothing may be invented. Recording a fault code the technician said out loud is
  /// not invention; it is the opposite.
  static const String noMatchNotice =
      'No matching entry was found in the local service manual for this '
      'inquiry.\n'
      'Do not invent a procedure, a part number, a tool or a fault code, and do '
      'not look up parts you have not been given a SKU for. You may still record '
      'what the technician told you. Tell the technician that the offline manual '
      'has no entry for this fault and ask for the exact fault code shown on the '
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

    // The inquiry is wrapped in double quotes and its own quotes are escaped, so
    // the quoted region cannot be closed early. This used to be unescaped, which
    // was tolerable *only* while this block was last — there was nothing after it
    // to break into. Task 1.9's agent loop appends `[TOOL CALL]` / `[TOOL RESULT]`
    // blocks after the whole compiled prompt for the second model turn, so this
    // block is no longer last, and the note left here for 1.9 ("this needs
    // escaping before it does") is discharged rather than inherited.
    buffer
      ..writeln(userInquiryMarker)
      ..write('"${escapeQuotes(neutralizeMarkers(result.rawQuery.trim()))}"');

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

  /// Escapes the two characters that can break out of a double-quoted region:
  /// the backslash and the double quote, in that order.
  ///
  /// Backslash first is not stylistic — escaping quotes first would leave the
  /// backslash this rule just emitted to be doubled by the second pass, so
  /// `a"b` would come out `a\\"b`, whose `\\` is an escaped backslash followed
  /// by a *live* quote. The order is pinned by a test rather than by this
  /// comment.
  ///
  /// The property it buys is checkable without enumerating inputs, which is
  /// what [neutralizeMarkers] learned to prefer: after this rewrite the only
  /// unescaped `"` in the inquiry block are the two delimiters the compiler
  /// itself wrote. A test asserts exactly that, by deleting every `\\`-escape
  /// pair from the block and counting what is left.
  ///
  /// It is not a second injection defence. [neutralizeMarkers] is what stops a
  /// bracketed section marker being forged; this stops a quote ending the
  /// quoted span early and leaving the rest of the technician's sentence
  /// sitting in the prompt as unquoted text.
  static String escapeQuotes(String text) =>
      text.replaceAll(r'\', r'\\').replaceAll('"', r'\"');

  /// Every codepoint Unicode gives General_Category `Ps` — `[`, `(`, `{`, and
  /// the fullwidth/CJK/mathematical bracket homoglyphs.
  static final RegExp _openingPunctuation = RegExp(r'\p{Ps}', unicode: true);

  /// The `Pe` counterpart.
  static final RegExp _closingPunctuation = RegExp(r'\p{Pe}', unicode: true);

  /// The standing instruction, ahead of the manual and the inquiry.
  ///
  /// **The second paragraph exists because the first one was measured on a device
  /// and the asymmetry it created was the whole failure.** With only the inventory
  /// sentence here, Gemma 4 E2B did exactly as told on a four-field inquiry: it
  /// called `get_local_parts_inventory`, wrote a correct grounded plan, left the
  /// work order at **0 of 4**, and closed with
  ///
  /// > *"If you require any further assistance or need to record the work order
  /// > fields, please let me know."*
  ///
  /// Which is the model behaving well. It knew the tool existed — the registry
  /// declares it and its schema describes it — and treated it as an offer, because
  /// nothing at this level had ever told it otherwise. One tool carried a `MUST`
  /// and the other carried a description. The turn budget was not the constraint
  /// (`AgentLoop.defaultMaxTurns` is 4, and one turn had been spent).
  ///
  /// So the rule this file now follows: **a tool the app depends on being called
  /// is named here, not only in its own schema.** A schema tells a model what a
  /// tool *is*; this tells it what the job *requires*. The last clause is aimed
  /// squarely at the sentence above — an offer to record is not a recording, and
  /// the technician never sees the prose version.
  ///
  /// The tool names are literals rather than references to
  /// `GetPartsInventoryTool.toolName` and `RecordWorkOrderFieldsTool.toolName`,
  /// which is a real cost and is bounded deliberately: `prompt_compiler.dart`
  /// belongs to the retrieval layer and importing the tool implementations would
  /// invert that dependency. `prompt_compiler_test.dart` asserts the two spellings
  /// agree with the registry instead, so a rename fails a test rather than
  /// silently instructing the model to call something that does not exist.
  static const String _preamble =
      'You are an offline Field Service Assistant.\n'
      'Based ONLY on the verified technical manual document below, answer the '
      "user's inquiry and formulate a repair plan.\n"
      'If parts are required, you MUST call the '
      '"get_local_parts_inventory(sku)" tool to check warehouse stock.\n'
      'You MUST also call the "record_work_order_fields" tool with every '
      'work-order field the technician has stated — the fault code, the '
      'replacement parts, the hours worked, the safety checkpoints — before you '
      'write your answer. Do not offer to record them and do not wait to be '
      'asked: the technician reads those fields on their form, never in your '
      'reply.';
}
