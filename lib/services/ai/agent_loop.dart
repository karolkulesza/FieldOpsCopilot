/// The agentic workflow: grounded prompt → model → tool call → tool result →
/// re-prompt → grounded answer.
///
/// Everything this loop needs already exists. Task 1.4 compiles the grounded
/// prompt, Task 1.5 declares the tools and dispatches what comes back, Task 1.6
/// guards the degraded path, and Task 1.8 proved the runtime emits structured
/// tool calls. What is left — and what this file owns — is the four decisions
/// none of them could make:
///
/// 1. **How a turn ends.** `LlmEngine.generate` is a *stateless single turn*
///    (Task 1.8): a fresh conversation per call, closed after. There is no
///    accumulated history to inherit, so the loop carries the conversation
///    itself, as text, by appending to the prompt it was given.
/// 2. **What a `GuardFailure` means.** Task 1.6 built [GuardFailureReason] "for
///    the loop to branch on" and deliberately did not decide the branch. It is
///    decided here, and the split is not the obvious one — see
///    [AgentLoop.run].
/// 3. **What bounds the loop.** Two bounds, doing different work: a hard turn
///    cap, and a repeat-call short circuit.
/// 4. **How the transcript is written into the next prompt** without letting
///    the model forge the loop's own markers. See [AgentLoop.continuationOf].
library;

import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../engines/llm_engine.dart';
import '../rag/prompt_compiler.dart';
import 'base_tool.dart';
import 'tool_call_guard.dart';
import 'tool_registry.dart';

/// Why [AgentLoop] stopped.
enum AgentStopReason {
  /// A turn asked for no tool and produced text. The normal ending.
  answered,

  /// A turn asked for no tool and produced nothing usable.
  ///
  /// Distinct from [answered] because the two need different things from the
  /// UI: one renders the model's words, the other has none to render and must
  /// say so rather than show a blank panel.
  emptyResponse,

  /// The turn cap stopped the loop while the model was still calling tools.
  iterationCapReached,
}

/// One tool call the loop actually acted on.
class AgentToolInvocation {
  const AgentToolInvocation({
    required this.call,
    required this.source,
    required this.outcome,
    this.renamedFrom,
    this.repeated = false,
  });

  /// The call as dispatched — the guard's resolved name, not necessarily the
  /// model's spelling. [renamedFrom] carries the spelling when they differ.
  final LlmToolCall call;

  /// Whether the call arrived as a native event or was recovered from text.
  final GuardSource source;

  /// What `ToolRegistry.dispatch` returned. For a [repeated] call this is the
  /// outcome recorded the first time, not a second execution.
  final ToolOutcome outcome;

  /// The name the model spelled, when the guard canonicalised it.
  final String? renamedFrom;

  /// Whether this call repeated one already made in the same run.
  final bool repeated;

  @override
  String toString() =>
      'AgentToolInvocation(${call.name}, ${call.arguments}, '
      'source: ${source.name}${repeated ? ', repeated' : ''} '
      '→ ${outcome.payload})';
}

/// Everything one model turn produced.
///
/// Kept as data rather than folded into the final answer because Task 1.10's
/// golden suite snapshots "prompt built, tools called, args, final-state
/// shape", and because the interesting failures of an agent loop are about
/// *which turn* did what.
class AgentTurn {
  const AgentTurn({
    required this.index,
    required this.prompt,
    required this.text,
    required this.invocations,
    required this.rejectedCalls,
    required this.textScannedForCall,
  });

  /// Zero-based turn number within the run.
  final int index;

  /// The exact prompt handed to `LlmEngine.generate` for this turn.
  final String prompt;

  /// The concatenated `LlmToken` text of this turn, unmodified.
  ///
  /// What the technician would have seen. The *echo* written into the next
  /// prompt is neutralised (see [AgentLoop.continuationOf]); this is not.
  final String text;

  /// Tool calls executed (or replayed) during this turn, in arrival order.
  final List<AgentToolInvocation> invocations;

