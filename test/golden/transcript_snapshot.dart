/// Turns one `AgentLoop` run into the canonical JSON text a golden file holds.
///
/// The golden suite's whole value depends on this file being **boring**: the same run
/// must produce byte-identical text every time, or the goldens become a source
/// of noise and get deleted. Four rules make that true, and each one is a
/// decision rather than a formatting preference:
///
/// 1. **Multi-line strings are stored as arrays of lines.** Measured over the six
///    committed goldens, a one-document grounded prompt is **933 characters over
///    14 lines** (620 over 10 for the no-match block), and the widest prompt in
///    the suite — `recovery_ladder`'s fourth turn — is **2363 characters**. As a
///    single JSON string any of those is one enormous escaped line, and a
///    one-word change to the preamble produces a diff nobody can read — which
///    would fail TC-GOLD-02's actual requirement ("a readable diff"), not just
///    its letter. Split on `\n`, which is lossless (`lines.join('\n') ==
///    original`, asserted in `golden_harness_test.dart`). The rule is applied to
///    exactly the three strings the loop assembles from parts — the prompt, the
///    turn text and the answer.
///
///    The figures are this suite's own. An earlier version of this paragraph said
///    "~1600 characters over ~15 lines", which is the agent-loop suite's
///    measurement for a **two**-document prompt — and no scenario here retrieves
///    two documents, so it described nothing in this suite. The argument
///    survives at 933 characters; the number had to be the measured one.
/// 2. **The file is 7-bit ASCII.** `jsonEncode` passes U+0085, U+2028, U+2029 and
///    U+007F through raw (measured, not assumed), and U+2028/U+2029 are
///    Unicode *mandatory* line breaks — so a golden could contain a character
///    that some editors, viewers and diff tools treat as a newline while this
///    harness's own line count does not. [encodeSnapshot] re-escapes every
///    non-printable-ASCII code unit as `\uXXXX`, leaving the file valid JSON,
///    lossless, and impossible to mangle in transit.
/// 3. **Nothing environmental is recorded.** No timestamps, no temp directory
///    paths, no durations, no hash codes. In particular `ToolFailure.cause` is
///    deliberately absent: a `SqliteException`'s `toString()` quotes the
///    database file path, which is a fresh temp directory on every run. That it
///    is *also* the boundary rule `base_tool.dart` states for the model-facing
///    payload is a happy coincidence, not the reason.
/// 4. **Unordered collections are sorted.** `RetrievalResult.codeHitIds` and
///    `ftsHitIds` are `Set<String>`. Today they are insertion-ordered
///    `LinkedHashSet`s, so iterating them *looks* stable; that is a property of
///    the implementation and not of the type, and a golden must not depend on
///    it.
///
/// **What this snapshot deliberately does not carry**, so no reader mistakes its
/// silence for coverage:
///
/// * **The `AgentTurnStarted` prompt.** It is byte-identical to the same turn's
///   `prompt`, and repeating 15 lines per turn to say so would triple the file.
///   That the two agree is a real property, so it is bound by a real test —
///   `llm_golden_test.dart`'s "every AgentTurnStarted prompt is the prompt the
///   turn recorded" — rather than by data.
/// * **Payloads on the event list.** `events` pins the *sequence* — that a tool
///   call is announced before it runs, that a rejection is reported, that
///   `AgentCompleted` is last. What each call carried is in `turns`, once.
/// * **Anything the fake does not produce.** A golden over the device engine
///   would be a flake generator, so every
///   scenario is scripted. These files therefore pin *the loop, the guard, the
///   registry, the retrieval and the prompt* — not the model.
library;

import 'dart:convert';

import 'package:field_ops_copilot/services/ai/agent_loop.dart';
import 'package:field_ops_copilot/services/ai/base_tool.dart';
import 'package:field_ops_copilot/services/ai/tool_call_guard.dart';
import 'package:field_ops_copilot/services/rag/retrieval_router.dart';

/// The structured snapshot of one run, ready for [encodeSnapshot].
///
/// [retrieval] is included because the prompt is only meaningful next to what
/// produced it: a golden that showed a changed `[MANUAL DOCUMENT]` block without
/// showing that the router stopped resolving the fault code would send a reader
/// looking in the compiler for a bug in the router.
Map<String, Object?> transcriptSnapshot({
  required String scenario,
  required RetrievalResult retrieval,
  required List<AgentEvent> events,
  required AgentRunResult result,
}) => {
  'scenario': scenario,
  'inquiry': retrieval.rawQuery,
  'retrieval': {
    'entryIds': retrieval.entryIds,
    'codeHitIds': sortedHits(retrieval.codeHitIds),
    'ftsHitIds': sortedHits(retrieval.ftsHitIds),
    'resolvedCodes': retrieval.resolvedCodes,
    'unresolvedCodes': retrieval.unresolvedCodes,
    'searchedTerms': retrieval.searchedTerms,
  },
  'result': {
    'stopReason': result.stopReason.name,
    'turnCount': result.turnCount,
    'isComplete': result.isComplete,
    'answer': lines(result.answer),
  },
  'turns': [for (final turn in result.turns) _turn(turn)],
  'events': [for (final event in events) _event(event)],
};

