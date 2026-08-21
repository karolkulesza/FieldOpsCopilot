import 'package:flutter/material.dart';

import '../diagnose_keys.dart';

/// A startup failure — a malformed seed asset, or a key that does not open the
/// existing database.
///
/// Rendered rather than thrown, because a malformed asset is required to
/// fail *loudly*, and a grey screen with a stack trace in the console is quiet.
/// The message is included: both causes are build or configuration mistakes, and
/// the person who can fix them is the person looking at the screen.
class StartupFailure extends StatelessWidget {
  const StartupFailure({required this.error, super.key});

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