  /// Call attempts the guard refused to turn into a call.
  ///
  /// Only ever the *specific* refusals. A plain-prose turn produces
  /// [GuardFailureReason.noToolCallFound], which is not a refusal at all — it
  /// means there was no call here — and never lands in this list.
  final List<GuardFailure> rejectedCalls;

  /// Whether the guard was asked to read this turn's **text** for a call —
  /// true exactly when the turn emitted no native tool-call event.
  ///
  /// Recorded rather than derived, and that distinction is review finding
  /// R1-F1. [AgentLoop.continuationOf] needs to know whether the turn's text
  /// was a *call attempt* or *commentary*, and the obvious proxy — "does any
  /// invocation have `GuardSource.text`" — is silently wrong for the turn where
  /// every text-path attempt was **refused**: [invocations] is then empty, so
  /// the proxy says "native" for a turn that was nothing but text. That is the
  /// case where getting it wrong costs most, because there is no `[TOOL CALL]`
  /// block beside the echo to show the model what the call should have looked
  /// like. The loop knows the answer directly (`nativeCalls.isEmpty`), so it
  /// carries it instead of inferring it.
  final bool textScannedForCall;

  /// Whether this turn asked the loop to do anything before answering.
  bool get requestedWork => invocations.isNotEmpty || rejectedCalls.isNotEmpty;
}

/// The outcome of one [AgentLoop.run].
class AgentRunResult {
  const AgentRunResult({
    required this.answer,
    required this.stopReason,
    required this.turns,
  });

  /// The technician-facing text.
  ///
  /// For [AgentStopReason.answered] this is the last turn's text, trimmed. For
  /// the other two it is a loop-authored fallback, because there is nothing
  /// truthful to show: see [AgentLoop.iterationCapMessage] and
  /// [AgentLoop.emptyResponseMessage].
  final String answer;

  final AgentStopReason stopReason;

  /// Every turn, in order. Never empty — the loop always runs at least one.
  final List<AgentTurn> turns;

  /// Whether the model, rather than a bound, ended the run.
  bool get isComplete => stopReason == AgentStopReason.answered;

  /// How many times `LlmEngine.generate` was called. The number
  /// TC-AGENT-LOOP-02 bounds.
  int get turnCount => turns.length;

  /// Every tool invocation across the run, in order.
  List<AgentToolInvocation> get invocations => [
    for (final turn in turns) ...turn.invocations,
  ];

  @override
  String toString() =>
      'AgentRunResult(${stopReason.name}, turns: $turnCount, '
      'tools: ${invocations.length})';
}

/// A single observable step of a run.
///
/// The stream exists for Task 1.11, which needs live tokens and a
/// "checking inventory…" indicator *while* the loop is still running, and for
/// Task 1.10, which snapshots the sequence. [AgentLoop.runToCompletion] is the
/// same thing drained.
sealed class AgentEvent {
  const AgentEvent();
}

/// A turn is about to be sent to the model.
final class AgentTurnStarted extends AgentEvent {
  const AgentTurnStarted({required this.index, required this.prompt});

  final int index;
  final String prompt;
}

/// A chunk of generated text, passed through unchanged and immediately.
final class AgentToken extends AgentEvent {
  const AgentToken(this.text);

  final String text;
}

/// A tool is about to run. Emitted *before* execution so the UI can show the
/// indicator while the query is in flight.
final class AgentToolCallStarted extends AgentEvent {
  const AgentToolCallStarted({
    required this.call,
    required this.source,
    required this.repeated,
  });

  final LlmToolCall call;
  final GuardSource source;

  /// A repeated call is still announced — the UI showing "checking inventory…"
  /// for a replayed result is honest about what the model asked for.
  final bool repeated;
}

/// A tool finished (or its recorded outcome was replayed).
final class AgentToolCallCompleted extends AgentEvent {
  const AgentToolCallCompleted(this.invocation);

  final AgentToolInvocation invocation;
}

