import 'dart:async';

import 'package:field_ops_copilot/engines/impl/gemma_llm_engine.dart';
import 'package:field_ops_copilot/engines/llm_engine.dart';
import 'package:field_ops_copilot/services/inference/inference_config.dart';
import 'package:field_ops_copilot/services/inference/inference_isolate.dart';
import 'package:flutter_test/flutter_test.dart';

/// The engine's *contract* — when it is ready, what happens to a turn requested too
/// early, what disposal guarantees — is app logic, and app logic should not need a
/// 2.6GB model to verify. So the engine takes an [InferenceHost] and this suite
/// scripts one. The device tests then only have to prove the parts a device owns.
void main() {
  const config = InferenceConfig(modelPath: '/models/gemma.litertlm');

  group('initialize', () {
    test('is not ready until the load completes', () async {
      final host = _ScriptedHost(startDelay: Completer<void>());
      final engine = GemmaLlmEngine(config: config, host: host);

      final initializing = engine.initialize();
      await pumpEventQueue();
      // A model that is still loading must not read as ready: a "Diagnose" tap here
      // would reach an engine with no weights resident.
      expect(engine.isReady, isFalse);

      host.startDelay!.complete();
      await initializing;

      expect(engine.isReady, isTrue);
    });

    test('exposes what the runtime reported', () async {
      final engine = GemmaLlmEngine(
        config: config,
        host: _ScriptedHost(
          loaded: const LoadedRuntime(
            backend: 'gpu',
            loadMillis: 4200,
            contextTokens: 2048,
          ),
        ),
      );

      await engine.initialize();

      // These are the numbers the spike exists to produce; a measurement nothing
      // can read is one nobody will check.
      expect(engine.runtime?.backend, 'gpu');
      expect(engine.runtime?.loadMillis, 4200);
      expect(engine.runtime?.contextTokens, 2048);
    });

    test('two overlapping calls share one model load', () async {
      // Loading 2.6GB twice either doubles the resident footprint or fails. The
      // readiness banner and a Diagnose tap can both want the engine at once, so
      // this is a real path, not a hypothetical one.
      final host = _ScriptedHost(startDelay: Completer<void>());
      final engine = GemmaLlmEngine(config: config, host: host);

      final first = engine.initialize();
      final second = engine.initialize();
      await pumpEventQueue();
      host.startDelay!.complete();
      await Future.wait([first, second]);

      expect(host.startCount, 1);
    });

    test('a second call after a completed load does no work', () async {
      final host = _ScriptedHost();
      final engine = GemmaLlmEngine(config: config, host: host);

      await engine.initialize();
      await engine.initialize();

      expect(host.startCount, 1);
    });

    test('passes the configuration through to the host', () async {
      final host = _ScriptedHost();
      final engine = GemmaLlmEngine(
        config: config.copyWith(
          family: GemmaModelFamily.gemma3,
          contextTokens: 4096,
        ),
        host: host,
      );

      await engine.initialize();

      expect(host.startedWith?.family, GemmaModelFamily.gemma3);
      expect(host.startedWith?.contextTokens, 4096);
      expect(host.startedWith?.modelPath, config.modelPath);
    });

    test('a load failure leaves the engine not ready and propagates', () async {
      final engine = GemmaLlmEngine(
        config: config,
        host: _ScriptedHost(
          startError: const InferenceFailure(
            'model load failed: no such file',
            enginePresumedLost: true,
          ),
        ),
      );

      await expectLater(engine.initialize(), throwsA(isA<InferenceFailure>()));
      // Silently staying "not ready" would be as bad as claiming ready: the caller
      // has to learn *why*, because "no such file" is a provisioning problem and
      // nothing about the engine will fix it.
      expect(engine.isReady, isFalse);
    });

    test('a failed load can be retried', () async {
      // The in-flight future must not be cached past its failure, or a transient
      // failure would poison the engine for the life of the app.
      final host = _ScriptedHost(
        startError: const InferenceFailure('transient'),
      );
      final engine = GemmaLlmEngine(config: config, host: host);

      await expectLater(engine.initialize(), throwsA(isA<InferenceFailure>()));
      host.startError = null;
      await engine.initialize();

      expect(engine.isReady, isTrue);
      expect(host.startCount, 2);
    });
  });

  group('generate', () {
    test('streams the host events through unchanged', () async {
      final host = _ScriptedHost(
        turn: const [
          LlmToken('Diag'),
          LlmToolCall(
            name: 'get_local_parts_inventory',
            arguments: {'sku': 'BRK-990-XP'},
          ),
          LlmDone(),
        ],
      );
      final engine = GemmaLlmEngine(config: config, host: host);
      await engine.initialize();

      final events = await engine.generate(prompt: 'E-102').toList();

      expect(events, hasLength(3));
      expect(events.first, const LlmToken('Diag'));
      expect(events[1], isA<LlmToolCall>());
      expect(events.last, isA<LlmDone>());
    });

    test('before initialize it throws, exactly as the fake does', () {
      // The agent loop is written against one contract and unit-tested against
      // FakeLlmEngine; a real engine that returned an empty stream here instead of
      // throwing would make that test a lie.
      final engine = GemmaLlmEngine(config: config, host: _ScriptedHost());
      expect(
        () => engine.generate(prompt: 'E-102'),
        throwsA(isA<StateError>()),
      );
    });

    test('passes the prompt and tools to the host', () async {
      final host = _ScriptedHost(turn: const [LlmDone()]);
      final engine = GemmaLlmEngine(config: config, host: host);
      await engine.initialize();

      await engine
          .generate(
            prompt: '[MANUAL DOCUMENT]\nE-102',
            tools: const [
              ToolDefinition(
                name: 'get_local_parts_inventory',
                description: 'x',
              ),
            ],
          )
          .toList();

      expect(host.lastPrompt, '[MANUAL DOCUMENT]\nE-102');
      expect(host.lastTools.single.name, 'get_local_parts_inventory');
    });

    test('a host failure surfaces as a stream error', () async {
      final engine = GemmaLlmEngine(
        config: config,
        host: _ScriptedHost(turnError: const InferenceFailure('decode failed')),
      );
      await engine.initialize();

      await expectLater(
        engine.generate(prompt: 'E-102'),
        emitsError(isA<InferenceFailure>()),
      );
      // A turn-scoped failure must not un-ready the engine: the weights are still
      // resident and the next question should not pay for a reload.
      expect(engine.isReady, isTrue);
    });
  });

  group('dispose', () {
    test('shuts the host down and stops reporting ready', () async {
      final host = _ScriptedHost();
      final engine = GemmaLlmEngine(config: config, host: host);
      await engine.initialize();

      await engine.dispose();

      expect(host.shutdownCount, 1);
      expect(engine.isReady, isFalse);
    });

    test('is idempotent', () async {
      // Riverpod's `onDispose` and an explicit teardown can both fire; a second
      // shutdown of a killed isolate is not something to throw over.
      final host = _ScriptedHost();
      final engine = GemmaLlmEngine(config: config, host: host);
      await engine.initialize();

      await engine.dispose();
      await engine.dispose();

      expect(host.shutdownCount, 1);
    });

    test('a dispose racing a load still tears the host down', () async {
      // Otherwise the worker finishes loading into a void and holds gigabytes for
      // the life of the process.
      final host = _ScriptedHost(startDelay: Completer<void>());
      final engine = GemmaLlmEngine(config: config, host: host);

      final initializing = engine.initialize().then<void>(
        (_) {},
        onError: (_) {},
      );
      final disposing = engine.dispose();
      host.startDelay!.complete();
      await disposing;
      await initializing;

      expect(host.shutdownCount, 1);
      expect(engine.isReady, isFalse);
    });

    test('a dispose racing a *failing* load does not throw out of dispose', () async {
      final host = _ScriptedHost(
        startDelay: Completer<void>(),
        startError: const InferenceFailure('load blew up'),
      );
      final engine = GemmaLlmEngine(config: config, host: host);

      // The error handler is attached at creation, not after the await below: the
      // load fails while `disposing` is still in flight, and a handler attached
      // later would arrive after the failure had already been reported as an
      // unhandled async error.
      final initializing = engine.initialize().then<void>(
        (_) {},
        onError: (_) {},
      );
      final disposing = engine.dispose();
      host.startDelay!.complete();

      // dispose() is what teardown paths call; making it throw would mask the real
      // error with a second one from the cleanup.
      await expectLater(disposing, completes);
      await initializing;
      expect(host.shutdownCount, 1);
    });

    test('generate after dispose throws', () async {
      final engine = GemmaLlmEngine(config: config, host: _ScriptedHost());
      await engine.initialize();
      await engine.dispose();

      expect(() => engine.generate(prompt: 'x'), throwsA(isA<StateError>()));
    });

    test(
      'initialize after dispose throws rather than reviving the engine',
      () async {
        // The host is gone and its isolate was killed; quietly re-starting would hide
        // that the caller is holding a stale engine.
        final engine = GemmaLlmEngine(config: config, host: _ScriptedHost());
        await engine.initialize();
        await engine.dispose();

        await expectLater(engine.initialize(), throwsA(isA<StateError>()));
      },
    );
  });
}

