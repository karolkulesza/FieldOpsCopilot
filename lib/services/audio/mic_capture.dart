import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

import 'pcm_audio_format.dart';

/// One buffer of captured audio, plus what was lost immediately before it.
///
/// [precedingGapBytes] is why this is a class and not a bare `Uint8List`. The
/// capture backlog is bounded (see [MicCapture.maxBacklogBytes]), so a consumer
/// that stalls loses audio — and audio lost *silently* is the worst outcome
/// available here: a streaming recogniser fed a spliced stream returns a fluent,
/// well-formed transcript of a sentence nobody said. Attaching the gap to the
/// frame that follows it puts the fact in the consumer's hands at the moment it
/// becomes relevant, rather than in a counter someone has to remember to read.
class MicFrame {
  const MicFrame({required this.bytes, this.precedingGapBytes = 0});

  /// Signed 16-bit little-endian samples, a whole number of frames (see
  /// [PcmAudioFormat.bytesPerFrame]). Never empty.
  final Uint8List bytes;

  /// Bytes of audio dropped between the previous [MicFrame] and this one, or 0
  /// when the stream is continuous.
  final int precedingGapBytes;

  /// Whether audio was lost immediately before this frame.
  bool get followsGap => precedingGapBytes > 0;

  @override
  String toString() => 'MicFrame(${bytes.length}B, gap: ${precedingGapBytes}B)';
}

/// The microphone stopped being usable part-way through a capture.
///
/// Delivered as an error on [MicCaptureSession.frames] rather than thrown from a
/// method, because that is where a consumer is already listening — and because it
/// arrives after whatever audio was already captured, so a partial utterance is
/// still transcribable.
class MicCaptureFault implements Exception {
  const MicCaptureFault(this.message);

  final String message;

  @override
  String toString() => 'MicCaptureFault: $message';
}

/// The bits of a recorder plugin this app uses, as an interface.
///
/// A seam of the same kind as `ModelDownloader`: the whole of [MicCapture] — the
/// permission gate, frame normalisation, the backlog bound, the lifecycle — runs
/// against a scripted implementation in host tests, so a device is needed only
/// for the one thing a device is actually required for (that real hardware
/// delivers real PCM). It is also what keeps `package:record` a replaceable
/// detail: the plugin is imported by exactly one class below.
abstract interface class AudioInput {
  /// Whether the app may record, requesting the permission when [request] is set.
  Future<bool> hasPermission({bool request = true});

  /// Opens the microphone and returns raw buffers in [format].
  ///
  /// Implementations must reject a format they cannot deliver rather than
  /// substitute one, and may throw to report that.
  Future<Stream<Uint8List>> startStream(PcmAudioFormat format);

  /// Registers [onCoerced] to be called if the platform captures in a format
  /// other than the one [startStream] requested, with a human-readable
  /// description of the difference.
  ///
  /// Implementations must call it only for a difference that changes how the
  /// bytes decode — not for an unrelated field the platform also adjusted.
  Future<void> watchFormat(void Function(String description) onCoerced);

  /// Closes the microphone. Must tolerate being called when nothing is open.
  Future<void> stop();

  /// Releases the underlying recorder.
  Future<void> dispose();
}

/// The outcome of asking [MicCapture] to start.
///
/// Sealed rather than "a session or an exception" for the reason Task 1.5
/// established for tool calls: a denied permission and a busy microphone are
/// ordinary runtime states the UI has to render, not programming errors. Only
/// [MicCaptureUnavailable] describes something going wrong, and it too is a value
/// — the caller that has to draw a message either way should not have to draw it
/// from two different control-flow shapes.
sealed class MicCaptureStart {
  const MicCaptureStart();
}

/// The microphone is open and [session] is producing audio.
final class MicCaptureStarted extends MicCaptureStart {
  const MicCaptureStarted(this.session);

  final MicCaptureSession session;
}

/// The user has not granted microphone access.
final class MicPermissionDenied extends MicCaptureStart {
  const MicPermissionDenied();
}

