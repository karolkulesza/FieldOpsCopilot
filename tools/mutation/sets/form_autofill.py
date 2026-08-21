"""The work-order auto-fill slice: form state, the recording tool, the two
viewmodels that write it, and the three widgets that show it.

A *focused* set rather than a full sweep over the diff: what is probed is the
decisions this slice makes, not every line it wrote. Twenty-two rows.

Two rows are expected to survive, and each says so at the row. A row kept with
its survival written down is a finding; a row deleted because it survived is a
harness that only ever agrees with itself.
"""

# Suites run for every row. One list, not per-row, so a row cannot look green by
# being pointed at a suite that does not exercise it.
SUITES = [
    "test/models",
    "test/services/ai",
    "test/services/audio",
    "test/viewmodels",
    "test/views",
    "test/golden",
]

MUTATIONS = [
    # --- form_state_model.dart --------------------------------------------------
    # M01 is retired rather than repaired. It replaced `if (key.isEmpty) return
    # null;` in `WorkOrderField.byKey` with `if (false)` and **SURVIVED** — correctly,
    # because no wire name normalises to the empty string, so the loop below already
    # answers `null`. The line was dead and is deleted; there is nothing left to
    # mutate. Recorded here rather than silently dropped, because a row that vanishes
    # from a harness looks like a row that was never run.
    dict(
        label="M02-blank-value-accepted",
        file="lib/models/form_state_model.dart",
        old="    final trimmed = value.trim();\n    if (trimmed.isEmpty) {",
        new="    final trimmed = value.trim();\n    if (false) {",
        count=1,
        expect="'a blank string is its own rejection, not \"not a string\"'",
    ),
    # **Rewritten after the first run, and the reason is the point.** The original
    # replaced the type test with a null test, which left `value.trim()` below it
    # applied to an `Object?` — so the mutation did not compile, the suite failed to
    # load, and the row reported KILLED without a single assertion having run. A kill
    # by compile error measures the type system, not the tests. This version performs
    # the coercion the guard exists to refuse, and compiles.
    dict(
        label="M03-non-string-coerced",
        file="lib/models/form_state_model.dart",
        old=(
            "    final value = entry.value;\n"
            "    if (value is! String) {"
        ),
        new=(
            "    final value = '${entry.value}';\n"
            "    if (false) {"
        ),
        count=1,
        expect="'a non-string value is refused rather than coerced'",
    ),
    # Rewritten for M03's reason: `const humanHeld = false;` destroyed the null
    # promotion the `else` branch depends on, so it was another compile-error kill.
    # This keeps the promotion and inverts only the *rule*.
    dict(
        label="M04-agent-overwrites-technician",
        file="lib/models/form_state_model.dart",
        old="          existing != null && existing.origin != FormFieldOrigin.agent;",
        new="          existing != null && existing.origin == FormFieldOrigin.agent;",
        count=1,
        expect="'a conflicting agent update is parked, not applied'",
    ),
    dict(
        label="M05-agreeing-update-still-suggests",
        file="lib/models/form_state_model.dart",
        old="      } else if (existing.text == entry.value) {",
        new="      } else if (false) {",
        count=1,
        expect="'an agreeing agent update raises no suggestion'",
    ),
    dict(
        label="M06-technician-blank-does-not-clear",
        file="lib/models/form_state_model.dart",
        old="    if (text.trim().isEmpty) {\n      next.remove(field);",
        new="    if (false) {\n      next.remove(field);",
        count=1,
        expect="'a technician clearing a field removes it'",
    ),
    dict(
        label="M07-one-option-is-a-question",
        file="lib/models/form_state_model.dart",
        old="  if (options.length < 2) {",
        new="  if (options.length < 1) {",
        count=1,
        expect="'fewer than two usable options is refused'",
    ),
    dict(
        label="M08-duplicate-options-kept",
        file="lib/models/form_state_model.dart",
        old="    if (trimmed.isEmpty || options.contains(trimmed)) continue;",
        new="    if (trimmed.isEmpty) continue;",
        count=1,
        expect="'duplicate options are collapsed, keeping the first spelling'",
    ),
    dict(
        label="M09-answer-leaves-question-open",
        file="lib/models/form_state_model.dart",
        old="    return copyWith(fields: next, clarification: null);",
        new="    return copyWith(fields: next);",
        count=1,
        expect="'answering fills the field and closes the question'",
    ),
    # --- record_work_order_fields_tool.dart -------------------------------------
    dict(
        label="M10-payload-reader-accepts-junk",
        file="lib/services/ai/tools/record_work_order_fields_tool.dart",
        old=(
            "    if (field == null || value is! String || value.trim().isEmpty) "
            "continue;"
        ),
        new="    if (field == null) continue;",
        count=1,
        expect="'inert on a payload that is not'",
    ),
    # --- work_order_form_viewmodel.dart -----------------------------------------
    dict(
        label="M11-any-tool-fills-the-form",
        file="lib/viewmodels/work_order_form_viewmodel.dart",
        old=(
            "    if (invocation.call.name != RecordWorkOrderFieldsTool.toolName) {\n"
            "      return false;\n"
            "    }"
        ),
        new="",
        count=1,
        expect="'a completion from another tool is ignored'",
    ),
    # **Expected to SURVIVE, and that is the row's finding rather than its failure.**
    # `ToolOutcome` is sealed and `ToolFailure.payload` is a computed
    # `{error, parameter?, message}` with no `recorded` key, so `applyPayload` already
    # answers `false` for a failure — the check is unreachable by construction. It is
    # kept with that written down at the site (see the method doc) rather than deleted,
    # because it states the rule where the decision belongs. Left in the harness so the
    # claim is re-measured rather than remembered.
    dict(
        label="M12-a-failed-call-fills-the-form",
        file="lib/viewmodels/work_order_form_viewmodel.dart",
        old="    if (outcome is! ToolSuccess) return false;",
        new="    if (outcome is ToolSuccess && false) return false;",
        count=1,
        expect="'a call the tool refuses fills nothing'",
    ),
    dict(
        label="M13-controller-written-unconditionally",
        file="lib/viewmodels/work_order_form_viewmodel.dart",
        old="      if (controller.text == text) continue;",
        new="      if (false) continue;",
        count=1,
        expect="'an update to one field does not move the caret in another'",
    ),
    # --- dictation_viewmodel.dart -----------------------------------------------
    dict(
        label="M14-final-appends-instead-of-indexing",
        file="lib/viewmodels/dictation_viewmodel.dart",
        old="    committed[transcript.segment] = transcript.text;",
        new="    committed.add(transcript.text);",
        count=1,
        expect="'a re-emitted final replaces its segment rather than appending'",
    ),
    # **Re-keyed after `--verify` reported it drifted, and the drift is the
    # argument for having `--verify` at all.** The row was written against
    # `await _closed?.future;`. A later device fix split that into a null test with
    # an `else if` branch, for a state that only exists since the microphone was
    # moved ahead of the model load — so the row matched nothing and would have
    # ABORTED forty suite-runs into a sweep. The mutation is unchanged in substance:
    # stop returns without waiting for the flush.
    dict(
        label="M15-stop-does-not-wait-for-the-flush",
        file="lib/viewmodels/dictation_viewmodel.dart",
        old="      await closed.future;",
        new="      ;",
        count=1,
        expect="'stop waits for the final transcript the flush produces'",
    ),
    dict(
        label="M16-a-fault-keeps-the-partial",
        file="lib/viewmodels/dictation_viewmodel.dart",
        old="      partial: '',\n      message: error is MicCaptureFault",
        new="      message: error is MicCaptureFault",
        count=1,
        expect="'a microphone fault fails the dictation and quotes it'",
    ),
    # --- diagnose_screen.dart ---------------------------------------------------
    dict(
        label="M17-diagnose-live-while-dictating",
        file="lib/views/diagnose_screen.dart",
        old="        !dictation.isActive &&",
        new="",
        count=1,
        expect="'Diagnose is inert while the microphone is open'",
    ),
    # --- clarification_dialog.dart ----------------------------------------------
    dict(
        label="M18-second-question-does-not-retarget",
        file="lib/views/components/clarification_dialog.dart",
        old="        showing.value = next;\n        return;",
        new="        return;",
        count=1,
        expect="'a second question retargets the one overlay'",
    ),
    # **M19 survived, and what it established is that the sequence it seemed to
    # expose does not exist.** The row expected `_present`'s tail check to be
    # load-bearing. It is not, and the plausible story — a question arriving while
    # the route animates out, then dismissed by that route's close — was written up,
    # implemented behind a `_closing` flag, and then **measured and reverted**: an
    # instrumented trace showed `showDialog`'s future resolving in the same frame as
    # the pop, with `choice: null` and nothing pending, while the route was still
    # painting its exit. There is no window. The row is kept exactly as it was so the
    # survival stays on the record rather than being quietly deleted; the code now
    # says at the site that this check is belt-and-braces.
    dict(
        label="M19-close-always-dismisses",
        file="lib/views/components/clarification_dialog.dart",
        old="    if (ref.read(workOrderFormProvider).clarification != null) {",
        new="    if (true) {",
        count=1,
        expect="'answering with the button does not dismiss anything'",
    ),
    dict(
        label="M20-technician-edit-not-recorded",
        file="lib/views/components/work_order_form_panel.dart",
        old="            onChanged: onChanged,",
        new="",
        count=1,
        expect="'typing into a field records it as the'",
    ),
]

