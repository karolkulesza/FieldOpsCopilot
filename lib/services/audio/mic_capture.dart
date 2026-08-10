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
    required this._releaseInput,
  }) {
    _controller = StreamController<MicFrame>(onListen: _pump, onResume: _pump);
  }

  /// The format every frame on [frames] is in.
  final PcmAudioFormat format;

  final int _maxBacklogBytes;
  final Future<void> Function() _releaseInput;

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

  /// Set once no further buffer will be accepted.
  bool _finishing = false;
  bool _closed = false;

  final Completer<void> _releaseCompleter = Completer<void>();
  final Completer<void> _rawClosed = Completer<void>();

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
      await _rawSubscription?.cancel();
      _rawSubscription = null;
      // A partial frame is not a frame, and padding it would invent samples the
      // technician did not speak, so the carry is discarded rather than flushed.
      _carry = null;
      if (!_releaseCompleter.isCompleted) _releaseCompleter.complete();
      _pump();
    }
  }

  void _attach(Stream<Uint8List> raw) {
    _rawSubscription = raw.listen(
      _onRawBuffer,
      onError: (Object error, StackTrace stackTrace) =>
          _fail(MicCaptureFault('the microphone reported an error: $error')),
      onDone: () {
        if (!_rawClosed.isCompleted) _rawClosed.complete();
        // A `done` arriving during [stop] is the expected end, not a fault:
        // releasing the input closes the plugin's stream (`record` 7.1.1,
        // `AudioRecorder.stop` → `_stopRecordStream`). [_fail] already declines
        // once a stop is under way, so that case needs no branch here — a second
        // guard for it would be a line no test could reach.
        //
        // A `done` at any other time is the microphone going away mid-capture — a
        // revoked permission, a route change, another app taking the input — and
        // the alternative to reporting it is a transcript that simply stops.
        _fail(
          const MicCaptureFault(
            'the microphone closed the stream unexpectedly',
          ),
        );
      },
    );
  }

  /// Turns one platform buffer into zero or more whole-frame [MicFrame]s.
  void _onRawBuffer(Uint8List raw) {
    if (_finishing) return;

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
      // Includes the empty buffer both platforms can produce (iOS when a tap
      // buffer carries no frames; Android when `AudioRecord.read` returns 0).
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
    // While finishing, push into the controller's own buffer regardless of
    // pause: the backlog is bounded, and a consumer that resumes after `stop`
    // should still get the tail of the utterance.
    while (_backlog.isNotEmpty &&
        (_finishing || (_controller.hasListener && !_controller.isPaused))) {
      final bytes = _backlog.removeFirst();
      _backlogBytes -= bytes.length;
      final gap = _pendingGapBytes;
      _pendingGapBytes = 0;
      _controller.add(MicFrame(bytes: bytes, precedingGapBytes: gap));
    }

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
  }) : maxBacklogBytes = format.byteCountFor(maxBacklog),
       assert(!maxBacklog.isNegative, 'maxBacklog cannot be negative');

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
      releaseInput: _input.stop,
    );

    try {
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
/// Configuration is three fields wide and every one of them is deliberate:
///
/// * `encoder: AudioEncoder.pcm16bits` — the only raw encoder either platform
///   accepts in streaming mode. `RecordConfig`'s default is `aacLc`, which
///   streams *encoded* frames; handing those to a PCM recogniser produces noise.
/// * `sampleRate` / `numChannels` from [PcmAudioFormat] — the defaults are
///   44100 Hz stereo, neither of which the STT model wants.
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
  /// stream — neither platform's PCM encoder reads it. Faulting a good capture
  /// because the platform normalised an unused field would be worse than not
  /// watching at all.
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