Map<String, Object?> _turn(AgentTurn turn) => {
  'index': turn.index,
  // The prompt *as sent*. For every turn after the first this is where the
  // neutralised echo of the previous turn appears — a golden must be explicit
  // about which copy of the model's words it holds, and the answer is: both,
  // in different places. This
  // field is the neutralised copy the model was shown; `text` below is what the
  // model actually said, unmodified. A regression in
  // `PromptCompiler.neutralizeMarkers` therefore shows up here and *only* here.
  'prompt': lines(turn.prompt),
  'text': lines(turn.text),
  'textScannedForCall': turn.textScannedForCall,
  'requestedWork': turn.requestedWork,
  'invocations': [for (final i in turn.invocations) _invocation(i)],
  'rejectedCalls': [for (final f in turn.rejectedCalls) _rejection(f)],
};

Map<String, Object?> _invocation(AgentToolInvocation invocation) => {
  'tool': invocation.call.name,
  'arguments': invocation.call.arguments,
  'source': invocation.source.name,
  'renamedFrom': invocation.renamedFrom,
  'repeated': invocation.repeated,
  'outcome': _outcome(invocation.outcome),
};

/// The outcome, without restating what [ToolOutcome.payload] already carries.
///
/// `ToolFailure.code`, `.message` and `.parameter` are all *derived into*
/// `payload` (`{error, parameter?, message}`), and `payload` is the thing that
/// reaches the model — so recording both would be two spellings of one fact,
/// free to disagree after a refactor. `kind` is not derivable and is kept: it is
/// the sealed type's identity, so a `ToolSuccess` carrying an error payload
/// would be visible here rather than plausible.
Map<String, Object?> _outcome(ToolOutcome outcome) => {
  'kind': switch (outcome) {
    ToolSuccess() => 'success',
    ToolFailure() => 'failure',
  },
  'toolName': outcome.toolName,
  'payload': outcome.payload,
};

Map<String, Object?> _rejection(GuardFailure failure) => {
  'reason': failure.reason.name,
  'message': failure.message,
};

/// One event: its kind, plus the minimum that makes the *sequence* legible.
///
/// Not "identity only", which is what this line first said and which the function
/// below contradicts: `AgentToken` carries the full token
/// text — three of `e102_native_tool_call`'s eight events are token text — and
/// `AgentToolCallStarted` carries the tool name, the guard source and the repeat
/// flag. What is actually omitted is the call's `arguments` and the outcome's
/// payload, both of which live in `turns` exactly once. See the library doc.
Map<String, Object?> _event(AgentEvent event) => switch (event) {
  AgentTurnStarted(:final index) => {'event': 'turnStarted', 'index': index},
  AgentToken(:final text) => {'event': 'token', 'text': text},
  AgentToolCallStarted(:final call, :final source, :final repeated) => {
    'event': 'toolCallStarted',
    'tool': call.name,
    'source': source.name,
    'repeated': repeated,
  },
  AgentToolCallCompleted(:final invocation) => {
    'event': 'toolCallCompleted',
    'tool': invocation.call.name,
    'outcome': invocation.outcome is ToolSuccess ? 'success' : 'failure',
  },
  AgentToolCallRejected(:final failure) => {
    'event': 'toolCallRejected',
    'reason': failure.reason.name,
  },
  AgentCompleted(:final result) => {
    'event': 'completed',
    'stopReason': result.stopReason.name,
  },
};

/// Splits [text] into the lines a golden stores it as.
///
/// Lossless by construction — `lines(s).join('\n') == s` for every string,
/// including the empty one, one that is only newlines, and one that ends in a
/// newline (which yields a trailing `''` element rather than dropping it).
/// Public because that property is asserted directly; routing the assertion
/// through [transcriptSnapshot] would test the caller.
List<String> lines(String text) => text.split('\n');

/// [values] in a defined order, for the `Set`-typed retrieval hits.
///
/// Public for the same reason [lines] is: what it buys is a property (a snapshot
/// cannot depend on `LinkedHashSet`'s insertion order), and no committed scenario
/// currently retrieves two hits in an order that differs from sorted — so this is
/// the only place the property can be bound. Bound by
/// `golden_harness_test.dart`'s 'set-typed retrieval hits are sorted, not
/// insertion-ordered', which builds the disagreeing case by hand.
List<String> sortedHits(Iterable<String> values) => values.toList()..sort();

/// The exact bytes a golden file holds: two-space-indented JSON, ASCII only,
/// one trailing newline.
///
/// The trailing newline is not cosmetic — without it every editor that adds one
/// on save turns a passing suite red, which is how a golden suite earns its
/// reputation for noise.
String encodeSnapshot(Map<String, Object?> snapshot) =>
    '${_asciiOnly(const JsonEncoder.withIndent('  ').convert(snapshot))}\n';

/// Re-escapes every code unit `JsonEncoder` left raw and outside printable
/// ASCII, so the encoded text is 7-bit clean.
///
/// **`\n` is excluded from the class on purpose, and that is load-bearing:** the
/// indented encoder emits real newlines *between* tokens, and escaping those
/// would collapse the whole file onto one line. It is safe to leave them out
/// because every other control character has already been escaped by
/// `jsonEncode` inside its string literal, so a surviving raw `\n` can only be
/// structural.
///
/// Applying this to the *whole* encoded document is safe for the same reason
/// `AgentLoop.encodeOneLine` gives one layer down: every structural character
/// `JsonEncoder` emits is printable ASCII, so anything this matches was
/// necessarily inside a string literal, where `\uXXXX` is valid and means the
/// same thing. A surrogate pair is escaped as its two units, which is likewise
/// exactly what JSON specifies.
String _asciiOnly(String json) => json.replaceAllMapped(
  RegExp(r'[^\n\x20-\x7E]'),
  (match) => '\\u${match[0]!.codeUnitAt(0).toRadixString(16).padLeft(4, '0')}',
);
