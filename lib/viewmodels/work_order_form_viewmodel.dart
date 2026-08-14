/// The work-order form as UI state, and the `TextEditingController`s the screen
/// renders it through.
///
/// `FieldJobViewModel` owns one *diagnosis*; this owns the form that outlives it.
/// A technician runs several inquiries against one job — "cabin vibrating, E-102",
/// then "how long will the brake pad take" — and the fields they have filled in
/// must survive the second one. So this is deliberately **not** reset when a run
/// starts, and the only things that clear a field are a technician clearing it and
/// [WorkOrderFormViewModel.reset].
///
/// **Where the values come from is one hop, not two.** `AgentLoop` emits
/// `AgentToolCallCompleted` while the run is still streaming, `FieldJobViewModel`
/// is already draining that stream, and it hands each completion here. The
/// alternative — deriving the form from `FieldJobState.invocations` with a cursor
/// into a growing list — was rejected because the cursor has to be reset on a
/// boundary the list does not itself mark, and getting that wrong silently skips
/// updates rather than failing.
///
/// **Two controllers for one string is the one duplication this file cannot avoid,
/// so it is made one-directional.** Flutter's text field needs a
/// `TextEditingController`, and [WorkOrderFormState] is the truth; keeping them in
/// step is [workOrderFormControllersProvider]'s whole job, and it works because
/// `TextField.onChanged` fires for **user edits only** and not for a programmatic
/// `controller.text = …`. That is what makes the state → controller direction safe
/// to write unconditionally without it echoing back as a technician entry. It is a
/// property of the framework rather than of this code, so it is pinned by a widget
/// test rather than trusted.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/form_state_model.dart';
import '../services/ai/agent_loop.dart';
import '../services/ai/base_tool.dart';
import '../services/ai/tools/record_work_order_fields_tool.dart';

/// Holds the work order the agent is filling in.
class WorkOrderFormViewModel extends Notifier<WorkOrderFormState> {
  @override
  WorkOrderFormState build() => const WorkOrderFormState();

  /// Applies one finished tool call, if it was a form recording.
  ///
  /// Ignores every other tool and every failure, rather than asserting: this is
  /// called for *every* completion the loop reports, and one of the two registered
  /// tools is a warehouse lookup. A `ToolFailure` is ignored because the failure
  /// codes are reserved for a call that recorded nothing (see the tool's class
  /// doc), so there is nothing in the payload to apply — and because a technician
  /// does not need the form to react to the model mis-spelling an argument.
  ///
  /// **The `ToolSuccess` check is unreachable today, and is recorded as unbound
  /// rather than dressed up as a guard.** Mutation M12 deletes it and the suite
  /// stays green, which is correct and not a coverage gap: `ToolOutcome` is sealed,
  /// so a failure is a `ToolFailure`, and `ToolFailure.payload` is a computed
  /// `{error, parameter?, message}` — it carries **none** of the three keys
  /// [applyPayload] reads (`recorded`, `refused`, `asked`), so that method already
  /// answers `false` for one. Stated over all three rather than over `recorded`
  /// alone, because review finding R0-F4 added the second and the narrower sentence
  /// would have gone quietly stale.
  ///
  /// It is kept because it puts the rule where the decision belongs instead of
  /// making this method depend on a payload shape defined one file away. The name
  /// check above is a different matter and *is* bound (M11).
  ///
  /// Returns whether anything changed, so a caller can tell "no form call" from
  /// "a form call that recorded nothing". Nothing in the app branches on it today;
  /// the tests do, and a bool is cheaper than making them diff the state.
  bool applyInvocation(AgentToolInvocation invocation) {
    if (invocation.call.name != RecordWorkOrderFieldsTool.toolName) {
      return false;
    }
    final outcome = invocation.outcome;
    if (outcome is! ToolSuccess) return false;
    return applyPayload(outcome.payload);
  }

