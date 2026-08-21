/// The demo screen: typed inquiry → Diagnose → live tokens → grounded answer.
///
/// This is the screen the demo recording captures, so a handful of decisions
/// here are about the recording as much as about the UI.
///
/// This library owns the layout and the two things that genuinely belong to the
/// screen: the inquiry `TextEditingController`, and the mirroring between
/// dictation and that field. Everything it composes lives under `components/` —
/// [ResultPanel], [DictateButton], [DictationStatus], [EngineStatusRow],
/// [StartupFailure] — and the keys they all carry are in `diagnose_keys.dart`.
///
/// **Nothing on this screen animates while the model works, and that is
/// deliberate.** Two things were measured on the demo device (iPad Air M4,
/// iOS 26.5, Metal): the UI isolate stalls **1445–1728ms** while the weights load,
/// and it drops **5–8 frames** (77–135ms worst gap) while tokens stream. A
/// progress indicator during either one freezes or stutters — and a frozen
/// indicator reads as a crash, which is strictly worse than a static label saying
/// what is happening. So there is no `CircularProgressIndicator` and no
/// `LinearProgressIndicator` **anywhere in this screen's tree** — this library or
/// any component under `components/` that it composes. That is deliberately a
/// wider claim than "not in this file", because the widgets this rule is about
/// were moved out of it: `diagnose_screen_test.dart` walks the whole tree for
/// `ProgressIndicator` rather than trusting either paragraph, so the assertion did
/// not narrow when the file did.
///
/// The live token stream is the honest progress indicator: text appearing is
/// unambiguous evidence of work, it cannot stutter in a way that reads as a hang,
/// and it is the single most convincing thing in the recording. (One exception is
/// out of scope and stays: `ModelReadinessBanner` shows a determinate bar while
/// *downloading* weights. A download is network I/O with no UI-isolate stall, so
/// a determinate bar there is safe.)
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
import '../services/database/providers.dart';
import '../services/inference/engine_warmup_controller.dart';
import '../services/models/model_storage.dart';
import '../services/models/providers.dart';
import '../viewmodels/dictation_viewmodel.dart';
import '../viewmodels/field_job_viewmodel.dart';
import '../viewmodels/work_order_form_viewmodel.dart';
import 'components/clarification_dialog.dart';
import 'components/dictate_button.dart';
import 'components/engine_status_row.dart';
import 'components/model_readiness_banner.dart';
import 'components/result_panel.dart';
import 'components/startup_failure.dart';
import 'components/work_order_form_panel.dart';
import 'diagnose_keys.dart';

// Re-exported so a test or a caller that imports the screen still gets its key
// vocabulary from one place. The components import `diagnose_keys.dart` itself.
export 'diagnose_keys.dart';

