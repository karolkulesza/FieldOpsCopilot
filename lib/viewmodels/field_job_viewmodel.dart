/// The agent loop as UI state: one technician inquiry, from typed text to a
/// grounded answer.
///
/// This is the bridge Task 1.11's brief names — "Riverpod viewmodel bridges agent
/// loop to UI" — and the composition the last five tasks each deferred:
/// retrieval → compilation → loop is three lines, and they are in [diagnose].
///
/// **What belongs here and what does not.** `AgentLoop.run` already streams
/// everything this screen needs (Task 1.9 built the stream for it); the viewmodel's
/// job is to fold that stream into something a widget can rebuild from, and to make
/// the handful of *presentation* decisions the loop deliberately left open. Three
/// of those are worth reading before changing anything:
///
/// 1. **The live text is the current turn's, not the run's.** [FieldJobState.streamedText]
///    is cleared on every [AgentTurnStarted]. A run that calls a tool has a first
///    turn saying something like "let me check the warehouse" and a second turn
///    carrying the actual repair plan; accumulating both leaves the preamble glued
///    to the top of the answer forever. Clearing per turn also means the live text
///    has *already converged on* `AgentRunResult.answer` by the time the run ends,
///    so settling from one to the other is not a visible jump.
/// 2. **All three [AgentStopReason]s are distinct states, not one "done".** The
///    loop authors the text for the two failures ([AgentLoop.emptyResponseMessage],
///    [AgentLoop.iterationCapMessage]), so `answer` is always non-empty and always
///    truthful — but rendering a failure in the same panel as a diagnosis would
///    hand a technician a report of failure dressed as advice. [FieldJobState.isDiagnosis]
///    is the single question the widget asks.
/// 3. **A tool in flight is state, not an event.** [FieldJobState.activeTool] is
///    set by [AgentToolCallStarted] — which Task 1.9 emits *before* the query runs,
///    precisely so "checking inventory…" is on screen while it happens — and
///    cleared by the completion.
///
/// **Errors.** Caught `on Exception` and rendered as [FieldJobPhase.failed]. An
/// `Error` propagates, for the reason `ToolRegistry.dispatch` gives: it means the
/// app is broken, and dressing it as "the diagnosis failed" hides a defect behind
/// an operational-looking message. The one `Error` reachable from here in practice
/// is `AgentLoop.run`'s `StateError` for an unready engine, and [diagnose] refuses
/// to start without an [EngineReady], so reaching it means the warm-up state and
/// the engine disagree — which is a defect and should crash.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/ai/agent_loop.dart';
import '../services/ai/providers.dart';
import '../services/ai/tool_call_guard.dart';
import '../services/inference/engine_warmup_controller.dart';
import '../services/rag/providers.dart';
import '../services/rag/retrieval_router.dart';

/// Where one diagnosis is in its life.
///
/// The three the AC names ([idle], [thinking], [done]) plus [failed], because
/// something that threw is not a diagnosis and must not render as one.
enum FieldJobPhase {
  /// Nothing has been asked yet.
  idle,

  /// Retrieval, compilation and the loop are running. Tokens arrive during this.
  thinking,

  /// The loop finished. Which of the three endings is on
  /// [FieldJobState.stopReason]; whether it is an answer is
  /// [FieldJobState.isDiagnosis].
  done,

  /// Something threw before the loop could finish. [FieldJobState.failure] says
  /// what.
  failed,
}

/// Everything the demo screen renders.
@immutable
class FieldJobState {
  const FieldJobState({
    this.phase = FieldJobPhase.idle,
    this.inquiry = '',
    this.streamedText = '',
    this.activeTool,
    this.invocations = const [],
    this.rejectedCalls = const [],
    this.retrieval,
    this.result,
    this.failure,
  });

  final FieldJobPhase phase;

  /// The technician's words, trimmed — what was actually sent, not what is
  /// currently in the text field.
  final String inquiry;

  /// Tokens of the turn **currently** generating, in arrival order.
  ///
  /// Reset at each turn boundary; see the library doc for why. Empty until the
  /// first token, which is the ~340-550ms of prefill Task 1.8 measured.
  final String streamedText;

