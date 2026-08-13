/// The work order on screen: four fields the agent fills and the technician owns.
///
/// **It is deliberately outside the answer panel**, and that is a layout decision
/// with a mechanism behind it rather than a matter of taste. `_ResultPanel`
/// auto-scrolls to its own bottom on every token (Task 1.11's R0-F6), and Task
/// 1.11's R12-F0 records what putting an interactive surface inside that is worth:
/// `jumpTo` opens with `goIdle()`, which **disposes the active drag**, so a
/// technician editing a field inside the streaming panel would have every
/// keystroke's worth of gesture cancelled underneath them. Text fields do not live
/// in a container that jumps.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/form_state_model.dart';
import '../../viewmodels/work_order_form_viewmodel.dart';

/// Keys the widget tests find things by.
abstract final class WorkOrderKeys {
  static const Key panel = Key('work-order-panel');

  static Key field(WorkOrderField field) => Key('work-order-${field.wireName}');

  /// The row offering the agent's value for a field the technician has written.
  static Key suggestion(WorkOrderField field) =>
      Key('work-order-suggestion-${field.wireName}');

  static Key acceptSuggestion(WorkOrderField field) =>
      Key('work-order-accept-${field.wireName}');

  static Key dismissSuggestion(WorkOrderField field) =>
      Key('work-order-dismiss-${field.wireName}');
}

/// The four fields, filled by the agent and editable by the technician.
class WorkOrderFormPanel extends ConsumerWidget {
  const WorkOrderFormPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final form = ref.watch(workOrderFormProvider);
    // `watch` on the controllers is safe and `listen` on the state is what keeps
    // them fresh — see `workOrderFormControllersProvider`, which is a `Provider`
    // that never rebuilds, so this hands back the same instances every frame.
    final controllers = ref.watch(workOrderFormControllersProvider);
    final notifier = ref.read(workOrderFormProvider.notifier);

    return Container(
      key: WorkOrderKeys.panel,
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      // **The header scrolls with the fields rather than being pinned above
      // them**, which is not a style choice: pinned chrome is fixed height, and a
      // fixed-height header plus a divider plus this padding overflows the box on
      // a short viewport before the first field is drawn. Everything inside one
      // scroll view means the panel degrades to "scroll to see it" instead of to a
      // yellow-and-black overflow stripe, which is what it did at 800x600.
      //
      // `SingleChildScrollView` + `Column` rather than a `ListView`, which is a
      // deliberate refusal to virtualise: there are four fields, and a `ListView`
      // does not build the ones below the fold — so a field the agent filled would
      // not exist in the tree until someone scrolled to it, and neither a test nor
      // a screen reader could reach it. Virtualisation is for lists whose length is
      // unknown; this one is `WorkOrderField.values`.
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.assignment_outlined,
                  size: 18,
                  color: theme.colorScheme.outline,
                ),
                const SizedBox(width: 8),
                Text(
                  'Work order',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
                const Spacer(),
                Text(
                  // A count rather than a "filled by the agent" badge: the origin
                  // is per field and already visible through the suggestion rows,
                  // and a single badge would have to pick one answer for four
                  // fields that can disagree.
                  '${form.fields.length} of ${WorkOrderField.values.length}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ],
            ),
            const Divider(height: 16),
            for (final field in WorkOrderField.values)
              _Field(
                field: field,
                value: form.fields[field],
                controller: controllers[field],
                onChanged: (text) => notifier.setTechnicianEntry(field, text),
                onAccept: () => notifier.acceptSuggestion(field),
                onDismiss: () => notifier.dismissSuggestion(field),
              ),
          ],
        ),
      ),
    );
  }
}

/// One field, and the agent's parked value for it when there is one.
class _Field extends StatelessWidget {
  const _Field({
    required this.field,
    required this.value,
    required this.controller,
    required this.onChanged,
    required this.onAccept,
    required this.onDismiss,
  });

  final WorkOrderField field;
  final FormFieldValue? value;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onAccept;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final suggestion = value?.suggestion;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: WorkOrderKeys.field(field),
            controller: controller,
            // `onChanged` and not a controller listener, which is the property
            // `WorkOrderFormViewModel`'s library doc rests on: this fires for a
            // *user* edit only, so the state → controller sync cannot echo back
            // as a technician entry and overwrite its own origin.
            onChanged: onChanged,
            decoration: InputDecoration(
              labelText: field.label,
              hintText: field.hint,
              isDense: true,
              border: const OutlineInputBorder(),
              // A quiet marker rather than a colour change: the agent having
              // filled a field is information, and re-tinting a form the moment
              // the model writes to it reads as an error state.
              suffixIcon: value?.origin == FormFieldOrigin.agent
                  ? Tooltip(
                      message: 'Filled by the assistant',
                      child: Icon(
                        Icons.auto_awesome,
                        size: 18,
                        color: theme.colorScheme.outline,
                      ),
                    )
                  : null,
            ),
          ),
          if (suggestion != null)
            Padding(
              key: WorkOrderKeys.suggestion(field),
              padding: const EdgeInsets.only(top: 6, left: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      // The technician's own value is on screen directly above,
                      // so this quotes only what is being offered.
                      'The assistant heard "$suggestion"',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ),
                  TextButton(
                    key: WorkOrderKeys.acceptSuggestion(field),
                    onPressed: onAccept,
                    child: const Text('Use it'),
                  ),
                  TextButton(
                    key: WorkOrderKeys.dismissSuggestion(field),
                    onPressed: onDismiss,
                    child: const Text('Keep mine'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