/// A capture is already running on this [MicCapture].
///
/// A distinct outcome rather than a silent restart, and the reason is in the
/// plugin: `AudioRecorder.startStream` closes the previous record stream before
/// opening a new one (read in `record` 7.1.1, `_StreamMixin._stopRecordStream`).
/// So a second start would end the first consumer's stream *without an error* —
/// a transcript that simply stops mid-sentence, with nothing to point at.
final class MicCaptureBusy extends MicCaptureStart {
  const MicCaptureBusy();
}

/// The microphone could not be opened, for a reason that is not permission.
///
/// A missing platform usage declaration, an input the OS refused, a format the
/// hardware cannot deliver.
final class MicCaptureUnavailable extends MicCaptureStart {
  const MicCaptureUnavailable(this.message);

  final String message;
}

/// A live microphone capture.
///
/// Obtain one from [MicCapture.start]; end it with [stop]. The instance is not
/// reusable — a stopped session stays stopped and [MicCapture.start] issues a new
/// one.
class MicCaptureSession {
  MicCaptureSession._({
    required this.format,
    required this._maxBacklogBytes,
    required this._stallTimeout,
    required this._releaseInput,
  }) {
    _controller = StreamController<MicFrame>(onListen: _pump, onResume: _pump);
  }

  /// The format every frame on [frames] is in.
  final PcmAudioFormat format;

  final int _maxBacklogBytes;
  final Duration? _stallTimeout;
  final Future<void> Function() _releaseInput;

  /// The stall timeout this session is actually running with.
  ///
  /// Exists so a test can bind [MicCapture]'s *default* reaching the session
  /// without waiting out five seconds of wall clock. Round 2 of review measured
  /// the alternative — a test that waits the real default — and found its marginal
  /// mutation coverage to be **zero**: the value assertion on
  /// [MicCapture.stallTimeout] and the millisecond-scale watchdog tests already
  /// kill every edit either party constructed, including one that breaks this
  /// plumbing while leaving the public field reading correctly. This accessor
  /// binds that last edge directly and costs nothing.
  @visibleForTesting
  Duration? get configuredStallTimeout => _stallTimeout;

  late final StreamController<MicFrame> _controller;
  final Queue<Uint8List> _backlog = Queue<Uint8List>();
  int _backlogBytes = 0;

  /// A partial frame held back from the previous buffer. At most
  /// `bytesPerFrame - 1` bytes: whole frames are always taken out.
  Uint8List? _carry;

  int _droppedByteCount = 0;
  int _pendingGapBytes = 0;

  StreamSubscription<Uint8List>? _rawSubscription;
  MicCaptureFault? _pendingFault;

  /// Set as soon as [stop] is called, which is *before* the input is released.
  ///
  /// Distinct from [_finishing] because the window between the two is exactly
  /// where the plugin's already-queued buffers arrive: they must still be
  /// accepted, while a stream `done` in that window must not be read as a fault.
  bool _stopRequested = false;

  /// Set once the terminal path has begun.
  ///
  /// What actually stops buffers being accepted is the `_rawSubscription.cancel()`
  /// that every path setting this flag performs in the same synchronous block — not
  /// the flag. The guard in [_onRawBuffer] that reads it is therefore
  /// belt-and-braces and unreachable today (review finding R0-F6); it is kept
  /// because an `await` introduced between the flag and the cancel would make it
  /// load-bearing again, and it costs one comparison.
  bool _finishing = false;
  bool _closed = false;

  final Completer<void> _releaseCompleter = Completer<void>();
  final Completer<void> _rawClosed = Completer<void>();

  /// Fires when no buffer has arrived for [_stallTimeout]; `null` when disabled.
  Timer? _stallTimer;

  /// How long [stop] waits for the plugin to close its stream before giving up on
  /// the drain.
  ///
  /// Bounded rather than open-ended on the principle Task 1.11 arrived at the
  /// hard way: a seam that hangs reports nothing, and a frozen UI reads as a
  /// crash. A quarter-second is far longer than the close takes when it happens
  /// at all — it is already in flight when the release completes — and short
  /// enough that a plugin which never closes costs a perceptible pause rather
  /// than the app.
  static const drainGrace = Duration(milliseconds: 250);

  /// Completes when the microphone has actually been handed back, which is later
  /// than [isCapturing] going false.
  ///
  /// [MicCapture.start] waits on it before opening a new capture: the two would
  /// otherwise overlap on the same recorder, and the plugin's own answer to that
  /// is to close the older stream silently — the outcome [MicCaptureBusy] exists
  /// to prevent.
  Future<void> get released => _releaseCompleter.future;

