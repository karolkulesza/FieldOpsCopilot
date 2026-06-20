/// Routes a structured tool-call event from the model to a Dart executor.
///
/// The registry owns two responsibilities that are easy to conflate:
///
/// 1. **Declaring** the tools to the model — [ToolRegistry.definitions] is what goes
///    into `LlmEngine.generate(tools: …)`, in plugin-native format.
/// 2. **Dispatching** what comes back — [ToolRegistry.dispatch] maps an
///    `LlmToolCall` to the matching [AgentTool] and returns a [ToolOutcome].
///
/// Keeping both on one object is what keeps the two halves from disagreeing — **so long
/// as `AgentTool.definition` is stable**: a tool the model was told about is a tool the
/// registry can execute, because the declaration and the dispatch key are the *same*
/// string, `definition.name`.
///
/// Both hedges are deliberate and each was earned. The sentence used to claim the halves
/// were impossible to disagree "by construction" while the dispatch key came from a
/// separate overridable getter — exactly how they *could* disagree (R0-F2). Removing that
/// getter fixed it, and then documenting the remaining hazard exposed that "impossible"
/// was still too strong: `_byName` is snapshotted here in the constructor while
/// [definitions] and [toolNames] re-read `tool.definition` on every access, so a
/// definition whose `name` changed between calls would diverge them, and nothing enforces
/// that it will not (R2-F2). See `AgentTool.definition`.
library;

import 'package:flutter/foundation.dart';

import '../../engines/llm_engine.dart';
import '../../engines/tool_schema.dart';
import 'base_tool.dart';

/// The set of tools the agent may use, and the router for calls to them.
class ToolRegistry {
  /// Builds a registry over [tools], rejecting an unusable set immediately.
  ///
  /// Validation happens **here**, at wiring time, rather than at the first
  /// `generate()` call. Task 1.8 established why that matters: neither consumer of a
  /// tool definition rejects a bad one. Gemma 4 hands the `parameters` map to a
  /// native template (with no Dart stack to read when it fails), and Gemma 3
  /// `jsonEncode`s it into the prompt verbatim — teaching the model a shape this
  /// registry cannot read, which surfaces two layers away as "the model is bad at
  /// tool calling".
  ///
  /// Throws [ToolSchemaException] for a malformed schema or a duplicated name, and
  /// that is deliberately unrecoverable: an agent whose registry is misdeclared has
  /// nothing useful to do, and the fault is in the wiring rather than in anything the
  /// model or the technician did.
  ToolRegistry(Iterable<AgentTool> tools)
    : _tools = List<AgentTool>.unmodifiable(tools) {
    // What is load-bearing here is *what the validator is handed*, not when it runs.
    // `definitions` is derived from `_tools`, so it still contains both of two tools
    // sharing a name and the duplicate check can fire. Handing it a name-keyed
    // collection instead — `{for (final t in _tools) t.definition.name: t}.values` —
    // collapses that pair into one entry and silently disarms the check. Making that
    // substitution kills exactly one test, 'rejects two tools registered under the
    // same name' — which is the evidence for this paragraph, stated inline because a
    // reader can act on it. (An earlier version cited a mutation id, `M4`, that lives
    // only in a review ledger deleted once the loop closes: a citation the reader
    // cannot follow. R1-F2.)
    //
    // The statement *order* below is NOT load-bearing, and an earlier version of this
    // comment claimed it was — in three documents, citing a regression guard that does
    // not exist. Building `_byName` first leaves every test green (review finding
    // R0-F1, reproduced before this correction was written). Validating first is only
    // a fail-before-you-build preference.
    assertToolDefinitionsUsable(definitions);

    // Keyed on `definition.name`: the same string `definitions` declares, and the only
    // one the model is ever told. This is the fix for R0-F2, and it is a deletion
    // rather than a check — `AgentTool` used to carry an overridable `name` getter that
    // the registry routed on, so a subclass overriding it was declared under one name
    // and dispatched under another. Removing it leaves no second name for the registry
    // to read, which is stronger than asserting two names agree. Precisely: a subclass
    // may still define its own `name` member, but nothing here consults one, so it
    // cannot affect declaration or dispatch. Pinned by
    // 'every declared name is dispatchable'.
    _byName = {for (final tool in _tools) tool.definition.name: tool};
  }

  final List<AgentTool> _tools;

  late final Map<String, AgentTool> _byName;

  /// The tool declarations to pass to `LlmEngine.generate`, in registration order.
  ///
  /// Order is preserved because it is the order the model is shown the tools in, and
  /// a reordering would change the prompt on the Gemma 3 textual path — which the
  /// golden suite (Task 1.10) snapshots.
  List<ToolDefinition> get definitions => [
    for (final tool in _tools) tool.definition,
  ];

  /// The registered tool names, in registration order.
  ///
  /// The **declared** names, so this list and [definitions] cannot disagree.
  List<String> get toolNames => [
    for (final tool in _tools) tool.definition.name,
  ];

  /// The tool registered under [name], or `null`.
  AgentTool? toolNamed(String name) => _byName[name];

  /// Executes [call] and returns its outcome.
  ///
  /// Never throws for anything the *model* did — an unknown tool name, a missing or
  /// mistyped argument and a failed lookup all come back as values, because the agent
  /// loop's recovery for each is the same: feed the payload back and let the model
  /// correct itself. A loop that had to catch exceptions here would be one `on Object`
  /// away from swallowing real defects.
  ///
  /// Which is exactly why the `catch` below is `on Exception` and not `on Object`.
  /// An [Error] — `StateError` from a closed database, a `TypeError`, a failed assert —
  /// means the *app* is broken, not the call, and reporting it to the model as
  /// `execution_failed` would hand it to something that will cheerfully paraphrase it
  /// to a technician and try again. Those propagate.
  ///
  /// Name matching is exact. On the primary path it has to be: Gemma 4's constrained
  /// decoding is driven by the declarations, so the name it emits comes from this
  /// registry. Anything else is a degraded-path question, and the degraded path is
  /// Task 1.6's guard — one place, not two.
  Future<ToolOutcome> dispatch(LlmToolCall call) async {
    final tool = _byName[call.name];
    if (tool == null) {
      return ToolFailure(
        toolName: call.name,
        code: ToolFailureCode.unknownTool,
        message:
            'no tool named "${call.name}" is registered; '
            'available tools: ${toolNames.join(', ')}',
      );
    }
    try {
      final payload = await tool.execute(call.arguments);
      return ToolSuccess(toolName: tool.definition.name, payload: payload);
    } on ToolArgumentException catch (error) {
      // Listed before `on Exception` because it implements it; Dart takes the first
      // matching clause, so the order is load-bearing rather than stylistic.
      return ToolFailure(
        toolName: tool.definition.name,
        code: error.code,
        message: error.message,
        parameter: error.parameter,
        cause: error,
      );
    } on Exception catch (error, stackTrace) {
      // The message the model sees says only that the lookup failed. `error` is kept
      // on the outcome and logged, but stays out of `payload` — see
      // [ToolFailure.cause].
      debugPrint(
        '[ToolRegistry] ${tool.definition.name} threw: $error\n$stackTrace',
      );
      return ToolFailure(
        toolName: tool.definition.name,
        code: ToolFailureCode.executionFailed,
        message:
            'the "${tool.definition.name}" tool could not complete; '
            'report that the local lookup failed rather than guessing a result',
        cause: error,
      );
    }
  }
}