/// The guard refused a call attempt. The loop will tell the model and continue.
final class AgentToolCallRejected extends AgentEvent {
  const AgentToolCallRejected(this.failure);

  final GuardFailure failure;
}

/// The run finished. Always the last event.
final class AgentCompleted extends AgentEvent {
  const AgentCompleted(this.result);

  final AgentRunResult result;
}

/// Drives a grounded prompt to a grounded answer, executing tools in between.
///
/// ```dart
/// final loop = AgentLoop(engine: engine, registry: registry);
/// final result = await loop.runToCompletion(compiler.compile(retrieved));
/// ```
///
/// The loop does **not** retrieve or compile. It is handed a finished prompt,
/// because the two halves fail differently and are worth being able to test
/// apart: retrieval is a database question with exact answers, and this is a
/// conversation-shaped question with fuzzy ones. Task 1.11 composes them.
class AgentLoop {
  /// Builds a loop over [engine] and [registry].
  ///
  /// **The guard is built from the registry and cannot be supplied.** Task 1.5
  /// deleted `AgentTool.name` because a second source for a tool's name is a
  /// second thing that can disagree with the first; the same argument applies
  /// one layer up. A guard constructed from some other list would canonicalise
  /// a near-miss to a name `dispatch` cannot route, turning a recoverable
  /// `unknown_tool` into a call to nothing. Exposed as [guard] so tests can
  /// read it, never so callers can replace it.
  AgentLoop({
    required this.engine,
    required this.registry,
    int maxTurns = defaultMaxTurns,
  }) : maxTurns = maxTurns < 1 ? 1 : maxTurns,
       guard = ToolCallGuard(registry.toolNames);

  /// Turn cap when none is given.
  ///
  /// Two turns is the shortest complete run — call a tool, then answer with the
  /// result — and a correction round costs one turn each, so four leaves room
  /// for **two** of them on top of the happy path. The first version of this
  /// sentence said "one", in three documents (review finding R0-F7); the
  /// arithmetic, not the number, was wrong.
  static const int defaultMaxTurns = 4;

  final LlmEngine engine;
  final ToolRegistry registry;

  /// Built from `registry.toolNames`. See the constructor.
  final ToolCallGuard guard;

  /// Hard upper bound on calls to `LlmEngine.generate` in one run.
  ///
  /// **Clamped to at least one, not asserted.** Task 1.4 paid for that lesson:
  /// an `assert` is compiled out in release, so it crashes the build where the
  /// mistake is cheap and permits it where it is expensive — and it makes the
  /// clamp unreachable from any debug test.
  final int maxTurns;

  /// Opening line of the echoed model turn.
  static const String assistantMarker = '[ASSISTANT]';

  /// Opening line of a tool call the loop made.
  static const String toolCallMarker = '[TOOL CALL]';

  /// Opening line of a tool's result.
  static const String toolResultMarker = '[TOOL RESULT]';

  /// Opening line of a call attempt the guard refused.
  static const String rejectedCallMarker = '[TOOL CALL REJECTED]';

  /// Opening line of the loop's instruction for the next turn.
  static const String continueMarker = '[CONTINUE]';

  /// What the model is told after at least one tool ran.
  static const String continueAfterResults =
      'The tool results above are the authoritative local warehouse data — '
      'they come from this device, not from your training. Use them together '
      'with the manual document to answer the technician now. Do not call a '
      'tool again with arguments already answered above.';

  /// What the model is told when every call attempt in the turn was refused.
  static const String continueAfterRejection =
      'That tool call could not be read. Either call the tool again with a '
      'tool name and JSON arguments, or answer the technician from the manual '
      'document alone. Do not state a stock level you were not given.';

  /// Shown when the turn cap stops the loop.
  ///
  /// It reports the failure and stops. Anything warmer would be a sentence
  /// about a diagnosis the loop does not have — which is the failure the whole
  /// grounding path exists to prevent, arriving from the app's side instead of
  /// the model's.
  static const String iterationCapMessage =
      'I could not finish this diagnosis. The assistant kept requesting '
      'warehouse lookups without producing an answer, so it was stopped. '
      'Check the manual entry and the parts inventory directly before '
      'proceeding.';

