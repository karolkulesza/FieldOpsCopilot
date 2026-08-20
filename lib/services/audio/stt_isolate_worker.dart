/// Runs speech recognition on a dedicated background isolate.
///
/// **Why an isolate, and the case is stronger here than for the LLM.** The LLM's
/// isolate is insurance: LiteRT-LM already keeps its worst work off the caller, so
/// that boundary guarantees at *this app's* seam something the plugin happens to
/// do. Here there is nothing to insure. Every entry point of `sherpa_onnx`'s Dart
/// API is a synchronous FFI call that runs to completion on the calling thread —
/// the recogniser's *constructor* loads three ONNX graphs (359–530ms measured — see
/// `SherpaRecognizerRuntime.load` for the command and the run count), and `decode`
/// runs the network. On the UI isolate that is a
/// dropped frame per decode step, for the whole length of an utterance.
///
/// **The protocol is one request, one reply, and that is the flow control.** The
/// session does not send the next chunk of audio until the previous one is
/// answered, so no queue can build in front of a decoder that has fallen behind.
/// Back-pressure then propagates up through `await for` to the subscription on
/// `MicCaptureSession.frames`, whose pump is already pause-aware, and the mic's
/// bounded backlog does what it was built to do: drop oldest and report the gap.
/// The gap arrives here as [SttAudioRequest.precedingGapBytes] and is bridged with
/// silence. Every piece of that chain existed before this worker did; this file is
/// the part that declines to break it by queueing.
library;

import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import 'pcm_samples.dart';
import 'sherpa_recognizer.dart';
import 'stt_config.dart';
import 'stt_protocol.dart';

/// Raised when the worker reports a failure, or dies.
class SttFailure implements Exception {
  const SttFailure(this.message, {this.recognizerLost = false});

  final String message;

  /// Whether the recogniser is gone rather than this session having failed.
  final bool recognizerLost;

  @override
  String toString() =>
      'SttFailure($message${recognizerLost ? ', recognizer lost' : ''})';
}

/// A place recognition can be hosted: an isolate in production, something
/// scripted in a test.
///
/// The same seam `InferenceHost` is, one layer above [SttRecognizerRuntime]: this
/// one abstracts *the boundary*, that one abstracts *the library*. Both are needed
/// because they fail differently — a worker can die between requests, which no
/// scripted runtime can reproduce.
abstract interface class SttHost {
  /// Starts the host and builds the recogniser described by [config].
  Future<SttReady> start(SttConfig config);

  /// Opens a recognition session.
  Future<void> beginSession();

  /// Feeds one chunk and returns what it produced.
  Future<List<SttTranscriptWire>> acceptAudio(SttAudioRequest request);

  /// Flushes and returns the session's final transcripts.
  Future<List<SttTranscriptWire>> finishSession();

  /// Abandons the session without flushing.
  Future<void> cancelSession();

  /// Releases the recogniser and the host.
  Future<void> shutdown();
}

/// [SttHost] backed by a real background isolate running [SherpaRecognizerRuntime].
class IsolateSttHost implements SttHost {
  IsolateSttHost({this.shutdownGrace = const Duration(seconds: 5)});

  /// How long [shutdown] waits for a clean teardown before killing the isolate.
  ///
  /// Much shorter than the inference host's ten seconds, because there is much
  /// less to lose: this model is 43MB against 2.6GB, and nothing here is mid-way
  /// through a multi-second native operation the way a generation turn is.
  final Duration shutdownGrace;

  Isolate? _isolate;
  SendPort? _commands;
  ReceivePort? _lifecycle;

  /// Completed with an error the moment the worker is known to be gone.
  ///
  /// Every request races this. Without it a request to a dead worker waits on a
  /// port nobody reads — forever, and while holding the microphone open.
  Completer<Never> _workerLost = _lostWorkerCompleter();

