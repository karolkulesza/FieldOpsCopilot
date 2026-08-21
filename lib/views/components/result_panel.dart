/// The result panel: what grounded the answer, what the agent did, and the answer.
///
/// One library for the panel and the five widgets it composes, because every one
/// of them reads `FieldJobState` and none is reusable anywhere else. Only
/// [ResultPanel] is public; the rest are its parts.
library;

import 'package:flutter/material.dart';

import '../../services/ai/agent_loop.dart';
import '../../services/ai/base_tool.dart';
import '../../services/ai/tools/get_parts_inventory_tool.dart';
import '../../services/database/tables.dart' show normalizeSku;
import '../../viewmodels/field_job_viewmodel.dart';
import '../diagnose_keys.dart';
import 'answer_markdown.dart';

/// Everything about the current diagnosis: what grounded it, what the agent did,
/// and the answer.
///
/// **Stateful only to follow the stream.** Without following, the panel is a bare
/// `SingleChildScrollView` pinned at offset 0 while the content extent
/// grows, so a long answer streams *below the fold*: the measured device answer is
/// 1401 characters in a panel that also carries the grounding line, a divider and a
/// completed-lookup line. That breaks the claim this whole screen rests on — "the
/// live token stream is the progress indicator" — precisely when the answer gets
/// long enough to be worth reading, and TC-UI-DEMO-01 could not see it either,
/// because `find.text` matches a scrolled-out `Text` (clipped, not offstage).
class ResultPanel extends StatefulWidget {
  const ResultPanel({required this.job, super.key});

  final FieldJobState job;

  @override
  State<ResultPanel> createState() => _ResultPanelState();
}

class _ResultPanelState extends State<ResultPanel> {
  final ScrollController _scroll = ScrollController();

  /// Whether a finger is on the panel right now.
  ///
  /// **The offset check below is necessary and was not sufficient** — found on
  /// device by a tester who reported "I could not scroll anything" while the
  /// answer streamed, which reads as the app being busy rather than as a defect.
  ///
  /// The mechanism: `jumpTo` begins
  /// with `goIdle()` (`scroll_position_with_single_context.dart`), and `goIdle`
  /// **disposes the active drag**. So every token cancelled the reader's in-flight
  /// gesture before it could accumulate the [_followSlack] pixels that would have
  /// released the follow — self-reinforcing, because escaping required movement the
  /// follow kept destroying. Measured with a matched control: an identical 288px
  /// drag moved the offset 1692 → 1404 with no tokens arriving, and 1692 → 1980
  /// (pinned to the extent) with tokens arriving.
  ///
  /// The first regression test could not see it, and that is the lesson worth
  /// keeping: it scrolls with `_scroll.jumpTo(0)`, a *programmatic* move with no
  /// drag to dispose, so it exercises the offset guard and never the mechanism
  /// that failed. The test now beside it drives a real [TestGesture] instead.
  bool _readerIsDragging = false;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// A reader within this many pixels of the bottom still counts as following the
  /// stream, so the panel keeps scrolling for them.
  ///
  /// **A deliberate comfort band, not a correction for measurement error.** There
  /// is no rounding artefact of the previous jump to defend against: the jump
  /// lands *exactly* on the extent, asserted one screen away in the same test
  /// file. Defending an imaginary hazard is how a magic number
  /// acquires a respectable-looking justification.
  ///
  /// What it is actually for: a reader who nudges the panel up by a line — a
  /// scroll-wheel click, a thumb drag that overshoots — has not asked to stop
  /// following, and yanking them out of the stream for 20px of movement would be
  /// worse than the alternative. Roughly two lines of `bodyLarge`. Bound in both
  /// directions by `diagnose_screen_test.dart`: a scroll of less than the slack keeps
  /// following, a scroll far beyond it does not.
  static const double _followSlack = 48;