  /// Shown when a turn asked for no tool and produced no text.
  static const String emptyResponseMessage =
      'I could not produce an answer for this inquiry. Try rephrasing it, or '
      'enter the exact fault code shown on the controller.';

  /// Runs the loop, streaming each step as it happens.
  ///
  /// The stream is single-subscription and ends with exactly one
  /// [AgentCompleted]. Each turn is fully drained before the next begins —
  /// both engine implementations refuse an overlapping `generate`, and
  /// `FakeLlmEngine` holds its in-flight slot until *someone drains the
  /// stream*, so a loop that walked away from a turn would deadlock the next
  /// one.
  ///
  /// **How a turn is read**, in the order the checks run:
  ///
  /// * **Native tool-call events win.** If the turn emitted any, each goes
  ///   through `ToolCallGuard.inspectEvent` and the turn's text is *not*
  ///   scanned. Prose accompanying a native call is commentary, and scanning
  ///   it would let a model that both called a tool and quoted a JSON example
  ///   run the example.
  /// * **Otherwise the text is scanned** with `ToolCallGuard.inspectText`.
  /// * **A `GuardFailure` branches on its reason**, which is what Task 1.6
  ///   built [GuardFailureReason] for and deliberately left undecided:
  ///   [GuardFailureReason.noToolCallFound] means *there was no call here*, so
  ///   the turn is a plain answer and the run ends. Every other reason means
  ///   the model tried to call something and got it wrong, which is
  ///   recoverable — the message goes back and the loop continues. Getting
  ///   this backwards in either direction is a real failure: treating a
  ///   malformed call as an answer ships the model's half-finished sentence to
  ///   a technician, and treating prose as a malformed call spends the turn
  ///   budget arguing with a model that already answered.
  ///
  /// A turn that neither called a tool nor had a call refused ends the run.
  ///
  /// Two things deliberately propagate rather than being caught. An error on
  /// the engine's stream is not something the model can correct, so it is not
  /// fed back — it surfaces. And `jsonEncode` on a tool payload throws
  /// `JsonUnsupportedObjectError`, an **`Error`**: `AgentTool.execute`'s
  /// contract requires a JSON-encodable map precisely because this loop
  /// serialises it, so a violation is a defect in the app and propagates for
  /// the same reason `ToolRegistry.dispatch` lets an `Error` through.
  Stream<AgentEvent> run(String groundedPrompt) async* {
    if (!engine.isReady) {
      // An `Error`, not a fed-back failure: nothing the model or the technician
      // did causes this, and there is no turn to recover into.
      throw StateError(
        'AgentLoop.run called before the engine was initialized; '
        'await engine.initialize() first',
      );
    }

    final turns = <AgentTurn>[];
    // Canonical call key → the outcome recorded the first time it was seen.
    final seenCalls = <String, ToolOutcome>{};
    var prompt = groundedPrompt;

    for (var index = 0; index < maxTurns; index++) {
      yield AgentTurnStarted(index: index, prompt: prompt);

      final turnText = StringBuffer();
      final nativeCalls = <LlmToolCall>[];
      await for (final event in engine.generate(
        prompt: prompt,
        tools: registry.definitions,
      )) {
        switch (event) {
          case LlmToken(text: final chunk):
            turnText.write(chunk);
            yield AgentToken(chunk);
          case LlmToolCall():
            nativeCalls.add(event);
          case LlmDone():
            // Stream completion is what ends a turn; this event carries no
            // extra information at this layer and is consumed so it cannot be
            // mistaken for text.
            break;
        }
      }

      final results = nativeCalls.isNotEmpty
          ? [for (final call in nativeCalls) guard.inspectEvent(call)]
          : [guard.inspectText(turnText.toString())];

      final invocations = <AgentToolInvocation>[];
      final rejected = <GuardFailure>[];
      for (final result in results) {
        switch (result) {
          case GuardedCall(:final call, :final source, :final renamedFrom):
            final key = _callKey(call);
            final recorded = seenCalls[key];
            yield AgentToolCallStarted(
              call: call,
              source: source,
              repeated: recorded != null,
            );
            final outcome = recorded ?? await registry.dispatch(call);
            seenCalls[key] = outcome;
            final invocation = AgentToolInvocation(
              call: call,
              source: source,
              outcome: outcome,
              renamedFrom: renamedFrom,
              repeated: recorded != null,
            );
            invocations.add(invocation);
            yield AgentToolCallCompleted(invocation);
          case GuardFailure(:final reason)
              when reason == GuardFailureReason.noToolCallFound:
            break;
          case GuardFailure():
            rejected.add(result);
            yield AgentToolCallRejected(result);
        }
      }

      final turn = AgentTurn(
        index: index,
        prompt: prompt,
        text: turnText.toString(),
        invocations: List.unmodifiable(invocations),
        rejectedCalls: List.unmodifiable(rejected),
        textScannedForCall: nativeCalls.isEmpty,
      );
      turns.add(turn);

      if (!turn.requestedWork) {
        final answer = turn.text.trim();
        yield AgentCompleted(
          AgentRunResult(
            answer: answer.isEmpty ? emptyResponseMessage : answer,
            stopReason: answer.isEmpty
                ? AgentStopReason.emptyResponse
                : AgentStopReason.answered,
            turns: List.unmodifiable(turns),
          ),
        );
        return;
      }

      prompt = continuationOf(prompt, turn);
    }

    yield AgentCompleted(
      AgentRunResult(
        answer: iterationCapMessage,
        stopReason: AgentStopReason.iterationCapReached,
        turns: List.unmodifiable(turns),
      ),
    );
  }

