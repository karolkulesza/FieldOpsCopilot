/// The work-order form the agent fills in, and the rules for reading what the
/// model sent.
///
/// The spec's §2.3 asks for three things, and this file owns the first and the
/// third: structured JSON conversion of spoken observations, real-time population
/// of the form fields, and an interactive clarification when a value is ambiguous.
/// The *screen* is `views/components/`; the *source* of the JSON is
/// `services/ai/tools/record_work_order_fields_tool.dart`; what is here is the
/// data and the parsing, with no Flutter and no Riverpod, so both of those can be
/// tested without either.
///
/// **Three decisions are worth reading before changing anything.**
///
/// 1. **A field update the model got wrong is a value, not a throw.** This is Task
///    1.5's rule ("a bad call is data, not an exception") applied one layer along,
///    and for the same reason: the caller is a language model, so an unknown field
///    name or a number where a string was declared is an ordinary outcome, and the
///    agent loop's whole recovery mechanism is feeding the payload back. So
///    [parseFormUpdates] never throws — it returns [FormUpdateParse], which carries
///    what was applied *and* what was refused.
/// 2. **A non-string value is refused rather than coerced**, which is
///    `ToolArguments.requiredString`'s decision quoted rather than re-argued: the
///    schema declares every field a string, so `{"technician_hours": 2}` is the
///    model ignoring the schema, and `2.toString()` would hide that behind a field
///    that looks correctly filled. The alternative — declaring `technician_hours` a
///    JSON `number` and accepting a `num` — is coherent and was rejected only
///    because it splits the field set into two type rules for one field, and
///    because Gemma 4's constrained decoding is driven by this very schema. If a
///    device run shows the model fighting the string type here, that is the change
///    to make.
/// 3. **The technician outranks the agent, and the agent's value is kept rather
///    than dropped.** See [WorkOrderFormState.applyUpdates]. A model that writes
///    over a field a technician has just typed into is the single most annoying
///    thing this feature could do, and silently discarding what the model extracted
///    is the second — so a conflicting update lands in [FormFieldValue.suggestion]
///    for the technician to accept.
library;

import 'package:flutter/foundation.dart';

/// A field of the work order the agent may fill in.
///
/// Exactly the four the spec's §2.3 names ("fault code, replacement parts,
/// technician hours, safety checkpoints"). The [wireName] is what the model sees
/// and what a transcript records, so it is a declared string rather than
/// `Enum.name` — renaming a Dart enum value must not silently change the JSON the
/// golden suite snapshots, which is `ToolFailureCode`'s reasoning one file along.
enum WorkOrderField {
  faultCode('fault_code', 'Fault code', 'e.g. E-102'),
  requiredParts('required_parts', 'Replacement parts', 'e.g. BRK-990-XP'),
  technicianHours('technician_hours', 'Technician hours', 'e.g. 1.5'),
  safetyCheckpoints(
    'safety_checkpoints',
    'Safety checkpoints',
    'e.g. lockout/tagout verified',
  );

  const WorkOrderField(this.wireName, this.label, this.hint);

  /// The key the model uses, and the key the payload echoes.
  final String wireName;

  /// The technician-facing label on the form.
  final String label;

  /// Placeholder copy, so an empty form still says what belongs in each field.
  final String hint;

  /// The field [rawKey] names, or `null` when it names none.
  ///
  /// **Resolution is a property rather than a list of spellings**, which is
  /// `ToolCallGuard`'s rule reused rather than reimplemented: two keys match when
  /// they are equal after dropping case and every non-alphanumeric character, so
  /// `faultCode`, `Fault Code` and `fault-code` all reach [faultCode] without
  /// anyone having enumerated them. No edit distance and no prefix scoring, for the
  /// guard's reason — guessing wrong writes a value into the wrong field, which is
  /// worse than the refusal the model can recover from.
  ///
  /// The four [wireName]s are distinct under that normalisation, so nothing here
  /// can be ambiguous. That is asserted by a test rather than by this sentence,
  /// because it is a property of the four names and a fifth field could break it.
  ///
  /// There is deliberately **no early return for an empty normalised key**. One
  /// was here and mutation testing found it dead (M01: replacing it with `false`
  /// left the suite green): no [wireName] normalises to the empty string, so an
  /// unmatchable key already falls out of the loop below as `null`. It is deleted
  /// rather than kept as a comment claiming a guard, which is Task 1.4's rule.
  static WorkOrderField? byKey(String rawKey) {
    final key = normalizeKey(rawKey);
    for (final field in values) {
      if (normalizeKey(field.wireName) == key) return field;
    }
    return null;
  }

