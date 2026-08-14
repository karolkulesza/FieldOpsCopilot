/// The agent's structured-output channel: the tool it calls to fill in the work
/// order, and to ask which of several answers it should have written.
library;

import '../../../engines/llm_engine.dart';
import '../../../engines/tool_schema.dart';
import '../../../models/form_state_model.dart';
import '../base_tool.dart';

/// Records what the agent extracted from the technician's words.
///
/// **Why this is a tool rather than a JSON blob parsed out of the answer.** The
/// spec's §2.3 calls for "structured JSON conversions", and Task 1.8 established
/// that this build's model emits *native function-call tokens* — so the app already
/// owns a validated, schema-driven, transcript-visible channel for structured
/// output, and the alternative would be a second one with none of those properties.
/// Concretely, going through the registry buys four things a scraped blob does not
/// have: Gemma 4's constrained decoding is driven by [definition]'s schema, so the
/// shape is enforced at generation time; a malformed call is caught by Task 1.6's
/// guard instead of by a brace scan written here; every refusal is fed back to the
/// model by Task 1.9's loop, so it can correct itself; and the whole exchange lands
/// in the golden transcripts rather than in a string nobody snapshots.
///
/// **This tool is pure, and the form is filled from its payload.** It writes
/// nothing and holds no sink — `WorkOrderFormViewModel` reads
/// [AgentToolInvocation.outcome]'s payload and applies it. That is the same
/// decision `_CompletedTool._summarise` made one layer up ("reads the payload
/// rather than restating the arguments, because the payload is what the model was
/// told"): **one parse feeds both readers**, so the screen and the model cannot
/// disagree about what this call *meant*. A sink would give two readings of one
/// call — the one the model got and the one the technician sees — and nothing to
/// keep them in step.
///
/// **What that does not say, corrected by review finding R0-F3:** the screen and
/// the model can still end up showing different *values*, and by design.
/// `WorkOrderFormState.applyUpdates` refuses to overwrite a field the technician
/// holds, so a payload the model was told recorded `E-102` can leave the field
/// reading the technician's `E-999` with `E-102` parked as a suggestion. That is
/// the precedence rule working, and it is a deliberate divergence rather than an
/// exception to a guarantee — an earlier version of this paragraph claimed the two
/// "cannot disagree about what was recorded", which the rule two files away
/// contradicts.
///
/// **A refused field is a successful call, not a [ToolFailure].** `{"fault_code":
/// "E-102", "elevator_colour": "green"}` recorded one field and refused one, and
/// reporting that as a failure would tell the model its whole call was rejected
/// when most of it landed. The failure codes are reserved for a call that recorded
/// *nothing because it could not be read at all* — no `form_updates`, or one that
/// is not an object — which `ToolArguments` already classifies.
class RecordWorkOrderFieldsTool extends AgentTool {
  RecordWorkOrderFieldsTool();

  /// The name the model emits.
  static const String toolName = 'record_work_order_fields';

  /// Payload key carrying the fields that were written, `wire name → value`.
  ///
  /// Always present, even when empty: an absent key is indistinguishable from a
  /// tool that does not report what it recorded, which is `GetPartsInventoryTool`'s
  /// argument for a present-and-null `aisle`.
  static const String recordedKey = 'recorded';

  /// Payload key carrying the entries that were not written. Omitted when none
  /// were, so the happy-path transcript stays short.
  static const String refusedKey = 'refused';

  /// Payload key echoing the question that will be put to the technician.
  static const String askedKey = 'asked';

  /// A `final` field rather than a getter, which is `AgentTool.definition`'s
  /// stated requirement rather than a style choice: `ToolRegistry` snapshots its
  /// dispatch map in the constructor while `definitions` recomputes per call, so a
  /// definition rebuilt on every access is one more thing that could come back
  /// different. Nothing here is non-deterministic, and that is exactly why the
  /// cheap guarantee is worth taking.
  @override
  final ToolDefinition definition = ToolDefinition(
    name: toolName,
    // The description is the only thing telling the model when to call this, and
    // the last two sentences are doing work rather than documenting: without the
    // first, a model that has already written the fault code into its prose sees no
    // reason to also call a tool; without the second, "ambiguous" is a judgement it
    // has no criterion for.
    description:
        'Record the work-order fields you have extracted from the technician. '
        'Call this as soon as you can identify any of them, before writing your '
        'answer — the fields appear on the technician\'s form immediately and '
        'are not read from your prose. If a value could reasonably be one of '
        'several specific things, record what you are sure of and use '
        '"$clarificationArgument" to ask which, rather than guessing.',
    parameters: objectSchema(
      properties: {
        formUpdatesArgument: {
          'type': 'object',
          'description':
              'The fields to write, as an object of field name to value. '
              'Every value must be a string. Omit a field you have nothing '
              'for; do not send an empty string.',
          'properties': {
            for (final field in WorkOrderField.values)
              field.wireName: {
                'type': 'string',
                'description': _describe(field),
              },
          },
        },
        clarificationArgument: {
          'type': 'object',
          'description':
              'A question to put to the technician when a field could be one '
              'of several specific values. Needs at least two distinct '
              'options.',
          'properties': {
            'field': {
              'type': 'string',
              'description':
                  'Which field the answer fills in: '
                  '${WorkOrderField.values.map((f) => f.wireName).join(', ')}.',
            },
            'question': {
              'type': 'string',
              'description': 'The question, in one short sentence.',
            },
            'options': {
              'type': 'array',
              'description':
                  'Two or more distinct answers to choose between, each the '
                  'exact text that should end up in the field.',
              'items': {'type': 'string'},
            },
          },
        },
      },
      required: [formUpdatesArgument],
    ),
  );

