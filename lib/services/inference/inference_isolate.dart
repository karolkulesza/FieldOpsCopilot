/// Runs on-device inference on a dedicated background isolate.
///
/// **Why an isolate at all, given the plugin already threads?** The LiteRT-LM
/// engine does keep its worst blocking work off the caller: engine and conversation
/// creation run inside `Isolate.run`, and generated chunks arrive through a
/// `NativeCallable.listener` fed by a native decode thread. So part of what this
/// wrapper guarantees, the plugin already happens to do.
///
/// "Happens to do" is the point. The spec's §3.1 promise is that the UI isolate
/// never stalls, and that promise has to survive a plugin upgrade, a swap to a
/// different engine package, and the MediaPipe `.task` path whose threading is not
/// the same. An isolate boundary at *this app's* seam is a guarantee about our own
/// architecture rather than a bet on a dependency's internals. The cost is a port
/// hop per token — microseconds against a decode measured in tens of milliseconds.
///
/// The boundary also buys crash containment: an uncaught error in the worker
/// arrives here as a message on a port instead of taking the UI isolate with it.
///
/// The protocol is deliberately small — load, generate, stop, shutdown — and every
/// message crosses as encoded maps (`inference_protocol.dart`) so the wire format is
/// unit-testable without spawning anything.
library;

import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../engines/llm_engine.dart';
import 'gemma_runtime.dart';
import 'inference_config.dart';
import 'inference_protocol.dart';

/// A place inference can be run: an isolate in production, something scripted in a
/// test.
///
/// Exists so the engine's contract — ready states, one turn at a time, disposal,
/// failure propagation — can be verified on the host. That contract is app logic,
/// and app logic should not need a 2.6GB model to test.
abstract interface class InferenceHost {
  /// Starts the host and loads [config]'s weights.
  Future<LoadedRuntime> start(InferenceConfig config);

  /// Streams one turn. The stream emits an [LlmDone] event and then closes.
  Stream<LlmEvent> generate({
    required String prompt,
    List<ToolDefinition> tools,
  });

  /// Releases the model and the host.
  Future<void> shutdown();
}

/// Raised when the worker reports a failure, or dies.
///
/// Carries [enginePresumedLost] so a caller can tell "this turn failed" from "there
/// is no engine any more": the first is worth retrying, the second needs a reload,
/// and confusing them either drops an answer or re-loads 2.6GB for nothing.
class InferenceFailure implements Exception {
  const InferenceFailure(this.message, {this.enginePresumedLost = false});

  final String message;
  final bool enginePresumedLost;

  @override
  String toString() =>
      'InferenceFailure($message'
      '${enginePresumedLost ? ', engine presumed lost' : ''})';
}

/// [InferenceHost] backed by a real background isolate running [GemmaRuntime].
class IsolateInferenceHost implements InferenceHost {
  IsolateInferenceHost({this.shutdownGrace = const Duration(seconds: 10)});

  /// How long [shutdown] waits for a clean teardown before killing the isolate.
  ///
  /// A worker wedged in native code would otherwise hold the model's memory for the
  /// life of the app, which on a 4GB device is the difference between the next
  /// screen working and the OS killing the process.
  final Duration shutdownGrace;

  Isolate? _isolate;
  SendPort? _commands;
  ReceivePort? _lifecycle;

  /// Completed with an error the moment the worker is known to be gone.
  ///
  /// Every request races this, because a port whose reader has died never answers:
  /// without it a load or a turn would hang forever on a worker that crashed.
  Completer<Never> _workerLost = _lostWorkerCompleter();

  /// Builds the completer above with its error pre-ignored.
  ///
  /// The `ignore()` is not tidiness. Completing a future with an error and no
  /// listener is an *unhandled async error*, and the common case has no listener at
  /// all: an app that never loads the model still disposes the engine on the way out,
  /// which completes this. Without this, every such teardown reported a crash that
  /// had not happened. Racers still receive the error normally — `ignore()` only
  /// suppresses the unhandled-error report.
  static Completer<Never> _lostWorkerCompleter() {
    final completer = Completer<Never>();
    completer.future.ignore();
    return completer;
  }

  /// The turn in flight, so it can be failed if the worker dies mid-generation.
  _HostTurn? _turn;