  /// Lower-cased with every non-alphanumeric character removed.
  @visibleForTesting
  static String normalizeKey(String raw) =>
      raw.toLowerCase().replaceAll(_nonAlphanumeric, '');

  static final RegExp _nonAlphanumeric = RegExp('[^a-z0-9]');
}

/// Why one entry of a `form_updates` map could not be applied.
///
/// Wire names for `ToolFailureCode`'s reason: they reach the model inside the tool
/// payload and they are snapshotted, so they are declared strings.
enum FormUpdateRejection {
  /// The key names no field of the work order.
  unknownField('unknown_field'),

  /// The value was present but not a string.
  notAString('not_a_string'),

  /// The value was a string, but blank once trimmed.
  ///
  /// Distinct from [notAString] because the corrective action differs: one is
  /// "send a string", the other is "send a value or omit the field". Blank is
  /// **not** treated as "clear this field", and that asymmetry is deliberate —
  /// a model emitting `""` for a field it has nothing to say about is far more
  /// likely than one deliberately erasing a technician's entry, and the erasing
  /// reading is the destructive one.
  blank('blank'),

  /// A `clarification` argument arrived but could not be put to a technician.
  ///
  /// One reason rather than four (not an object / no such field / no question /
  /// too few options) because unlike the field cases above they do not have
  /// different corrective actions — every one of them means "send the whole
  /// clarification object again, correctly". The *message* says which, on
  /// [FormUpdateRejection.blank]'s reasoning.
  unusableClarification('unusable_clarification');

  const FormUpdateRejection(this.wireName);

  final String wireName;
}

/// One entry of a `form_updates` map that was refused, and why.
@immutable
class RejectedFieldUpdate {
  const RejectedFieldUpdate({
    required this.key,
    required this.reason,
    required this.message,
  });

  /// The key **as the model spelled it**, not a canonical form. It is what the
  /// model has to correct, so it is what the payload quotes back.
  final String key;

  final FormUpdateRejection reason;

  /// Written for the model: what was wrong and what to send instead.
  final String message;

  @override
  bool operator ==(Object other) =>
      other is RejectedFieldUpdate &&
      other.key == key &&
      other.reason == reason &&
      other.message == message;

  @override
  int get hashCode => Object.hash(key, reason, message);

  @override
  String toString() => 'RejectedFieldUpdate($key, ${reason.wireName})';
}

/// What one `form_updates` map turned into.
@immutable
class FormUpdateParse {
  const FormUpdateParse({required this.accepted, required this.rejected});

  /// Every update that will be applied, canonicalised onto the enum.
  final Map<WorkOrderField, String> accepted;

  /// Every entry that will not, in the order the map presented them.
  final List<RejectedFieldUpdate> rejected;

  /// Nothing usable arrived. Not the same as [rejected] being empty — an empty
  /// map produces neither.
  bool get isEmpty => accepted.isEmpty;

  @override
  String toString() =>
      'FormUpdateParse(${accepted.length} accepted, '
      '${rejected.length} rejected)';
}

