/// The shape a [ToolDefinition] must have before an on-device model can be told
/// about it.
///
/// Task 0.2 declared `ToolDefinition.parameters` as a "JSON-schema-ish type
/// descriptor", which was enough for a fake that never rendered it. It is not
/// enough now, because two different code paths inside the runtime read this map
/// and both expect the *same* concrete shape — a JSON-Schema object:
///
/// ```json
/// {"type": "object",
///  "properties": {"sku": {"type": "string", "description": "…"}},
///  "required": ["sku"]}
/// ```
///
/// * Gemma 4 hands the map to the LiteRT-LM SDK as `tools_json`, which renders the
///   native tool declaration from it.
/// * Gemma 3 has no native declaration, so the plugin builds a textual one by
///   reading `properties` and `required` out of this same map.
///
/// A map in any other shape does not fail loudly at either site. It renders as a
/// tool with **no arguments**, and the model then either omits the argument or
/// invents one — a failure that surfaces as "the model is bad at tool calling"
/// three layers away from the mistake. So the shape is validated here, at
/// registration time, and [validateToolDefinition] is called before any tool
/// reaches the runtime.
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
    // The plugin's declaration builder infers a type from `properties`/`items`
    // when there is no explicit `type`, and refuses to guess otherwise — an
    // untyped scalar reaches the model as an unusable declaration.
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
