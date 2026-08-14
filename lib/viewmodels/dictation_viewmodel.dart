/// Voice input as UI state: microphone → recogniser → the words on screen.
///
/// This is the wiring Task 2.2's row says nothing performs yet — *"nothing today
/// consumes a transcript"* — and it is deliberately the last hop rather than a
/// re-implementation of anything below it. `MicCapture` already owns the
/// permission gate, frame normalisation and the bounded backlog; `SherpaSttEngine`
/// already owns the isolate, the endpointer and the spoken-digit repair. What is
/// left, and what this owns, is the three decisions neither of them could make:
///
/// 1. **What a technician sees while a streaming recogniser is mid-utterance.** A
///    zipformer emits interim partials and then a final per utterance, and
///    [SttTranscript.segment] exists so a consumer can tell "a better guess at what
///    you just said" from "a new sentence". [DictationState.text] assembles both:
///    finals are committed by segment and the newest partial trails them, so the
///    line grows the way speech does instead of being rewritten under the reader.
/// 2. **When the microphone stops.** Not on a timer and not on the recogniser
///    going quiet: on the technician letting go. `MicCapture.stallTimeout` handles
///    the one case where the input dies without saying so, and it arrives here as
///    an error rather than as silence.
/// 3. **That there is no engine at all**, which on this device is an ordinary
///    state rather than a failure — see `services/audio/providers.dart` for why the
///    absent case answers `null` instead of a fake.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../engines/stt_engine.dart';
import '../services/audio/mic_capture.dart';
import '../services/audio/providers.dart';

/// Where dictation is.
enum DictationPhase {
  /// Nothing is running. [DictationState.text] holds whatever the last capture
  /// produced, because the screen has already put it in the inquiry field and a
  /// state that forgot it would flicker.
  idle,

  /// The recogniser is loading, or the microphone is opening.
  ///
  /// Its own phase rather than folded into [listening] because Task 2.2 measured
  /// the recogniser's constructor at 359–530ms and this is the first tap of the
  /// demo: a button that looks unresponsive for half a second is the thing Task
  /// 1.11's whole screen is written to avoid.
  starting,

  /// Audio is flowing and transcripts are arriving.
  listening,

  /// Dictation is not available on this device, or was refused.
  ///
  /// Distinct from [failed] because the two are different sentences and only one
  /// of them is worth a retry: no verified weights and a denied permission are
  /// states of the device, and a microphone that died mid-utterance is an event.
  unavailable,

  /// A capture started and then went wrong.
  failed,
}

/// Everything the microphone button and the inquiry field need.
@immutable
class DictationState {
  const DictationState({
    this.phase = DictationPhase.idle,
    this.committed = const [],
    this.partial = '',
    this.message,
  });

  final DictationPhase phase;

  /// Completed utterances, in segment order.
  final List<String> committed;

  /// The recogniser's current guess at the utterance still being spoken.
  final String partial;

  /// Why dictation is unavailable or failed. `null` otherwise.
  final String? message;

  /// Whether the microphone is open or about to be.
  bool get isActive =>
      phase == DictationPhase.starting || phase == DictationPhase.listening;

  /// Everything heard so far, as one line.
  ///
  /// Joined with single spaces: the recogniser emits no punctuation and no
  /// inter-utterance spacing, so concatenating raw runs the last word of one
  /// utterance into the first of the next — which then reaches
  /// `RetrievalRouter`'s FTS query as a word that is in no manual.
  String get text => [
    ...committed.where((utterance) => utterance.trim().isNotEmpty),
    if (partial.trim().isNotEmpty) partial.trim(),
  ].join(' ');

  /// Whether anything has been heard.
  bool get isEmpty => text.isEmpty;

  DictationState copyWith({
    DictationPhase? phase,
    List<String>? committed,
    String? partial,
    Object? message = _unset,
  }) => DictationState(
    phase: phase ?? this.phase,
    committed: committed ?? this.committed,
    partial: partial ?? this.partial,
    message: message == _unset ? this.message : message as String?,
  );

  static const Object _unset = Object();

  @override
  String toString() =>
      'DictationState(${phase.name}, ${committed.length} utterances'
      '${partial.isEmpty ? '' : ', partial'})';
}

/// Drives one dictation.
class DictationController extends Notifier<DictationState> {
  MicCaptureSession? _session;
  StreamSubscription<SttTranscript>? _transcripts;