  @override
  void didUpdateWidget(ResultPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Three conditions. The first two — the run is in flight, and the text
    // actually *grew* — are the obvious ones. The third exists because without
    // it a technician who scrolls up mid-generation is yanked straight back —
    // measured, not argued: with
    // the panel scrolled to offset 0 mid-generation, one more token returned it to
    // 1716.0, exactly `maxScrollExtent`. During generation the text grows on every
    // token, so "grew" is satisfied constantly and the reader loses the scroll
    // immediately.
    //
    // **At-bottom-ness has to be sampled here, before layout, and that is the whole
    // subtlety.** The obvious guard — checking `offset` against `maxScrollExtent`
    // inside the post-frame callback — is wrong and is caught by this file's own
    // scroll test: by then the extent has already grown by the new text, so a reader
    // sitting legitimately at the bottom *before* the update measures as one who has
    // scrolled away, and the panel stops following at all. Sampled at this point the
    // extent is still the pre-growth one, so the question asked is the right one:
    // "was the reader at the bottom of what they could see?"
    if (!widget.job.isBusy) return;
    if (widget.job.displayText.length <= oldWidget.job.displayText.length) {
      return;
    }
    // A finger is down: never jump. See [_readerIsDragging] — jumping here does not
    // merely overrule the reader, it destroys the gesture they are in the middle of,
    // so the offset guard below can never be reached.
    if (_readerIsDragging) return;

    // Nothing scrollable yet (the first tokens of a short answer) counts as at the
    // bottom, which is what makes the panel follow from the start.
    final wasAtBottom =
        !_scroll.hasClients ||
        _scroll.offset >= _scroll.position.maxScrollExtent - _followSlack;
    if (!wasAtBottom) return;

    // After the frame, because the extent this jumps to does not exist until the
    // new text has been laid out. `jumpTo` rather than `animateTo`: an animation
    // during generation is the thing this screen refuses to do — frames are
    // measurably dropped while tokens stream (see the library doc), and a
    // smooth-scroll through that stutters visibly in a recording.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final job = widget.job;

    return Container(
      key: DiagnoseKeys.resultPanel,
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      // `dragDetails != null` names the concept precisely — *a reader's* scroll, as
      // opposed to one this panel caused — and that is the whole of its
      // justification. **It is not load-bearing today and no test distinguishes it,
      // which I checked by deleting it rather than by reasoning:** the suite stays
      // green. The latch it looks like it prevents does not exist, because `jumpTo`
      // fires `didStartScroll()` and `didEndScroll()` within one synchronous call,
      // so the flag would be set and cleared before any token could observe it.
      // Kept because the narrower predicate is the one that stays correct if a
      // future scroll source starts emitting these, and recorded as unbound rather
      // than dressed up as a guard.
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification is ScrollStartNotification &&
              notification.dragDetails != null) {
            _readerIsDragging = true;
          } else if (notification is ScrollEndNotification) {
            // Cleared on *any* end, including the one that follows the momentum
            // fling after the finger lifts, so a reader who flings back to the
            // bottom resumes following rather than being stranded.
            _readerIsDragging = false;
          }
          // Not consumed: this observes, and something above may also want these.
          return false;
        },
        child: SingleChildScrollView(
          controller: _scroll,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (job.retrieval != null) ...[
                _GroundingLine(job: job),
                const Divider(height: 20),
              ],
              for (final invocation in job.invocations)
                _CompletedTool(invocation: invocation),
              // One line per refusal, counted rather than iterated, because nothing
              // about the individual failure is rendered. `GuardFailure.message` is
              // written *for the model* ("call the tool again with a tool name and
              // JSON arguments"), so it is not a sentence to show a technician — and
              // it deliberately does not reach the screen even as a `semanticsLabel`,
              // which would replace the readable line above with it for anyone using
              // assistive technology.
              for (var i = 0; i < job.rejectedCalls.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    'The assistant sent a malformed lookup and was asked to retry.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ),
              if (job.activeTool != null)
                _ToolActivity(started: job.activeTool!),
              if (job.invocations.isNotEmpty ||
                  job.rejectedCalls.isNotEmpty ||
                  job.activeTool != null)
                const SizedBox(height: 12),
              _Body(job: job),
            ],
          ),
        ),
      ),
    );
  }
}