  /// The captured audio.
  ///
  /// Single-subscription. Buffers up to the backlog bound while nothing is
  /// listening, so audio captured between [MicCapture.start] and the first
  /// `listen` is not lost — which is *not* true of the plugin's own stream, a
  /// broadcast controller that discards every buffer arriving without a listener
  /// (read in `record` 7.1.1, `_StreamMixin._startRecordStream`).
  ///
  /// Closes when [stop] completes the drain, or after a [MicCaptureFault].
  Stream<MicFrame> get frames => _controller.stream;

  /// Total audio dropped to keep the backlog inside its bound, in bytes.
  ///
  /// Monotonic. The same information reaches a consumer of [frames] as
  /// [MicFrame.precedingGapBytes]; this is the running total, for a UI that wants
  /// to say how bad it got.
  int get droppedByteCount => _droppedByteCount;

  /// Whether audio is still being captured.
  ///
  /// Goes false the moment [stop] is *asked for*, not when it finishes: from that
  /// point on this session will accept no new audio, only drain what the plugin
  /// had already queued. Callers waiting for the microphone itself to come back
  /// want [released].
  bool get isCapturing => !_stopRequested && !_closed;

  /// Closes the microphone and lets [frames] drain, then close.
  ///
  /// Idempotent, and safe to call from a `frames` listener. Completes once the
  /// input is released — not once the stream has drained, which cannot be
  /// promised to a caller who may itself be the thing draining it.
  ///
  /// **The release happens before the subscription is cancelled, and that order
  /// is the whole point.** Buffers the plugin has already handed to its stream
  /// but not yet dispatched are lost the instant the subscription is cancelled,
  /// so cancelling first truncates the end of the utterance — the last word of
  /// "…and the brake is dragging", every time, with nothing to indicate it
  /// happened. Awaiting the release yields to the event loop, which is what lets
  /// those buffers land first.
  ///
  /// A failure releasing the input is rethrown, after [frames] has been closed
  /// out: the stream is finished either way, but "the microphone may still be
  /// open" is not something to swallow.
  Future<void> stop() async {
    if (_stopRequested) return released;
    _stopRequested = true;
    try {
      await _releaseInput();
      // Releasing the input closes the plugin's stream, and every buffer it had
      // already queued is delivered before that close. So waiting for the close
      // — rather than for the release future alone — is what makes the drain
      // complete instead of "however many event-loop turns the release happened
      // to take".
      await _rawClosed.future.timeout(drainGrace, onTimeout: () {});
    } finally {
      _finishing = true;
      // Hygiene, not mechanism (review finding R1-F5): `_onStalled` routes through
      // [_fail], which declines once `_stopRequested` is set, so a timer left
      // running would fire into a no-op and nothing observable would change.
      // Deleting this line leaves the host suite green. What it prevents is a
      // `Timer` outliving its session by up to `stallTimeout` — invisible here, and
      // *not* invisible in a widget test, where `flutter_test` fails a test that
      // ends with a pending timer. A widget is where Task 2.3 puts this.
      _stallTimer?.cancel();
      _stallTimer = null;
      await _rawSubscription?.cancel();
      _rawSubscription = null;
      // Hygiene, not the mechanism: nothing reads the carry after the cancel
      // above, so deleting this line changes no behaviour (review finding R0-F6).
      // The decision it used to claim — that a partial frame is dropped rather than
      // padded into samples the technician did not speak — is implemented by the
      // *absence* of a flush here, which no line can express.
      _carry = null;
      if (!_releaseCompleter.isCompleted) _releaseCompleter.complete();
      _pump();
    }
  }