/// Reads a model-supplied `form_updates` map.
///
/// Never throws; see the library doc. Every *entry* that cannot be used becomes a
/// [RejectedFieldUpdate] and the rest still apply.
///
/// **Takes a map rather than `Object?`, and the asymmetry with
/// [parseClarification] is deliberate.** `form_updates` not being an object at all
/// is a failure of the whole call — there is nothing left to record — so it is
/// caught one layer up by `ToolArguments.requiredMap`, where Task 1.5 already
/// decided what a wrongly typed argument means. Putting a `raw is! Map` branch here
/// as well would be a second rule for one question, and it would be unreachable
/// from the only production caller. `clarification` gets the opposite treatment for
/// the opposite reason: it is an optional extra, so a malformed one must not take
/// good field updates down with it, and its refusal is a value.
///
/// The key type is `Object?` because this map crossed an isolate port and came out
/// of a plugin: JSON keys are strings once decoded, but nothing in the type system
/// says so by the time it arrives here.
FormUpdateParse parseFormUpdates(Map<Object?, Object?> raw) {
  final accepted = <WorkOrderField, String>{};
  final rejected = <RejectedFieldUpdate>[];

  for (final entry in raw.entries) {
    // The key of a JSON object is always a string once decoded, but this map has
    // also been through an isolate port and a plugin, so it is `Map<Object?,
    // Object?>` as far as the type system is concerned. `toString()` here is not
    // the coercion decision 2 above refuses — it is how a non-string key gets
    // *named* in its own rejection.
    final key = '${entry.key}';
    final field = WorkOrderField.byKey(key);
    if (field == null) {
      rejected.add(
        RejectedFieldUpdate(
          key: key,
          reason: FormUpdateRejection.unknownField,
          message:
              '"$key" is not a field of the work order; the fields are '
              '${WorkOrderField.values.map((f) => f.wireName).join(', ')}',
        ),
      );
      continue;
    }

    final value = entry.value;
    if (value is! String) {
      rejected.add(
        RejectedFieldUpdate(
          key: key,
          reason: FormUpdateRejection.notAString,
          message:
              '"$key" must be a string, but a ${value.runtimeType} was '
              'provided; send the value as text',
        ),
      );
      continue;
    }
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      rejected.add(
        RejectedFieldUpdate(
          key: key,
          reason: FormUpdateRejection.blank,
          message:
              '"$key" was blank; send a value or leave the field out of '
              '"$formUpdatesArgument" entirely',
        ),
      );
      continue;
    }
    // Last spelling wins when the model sends two keys that canonicalise alike
    // (`fault_code` and `faultCode` in one map). Recorded rather than guarded:
    // refusing both would lose a value the model did supply, and there is no
    // reading under which one of two identical-meaning keys is more authoritative
    // than the other.
    accepted[field] = trimmed;
  }

  return FormUpdateParse(accepted: accepted, rejected: rejected);
}

/// The argument name carrying the field map. Shared by the tool, the parser and
/// the tests so a rename cannot leave one of them behind.
const String formUpdatesArgument = 'form_updates';

/// The argument name carrying an optional clarification question.
const String clarificationArgument = 'clarification';

/// A question the agent needs answered before a field can be filled.
///
/// The spec's §2.3 example: a technician says "I replaced the filter" and the
/// inventory carries several, so the agent asks which. Rendered by
/// `views/components/clarification_dialog.dart`.
@immutable
class ClarificationRequest {
  const ClarificationRequest({
    required this.field,
    required this.question,
    required this.options,
  });

  /// The field an answer fills in.
  final WorkOrderField field;

  /// The question, in the agent's words.
  final String question;

  /// The answers offered, in the order they were sent. At least two — see
  /// [parseClarification].
  final List<String> options;

  @override
  bool operator ==(Object other) =>
      other is ClarificationRequest &&
      other.field == field &&
      other.question == question &&
      listEquals(other.options, options);

  @override
  int get hashCode => Object.hash(field, question, Object.hashAll(options));

  @override
  String toString() =>
      'ClarificationRequest(${field.wireName}, ${options.length} options)';
}