  /// Which capture attempt is current.
  ///
  /// **A `stop()` during [DictationPhase.starting] had nothing to stop — review
  /// finding R1-F1, and it is the half of R0-F1's fix that did not fire.**
  /// `_session` is assigned at the *end* of [start], after the recogniser has
  /// loaded (359–530ms, measured in Task 2.2), so a stop arriving during that load
  /// returned at its first line while the start went on to open the microphone
  /// anyway. What a technician got for typing while the recogniser loaded was a
  /// live microphone, a status line reading "Listening", and nothing they said
  /// reaching the field — verbatim the state [DiagnoseScreen]'s doc says stopping
  /// exists to prevent.
  ///
  /// The counter is the cancellation edge a `Future` chain does not otherwise
  /// have: [stop] bumps it, and [start] re-reads it after every `await`. A start
  /// that finds it changed abandons its work, closing anything it opened in the
  /// meantime — the microphone is a real resource, so "abandon" has to mean
  /// released rather than forgotten.
  ///
  /// **"Abandons its work" includes not repainting the screen**, which it did not
  /// when this sentence was first written: three of [start]'s exits reported a
  /// failure before reaching the next check. The guard now sits inside
  /// [_unavailable], so it covers every exit rather than the ones someone
  /// remembered (review finding R2-F1).
  int _generation = 0;

  /// Completes when the transcript stream has finished — normally or by error.
  ///
  /// **Not `StreamSubscription.asFuture`, and the difference is not stylistic:**
  /// `asFuture` installs its own `onDone` handler, replacing the one [_listen]
  /// registered. Using it would silently disable the handler that puts the phase
  /// back to [DictationPhase.idle], so a finished dictation would sit on screen
  /// saying it was still listening.
  Completer<void>? _closed;

  @override
  DictationState build() {
    // The subscription and the microphone outlive a rebuild of this notifier
    // otherwise — a provider container disposed mid-capture would leave the input
    // open and the isolate holding a session. `onDispose` is what makes tearing
    // down the graph a complete teardown.
    ref.onDispose(() {
      unawaited(_teardown());
    });
    return const DictationState();
  }

  /// Opens the microphone and starts transcribing.
  ///
  /// Every refusal below is a *state*, not a throw, on `MicCaptureStart`'s own
  /// reasoning: a denied permission and an absent model are things the screen has
  /// to draw, and drawing them from two different control-flow shapes is how one
  /// of them ends up undrawn.
  Future<void> start() async {
    if (state.isActive) return;
    // A fresh line per capture. The *previous* text is kept on the screen rather
    // than here — the inquiry field already holds it, and re-appending it here
    // would double it.
    final generation = ++_generation;
    state = const DictationState(phase: DictationPhase.starting);

    final SttEngine? engine;
    try {
      engine = await ref.read(dictationEngineProvider.future);
    } on Exception catch (error) {
      _unavailable(
        generation,
        'Speech recognition could not be prepared: $error',
      );
      return;
    }
    if (engine == null) {
      _unavailable(
        generation,
        'No verified speech model is installed on this device, so dictation '
        'is unavailable. Type the inquiry instead.',
      );
      return;
    }
    if (!ref.mounted || _generation != generation) return;

    try {
      // Idempotent, and awaited here rather than at provider resolution: this is
      // the deliberate action `deviceSttEngineProvider` defers the load to. **This
      // is the await R1-F1 lived under** — it is the long one, and until the check
      // below a `stop()` inside it was a no-op.
      await engine.initialize();
    } on Exception catch (error) {
      _unavailable(generation, 'The speech model could not be loaded: $error');
      return;
    }
    if (!ref.mounted || _generation != generation) return;

    final outcome = await ref.read(micCaptureProvider).start();
    // The graph went away, or a stop landed, while the platform was answering.
    // Whatever was opened has to be closed either way, or the microphone stays
    // live with nobody reading it.
    if (!ref.mounted || _generation != generation) {
      if (outcome is MicCaptureStarted) unawaited(outcome.session.stop());
      return;
    }

    switch (outcome) {
      case MicPermissionDenied():
        _unavailable(
          generation,
          'FieldOps Copilot has no microphone access. Grant it in Settings to '
          'dictate.',
        );
      case MicCaptureBusy():
        // Reachable only if something else holds the capture — this controller's
        // own re-entry is refused at the top. Reported rather than swallowed,
        // because a mic button that silently does nothing is indistinguishable
        // from one that is broken.
        _unavailable(generation, 'The microphone is already in use.');
      case MicCaptureUnavailable(:final message):
        _unavailable(
          generation,
          'The microphone could not be opened: $message',
        );
      case MicCaptureStarted(:final session):
        _session = session;
        _listen(engine, session);
        state = state.copyWith(phase: DictationPhase.listening);
    }
  }

