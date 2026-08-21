import 'package:flutter/material.dart';

import '../../services/inference/engine_warmup_controller.dart';
import '../diagnose_keys.dart';

/// Whether the on-device model is loaded — a **static** row in every state.
///
/// See the library doc: the UI isolate is stalled for 1445–1728ms inside
/// [EngineLoading], so anything animated here freezes exactly when it is being
/// looked at.
class EngineStatusRow extends StatelessWidget {
  const EngineStatusRow({required this.warmup, super.key});

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