  /// Applies one [RecordWorkOrderFieldsTool] payload.
  ///
  /// Separate from [applyInvocation] because the payload is the whole of what this
  /// reads — see the tool's class doc for why the payload rather than the call's
  /// arguments — and a test of the *form* behaviour should not have to build an
  /// `AgentToolInvocation` around a map.
  bool applyPayload(Map<String, Object?> payload) {
    final recorded = recordedFieldsOf(payload);
    final asked = askedClarificationOf(payload);
    // **Read rather than discarded — review finding R0-F4.** This used to pass
    // `rejected: const []`, so `WorkOrderFormState.rejected` was dead on every
    // production path while its docstring claimed to be what someone debugging a
    // demo reads. The refusals are the model's mistakes, and they are worth seeing
    // beside the form rather than only in the transcript the model got.
    final refused = refusedUpdatesOf(payload);
    if (recorded.isEmpty && asked == null && refused.isEmpty) return false;

    var next = state.applyUpdates(
      FormUpdateParse(accepted: recorded, rejected: refused),
    );
    if (asked != null) next = next.withClarification(asked);
    state = next;
    return true;
  }

  /// Records what the technician typed into [field].
  void setTechnicianEntry(WorkOrderField field, String text) {
    state = state.withTechnicianEntry(field, text);
  }

  /// Takes the agent's parked value for [field].
  void acceptSuggestion(WorkOrderField field) {
    state = state.acceptSuggestion(field);
  }

  /// Drops the agent's parked value for [field].
  void dismissSuggestion(WorkOrderField field) {
    state = state.dismissSuggestion(field);
  }

  /// Answers the pending clarification.
  void answerClarification(String choice) {
    state = state.answerClarification(choice);
  }

  /// Closes the pending clarification without answering it.
  void dismissClarification() {
    state = state.withoutClarification();
  }

  /// Empties the form — a new job, not a new inquiry.
  void reset() {
    state = const WorkOrderFormState();
  }
}

/// The one work order the demo screen fills in.
final workOrderFormProvider =
    NotifierProvider<WorkOrderFormViewModel, WorkOrderFormState>(
      WorkOrderFormViewModel.new,
    );

/// One `TextEditingController` per field, kept in step with
/// [workOrderFormProvider].
///
/// **Why the controllers are a provider rather than widget state.** The AC
/// (TC-VM-FORM-01) is a unit-tier assertion that the `fault_code` controller holds
/// `"E-102"` after the agent recorded it, and a controller owned by a `State`
/// object can only be reached by pumping a widget. More usefully: the sync has to
/// happen whether or not the form is on screen, because the agent records fields
/// while the technician is scrolled to the answer.
class WorkOrderFormControllers {
  WorkOrderFormControllers()
    : _byField = {
        for (final field in WorkOrderField.values)
          field: TextEditingController(),
      };

  final Map<WorkOrderField, TextEditingController> _byField;

  /// The controller for [field]. Never null — one exists for every field from
  /// construction, so a caller never has to handle an absent one.
  TextEditingController operator [](WorkOrderField field) => _byField[field]!;

  /// Pushes [state] into the controllers.
  ///
  /// **Writes only when the text actually differs**, and that is not an
  /// optimisation: assigning `controller.text` rebuilds the `TextEditingValue`,
  /// which drops the selection — so a technician with a cursor mid-word in a field
  /// the agent did not touch would lose it on every token that changed some *other*
  /// field. The comparison is what keeps an untouched field untouched.
  ///
  /// When it does write, the caret goes to the end rather than to `-1`: the value
  /// was just replaced under the technician, and the end is where they would
  /// continue from.
  @visibleForTesting
  void sync(WorkOrderFormState state) {
    for (final field in WorkOrderField.values) {
      final controller = _byField[field]!;
      final text = state.textOf(field);
      if (controller.text == text) continue;
      controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }
  }

  void dispose() {
    for (final controller in _byField.values) {
      controller.dispose();
    }
  }
}

/// Controllers wired to the form state.
///
/// `listen` rather than `watch`: watching would rebuild this provider on every
/// keystroke and hand the screen a *new* set of controllers, which is a text field
/// that loses focus as you type. The controllers are stable for the life of the
/// provider and their contents are the thing that changes.
final workOrderFormControllersProvider = Provider<WorkOrderFormControllers>((
  ref,
) {
  final controllers = WorkOrderFormControllers()
    // Seeded before any listener fires, so a form that already has values — a
    // provider rebuilt after the agent recorded something — shows them on the
    // first frame rather than on the next change.
    ..sync(ref.read(workOrderFormProvider));
  ref.listen<WorkOrderFormState>(
    workOrderFormProvider,
    (previous, next) => controllers.sync(next),
  );
  ref.onDispose(controllers.dispose);
  return controllers;
});