  static Completer<Never> _lostWorkerCompleter() {
    final completer = Completer<Never>();
    // Belt to `_teardown`'s braces. Nothing *should* complete this without a racer
    // attached — see `_teardown`, which deliberately does not — but a future
    // completed with an error and no listener is an unhandled async error, and on the
    // integration-test binding an unhandled error fails whatever test is running.
    completer.future.ignore();
    return completer;
  }

  bool _disposed = false;
  String? _lostReason;

  /// Serialises requests onto the single command port.
  ///
  /// The session protocol is strictly one-in-flight by construction, but `shutdown`
  /// can arrive from a different call stack than the audio loop — the user leaving
  /// the screen mid-utterance — and two `_request` calls interleaving on one port
  /// would pair each reply with the wrong caller.
  Future<void> _gate = Future.value();

  bool get isRunning => _commands != null && _lostReason == null;

  @override
  Future<SttReady> start(SttConfig config) async {
    if (_disposed) {
      throw StateError('IsolateSttHost was shut down; create a new one');
    }
    if (_isolate != null) {
      throw StateError('IsolateSttHost.start called twice');
    }

    _workerLost = _lostWorkerCompleter();
    try {
      return await _startAndLoad(config);
    } on Object {
      // Every failure path lands here — a spawn that failed, a worker that died at
      // the handshake, a load that was refused. One teardown for all of them, so a
      // failed start leaves the host able to try again rather than permanently
      // refusing with "start called twice". `IsolateInferenceHost` records the bug
      // this prevents; it is the same bug.
      await _teardown();
      rethrow;
    }
  }

  Future<SttReady> _startAndLoad(SttConfig config) async {
    final handshake = ReceivePort('stt.handshake');
    // One port serves `onExit` (a bare null) and `onError` (a two-element list),
    // told apart by shape. Both must be watched: a worker that dies between
    // requests has to surface, or the next call waits on a port nobody reads.
    final lifecycle = ReceivePort('stt.lifecycle');
    _lifecycle = lifecycle;
    lifecycle.listen(_onWorkerLifecycleEvent);

    // No `RootIsolateToken` is handed over, unlike the inference worker. sherpa
    // reaches its native library through `DynamicLibrary.open` — no platform
    // channel — and the model paths in `config` were resolved on the root isolate,
    // so the worker never calls `path_provider`. See `sherpa_recognizer.dart`.
    _isolate = await Isolate.spawn(
      sttWorkerMain,
      handshake.sendPort,
      debugName: 'fieldops-stt',
      onExit: lifecycle.sendPort,
      onError: lifecycle.sendPort,
      errorsAreFatal: true,
    );

    try {
      _commands =
          await Future.any<Object?>([handshake.first, _workerLost.future])
              as SendPort;
    } finally {
      handshake.close();
    }

    final reply = await _request(SttLoadRequest(config.toWire()));
    return switch (reply) {
      SttReadyReply(:final ready) => ready,
      // Thrown rather than returned, and `start` tears the worker down on the way
      // out. A worker that could not build a recogniser has nothing worth keeping.
      // The teardown is `_teardown`, not `shutdown()`: a failed load must stay
      // retryable, and `shutdown` marks the host permanently unusable.
      SttFailureReply(:final message) => throw SttFailure(
        message,
        recognizerLost: true,
      ),
      _ => throw SttFailure('unexpected reply to load: $reply'),
    };
  }

  @override
  Future<void> beginSession() async {
    final reply = await _request(const SttBeginRequest());
    _expectAck(reply, 'begin');
  }

  @override
  Future<List<SttTranscriptWire>> acceptAudio(SttAudioRequest request) async =>
      _expectTranscripts(await _request(request), 'audio');

  @override
  Future<List<SttTranscriptWire>> finishSession() async =>
      _expectTranscripts(await _request(const SttFinishRequest()), 'finish');

  @override
  Future<void> cancelSession() async {
    _expectAck(await _request(const SttCancelRequest()), 'cancel');
  }

  @override
  Future<void> shutdown() async {
    _disposed = true;
    await _teardown();
  }

