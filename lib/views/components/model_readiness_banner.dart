import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/models/model_descriptor.dart';
import '../../services/models/model_provisioner.dart';
import '../../services/models/model_provisioning_controller.dart';
import '../../services/models/model_storage.dart';
import '../../services/models/providers.dart';

/// Shows whether verified model weights are present on this device, and offers the
/// one action that can change it — one row per provisioned model.
///
/// This exists because of a demo-day failure mode, not for decoration: a
/// first-run download of 2.6GB over venue Wi-Fi is a coin flip, so the model is
/// pre-installed and the app has to make "are the weights actually here, and did
/// they verify?" visible *before* someone taps Diagnose. The states below
/// are exactly the answers the provisioner can give.
///
/// Task 2.0 turned the single banner into a **column of independent rows**, one
/// per entry in [provisionedModelDescriptorsProvider]. Independent is the
/// load-bearing word: each row watches its own family instance of the status and
/// provisioning providers, so the STT set being absent renders as one warning row
/// while the LLM's row — and everything the LLM gates, Diagnose included — is
/// untouched (TC-PROV-MULTI-01).
///
/// Task 1.8 added the trigger underneath each row. Note what the button
/// deliberately does *not* do: it does not come back after a download whose bytes
/// failed the pinned digest. That is a configuration error, a retry moves the same
/// gigabytes and fails the same way, and `ModelProvisioningController` is where
/// that rule lives.
class ModelReadinessBanner extends ConsumerWidget {
  const ModelReadinessBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final descriptors = ref.watch(provisionedModelDescriptorsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < descriptors.length; i++) ...[
          if (i > 0) const SizedBox(height: 12),
          _ModelRow(descriptor: descriptors[i]),
        ],
      ],
    );
  }
}

/// Readiness and provisioning for one model — Task 1.7's whole banner, scoped to
/// a descriptor.
class _ModelRow extends ConsumerWidget {
  const _ModelRow({required this.descriptor});

  final ModelDescriptor descriptor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final status = ref.watch(modelInstallStatusProvider(descriptor.id));
    final provisioning = ref.watch(
      modelProvisioningControllerProvider(descriptor.id),
    );

    final display = status.when(
      loading: () => const _Display(
        icon: Icons.hourglass_empty,
        label: 'Checking model…',
        tone: _Tone.neutral,
      ),
      // The status check itself failing (no platform channel, unreadable
      // directory) is distinct from "no model": it says nothing about the
      // weights, so it must not be rendered as either ready or absent.
      error: (error, _) => _Display(
        icon: Icons.help_outline,
        label: 'Model status unavailable',
        detail: '$error',
        tone: _Tone.warning,
      ),
      data: (value) => _forStatus(value, descriptor),
    );

    final color = switch (display.tone) {
      _Tone.ready => theme.colorScheme.primary,
      _Tone.warning => theme.colorScheme.error,
      _Tone.neutral => theme.disabledColor,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(display.icon, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(display.label, style: theme.textTheme.titleMedium),
                  if (display.detail != null)
                    Text(
                      display.detail!,
                      style: theme.textTheme.bodySmall,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
          ],
        ),
        _ProvisioningSection(
          descriptor: descriptor,
          installStatus: status.value,
          provisioning: provisioning,
        ),
      ],
    );
  }

  static _Display _forStatus(
    ModelInstallStatus status,
    ModelDescriptor descriptor,
  ) => switch (status) {
    ModelInstallStatus.ready => _Display(
      icon: Icons.verified,
      label: 'Model ready',
      detail: descriptor.displayName,
      tone: _Tone.ready,
    ),
    ModelInstallStatus.unverified => _Display(
      icon: Icons.pending_outlined,
      label: 'Model needs verification',
      detail:
          '${descriptor.displayName} — weights are present but unverified; '
          'run provisioning to hash them against the pinned SHA-256.',
      tone: _Tone.warning,
    ),
    // "Absent" splits in two, because the operator's next action is completely
    // different: fetch the weights, or fix the build configuration.
    ModelInstallStatus.absent => switch (descriptor.configurationIssue) {
      null => _Display(
        icon: Icons.cloud_download_outlined,
        label: 'Model not installed',
        detail: descriptor.displayName,
        tone: _Tone.warning,
      ),
      ModelConfigurationIssue.missingSource => _Display(
        icon: Icons.link_off,
        label: 'Model source not configured',
        detail:
            'Set FIELDOPS_MODEL_URI (and accept the license at '
            '${descriptor.licensePage}).',
        tone: _Tone.warning,
      ),
      ModelConfigurationIssue.unpinnedHash => const _Display(
        icon: Icons.gpp_maybe_outlined,
        label: 'Model hash not pinned',
        detail:
            'Set FIELDOPS_MODEL_SHA256 — weights are never installed '
            'unverified.',
        tone: _Tone.warning,
      ),
    },
  };
}