  int _nextTurnId = 1;
  bool _disposed = false;
  String? _lostReason;

  /// Whether the worker is up and has not been reported lost.
  bool get isRunning => _commands != null && _lostReason == null;

  @override
  Future<LoadedRuntime> start(InferenceConfig config) async {
    if (_disposed) {
      throw StateError('IsolateInferenceHost was shut down; create a new one');
    }
    if (_isolate != null) {
      throw StateError('IsolateInferenceHost.start called twice');
    }

    // The worker reaches `path_provider` and `shared_preferences` through the
    // plugin, and platform channels on a background isolate only work once the
    // messenger has this token. Reading it *here* is mandatory:
    // `RootIsolateToken.instance` is null inside the worker, which is exactly why
    // it has to be handed over at spawn.
    final token = RootIsolateToken.instance;
    if (token == null) {
      throw StateError(
        'no RootIsolateToken — inference must be started from the root isolate '
        'after the Flutter binding is initialised',
      );
    }

    _workerLost = _lostWorkerCompleter();

    try {
      return await _startAndLoad(config, token);
    } on Object {
      // Every failure path lands here — a spawn that failed, a worker that died
      // before the handshake, a load that was refused, a reply that made no sense.
      // The first version only tore down after a `FailureReply`, and a worker dying
      // *at the handshake* therefore left `_isolate` set: the next attempt was
      // refused with "start called twice" and the host was permanently unusable
      // after one bad start. One teardown for all of them, and the caller still sees
      // the original error.
      await _teardown();
      rethrow;
    }
  }

  /// The body of [start]: spawn, handshake, load. Failures are handled by [start].
  Future<LoadedRuntime> _startAndLoad(
    InferenceConfig config,
    RootIsolateToken token,
  ) async {
    final handshake = ReceivePort('inference.handshake');
    // One port serves both channels: `onExit` sends a bare null and `onError` sends
    // a two-element list, so they are told apart by shape. Both must be watched — a
    // worker that dies between requests has to surface, or the next call waits on a
    // port nobody reads.
    final lifecycle = ReceivePort('inference.lifecycle');
    _lifecycle = lifecycle;
    lifecycle.listen(_onWorkerLifecycleEvent);

    _isolate = await Isolate.spawn(
      inferenceWorkerMain,
      [handshake.sendPort, token],
      debugName: 'fieldops-inference',
      onExit: lifecycle.sendPort,
      onError: lifecycle.sendPort,
      // An error the worker did not handle must end the worker rather than leave a
      // half-dead isolate holding the model: `onExit` then fires and every pending
      // request fails with a reason.
      errorsAreFatal: true,
    );

    try {
      _commands =
          await Future.any<Object?>([handshake.first, _workerLost.future])
              as SendPort;
    } finally {
      handshake.close();
    }

    final reply = await _request(LoadRequest(config.toWire()));
    switch (reply) {
      case LoadedReply(:final runtime):
        return LoadedRuntime.fromWire(runtime);
      // Thrown, not returned: [start] tears the worker down on the way out. A
      // worker that could not load has nothing worth keeping — the weights are not
      // resident, and leaving the isolate alive would hold an idle plugin and a stale
      // handshake.
      //
      // That teardown uses `_teardown`, *not* `shutdown()`. `shutdown` is the public
      // "this host is finished" call and marks the host unusable, which would make a
      // load failure permanent: a device that failed one load could never try again
      // without rebuilding the whole provider graph. The engine's contract is that a
      // failed load stays retryable, and this is the half of it that lives here.
      case FailureReply(:final message):
        throw InferenceFailure(message, enginePresumedLost: true);
      default:
        throw InferenceFailure('unexpected reply to load: $reply');
    }
  }