  void _listen(SttEngine engine, MicCaptureSession session) {
    // `transcribe` consumes `frames` to completion, and closing them is what
    // produces the final transcript — so `stop()` on the session, not `cancel()`
    // here, is how a dictation is meant to end.
    final closed = Completer<void>();
    _closed = closed;
    _transcripts = engine
        .transcribe(session.frames)
        .listen(
          _onTranscript,
          onError: _onError,
          onDone: () {
            if (!closed.isCompleted) closed.complete();
            if (!ref.mounted) return;
            // Whatever was heard stays on screen; only the phase changes.
            if (state.phase == DictationPhase.listening) {
              state = state.copyWith(phase: DictationPhase.idle);
            }
          },
          // A fault arrives *after* the audio it interrupted (Task 2.1's
          // ordering), and `_onError` closes the run itself, so there is nothing
          // for `cancelOnError` to do except race it.
          cancelOnError: false,
        );
  }

  void _onTranscript(SttTranscript transcript) {
    if (!ref.mounted) return;
    if (!transcript.isFinal) {
      state = state.copyWith(partial: transcript.text);
      return;
    }
    // A final closes its segment. Indexed rather than appended, because the
    // recogniser is entitled to re-emit a final for a segment it has already
    // closed and appending would then say the sentence twice.
    final committed = [...state.committed];
    while (committed.length <= transcript.segment) {
      committed.add('');
    }
    committed[transcript.segment] = transcript.text;
    state = state.copyWith(committed: committed, partial: '');
  }

  void _onError(Object error, StackTrace stackTrace) {
    debugPrint('[Dictation] capture failed: $error\n$stackTrace');
    final closed = _closed;
    if (closed != null && !closed.isCompleted) closed.complete();
    if (!ref.mounted) return;
    // The partial is dropped and the finals are kept: a partial is the
    // recogniser's guess at an utterance it never finished hearing, and a capture
    // that died mid-word should not leave half a word in the inquiry.
    state = state.copyWith(
      phase: DictationPhase.failed,
      partial: '',
      message: error is MicCaptureFault
          ? error.message
          : 'Dictation stopped: $error',
    );
    unawaited(_teardown());
  }

  /// Closes the microphone and lets the last utterance finish.
  ///
  /// Awaits the transcript stream rather than only the session, because the final
  /// transcript arrives *after* the frames close — returning at the session's stop
  /// would hand a caller a state that is one utterance short of what was said.
  Future<void> stop() async {
    // **Bumped before anything else, so a start still in flight abandons itself**
    // — R1-F1. Unconditional: a bump with no start running costs nothing, and
    // making it conditional would need exactly the "is a start in flight" state
    // this counter *is*.
    _generation++;
    final session = _session;
    if (session == null) {
      // A start that has not reached its session yet. The bump above is the whole
      // stop; what is left is the phase, which would otherwise sit on `starting`
      // for a capture that is never going to open.
      if (state.isActive) {
        state = state.copyWith(phase: DictationPhase.idle);
      }
      return;
    }
    await session.stop();
    // Closing the frames is what makes the engine flush, and the flush is where
    // the last utterance comes from — so the wait is on the transcript stream
    // ending, not on the microphone being handed back.
    await _closed?.future;
    _session = null;
    _closed = null;
    await _transcripts?.cancel();
    _transcripts = null;
  }

  /// Clears the transcript without touching the microphone.
  void clear() {
    if (state.isActive) return;
    state = const DictationState();
  }

  /// Reports why this capture cannot run — **unless it is no longer the current
  /// one.**
  ///
  /// The generation check lives here rather than at each call site, which is review
  /// finding **R2-F1**. R1-F1 added the counter and read it after each `await` on
  /// the way *forward*; three of [start]'s six exits report a failure and return
  /// *before* the next such check, so a cancelled start still repainted the screen.
  /// The reachable one is a fresh install with no STT set: tap the mic, type while
  /// `dictationEngineProvider` resolves (it awaits a status provider that hashes
  /// files, so the window is real), watch the status row go — and then a red
  /// "dictation is unavailable" line appears under an idle microphone, about a
  /// capture that no longer exists. The message was true and about nothing.
  ///
  /// Guarding the **single write** rather than the six exits is the move this
  /// project keeps arriving at: an enumeration of call sites is a list to keep
  /// complete, and this is one question asked once. The forward checks after the
  /// awaits stay, because they stop the microphone being *opened* rather than a
  /// state being written, which is a different thing to prevent.
  void _unavailable(int generation, String message) {
    if (!ref.mounted || _generation != generation) return;
    state = DictationState(phase: DictationPhase.unavailable, message: message);
  }

  Future<void> _teardown() async {
    final session = _session;
    _session = null;
    final transcripts = _transcripts;
    _transcripts = null;
    _closed = null;
    // The session first: cancelling the transcript subscription releases the
    // recogniser's session, and doing that while the microphone is still pushing
    // frames leaves the pump writing into a controller nobody reads.
    await session?.stop();
    await transcripts?.cancel();
  }
}

/// The one dictation the demo screen drives.
final dictationControllerProvider =
    NotifierProvider<DictationController, DictationState>(
      DictationController.new,
    );