/// What the answer is grounded in — the manual entries retrieval found.
///
/// On screen because it is the whole architectural claim made visible: the model
/// is answering from these documents, and a viewer can see which. It appears
/// *before* the first token, so it frames the answer rather than annotating it.
class _GroundingLine extends StatelessWidget {
  const _GroundingLine({required this.job});

  final FieldJobState job;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = job.retrieval!.entries;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          entries.isEmpty ? Icons.menu_book_outlined : Icons.menu_book,
          size: 18,
          color: theme.colorScheme.outline,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            entries.isEmpty
                // The honest wording for the no-match case. A device run
                // found this path is far less reachable than the design assumes —
                // stop words match, so almost any English sentence retrieves
                // something — which is recorded in the README rather than papered
                // over here.
                ? 'No manual entry matched. The assistant has been told not to '
                      'invent a procedure.'
                : 'Grounded in: '
                      '${entries.map((e) => '${e.title} (${e.code})').join('; ')}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ),
      ],
    );
  }
}

/// "Checking inventory…" — a tool the agent is running right now.
///
/// Static, like everything else here. The agent loop emits `AgentToolCallStarted`
/// *before* the query is in flight precisely so this can be on screen while it
/// runs.
class _ToolActivity extends StatelessWidget {
  const _ToolActivity({required this.started});

  final AgentToolCallStarted started;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      key: DiagnoseKeys.toolActivity,
      children: [
        Icon(
          Icons.inventory_2_outlined,
          size: 18,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            _labelFor(started),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
        ),
      ],
    );
  }

  /// A technician-facing sentence for a tool call.
  ///
  /// Falls back to the tool's own name for anything unmapped, rather than to a
  /// generic "working…": one tool exists today and more are planned,
  /// and a wrong-but-specific label is easier to notice than a vague one.
  static String _labelFor(AgentToolCallStarted started) {
    final sku = started.call.arguments[GetPartsInventoryTool.skuParameter];
    return switch (started.call.name) {
      GetPartsInventoryTool.toolName =>
        sku is String && sku.trim().isNotEmpty
            ? 'Checking local inventory for ${normalizeSku(sku)}…'
            : 'Checking local inventory…',
      final other => 'Running $other…',
    };
  }
}

/// A finished tool call, rendered from its payload.
class _CompletedTool extends StatelessWidget {
  const _CompletedTool({required this.invocation});

  final AgentToolInvocation invocation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final outcome = invocation.outcome;
    final failed = outcome is ToolFailure;

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            failed ? Icons.help_outline : Icons.check_circle_outline,
            size: 18,
            color: failed
                ? theme.colorScheme.error
                : theme.colorScheme.secondary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _summarise(invocation),
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  /// A one-line report of what the lookup found.
  ///
  /// Reads the payload rather than restating the arguments, because the payload is
  /// what the model was told and therefore what the answer should agree with — a
  /// viewer comparing this line to the answer is checking the grounding by eye.
  /// The tool's two success shapes are kept apart here for the reason the tool
  /// keeps them apart: "we do not carry this part" and "we carry it and have none"
  /// are different sentences to a technician.
  ///
  /// **Every branch below reads the inventory tool's payload shape, so the tool is
  /// checked first.** One tool is registered today and more are
  /// planned; without this gate the first of them renders as "null: null in stock",
  /// which is worse than useless because it looks like data. [_ToolActivity] already
  /// had a generic fallback for an unrecognised tool and this did not — an asymmetry
  /// between two functions doing the same job one line apart.
  static String _summarise(AgentToolInvocation invocation) {
    final payload = invocation.outcome.payload;
    final replayed = invocation.repeated ? ' (already answered)' : '';
    if (invocation.call.name != GetPartsInventoryTool.toolName) {
      return invocation.outcome is ToolFailure
          ? '${invocation.call.name} could not be completed$replayed.'
          : '${invocation.call.name} completed$replayed.';
    }
    if (invocation.outcome is ToolFailure) {
      return 'Inventory lookup could not be completed$replayed.';
    }
    final sku = payload['sku'];
    if (payload['found'] == false) {
      return 'The warehouse does not carry $sku$replayed.';
    }
    final stock = payload['in_stock'];
    final aisle = payload['aisle'];
    final where = aisle == null ? '' : ' at $aisle';
    return stock == 0
        ? '$sku is carried but out of stock$where$replayed.'
        : '$sku: $stock in stock$where$replayed.';
  }
}