  @override
  Stream<LlmEvent> generate({
    required String prompt,
    List<ToolDefinition> tools = const [],
  }) {
    final commands = _commands;
    if (commands == null || _lostReason != null) {
      throw StateError(switch ((_disposed, _lostReason)) {
        (_, final reason?) => 'inference worker is gone: $reason',
        (true, _) => 'IsolateInferenceHost was shut down',
        _ => 'IsolateInferenceHost.generate called before start()',
      });
    }
    if (_turn != null) {
      // Generation is serialised all the way down — the engine runs one
      // conversation at a time — so overlapping turns cannot be honoured. Refusing
      // is better than queueing: a queued turn silently inherits the delay of the
      // one ahead of it, and the caller (the agent loop) needs to know.
      throw StateError('a generation turn is already in flight');
    }

    final turnId = _nextTurnId++;
    final events = ReceivePort('inference.turn.$turnId');
    final turn = _HostTurn(id: turnId, events: events);
    _turn = turn;

    turn.controller.onCancel = () {
      // Cancelling before the turn finished means the consumer walked away mid
      // generation. Tell the worker, or the accelerator keeps decoding tokens
      // nobody will read — which delays the *next* turn and burns the battery this
      // app exists to protect.
      if (!turn.isFinished && isRunning) {
        commands.send([StopRequest(turnId).toWire(), null]);
      }
      _finishTurn(turn);
    };

    events.listen((raw) => _onTurnMessage(turn, raw));

    // Sent eagerly rather than from `onListen`, because that is what actually
    // happens on device: asking for a turn starts the decode. A consumer that
    // listens late gets the buffered tokens in order.
    commands.send([
      GenerateRequest(turnId: turnId, prompt: prompt, tools: tools).toWire(),
      events.sendPort,
    ]);

    return turn.controller.stream;
  }

  @override
  Future<void> shutdown() async {
    // The one difference from [_teardown]: this host is finished for good, and a
    // later `start()` on it is a bug in the caller rather than a retry.
    _disposed = true;
    await _teardown();
  }

  /// Releases the worker and every resource attached to it, leaving the host able to
  /// [start] again.
  ///
  /// Used by both [shutdown] and a failed [start]. The difference is only
  /// [_disposed], which [shutdown] sets and a failed start deliberately does not.
  Future<void> _teardown() async {
    final commands = _commands;
    _commands = null;

    final turn = _turn;
    if (turn != null) {
      turn.fail(
        const InferenceFailure(
          'inference host shut down mid-turn',
          enginePresumedLost: true,
        ),
      );
      _finishTurn(turn);
    }

    if (commands != null && _lostReason == null) {
      try {
        await _requestOn(
          commands,
          const ShutdownRequest(),
        ).timeout(shutdownGrace);
      } on TimeoutException {
        // Deliberate: a worker that will not answer is holding gigabytes, and
        // waiting longer only makes the OS more likely to kill the whole process.
        debugPrint(
          '[inference] worker did not acknowledge shutdown within '
          '${shutdownGrace.inSeconds}s; killing the isolate',
        );
      } on InferenceFailure catch (error) {
        // It died while we were asking. Nothing left to do politely.
        debugPrint('[inference] worker lost during shutdown: ${error.message}');
      }
    }

    // Harmless when the worker already returned from its entry point and exited;
    // decisive when it did not.
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _lifecycle?.close();
    _lifecycle = null;
    if (!_workerLost.isCompleted) {
      _workerLost.completeError(
        const InferenceFailure('inference host shut down'),
      );
    }
    // Cleared so a retry is not immediately refused by its own predecessor's
    // failure: `_lostReason` is what makes `generate` and `isRunning` report a dead
    // worker, and after a teardown there is no worker to be dead. `start()` installs
    // a fresh `_workerLost` for the next attempt.
    _lostReason = null;
  }

  /// Handles the `onExit` / `onError` messages of the worker isolate.
  void _onWorkerLifecycleEvent(Object? message) {
    // `onError` sends [errorString, stackTraceString]; `onExit` sends null.
    final reason = switch (message) {
      List(length: 2, first: final error) => 'worker error: $error',
      _ => 'worker exited',
    };
    if (_lostReason != null) return;
    _lostReason = reason;
    _commands = null;

    final turn = _turn;
    if (turn != null) {
      turn.fail(InferenceFailure(reason, enginePresumedLost: true));
      _finishTurn(turn);
    }
    if (!_workerLost.isCompleted) {
      _workerLost.completeError(
        InferenceFailure(reason, enginePresumedLost: true),
      );
    }
  }

