/// Abstraction over an on-device large language model.
///
/// The interface intentionally exposes *structured tool-call events* as a
/// first-class stream item alongside plain text tokens, mirroring the native
/// function-calling API of the intended on-device runtime. Unit tests inject a
/// scripted fake; an on-device implementation is injected at runtime.
library;

/// A single item emitted while the model generates a response.
sealed class LlmEvent {
  const LlmEvent();
}

/// A chunk of generated text.
class LlmToken extends LlmEvent {
  const LlmToken(this.text);

  final String text;

  @override
  bool operator ==(Object other) => other is LlmToken && other.text == text;

  @override
  int get hashCode => text.hashCode;

  @override
  String toString() => 'LlmToken($text)';
}

/// A structured request from the model to invoke a registered tool.
class LlmToolCall extends LlmEvent {
  const LlmToolCall({required this.name, this.arguments = const {}});

  final String name;
  final Map<String, Object?> arguments;

  @override
  String toString() => 'LlmToolCall($name, $arguments)';
}

/// Terminal event signalling that generation has finished.
class LlmDone extends LlmEvent {
  const LlmDone();
}

/// Declarative description of a tool the model may call.
class ToolDefinition {
  const ToolDefinition({
    required this.name,
    required this.description,
    this.parameters = const {},
  });

  final String name;
  final String description;

  /// JSON-Schema object describing the tool's arguments:
  /// `{'type': 'object', 'properties': {…}, 'required': [...]}`. Empty for a tool that
  /// takes none. Build one with `objectSchema()` in `tool_schema.dart`.
  ///
  /// **Not** a bare name-to-type map. This was originally documented as a
  /// "JSON-schema-ish type descriptor", which read as licence to write
  /// `{'sku': 'String'}` — and every engine rejects that, because on-device runtimes
  /// consume this map in two ways and neither can use it: one hands it to a native
  /// template as `tools_json`, the other writes it into the prompt verbatim. Both fail
  /// quietly, which is why the shape is validated at registration (see
  /// `assertToolDefinitionsUsable`) by *every* implementation of this interface — the
  /// fake included, so that a definition passing the host suite cannot throw on device.
  final Map<String, Object?> parameters;
}

/// Contract implemented by every LLM backend (fake or on-device).
abstract interface class LlmEngine {
  /// Loads model weights / warms up the runtime.
  Future<void> initialize();

  /// Whether [initialize] has completed successfully.
  bool get isReady;

  /// Streams tokens and structured tool-call events for [prompt].
  Stream<LlmEvent> generate({
    required String prompt,
    List<ToolDefinition> tools,
  });

  /// Releases native resources.
  Future<void> dispose();
}