  /// Releases the worker and everything attached to it, leaving the host able to
  /// [start] again. [shutdown] additionally sets [_disposed]; a failed start does
  /// not.
  Future<void> _teardown() async {
    final commands = _commands;
    _commands = null;

    if (commands != null && _lostReason == null) {
      try {
        await _requestOn(
          commands,
          const SttShutdownRequest(),
        ).timeout(shutdownGrace);
      } on TimeoutException {
        debugPrint(
          '[stt] worker did not acknowledge shutdown within '
          '${shutdownGrace.inSeconds}s; killing the isolate',
        );
      } on SttFailure catch (error) {
        debugPrint('[stt] worker lost during shutdown: ${error.message}');
      }
    }

    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _lifecycle?.close();
    _lifecycle = null;

    // **Deliberately does not complete `_workerLost`, and that is a device finding.**
    // This used to be `_workerLost.completeError(SttFailure('stt host shut down'))`,
    // copied from `IsolateInferenceHost` along with the `ignore()` meant to keep it
    // quiet. On the iPad it was **not** quiet: disposing an engine that had
    // successfully started threw that failure as an unhandled error out of this
    // method, and `IntegrationTestWidgetsFlutterBinding` failed all three STT ACs on
    // it — *after their bodies had passed*. Attaching a real `onError` handler to the
    // completer did not help either; the report happens at the completion itself.
    //
    // The design answer is that the completion was never needed here. `_workerLost`
    // exists to release a request racing a worker that **died** — that is
    // `_onWorkerLifecycleEvent`'s job, and it still does it. A *clean* teardown has no
    // racer to release: `_gate` serialises every request, so the shutdown above queued
    // behind whatever was in flight and that request has already been answered. And if
    // the worker was wedged, the `.timeout(shutdownGrace)` has already given up on it.
    // So there was nobody to notify, and notifying nobody with an error is exactly
    // what the binding objects to.
    //
    // `start()` installs a fresh completer, so a later attempt never inherits this
    // one.
    //
    // Only hardware said so: every host test passed, including the whole-stack live
    // run that starts a real isolate, loads the real weights and disposes the engine.
    // That is the clearest example this task produced of what the device tier is *for*.
    // Cleared so a retry is not refused by its predecessor's failure: after a
    // teardown there is no worker to be dead, and `start()` installs a fresh
    // `_workerLost`.
    _lostReason = null;
  }

  void _onWorkerLifecycleEvent(Object? message) {
    final reason = switch (message) {
      List(length: 2, first: final error) => 'worker error: $error',
      _ => 'worker exited',
    };
    if (_lostReason != null) return;
    _lostReason = reason;
    _commands = null;
    if (!_workerLost.isCompleted) {
      _workerLost.completeError(SttFailure(reason, recognizerLost: true));
    }
  }

  Future<SttReply> _request(SttRequest request) {
    final commands = _commands;
    if (commands == null || _lostReason != null) {
      throw StateError(switch ((_disposed, _lostReason)) {
        (_, final reason?) => 'stt worker is gone: $reason',
        (true, _) => 'IsolateSttHost was shut down',
        _ => 'IsolateSttHost used before start()',
      });
    }
    return _requestOn(commands, request);
  }

  /// Sends one request and waits for its single reply, or for the worker to die —
  /// whichever happens first. Serialised through [_gate].
  Future<SttReply> _requestOn(SendPort commands, SttRequest request) {
    final result = _gate.then((_) async {
      final port = ReceivePort('stt.reply');
      try {
        commands.send([request.toWire(), port.sendPort]);
        final raw = await Future.any<Object?>([port.first, _workerLost.future]);
        return SttReply.fromWire((raw as Map).cast<String, Object?>());
      } finally {
        port.close();
      }
    });
    // The gate must advance even when this request failed, or one dead worker
    // wedges every later call — including the shutdown that would clean it up.
    _gate = result.then((_) {}, onError: (_) {});
    return result;
  }

