import 'dart:async';
import 'dart:isolate';

import 'package:field_ops_copilot/engines/llm_engine.dart';
import 'package:field_ops_copilot/services/inference/gemma_runtime.dart';
import 'package:field_ops_copilot/services/inference/inference_config.dart';
import 'package:field_ops_copilot/services/inference/inference_isolate.dart';
import 'package:field_ops_copilot/services/inference/inference_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

/// Exercises the worker's request loop without spawning an isolate.
///
/// `serveInferenceRequests` is the half of the isolate that can be wrong in
/// interesting ways — a stop that cancels the wrong turn, a loop that goes deaf
/// while generating, a native error that kills the worker instead of being reported.
/// Driving it over ports in the test isolate against a scripted runtime makes all of
/// that testable in CI, and leaves the device tests to prove only what a device can.
void main() {
  const config = InferenceConfig(modelPath: '/models/gemma.litertlm');

  /// Starts the loop and returns a handle for talking to it.
  _Worker startWorker(InferenceRuntime runtime) {
    final commands = ReceivePort('test.commands');
    final served = serveInferenceRequests(commands: commands, runtime: runtime);
    return _Worker(commands.sendPort, served);
  }

  group('load', () {
    test('reports the runtime the load produced', () async {
      final runtime = _ScriptedRuntime(
        loaded: const LoadedRuntime(
          backend: 'gpu',
          loadMillis: 4200,
          contextTokens: 2048,
        ),
      );
      final worker = startWorker(runtime);
      addTearDown(worker.shutdown);

      final reply = await worker.request(LoadRequest(config.toWire()));

      expect(reply, isA<LoadedReply>());
      final loaded = LoadedRuntime.fromWire((reply as LoadedReply).runtime);
      expect(loaded.backend, 'gpu');
      expect(loaded.loadMillis, 4200);
      expect(runtime.loadedWith?.modelPath, '/models/gemma.litertlm');
    });

    test('an Error thrown by the runtime comes back as a stateful failure', () async {
      // Native load failures do not arrive as Exceptions. If the loop only caught
      // Exception, this would escape, `errorsAreFatal` would kill the worker, and
      // the caller would see "worker exited" instead of the reason.
      final worker = startWorker(
        _ScriptedRuntime(loadError: StateError('no such file')),
      );
      addTearDown(worker.shutdown);

      final reply =
          await worker.request(LoadRequest(config.toWire())) as FailureReply;

      expect(reply.message, contains('no such file'));
      // Stateful: nothing is resident, so the caller must reload rather than retry a
      // turn against an engine that does not exist.
      expect(reply.stateful, isTrue);
    });

    test(
      'the loop survives a failed load and can serve the next request',
      () async {
        final worker = startWorker(
          _ScriptedRuntime(loadError: StateError('transient')),
        );

        await worker.request(LoadRequest(config.toWire()));
        // A worker that died on the failed load could not answer this.
        expect(
          await worker.request(const ShutdownRequest()),
          isA<ShutdownReply>(),
        );
        await worker.served;
      },
    );
  });

  group('generate', () {
    test('streams the runtime events in order and terminates', () async {
      final worker = startWorker(
        _ScriptedRuntime(
          turns: [
            const [
              LlmToken('Diag'),
              LlmToken('nosed'),
              LlmToolCall(
                name: 'get_local_parts_inventory',
                arguments: {'sku': 'BRK-990-XP'},
              ),
              LlmDone(),
            ],
          ],
        ),
      );
      addTearDown(worker.shutdown);

      final events = await worker.runTurn(
        const GenerateRequest(turnId: 1, prompt: 'E-102'),
      );

      expect(events, hasLength(4));
      expect((events[0] as EventReply).event, const LlmToken('Diag'));
      expect((events[1] as EventReply).event, const LlmToken('nosed'));
      final call = (events[2] as EventReply).event as LlmToolCall;
      expect(call.name, 'get_local_parts_inventory');
      expect(call.arguments['sku'], 'BRK-990-XP');
      expect((events[3] as EventReply).event, isA<LlmDone>());
    });

    test('the prompt and tools reach the runtime unchanged', () async {
      final runtime = _ScriptedRuntime(
        turns: [
          const [LlmDone()],
        ],
      );
      final worker = startWorker(runtime);
      addTearDown(worker.shutdown);

      await worker.runTurn(
        const GenerateRequest(
          turnId: 1,
          prompt: '[MANUAL DOCUMENT]\nE-102',
          tools: [
            ToolDefinition(
              name: 'get_local_parts_inventory',
              description: 'stock',
              parameters: {
                'type': 'object',
                'properties': {
                  'sku': {'type': 'string'},
                },
              },
            ),
          ],
        ),
      );

      expect(runtime.lastPrompt, '[MANUAL DOCUMENT]\nE-102');
      expect(runtime.lastTools.single.name, 'get_local_parts_inventory');
      // The schema has to survive the hop, or the model is shown an argument-less
      // tool.
      expect((runtime.lastTools.single.parameters['properties']! as Map).keys, [
        'sku',
      ]);
    });

    test('a runtime error mid-turn is reported as a turn-scoped failure', () async {
      final worker = startWorker(
        _ScriptedRuntime(
          turns: [
            const [LlmToken('Diag')],
          ],
          generateError: StateError('decode failed'),
        ),
      );
      addTearDown(worker.shutdown);

      final events = await worker.runTurn(
        const GenerateRequest(turnId: 1, prompt: 'x'),
      );

      expect((events.first as EventReply).event, const LlmToken('Diag'));
      final failure = events.last as FailureReply;
      expect(failure.message, contains('decode failed'));
      // Turn-scoped: a failed decode says nothing about whether the weights are
      // still resident, and declaring the engine lost would cost a needless reload.
      expect(failure.stateful, isFalse);
    });

    test(
      'a stream that ends without LlmDone is reported, not left hanging',
      () async {
        // The host closes a turn on `LlmDone` or a failure. A runtime that ended
        // without either would leave the caller waiting on a model that has already
        // stopped, so the loop turns that into an explicit failure rather than
        // synthesising a `done` that would hide the bug.
        final worker = startWorker(
          _ScriptedRuntime(
            turns: [
              const [LlmToken('Diag')],
            ],
          ),
        );
        addTearDown(worker.shutdown);

        final events = await worker.runTurn(
          const GenerateRequest(turnId: 1, prompt: 'x'),
        );

        expect((events.last as FailureReply).message, contains('LlmDone'));
      },
    );

    test('an overlapping turn is refused rather than queued', () async {
      // Inference is serialised on device, so a queued turn would silently inherit
      // the delay of the one ahead of it; the agent loop needs to be told instead.
      final runtime = _ScriptedRuntime(turns: [const [], const []]);
      final worker = startWorker(runtime);
      addTearDown(worker.shutdown);

      final first = worker.turn(const GenerateRequest(turnId: 1, prompt: 'a'));
      // Let the first turn register before the second arrives.
      await pumpEventQueue();
      final second = worker.turn(const GenerateRequest(turnId: 2, prompt: 'b'));
      // And let the loop *answer* the second while the first is genuinely still
      // running. Without this pump the first turn would finish first and the second
      // would legitimately be accepted — which is the sequencing mistake this
      // comment exists to stop the next reader from re-introducing.
      await pumpEventQueue();

      expect(
        (await second).whereType<FailureReply>().single.message,
        contains('serialised'),
      );
      // The refused turn must not have disturbed the running one.
      expect(runtime.lastPrompt, 'a');

      runtime.emit(const LlmDone());
      await runtime.finishTurn();
      expect((await first).last, isA<EventReply>());
    });
  });

  group('stop', () {
    test('is handled while a turn is still generating', () async {
      // The reason generation is not awaited inside the message loop: if it were,
      // the loop would be deaf to the stop until the turn it is meant to stop had
      // already finished.
      final runtime = _ScriptedRuntime(turns: [const []]);
      final worker = startWorker(runtime);
      addTearDown(worker.shutdown);

      final turn = worker.turn(const GenerateRequest(turnId: 1, prompt: 'a'));
      await pumpEventQueue();
      expect(runtime.stopCount, 0);

      worker.send(const StopRequest(1));
      await pumpEventQueue();

      expect(
        runtime.stopCount,
        1,
        reason: 'the stop must not wait for the turn',
      );

      runtime.emit(const LlmDone());
      await runtime.finishTurn();
      await turn;
    });

    test('a stale turn id does not stop the turn that is running', () async {
      // A stop racing the end of turn N must not cancel N+1 — the user would
      // experience that as a question that got no answer.
      final runtime = _ScriptedRuntime(turns: [const []]);
      final worker = startWorker(runtime);
      addTearDown(worker.shutdown);

      final turn = worker.turn(const GenerateRequest(turnId: 7, prompt: 'a'));
      await pumpEventQueue();

      worker.send(const StopRequest(6));
      await pumpEventQueue();

      expect(runtime.stopCount, 0);

      runtime.emit(const LlmDone());
      await runtime.finishTurn();
      await turn;
    });

    test('a stop with no turn in flight is a no-op', () async {
      final runtime = _ScriptedRuntime();
      final worker = startWorker(runtime);
      addTearDown(worker.shutdown);

      worker.send(const StopRequest(1));
      await pumpEventQueue();

      expect(runtime.stopCount, 0);
    });
  });

  group('shutdown', () {
    test('closes the runtime, acknowledges, and ends the loop', () async {
      final runtime = _ScriptedRuntime();
      final worker = startWorker(runtime);

      expect(
        await worker.request(const ShutdownRequest()),
        isA<ShutdownReply>(),
      );
      // The loop returning is what lets the isolate's entry point return and the
      // isolate exit; without it the worker would linger holding the model.
      await worker.served;
      expect(runtime.closed, isTrue);
    });

    test('stops a running turn before closing the model', () async {
      // Deleting the native engine while it is still decoding is a crash rather
      // than an exit.
      final runtime = _ScriptedRuntime(turns: [const []]);
      final worker = startWorker(runtime);

      worker.turn(const GenerateRequest(turnId: 1, prompt: 'a')).ignore();
      await pumpEventQueue();

      worker.send(const ShutdownRequest());
      await pumpEventQueue();

      expect(runtime.stopCount, 1);
      runtime.emit(const LlmDone());
      await runtime.finishTurn();
      await worker.served;
      expect(runtime.closed, isTrue);
    });
  });

  group('malformed commands', () {
    test('a command that is not a [request, port] pair is ignored', () async {
      final worker = startWorker(_ScriptedRuntime());
      addTearDown(worker.shutdown);

      worker.sendRaw('nonsense');
      worker.sendRaw([1, 2, 3]);
      worker.sendRaw([
        <String, Object?>{kindKey: 'embed'},
        null,
      ]);
      await pumpEventQueue();

      // Still serving: a bad message must not take the worker down with it.
      expect(
        await worker.request(const ShutdownRequest()),
        isA<ShutdownReply>(),
      );
    });
  });
}

