/// The degraded path into `ToolRegistry.dispatch`: a thin defensive layer between
/// whatever the model actually produced and a call the registry can route.
///
/// **Why this is small.** With native function calling the runtime hands the app a
/// structured `LlmToolCall` on the happy path — Task 1.8 verified that on the device,
/// so the v2 premise for this task ("coerce noisy model output into valid JSON") is
/// mostly gone. What is left is the degraded path, and it has exactly two shapes:
///
/// 1. a **native event that is malformed** — a name that is not usable, or an
///    argument map the next turn could not serialise; and
/// 2. a **call that arrived as text** — prose, a fenced code block, or a JSON blob,
///    because the weights emitted a tool call the chat template did not turn into
///    function-call tokens.
///
/// Extract-and-parse only. There is no bracket repair, no quote balancing and no
/// attempt to salvage truncated JSON: [_matchingBrace] finds the *extent* of a JSON
/// object and `jsonDecode` decides whether it is one. Anything that does not decode is
/// not a tool call, which is a cheaper answer than a wrong one.
///
/// **Where the responsibility line sits, and why it is here rather than in the
/// registry.** `ToolRegistry.dispatch` matches tool names **exactly**, deliberately:
/// on the primary path Gemma 4's constrained decoding is driven by the registry's own
/// declarations, so the name it emits came from the registry. Every lenient reading —
/// a near-miss spelling, a call wrapped in prose — lives here instead, so there is
/// **one** forgiving place rather than two.
///
/// The split that follows from that, and it is the load-bearing distinction in this
/// file: **a [GuardFailure] means "there is no tool call here", not "the tool does not
/// exist".** A name this guard cannot resolve is passed through *unchanged* so
/// `dispatch` answers `unknown_tool` — the registry already has a payload for that,
/// written for the model, and duplicating it here would give the same condition two
/// different reports depending on which layer noticed first.
library;

import 'dart:convert';

import '../../engines/llm_engine.dart';

/// Where a guarded call was recovered from.
enum GuardSource {
  /// The runtime delivered a structured `LlmToolCall` — the primary path.
  nativeEvent,

  /// The call was extracted from generated text — the degraded path.
  text,
}

/// Why the guard could not produce a call.
///
/// These are **not** wire strings. Unlike `ToolFailureCode`, nothing here is written
/// into a payload the model reads: [GuardFailure.message] is the model-facing text and
/// this enum is for the agent loop's own branching. Task 1.9 decides what a failure
/// *means* for a turn — feed the message back, or treat the turn as a plain answer —
/// and if it ever puts one of these names in a prompt it owns the stable mapping.
/// (A `wireName` here today would be decoration, and decoration rots.)
enum GuardFailureReason {
  /// The text carried nothing shaped like a tool call.
  ///
  /// The ordinary case, and usually not a problem: most model turns are prose.
  noToolCallFound,

  /// Something shaped like a call carried no usable tool name — absent, not a string,
  /// or blank once trimmed.
  emptyToolName,

  /// A call carried an `arguments` key that could not be read as a JSON object.
  ///
  /// Distinct from *absent* arguments, which are legitimate (a tool may take none).
  argumentsUnreadable,

  /// A native event's argument map holds a value `jsonEncode` would refuse.
  argumentsNotEncodable,
}

/// What the guard made of one candidate tool call.
sealed class GuardResult {
  const GuardResult();
}

/// A usable tool call, ready to hand to `ToolRegistry.dispatch`.
final class GuardedCall extends GuardResult {
  const GuardedCall({
    required this.call,
    required this.source,
    this.renamedFrom,
  });

  /// The call to dispatch.
  ///
  /// For a well-formed native event this is the **same instance** that came in — the
  /// guard rewrites nothing it does not have to (TC-GUARD-OK-01 asserts identity).
  final LlmToolCall call;

  /// Whether this came from a native event or out of generated text.
  final GuardSource source;

  /// The name as the model spelled it, when the guard canonicalised it; `null` when
  /// the name was already exact.
  ///
  /// Kept because a transcript should record what the model actually emitted, and
  /// because it lets a test assert *that* a rename happened without comparing strings
  /// to guess at it.
  final String? renamedFrom;

