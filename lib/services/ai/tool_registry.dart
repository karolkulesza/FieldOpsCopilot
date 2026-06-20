/// Routes a structured tool-call event from the model to a Dart executor.
///
/// The registry owns two responsibilities that are easy to conflate:
///
/// 1. **Declaring** the tools to the model — [ToolRegistry.definitions] is what goes
///    into `LlmEngine.generate(tools: …)`, in plugin-native format.
/// 2. **Dispatching** what comes back — [ToolRegistry.dispatch] maps an
///    `LlmToolCall` to the matching [AgentTool] and returns a [ToolOutcome].
///
/// Keeping both on one object is what makes the two halves impossible to disagree: a
/// tool the model was told about is, by construction, a tool the registry can execute.
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
    // Validate the *list*, not a name-keyed map built from it. Building the map first
    // would be the natural order and would quietly disarm the duplicate-name check:
    // `{for (final t in tools) t.name: t}` collapses two tools sharing a name into
    // one entry, so `assertToolDefinitionsUsable` would receive a set that can no
    // longer contain a duplicate and the check could never fire. Pinned by
    // 'rejects two tools registered under the same name'.
    assertToolDefinitionsUsable(definitions);
    _byName = {for (final tool in _tools) tool.name: tool};
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
  List<String> get toolNames => [for (final tool in _tools) tool.name];

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
      return ToolSuccess(toolName: tool.name, payload: payload);
    } on ToolArgumentException catch (error) {
      // Listed before `on Exception` because it implements it; Dart takes the first
      // matching clause, so the order is load-bearing rather than stylistic.
      return ToolFailure(
        toolName: tool.name,
        code: error.code,
        message: error.message,
        parameter: error.parameter,
        cause: error,
      );
    } on Exception catch (error, stackTrace) {
      // The message the model sees says only that the lookup failed. `error` is kept
      // on the outcome and logged, but stays out of `payload` — see
      // [ToolFailure.cause].
      debugPrint('[ToolRegistry] ${tool.name} threw: $error\n$stackTrace');
      return ToolFailure(
        toolName: tool.name,
        code: ToolFailureCode.executionFailed,
        message:
            'the "${tool.name}" tool could not complete; '
            'report that the local lookup failed rather than guessing a result',
        cause: error,
      );
    }
  }
}
