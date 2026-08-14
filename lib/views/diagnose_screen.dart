/// The demo screen: typed inquiry → Diagnose → live tokens → grounded answer.
///
/// This is the artefact Task 1.11 exists to produce — the thing that gets
/// screen-recorded — so a handful of decisions here are about the recording as
/// much as about the UI.
///
/// **Nothing on this screen animates while the model works, and that is
/// deliberate.** Task 1.8 measured two things on the demo device (iPad Air M4,
/// iOS 26.5, Metal): the UI isolate stalls **1445–1728ms** while the weights load,
/// and it drops **5–8 frames** (77–135ms worst gap) while tokens stream. A
/// progress indicator during either one freezes or stutters — and a frozen
/// indicator reads as a crash, which is strictly worse than a static label saying
/// what is happening. So there is no `CircularProgressIndicator` and no
/// `LinearProgressIndicator` anywhere in this file, and
/// `diagnose_screen_test.dart` asserts that structurally rather than trusting this
/// paragraph.
///
/// The live token stream is the honest progress indicator: text appearing is
/// unambiguous evidence of work, it cannot stutter in a way that reads as a hang,
/// and it is the single most convincing thing in the recording. (One exception is
/// out of scope and stays: `ModelReadinessBanner` shows a determinate bar while
/// *downloading* weights. A download is network I/O with no UI-isolate stall, and
/// that widget is Task 1.7's.)
///
/// **All three [AgentStopReason]s render differently.** The loop authors truthful
/// non-empty text for each, so a screen could render all three identically and
/// look correct — while handing a technician "the assistant kept requesting
/// lookups without producing an answer" in the same panel as a repair plan. The
/// branch is [FieldJobState.isDiagnosis] and the outcome panel carries a key naming
/// which of the three it is.
library;

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/ai/agent_loop.dart';
import '../services/ai/base_tool.dart';
import '../services/ai/tools/get_parts_inventory_tool.dart';
import '../services/database/providers.dart';
import '../services/database/tables.dart' show normalizeSku;
import '../services/inference/engine_warmup_controller.dart';
import '../services/models/model_storage.dart';
import '../services/models/providers.dart';
import '../viewmodels/dictation_viewmodel.dart';
import '../viewmodels/field_job_viewmodel.dart';
import 'components/answer_markdown.dart';
import 'components/clarification_dialog.dart';
import 'components/model_readiness_banner.dart';
import 'components/work_order_form_panel.dart';

/// Keys the widget tests find things by, so an assertion names a role rather than
/// a colour or a string of copy.
abstract final class DiagnoseKeys {
  static const Key inquiryField = Key('diagnose-inquiry-field');
  static const Key diagnoseButton = Key('diagnose-button');
  static const Key resultPanel = Key('diagnose-result-panel');
  static const Key engineStatus = Key('diagnose-engine-status');
  static const Key toolActivity = Key('diagnose-tool-activity');

  /// The database or the seed could not be prepared — the app cannot retrieve.
  static const Key startupFailure = Key('diagnose-startup-failure');

  /// The microphone toggle. Task 2.3.
  static const Key dictateButton = Key('diagnose-dictate-button');

  /// The line saying what dictation is doing, or why it cannot.
  static const Key dictationStatus = Key('diagnose-dictation-status');

  /// This particular diagnosis threw. Distinct from [startupFailure] because one
  /// is "this app is misconfigured" and the other is "that attempt did not work",
  /// and only the second leaves the button worth pressing again.
  static const Key runFailure = Key('diagnose-run-failure');

  /// The outcome panel, named by which of the three endings produced it.
  ///
  /// Derived from the enum rather than three literals, so a fourth stop reason
  /// cannot be added without this key changing with it.
  static Key outcome(AgentStopReason reason) =>
      Key('diagnose-outcome-${reason.name}');
}

/// One screen: the whole Tier 1 slice.
class DiagnoseScreen extends ConsumerStatefulWidget {
  const DiagnoseScreen({super.key});

  @override
  ConsumerState<DiagnoseScreen> createState() => _DiagnoseScreenState();
}