  @override
  String toString() =>
      'GuardedCall(${call.name}, ${call.arguments}, source: ${source.name}'
      '${renamedFrom == null ? '' : ', renamed from: $renamedFrom'})';
}

/// No tool call could be recovered.
///
/// The agent loop's contract for this is "treat the turn as carrying no tool call".
/// [message] is written for the model in case the loop chooses to say so out loud;
/// [reason] is what lets it choose.
final class GuardFailure extends GuardResult {
  const GuardFailure({required this.reason, required this.message});

  final GuardFailureReason reason;

  /// Written for the model, not for a log line — same rule as `ToolFailure.message`.
  /// It never quotes the offending text: a malformed call is model output, and echoing
  /// it back verbatim invites the model to repeat it.
  final String message;

  @override
  String toString() => 'GuardFailure(${reason.name}: $message)';
}

/// Turns whatever the model produced into a [GuardResult].
///
/// Construct it with the registry's declared names — `ToolCallGuard(registry.toolNames)`
/// — which is the only thing it needs from the registry, and the reason this file does
/// not import `tool_registry.dart`: the guard is a text-and-events problem and stays
/// testable without a database behind it.
///
/// An **empty** name list is legal and disables name resolution: every name is then
/// passed through as spelled, and an unmatched one comes back from `dispatch` as
/// `unknown_tool`. That is a real degradation, not a no-op, so it is stated rather
/// than defaulted — the constructor takes the list positionally so a caller cannot
/// omit it by accident.
class ToolCallGuard {
  ToolCallGuard(Iterable<String> knownToolNames)
    : knownToolNames = List<String>.unmodifiable(knownToolNames) {
    // Name resolution is a *property*, not a list of spellings to enumerate: two names
    // match when they are equal after dropping case and every non-alphanumeric
    // character. That is deliberately not fuzzy matching — no edit distance, no prefix
    // scoring — because the cost of guessing wrong is dispatching to the wrong tool,
    // which is worse than the `unknown_tool` the model can recover from.
    //
    // A collision under that normalisation is recorded as `null`, i.e. "ambiguous, do
    // not guess". `ToolRegistry` already rejects two tools with the *same* name, but
    // `get_parts` and `getParts` are two different names that normalise alike, and it
    // registers both quite happily.
    final byNormalised = <String, String?>{};
    for (final name in this.knownToolNames) {
      final key = _normalise(name);
      if (key.isEmpty) continue;
      byNormalised.update(
        key,
        (existing) => existing == name ? existing : null,
        ifAbsent: () => name,
      );
    }
    _byNormalised = Map<String, String?>.unmodifiable(byNormalised);
  }

  /// The names the guard may canonicalise a near-miss to, in registration order.
  final List<String> knownToolNames;

  /// Normalised name → the one known name it belongs to, or `null` when two known
  /// names share a normalised form.
  late final Map<String, String?> _byNormalised;

  /// Validates a native tool-call event.
  ///
  /// Returns the received [call] unchanged when it is already usable and exactly
  /// named. The two checks are ordered name-then-arguments so the diagnosis names the
  /// more fundamental problem first.
  GuardResult inspectEvent(LlmToolCall call) {
    final resolved = _resolveName(call.name);
    if (resolved == null) {
      return const GuardFailure(
        reason: GuardFailureReason.emptyToolName,
        message:
            'a tool call arrived with no tool name; call a tool by name or '
            'answer in plain text',
      );
    }
    // Only the native path needs this probe. Arguments recovered from text come out of
    // `jsonDecode`, so they are JSON-encodable by construction; a native event's map is
    // ordinary Dart `Object?` and nothing upstream constrains its values. No current
    // backend produces a bad one — the plugin's arguments are JSON-decoded too, and the
    // isolate wire's `decodeEvent` rejects a non-`Map` outright — but `decodeEvent`
    // checks only that the arguments *are* a map and never inspects the values, and
    // `FakeLlmEngine` scripts whatever a test hands it. What breaks downstream is Task
    // 1.9 putting the attempted call into the next turn's context: `jsonEncode` throws
    // `JsonUnsupportedObjectError`, an **`Error`**, which is not something the loop's
    // `on Exception` recovery catches.
    //
    // Checked structurally rather than by encoding-and-catching, for that same reason:
    // catching it would mean `on Error`, the shape Task 1.5 rejected on purpose.
    if (!_isJsonEncodable(call.arguments)) {
      return const GuardFailure(
        reason: GuardFailureReason.argumentsNotEncodable,
        message:
            'the arguments of that tool call could not be read; call the tool '
            'again with plain JSON values',
      );
    }
    if (resolved == call.name) {
      return GuardedCall(call: call, source: GuardSource.nativeEvent);
    }
    return GuardedCall(
      call: LlmToolCall(name: resolved, arguments: call.arguments),
      source: GuardSource.nativeEvent,
      renamedFrom: call.name,
    );
  }