/// What a `clarification` argument turned into: a request, or the reason there is
/// none.
@immutable
class ClarificationParse {
  const ClarificationParse.absent() : request = null, rejection = null;
  const ClarificationParse.parsed(ClarificationRequest this.request)
    : rejection = null;
  const ClarificationParse.refused(RejectedFieldUpdate this.rejection)
    : request = null;

  final ClarificationRequest? request;

  /// Why a clarification that *was* sent could not be shown. `null` both when one
  /// parsed and when none was sent — [request] is what tells those apart.
  final RejectedFieldUpdate? rejection;
}

/// Reads a model-supplied `clarification` argument.
///
/// **Two or more options, or it is not a clarification.** A question with one
/// answer is an assertion, and rendering it as a chooser would put a technician in
/// front of a dialog whose only move is to agree — worse than not asking, because
/// it looks like a decision was taken. Zero options is a question with no way to
/// answer it. Both are refused and fed back rather than shown.
ClarificationParse parseClarification(Object? raw) {
  RejectedFieldUpdate refuse(String message) => RejectedFieldUpdate(
    key: clarificationArgument,
    reason: FormUpdateRejection.unusableClarification,
    message: message,
  );

  if (raw == null) return const ClarificationParse.absent();
  if (raw is! Map) {
    return ClarificationParse.refused(
      refuse(
        '"$clarificationArgument" must be an object with "field", "question" '
        'and "options", but a ${raw.runtimeType} was provided',
      ),
    );
  }

  final rawField = '${raw['field']}';
  final field = WorkOrderField.byKey(rawField);
  if (field == null) {
    return ClarificationParse.refused(
      refuse(
        '"$clarificationArgument.field" must name a work-order field '
        '(${WorkOrderField.values.map((f) => f.wireName).join(', ')}), but '
        '"$rawField" does not',
      ),
    );
  }

  final question = raw['question'];
  if (question is! String || question.trim().isEmpty) {
    return ClarificationParse.refused(
      refuse(
        '"$clarificationArgument.question" must be the question to put to the '
        'technician, as a non-empty string',
      ),
    );
  }

  final rawOptions = raw['options'];
  if (rawOptions is! List) {
    return ClarificationParse.refused(
      refuse(
        '"$clarificationArgument.options" must be a list of at least two '
        'answers to choose between',
      ),
    );
  }

  // Non-string and blank entries are dropped rather than failing the whole
  // clarification, and then the count is checked: what matters to a technician is
  // whether two real choices survived, and a list of three where one arrived as
  // `null` still asks a coherent question. Duplicates are dropped for the same
  // reason a one-option chooser is refused — two buttons with the same words are
  // one choice wearing a disguise.
  final options = <String>[];
  for (final option in rawOptions) {
    if (option is! String) continue;
    final trimmed = option.trim();
    if (trimmed.isEmpty || options.contains(trimmed)) continue;
    options.add(trimmed);
  }
  if (options.length < 2) {
    return ClarificationParse.refused(
      refuse(
        '"$clarificationArgument.options" needs at least two distinct '
        'non-empty answers to choose between; ${options.length} usable '
        'option(s) arrived',
      ),
    );
  }

  return ClarificationParse.parsed(
    ClarificationRequest(
      field: field,
      question: question.trim(),
      options: List.unmodifiable(options),
    ),
  );
}

/// Where the text in a field came from.
enum FormFieldOrigin {
  /// The agent extracted it from the inquiry.
  agent,

  /// The technician typed it.
  technician,

  /// The technician chose it from a clarification.
  ///
  /// Distinct from [technician] because the two answer different questions about
  /// a field: both mean "a human decided this", but only this one means "the agent
  /// asked and got an answer", which is the interaction §2.3 is about.
  clarification,
}

/// One field's contents.
@immutable
class FormFieldValue {
  const FormFieldValue({
    required this.text,
    required this.origin,
    this.suggestion,
  });

  final String text;
  final FormFieldOrigin origin;

  /// A value the agent extracted that was **not** applied, because the technician
  /// had already written this field themselves.
  ///
  /// See [WorkOrderFormState.applyUpdates]. Kept rather than dropped so the
  /// disagreement is visible and one tap away from being resolved either way.
  final String? suggestion;

