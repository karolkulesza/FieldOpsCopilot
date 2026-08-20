import 'dart:convert';

import 'package:field_ops_copilot/engines/llm_engine.dart';
import 'package:field_ops_copilot/engines/tool_schema.dart';
import 'package:field_ops_copilot/models/form_state_model.dart';
import 'package:field_ops_copilot/services/ai/base_tool.dart';
import 'package:field_ops_copilot/services/ai/tool_registry.dart';
import 'package:field_ops_copilot/services/ai/tools/record_work_order_fields_tool.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final tool = RecordWorkOrderFieldsTool();

  Future<Map<String, Object?>> run(Map<String, Object?> arguments) =>
      tool.execute(arguments);

  group('declaration', () {
    test('it is a usable plugin-native definition', () {
      expect(validateToolDefinition(tool.definition), isEmpty);
      // And through the registry's own gate, which is what actually runs on the
      // way to the device.
      expect(() => ToolRegistry([tool]), returnsNormally);
    });

    test('the definition is stable across accesses', () {
      // `AgentTool.definition`'s stated requirement. A getter that rebuilt the map
      // would still satisfy `name`, so this asserts identity rather than equality:
      // the registry snapshots dispatch from one access and declares from another.
      expect(identical(tool.definition, tool.definition), isTrue);
    });

    test('it declares form_updates required and clarification optional', () {
      final parameters = tool.definition.parameters;
      expect(parameters['required'], [formUpdatesArgument]);
      final properties = parameters['properties']! as Map<String, Object?>;
      expect(properties.keys, {formUpdatesArgument, clarificationArgument});
    });

    // The point of a *schema* rather than a free-form object: Gemma 4's
    // constrained decoding is driven by this map, so a field missing from it is a
    // field the model is never told exists.
    test('every work-order field is declared to the model, with a type', () {
      final updates =
          (tool.definition.parameters['properties']!
                  as Map<String, Object?>)[formUpdatesArgument]!
              as Map<String, Object?>;
      final declared = updates['properties']! as Map<String, Object?>;

      expect(declared.keys, WorkOrderField.values.map((f) => f.wireName));
      for (final entry in declared.entries) {
        final schema = entry.value! as Map<String, Object?>;
        expect(schema['type'], 'string', reason: entry.key);
        expect(
          (schema['description']! as String).trim(),
          isNotEmpty,
          reason: entry.key,
        );
      }
    });

    test('the clarification schema declares a list of strings', () {
      final clarification =
          (tool.definition.parameters['properties']!
                  as Map<String, Object?>)[clarificationArgument]!
              as Map<String, Object?>;
      final options =
          (clarification['properties']! as Map<String, Object?>)['options']!
              as Map<String, Object?>;

      expect(options['type'], 'array');
      expect(options['items'], {'type': 'string'});
    });
  });

  group('execute', () {
    // TC-VM-FORM-01's payload, at the layer that first sees it.
    test('records the fields it was sent', () async {
      final payload = await run(const {
        formUpdatesArgument: {
          'fault_code': 'E-102',
          'required_parts': 'BRK-990-XP',
        },
      });

      expect(payload, {
        RecordWorkOrderFieldsTool.recordedKey: {
          'fault_code': 'E-102',
          'required_parts': 'BRK-990-XP',
        },
      });
    });

    test('recorded is present even when nothing was recorded', () async {
      final payload = await run(const {formUpdatesArgument: {}});
      expect(payload[RecordWorkOrderFieldsTool.recordedKey], isEmpty);
      expect(
        payload.containsKey(RecordWorkOrderFieldsTool.refusedKey),
        isFalse,
      );
    });

    test('canonicalises the field name the model spelled', () async {
      final payload = await run(const {
        formUpdatesArgument: {'faultCode': 'E-102'},
      });

      expect(payload[RecordWorkOrderFieldsTool.recordedKey], {
        'fault_code': 'E-102',
      });
    });

    // The class doc's rule: a refused field is a successful call.
    test('a refused field sits beside a recorded one', () async {
      final payload = await run(const {
        formUpdatesArgument: {
          'fault_code': 'E-102',
          'elevator_colour': 'green',
        },
      });

      expect(payload[RecordWorkOrderFieldsTool.recordedKey], {
        'fault_code': 'E-102',
      });
      final refused =
          payload[RecordWorkOrderFieldsTool.refusedKey]! as List<Object?>;
      expect(refused, hasLength(1));
      final entry = refused.single! as Map<String, Object?>;
      expect(entry['field'], 'elevator_colour');
      expect(entry['error'], FormUpdateRejection.unknownField.wireName);
      expect(entry['message'], isNotEmpty);
    });

    test('it echoes a clarification it can put to a technician', () async {
      final payload = await run(const {
        formUpdatesArgument: {'fault_code': 'E-102'},
        clarificationArgument: {
          'field': 'required_parts',
          'question': 'Which filter did you use?',
          'options': ['12-inch mesh', '14-inch carbon'],
        },
      });

      expect(payload[RecordWorkOrderFieldsTool.askedKey], {
        'field': 'required_parts',
        'question': 'Which filter did you use?',
        'options': ['12-inch mesh', '14-inch carbon'],
      });
    });

    // The asymmetry `parseFormUpdates`' doc argues for: an optional extra that
    // cannot be used must not take good field updates down with it.
    test(
      'an unusable clarification is refused without losing the fields',
      () async {
        final payload = await run(const {
          formUpdatesArgument: {'fault_code': 'E-102'},
          clarificationArgument: {
            'field': 'required_parts',
            'question': 'Which?',
            'options': ['only one'],
          },
        });

        expect(payload[RecordWorkOrderFieldsTool.recordedKey], {
          'fault_code': 'E-102',
        });
        expect(
          payload.containsKey(RecordWorkOrderFieldsTool.askedKey),
          isFalse,
        );
        final refused =
            payload[RecordWorkOrderFieldsTool.refusedKey]! as List<Object?>;
        expect(
          (refused.single! as Map<String, Object?>)['error'],
          FormUpdateRejection.unusableClarification.wireName,
        );
      },
    );

    group('the shapes that are a failure rather than a refusal', () {
      test('form_updates absent', () {
        expect(
          () => run(const {}),
          throwsA(
            isA<ToolArgumentException>()
                .having((e) => e.parameter, 'parameter', formUpdatesArgument)
                .having(
                  (e) => e.code,
                  'code',
                  ToolFailureCode.missingParameter,
                ),
          ),
        );
      });

      test('form_updates null', () {
        expect(
          () => run(const {formUpdatesArgument: null}),
          throwsA(
            isA<ToolArgumentException>().having(
              (e) => e.code,
              'code',
              ToolFailureCode.missingParameter,
            ),
          ),
        );
      });

      test('form_updates not an object', () {
        for (final raw in const <Object?>[
          'E-102',
          42,
          ['a'],
        ]) {
          expect(
            () => run({formUpdatesArgument: raw}),
            throwsA(
              isA<ToolArgumentException>().having(
                (e) => e.code,
                'code',
                ToolFailureCode.invalidParameter,
              ),
            ),
            reason: '$raw',
          );
        }
      });

      // And through the registry, because that is what turns the throw into the
      // payload the loop feeds back — the throw itself never reaches the model.
      test('the registry renders it as a failure payload', () async {
        final outcome = await ToolRegistry([tool]).dispatch(
          const LlmToolCall(
            name: RecordWorkOrderFieldsTool.toolName,
            arguments: {},
          ),
        );

        expect(outcome, isA<ToolFailure>());
        expect(
          outcome.payload['error'],
          ToolFailureCode.missingParameter.wireName,
        );
        expect(outcome.payload['parameter'], formUpdatesArgument);
      });
    });

    // `AgentLoop.continuationOf` serialises this payload into the next prompt with
    // `jsonEncode`, and a failure there is an `Error` the loop deliberately does
    // not catch. So the payload being encodable is load-bearing rather than tidy.
    test('every payload it can produce is JSON-encodable', () async {
      final payload = await run(const {
        formUpdatesArgument: {'fault_code': 'E-102', 'nope': 7},
        clarificationArgument: {
          'field': 'required_parts',
          'question': 'Which?',
          'options': ['a', 'b'],
        },
      });

      expect(() => jsonEncode(payload), returnsNormally);
      expect(jsonDecode(jsonEncode(payload)), payload);
    });
  });

  group('reading the payload back', () {
    // The round trip the viewmodel depends on, over every field rather than an
    // example — `recordedFieldsOf`'s doc claims exactness, so this is the check.
    test('every field survives execute → recordedFieldsOf', () async {
      final payload = await run({
        formUpdatesArgument: {
          for (final field in WorkOrderField.values)
            field.wireName: 'value for ${field.name}',
        },
      });

      expect(recordedFieldsOf(payload), {
        for (final field in WorkOrderField.values)
          field: 'value for ${field.name}',
      });
    });

    test('a clarification survives execute → askedClarificationOf', () async {
      final payload = await run(const {
        formUpdatesArgument: {},
        clarificationArgument: {
          'field': 'required_parts',
          'question': 'Which filter did you use?',
          'options': ['12-inch mesh', '14-inch carbon'],
        },
      });

      expect(
        askedClarificationOf(payload),
        const ClarificationRequest(
          field: WorkOrderField.requiredParts,
          question: 'Which filter did you use?',
          options: ['12-inch mesh', '14-inch carbon'],
        ),
      );
    });

    // The refusals reach the state and the panel, so the reader has to be
    // exact in the same way `recordedFieldsOf` is.
    test('every refusal survives execute → refusedUpdatesOf', () async {
      final payload = await run(const {
        formUpdatesArgument: {
          'fault_code': 'E-102',
          'elevator_colour': 'green',
          'technician_hours': 2,
          'required_parts': '',
        },
      });

      final refused = refusedUpdatesOf(payload);
      expect(refused.map((r) => r.key), [
        'elevator_colour',
        'technician_hours',
        'required_parts',
      ]);
      expect(refused.map((r) => r.reason), [
        FormUpdateRejection.unknownField,
        FormUpdateRejection.notAString,
        FormUpdateRejection.blank,
      ]);
      expect(refused.map((r) => r.message), everyElement(isNotEmpty));
    });

    test('a payload with nothing refused reports nothing', () async {
      final payload = await run(const {
        formUpdatesArgument: {'fault_code': 'E-102'},
      });
      expect(refusedUpdatesOf(payload), isEmpty);
    });

    test('an unreadable refusal entry is dropped, not half-built', () {
      // Same tolerance as the other two readers, and for the same reason: it runs
      // mid-flight over whatever payload arrives. An unknown `error` keeps the
      // entry — the reason is the least interesting part of it — but an entry with
      // no message has nothing to draw and is dropped.
      final refused = refusedUpdatesOf(const {
        RecordWorkOrderFieldsTool.refusedKey: [
          {'field': 'a', 'error': 'unknown_field', 'message': 'kept'},
          {'field': 'b', 'error': 'a_code_from_the_future', 'message': 'kept'},
          {'field': 'c', 'error': 'unknown_field'},
          {'field': 7, 'error': 'unknown_field', 'message': 'dropped'},
          'not a map',
        ],
      });

      expect(refused.map((r) => r.key), ['a', 'b']);
      expect(refused[1].reason, FormUpdateRejection.unknownField);
    });

    test('a payload with no question asks none', () async {
      final payload = await run(const {
        formUpdatesArgument: {'fault_code': 'E-102'},
      });
      expect(askedClarificationOf(payload), isNull);
    });

    // It runs mid-flight against a payload from *any* tool, so it must be inert
    // rather than throwing on one it does not recognise.
    test('it is inert on a payload that is not this tool\'s', () {
      for (final payload in const <Map<String, Object?>>[
        {},
        {'sku': 'BRK-990-XP', 'in_stock': 2},
        {'recorded': 'not a map'},
        {'recorded': <String, Object?>{}},
        {
          'recorded': {'fault_code': 7, 'nope': 'x', 'required_parts': '  '},
        },
        {'asked': 'not a map'},
      ]) {
        expect(recordedFieldsOf(payload), isEmpty, reason: '$payload');
        expect(askedClarificationOf(payload), isNull, reason: '$payload');
      }
    });
  });
}