/// An [InferenceHost] whose load and turn behaviour is scripted.
class _ScriptedHost implements InferenceHost {
  _ScriptedHost({
    this.loaded = const LoadedRuntime(
      backend: 'cpu',
      loadMillis: 1,
      contextTokens: 1024,
    ),
    this.startError,
    this.startDelay,
    this.turn = const [LlmDone()],
    this.turnError,
  });

  final LoadedRuntime loaded;
  Object? startError;

  /// When set, `start` waits on it — so a test can observe the engine mid-load.
  final Completer<void>? startDelay;

  final List<LlmEvent> turn;
  final Object? turnError;

  int startCount = 0;
  int shutdownCount = 0;
  InferenceConfig? startedWith;
  String? lastPrompt;
  List<ToolDefinition> lastTools = const [];

  @override
  Future<LoadedRuntime> start(InferenceConfig config) async {
    startCount++;
    startedWith = config;
    if (startDelay != null) await startDelay!.future;
    final error = startError;
    if (error != null) throw error;
    return loaded;
  }

  @override
  Stream<LlmEvent> generate({
    required String prompt,
    List<ToolDefinition> tools = const [],
  }) async* {
    lastPrompt = prompt;
    lastTools = tools;
    final error = turnError;
    if (error != null) throw error;
    for (final event in turn) {
      yield event;
    }
  }

  @override
  Future<void> shutdown() async {
    shutdownCount++;
  }
}
