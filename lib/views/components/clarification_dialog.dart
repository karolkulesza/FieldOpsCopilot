/// The agent's question to the technician, and the overlay that puts it.
///
/// The design intent this implements: if mandatory fields are missing or
/// ambiguous, the agent dynamically prompts the user — *"Which filter did you
/// use: the 12-inch mesh or the 14-inch carbon?"* — through a text-to-speech
/// speaker or an inline UI selector. Spoken output is future work; this is the
/// selector.
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
///   question about a form that has moved on. **The same clearing one frame
///   *earlier* is a different state and must not be handled as if it were this
///   one** — see [_ClarificationHostState._routeUp]. Note that
///   `reset()` has no caller in `lib/` today, so the citation above is a capability
///   rather than a live path; it is named because it is what the next "new job"
///   button will use.
/// * **A dialog with a different question.** `AgentLoop` runs up to four turns and
///   each may call the tool, so a second clarification can arrive while the first
///   is still on screen. The route follows [_showing] rather than the request it
///   was pushed with, so the buttons are always the ones belonging to the question
///   the state holds.
///
/// **A fifth state was implemented here and then removed, and it is recorded
/// because the removal is the lesson.** A surviving mutation prompted reasoning
/// that produced a plausible three-step sequence — a question answered from outside
/// the dialog pops the route; the agent's next turn asks something else while that
/// pop animates; the tail then dismisses the new question. A `_closing` flag and a
/// request-specific dismissal were written for it. **The sequence cannot happen**,
/// and an instrumented trace is what said so rather than a second reading:
/// `showDialog`'s future resolves in the *same frame* as the pop — the route is
/// still painting its exit transition, but [_present] has already resumed with
/// `choice: null` and `pending: null`. There is no window for a later state change
/// to land in. The flag was reverted rather than kept as an unreachable guard with
/// a story attached.
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

  /// Whether a dialog route is actually on the navigator right now.
  ///
  /// **Distinct from `_showing != null`, and the gap between the two was a real
  /// defect.**
  /// [_showing] is assigned in the listener; the route is pushed one post-frame
  /// callback later. A clarification cleared inside that window took the
  /// `next == null` branch, found `_showing` non-null and popped the **root
  /// navigator** — with no dialog on the stack, so it popped the app's home route
  /// and left a blank screen. Measured against `reset()`; latent
  /// only because `reset()` has no caller in `lib/` yet, which is the sort of thing
  /// that stops being true the moment someone adds a "new job" button.
  ///
  /// So the two states are now separate questions: whether a presentation is
  /// *pending* ([_showing]) and whether a route is *up* (this). Clearing the
  /// request before the push cancels the presentation instead of popping something
  /// else.
  bool _routeUp = false;

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
        if (showing == null) return;
        if (_routeUp) {
          // The question went away under an open dialog — answered, or the form
          // was reset behind the barrier. `_showing` is deliberately left holding
          // the outgoing question so the route paints it while it animates out;
          // `_present` clears it when the route is actually gone.
          Navigator.of(context, rootNavigator: true).pop();
        } else {
          // Cleared in the window between the assignment above and the push one
          // frame later. There is nothing to pop, and
          // popping anyway takes the app's home route with it. Cancel the pending
          // presentation instead: the callback queued for it is still on the
          // frame, and it identifies itself by the notifier it was scheduled
          // with, so clearing `_showing` here is what makes it a no-op.
          _showing = null;
          showing.dispose();
        }
        return;
      }
      if (showing != null) {
        // A second question while the first is up: retarget the open route.
        showing.value = next;
        return;
      }
      // **The notifier is captured and handed to the callback, and the identity
      // matters.** The cancel branch above clears `_showing` without unscheduling
      // the callback queued for it, so a question arriving in the same frame took the
      // "nothing open" path and scheduled a *second* presentation. Both then ran,
      // both found a non-null `_showing`, and both pushed a route: two stacked
      // dialogs, and answering the top one stranded the other over a state with no
      // question, rendering a disposed notifier that no listener edge could close.
      // Identity is what tells a live schedule from a cancelled one.
      final scheduled = ValueNotifier<ClarificationRequest>(next);
      _showing = scheduled;
      // After the frame, because this fires during a notification and
      // `showDialog` mutates the navigator.
      WidgetsBinding.instance.addPostFrameCallback((_) => _present(scheduled));
    });

    return widget.child;
  }

  Future<void> _present(ValueNotifier<ClarificationRequest> scheduled) async {
    // Not the current presentation: this callback was queued for a question that
    // has since been cancelled (the branch that disposed [scheduled]) or
    // replaced. Returning is the whole of the fix — whoever replaced it
    // owns the disposal, so there is nothing to clean up here.
    if (!identical(_showing, scheduled)) return;
    final showing = scheduled;
    if (!mounted) {
      _showing = null;
      showing.dispose();
      return;
    }

    // Set *before* the await and cleared after it, so the listener can tell a
    // pending presentation from a route that is actually up.
    _routeUp = true;
    final choice = await showClarificationDialog(context, showing);
    _routeUp = false;
    _showing = null;
    showing.dispose();
    if (!mounted) return;

    final form = ref.read(workOrderFormProvider.notifier);
    if (choice != null) {
      // See `WorkOrderFormState.answerClarification` for what this deliberately
      // does *not* do, which is resume the agent's run.
      form.answerClarification(choice);
      return;
    }
    // `null` covers three closings and only one of them is a dismissal: the
    // button, the barrier, and the pop this host itself performs when the question
    // is already gone. Checking the state is what tells them apart.
    //
    // **It is belt-and-braces, not a guard, and that is measured rather than
    // assumed** — replacing this condition with `true` leaves the suite
    // green. It is unreachable in the third case because the state is
    // already `null` there, and in the first two the condition is always true. What
    // it costs is one comparison; what it buys is that a future closing path which
    // *does* leave a question pending cannot silently clear it. Recorded as unbound
    // rather than described as protection.
    if (ref.read(workOrderFormProvider).clarification != null) {
      form.dismissClarification();
    }
  }
}