  void _onTurnMessage(_HostTurn turn, Object? raw) {
    // A message for a turn that already ended (a stop and a final token crossing)
    // is dropped rather than added to a closed controller.
    if (turn.isFinished) return;
    final InferenceReply reply;
    try {
      reply = InferenceReply.fromWire((raw as Map).cast<String, Object?>());
    } on Object catch (error) {
      turn.fail(InferenceFailure('undecodable reply from worker: $error'));
      _finishTurn(turn);
      return;
    }

    switch (reply) {
      case EventReply(:final event):
        turn.controller.add(event);
        // `LlmDone` is delivered to the consumer *and* terminates the stream: the
        // sealed event hierarchy makes it the turn's terminal item, and the fake
        // engine emits it the same way, so the two backends look identical to a
        // consumer.
        if (event is LlmDone) _finishTurn(turn);
      case FailureReply(:final message, :final stateful):
        turn.fail(InferenceFailure(message, enginePresumedLost: stateful));
        _finishTurn(turn);
      default:
        turn.fail(InferenceFailure('unexpected reply during a turn: $reply'));
        _finishTurn(turn);
    }
  }

  void _finishTurn(_HostTurn turn) {
    if (turn.isFinished) return;
    turn.finish();
    if (_turn == turn) _turn = null;
  }

  Future<InferenceReply> _request(InferenceRequest request) {
    final commands = _commands;
    if (commands == null) {
      throw StateError('inference worker is not running');
    }
    return _requestOn(commands, request);
  }

  /// Sends a one-shot request and waits for its single reply, or for the worker to
  /// die — whichever happens first.
  Future<InferenceReply> _requestOn(
    SendPort commands,
    InferenceRequest request,
  ) async {
    final port = ReceivePort('inference.reply');
    try {
      commands.send([request.toWire(), port.sendPort]);
      final raw = await Future.any<Object?>([port.first, _workerLost.future]);
      return InferenceReply.fromWire((raw as Map).cast<String, Object?>());
    } finally {
      port.close();
    }
  }
}

/// Host-side bookkeeping for one generation turn.
class _HostTurn {
  _HostTurn({required this.id, required this.events});

  final int id;
  final ReceivePort events;
  final StreamController<LlmEvent> controller = StreamController<LlmEvent>();

  bool _finished = false;
  bool get isFinished => _finished;

  void fail(InferenceFailure failure) {
    if (_finished || controller.isClosed) return;
    controller.addError(failure);
  }

  /// Closes the turn's resources. Idempotent — the consumer cancelling and the
  /// worker sending `LlmDone` both land here, often in that order.
  void finish() {
    if (_finished) return;
    _finished = true;
    events.close();
    if (!controller.isClosed) controller.close();
  }
}

/// Entry point of the inference isolate.
///
/// [boot] is `[handshakeSendPort, rootIsolateToken]`. Top-level and annotated
/// because `Isolate.spawn` needs a statically resolvable entry point, and AOT builds
/// must not tree-shake it.
@pragma('vm:entry-point')
Future<void> inferenceWorkerMain(List<Object?> boot) async {
  final handshake = boot[0] as SendPort;
  final token = boot[1] as RootIsolateToken;
  // Without this, the plugin's first `path_provider` / `shared_preferences` call
  // throws — platform channels on a background isolate need the root token.
  BackgroundIsolateBinaryMessenger.ensureInitialized(token);

  final commands = ReceivePort('inference.commands');
  handshake.send(commands.sendPort);
  await serveInferenceRequests(commands: commands, runtime: GemmaRuntime());
}

