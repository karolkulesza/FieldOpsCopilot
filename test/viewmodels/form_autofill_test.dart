import 'package:field_ops_copilot/engines/fakes/fake_llm_engine.dart';
import 'package:field_ops_copilot/engines/llm_engine.dart';
import 'package:field_ops_copilot/models/form_state_model.dart';
import 'package:field_ops_copilot/services/ai/agent_loop.dart';
import 'package:field_ops_copilot/services/ai/base_tool.dart';
import 'package:field_ops_copilot/services/ai/tool_call_guard.dart';
import 'package:field_ops_copilot/services/ai/tool_registry.dart';
import 'package:field_ops_copilot/services/ai/tools/record_work_order_fields_tool.dart';
import 'package:field_ops_copilot/viewmodels/work_order_form_viewmodel.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Task 2.3's unit tier: the agent's `form_updates` map reaching the Riverpod
/// form controllers, and everything that decides whether it should.
///
/// **TC-VM-FORM-01 is driven through the real loop, not through the viewmodel's
/// front door**, and that is the difference between asserting the criterion and
/// asserting a function call. The criterion is "the agent emits this map and the
/// controllers update to match"; a test that hands the payload straight to
/// `applyPayload` would still pass with the tool unregistered, with the loop not
/// forwarding completions, and with the controllers never synced — three of the
/// four things that have to be true. So the AC case scripts a `FakeLlmEngine` to
/// emit a native tool call, runs the real `AgentLoop` over the real `ToolRegistry`
/// holding the real tool, forwards completions exactly as `FieldJobViewModel` does,
/// and reads the controller.
void main() {
  ProviderContainer container() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  /// Runs one loop turn that emits [call], forwarding completions to the form the
  /// way `FieldJobViewModel.diagnose` does.
  Future<AgentRunResult> runAgent(
    ProviderContainer c,
    LlmToolCall call, {
    String answer = 'Replace the brake pad.',
  }) async {
    final engine = FakeLlmEngine(
      turns: [
        [call, const LlmDone()],
        [LlmToken(answer), const LlmDone()],
      ],
    );
    await engine.initialize();
    addTearDown(engine.dispose);

    final loop = AgentLoop(
      engine: engine,
      registry: ToolRegistry([RecordWorkOrderFieldsTool()]),
    );

    AgentRunResult? result;
    await for (final event in loop.run('[USER INQUIRY]\ncabin vibrating')) {
      if (event is AgentToolCallCompleted) {
        c
            .read(workOrderFormProvider.notifier)
            .applyInvocation(event.invocation);
      }
      if (event is AgentCompleted) result = event.result;
    }
    return result!;
  }

  group('TC-VM-FORM-01: auto-fill', () {
    // The AC verbatim: `{"form_updates":{"fault_code":"E-102",
    // "required_parts":"BRK-990-XP"}}` → controllers update to match.
    test('the agent\'s form_updates map reaches the controllers', () async {
      final c = container();
      final controllers = c.read(workOrderFormControllersProvider);

      expect(controllers[WorkOrderField.faultCode].text, '');

      final result = await runAgent(
        c,
        const LlmToolCall(
          name: RecordWorkOrderFieldsTool.toolName,
          arguments: {
            formUpdatesArgument: {
              'fault_code': 'E-102',
              'required_parts': 'BRK-990-XP',
            },
          },
        ),
      );

      expect(controllers[WorkOrderField.faultCode].text, 'E-102');
      expect(controllers[WorkOrderField.requiredParts].text, 'BRK-990-XP');
      // The two the agent said nothing about stay empty — a form that filled
      // everything it was shown would pass the two assertions above as well.
      expect(controllers[WorkOrderField.technicianHours].text, '');
      expect(controllers[WorkOrderField.safetyCheckpoints].text, '');
      // And the run itself completed normally: a form filled by a call the loop
      // reported as a failure would be filling from a payload nothing produced.
      expect(result.stopReason, AgentStopReason.answered);
      expect(result.invocations.single.outcome, isA<ToolSuccess>());
    });

    test('the state records the agent as the origin', () async {
      final c = container();

      await runAgent(
        c,
        const LlmToolCall(
          name: RecordWorkOrderFieldsTool.toolName,
          arguments: {
            formUpdatesArgument: {'fault_code': 'E-102'},
          },
        ),
      );

      final state = c.read(workOrderFormProvider);
      expect(
        state.fields[WorkOrderField.faultCode]!.origin,
        FormFieldOrigin.agent,
      );
    });

    // The path that is *not* the AC's: a call the loop refuses to dispatch must
    // leave the form alone. Without this, "the controllers updated" would be
    // satisfied by a form that applies whatever arrives.
    test('a call the tool refuses fills nothing', () async {
      final c = container();
      final controllers = c.read(workOrderFormControllersProvider);

      final result = await runAgent(
        c,
        // No `form_updates` at all — `ToolArguments.requiredMap` makes this a
        // `ToolFailure`, not a recording of nothing.
        const LlmToolCall(
          name: RecordWorkOrderFieldsTool.toolName,
          arguments: {},
        ),
      );

      expect(result.invocations.single.outcome, isA<ToolFailure>());
      for (final field in WorkOrderField.values) {
        expect(controllers[field].text, '', reason: field.name);
      }
      expect(c.read(workOrderFormProvider).isEmpty, isTrue);
    });

    test('a completion from another tool is ignored', () {
      final c = container();
      final applied = c
          .read(workOrderFormProvider.notifier)
          .applyInvocation(
            const AgentToolInvocation(
              call: LlmToolCall(
                name: 'get_local_parts_inventory',
                arguments: {'sku': 'BRK-990-XP'},
              ),
              source: GuardSource.nativeEvent,
              // Deliberately a payload shaped like this tool's, so that being
              // ignored has to come from the *name* rather than from the payload
              // failing to parse.
              outcome: ToolSuccess(
                toolName: 'get_local_parts_inventory',
                payload: {
                  RecordWorkOrderFieldsTool.recordedKey: {
                    'fault_code': 'E-999',
                  },
                },
              ),
            ),
          );

      expect(applied, isFalse);
      expect(c.read(workOrderFormProvider).isEmpty, isTrue);
    });

    test('a form call that recorded nothing changes nothing', () {
      final c = container();
      final applied = c.read(workOrderFormProvider.notifier).applyPayload(
        const {RecordWorkOrderFieldsTool.recordedKey: {}},
      );

      expect(applied, isFalse);
      expect(c.read(workOrderFormProvider).isEmpty, isTrue);
    });
  });

  group('the controllers stay in step with the state', () {
    test('a technician entry reaches the controller', () {
      final c = container();
      final controllers = c.read(workOrderFormControllersProvider);

      c
          .read(workOrderFormProvider.notifier)
          .setTechnicianEntry(WorkOrderField.technicianHours, '1.5');

      expect(controllers[WorkOrderField.technicianHours].text, '1.5');
    });

    test('clearing a field clears its controller', () {
      final c = container();
      final controllers = c.read(workOrderFormControllersProvider);
      final form = c.read(workOrderFormProvider.notifier);

      form.setTechnicianEntry(WorkOrderField.faultCode, 'E-102');
      form.setTechnicianEntry(WorkOrderField.faultCode, '');

      expect(controllers[WorkOrderField.faultCode].text, '');
    });

    // The state → controller write is unconditional per field, so the guard that
    // keeps an *untouched* field untouched is the text comparison. Without it, a
    // caret sitting mid-word in one field is destroyed by an update to another.
    test('an update to one field does not move the caret in another', () {
      final c = container();
      final controllers = c.read(workOrderFormControllersProvider);
      final form = c.read(workOrderFormProvider.notifier);

      form.setTechnicianEntry(WorkOrderField.safetyCheckpoints, 'lockout');
      controllers[WorkOrderField.safetyCheckpoints].selection =
          const TextSelection.collapsed(offset: 3);

      form.setTechnicianEntry(WorkOrderField.faultCode, 'E-102');

      expect(
        controllers[WorkOrderField.safetyCheckpoints].selection.baseOffset,
        3,
      );
    });

    test('a field that is rewritten puts the caret at the end', () {
      final c = container();
      final controllers = c.read(workOrderFormControllersProvider);

      c
          .read(workOrderFormProvider.notifier)
          .setTechnicianEntry(WorkOrderField.faultCode, 'E-102');

      expect(
        controllers[WorkOrderField.faultCode].selection.baseOffset,
        'E-102'.length,
      );
    });

    // A provider built after the agent has already recorded something — the case a
    // listener alone would miss, because there is no *change* left to observe.
    test('controllers built late are seeded from the current state', () {
      final c = container();
      c.read(workOrderFormProvider.notifier).applyPayload(const {
        RecordWorkOrderFieldsTool.recordedKey: {'fault_code': 'E-102'},
      });

      expect(
        c.read(workOrderFormControllersProvider)[WorkOrderField.faultCode].text,
        'E-102',
      );
    });

    test('every field has a controller from the start', () {
      final controllers = container().read(workOrderFormControllersProvider);
      for (final field in WorkOrderField.values) {
        expect(controllers[field], isA<TextEditingController>());
      }
    });
  });

  group('the technician outranks the agent, end to end', () {
    test('an agent value does not overwrite what was typed', () async {
      final c = container();
      final controllers = c.read(workOrderFormControllersProvider);
      c
          .read(workOrderFormProvider.notifier)
          .setTechnicianEntry(WorkOrderField.faultCode, 'E-999');

      await runAgent(
        c,
        const LlmToolCall(
          name: RecordWorkOrderFieldsTool.toolName,
          arguments: {
            formUpdatesArgument: {'fault_code': 'E-102'},
          },
        ),
      );

      expect(controllers[WorkOrderField.faultCode].text, 'E-999');
      expect(
        c
            .read(workOrderFormProvider)
            .fields[WorkOrderField.faultCode]!
            .suggestion,
        'E-102',
      );
    });

    test('accepting the suggestion moves it into the controller', () async {
      final c = container();
      final controllers = c.read(workOrderFormControllersProvider);
      final form = c.read(workOrderFormProvider.notifier);
      form.setTechnicianEntry(WorkOrderField.faultCode, 'E-999');

      await runAgent(
        c,
        const LlmToolCall(
          name: RecordWorkOrderFieldsTool.toolName,
          arguments: {
            formUpdatesArgument: {'fault_code': 'E-102'},
          },
        ),
      );
      form.acceptSuggestion(WorkOrderField.faultCode);

      expect(controllers[WorkOrderField.faultCode].text, 'E-102');
    });

    test('dismissing it leaves the controller alone', () async {
      final c = container();
      final controllers = c.read(workOrderFormControllersProvider);
      final form = c.read(workOrderFormProvider.notifier);
      form.setTechnicianEntry(WorkOrderField.faultCode, 'E-999');

      await runAgent(
        c,
        const LlmToolCall(
          name: RecordWorkOrderFieldsTool.toolName,
          arguments: {
            formUpdatesArgument: {'fault_code': 'E-102'},
          },
        ),
      );
      form.dismissSuggestion(WorkOrderField.faultCode);

      expect(controllers[WorkOrderField.faultCode].text, 'E-999');
      expect(
        c
            .read(workOrderFormProvider)
            .fields[WorkOrderField.faultCode]!
            .hasSuggestion,
        isFalse,
      );
    });
  });

  group('clarification arrives with the recording', () {
    const askArguments = {
      formUpdatesArgument: {'fault_code': 'E-102'},
      clarificationArgument: {
        'field': 'required_parts',
        'question': 'Which filter did you use?',
        'options': ['12-inch mesh', '14-inch carbon'],
      },
    };

    test('the question lands on the state and the fields still fill', () async {
      final c = container();
      final controllers = c.read(workOrderFormControllersProvider);

      await runAgent(
        c,
        const LlmToolCall(
          name: RecordWorkOrderFieldsTool.toolName,
          arguments: askArguments,
        ),
      );

      expect(controllers[WorkOrderField.faultCode].text, 'E-102');
      final request = c.read(workOrderFormProvider).clarification!;
      expect(request.field, WorkOrderField.requiredParts);
      expect(request.options, ['12-inch mesh', '14-inch carbon']);
    });

    test('answering it fills the field it names', () async {
      final c = container();
      final controllers = c.read(workOrderFormControllersProvider);

      await runAgent(
        c,
        const LlmToolCall(
          name: RecordWorkOrderFieldsTool.toolName,
          arguments: askArguments,
        ),
      );
      c
          .read(workOrderFormProvider.notifier)
          .answerClarification('14-inch carbon');

      expect(controllers[WorkOrderField.requiredParts].text, '14-inch carbon');
      expect(c.read(workOrderFormProvider).clarification, isNull);
    });

    test('dismissing it fills nothing', () async {
      final c = container();
      final controllers = c.read(workOrderFormControllersProvider);

      await runAgent(
        c,
        const LlmToolCall(
          name: RecordWorkOrderFieldsTool.toolName,
          arguments: askArguments,
        ),
      );
      c.read(workOrderFormProvider.notifier).dismissClarification();

      expect(controllers[WorkOrderField.requiredParts].text, '');
      expect(c.read(workOrderFormProvider).clarification, isNull);
    });
  });

  group('the form outlives one diagnosis', () {
    test('a second run keeps what the first recorded', () async {
      final c = container();
      final controllers = c.read(workOrderFormControllersProvider);

      await runAgent(
        c,
        const LlmToolCall(
          name: RecordWorkOrderFieldsTool.toolName,
          arguments: {
            formUpdatesArgument: {'fault_code': 'E-102'},
          },
        ),
      );
      await runAgent(
        c,
        const LlmToolCall(
          name: RecordWorkOrderFieldsTool.toolName,
          arguments: {
            formUpdatesArgument: {'technician_hours': '1.5'},
          },
        ),
      );

      expect(controllers[WorkOrderField.faultCode].text, 'E-102');
      expect(controllers[WorkOrderField.technicianHours].text, '1.5');
    });

    test('reset empties it', () {
      final c = container();
      final controllers = c.read(workOrderFormControllersProvider);
      final form = c.read(workOrderFormProvider.notifier);

      form.setTechnicianEntry(WorkOrderField.faultCode, 'E-102');
      form.reset();

      expect(controllers[WorkOrderField.faultCode].text, '');
      expect(c.read(workOrderFormProvider).isEmpty, isTrue);
    });
  });
}