  void _attach(Stream<Uint8List> raw) {
    _armStallTimer();
    _rawSubscription = raw.listen(
      _onRawBuffer,
      onError: (Object error, StackTrace stackTrace) =>
          _fail(MicCaptureFault('the microphone reported an error: $error')),
      onDone: () {
        // Completing this is what makes [stop] prompt rather than always paying the
        // full [drainGrace]; bound by *stop is prompt when the plugin closes its
        // stream*. Deleting it left every other test green and added 250ms to every
        // utterance (review finding R0-F5).
        if (!_rawClosed.isCompleted) _rawClosed.complete();
        // A `done` arriving during [stop] is the expected end, not a fault:
        // releasing the input closes the plugin's stream (`record` 7.1.1,
        // `AudioRecorder.stop` → `_stopRecordStream`). [_fail] already declines
        // once a stop is under way, so that case needs no branch here — a second
        // guard for it would be a line no test could reach.
        //
        // **A `done` at any other time cannot come from `record` 7.1.1.** An earlier
        // version of this comment named three causes for it — a revoked permission,
        // a route change, another app taking the input — and the plugin's source
        // refutes all three (review finding R0-F1). `_startRecordStream` subscribes
        // to the platform stream with `onData` and `onError` and **no `onDone`**,
        // and neither native side ever ends its event channel (`endOfStream` and
        // `FlutterEndOfEventStream` appear nowhere in `record_ios` 2.1.1 or
        // `record_android` 2.1.2), so the broadcast controller this listens to is
        // closed only by `_stopRecordStream` — by `stop`, `cancel`, `dispose`, or a
        // second `startStream`. The three causes go elsewhere: on Android a read
        // failure arrives as an **error**, handled above; on iOS an audio-session
        // interruption pauses the engine and never resumes it, which is silence
        // rather than an end and is what [MicCapture.stallTimeout] exists for.
        //
        // So this is defence against a future plugin version and against any other
        // [AudioInput] implementation — the seam's contract says a stream that ends
        // by itself is a fault, and this is where that contract is kept. It is
        // deliberately no longer described as a live path.
        _fail(
          const MicCaptureFault(
            'the microphone closed the stream unexpectedly',
          ),
        );
      },
    );
  }

  /// Restarts the stall watchdog. Every arriving buffer is proof of life.
  void _armStallTimer() {
    final timeout = _stallTimeout;
    if (timeout == null) return;
    _stallTimer?.cancel();
    _stallTimer = Timer(timeout, _onStalled);
  }

  void _onStalled() {
    _fail(
      MicCaptureFault(
        'the microphone delivered no audio for '
        '${_stallTimeout!.inMilliseconds}ms — the input was most likely taken by '
        'the system (a call, a voice assistant, another app) and will not come '
        'back on its own',
      ),
    );
  }

  /// Turns one platform buffer into zero or more whole-frame [MicFrame]s.
  void _onRawBuffer(Uint8List raw) {
    if (_finishing) return;
    // Re-armed before the empty-buffer and partial-frame checks below,
    // deliberately: a buffer carrying no whole frame is still evidence the input
    // is alive, and iOS does emit those.
    _armStallTimer();

    final carry = _carry;
    final Uint8List merged;
    if (carry == null || carry.isEmpty) {
      merged = raw;
    } else {
      merged = Uint8List(carry.length + raw.length)
        ..setRange(0, carry.length, carry)
        ..setRange(carry.length, carry.length + raw.length, raw);
    }

    // A buffer cut anywhere but a frame boundary splits a sample, and every
    // sample after the splice decodes from the wrong two bytes — silence turns
    // into full-scale noise, and on a stereo stream the channels swap as well.
    // Both plugin paths read at these versions emit whole frames (iOS composes
    // each `Data` from `frameLength * channels` samples in `Pcm16BitsEncoder`;
    // Android reads into a `ShortArray` and returns `readResult * 2` bytes in
    // `PCMReader`), so this carry is expected to stay empty on both. It is here
    // because the cost is one field and the failure it prevents is inaudible in
    // a test and catastrophic in a transcript.
    final wholeBytes =
        merged.length - merged.length.remainder(format.bytesPerFrame);
    if (wholeBytes == 0) {
      // Includes an empty buffer, which **iOS** can produce: `Pcm16BitsEncoder`
      // returns `[bytes]` with `bytes` empty when the converted buffer has no
      // frames, and `handleTap` sends every element. Android cannot — review
      // finding R0-F8.3 refuted that half of an earlier comment, because
      // `RecordThread` guards `if (buffer.isNotEmpty()) encoder.encode(buffer)`, so
      // a zero-length read never reaches the sink.
      _carry = merged.isEmpty ? null : merged;
      return;
    }
    _carry = wholeBytes == merged.length
        ? null
        : Uint8List.sublistView(merged, wholeBytes);
    _enqueue(Uint8List.sublistView(merged, 0, wholeBytes));
  }

