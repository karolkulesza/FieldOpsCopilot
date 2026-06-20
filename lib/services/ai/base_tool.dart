/// The contract a Dart-native agent tool implements, and the typed result the
/// registry hands back for one tool call.
///
/// Task 1.5's job is the seam between two things that speak different languages: a
/// model that emits a *structured tool-call event* (`LlmToolCall` — a name plus a
/// JSON-decoded argument map, produced by weights and therefore untrusted), and a
/// Dart executor with a real signature. Everything in this file exists to make that
/// crossing explicit rather than implicit.
///
/// Two rules shape the design, and both come from the fact that the caller is a
/// model rather than a programmer:
///
/// * **A bad call is data, not an exception.** A hallucinated tool name, a missing
///   argument, a SKU that does not exist — these are ordinary outcomes of asking a
///   language model to call a function, and the agent loop (Task 1.9) recovers from
///   them by feeding the result back so the model can correct itself. So they are
///   [ToolFailure] values with a JSON payload, not thrown objects. Task 1.3 already
///   applied the same reasoning one layer down: `inventoryPartBySku` returns `null`
///   for an unknown SKU instead of throwing.
/// * **Everything that reaches the model is a payload, and payloads are curated.**
///   [ToolFailure.payload] carries a stable error key, the parameter at fault and a
///   message written for the model. It deliberately does **not** carry
///   [ToolFailure.cause] — an underlying `SqliteException` can quote file paths and
///   SQL, and this app's whole premise (§3.2) is that nothing sensitive leaves the
///   device boundary. The prompt is a boundary too.
library;

import '../../engines/llm_engine.dart';

/// A tool the on-device model may call, exposed to it as [definition] and executed
/// in Dart by [execute].
///
/// Not sealed and not `base`: `ToolRegistry` is tested with small purpose-built
/// tools (one that throws, one that takes no arguments), and future tools from the
/// spec's §2.2 list (`schedule_followup_appointment`,
/// `raise_safety_hazard_alert`) live outside this library.
abstract class AgentTool {
  const AgentTool();

  /// How the tool is declared to the model.
  ///
  /// Must be a plugin-native definition — `parameters` a JSON-Schema object, built
  /// with `objectSchema()`. `ToolRegistry`'s constructor enforces that with the same
  /// `assertToolDefinitionsUsable` both `LlmEngine` implementations run, so a
  /// registry that constructs cannot produce a definition the device rejects.
  ToolDefinition get definition;

  // There is deliberately **no `name` getter here.** An earlier version had one,
  // defaulting to `definition.name`, and `ToolRegistry` routed on it — which made the
  // "every declared tool is dispatchable" invariant depend on a subclass not
  // overriding a single getter, on a class this very docstring says is left open for
  // subclassing. Override it and the tool is declared under one name and routed under
  // another: permanently `unknown_tool` (review finding R0-F2, demonstrated with a
  // probe). Rather than check that the two names agree, the second one is gone: the
  // registry reads `definition.name` and nothing else — the only string the model is
  // ever told. Callers that want the name ask for `tool.definition.name`.
  //
  // Stated precisely, because the loose version of this sentence is the same mistake
  // one layer along: a subclass can still define a `name` member of its own, and
  // nothing prevents it. What changed is that **the registry no longer consults one**,
  // so such a member cannot affect what is declared or what is dispatchable. That is
  // narrower than "divergence is impossible" and it is what the code actually buys.

  /// Runs the tool and returns the payload fed back to the model.
  ///
  /// [arguments] comes from the model. Read it through [ToolArguments] rather than
  /// indexing it directly: the map can be empty, hold `null`, or hold a value of the
  /// wrong JSON type, and [ToolArguments] turns each of those into a
  /// [ToolArgumentException] the registry renders as a [ToolFailure].
  ///
  /// The returned map must be JSON-encodable — the agent loop serialises it into the
  /// next turn's context. Throwing an [Exception] is allowed and becomes
  /// [ToolFailureCode.executionFailed]; throwing an [Error] is a defect and is
  /// deliberately *not* caught (see [ToolRegistry.dispatch]).
  Future<Map<String, Object?>> execute(Map<String, Object?> arguments);
}

/// Raised by [ToolArguments] when the model's argument map cannot supply a value.
///
/// Carries the parameter name because that is the one thing the model needs in order
/// to fix the call, and it is what TC-TOOL-FAIL-01 asserts.
class ToolArgumentException implements Exception {
  /// The argument was absent, `null`, or blank — the model supplied no value.
  const ToolArgumentException.missing({
    required this.parameter,
    required this.message,
  }) : code = ToolFailureCode.missingParameter;

  /// The argument was present but not of the declared type.
  const ToolArgumentException.invalid({
    required this.parameter,
    required this.message,
  }) : code = ToolFailureCode.invalidParameter;

  /// The argument at fault, e.g. `sku`.
  final String parameter;

  /// Always [ToolFailureCode.missingParameter] or
  /// [ToolFailureCode.invalidParameter].
  ///
  /// True by construction rather than by documentation: there are only the two named
  /// constructors above, so a caller cannot build one carrying
  /// [ToolFailureCode.unknownTool] and have `dispatch` faithfully report
  /// `error: unknown_tool` for a tool that plainly exists. (Raised as a non-blocking
  /// review note, which suggested an `assert`; an `assert` is compiled out in release
  /// and Task 1.4 already paid for that lesson, so the shape is closed instead.)
  final ToolFailureCode code;