  /// The tool call in flight, or `null`.
  ///
  /// The event itself rather than a parallel "tool activity" type, on the argument
  /// Task 1.5 used to delete `AgentTool.name`: a second representation of one fact
  /// is a second thing that can disagree with the first.
  final AgentToolCallStarted? activeTool;

  /// Tool calls that have completed, in order, across every turn.
  final List<AgentToolInvocation> invocations;

  /// Call attempts the guard refused. Shown because a technician watching the
  /// model fumble a call and recover is the agent loop being legible rather than
  /// magic — and because silently dropping them would make a four-turn run look
  /// like an inexplicably slow two-turn one.
  final List<GuardFailure> rejectedCalls;

  /// What retrieval found, for the "grounded in" line.
  ///
  /// Set before the loop starts, so the screen can show what the answer is
  /// *supposed* to be grounded in while it is still being written.
  final RetrievalResult? retrieval;

  /// The finished run, or `null` until [FieldJobPhase.done].
  final AgentRunResult? result;

  /// Why the run could not be attempted or could not finish.
  final String? failure;

  /// Whether a run is in flight — what disables the button.
  bool get isBusy => phase == FieldJobPhase.thinking;

  /// How the loop ended, or `null` if it has not.
  AgentStopReason? get stopReason => result?.stopReason;

  /// Whether what is on screen is a diagnosis the model produced.
  ///
  /// False for both loop-authored endings and for [FieldJobPhase.failed]. The
  /// single question the widget branches on, so the "is this advice or is this a
  /// report of failure" decision is made once, here, rather than at each place
  /// that draws a panel.
  bool get isDiagnosis => stopReason == AgentStopReason.answered;

  /// The text to show: the finished answer once there is one, the live stream
  /// while there is not.
  ///
  /// For [FieldJobPhase.failed] this is empty and [failure] is what to render —
  /// deliberately not merged, because a failure message is not a diagnosis and
  /// giving them one accessor would be an invitation to draw them the same way.
  String get displayText => switch (phase) {
    FieldJobPhase.done => result!.answer,
    FieldJobPhase.failed => '',
    FieldJobPhase.idle || FieldJobPhase.thinking => streamedText,
  };

  FieldJobState copyWith({
    FieldJobPhase? phase,
    String? inquiry,
    String? streamedText,
    Object? activeTool = _unset,
    List<AgentToolInvocation>? invocations,
    List<GuardFailure>? rejectedCalls,
    Object? retrieval = _unset,
    Object? result = _unset,
    Object? failure = _unset,
  }) => FieldJobState(
    phase: phase ?? this.phase,
    inquiry: inquiry ?? this.inquiry,
    streamedText: streamedText ?? this.streamedText,
    // The sentinel is what lets a nullable field be *cleared* rather than only
    // set. Without it `copyWith(activeTool: null)` is indistinguishable from
    // "leave it alone", and clearing the in-flight tool is the common case.
    activeTool: activeTool == _unset
        ? this.activeTool
        : activeTool as AgentToolCallStarted?,
    invocations: invocations ?? this.invocations,
    rejectedCalls: rejectedCalls ?? this.rejectedCalls,
    retrieval: retrieval == _unset
        ? this.retrieval
        : retrieval as RetrievalResult?,
    result: result == _unset ? this.result : result as AgentRunResult?,
    failure: failure == _unset ? this.failure : failure as String?,
  );

  static const Object _unset = Object();
}

/// Runs one diagnosis and exposes its progress.
class FieldJobViewModel extends Notifier<FieldJobState> {
  @override
  FieldJobState build() => const FieldJobState();