class _DiagnoseScreenState extends ConsumerState<DiagnoseScreen> {
  final TextEditingController _inquiry = TextEditingController();

  /// What was in the inquiry field when the current dictation started, or `null`
  /// when nothing is being mirrored.
  ///
  /// **Dictation appends to what is there rather than replacing it**, which is
  /// the difference between a microphone that helps and one that costs you a
  /// sentence: a technician who typed "cabin vibrating" and then tapped the mic to
  /// add the fault code must not lose the half they typed. Holding the base here
  /// rather than in `DictationState` is what keeps the controller's line a *pure*
  /// transcript — the state carries what was heard, this carries what it is being
  /// added to, and neither has to know about the other.
  ///
  /// **`null` also means "released", and that is review finding R0-F1.** The field
  /// is not read-only while the microphone is open, because a technician watching
  /// `FALK CODE` land has to be able to fix it — and until R0-F1 that was a claim
  /// the code refuted: [_onDictation] rebuilds the whole line from `base +
  /// transcript` on **every** state change, so a correction was overwritten by the
  /// next partial, and by the capture merely ending. Measured by the reviewer, not
  /// argued.
  ///
  /// The rule now is the one the comment always claimed: **typing takes the
  /// field.** An edit made while a capture is running releases the mirror (this
  /// goes `null`, so [_onDictation] returns) and stops the capture, in that order —
  /// stopping first would flush a final transcript through the mirror and clobber
  /// the very edit being protected. Stopping rather than merely releasing is what
  /// keeps the status line honest: a microphone that stays open while its words
  /// stop arriving reads as broken.
  String? _dictationBase;