  /// Whether the agent has something to offer that is not already in the field.
  bool get hasSuggestion => suggestion != null;

  FormFieldValue copyWith({
    String? text,
    FormFieldOrigin? origin,
    Object? suggestion = _unset,
  }) => FormFieldValue(
    text: text ?? this.text,
    origin: origin ?? this.origin,
    suggestion: suggestion == _unset ? this.suggestion : suggestion as String?,
  );

  static const Object _unset = Object();

  @override
  bool operator ==(Object other) =>
      other is FormFieldValue &&
      other.text == text &&
      other.origin == origin &&
      other.suggestion == suggestion;

  @override
  int get hashCode => Object.hash(text, origin, suggestion);

  @override
  String toString() =>
      'FormFieldValue($text, ${origin.name}'
      '${suggestion == null ? '' : ', suggests: $suggestion'})';
}

/// The whole form: what is in it, what the agent still wants to ask, and what it
/// sent that could not be used.
@immutable
class WorkOrderFormState {
  const WorkOrderFormState({
    this.fields = const {},
    this.clarification,
    this.rejected = const [],
  });

  /// Filled fields only. A field absent from this map is an empty field, which is
  /// why there is no "empty" [FormFieldValue] — one representation of emptiness,
  /// not two.
  final Map<WorkOrderField, FormFieldValue> fields;

  /// The question waiting for the technician, or `null`.
  ///
  /// At most one at a time: a second dialog stacked over the first is a technician
  /// answering questions instead of fixing an elevator, and the agent has a whole
  /// next turn in which to ask again.
  final ClarificationRequest? clarification;

  /// Every update the agent sent that was refused, newest run last.
  ///
  /// On the state rather than only in the tool payload because the tool's copy
  /// goes to the *model*, and this one is what a person debugging a demo reads.
  final List<RejectedFieldUpdate> rejected;

  /// Whether anything at all has been filled in.
  bool get isEmpty => fields.isEmpty;

  /// The text of [field], or `''`.
  String textOf(WorkOrderField field) => fields[field]?.text ?? '';

  /// Applies a parsed set of updates from the **agent**.
  ///
  /// **A field the technician wrote is not overwritten.** The incoming value is
  /// parked on [FormFieldValue.suggestion] instead, so nothing the model extracted
  /// is lost and nothing the technician typed is lost either. The alternatives are
  /// both worse in a way that shows up on a demo: overwriting means a value
  /// vanishing under a thumb mid-dictation, and dropping means the agent silently
  /// failing to record what it heard.
  ///
  /// An agent update that *equals* what the technician already wrote clears the
  /// suggestion rather than raising one — there is no disagreement to resolve, and
  /// a "the agent suggests E-102" badge beside a field reading `E-102` is noise
  /// that reads as a defect.
  WorkOrderFormState applyUpdates(FormUpdateParse parse) {
    final next = Map<WorkOrderField, FormFieldValue>.of(fields);
    for (final entry in parse.accepted.entries) {
      final existing = next[entry.key];
      final humanHeld =
          existing != null && existing.origin != FormFieldOrigin.agent;
      if (!humanHeld) {
        next[entry.key] = FormFieldValue(
          text: entry.value,
          origin: FormFieldOrigin.agent,
        );
      } else if (existing.text == entry.value) {
        next[entry.key] = existing.copyWith(suggestion: null);
      } else {
        next[entry.key] = existing.copyWith(suggestion: entry.value);
      }
    }
    return copyWith(fields: next, rejected: [...rejected, ...parse.rejected]);
  }