/// The action half of a row: a trigger, a progress bar, or a reason.
///
/// Renders nothing at all in the common cases — weights ready, or a build that is not
/// configured to fetch anything — because an inert button next to "Model ready" is
/// just an invitation to re-download 2.6GB.
class _ProvisioningSection extends ConsumerWidget {
  const _ProvisioningSection({
    required this.descriptor,
    required this.installStatus,
    required this.provisioning,
  });

  final ModelDescriptor descriptor;

  /// Null while the status is still loading or failed to load — neither of which is a
  /// state to offer a download from, since nothing is known about the weights yet.
  final ModelInstallStatus? installStatus;

  final ModelProvisioningState provisioning;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    if (provisioning is ProvisioningRunning) {
      final running = provisioning as ProvisioningRunning;
      // "file 2 of 4" earns its place only on a set; on a single-file model it
      // would be noise that is always "1 of 1".
      final fileAnnotation = running.fileCount > 1
          ? ' (file ${running.fileIndex} of ${running.fileCount})'
          : '';
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // A null fraction means the total is genuinely unknown (no
            // `Content-Length`, no documented size). An indeterminate bar is the
            // honest rendering; a fabricated percentage would not be.
            LinearProgressIndicator(value: running.fraction),
            const SizedBox(height: 4),
            Text(switch (running.phase) {
              ModelProvisionPhase.downloading =>
                running.fraction == null
                    ? 'Downloading weights$fileAnnotation…'
                    : 'Downloading weights$fileAnnotation — '
                          '${(running.fraction! * 100).floor()}%',
              ModelProvisionPhase.verifying =>
                'Verifying SHA-256$fileAnnotation…',
            }, style: theme.textTheme.bodySmall),
          ],
        ),
      );
    }

    final failure = provisioning is ProvisioningFailed
        ? provisioning as ProvisioningFailed
        : null;
    // A configuration problem is already spelled out by the banner's own detail line;
    // repeating it under a button the operator cannot usefully press would be noise.
    final canProvision =
        descriptor.configurationIssue == null &&
        installStatus != null &&
        installStatus != ModelInstallStatus.ready &&
        (failure == null || failure.retryable);

    if (failure == null && !canProvision) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (failure != null)
            Text(
              failure.message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          if (canProvision)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: FilledButton.tonalIcon(
                onPressed: () => ref
                    .read(
                      modelProvisioningControllerProvider(
                        descriptor.id,
                      ).notifier,
                    )
                    .provision(),
                icon: const Icon(Icons.download),
                // The two labels are different work: one fetches gigabytes, the other
                // only hashes what is already here. Saying which is about to happen is
                // the difference between a considered tap and a surprise transfer.
                label: Text(
                  installStatus == ModelInstallStatus.unverified
                      ? 'Verify weights'
                      : 'Download & verify weights',
                ),
              ),
            ),
        ],
      ),
    );
  }
}

enum _Tone { ready, warning, neutral }

class _Display {
  const _Display({
    required this.icon,
    required this.label,
    required this.tone,
    this.detail,
  });

  final IconData icon;
  final String label;
  final String? detail;
  final _Tone tone;
}