/// Test-side handle on a running [serveInferenceRequests] loop.
class _Worker {
  _Worker(this._commands, this.served);

  final SendPort _commands;

  /// Completes when the loop returns, i.e. after a shutdown.
  final Future<void> served;

  void send(InferenceRequest request) =>
      _commands.send([request.toWire(), null]);

  void sendRaw(Object? message) => _commands.send(message);

  /// Sends a request and awaits its single reply.
  Future<InferenceReply> request(InferenceRequest request) async {
    final port = ReceivePort();
    try {
      _commands.send([request.toWire(), port.sendPort]);
      return InferenceReply.fromWire(
        (await port.first as Map).cast<String, Object?>(),
      );
    } finally {
      port.close();
    }
  }

  /// Collects every reply of one turn, up to and including its terminal message.
  Future<List<InferenceReply>> turn(GenerateRequest request) async {
    final port = ReceivePort();
    final replies = <InferenceReply>[];
    _commands.send([request.toWire(), port.sendPort]);
    await for (final raw in port) {
      final reply = InferenceReply.fromWire(
        (raw as Map).cast<String, Object?>(),
      );
      replies.add(reply);
      final terminal =
          reply is FailureReply ||
          (reply is EventReply && reply.event is LlmDone);
      if (terminal) break;
    }
    port.close();
    return replies;
  }