/// The worker's request loop, factored out of [inferenceWorkerMain] so it can be
/// driven on the host against a scripted [InferenceRuntime].
///
/// Returns once a [ShutdownRequest] has been served, at which point [commands] is
/// closed and the isolate's entry point is free to return.
@visibleForTesting
Future<void> serveInferenceRequests({
  required ReceivePort commands,
  required InferenceRuntime runtime,
}) async {
  // The turn in flight, if any. Generation is *not* awaited inside the loop: doing
  // so would make the loop deaf to the very `stop` it needs to hear, since the stop
  // arrives while the turn is still running.
  _WorkerTurn? active;

  await for (final message in commands) {
    final command = _decodeCommand(message);
    if (command == null) continue;
    final (request, reply) = command;

    switch (request) {
      case LoadRequest(:final config):
        // Awaited inline. Nothing else can usefully run before the model exists,
        // and a `stop` or `generate` racing a load has nothing to act on. A
        // `shutdown` therefore queues behind the load, which is the safer order:
        // tearing down native state mid-load is how you crash instead of exit.
        try {
          final loaded = await runtime.load(InferenceConfig.fromWire(config));
          reply?.send(LoadedReply(loaded.toWire()).toWire());
        } on Object catch (error) {
          // `on Object`, not `on Exception`: a native load failure surfaces as
          // whatever the FFI layer threw — including `Error` subtypes — and letting
          // it escape would kill the isolate instead of telling the caller why.
          reply?.send(
            FailureReply(
              message: 'model load failed: $error',
              stateful: true,
            ).toWire(),
          );
        }

      case GenerateRequest():
        if (reply == null) {
          // No port to stream to. Dropping it is all that is left, but silence here
          // would look like a hung model, so say so.
          debugPrint('[inference worker] generate request had no reply port');
          continue;
        }
        if (active != null) {
          reply.send(
            const FailureReply(
              message:
                  'the engine is already generating; inference is serialised '
                  'on device and turns cannot overlap',
            ).toWire(),
          );
          continue;
        }
        final turn = _WorkerTurn(request.turnId);
        active = turn;
        // Unawaited on purpose — see the note above `active`.
        unawaited(
          _runTurn(
            runtime: runtime,
            request: request,
            reply: reply,
          ).whenComplete(() {
            if (active == turn) active = null;
          }),
        );

      case StopRequest(:final turnId):
        // A stop naming a turn that already finished must not touch the current
        // one: without this check, a stop racing the end of turn N would cancel
        // turn N+1, which the user experiences as a question that got no answer.
        if (active?.id == turnId) {
          await runtime.stop();
        }

      case ShutdownRequest():
        // Stop first so native decoding is not still running while the model is
        // being deleted underneath it.
        if (active != null) await runtime.stop();
        await runtime.close();
        reply?.send(const ShutdownReply().toWire());
        commands.close();
        return;
    }
  }
}

/// Streams one turn's events to [reply], guaranteeing a terminal message.
Future<void> _runTurn({
  required InferenceRuntime runtime,
  required GenerateRequest request,
  required SendPort reply,
}) async {
  var sawDone = false;
  try {
    await for (final event in runtime.generate(
      prompt: request.prompt,
      tools: request.tools,
    )) {
      if (event is LlmDone) sawDone = true;
      reply.send(EventReply(event).toWire());
    }
    if (!sawDone) {
      // The host closes a turn's stream on `LlmDone` or a failure, so a runtime
      // that ended without either would leave the caller waiting on a model that
      // has already stopped. Report it rather than synthesising a `done` that would
      // hide the bug.
      reply.send(
        const FailureReply(
          message:
              'generation ended without a terminal event — the runtime closed '
              'its stream without emitting LlmDone',
        ).toWire(),
      );
    }
  } on Object catch (error) {
    // Turn-scoped by default: a failed generation says nothing about whether the
    // weights are still loaded, and declaring the engine lost here would cost a
    // needless multi-gigabyte reload.
    if (!sawDone) {
      reply.send(FailureReply(message: 'generation failed: $error').toWire());
    }
  }
}

/// Worker-side bookkeeping for one turn.
class _WorkerTurn {
  _WorkerTurn(this.id);

  final int id;
}

/// Splits a command message into its request and reply port.
///
/// Returns `null` for anything malformed. There is deliberately no reply on that
/// path: a message this layer cannot parse may not even carry a port to answer on,
/// and inventing one would be worse than logging.
(InferenceRequest, SendPort?)? _decodeCommand(Object? message) {
  if (message is! List || message.length != 2) {
    debugPrint('[inference worker] ignoring malformed command: $message');
    return null;
  }
  final wire = message[0];
  final reply = message[1];
  if (wire is! Map) {
    debugPrint('[inference worker] ignoring command with no request map');
    return null;
  }
  try {
    return (
      InferenceRequest.fromWire(wire.cast<String, Object?>()),
      reply is SendPort ? reply : null,
    );
  } on FormatException catch (error) {
    debugPrint('[inference worker] ignoring undecodable command: $error');
    return null;
  }
}
