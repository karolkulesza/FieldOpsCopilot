/// The agent's question to the technician, and the overlay that puts it.
///
/// The spec's §2.3 third bullet: *"If mandatory fields are missing or ambiguous
/// … the agent dynamically prompts the user: 'Which filter did you use: the
/// 12-inch mesh or the 14-inch carbon?' using a text-to-speech speaker or inline
/// UI selector."* Spoken output is Task 2.5; this is the selector.
///
/// **It is modal, which is a decision rather than the default.** An inline card
/// would be less intrusive, and it was rejected because of where this arrives: the
/// clarification comes back on the *same* tool call that records the fields, so it
/// lands while tokens are streaming into a panel the technician is watching. An
/// inline card would appear above or below that panel and be scrolled past — and a
/// question nobody answers is worse than no question, because the agent's next
/// turn is written as though it had been asked. The cost is stated plainly: a modal
/// interrupts a stream that is mid-sentence. It is dismissible for exactly that
/// reason, and dismissing is a first-class outcome rather than a way out of a
/// dialog that should not have opened.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/form_state_model.dart';
import '../../viewmodels/work_order_form_viewmodel.dart';

/// Keys the widget tests find things by, so an assertion names a role rather than
/// a string of copy. Mirrors `DiagnoseKeys` one directory up.
abstract final class ClarificationKeys {
  static const Key dialog = Key('clarification-dialog');
  static const Key question = Key('clarification-question');
  static const Key dismiss = Key('clarification-dismiss');

  /// One key per offered answer, by position.
  ///
  /// **By position rather than by the option's text**, which is the opposite of
  /// what a key usually wants — and the reason is that the text comes from the
  /// *model*. A key built from it would be built from weights, so two options that
  /// differ only in trailing punctuation would still be distinct while two that
  /// arrived identical would collide. `parseClarification` already drops duplicates
  /// and blanks, so position is total and stable here.
  static Key option(int index) => Key('clarification-option-$index');
}

/// One question, with a button per answer.
///
/// A plain widget over a [ClarificationRequest] rather than something that reads a
/// provider: it is what [showClarificationDialog] pushes, and keeping it dumb is
/// what lets TC-UI-CLAR-01 pump the option list the AC names without standing up
/// an agent, a registry and a database behind it.
class ClarificationDialog extends StatelessWidget {
  const ClarificationDialog({
    required this.request,
    required this.onChosen,
    required this.onDismissed,
    super.key,
  });

  final ClarificationRequest request;

  /// Called with the chosen option's exact text — what goes into the field.
  final ValueChanged<String> onChosen;

  /// Called when the technician closes the question without answering it.
  final VoidCallback onDismissed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      key: ClarificationKeys.dialog,
      icon: Icon(Icons.help_outline, color: theme.colorScheme.primary),
      title: Text(
        // The field, not the question — the question is the body. Naming the
        // field is what tells a technician which of four boxes this is about,
        // which the agent's sentence often does not.
        request.field.label,
        style: theme.textTheme.titleMedium,
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            request.question,
            key: ClarificationKeys.question,
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          // One button per option, in the order the model sent them. Full-width
          // and stacked rather than laid out in a row: the options are phrases
          // ("12-inch mesh"), not words, and a row of them wraps into something
          // whose tap targets a technician in gloves has to aim at.
          for (var i = 0; i < request.options.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: OutlinedButton(
                key: ClarificationKeys.option(i),
                onPressed: () => onChosen(request.options[i]),
                child: Text(request.options[i]),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          key: ClarificationKeys.dismiss,
          onPressed: onDismissed,
          // Not "Cancel": nothing is being cancelled, and the agent's other
          // fields have already been recorded. This says what the outcome is.
          child: const Text('Not sure yet'),
        ),
      ],
    );
  }
}

/// Puts the technician a question and returns their answer, or `null`.
///
/// **The content follows a listenable rather than a fixed request**, and that is
/// the fix for a real gap rather than a generalisation: the agent can ask again on
/// a later turn of the same run, and a route built around one request would then
/// show the *first* question while the state held the second — so a tap would
/// write the option the technician read into the field they were not asked about.
/// One route whose content follows the pending question has no such window.
///
/// It also keeps the outgoing question painted while the route animates away.
/// A route that emptied itself the moment the state cleared would blink to nothing
/// and then fade, which reads as a glitch on the recording this app exists to make.
///
/// `barrierDismissible` is left at its default of `true` and the barrier tap is
/// the same outcome as the button: this is a question, and a technician who has
/// not decided yet must be able to get back to the answer they were reading.
Future<String?> showClarificationDialog(
  BuildContext context,
  ValueListenable<ClarificationRequest> request,
) => showDialog<String>(
  context: context,
  builder: (context) => ValueListenableBuilder<ClarificationRequest>(
    valueListenable: request,
    builder: (context, value, _) => ClarificationDialog(
      request: value,
      onChosen: (choice) => Navigator.of(context).pop(choice),
      onDismissed: () => Navigator.of(context).pop(),
    ),
  ),
);