  /// [turn], for a runtime whose events are already scripted.
  Future<List<InferenceReply>> runTurn(GenerateRequest request) =>
      turn(request);

  Future<void> shutdown() async {
    try {
      await request(
        const ShutdownRequest(),
      ).timeout(const Duration(seconds: 2));
    } on Object {
      // Already shut down, or wedged — either way the test is over.
    }
  }
}

/// An [InferenceRuntime] whose behaviour is scripted.
///
/// Turns can be pre-scripted (a fixed list of events) or driven live via [emit] and
/// [finishTurn], which is what makes the stop/overlap tests possible: they need a
/// turn that is genuinely still running while another message arrives.
class _ScriptedRuntime implements InferenceRuntime {
  _ScriptedRuntime({
    this.loaded = const LoadedRuntime(
      backend: 'cpu',
      loadMillis: 1,
      contextTokens: 1024,
    ),
    this.loadError,
    List<List<LlmEvent>>? turns,
    this.generateError,
  }) : _turns = [...?turns];

  final LoadedRuntime loaded;
  final Object? loadError;
  final Object? generateError;
  final List<List<LlmEvent>> _turns;

  InferenceConfig? loadedWith;
  String? lastPrompt;
  List<ToolDefinition> lastTools = const [];
  int stopCount = 0;
  bool closed = false;

  StreamController<LlmEvent>? _live;

  @override
  Future<LoadedRuntime> load(InferenceConfig config) async {
    loadedWith = config;
    final error = loadError;
    if (error != null) throw error;
    return loaded;
  }

  @override
  Stream<LlmEvent> generate({
    required String prompt,
    List<ToolDefinition> tools = const [],
  }) {
    lastPrompt = prompt;
    lastTools = tools;
    final scripted = _turns.isEmpty ? null : _turns.removeAt(0);
    // An empty script means "drive me from the test" — the events arrive through
    // [emit] and the turn ends at [finishTurn].
    if (scripted != null && scripted.isNotEmpty) {
      return _scriptedStream(scripted);
    }
    final controller = StreamController<LlmEvent>();
    _live = controller;
    return controller.stream;
  }

  Stream<LlmEvent> _scriptedStream(List<LlmEvent> events) async* {
    for (final event in events) {
      yield event;
    }
    final error = generateError;
    if (error != null) throw error;
  }

  /// Pushes an event into the turn currently being driven live.
  void emit(LlmEvent event) => _live?.add(event);

  /// Ends the live turn.
  Future<void> finishTurn() async {
    final controller = _live;
    _live = null;
    await controller?.close();
    await pumpEventQueue();
  }

  @override
  Future<void> stop() async {
    stopCount++;
  }

  @override
  Future<void> close() async {
    closed = true;
    await _live?.close();
    _live = null;
  }
}
