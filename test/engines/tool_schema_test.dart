import 'package:field_ops_copilot/engines/llm_engine.dart';
import 'package:field_ops_copilot/engines/tool_schema.dart';
import 'package:flutter_test/flutter_test.dart';

/// The trap this guards is specific and quiet: a `parameters` map that is not a
/// JSON-Schema object is not rejected by anything downstream. On the Gemma 3 path the
/// plugin `jsonEncode`s it straight into the prompt, so the model is taught a shape
/// nothing else agrees with; on the Gemma 4 path it goes to a native template as
/// `tools_json` and also drives constrained decoding, where a bad schema fails with no
/// Dart stack to read. Either way the symptom appears in the agent loop as a bad model
/// rather than a bad registration.
void main() {
  /// The tool Task 1.5 will register first, in the shape the runtime requires.
  final inventoryTool = ToolDefinition(
    name: 'get_local_parts_inventory',
    description: 'Check offline warehouse stock and shelf location for a SKU.',
    parameters: objectSchema(
      properties: {
        'sku': {
          'type': 'string',
          'description': 'Part number, e.g. BRK-990-XP',
        },
      },
      required: ['sku'],
    ),
  );

  group('objectSchema', () {
    test('builds the exact map the plugin reads', () {
      expect(
        objectSchema(
          properties: {
            'sku': {'type': 'string', 'description': 'Part number'},
          },
          required: ['sku'],
        ),
        {
          'type': 'object',
          'properties': {
            'sku': {'type': 'string', 'description': 'Part number'},
          },
          'required': ['sku'],
        },
      );
    });

    test('omits "required" entirely when nothing is required', () {
      // An empty `required: []` is legal JSON Schema but noise in the rendered
      // declaration; leaving the key out keeps the prompt the model sees minimal.
      expect(
        objectSchema(
          properties: {
            'note': {'type': 'string'},
          },
        ).containsKey('required'),
        isFalse,
      );
    });

    test('rejects a required argument that was never declared', () {
      expect(
        () => objectSchema(
          properties: {
            'sku': {'type': 'string'},
          },
          required: ['skew'],
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('copies each property schema so a caller cannot mutate it later', () {
      final property = <String, Object?>{'type': 'string'};
      final schema = objectSchema(properties: {'sku': property});

      property['type'] = 'integer';

      expect((schema['properties']! as Map)['sku'], {'type': 'string'});
    });
  });

  group('validateToolDefinition', () {
    test('accepts the inventory tool', () {
      expect(validateToolDefinition(inventoryTool), isEmpty);
    });

    test('accepts a genuinely argument-less tool', () {
      expect(
        validateToolDefinition(
          const ToolDefinition(
            name: 'raise_safety_hazard_alert_ack',
            description: 'Acknowledge the current hazard banner.',
          ),
        ),
        isEmpty,
      );
    });

    test('rejects the bare name-to-type map — the actual trap', () {
      // This is what "JSON-schema-ish" invites you to write. On the Gemma 3 path it
      // reaches the model verbatim as `Parameters: {"sku":"String"}`; on Gemma 4 it
      // goes to a native template as `tools_json`. Neither rejects it here.
      final problems = validateToolDefinition(
        const ToolDefinition(
          name: 'get_local_parts_inventory',
          description: 'stock lookup',
          parameters: {'sku': 'String'},
        ),
      );

      expect(problems, isNotEmpty);
      expect(
        problems.map((problem) => problem.message).join(' '),
        contains('"type": "object"'),
      );
    });

    test('rejects a property with no type', () {
      // The plugin's declaration builder refuses to guess a type, so the argument
      // reaches the model undeclared.
      final problems = validateToolDefinition(
        const ToolDefinition(
          name: 'x',
          description: 'y',
          parameters: {
            'type': 'object',
            'properties': {
              'sku': {'description': 'no type here'},
            },
          },
        ),
      );
      expect(problems.single.message, contains('declares no "type"'));
    });

    test('accepts a nested object property, whose type is inferable', () {
      // `properties` implies `type: object` for the plugin, so requiring an explicit
      // type here would reject a schema that works.
      expect(
        validateToolDefinition(
          const ToolDefinition(
            name: 'x',
            description: 'y',
            parameters: {
              'type': 'object',
              'properties': {
                'location': {
                  'properties': {
                    'aisle': {'type': 'string'},
                  },
                },
              },
            },
          ),
        ),
        isEmpty,
      );
    });

    test('rejects a required argument that is not declared', () {
      final problems = validateToolDefinition(
        const ToolDefinition(
          name: 'x',
          description: 'y',
          parameters: {
            'type': 'object',
            'properties': {
              'sku': {'type': 'string'},
            },
            'required': ['quantity'],
          },
        ),
      );
      expect(problems.single.message, contains('"quantity"'));
    });

    test('rejects an empty description', () {
      // The description is the only thing telling the model *when* to call the tool.
      final problems = validateToolDefinition(
        ToolDefinition(
          name: 'get_local_parts_inventory',
          description: '   ',
          parameters: inventoryTool.parameters,
        ),
      );
      expect(problems.single.message, contains('when to call it'));
    });

    test('rejects an empty name', () {
      expect(
        validateToolDefinition(
          const ToolDefinition(name: '', description: 'y'),
        ).map((problem) => problem.message).join(' '),
        contains('nothing to call'),
      );
    });

    test('reports every problem at once, not just the first', () {
      final problems = validateToolDefinition(
        const ToolDefinition(
          name: '',
          description: '',
          parameters: {'sku': 'String'},
        ),
      );
      // Name, description and shape: three independent mistakes, one run.
      expect(problems.length, greaterThanOrEqualTo(3));
    });
  });

  group('assertToolDefinitionsUsable', () {
    test('passes a usable set', () {
      expect(
        () => assertToolDefinitionsUsable([inventoryTool]),
        returnsNormally,
      );
    });

    test('passes an empty set', () {
      // A turn with no tools is the ordinary case for a plain question.
      expect(() => assertToolDefinitionsUsable(const []), returnsNormally);
    });

    test('throws on a malformed definition', () {
      expect(
        () => assertToolDefinitionsUsable([
          const ToolDefinition(
            name: 'x',
            description: 'y',
            parameters: {'sku': 'String'},
          ),
        ]),
        throwsA(isA<ToolSchemaException>()),
      );
    });

    test('throws on a duplicate tool name', () {
      // Two tools with one name means the registry cannot know which was called,
      // and the model is shown an ambiguous declaration.
      expect(
        () => assertToolDefinitionsUsable([inventoryTool, inventoryTool]),
        throwsA(
          isA<ToolSchemaException>().having(
            (error) => error.problems.single.message,
            'problem',
            contains('more than once'),
          ),
        ),
      );
    });

    test('the exception names the offending tool', () {
      // The message is what a developer sees at 3am on a device; it has to say which
      // tool, not just that something was wrong.
      try {
        assertToolDefinitionsUsable([
          const ToolDefinition(
            name: 'get_local_parts_inventory',
            description: 'y',
            parameters: {'sku': 'String'},
          ),
        ]);
        fail('expected a ToolSchemaException');
      } on ToolSchemaException catch (error) {
        expect('$error', contains('get_local_parts_inventory'));
      }
    });
  });
}