  void _enqueue(Uint8List bytes) {
    _backlog.add(bytes);
    _backlogBytes += bytes.length;
    // Drop the oldest audio, never the newest: a live recogniser that falls
    // behind should come back at the current moment with a gap behind it, not
    // keep accumulating lag it can never pay off. `length > 1` keeps the buffer
    // just added, so a bound smaller than one platform buffer degrades to
    // latest-only rather than to nothing.
    while (_backlogBytes > _maxBacklogBytes && _backlog.length > 1) {
      final dropped = _backlog.removeFirst();
      _backlogBytes -= dropped.length;
      _droppedByteCount += dropped.length;
      _pendingGapBytes += dropped.length;
    }
    _pump();
  }

  void _pump() {
    // Delivery is driven entirely by the consumer being ready — which, after the
    // last buffer has arrived, means it is driven by `onListen` and `onResume`.
    // Nothing forces events past a pause, deliberately: a paused subscription's
    // own buffer is unbounded, so pushing into it would launder the very
    // ceiling the backlog exists to impose, and it would step over the
    // backpressure signal the consumer just gave.
    //
    // An earlier version added `_finishing ||` here so that `stop` drained the
    // queue whatever the consumer was doing. It made no observable difference —
    // a consumer that never resumes never observes anything either way — and it
    // cost something real: draining unconditionally left the backlog always
    // empty at the closing guard below, so the `_backlog.isNotEmpty` clause
    // there could not fail, and a mutation deleting it survived the suite. Two
    // clauses overlapping is how a guard stops being checked.
    while (_backlog.isNotEmpty &&
        _controller.hasListener &&
        !_controller.isPaused) {
      final bytes = _backlog.removeFirst();
      _backlogBytes -= bytes.length;
      final gap = _pendingGapBytes;
      _pendingGapBytes = 0;
      _controller.add(MicFrame(bytes: bytes, precedingGapBytes: gap));
    }

    // `|| _closed` is belt-and-braces: no path calls `_pump` after the close, so
    // deleting it changes no behaviour (review finding R0-F6). Kept because it
    // makes double-closing impossible by construction rather than by tracing every
    // caller.
    if (!_finishing || _backlog.isNotEmpty || _closed) return;
    _closed = true;
    final fault = _pendingFault;
    // The fault goes out *after* the audio, so a consumer sees the utterance it
    // did capture and then why it ended.
    if (fault != null) _controller.addError(fault);
    _controller.close();
  }

  void _fail(MicCaptureFault fault) {
    if (_stopRequested || _finishing) return;
    _pendingFault = fault;
    _stopRequested = true;
    _finishing = true;
    // Hygiene, for the reason given in [stop]: this cannot change an outcome, only
    // whether a `Timer` outlives the session (review finding R1-F5).
    _stallTimer?.cancel();
    _stallTimer = null;
    _rawSubscription?.cancel();
    _rawSubscription = null;
    _carry = null;
    // Synchronous by necessity — this runs from a stream callback — so the
    // teardown is a detached future. Its failure is swallowed rather than left to
    // become an unhandled async error: the consumer is about to be told the
    // capture is over by [_pendingFault], which is the actionable half, and an
    // uncaught error here would instead crash whatever zone the callback ran in.
    unawaited(
      _releaseInput().onError<Object>((_, _) {}).whenComplete(() {
        if (!_releaseCompleter.isCompleted) _releaseCompleter.complete();
        _pump();
      }),
    );
  }
}