  /// Written for the model: says what was wrong and what to send instead.
  final String message;

  @override
  String toString() => 'ToolArgumentException($parameter): $message';
}

/// Typed reader over the model's argument map.
///
/// A thin wrapper rather than a set of free functions so a tool with several
/// arguments reads as `final args = ToolArguments(arguments); args.requiredString(…)`.
class ToolArguments {
  const ToolArguments(this._raw);

  final Map<String, Object?> _raw;

  /// Reads [name] as a non-blank string, or throws [ToolArgumentException].
  ///
  /// Three inputs collapse to [ToolFailureCode.missingParameter] — the key absent, the
  /// key present holding `null`, and a string that is blank once trimmed. They are one
  /// code on purpose: from the model's side all three mean "you did not tell me which
  /// part", and the corrective action is identical. The *message* distinguishes them,
  /// so a human reading a transcript still knows which shape arrived.
  ///
  /// The blank case is the one worth defending, because it could plausibly have been
  /// routed to "not found" instead: `inventoryPartBySku('  ')` returns `null`, which
  /// would render as a normal empty-warehouse answer. That would be a lie about what
  /// happened — nothing was looked up — and it invites the model to tell a technician a
  /// part is unavailable when it never named one.
  ///
  /// A non-string value is [ToolFailureCode.invalidParameter] rather than being coerced
  /// with `toString()`. Coercion is tempting and wrong here: `{"sku": true}` would
  /// become a lookup for `TRUE`, which resolves to nothing and is indistinguishable
  /// from a real miss. Rejecting it names the actual problem, and the model gets the
  /// schema's type back in the message so it can retry. (Coercion is also unnecessary
  /// on the primary path: Gemma 4's constrained decoding is driven by this very
  /// schema.)
  String requiredString(String name) {
    if (!_raw.containsKey(name)) {
      throw ToolArgumentException.missing(
        parameter: name,
        message:
            'required argument "$name" was not provided; call the tool again '
            'with "$name" set to a string value',
      );
    }
    final value = _raw[name];
    if (value == null) {
      throw ToolArgumentException.missing(
        parameter: name,
        message:
            'required argument "$name" was null; call the tool again with '
            '"$name" set to a string value',
      );
    }
    if (value is! String) {
      throw ToolArgumentException.invalid(
        parameter: name,
        message:
            'argument "$name" must be a string, but a '
            '${value.runtimeType} was provided',
      );
    }
    if (value.trim().isEmpty) {
      throw ToolArgumentException.missing(
        parameter: name,
        message:
            'required argument "$name" was blank; call the tool again with '
            '"$name" set to a non-empty string value',
      );
    }
    return value;
  }
}

/// Why a tool call could not produce a result.
///
/// The wire names are what the model sees, so they are stable strings rather than
/// `Enum.name` — renaming a Dart enum value must not silently change the transcript
/// the golden suite (Task 1.10) snapshots.
enum ToolFailureCode {
  /// The model asked for a tool that is not registered — a hallucinated name, or a
  /// tool this build does not ship.
  unknownTool('unknown_tool'),

  /// A required argument was absent, `null`, or blank.
  missingParameter('missing_parameter'),

  /// An argument was present but not of the declared type.
  invalidParameter('invalid_parameter'),

  /// The executor threw an [Exception] — the call was well-formed but the work
  /// failed (a database error, say).
  executionFailed('execution_failed');

  const ToolFailureCode(this.wireName);

  /// The value that appears under `error` in [ToolFailure.payload].
  final String wireName;
}

/// The result of routing one [LlmToolCall] through `ToolRegistry`.
sealed class ToolOutcome {
  const ToolOutcome({required this.toolName});

  /// The tool the model asked for — echoed even when no such tool exists, so a
  /// transcript records what was attempted.
  final String toolName;

  /// The JSON-encodable map fed back into the model's next turn.
  Map<String, Object?> get payload;
}

/// A tool ran and produced [payload].
class ToolSuccess extends ToolOutcome {
  const ToolSuccess({required super.toolName, required this.payload});

  @override
  final Map<String, Object?> payload;

  @override
  String toString() => 'ToolSuccess($toolName, $payload)';
}

/// A tool call could not produce a result, for a reason the model may be able to fix.
class ToolFailure extends ToolOutcome {
  const ToolFailure({
    required super.toolName,
    required this.code,
    required this.message,
    this.parameter,
    this.cause,
  });

  final ToolFailureCode code;

  /// Written for the model, not for a log line.
  final String message;

  /// The argument at fault, when the failure is about one.
  final String? parameter;

  /// The underlying error, for logging and tests.
  ///
  /// **Never part of [payload].** It is the one field here that was not written with
  /// the model in mind, and an exception's `toString()` routinely quotes file paths,
  /// SQL and row values.
  final Object? cause;

  @override
  Map<String, Object?> get payload => {
    'error': code.wireName,
    if (parameter != null) 'parameter': parameter,
    'message': message,
  };

  @override
  String toString() =>
      'ToolFailure($toolName, ${code.wireName}'
      '${parameter == null ? '' : ', parameter: $parameter'}: $message)';
}
