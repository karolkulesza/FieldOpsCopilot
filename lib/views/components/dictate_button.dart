/// The microphone toggle and the line under it that says what dictation is doing.
///
/// Two widgets in one library because they are one control: the button starts and
/// stops, the status line is the only feedback that it worked, and a change to
/// either without the other leaves a microphone whose state cannot be read.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../viewmodels/dictation_viewmodel.dart';
import '../diagnose_keys.dart';

/// The microphone toggle.
///
/// **A toggle rather than press-and-hold**, which is the one interaction decision
/// here and it is made for the technician rather than for the test: this app's
/// persona is someone in heavy gloves, and holding a soft key steady for
/// fifteen seconds through a glove is exactly the thing gloves are bad at. A
/// toggle also makes the "stop" moment observable, which press-and-hold leaves to
/// a pointer-up nothing records.
///
/// **Static in every state, like everything else on this screen.** No pulsing
/// record dot: the UI isolate measurably drops 5–8 frames while tokens
/// stream, and a recogniser decode step runs on its own isolate but the *state
/// updates* land here — an animation that stutters exactly when the microphone is
/// working reads as the microphone failing.
class DictateButton extends ConsumerWidget {
  const DictateButton({required this.dictation, required this.busy, super.key});

  final DictationState dictation;

  /// Whether a diagnosis is running. Dictating into an inquiry the agent has
  /// already compiled a prompt from would change the question after it was asked.
  final bool busy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final controller = ref.read(dictationControllerProvider.notifier);
    final active = dictation.isActive;

    return IconButton.filledTonal(
      key: DiagnoseKeys.dictateButton,
      // **Live during `starting` too.** A second tap in that window once did
      // nothing — it only reached `start`'s own re-entry guard, which reads as a
      // dead button — but `start` now has a cancellation edge, so a stop during
      // the load genuinely stops. With the
      // wait made visible (it is 1227ms of microphone plus 458ms of model on the
      // demo device), a button that cannot be taken back during it is worse than
      // one that can.
      onPressed: busy
          ? null
          : () => active ? controller.stop() : controller.start(),
      tooltip: active ? 'Stop dictating' : 'Dictate the fault',
      icon: Icon(active ? Icons.stop : Icons.mic_none),
      style: IconButton.styleFrom(
        foregroundColor: active ? theme.colorScheme.error : null,
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
class DictationStatus extends StatelessWidget {
  const DictationStatus({required this.dictation, super.key});

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
        // **"Wait" is the operative word and it is there for a measured reason.**
        // Opening the input takes 1227ms on the demo iPad and the recogniser load
        // another 458ms; a technician who talks over that window loses the start
        // of their sentence, which is what "IN VIBRATING" was. The status now
        // names the thing to wait for, and `listening` does not appear until audio
        // is genuinely arriving.
        'Getting the microphone ready — wait for “Listening”',
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