/// The answer, the live stream, or the reason there is neither.
class _Body extends StatelessWidget {
  const _Body({required this.job});

  final FieldJobState job;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (job.phase == FieldJobPhase.failed) {
      return Text(
        job.failure ?? 'This diagnosis could not be completed.',
        key: DiagnoseKeys.runFailure,
        style: theme.textTheme.bodyLarge?.copyWith(
          color: theme.colorScheme.error,
        ),
      );
    }

    if (job.phase == FieldJobPhase.idle) {
      return Text(
        'Describe a fault and tap Diagnose. Everything runs on this device: '
        'the manual, the warehouse inventory and the model.',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.outline,
        ),
      );
    }

    final reason = job.stopReason;
    if (reason == null) {
      // Still generating. The text itself is the progress indicator.
      // Formatted while streaming too, not only once finished: a half-arrived
      // `**Isolate` would otherwise show its asterisks and then lose them when the
      // run ended, which is a visible flicker in the recording. `answerSpans`
      // leaves an unpaired `**` literal, so the partial state is stable.
      return _AnswerText(job.displayText);
    }

    // Finished. **The advice-vs-failure decision is [FieldJobState.isDiagnosis]
    // and nothing else.** An earlier version of `_Body` re-derived the
    // decision from `stopReason` on its own. Two representations of one fact is
    // exactly what `FieldJobState.activeTool` refuses to allow one layer down, so
    // the duplication is removed rather than the claim softened — the colour and
    // the icon, which are what actually stop a report of failure reading as
    // advice, come from the one question.
    final color = job.isDiagnosis
        ? theme.colorScheme.primary
        : theme.colorScheme.error;
    final icon = job.isDiagnosis
        ? Icons.check_circle
        : Icons.report_problem_outlined;

    // The *wording* still needs all three, because "no answer produced" and
    // "diagnosis stopped" are different sentences. Kept exhaustive and unmapped by
    // `isDiagnosis`, so a fourth `AgentStopReason` fails to compile here.
    final header = switch (reason) {
      AgentStopReason.answered => 'Repair plan',
      AgentStopReason.emptyResponse => 'No answer produced',
      AgentStopReason.iterationCapReached => 'Diagnosis stopped',
    };

    return Column(
      key: DiagnoseKeys.outcome(reason),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 6),
            Text(
              header,
              style: theme.textTheme.labelLarge?.copyWith(color: color),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _AnswerText(job.displayText),
      ],
    );
  }
}

/// The model's answer, with the little Markdown it emits rendered rather than
/// shown.
///
/// See `components/answer_markdown.dart` for what "the little Markdown it emits"
/// means and why the scope is exactly that. This widget is the only consumer, and
/// exists so the two call sites — streaming and finished — cannot drift apart in how
/// they render the same string.
class _AnswerText extends StatelessWidget {
  const _AnswerText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text.rich(
    TextSpan(children: answerSpans(text)),
    style: Theme.of(context).textTheme.bodyLarge,
  );
}