  /// Recovers a tool call from generated [text].
  ///
  /// Scans for JSON objects and returns the **first usable** one, so prose before,
  /// after or between candidates is irrelevant and no wrapper syntax is enumerated: a
  /// fenced code block, an `<tool_call>` tag and a bare object all reduce to "there is
  /// a JSON object in here".
  ///
  /// One call per turn. A turn emitting two textual calls yields the first; parallel
  /// calls are a native-path feature (`llmEventsFor` already flattens
  /// `ParallelFunctionCallResponse` into separate events) and multiplexing them on the
  /// degraded path is Task 1.9's loop, not this guard's.
  ///
  /// **One residual, recorded rather than engineered around.** A model that echoes a
  /// tool *declaration* back as text — `{"name": …, "description": …, "parameters":
  /// {"type": "object", …}}` — reads as a call whose arguments are the JSON schema,
  /// because a declaration and a call share both key names. The guard does not try to
  /// tell them apart: the outcome is a `missing_parameter` from the registry, which is
  /// a recoverable turn, and the discriminators available (a `description` key, a
  /// `type: object` argument map) are exactly the enumerate-the-attack shape Task 1.4
  /// learned to avoid.
  ///
  /// When nothing is usable the *most specific* failure wins: a candidate that was
  /// clearly a call attempt but unusable ([GuardFailureReason.emptyToolName],
  /// [GuardFailureReason.argumentsUnreadable]) is reported ahead of the generic
  /// [GuardFailureReason.noToolCallFound], because "your call was malformed" and "you
  /// did not call anything" are different things to tell a model.
  GuardResult inspectText(String text) {
    GuardFailure? specific;
    for (final candidate in _jsonObjectCandidates(text)) {
      final object = _decodeObject(candidate);
      if (object == null) continue;
      final result = _callFromObject(object);
      if (result is GuardedCall) return result;
      if (result is GuardFailure &&
          result.reason != GuardFailureReason.noToolCallFound) {
        specific ??= result;
      }
    }
    return specific ?? _noCallFound;
  }