/// Opens the microphone and delivers 16-bit PCM to the STT path.
///
/// One responsibility split three ways, and none of them is "record audio" —
/// that is the plugin's job, behind [AudioInput]. What this owns is everything
/// between the plugin and a recogniser:
///
/// * **the permission gate**, so nothing calls into the recorder before the user
///   has agreed and a denial is a value rather than a platform exception;
/// * **frame normalisation** — no empty buffers, no split samples;
/// * **a bounded backlog**, because the plugin's stream has no backpressure at
///   all. It is a broadcast controller fed from a platform callback (read in
///   `record` 7.1.1, `_StreamMixin`), so a subscriber that pauses buffers audio
///   in its subscription with no ceiling. In an app whose measured RSS already
///   reaches 1.67GB with the LLM resident (Task 1.8), unbounded audio behind a
///   stalled recogniser is an out-of-memory kill; a bound plus a visible gap is
///   a degraded transcript.
class MicCapture {
  MicCapture({
    required this._input,
    this.format = PcmAudioFormat.sttMono16k,
    Duration maxBacklog = const Duration(seconds: 2),
    this.stallTimeout = const Duration(seconds: 5),
  }) : maxBacklogBytes = format.byteCountFor(maxBacklog),
       assert(!maxBacklog.isNegative, 'maxBacklog cannot be negative'),
       assert(
         stallTimeout == null || stallTimeout > Duration.zero,
         'stallTimeout must be positive, or null to disable',
       );

  final AudioInput _input;

  /// The format the microphone is asked for, and the one every [MicFrame] is in.
  final PcmAudioFormat format;

  /// How much captured audio may wait for a slow consumer before the oldest is
  /// dropped.
  ///
  /// Two seconds by default: long enough to cover a garbage-collection pause or
  /// a thermal hiccup in the recogniser, short enough that the technician is
  /// never watching a transcript run seconds behind their own voice.
  final int maxBacklogBytes;

  /// How long the microphone may deliver *nothing* before the capture is faulted.
  /// `null` disables the check.
  ///
  /// **This is the only "the microphone went away" condition either real platform
  /// produces, and it took review findings R0-F1/R0-F2 to establish that.** The
  /// obvious candidate does not happen: `record` 7.1.1 registers no `onDone` on the
  /// platform stream and neither native side ever ends its event channel, so a
  /// stream closing by itself is not a thing. What *does* happen, on iOS, is
  /// silence — an audio-session interruption (a call, a voice assistant, another app
  /// claiming the input) reaches `RecorderSessionExtension`, which under `record`'s
  /// default `AudioInterruptionMode.pause` pauses the engine and **never resumes
  /// it**. The tap stays installed and buffers simply stop arriving.
  ///
  /// Without this timer that state is invisible and terminal: the session sits
  /// `isCapturing`, `frames` stays open, and `SttEngine.transcribe` consumes
  /// `frames` to completion — so it can never emit a final transcript. The app waits
  /// forever on a microphone that is not coming back, which on the demo device is
  /// the most likely way voice capture fails.
  ///
  /// Five seconds because *any* live input produces buffers continuously — a quiet
  /// room is a stream of near-zero samples, not an absence of buffers — so silence
  /// this long is not a pause in speech, it is a dead input. Long enough that no
  /// plausible scheduling hiccup trips it; short enough that a technician is not
  /// left watching a dictation that will never finish.
  final Duration? stallTimeout;

  MicCaptureSession? _session;

  /// The running capture, or `null`.
  MicCaptureSession? get session {
    final session = _session;
    return session != null && session.isCapturing ? session : null;
  }

  /// Requests permission if needed, opens the microphone, and returns a session.
  Future<MicCaptureStart> start() async {
    final previous = _session;
    if (previous != null) {
      if (previous.isCapturing) return const MicCaptureBusy();
      // Stopped, but the recorder may not be back yet. Opening a second stream
      // over a half-released one is exactly the overlap [MicCaptureBusy] guards
      // against, so wait rather than race it.
      await previous.released;
    }

    final bool granted;
    try {
      granted = await _input.hasPermission();
    } on Exception catch (error) {
      // A *failure* to ask is not a refusal. The one that actually happens is a
      // missing platform usage declaration, and telling an operator "permission
      // denied" sends them to Settings for a toggle that is not there.
      return MicCaptureUnavailable(
        'could not determine microphone permission: $error',
      );
    }
    if (!granted) return const MicPermissionDenied();

    final session = MicCaptureSession._(
      format: format,
      maxBacklogBytes: maxBacklogBytes,
      stallTimeout: stallTimeout,
      releaseInput: _input.stop,
    );

    try {
      // **Before `startStream`, and that order is load-bearing** (raised in review
      // round 0): on Android `notifyConfigChanged` fires immediately after the
      // platform call `startStream` awaits resolves, so a watcher registered
      // afterwards can miss the only notification there will be.
      await _input.watchFormat(
        (description) => session._fail(
          MicCaptureFault(
            'the microphone is not capturing in the requested format '
            '($description) — 16-bit PCM at the wrong rate transcribes as '
            'nonsense rather than failing, so the capture is stopped instead',
          ),
        ),
      );
      final raw = await _input.startStream(format);
      session._attach(raw);
    } on Exception catch (error) {
      // The input may already be open — `watchFormat` can succeed and `startStream`
      // fail after the platform has taken the microphone — and a caller told
      // "unavailable" holds no session to stop with. Without this the recorder stays
      // open until `dispose`. Raised as a non-blocking note in review round 0.
      try {
        await _input.stop();
      } on Exception catch (_) {
        // Already closed, or never opened. What the caller needs is the failure
        // below, not a second one from the cleanup.
      }
      return MicCaptureUnavailable('could not open the microphone: $error');
    }

    _session = session;
    return MicCaptureStarted(session);
  }

