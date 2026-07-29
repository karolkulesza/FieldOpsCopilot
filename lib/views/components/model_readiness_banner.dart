import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/models/model_descriptor.dart';
import '../../services/models/model_storage.dart';
import '../../services/models/providers.dart';

/// Shows whether verified model weights are present on this device.
///
/// This exists because of a demo-day failure mode, not for decoration: a
/// first-run download of 2.4GB over venue Wi-Fi is a coin flip, so the model is
/// pre-installed and the app has to make "are the weights actually here, and did
/// they verify?" visible *before* someone taps Diagnose. The four states below
/// are exactly the four answers the provisioner can give.
class ModelReadinessBanner extends ConsumerWidget {
  const ModelReadinessBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final descriptor = ref.watch(activeModelDescriptorProvider);
    final status = ref.watch(modelInstallStatusProvider);

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

    return Row(
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
          'Weights are present but unverified — run provisioning to hash '
          'them against the pinned SHA-256.',
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