  /// Per-field guidance for the schema.
  ///
  /// Derived from the enum so a fifth field cannot be declared to the model
  /// without one — the `switch` is exhaustive, so adding a value fails to compile
  /// here rather than shipping a field the model is told nothing about.
  static String _describe(WorkOrderField field) => switch (field) {
    WorkOrderField.faultCode =>
      'The controller fault code exactly as it appears, for example "E-102".',
    WorkOrderField.requiredParts =>
      'The replacement part, by SKU where you have looked one up, otherwise '
          'by the name the technician used.',
    WorkOrderField.technicianHours =>
      'Hours spent or estimated, as text, for example "1.5".',
    WorkOrderField.safetyCheckpoints =>
      'Safety steps the technician stated they completed, for example '
          '"lockout/tagout verified".',
  };

  @override
  Future<Map<String, Object?>> execute(Map<String, Object?> arguments) async {
    final args = ToolArguments(arguments);
    // Throws `ToolArgumentException` for absent / null / not-an-object, which the
    // registry renders as `missing_parameter` or `invalid_parameter`. That is the
    // only shape of this call that produces a failure — see the class doc.
    final parse = parseFormUpdates(args.requiredMap(formUpdatesArgument));
    final clarification = parseClarification(
      args.optional(clarificationArgument),
    );

    final refused = <Map<String, Object?>>[
      for (final rejection in parse.rejected) _refusal(rejection),
      if (clarification.rejection != null) _refusal(clarification.rejection!),
    ];
    final request = clarification.request;

    return {
      recordedKey: {
        for (final entry in parse.accepted.entries)
          entry.key.wireName: entry.value,
      },
      if (refused.isNotEmpty) refusedKey: refused,
      if (request != null)
        askedKey: {
          'field': request.field.wireName,
          'question': request.question,
          'options': [...request.options],
        },
    };
  }

  /// One refusal, in the shape `ToolFailure.payload` uses for the same job — a
  /// stable `error` key, what it was about, and a message written for the model.
  static Map<String, Object?> _refusal(RejectedFieldUpdate rejection) => {
    'field': rejection.key,
    'error': rejection.reason.wireName,
    'message': rejection.message,
  };
}

/// Reads one [RecordWorkOrderFieldsTool] payload back into form updates.
///
/// The inverse of [RecordWorkOrderFieldsTool.execute]'s `recorded` map. It exists
/// so the viewmodel reads *what the model was told* rather than re-parsing the
/// arguments the model sent — see the tool's class doc. It is deliberately
/// tolerant: a payload that is not this tool's, or that has been reshaped, yields
/// an empty result rather than throwing, because it runs while a run is in flight
/// and there is no useful way for a screen to fail here.
///
/// **The round trip is exact, and that is a property rather than a hope.** The keys
/// are [WorkOrderField.wireName]s written by [RecordWorkOrderFieldsTool.execute]
/// moments earlier, so [WorkOrderField.byKey] resolves every one of them —
/// `record_work_order_fields_tool_test.dart` asserts the round trip over every
/// field rather than over an example.
Map<WorkOrderField, String> recordedFieldsOf(Map<String, Object?> payload) {
  final recorded = payload[RecordWorkOrderFieldsTool.recordedKey];
  if (recorded is! Map) return const {};
  final fields = <WorkOrderField, String>{};
  for (final entry in recorded.entries) {
    final field = WorkOrderField.byKey('${entry.key}');
    final value = entry.value;
    if (field == null || value is! String || value.trim().isEmpty) continue;
    fields[field] = value;
  }
  return fields;
}

/// Reads the entries a [RecordWorkOrderFieldsTool] payload reports as refused.
///
/// The inverse of [RecordWorkOrderFieldsTool._refusal], and it exists because
/// review finding **R0-F4** caught `WorkOrderFormState.rejected` being dead on
/// every production path while its docstring named a reader. The list reaches the
/// state, and the work-order panel draws a line when it is non-empty — so what the
/// model got wrong is visible to the person watching the demo rather than only to
/// the model.
///
/// Tolerant for [recordedFieldsOf]'s reason: it runs mid-flight over whatever
/// payload arrives, so an unrecognised shape yields nothing rather than throwing.
/// A refusal with no message is dropped — there would be nothing to draw.
List<RejectedFieldUpdate> refusedUpdatesOf(Map<String, Object?> payload) {
  final refused = payload[RecordWorkOrderFieldsTool.refusedKey];
  if (refused is! List) return const [];
  final entries = <RejectedFieldUpdate>[];
  for (final raw in refused) {
    if (raw is! Map) continue;
    final field = raw['field'];
    final message = raw['message'];
    if (field is! String || message is! String || message.isEmpty) continue;
    entries.add(
      RejectedFieldUpdate(
        key: field,
        // The wire name the tool wrote, resolved back to the enum. An unknown one
        // is reported as `unknownField` rather than dropped: the entry is real and
        // the reason is the least interesting part of it.
        reason: FormUpdateRejection.values.firstWhere(
          (value) => value.wireName == raw['error'],
          orElse: () => FormUpdateRejection.unknownField,
        ),
        message: message,
      ),
    );
  }
  return entries;
}

/// Reads the clarification a [RecordWorkOrderFieldsTool] payload asked for, or
/// `null`.
///
/// Reuses [parseClarification] rather than re-reading the three keys, so the
/// two-distinct-options rule is enforced in one place. A refusal on the way back is
/// impossible for a payload this tool wrote — [RecordWorkOrderFieldsTool.execute]
/// only emits `asked` for a request that already parsed — and is treated as "no
/// question" rather than surfaced, because the tool's own refusal has already gone
/// to the model.
ClarificationRequest? askedClarificationOf(Map<String, Object?> payload) =>
    parseClarification(payload[RecordWorkOrderFieldsTool.askedKey]).request;