  /// Records what the technician typed into [field].
  ///
  /// Clearing a field is what a blank [text] means here, and it is the one place
  /// blank means "erase" — the asymmetry with [FormUpdateRejection.blank] is
  /// deliberate and is argued there. A technician who selects a field's contents
  /// and deletes them has said something; a model emitting `""` has not.
  WorkOrderFormState withTechnicianEntry(WorkOrderField field, String text) {
    final next = Map<WorkOrderField, FormFieldValue>.of(fields);
    if (text.trim().isEmpty) {
      next.remove(field);
    } else {
      next[field] = FormFieldValue(
        text: text,
        origin: FormFieldOrigin.technician,
        // Any pending suggestion is about text that no longer exists.
        suggestion: null,
      );
    }
    return copyWith(fields: next);
  }

  /// Takes the agent's parked suggestion for [field] and puts it in the field.
  ///
  /// A no-op when there is nothing parked, rather than a throw: the button that
  /// calls this is drawn from the same state, so the only way to reach it with an
  /// empty suggestion is a race, and losing that race should not crash the screen.
  WorkOrderFormState acceptSuggestion(WorkOrderField field) {
    final existing = fields[field];
    final suggestion = existing?.suggestion;
    if (existing == null || suggestion == null) return this;
    final next = Map<WorkOrderField, FormFieldValue>.of(fields)
      ..[field] = FormFieldValue(
        text: suggestion,
        // The technician accepted it, so it is a human decision about a human's
        // field — not the agent overruling one. That keeps the next agent update
        // parked rather than applied, which is the rule they just exercised.
        origin: FormFieldOrigin.technician,
      );
    return copyWith(fields: next);
  }

  /// Drops the agent's parked suggestion for [field], keeping what is there.
  WorkOrderFormState dismissSuggestion(WorkOrderField field) {
    final existing = fields[field];
    if (existing == null || !existing.hasSuggestion) return this;
    final next = Map<WorkOrderField, FormFieldValue>.of(fields)
      ..[field] = existing.copyWith(suggestion: null);
    return copyWith(fields: next);
  }

  /// Puts a question to the technician.
  WorkOrderFormState withClarification(ClarificationRequest request) =>
      copyWith(clarification: request);

  /// Answers the pending clarification with [choice].
  ///
  /// The answer goes into the field **whatever is already there**, including a
  /// value the technician typed, because choosing an option *is* the technician
  /// speaking — this is the one path where a human overrules a human, and they are
  /// the same human.
  ///
  /// **What this deliberately does not do is resume the agent's run**, and that
  /// bound is stated rather than hidden. `AgentLoop.run` is a single stream over
  /// one inquiry; feeding an answer back mid-run would mean a second input channel
  /// into a loop whose whole design is "the conversation is the prompt". The answer
  /// fills the field and is offered as the seed of a follow-up inquiry, which is
  /// the interaction §2.3 describes minus the round trip.
  WorkOrderFormState answerClarification(String choice) {
    final request = clarification;
    if (request == null) return this;
    final trimmed = choice.trim();
    if (trimmed.isEmpty) return this;
    final next = Map<WorkOrderField, FormFieldValue>.of(fields)
      ..[request.field] = FormFieldValue(
        text: trimmed,
        origin: FormFieldOrigin.clarification,
      );
    return copyWith(fields: next, clarification: null);
  }

  /// Dismisses the pending clarification without answering it.
  WorkOrderFormState withoutClarification() => copyWith(clarification: null);

  WorkOrderFormState copyWith({
    Map<WorkOrderField, FormFieldValue>? fields,
    Object? clarification = _unset,
    List<RejectedFieldUpdate>? rejected,
  }) => WorkOrderFormState(
    fields: fields ?? this.fields,
    // The sentinel, for `FieldJobState.copyWith`'s reason: without it, clearing
    // the clarification is indistinguishable from leaving it alone, and clearing
    // it is the common case.
    clarification: clarification == _unset
        ? this.clarification
        : clarification as ClarificationRequest?,
    rejected: rejected ?? this.rejected,
  );

  static const Object _unset = Object();

  @override
  String toString() =>
      'WorkOrderFormState(${fields.length} filled'
      '${clarification == null ? '' : ', asking'}'
      '${rejected.isEmpty ? '' : ', ${rejected.length} refused'})';
}