  /// Stops any running capture and releases the recorder.
  Future<void> dispose() async {
    await _session?.stop();
    _session = null;
    await _input.dispose();
  }
}

/// [AudioInput] over `package:record`.
///
/// The only file in the app that imports the plugin.
///
/// Configuration is four fields wide and every one of them is deliberate — three
/// set and one deliberately left at its default:
///
/// * `encoder: AudioEncoder.pcm16bits` — the only raw encoder either platform
///   accepts in streaming mode. `RecordConfig`'s default is `aacLc`, which
///   streams *encoded* frames; handing those to a PCM recogniser produces noise.
/// * `sampleRate` / `numChannels` from [PcmAudioFormat] — the defaults are
///   44100 Hz stereo, neither of which the STT model wants.
/// * `audioInterruption` is left at `RecordConfig`'s default of
///   `AudioInterruptionMode.pause`, and **that default is what makes an
///   interruption permanent** — which review finding R1-F6 established, because an
///   earlier version of this list said the configuration was "three fields wide"
///   while a fourth was quietly load-bearing. Both platforms gate resuming on
///   `pauseResume`: iOS returns from its `.ended` handler unless
///   `audioInterruption == pauseResume` *and* the notification carries
///   `.shouldResume` (`RecorderSessionExtension.onAudioSessionInterruption`), and
///   Android resumes on focus gain only
///   `if (interruption == AudioInterruption.PAUSE_RESUME)`
///   (`AudioRecorder`'s `onFocusGain`). So the silence
///   [MicCapture.stallTimeout] detects is a consequence of this default, not a
///   platform fact.
///
///   It stays `pause`, and the reason is stronger than the platform behaviour it is
///   sometimes justified by — the argument is the reviewer's, in round 1. An
///   auto-resume would restart the tap mid-utterance and **splice the stream with a
///   gap this class cannot see**: the missing audio never enters the backlog, so
///   nothing increments `precedingGapBytes`, and the recogniser receives a
///   continuous-looking stream across a hole. That is precisely the invisible splice
///   [MicFrame] exists to make impossible, arriving through the one route the gap
///   accounting cannot cover. A capture that stops and says so is strictly better
///   than one that resumes and lies.
/// * `streamBufferSize` is left unset **on purpose**. The field's unit differs
///   between the platforms: `record_ios` 2.1.1 passes it to
///   `AVAudioNode.installTap` as `AVAudioFrameCount` (sample *frames*, defaulting
///   to 1024), while `record_android` 2.1.2 passes it to `AudioRecord` as
///   `bufferSizeInBytes`. One number cannot mean both, so each platform keeps its
///   own default rather than this app picking a figure that is right on one of
///   them.
///
/// Noise suppression is *not* requested, and not because it would be unwelcome —
/// the spec asks for it. It is because on the demo platform it would be
/// decoration: `record_ios` 2.1.1 parses `noiseSuppress` into its `RecordConfig`
/// and never reads it again — the stream delegate applies only `echoCancel` and
/// `autoGain`, via `setVoiceProcessingEnabled`. (`record_android` 2.1.2 does honour
/// it, through `AudioEffectsManager`.) Ambient-noise filtering stays where the
/// sprint plan puts it, in the narrated appendix, rather than becoming a flag that
/// looks like a feature on the device this is demoed from.
class RecordAudioInput implements AudioInput {
  RecordAudioInput({AudioRecorder? recorder})
    : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;

