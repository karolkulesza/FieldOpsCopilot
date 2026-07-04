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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/ai/agent_loop.dart';
import '../services/ai/base_tool.dart';
import '../services/ai/tools/get_parts_inventory_tool.dart';
import '../services/database/providers.dart';
import '../services/database/tables.dart' show normalizeSku;
import '../services/inference/engine_warmup_controller.dart';
import '../viewmodels/field_job_viewmodel.dart';
import 'components/model_readiness_banner.dart';

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
  }

  @override
  void dispose() {
    _inquiry.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final job = ref.watch(fieldJobViewModelProvider);
    final warmup = ref.watch(engineWarmupControllerProvider);
    // Watched rather than read so a startup failure is rendered instead of
    // surfacing as an exception the first time the viewmodel touches it.
    final startup = ref.watch(seedOutcomeProvider);

    final canDiagnose =
        warmup is EngineReady && !job.isBusy && !startup.hasError;

    return Scaffold(
      appBar: AppBar(
        title: const Text('FieldOps Copilot'),
        backgroundColor: theme.colorScheme.inversePrimary,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
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
              const SizedBox(height: 16),
              TextField(
                key: DiagnoseKeys.inquiryField,
                controller: _inquiry,
                minLines: 2,
                maxLines: 4,
                textInputAction: TextInputAction.newline,
                decoration: const InputDecoration(
                  labelText: 'Describe the fault',
                  hintText: 'e.g. cabin vibrating, E-102',
                  border: OutlineInputBorder(),
                ),
                // Rebuilds so the button's enabled state follows the text. The
                // viewmodel refuses a blank inquiry too; this is the affordance,
                // that is the guarantee.
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                key: DiagnoseKeys.diagnoseButton,
                onPressed: canDiagnose && _inquiry.text.trim().isNotEmpty
                    ? () => ref
                          .read(fieldJobViewModelProvider.notifier)
                          .diagnose(_inquiry.text)
                    : null,
                icon: const Icon(Icons.medical_services_outlined),
                // No spinner in the busy label, for the reason in the library doc.
                // "Diagnosing…" plus text arriving in the panel below is the
                // progress report.
                label: Text(job.isBusy ? 'Diagnosing…' : 'Diagnose'),
              ),
              const SizedBox(height: 16),
              Expanded(child: _ResultPanel(job: job)),
            ],
          ),
        ),
      ),
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
class _ResultPanel extends StatelessWidget {
  const _ResultPanel({required this.job});

  final FieldJobState job;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      key: DiagnoseKeys.resultPanel,
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (job.retrieval != null) ...[
              _GroundingLine(job: job),
              const Divider(height: 20),
            ],
            for (final invocation in job.invocations)
              _CompletedTool(invocation: invocation),
            for (final failure in job.rejectedCalls)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  'The assistant sent a malformed lookup and was asked to retry.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                  semanticsLabel: failure.message,
                ),
              ),
            if (job.activeTool != null) _ToolActivity(started: job.activeTool!),
            if (job.invocations.isNotEmpty ||
                job.rejectedCalls.isNotEmpty ||
                job.activeTool != null)
              const SizedBox(height: 12),
            _Body(job: job),
          ],
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
  static String _summarise(AgentToolInvocation invocation) {
    final payload = invocation.outcome.payload;
    final replayed = invocation.repeated ? ' (already answered)' : '';
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
      return Text(job.displayText, style: theme.textTheme.bodyLarge);
    }

    // Finished. The three endings are three different things to say, and the
    // header is what stops a report of failure being read as advice.
    final (IconData icon, String header, Color color) = switch (reason) {
      AgentStopReason.answered => (
        Icons.check_circle,
        'Repair plan',
        theme.colorScheme.primary,
      ),
      AgentStopReason.emptyResponse => (
        Icons.help_outline,
        'No answer produced',
        theme.colorScheme.error,
      ),
      AgentStopReason.iterationCapReached => (
        Icons.report_problem_outlined,
        'Diagnosis stopped',
        theme.colorScheme.error,
      ),
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
        Text(job.displayText, style: theme.textTheme.bodyLarge),
      ],
    );
  }
}
