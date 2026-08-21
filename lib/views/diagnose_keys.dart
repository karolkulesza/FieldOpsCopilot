/// The `Key`s the screen's widgets carry, in one place.
///
/// A separate library rather than a member of `DiagnoseScreen`, because the
/// components under `components/` need them too and the screen imports those —
/// so keeping the vocabulary on the screen would make the dependency a cycle.
/// Tests reach them through `diagnose_screen.dart`, which re-exports this.
library;

import 'package:flutter/foundation.dart';

import '../services/ai/agent_loop.dart';

/// Keys the widget tests find things by, so an assertion names a role rather than
/// a colour or a string of copy.
abstract final class DiagnoseKeys {
  static const Key inquiryField = Key('diagnose-inquiry-field');

  /// Empties the inquiry field. Present only while it has text.
  static const Key clearInquiry = Key('diagnose-clear-inquiry');
  static const Key diagnoseButton = Key('diagnose-button');
  static const Key resultPanel = Key('diagnose-result-panel');
  static const Key engineStatus = Key('diagnose-engine-status');
  static const Key toolActivity = Key('diagnose-tool-activity');

  /// The database or the seed could not be prepared — the app cannot retrieve.
  static const Key startupFailure = Key('diagnose-startup-failure');

  /// The microphone toggle.
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