  /// Runs the whole slice for [rawInquiry].
  ///
  /// Ignores a blank inquiry and a call made while one is already running. The
  /// second guard is not only tidiness: both engine implementations refuse an
  /// overlapping `generate` with a `StateError` (Task 1.8 made the fake refuse it
  /// too, so the host suite cannot be more permissive than the device), so a
  /// double tap without this guard is a crash rather than a wasted run.
  Future<void> diagnose(String rawInquiry) async {
    final inquiry = rawInquiry.trim();
    if (inquiry.isEmpty || state.isBusy) return;

    final warmup = ref.read(engineWarmupControllerProvider);
    if (warmup is! EngineReady) {
      // Reachable by a caller that did not gate on readiness. The screen does
      // gate, so this is a backstop that reports rather than throws — and it says
      // which state it found, because "the model is not ready" without saying
      // whether that is *loading*, *absent* or *failed* is the least useful
      // sentence available.
      state = FieldJobState(
        phase: FieldJobPhase.failed,
        inquiry: inquiry,
        failure: _notReadyMessage(warmup),
      );
      return;
    }

    state = FieldJobState(phase: FieldJobPhase.thinking, inquiry: inquiry);

    try {
      final router = await ref.read(retrievalRouterProvider.future);
      final registry = await ref.read(toolRegistryProvider.future);
      final compiler = ref.read(promptCompilerProvider);

      // The composition. Three lines, as the plan said, and this is them.
      final retrieval = await router.retrieve(inquiry);
      final prompt = compiler.compile(retrieval);
      final loop = AgentLoop(engine: warmup.engine, registry: registry);

      if (!ref.mounted) return;
      state = state.copyWith(retrieval: retrieval);

      await for (final event in loop.run(prompt)) {
        // Returning here cancels the subscription, which is what releases the
        // engine's in-flight turn — the fake holds that slot until *someone*
        // drains or cancels the stream, so walking away without cancelling would
        // deadlock the next run.
        if (!ref.mounted) return;
        state = applyEvent(state, event);
      }
    } on Exception catch (error, stackTrace) {
      // `on Exception`, never `on Object`: see the library doc.
      debugPrint('[FieldJob] diagnosis failed: $error\n$stackTrace');
      if (!ref.mounted) return;
      state = state.copyWith(
        phase: FieldJobPhase.failed,
        activeTool: null,
        failure: 'This diagnosis could not be completed: $error',
      );
    }
  }

  /// Folds one loop event into the state.
  ///
  /// Static and pure so it can be read as a table, and **public for the reason
  /// `PromptCompiler.neutralizeMarkers` is**: one row of the table is not
  /// reachable through `run`. A refused call attempt cannot coexist with a tool in
  /// flight, so the only way to assert that `AgentToolCallRejected` leaves
  /// [FieldJobState.activeTool] alone is to hand this function both at once. A
  /// property bound only by a comment is the thing this project keeps paying for.
  @visibleForTesting
  static FieldJobState applyEvent(
    FieldJobState state,
    AgentEvent event,
  ) => switch (event) {
    // A new turn replaces the visible text rather than appending to it. See
    // the library doc: this is what keeps the first turn's "let me check the
    // warehouse" from being glued above the repair plan.
    AgentTurnStarted() => state.copyWith(streamedText: '', activeTool: null),
    AgentToken(:final text) => state.copyWith(
      streamedText: state.streamedText + text,
    ),
    AgentToolCallStarted() => state.copyWith(activeTool: event),
    AgentToolCallCompleted(:final invocation) => state.copyWith(
      activeTool: null,
      invocations: [...state.invocations, invocation],
    ),
    // `activeTool` is deliberately *not* cleared here. A refused attempt never
    // produced an `AgentToolCallStarted` — the guard refuses before dispatch —
    // so there is nothing in flight to clear, and clearing would imply
    // otherwise to the next person reading this table.
    AgentToolCallRejected(:final failure) => state.copyWith(
      rejectedCalls: [...state.rejectedCalls, failure],
    ),
    AgentCompleted(:final result) => state.copyWith(
      phase: FieldJobPhase.done,
      activeTool: null,
      result: result,
    ),
  };

  static String _notReadyMessage(EngineWarmupState warmup) => switch (warmup) {
    EngineIdle() => 'The on-device model has not started loading yet.',
    EngineLoading() => 'The on-device model is still loading.',
    EngineUnavailable() =>
      'No verified model weights are installed on this device.',
    EngineFailed(:final message) =>
      'The on-device model is unavailable: '
          '$message',
    // Unreachable: `diagnose` only calls this on the `is! EngineReady` branch.
    // Answered rather than thrown because a wrong message is a better failure
    // than a crash on the screen being recorded, and it cannot silently mislead
    // — nothing renders it without a non-ready state to have produced it.
    EngineReady() => 'The on-device model is ready.',
  };
}

/// The one diagnosis the demo screen drives.
final fieldJobViewModelProvider =
    NotifierProvider<FieldJobViewModel, FieldJobState>(FieldJobViewModel.new);