  /// Reads a decoded JSON object as a tool call.
  ///
  /// **Nested envelopes need no code here, and this is the second version of that
  /// sentence.** The OpenAI-shaped `{"type": "function", "function": {"name": …,
  /// "arguments": …}}` resolves because [_jsonObjectCandidates] starts a candidate at
  /// *every* `{` in the text, so the inner object is offered on its own after the outer
  /// one is rejected for having no name string. The first version of this method also
  /// recursed into any object found under a name key, and a mutation deleting that
  /// recursion killed **nothing** — the scan had been doing the work the whole time,
  /// while a test comment credited the recursion. It is deleted rather than kept and
  /// re-documented: unreachable leniency is machinery this task's brief rules out, and
  /// a second path to the same answer is a second thing to keep true.
  GuardResult _callFromObject(Map<String, Object?> object) {
    final rawName = _firstStringUnder(object, _nameKeys);
    if (rawName == null) {
      // No name-shaped key at all: this is some other JSON object that happened to be
      // in the text, not a malformed call. Deliberately *not* inferred from a
      // single-tool registry — a lone `{"sku": "BRK-990-XP"}` is data, and reading it
      // as a call would invent an intent the model did not express.
      return _noCallFound;
    }
    // Unlike a native event, a JSON object found in prose is not a tool call *by
    // construction* — it has to look like one, and the rule for that is: it names a
    // tool this build knows, or it is shaped like a call (a name **and** an arguments
    // key). Without it, `{"name": "Bob", "age": 3}` in an answer becomes a call to a
    // tool named `Bob`, and the loop reports a tool failure for a sentence.
    //
    // The second half of the disjunction is what keeps the "guard failures are not
    // unknown tools" rule intact: `{"tool": "invented_tool", "arguments": {}}` *is* a
    // call attempt, so it passes through under the name the model chose and `dispatch`
    // answers `unknown_tool` — the payload written for exactly that case.
    final hasArgumentsKey = _argumentKeys.any(object.containsKey);
    final resolved = _resolveName(rawName);
    if (resolved == null) {
      return hasArgumentsKey
          ? const GuardFailure(
              reason: GuardFailureReason.emptyToolName,
              message:
                  'that tool call named no tool; call a tool by name or answer '
                  'in plain text',
            )
          : _noCallFound;
    }
    if (!knownToolNames.contains(resolved) && !hasArgumentsKey) {
      return _noCallFound;
    }

    final arguments = _argumentsOf(object);
    if (arguments == null) {
      return const GuardFailure(
        reason: GuardFailureReason.argumentsUnreadable,
        message:
            'the arguments of that tool call were not a JSON object; call the '
            'tool again with arguments as a JSON object',
      );
    }

    return GuardedCall(
      call: LlmToolCall(name: resolved, arguments: arguments),
      source: GuardSource.text,
      renamedFrom: resolved == rawName ? null : rawName,
    );
  }

  /// The arguments carried by [object], or `null` when a present key is unreadable.
  ///
  /// The asymmetry here is deliberate, and it is Task 1.5's blank-SKU reasoning one
  /// layer up. **Absent** (or explicitly `null`) arguments become `{}`: a tool may
  /// legitimately take none, and for one that does not, `{}` reaches the registry as
  /// `missing_parameter` — an accurate report, since the model named no value.
  /// **Present but unreadable** is a failure instead of `{}`, because the model *did*
  /// supply something and answering "you supplied nothing" would describe a call that
  /// never happened.
  static Map<String, Object?>? _argumentsOf(Map<String, Object?> object) {
    for (final key in _argumentKeys) {
      if (!object.containsKey(key)) continue;
      final value = object[key];
      if (value == null) return const {};
      if (value is Map) return Map<String, Object?>.from(value);
      // A JSON *string* holding an object is the common serialised-arguments shape
      // (`"arguments": "{\"sku\": \"BRK-990-XP\"}"`), so it is decoded once. Once, not
      // repeatedly: a second pass would be repair machinery.
      if (value is String) return _decodeObject(value);
      // A list, number or bool: the model passed arguments in a shape this app has no
      // reading for. Positional arguments are not accepted — mapping `["BRK-990-XP"]`
      // onto `sku` would work only for single-parameter tools and would silently
      // mis-assign the moment a tool takes two.
      return null;
    }
    return const {};
  }

  /// The canonical form of [rawName], or `null` when it is unusable.
  ///
  /// Returns the trimmed name unchanged when nothing better is known — an unresolvable
  /// name is `dispatch`'s `unknown_tool` to report, not this guard's.
  String? _resolveName(String rawName) {
    final trimmed = rawName.trim();
    if (trimmed.isEmpty) return null;

    // Exactly two spellings are tried: the name as given, then its last dotted/scoped
    // segment. The second exists because a runtime that namespaces its tools emits
    // `functions.get_local_parts_inventory`, and normalisation alone will not strip a
    // prefix (it drops the separator but keeps `functions`).
    final segment = trimmed.split(_scopeSeparator).last.trim();
    final candidates = segment.isEmpty || segment == trimmed
        ? [trimmed]
        : [trimmed, segment];

    // **Candidate-major, and the order is load-bearing.** Each spelling is resolved
    // exactly, then by normalisation, before the *next* spelling is considered — so the
    // whole name always beats its own segment, and within one spelling an exact hit
    // beats a normalised one.
    //
    // The first version ran pass-major (both spellings exact, then both normalised),
    // which let a segment's exact match beat the whole name's normalised match: with
    // `getparts` and `parts` both registered, `get.parts` resolved to **`parts`** —
    // dispatching to a different tool than the one the model named. Found because a
    // mutation deleting the exact-match pass survived, and the test that was supposed to
    // bind that pass had been passing because of the *ambiguity* rule instead.
    for (final candidate in candidates) {
      if (knownToolNames.contains(candidate)) return candidate;
      final match = _byNormalised[_normalise(candidate)];
      if (match != null) return match;
    }
    return trimmed;
  }

