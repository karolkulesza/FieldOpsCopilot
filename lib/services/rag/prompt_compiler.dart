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
/// have the model treat it as verified content. [neutralizeMarkers] rewrites the
/// opening bracket of this compiler's own markers so a forged block cannot be
/// spelled. It is a boundary defence, not a general prompt-injection cure —
/// nothing stops a user from *asking* the model to ignore its instructions, and
/// nothing here should be described as if it did.
///
/// **Documents are capped.** Task 1.8 measured a ~400-token grounded prompt for
/// a single entry against a 2B-parameter model, and the router can return one
/// row per resolved code plus its full-text hits. [maxDocuments] is the prompt
/// budget, and it truncates from the *end* — so the code hits, which the router
/// puts first, are the last thing to be dropped.
class PromptCompiler {
  const PromptCompiler({this.maxDocuments = 2})
    : assert(
        maxDocuments > 0,
        'a prompt with no document block is not grounded',
      );

  /// Maximum manual entries embedded in one prompt. See the class doc for why
  /// this is a budget rather than a preference.
  final int maxDocuments;

  /// Opening line of the manual block. Kept as a constant because it is both
  /// the thing tests assert on and the thing [neutralizeMarkers] defends.
  static const String manualDocumentMarker = '[MANUAL DOCUMENT]';

  /// Opening line of the inquiry block.
  static const String userInquiryMarker = '[USER INQUIRY]';

  /// The two markers untrusted text must not be able to spell.
  ///
  /// Numbered manual headers (`[MANUAL DOCUMENT 1 of 2]`) are covered because
  /// the neutraliser matches the marker's *prefix*, not the whole literal.
  static const List<String> _markerPrefixes = [
    '[MANUAL DOCUMENT',
    '[USER INQUIRY',
  ];

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
    final documents = result.entries.take(maxDocuments).toList(growable: false);

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

  /// Rewrites the opening bracket of any of this compiler's section markers in
  /// [text], so untrusted input cannot forge a block boundary.
  ///
  /// Matching is case-insensitive because the markers are read by a language
  /// model, not a parser: `[manual document]` would be just as convincing to it
  /// as the upper-case form, so a case-sensitive guard would be a guard in name
  /// only.
  ///
  /// The replacement keeps the text readable — `(MANUAL DOCUMENT` — rather than
  /// deleting it, because the technician's words are evidence for the diagnosis
  /// and silently dropping them changes the question being asked. Only the
  /// bracket changes; the matched text keeps the casing the user typed.
  static String neutralizeMarkers(String text) {
    var out = text;
    for (final prefix in _markerPrefixes) {
      out = out.replaceAllMapped(
        RegExp(RegExp.escape(prefix), caseSensitive: false),
        (m) => '(${m[0]!.substring(1)}',
      );
    }
    return out;
  }

  static const String _preamble =
      'You are an offline Field Service Assistant.\n'
      'Based ONLY on the verified technical manual document below, answer the '
      "user's inquiry and formulate a repair plan.\n"
      'If parts are required, you MUST call the '
      '"get_local_parts_inventory(sku)" tool to check warehouse stock.';
}