  static void _expectAck(SttReply reply, String what) {
    switch (reply) {
      case SttAckReply():
        return;
      case SttFailureReply(:final message, :final recognizerLost):
        throw SttFailure(message, recognizerLost: recognizerLost);
      default:
        throw SttFailure('unexpected reply to $what: $reply');
    }
  }

  static List<SttTranscriptWire> _expectTranscripts(
    SttReply reply,
    String what,
  ) {
    switch (reply) {
      case SttTranscriptsReply(:final transcripts):
        return transcripts;
      case SttFailureReply(:final message, :final recognizerLost):
        throw SttFailure(message, recognizerLost: recognizerLost);
      default:
        throw SttFailure('unexpected reply to $what: $reply');
    }
  }
}

/// Entry point of the STT isolate.
///
/// Top-level and annotated because `Isolate.spawn` needs a statically resolvable
/// entry point and AOT builds must not tree-shake it.
@pragma('vm:entry-point')
Future<void> sttWorkerMain(SendPort handshake) async {
  final commands = ReceivePort('stt.commands');
  handshake.send(commands.sendPort);
  await serveSttRequests(commands: commands, runtime: null);
}

/// The worker's request loop, factored out of [sttWorkerMain] so it can be driven
/// on the host against a scripted [SttRecognizerRuntime].
///
/// Returns once an [SttShutdownRequest] has been served, at which point [commands]
/// is closed and the entry point is free to return.
///
/// [runtime] is `null` in the isolate, where the real one cannot be built until a
/// load request arrives carrying [SttConfig.nativeLibraryPath]; it is constructed
/// there and reused for the worker's life. Tests pass a scripted runtime, which is
/// used as given and never replaced.
@visibleForTesting
Future<void> serveSttRequests({
  required ReceivePort commands,
  required SttRecognizerRuntime? runtime,
}) async {
  SttConfig? config;
  var recognizer = runtime;

  await for (final message in commands) {
    final command = _decodeCommand(message);
    if (command == null) continue;
    final (request, reply) = command;

    switch (request) {
      case SttLoadRequest(config: final wire):
        try {
          final decoded = SttConfig.fromWire(wire);
          // Built here rather than at spawn because the library path travels in
          // the config. A scripted runtime supplied by a test is kept as it is.
          recognizer ??= SherpaRecognizerRuntime(
            nativeLibraryPath: decoded.nativeLibraryPath,
          );
          final ready = await recognizer.load(decoded);
          config = decoded;
          reply?.send(SttReadyReply(ready).toWire());
        } on Object catch (error) {
          // `on Object`, not `on Exception`: `OnlineRecognizer`'s constructor
          // throws a bare `Exception` for a bad config, but the FFI layer under it
          // can surface an `Error`, and letting one escape would kill the isolate
          // instead of telling the caller why the model would not load.
          reply?.send(
            SttFailureReply(
              message: 'recognizer load failed: $error',
              recognizerLost: true,
            ).toWire(),
          );
        }

      case SttBeginRequest():
        final active = recognizer;
        if (active == null) {
          reply?.send(_notLoaded('begin').toWire());
          continue;
        }
        _guard(reply, () {
          active.beginSession();
          return const SttAckReply();
        });

      case SttAudioRequest(:final bytes, :final precedingGapBytes):
        final active = config;
        final engine = recognizer;
        if (active == null || engine == null) {
          reply?.send(_notLoaded('audio').toWire());
          continue;
        }
        _guard(reply, () {
          final produced = <SttRuntimeTranscript>[];
          // The gap is bridged *before* the audio that follows it, which is the
          // order it happened in. Bridging after would move the silence past the
          // words it separated and change which of them the endpointer splits.
          final gap = _bridgeSamples(active, precedingGapBytes);
          if (gap > 0) {
            produced.addAll(engine.acceptSamples(silentSamples(gap)));
          }
          produced.addAll(engine.acceptSamples(pcm16ToFloat32(bytes)));
          return SttTranscriptsReply(_toWire(produced));
        });

      case SttFinishRequest():
        final active = config;
        final engine = recognizer;
        if (active == null || engine == null) {
          reply?.send(_notLoaded('finish').toWire());
          continue;
        }
        _guard(reply, () {
          final produced = <SttRuntimeTranscript>[];
          // Tail padding goes in before the flush, not after: `inputFinished`
          // stops the stream accepting samples, so padding sent afterwards would
          // be discarded — and the padding is the whole reason the last word
          // survives. See `SttConfig.tailPadding`.
          final padding = sampleCountFor(
            active.format,
            active.format.byteCountFor(active.tailPadding),
          );
          if (padding > 0) {
            produced.addAll(engine.acceptSamples(silentSamples(padding)));
          }
          produced.addAll(engine.finishSession());
          return SttTranscriptsReply(_toWire(produced));
        });

      case SttCancelRequest():
        final active = recognizer;
        if (active == null) {
          reply?.send(_notLoaded('cancel').toWire());
          continue;
        }
        _guard(reply, () {
          active.cancelSession();
          return const SttAckReply();
        });

      case SttShutdownRequest():
        // Cancel first so no native stream is live while the recogniser under it
        // is being destroyed. A worker that never loaded has nothing to release,
        // and must still acknowledge — the host waits for this before killing the
        // isolate.
        final active = recognizer;
        if (active != null) {
          try {
            active.cancelSession();
          } on Object catch (error) {
            debugPrint('[stt worker] cancel during shutdown failed: $error');
          }
          await active.close();
        }
        reply?.send(const SttAckReply().toWire());
        commands.close();
        return;
    }
  }
}