/// One screen: the whole inquiry-to-answer slice.
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
  /// **`null` also means "released", and the release exists for a demonstrated
  /// reason.** The field is not read-only while the microphone is open, because a
  /// technician watching `FALK CODE` land has to be able to fix it — but
  /// [_onDictation] rebuilds the whole line from `base + transcript` on **every**
  /// state change, so without a release a correction was overwritten by the next
  /// partial, and by the capture merely ending. Measured, not argued.
  ///
  /// The rule is: **typing takes the
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

    // **And again whenever weights become ready.**
    // The callback above is one-shot, and this screen is
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
    // The LLM's family instance specifically (the status provider is
    // per-model): the STT set becoming ready changes nothing about the engine,
    // and warming up on its edge would be a no-op fired for the wrong reason.
    ref.listenManual(
      modelInstallStatusProvider(ref.read(activeLlmDescriptorProvider).id),
      (previous, next) {
        // `next.value`, not `valueOrNull` —
        // Riverpod 3's `AsyncValue` exposes a nullable `value` and no `valueOrNull`,
        // so `valueOrNull` does not compile here. `ModelReadinessBanner`
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
  /// `base + that` over the words just typed — the same overwrite the release
  /// exists to prevent, arriving through the other door.
  void _onInquiryEdited() {
    if (_dictationBase != null &&
        ref.read(dictationControllerProvider).isActive) {
      _dictationBase = null;
      unawaited(ref.read(dictationControllerProvider.notifier).stop());
    }
    setState(() {});
  }

  /// Empties the inquiry field in one tap.
  ///
  /// **It goes through [_onInquiryEdited] rather than just calling `clear()`**,
  /// and both halves of that matter.
  ///
  /// `controller.clear()` is a *programmatic* write, so `onChanged` does not fire
  /// — the same asymmetry [_onDictation] documents. Without this call the text
  /// would vanish while Diagnose stayed enabled, because the button's enabled
  /// state is computed in `build` from `_inquiry.text` and nothing would have
  /// asked for a rebuild.
  ///
  /// And clearing **is an edit by the technician**, so it takes the field on
  /// exactly the terms typing does: during a capture it releases the mirror and
  /// stops the microphone. Anything else would be worse in both directions — a
  /// clear that left the mirror attached would be undone by the next partial, and
  /// one that left the microphone open would go on filling a field the technician
  /// had just emptied.
  ///
  /// The dictation state is deliberately not touched. `start()` resets the
  /// transcript and [_onDictation] re-reads the base from the field, so the next
  /// capture already begins from what is there — which, after this, is nothing.
  void _clearInquiry() {
    _inquiry.clear();
    _onInquiryEdited();
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
                // this column overflowed by 64 pixels. The two panels below are
                // `Expanded` and had already collapsed to zero, so what did not
                // fit was the *fixed* chrome itself.
                //
                // Reproduced in `voice_and_form_screen_test.dart` at **4 pixels**,
                // with a 420pt keyboard inset and the device's own readiness state
                // (no LLM configured, STT installed). The magnitudes differ because
                // the device's banner is taller still; the mechanism is the same.
                // The inset is stated because it is load-bearing — at 360 the
                // defect does not reproduce at all, and the first version of that
                // test passed with this fix reverted.
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
                        EngineStatusRow(warmup: warmup),
                        if (startup.hasError) ...[
                          const SizedBox(height: 12),
                          StartupFailure(error: startup.error!),
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
                        decoration: InputDecoration(
                          labelText: 'Describe the fault',
                          hintText: 'e.g. cabin vibrating, E-102',
                          border: const OutlineInputBorder(),
                          // **Only when there is something to clear.** A button
                          // that is always there is a permanent invitation to
                          // destroy the field, sitting a thumb's width from the
                          // microphone; one that appears with the text says what
                          // it does by existing. It also keeps the empty state —
                          // the screen a technician meets — free of a control
                          // that would do nothing.
                          //
                          // A `suffixIcon` rather than another button in the row
                          // beside the microphone: the row is already tight at
                          // the demo device's width, and adding chrome to this
                          // column has already caused one recorded overflow.
                          suffixIcon: _inquiry.text.isEmpty
                              ? null
                              : IconButton(
                                  key: DiagnoseKeys.clearInquiry,
                                  icon: const Icon(Icons.clear),
                                  tooltip: 'Clear the fault description',
                                  onPressed: _clearInquiry,
                                ),
                        ),
                        // Rebuilds so the button's enabled state follows the text.
                        // The viewmodel refuses a blank inquiry too; this is the
                        // affordance, that is the guarantee.
                        //
                        // `onChanged` fires for a *user* edit only — never for the
                        // programmatic write in [_onDictation] — which is what
                        // makes it safe to treat it as "the technician took the
                        // field".
                        onChanged: (_) => _onInquiryEdited(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    DictateButton(dictation: dictation, busy: job.isBusy),
                  ],
                ),
                if (dictation.phase != DictationPhase.idle) ...[
                  const SizedBox(height: 8),
                  DictationStatus(dictation: dictation),
                ],
                const SizedBox(height: 12),
                FilledButton.icon(
                  key: DiagnoseKeys.diagnoseButton,
                  onPressed: canDiagnose && _inquiry.text.trim().isNotEmpty
                      ? () {
                          // **Before the run, not after it.** A new inquiry
                          // discards the previous one's agent-filled fields, and
                          // the agent's first `record_work_order_fields` call can
                          // land before its answer does — so clearing on
                          // completion would erase the run that just filled the
                          // form. The technician's own values survive either way;
                          // see `WorkOrderFormState.forNewInquiry`.
                          ref
                              .read(workOrderFormProvider.notifier)
                              .beginInquiry();
                          ref
                              .read(fieldJobViewModelProvider.notifier)
                              .diagnose(_inquiry.text);
                        }
                      : null,
                  icon: const Icon(Icons.medical_services_outlined),
                  // No spinner in the busy label, for the reason in the library
                  // doc. "Diagnosing…" plus text arriving in the panel below is the
                  // progress report.
                  label: Text(job.isBusy ? 'Diagnosing…' : 'Diagnose'),
                ),
                const SizedBox(height: 16),
                // Three parts to two, and the split is what makes the form fill
                // *visible* — the demo moment is fields populating while the
                // answer streams, which a collapsed section would hide. The panel
                // is outside the answer's scroll view for the reason
                // `work_order_form_panel.dart` gives.
                Expanded(flex: 3, child: ResultPanel(job: job)),
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