  /// Whether [value] is something `jsonEncode` will accept.
  ///
  /// Non-finite doubles are rejected: measured, not assumed — `jsonEncode(double.nan)`
  /// throws `JsonUnsupportedObjectError` exactly as a `DateTime` does.
  static bool _isJsonEncodable(Object? value) {
    if (value == null || value is String || value is bool) return true;
    if (value is int) return true;
    if (value is double) return value.isFinite;
    if (value is List) return value.every(_isJsonEncodable);
    if (value is Map) {
      return value.entries.every(
        (entry) => entry.key is String && _isJsonEncodable(entry.value),
      );
    }
    return false;
  }

  static const GuardFailure _noCallFound = GuardFailure(
    reason: GuardFailureReason.noToolCallFound,
    message: 'no tool call was found in that response',
  );

  /// Keys a model may put a tool name under, in preference order.
  static const List<String> _nameKeys = [
    'tool',
    'tool_name',
    'name',
    'function',
    'function_name',
    'recipient_name',
  ];

  /// Keys a model may put arguments under, in preference order.
  static const List<String> _argumentKeys = [
    'arguments',
    'args',
    'parameters',
    'parameter_values',
    'input',
  ];

  static final RegExp _scopeSeparator = RegExp(r'[.:/]');
  static final RegExp _nonAlphanumeric = RegExp('[^a-z0-9]');

  static String _normalise(String name) =>
      name.toLowerCase().replaceAll(_nonAlphanumeric, '');

  static String? _firstStringUnder(
    Map<String, Object?> object,
    List<String> keys,
  ) {
    for (final key in keys) {
      final value = object[key];
      if (value is String) return value;
    }
    return null;
  }

  /// Decodes [source] as a JSON object, or `null` if it is not one.
  ///
  /// `jsonDecode` throws `FormatException` — an `Exception`, so this catch is the
  /// narrow kind. A decoded JSON *array* or scalar returns `null`: not an object.
  static Map<String, Object?>? _decodeObject(String source) {
    try {
      final decoded = jsonDecode(source);
      if (decoded is Map) return Map<String, Object?>.from(decoded);
      return null;
    } on FormatException {
      return null;
    }
  }

  /// Every substring of [text] that starts at a `{` and ends at its matching `}`.
  ///
  /// Candidates are produced outermost-first at each position, so an envelope is seen
  /// before the object nested inside it. Quadratic in the number of `{` characters in
  /// the worst case, which is fine for a model turn and is the price of not writing a
  /// streaming parser.
  static Iterable<String> _jsonObjectCandidates(String text) sync* {
    for (var start = 0; start < text.length; start++) {
      if (text.codeUnitAt(start) != _openBrace) continue;
      final end = _matchingBrace(text, start);
      if (end != null) yield text.substring(start, end + 1);
    }
  }

  /// The index of the `}` matching the `{` at [start], or `null` if unbalanced.
  ///
  /// String-aware: a brace inside a JSON string literal is text, not structure, so
  /// `{"sku": "}"}` is one object rather than a truncated one. Escapes are tracked for
  /// the same reason — `"\\"` ends its string and `"\""` does not.
  static int? _matchingBrace(String text, int start) {
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var i = start; i < text.length; i++) {
      final unit = text.codeUnitAt(i);
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (unit == _backslash) {
          escaped = true;
        } else if (unit == _doubleQuote) {
          inString = false;
        }
        continue;
      }
      switch (unit) {
        case _doubleQuote:
          inString = true;
        case _openBrace:
          depth++;
        case _closeBrace:
          depth--;
          if (depth == 0) return i;
      }
    }
    return null;
  }

  static const int _openBrace = 0x7B; // {
  static const int _closeBrace = 0x7D; // }
  static const int _doubleQuote = 0x22; // "
  static const int _backslash = 0x5C; // \
}