/// The answer to any session request that arrives before a successful load.
///
/// One shape for all of them, naming which request it was: the caller's bug is
/// the ordering, and the request name is the only part that varies.
SttFailureReply _notLoaded(String what) =>
    SttFailureReply(message: '$what arrived before the recognizer was loaded');

/// Runs [body] and answers [reply] with its result, or with a failure.
///
/// A session-scoped failure by default: a chunk that failed to decode says
/// nothing about whether the recogniser is still loaded, and declaring it lost
/// would cost a needless reload.
void _guard(SendPort? reply, SttReply Function() body) {
  if (reply == null) {
    // No port to answer on. Running the body anyway would advance the recogniser's
    // state with nobody able to observe it, which is worse than dropping it.
    debugPrint('[stt worker] request had no reply port');
    return;
  }
  try {
    reply.send(body().toWire());
  } on Object catch (error) {
    reply.send(SttFailureReply(message: '$error').toWire());
  }
}

/// Samples of silence to insert for [gapBytes] of dropped audio, capped.
int _bridgeSamples(SttConfig config, int gapBytes) {
  if (gapBytes <= 0) return 0;
  final capBytes = config.format.byteCountFor(config.maxGapBridge);
  final bounded = gapBytes < capBytes ? gapBytes : capBytes;
  return sampleCountFor(config.format, bounded);
}

List<SttTranscriptWire> _toWire(List<SttRuntimeTranscript> transcripts) => [
  for (final t in transcripts)
    SttTranscriptWire(text: t.text, isFinal: t.isFinal, segment: t.segment),
];

/// Splits a command message into its request and reply port.
///
/// Returns `null` for anything malformed, and deliberately does not reply on that
/// path: a message this layer cannot parse may not carry a port to answer on.
(SttRequest, SendPort?)? _decodeCommand(Object? message) {
  if (message is! List || message.length != 2) {
    debugPrint('[stt worker] ignoring malformed command: $message');
    return null;
  }
  final wire = message[0];
  final reply = message[1];
  if (wire is! Map) {
    debugPrint('[stt worker] ignoring command with no request map');
    return null;
  }
  try {
    return (
      SttRequest.fromWire(wire.cast<String, Object?>()),
      reply is SendPort ? reply : null,
    );
  } on FormatException catch (error) {
    debugPrint('[stt worker] ignoring undecodable command: $error');
    return null;
  }
}