/// Shows the pending clarification over [child], and reports the answer.
///
/// **Presentation is a widget rather than a `ref.listen` in the screen's
/// `initState`**, because the four states this has to keep straight — no question,
/// a question with no dialog, a dialog with no question, and a dialog with a
/// *different* question — are exactly what a `State` object is for, and scattering
/// them across the screen's lifecycle callbacks is how a modal ends up shown twice
/// or left open over a form that no longer has anything to ask.
///
/// The last two are the ones worth naming, because neither is hypothetical:
///
/// * **A dialog with no question.** [WorkOrderFormViewModel.reset] and
///   [WorkOrderFormViewModel.answerClarification] can both clear the request while
///   the dialog is up, so a cleared request pops the route rather than leaving a
///   question about a form that has moved on.
/// * **A dialog with a different question.** `AgentLoop` runs up to four turns and
///   each may call the tool, so a second clarification can arrive while the first
///   is still on screen. The route follows [_showing] rather than the request it
///   was pushed with, so the buttons are always the ones belonging to the question
///   the state holds.
class ClarificationHost extends ConsumerStatefulWidget {
  const ClarificationHost({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<ClarificationHost> createState() => _ClarificationHostState();
}

class _ClarificationHostState extends ConsumerState<ClarificationHost> {
  /// The question the open route is rendering, or `null` when none is open.
  ///
  /// Non-nullable *inside* the notifier and nullable outside it: a route only
  /// exists for a question that exists, so the dialog never has to draw an absent
  /// one — and there is therefore no empty branch in the builder to go stale.
  ValueNotifier<ClarificationRequest>? _showing;

  /// Whether the route on screen is being popped *by this host* because its
  /// question went away.
  ///
  /// **This is the fix for a defect mutation M19 exposed, and the mutation was not
  /// even the thing that failed** — the row was written expecting the state check
  /// in [_present] to be load-bearing, it survived, and working out why found a
  /// three-step sequence in which the host loses a question outright:
  ///
  /// 1. Something other than the dialog answers the pending question — the agent's
  ///    own `answerClarification`, or `reset` behind the barrier — so the listener
  ///    pops the route.
  /// 2. The agent's next turn asks a *new* question while that pop is still
  ///    animating. Without this flag the listener retargeted the dying route, so
  ///    the new question was rendered into something already on its way out.
  /// 3. The pop then resolved with `null`, and [_present]'s tail read the state,
  ///    found a pending question and **dismissed it** — the very question that had
  ///    just arrived, thrown away by the close of the dialog before it.
  ///
  /// So a closing route is left alone (step 2), the tail dismisses only the
  /// question that was actually on screen (step 3), and a question that arrived
  /// with no listener edge left to fire is presented by the tail itself. The window
  /// is one frame wide and reachable: `AgentLoop` runs up to four turns, each may
  /// call the tool, and a modal takes ~150ms to animate out.
  bool _closing = false;

  @override
  void dispose() {
    _showing?.dispose();
    _showing = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // `select` so this fires on the clarification changing and not on every
    // keystroke into the form.
    ref.listen<
      ClarificationRequest?
    >(workOrderFormProvider.select((state) => state.clarification), (
      previous,
      next,
    ) {
      final showing = _showing;
      if (next == null) {
        // The question went away under an open dialog — answered, or the form
        // was reset behind the barrier. `_showing` is deliberately left holding
        // the outgoing question so the route paints it while it animates out;
        // `_present` clears it when the route is actually gone.
        if (showing != null && !_closing) {
          _closing = true;
          Navigator.of(context, rootNavigator: true).pop();
        }
        return;
      }
      if (showing != null) {
        // A second question while the first is up: retarget the open route —
        // unless that route is already closing, in which case it is about to
        // stop existing and `_present`'s tail will put the new one up instead.
        if (!_closing) showing.value = next;
        return;
      }
      _showing = ValueNotifier<ClarificationRequest>(next);
      // After the frame, because this fires during a notification and
      // `showDialog` mutates the navigator.
      WidgetsBinding.instance.addPostFrameCallback((_) => _present());
    });

    return widget.child;
  }

  Future<void> _present() async {
    final showing = _showing;
    if (showing == null) return;
    if (!mounted) {
      _showing = null;
      _closing = false;
      showing.dispose();
      return;
    }

    final choice = await showClarificationDialog(context, showing);
    // The question the route was actually rendering when it closed. Read before
    // the notifier is disposed, and it is what makes a dismissal specific.
    final shown = showing.value;
    _showing = null;
    _closing = false;
    showing.dispose();
    if (!mounted) return;

    final form = ref.read(workOrderFormProvider.notifier);
    if (choice != null) {
      // See `WorkOrderFormState.answerClarification` for what this deliberately
      // does *not* do, which is resume the agent's run.
      form.answerClarification(choice);
    } else if (ref.read(workOrderFormProvider).clarification == shown) {
      // `null` covers three closings and only one of them is a dismissal: the
      // button, the barrier, and the pop this host itself performs when the
      // question is already gone. **Comparing the request rather than checking for
      // one** is what tells them apart — an earlier version asked only whether
      // *some* question was pending, which dismissed a question that had arrived
      // while this route was closing. `ClarificationRequest` has value equality.
      form.dismissClarification();
    }

    // A question that arrived while the route was closing produced no listener
    // edge this host could act on — the listener saw a non-null `next` while a
    // route still existed and deliberately left it alone. So it is presented from
    // here, which is the only point at which the route is known to be gone.
    final pending = ref.read(workOrderFormProvider).clarification;
    if (pending != null && _showing == null) {
      _showing = ValueNotifier<ClarificationRequest>(pending);
      WidgetsBinding.instance.addPostFrameCallback((_) => _present());
    }
  }
}