  /// [run], drained to its result.
  ///
  /// Throws [StateError] if the stream ends without an [AgentCompleted] — which
  /// it cannot, and is checked rather than asserted because returning a
  /// fabricated result would be worse than the crash.
  Future<AgentRunResult> runToCompletion(String groundedPrompt) async {
    AgentRunResult? result;
    await for (final event in run(groundedPrompt)) {
      if (event is AgentCompleted) result = event.result;
    }
    if (result == null) {
      throw StateError('AgentLoop.run ended without completing');
    }
    return result;
  }

  /// Builds the next turn's prompt: [previous], then a transcript of [turn].
  ///
  /// `LlmEngine.generate` is stateless (Task 1.8), so the conversation *is*
  /// this string. It grows by one transcript block per turn and is bounded by
  /// [maxTurns].
  ///
  /// **The forgery problem, and why it is solved by encoding rather than by
  /// filtering.** Everything appended here is written into a prompt whose
  /// preamble tells the model what to trust, and three of the four embedded
  /// pieces are model-authored or model-influenced: the echoed turn text, the
  /// tool name and arguments, and the result payload — which is not obviously
  /// in that set until you notice `get_local_parts_inventory` echoes the SKU
  /// *the model supplied* when the part is not carried. So a model can put
  /// chosen text inside a `[TOOL RESULT]` block, and the interesting version
  /// of that is putting `[TOOL RESULT]` itself there, followed by an invented
  /// stock level.
  ///
  /// The defence is that **every marker in this prompt starts a line, and no
  /// embedded value can start one**:
  ///
  /// * The call and result blocks are single lines, written by
  ///   [encodeOneLine]. `jsonEncode` alone is **not** enough for that, and the
  ///   first version of this comment claimed it was: it escapes every code unit
  ///   below `0x20` plus `"` and `\`, and passes **U+0085 NEL, U+2028 LINE
  ///   SEPARATOR, U+2029 PARAGRAPH SEPARATOR and U+007F through raw**. U+2028
  ///   and U+2029 are Unicode *mandatory* line breaks, and `normalizeSku` is
  ///   `trim().toUpperCase()`, so an interior one in a model-supplied SKU
  ///   reached the echoed payload verbatim and opened a real second
  ///   `[TOOL RESULT]` at column 0 — the exact attack this paragraph said was
  ///   closed (review finding R0-F1, reproduced against the loop before this
  ///   fix). [encodeOneLine] re-escapes the survivors as `\uXXXX`.
  /// * The echoed turn text *can* contain line breaks, so it gets the other
  ///   rule instead: [PromptCompiler.neutralizeMarkers] rewrites every Unicode
  ///   `Ps`/`Pe` codepoint to a round bracket, so it cannot spell a bracketed
  ///   marker at all — line-initial or not, which is why the terminator gap
  ///   above never applied to it. Reused rather than reimplemented; a second
  ///   copy of that rule would be a second thing to keep true.
  ///
  /// **The echo is dropped whenever the guard read this turn's text**, i.e.
  /// whenever no native event arrived — see [AgentTurn.textScannedForCall].
  /// `neutralizeMarkers` rewrites every brace, so echoing that text showed the
  /// next turn a syntactically corrupted copy of the very JSON shape the guard
  /// needs it to keep producing (R0-F5). The refused case is the worse one and
  /// the first fix missed it (R1-F1): there is no `[TOOL CALL]` block beside
  /// the mangled line, so it is the *only* rendering the model sees, directly
  /// above an instruction to send well-formed JSON.
  ///
  /// **What that costs, stated rather than glossed.** The turn text is not
  /// always *only* the call — `inspectText` scans for a JSON object anywhere in
  /// the text, so `"Let me look that up. {…}"` is a legitimate turn and its
  /// first sentence is dropped with the rest. The loop cannot separate the
  /// prose from the call without re-deriving the guard's extent scan, and
  /// showing mangled JSON is worse than losing a sentence of preamble. The
  /// canonical `[TOOL CALL]` block carries what the next turn needs. (The
  /// earlier claim here — "on that path the turn text *is* the call" — was
  /// wider than `inspectText`'s own contract: R1-F2.)
  ///
  /// On the native path the echo is kept, because there it really is the
  /// reasoning that led to the call and the next turn is being asked to finish
  /// it.
  String continuationOf(String previous, AgentTurn turn) {
    final buffer = StringBuffer(previous)
      ..writeln()
      ..writeln();

    // See [AgentTurn.textScannedForCall]. Deriving this from the invocations'
    // `source` was R1-F1: it reads "native" for a turn whose only text-path
    // attempt was refused, which is the turn that can least afford it.
    final echo = turn.textScannedForCall
        ? ''
        : PromptCompiler.neutralizeMarkers(turn.text.trim());
    if (echo.isNotEmpty) {
      buffer
        ..writeln(assistantMarker)
        ..writeln(echo)
        ..writeln();
    }

    for (final invocation in turn.invocations) {
      buffer
        ..writeln(toolCallMarker)
        ..writeln(
          encodeOneLine({
            'tool': invocation.call.name,
            'arguments': invocation.call.arguments,
            if (invocation.repeated) 'repeated': true,
          }),
        )
        ..writeln(toolResultMarker)
        ..writeln(encodeOneLine(invocation.outcome.payload))
        ..writeln();
    }

    for (final failure in turn.rejectedCalls) {
      buffer
        ..writeln(rejectedCallMarker)
        // The message is one of the guard's own constants, so it is neither
        // model-authored nor able to quote the offending text back — the guard
        // is explicit about not doing that. Encoded anyway, for the same
        // single-line property as the blocks above.
        ..writeln(
          encodeOneLine({
            'error': 'malformed_tool_call',
            'message': failure.message,
          }),
        )
        ..writeln();
    }

    buffer
      ..writeln(continueMarker)
      ..write(
        turn.invocations.isNotEmpty
            ? continueAfterResults
            : continueAfterRejection,
      );

    return buffer.toString();
  }