  @override
  void initState() {
    super.initState();
    // The weights start loading as this screen mounts, which — since this screen
    // is the app's home — is app start. Not on the Diagnose tap: that is the
    // moment being recorded, and a 1.5-second stall between the tap and the first
    // token is the one place the stall must not land. `warmUp` is idempotent, so a
    // rebuild costs nothing.
    //
    // Deferred by one frame so the first frame paints before the load begins.
    // Calling it synchronously here would stall the UI isolate *before* anything
    // was on screen, which is a launch that looks like a hang.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(engineWarmupControllerProvider.notifier).warmUp();
      }
    });

    // **And again whenever weights become ready, which is the fix for review
    // finding R0-F1.** The callback above is one-shot, and this screen is
    // `MaterialApp.home` under a `StatelessWidget`, so `initState` never runs
    // twice. Without this listener an operator who used the download button
    // `ModelReadinessBanner` offers got a screen showing "Model ready" from the
    // banner directly above "No verified weights on this device — the agent cannot
    // run" from the status row, with Diagnose dead until the app was restarted:
    // `provision()` invalidates `modelInstallStatusProvider` on success, but
    // nothing re-ran `warmUp`, and neither this widget nor the controller had any
    // edge to that provider.
    //
    // `EngineWarmupController` already documented this recovery and a unit test
    // already bound it by calling `warmUp()` twice by hand. The capability, the
    // doc and the test existed; the caller did not.
    //
    // `listenManual` rather than a `ref.watch` in `build`, because this is an
    // *effect* and not something the render depends on. It is safe to fire on
    // every transition into `ready`: `warmUp` returns immediately when the state is
    // already `EngineLoading` or `EngineReady`, so the common path — weights
    // already present at launch — costs one early return.
    // The LLM's family instance specifically (Task 2.0 made the status provider
    // per-model): the STT set becoming ready changes nothing about the engine,
    // and warming up on its edge would be a no-op fired for the wrong reason.
    ref.listenManual(
      modelInstallStatusProvider(ref.read(activeLlmDescriptorProvider).id),
      (previous, next) {
        // `next.value`, not the `valueOrNull` the review's suggested fix used —
        // Riverpod 3's `AsyncValue` exposes a nullable `value` and no `valueOrNull`,
        // so the suggestion as written does not compile. `ModelReadinessBanner`
        // already reads `status.value`, which is how the shape was confirmed rather
        // than guessed.
        if (next.value != ModelInstallStatus.ready) return;
        ref.read(engineWarmupControllerProvider.notifier).warmUp();
      },
    );
  }

  @override
  void dispose() {
    _inquiry.dispose();
    super.dispose();
  }

  /// Handles a keystroke in the inquiry field.
  ///
  /// See [_dictationBase]: an edit during a capture releases the mirror and then
  /// stops the capture. The order is load-bearing — `stop()` flushes the
  /// recogniser's last utterance, and a mirror still attached would write
  /// `base + that` over the words just typed, which is R0-F1 arriving through the
  /// other door.
  void _onInquiryEdited() {
    if (_dictationBase != null &&
        ref.read(dictationControllerProvider).isActive) {
      _dictationBase = null;
      unawaited(ref.read(dictationControllerProvider.notifier).stop());
    }
    setState(() {});
  }

  /// Mirrors the live transcript into the inquiry field.
  ///
  /// Called from a `ref.listen` rather than from `build`, because writing a
  /// controller during a build is a change to a widget that is already being laid
  /// out. `setState` is still needed: a programmatic `controller.text =` does
  /// **not** fire `onChanged`, so nothing else would re-evaluate whether Diagnose
  /// should be enabled — which is the whole point of dictating.
  void _onDictation(DictationState? previous, DictationState next) {
    if (next.phase == DictationPhase.starting &&
        previous?.phase != DictationPhase.starting) {
      _dictationBase = _inquiry.text.trim();
    }
    final base = _dictationBase;
    if (base == null) return;

    final heard = next.text;
    final combined = [
      if (base.isNotEmpty) base,
      if (heard.isNotEmpty) heard,
    ].join(' ');
    if (_inquiry.text != combined) {
      _inquiry.value = TextEditingValue(
        text: combined,
        selection: TextSelection.collapsed(offset: combined.length),
      );
    }
    // The base is released once the capture is over, so the *next* one starts
    // from what is now in the field — including anything typed in between.
    if (!next.isActive) _dictationBase = null;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final job = ref.watch(fieldJobViewModelProvider);
    final warmup = ref.watch(engineWarmupControllerProvider);
    // Watched rather than read so a startup failure is rendered instead of
    // surfacing as an exception the first time the viewmodel touches it.
    final startup = ref.watch(seedOutcomeProvider);
    final dictation = ref.watch(dictationControllerProvider);
    ref.listen<DictationState>(dictationControllerProvider, _onDictation);

    // A run and a dictation are mutually exclusive: the microphone is writing the
    // inquiry the run would be reading, and letting both go at once means an
    // inquiry that changes under a prompt that has already been compiled.
    final canDiagnose =
        warmup is EngineReady &&
        !job.isBusy &&
        !dictation.isActive &&
        !startup.hasError;

    return Scaffold(
      appBar: AppBar(
        title: const Text('FieldOps Copilot'),
        backgroundColor: theme.colorScheme.inversePrimary,
      ),
      // The agent's questions arrive over everything else — see
      // `ClarificationHost`, which owns when a modal is up and which question it
      // is about. Wrapped at the body rather than inside the column so the barrier
      // covers the whole screen, including the readiness banner's download button.
      body: ClarificationHost(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // **The readiness chrome is `Flexible`, and that is a keyboard
                // fix rather than a style choice.** Reported from the demo iPad:
                // with the software keyboard up, `Scaffold` shrinks the body and
                // this column overflowed — 64 pixels there, reproduced at 12 in a
                // widget test at the same geometry. The two panels below are
                // `Expanded` and had already collapsed to zero, so what did not
                // fit was the *fixed* chrome itself.
                //
                // Loose flex makes this region take its natural height when there
                // is room — so the layout is unchanged with the keyboard down —
                // and scroll internally when there is not. The banner is the right
                // thing to give up first: it is startup information, and by the
                // time a technician is typing they have already read it.
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const ModelReadinessBanner(),
                        const SizedBox(height: 12),
                        _EngineStatusRow(warmup: warmup),
                        if (startup.hasError) ...[
                          const SizedBox(height: 12),
                          _StartupFailure(error: startup.error!),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextField(
                        key: DiagnoseKeys.inquiryField,
                        controller: _inquiry,
                        minLines: 2,
                        maxLines: 4,
                        textInputAction: TextInputAction.newline,
                        // Not read-only while dictating, deliberately: the words
                        // arriving are a transcript of a room, and a technician who
                        // sees `FALK CODE` land has to be able to fix it. What they
                        // type is preserved — `_onDictation` only ever rewrites the
                        // field when the combined line differs, and the base is
                        // re-read at the start of the *next* capture.
                        decoration: const InputDecoration(
                          labelText: 'Describe the fault',
                          hintText: 'e.g. cabin vibrating, E-102',
                          border: OutlineInputBorder(),
                        ),
                        // Rebuilds so the button's enabled state follows the text.
                        // The viewmodel refuses a blank inquiry too; this is the
                        // affordance, that is the guarantee.
                        //
                        // `onChanged` fires for a *user* edit only — never for the
                        // programmatic write in [_onDictation] — which is what
                        // makes it safe to treat it as "the technician took the
                        // field" (R0-F1).
                        onChanged: (_) => _onInquiryEdited(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _DictateButton(dictation: dictation, busy: job.isBusy),
                  ],
                ),
                if (dictation.phase != DictationPhase.idle) ...[
                  const SizedBox(height: 8),
                  _DictationStatus(dictation: dictation),
                ],
                const SizedBox(height: 12),
                FilledButton.icon(
                  key: DiagnoseKeys.diagnoseButton,
                  onPressed: canDiagnose && _inquiry.text.trim().isNotEmpty
                      ? () => ref
                            .read(fieldJobViewModelProvider.notifier)
                            .diagnose(_inquiry.text)
                      : null,
                  icon: const Icon(Icons.medical_services_outlined),
                  // No spinner in the busy label, for the reason in the library
                  // doc. "Diagnosing…" plus text arriving in the panel below is the
                  // progress report.
                  label: Text(job.isBusy ? 'Diagnosing…' : 'Diagnose'),
                ),
                const SizedBox(height: 16),
                // Three parts to two, and the split is what makes the form fill
                // *visible* — Task 2.3's whole demo is fields populating while the
                // answer streams, which a collapsed section would hide. The panel
                // is outside the answer's scroll view for the reason
                // `work_order_form_panel.dart` gives.
                Expanded(flex: 3, child: _ResultPanel(job: job)),
                const SizedBox(height: 12),
                const Expanded(flex: 2, child: WorkOrderFormPanel()),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The microphone toggle.
///
/// **A toggle rather than press-and-hold**, which is the one interaction decision
/// here and it is made for the technician rather than for the test: this app's
/// persona is someone in heavy gloves (§2.1), and holding a soft key steady for
/// fifteen seconds through a glove is exactly the thing gloves are bad at. A
/// toggle also makes the "stop" moment observable, which press-and-hold leaves to
/// a pointer-up nothing records.
///
/// **Static in every state, like everything else on this screen.** No pulsing
/// record dot: Task 1.8 measured the UI isolate dropping 5–8 frames while tokens
/// stream, and a recogniser decode step runs on its own isolate but the *state
/// updates* land here — an animation that stutters exactly when the microphone is
/// working reads as the microphone failing.
class _DictateButton extends ConsumerWidget {
  const _DictateButton({required this.dictation, required this.busy});

  final DictationState dictation;

  /// Whether a diagnosis is running. Dictating into an inquiry the agent has
  /// already compiled a prompt from would change the question after it was asked.
  final bool busy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final controller = ref.read(dictationControllerProvider.notifier);
    final listening = dictation.phase == DictationPhase.listening;
    final starting = dictation.phase == DictationPhase.starting;

    return IconButton.filledTonal(
      key: DiagnoseKeys.dictateButton,
      // Disabled while *starting* as well as while a run is in flight: the model
      // load is 359–530ms (Task 2.2) and a second tap in that window would reach
      // `start`'s own re-entry guard and do nothing, which reads as a dead button.
      onPressed: busy || starting
          ? null
          : () => listening ? controller.stop() : controller.start(),
      tooltip: listening ? 'Stop dictating' : 'Dictate the fault',
      icon: Icon(listening ? Icons.stop : Icons.mic_none),
      style: IconButton.styleFrom(
        foregroundColor: listening ? theme.colorScheme.error : null,
        // Square with the two-line text field beside it, so the row does not
        // change height when the icon does.
        minimumSize: const Size(56, 56),
      ),
    );
  }
}

/// What dictation is doing, or why it cannot.
///
/// Shown only outside [DictationPhase.idle] — an idle microphone has nothing to
/// say, and a permanent "not listening" line is a line a reader learns to skip.
class _DictationStatus extends StatelessWidget {
  const _DictationStatus({required this.dictation});

  final DictationState dictation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (
      IconData icon,
      String label,
      Color color,
    ) = switch (dictation.phase) {
      DictationPhase.starting => (
        Icons.hourglass_empty,
        'Preparing the recogniser…',
        theme.colorScheme.outline,
      ),
      DictationPhase.listening => (
        Icons.graphic_eq,
        // Nothing about *what* was heard: the words are in the field above, and
        // repeating them here would be the second representation this project
        // keeps deleting.
        'Listening — tap stop when you are done',
        theme.colorScheme.primary,
      ),
      DictationPhase.unavailable || DictationPhase.failed => (
        Icons.mic_off,
        dictation.message ?? 'Dictation is unavailable.',
        theme.colorScheme.error,
      ),
      // Not rendered; the caller gates on it. Answered rather than thrown for
      // `_notReadyMessage`'s reason — a wrong line beats a crash on the screen
      // being recorded, and nothing can render this without the gate failing.
      DictationPhase.idle => (
        Icons.mic_none,
        'Dictation is idle.',
        theme.colorScheme.outline,
      ),
    };

    return Row(
      key: DiagnoseKeys.dictationStatus,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}

/// Whether the on-device model is loaded — a **static** row in every state.
///
/// See the library doc: the UI isolate is stalled for 1445–1728ms inside
/// [EngineLoading], so anything animated here freezes exactly when it is being
/// looked at.
class _EngineStatusRow extends StatelessWidget {
  const _EngineStatusRow({required this.warmup});

  final EngineWarmupState warmup;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (IconData icon, String label, Color color) = switch (warmup) {
      EngineIdle() => (
        Icons.hourglass_empty,
        'Preparing the on-device model…',
        theme.disabledColor,
      ),
      EngineLoading() => (
        Icons.downloading_outlined,
        'Loading model weights — this takes a few seconds',
        theme.disabledColor,
      ),
      EngineReady() => (
        Icons.psychology_outlined,
        'On-device model ready',
        theme.colorScheme.primary,
      ),
      // The banner above already names which flavour of "no weights" this is and
      // offers the action, so this line says only that the agent cannot run.
      EngineUnavailable() => (
        Icons.cloud_off,
        'No verified weights on this device — the agent cannot run',
        theme.colorScheme.error,
      ),
      EngineFailed(:final message) => (
        Icons.error_outline,
        'Model unavailable: $message',
        theme.colorScheme.error,
      ),
    };

    return Row(
      key: DiagnoseKeys.engineStatus,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}

/// A startup failure — a malformed seed asset, or a key that does not open the
/// existing database.
///
/// Rendered rather than thrown, because Task 1.3 asked for a malformed asset to
/// fail *loudly*, and a grey screen with a stack trace in the console is quiet.
/// The message is included: both causes are build or configuration mistakes, and
/// the person who can fix them is the person looking at the screen.
class _StartupFailure extends StatelessWidget {
  const _StartupFailure({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: DiagnoseKeys.startupFailure,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.dangerous_outlined, color: theme.colorScheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'The local manual could not be prepared, so retrieval is '
              'unavailable: $error',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Everything about the current diagnosis: what grounded it, what the agent did,
/// and the answer.
///
/// **Stateful only to follow the stream, which is review finding R0-F6.** The panel
/// was a bare `SingleChildScrollView` pinned at offset 0 while the content extent
/// grew, so a long answer streamed *below the fold*: the measured device answer is
/// 1401 characters in a panel that also carries the grounding line, a divider and a
/// completed-lookup line. That breaks the claim this whole screen rests on — "the
/// live token stream is the progress indicator" — precisely when the answer gets
/// long enough to be worth reading, and TC-UI-DEMO-01 could not see it either,
/// because `find.text` matches a scrolled-out `Text` (clipped, not offstage).
class _ResultPanel extends StatefulWidget {
  const _ResultPanel({required this.job});

  final FieldJobState job;

  @override
  State<_ResultPanel> createState() => _ResultPanelState();
}

class _ResultPanelState extends State<_ResultPanel> {
  final ScrollController _scroll = ScrollController();

  /// Whether a finger is on the panel right now.
  ///
  /// **This exists because [R1-F1]'s fix closed the case its test simulates and not
  /// the case the finding described** — review finding **R12-F0**, found on device
  /// by a technician who reported "I could not scroll anything" while the answer
  /// streamed, which reads as the app being busy rather than as a defect.
  ///
  /// The offset check below is necessary and was not sufficient. `jumpTo` begins
  /// with `goIdle()` (`scroll_position_with_single_context.dart`), and `goIdle`
  /// **disposes the active drag**. So every token cancelled the reader's in-flight
  /// gesture before it could accumulate the [_followSlack] pixels that would have
  /// released the follow — self-reinforcing, because escaping required movement the
  /// follow kept destroying. Measured with a matched control: an identical 288px
  /// drag moved the offset 1692 → 1404 with no tokens arriving, and 1692 → 1980
  /// (pinned to the extent) with tokens arriving.
  ///
  /// R1-F1's regression test could not see it, and that is the lesson worth keeping:
  /// it scrolls with `_scroll.jumpTo(0)`, a *programmatic* move with no drag to
  /// dispose, so it exercises the offset guard and never the mechanism that failed.
  /// The test now beside it drives a real [TestGesture] instead.
  bool _readerIsDragging = false;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// A reader within this many pixels of the bottom still counts as following the
  /// stream, so the panel keeps scrolling for them.
  ///
  /// **A deliberate comfort band, not a correction for measurement error** — review
  /// finding R2-F4. The first version of this comment called 48px "the smallest gap
  /// that is plainly a deliberate scroll rather than a rounding artefact of the
  /// previous jump", and there is no such artefact to defend against: R1-F4
  /// established that the jump lands *exactly* on the extent, asserted one screen
  /// away in the same test file. Defending an imaginary hazard is how a magic number
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
  void didUpdateWidget(_ResultPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Three conditions, and the third one is review finding **R1-F1**.
    //
    // The first two — the run is in flight, and the text actually *grew* — were
    // here already. The comment also claimed a third property it did not
    // implement: that a technician who scrolls up mid-generation is not yanked
    // back. It was not true, and the review proved it rather than arguing it: with
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
    // during generation is the thing this screen refuses to do — Task 1.8 measured
    // frames being dropped while tokens stream, and a smooth-scroll through that
    // stutters visibly in a recording.
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
                // The honest wording for the no-match case. Task 1.9's device run
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
/// Static, like everything else here. Task 1.9 emits `AgentToolCallStarted`
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
  /// generic "working…": one tool exists today and three more are in the spec's
  /// §2.2, and a wrong-but-specific label is easier to notice than a vague one.
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
  /// Task 1.5's two success shapes are kept apart here for the reason it kept them
  /// apart there: "we do not carry this part" and "we carry it and have none" are
  /// different sentences to a technician.
  ///
  /// **Every branch below reads the inventory tool's payload shape, so the tool is
  /// checked first.** One tool is registered today and the spec's §2.2 lists three
  /// more; without this gate the first of them renders as "null: null in stock",
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
    // and nothing else**, which is review finding R0-F2: four documents claimed
    // this screen branched on that getter while `_Body` in fact re-derived the
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