  @override
  Future<bool> hasPermission({bool request = true}) =>
      _recorder.hasPermission(request: request);

  @override
  Future<Stream<Uint8List>> startStream(PcmAudioFormat format) {
    _requestedFormat = format;
    return _recorder.startStream(
      RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: format.sampleRate,
        numChannels: format.numChannels,
      ),
    );
  }

  @override
  Future<void> watchFormat(void Function(String description) onCoerced) =>
      _recorder.setOnConfigChanged((config) {
        final mismatch = describeFormatMismatch(
          requested: _requestedFormat,
          encoder: config.encoder,
          sampleRate: config.sampleRate,
          numChannels: config.numChannels,
        );
        if (mismatch != null) onCoerced(mismatch);
      });

  /// The format the last [startStream] asked for, remembered so the coercion
  /// callback has something to compare against.
  ///
  /// Seeded with the STT format so a callback arriving before any `startStream`
  /// compares against something meaningful rather than a null.
  PcmAudioFormat _requestedFormat = PcmAudioFormat.sttMono16k;

  @override
  Future<void> stop() async {
    await _recorder.stop();
  }

  @override
  Future<void> dispose() => _recorder.dispose();

  /// Whether a delivered recorder configuration still decodes as the requested
  /// PCM, and how it differs when it does not.
  ///
  /// Split out as a pure function because the callback that feeds it can only be
  /// triggered by a real platform, and the decision it makes is the part worth
  /// binding: the plugin fires `onConfigChanged` whenever *any* of bit rate,
  /// sample rate or channel count was adjusted (read in `record_ios` 2.1.1
  /// `RecordConfig.isModified` and `record_android` 2.1.2
  /// `RecordConfig.isModified`), and bit rate does not exist for a raw PCM
  /// stream — neither platform's PCM encoder reads it (`Pcm16BitsEncoder.setup` is
  /// empty; `PcmFormat.getMediaFormat` never sets `KEY_BIT_RATE`, and `syncConfig`
  /// copies it only `if (containsKey)`). Faulting a good capture because the
  /// platform normalised an unused field would be worse than not watching at all.
  ///
  /// **Which platform this is live on, corrected by review finding R0-F3.** An
  /// earlier version claimed neither stream path mutates the format, so the callback
  /// should never fire. True on iOS, whose stream delegate resamples to the
  /// requested format through `AVAudioConverter` and throws if it cannot, never
  /// rewriting the config. **False on Android:** `FormatCodecSelector.findCodec`
  /// calls `adjustToDeviceCapabilities(config)` *before* its `MIMETYPE_AUDIO_RAW`
  /// early return, and that assigns
  /// `config.numChannels = nearestValue(deviceChannelCounts, config.numChannels)`
  /// from the routed input's advertised channel counts. So on an Android device
  /// whose default input does not advertise mono, a mono request is silently coerced
  /// to stereo and this fires.
  ///
  /// The consequence is deliberate and worth stating: such a capture is **faulted,
  /// not degraded**. Interleaved stereo handed to a mono recogniser is not
  /// quiet-but-usable audio, it is every second sample from the wrong channel, and
  /// this app does not downmix. A named failure beats a transcript of nonsense.
  /// Downmixing is the obvious alternative and belongs with whoever owns the
  /// recogniser.
  @visibleForTesting
  static String? describeFormatMismatch({
    required PcmAudioFormat requested,
    required AudioEncoder encoder,
    required int sampleRate,
    required int numChannels,
  }) {
    final differences = <String>[
      if (encoder != AudioEncoder.pcm16bits) 'encoder ${encoder.name}',
      if (sampleRate != requested.sampleRate)
        '${sampleRate}Hz rather than ${requested.sampleRate}Hz',
      if (numChannels != requested.numChannels)
        '$numChannels channels rather than ${requested.numChannels}',
    ];
    return differences.isEmpty ? null : differences.join(', ');
  }
}