  /// `jsonEncode(value)` with every line terminator it leaves raw re-escaped,
  /// so the result is guaranteed to be one line.
  ///
  /// Public for the same reason [PromptCompiler.neutralizeMarkers] is: the
  /// property it buys is asserted directly by a test, and routing that
  /// assertion through [continuationOf] would test the caller instead.
  ///
  /// The guarantee `jsonEncode` gives is narrower than "no line breaks", and
  /// the gap is the whole of review finding R0-F1. Measured on this toolchain
  /// (`jsonEncode({'k': 'a<c>b'})`): LF, CR, VT, FF and every other code unit
  /// below `0x20` come out escaped, while **U+0085, U+2028, U+2029 and U+007F
  /// come out raw**. Two of those are Unicode mandatory line breaks.
  ///
  /// Matched by general category rather than by listing those four codepoints,
  /// for the reason [PromptCompiler.neutralizeMarkers] gives one layer down: a
  /// list only covers what someone enumerated. `Cc` is every C0/C1 control
  /// (which subsumes U+0085 and U+007F), `Zl` is U+2028 and `Zp` is U+2029 —
  /// so the question asked is membership, not spelling. Applying it to the
  /// *whole* encoded string is safe because every structural character
  /// `jsonEncode` emits is printable ASCII, so anything this matches was
  /// necessarily inside a string literal.
  ///
  /// Re-escaped as `\uXXXX` rather than stripped or replaced with a space: that
  /// keeps the line valid JSON *and* lossless, so the model still sees what it
  /// sent — `jsonDecode` of the output equals the input map, which is asserted
  /// by a test rather than argued here.
  @visibleForTesting
  static String encodeOneLine(Object? value) =>
      jsonEncode(value).replaceAllMapped(
        _rawLineTerminators,
        (match) =>
            '\\u'
            '${match[0]!.codeUnitAt(0).toRadixString(16).padLeft(4, '0')}',
      );

