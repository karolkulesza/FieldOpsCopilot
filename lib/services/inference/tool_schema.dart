/// The shape a [ToolDefinition] must have before an on-device model can be told
/// about it.
///
/// Task 0.2 declared `ToolDefinition.parameters` as a "JSON-schema-ish type
/// descriptor", which was enough for a fake that never rendered it. It is not enough
/// now, because the map has to satisfy **two consumers that read it completely
/// differently**, and neither one tells you when it does not:
///
/// ```json
/// {"type": "object",
///  "properties": {"sku": {"type": "string", "description": "…"}},
///  "required": ["sku"]}
/// ```
///
/// * **Gemma 4** — Dart passes the map through untouched as the SDK's `tools_json`,
///   and a native template this app cannot read renders the declaration from it.
///   Setting tools there also switches on constrained decoding, so a malformed schema
///   is at least as likely to fail *inside* the native engine as to produce a usable
///   declaration. Either way the diagnosis arrives from a layer with no Dart stack.
/// * **Gemma 3 (`gemmaIt`)** — no native declaration at all. The plugin writes the map
///   into the prompt **verbatim**: `'<name>: <description> Parameters: '` followed by
///   `jsonEncode(parameters)`. So a bare `{"sku": "String"}` does not throw and does
///   not degrade; it simply teaches the model a shape that nothing downstream agrees
///   with, and the tool call comes back with arguments the registry cannot read.
///
/// A correction worth recording, because the first version of this comment got it
/// wrong in a way that sounded convincing: it claimed both paths read `properties` and
/// `required` structurally, and that a non-schema map "renders as a tool with no
/// arguments". Only the Gemma 4 path consumes the map structurally, and the textual
/// path does not drop the arguments — it forwards the nonsense. The conclusion holds
/// (validate at registration, where the mistake is) but the mechanism is not the one
/// originally described.
///
/// This is the contract Task 1.5's registry must emit. [objectSchema] exists so it
/// (and the tests here) can build a conforming map without hand-writing it.
library;

import '../../engines/llm_engine.dart';

/// Why a tool definition cannot be handed to the model.
class ToolSchemaProblem {
  const ToolSchemaProblem(this.toolName, this.message);

  final String toolName;
  final String message;

  @override
  String toString() => 'tool "$toolName": $message';
}

/// Thrown when a tool would be registered with a schema the runtime cannot render.
class ToolSchemaException implements Exception {
  const ToolSchemaException(this.problems);

  final List<ToolSchemaProblem> problems;

  @override
  String toString() =>
      'ToolSchemaException: ${problems.map((p) => '$p').join('; ')}';
}

/// Builds a conforming JSON-Schema object for a tool's arguments.
///
/// [properties] maps each argument name to its own schema (`{'type': 'string',
/// 'description': …}`). [required] must name only properties that exist — a
/// required argument that is not declared is a schema the model cannot satisfy,
/// and it is a typo often enough to be worth rejecting here.
Map<String, Object?> objectSchema({
  required Map<String, Map<String, Object?>> properties,
  List<String> required = const [],
}) {
  for (final name in required) {
    if (!properties.containsKey(name)) {
      throw ArgumentError.value(
        name,
        'required',
        'required argument is not declared in properties '
            '(${properties.keys.join(', ')})',
      );
    }
  }
  return {
    'type': 'object',
    'properties': {
      for (final entry in properties.entries) entry.key: {...entry.value},
    },
    if (required.isNotEmpty) 'required': [...required],
  };
}

/// Checks one definition, returning every problem found (never throwing).
///
/// Returns all problems rather than the first, so a caller fixing a registry sees
/// the whole list in one run instead of peeling them off one build at a time.
List<ToolSchemaProblem> validateToolDefinition(ToolDefinition definition) {
  final problems = <ToolSchemaProblem>[];
  void report(String message) =>
      problems.add(ToolSchemaProblem(definition.name, message));

  if (definition.name.trim().isEmpty) {
    report('name is empty; the model has nothing to call');
  }
  if (definition.description.trim().isEmpty) {
    // Not pedantry: the description is the only thing telling the model *when* to
    // call this tool. An undescribed tool is one the model will not use, which
    // looks like a model failure rather than a registration one.
    report('description is empty; the model is not told when to call it');
  }

  final parameters = definition.parameters;
  // A genuinely argument-less tool is legitimate, and an empty map is the honest
  // way to say so — the runtime sends no `properties` and the model calls it with
  // no arguments. Everything below only applies once a map claims to declare some.
  if (parameters.isEmpty) return problems;

  final type = parameters['type'];
  if (type != 'object') {
    report(
      'parameters must be a JSON-Schema object with "type": "object" '
      '(found ${type == null ? 'no type' : '"$type"'}) — a bare '
      'name-to-type map renders as a tool with no arguments',
    );
  }

  final properties = parameters['properties'];
  if (properties is! Map) {
    report('parameters.properties must be a map of argument name to schema');
    return problems;
  }
  if (properties.isEmpty) {
    report(
      'parameters.properties is empty while parameters is not; declare the '
      'arguments or pass an empty parameters map',
    );
  }

  for (final entry in properties.entries) {
    final name = entry.key;
    final schema = entry.value;
    if (schema is! Map) {
      report(
        'property "$name" must map to a schema, not ${schema.runtimeType}',
      );
      continue;
    }
    // A conservative rule, and worth being straight about its provenance: it is
    // modelled on the *one* place the plugin infers a property type — the
    // FunctionGemma declaration builder, which reads `properties`/`items` and throws
    // rather than guessing anything else. This app never selects that model type, so
    // that code does not run here. The rule is kept because an untyped scalar is
    // genuinely under-specified for both consumers this file exists to protect (a
    // native template that must emit a type, and a prompt that hands the model the
    // map as-is), and because the family set may grow.
    final hasInferableType =
        schema.containsKey('properties') || schema.containsKey('items');
    if (schema['type'] is! String && !hasInferableType) {
      report('property "$name" declares no "type"');
    }
  }

  final required = parameters['required'];
  if (required != null) {
    if (required is! List) {
      report('parameters.required must be a list of property names');
    } else {
      for (final name in required) {
        if (!properties.containsKey(name)) {
          report('required argument "$name" is not declared in properties');
        }
      }
    }
  }

  return problems;
}

/// Validates every definition, throwing [ToolSchemaException] if any is unusable.
///
/// Also rejects duplicate names: two tools with one name means the registry that
/// executes the call cannot know which was meant, and the model is handed an
/// ambiguous declaration.
void assertToolDefinitionsUsable(List<ToolDefinition> definitions) {
  final problems = <ToolSchemaProblem>[];
  final seen = <String>{};
  for (final definition in definitions) {
    problems.addAll(validateToolDefinition(definition));
    if (!seen.add(definition.name)) {
      problems.add(
        ToolSchemaProblem(definition.name, 'declared more than once'),
      );
    }
  }
  if (problems.isNotEmpty) throw ToolSchemaException(problems);
}