  /// Every control, line separator and paragraph separator — the categories
  /// that contain what `jsonEncode` leaves raw. See [encodeOneLine].
  static final RegExp _rawLineTerminators = RegExp(
    r'[\p{Cc}\p{Zl}\p{Zp}]',
    unicode: true,
  );

  /// Canonical identity of a call, for the repeat short circuit.
  ///
  /// **What this bound is for.** The turn cap already stops an infinite run, so
  /// this is not what makes the loop terminate. It stops a model that asks the
  /// same question twice from spending a turn each time it is answered, and it
  /// keeps the second answer *identical* to the first — a replay cannot
  /// disagree with what the model was already told, which a re-execution could
  /// if a tool were not a pure read. It is scoped to one run and nothing
  /// persists between runs.
  ///
  /// **It caches failures too, including `execution_failed`**, and that is
  /// worth saying out loud because Task 1.5's `dispatch` describes the loop's
  /// recovery as feeding the payload back "so the model can correct itself".
  /// For an identical call there is nothing left to correct: the same arguments
  /// against the same local database produce the same error, so a retry would
  /// spend a turn out of a four-turn budget to be told the same thing. What the
  /// model *can* still do is call with different arguments, or answer without
  /// the tool — both of which stay open, because a different call is a
  /// different key. Recorded rather than left implicit by this method's own
  /// standard, and pinned by a test (review finding R0-F6).
  ///
  /// Top-level argument keys are sorted so the same call written in a different
  /// key order is one call. Nested maps are left as they are: a nested map
  /// reordered between turns reads as a different call and costs one extra
  /// execution, which is a wasted query rather than a wrong answer. Stated
  /// because the loose version of this sentence — "arguments are canonical" —
  /// would be false.
  ///
  /// `jsonEncode` cannot throw here: only a `GuardedCall` reaches this method,
  /// and the guard runs a structural encodability probe on the arguments of
  /// **both** its paths before returning one (`tool_call_guard.dart`'s
  /// `_isJsonEncodable`, which is the fix for its R0-F1).
  static String _callKey(LlmToolCall call) => jsonEncode({
    'tool': call.name,
    'arguments': SplayTreeMap<String, Object?>.of(call.arguments),
  });
}
