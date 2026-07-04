import 'dart:async';

import 'package:field_ops_copilot/engines/fakes/fake_llm_engine.dart';
import 'package:field_ops_copilot/engines/llm_engine.dart';
import 'package:field_ops_copilot/services/inference/engine_warmup_controller.dart';
import 'package:field_ops_copilot/services/inference/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Unit-tier coverage for Task 1.11's third deferred wiring: loading the weights
/// before the UI needs to be interactive.
///
/// **What this suite can and cannot bind.** It can bind the state machine, the
/// ordering of `EngineLoading` against the load, idempotence, and every failure
/// branch. It cannot bind the property the whole design exists for — that the UI
/// isolate's 1445–1728ms stall lands while a *static* row is on screen rather than
/// an animated one — because there is no stall on the host. That splits two ways
/// and both halves are covered somewhere: the widget half (nothing animates in the
/// loading subtree) is in `test/views/diagnose_screen_test.dart`, and the device
/// half is `integration_test/demo_flow_test.dart`.
///
/// The engines here wrap `FakeLlmEngine` rather than replacing it, for the reason
/// Task 1.9's `_RecordingEngine` gives: Task 1.8 made the fake enforce every rule
/// the device engine does, at the same moment, and a hand-written stub silently
/// drops all of them.
void main() {
  /// A container in which [agentEngineProvider] resolves to [engine].
  ProviderContainer containerWith(LlmEngine? engine, {Object? resolveError}) {
    final container = ProviderContainer(
      overrides: [
        agentEngineProvider.overrideWith((ref) async {
          if (resolveError != null) throw resolveError;
          return engine;
        }),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  EngineWarmupController controllerOf(ProviderContainer container) =>
      container.read(engineWarmupControllerProvider.notifier);

  group('the happy path', () {
    test('starts idle', () {
      final container = containerWith(_GatedEngine());

      expect(container.read(engineWarmupControllerProvider), isA<EngineIdle>());
    });

    test('reaches ready, carrying the engine it loaded', () async {
      final engine = _GatedEngine();
      final container = containerWith(engine);

      await controllerOf(container).warmUp();

      final state = container.read(engineWarmupControllerProvider);
      expect(state, isA<EngineReady>());
      expect((state as EngineReady).engine, same(engine));
      expect(engine.initializeCalls, 1);
    });

    // The ordering the library doc argues for, asserted rather than described:
    // `EngineLoading` is set *before* the load is awaited, so the frame carrying
    // the static loading row is painted before the work that stalls the UI isolate
    // begins. Swap the two statements in `warmUp` and this fails.
    test('is EngineLoading while the load is in flight', () async {
      final engine = _GatedEngine()..gateInitialize();
      final container = containerWith(engine);

      final pending = controllerOf(container).warmUp();
      // One microtask drain is enough to get past `agentEngineProvider`'s await
      // and into `initialize()`, which is gated open.
      await pumpEventQueue();

      expect(
        container.read(engineWarmupControllerProvider),
        isA<EngineLoading>(),
      );

      engine.openGate();
      await pending;

      expect(
        container.read(engineWarmupControllerProvider),
        isA<EngineReady>(),
      );
    });

    // The caller is a widget's `initState`, and widgets are rebuilt. A second call
    // must not load 2.6GB again.
    test('a second call during the load does not load twice', () async {
      final engine = _GatedEngine()..gateInitialize();
      final container = containerWith(engine);
      final controller = controllerOf(container);

      final first = controller.warmUp();
      await pumpEventQueue();
      final second = controller.warmUp();

      engine.openGate();
      await Future.wait([first, second]);

      expect(engine.initializeCalls, 1);
    });

    test('a call after ready does not load again', () async {
      final engine = _GatedEngine();
      final container = containerWith(engine);
      final controller = controllerOf(container);

      await controller.warmUp();
      await controller.warmUp();

      expect(engine.initializeCalls, 1);
    });

    // An engine that survived a controller rebuild is already loaded. Calling
    // `initialize()` on it would spend seconds and gigabytes reaching the state it
    // is in — and `GemmaLlmEngine.initialize` on a live runtime is not a documented
    // no-op, so this is a correctness question as well as a cost one.
    test('an already-initialised engine is adopted, not reloaded', () async {
      final engine = _GatedEngine();
      await engine.initialize();
      final container = containerWith(engine);

      await controllerOf(container).warmUp();

      expect(
        container.read(engineWarmupControllerProvider),
        isA<EngineReady>(),
      );
      expect(engine.initializeCalls, 1, reason: 'the one call was the test\'s');
    });
  });

  group('nothing to load', () {
    // No verified weights is not an error: `ModelReadinessBanner` already names
    // which of "not installed" / "needs verification" / "source not configured"
    // applies and offers the action, so a second vaguer message above it would be
    // noise. Asserted as a distinct type rather than a message, because the screen
    // branches on the type.
    test('a null engine is Unavailable rather than Failed', () async {
      final container = containerWith(null);

      await controllerOf(container).warmUp();

      expect(
        container.read(engineWarmupControllerProvider),
        isA<EngineUnavailable>(),
      );
    });

    // Unavailable is not terminal: the operator can provision weights while the
    // screen is open, and a successful provision invalidates
    // `modelInstallStatusProvider`, so the next `warmUp` sees a different engine.
    test('warming up again after Unavailable retries', () async {
      final engine = _GatedEngine();
      var resolved = 0;
      final container = ProviderContainer(
        overrides: [
          agentEngineProvider.overrideWith(
            (ref) async => resolved++ == 0 ? null : engine,
          ),
        ],
      );
      addTearDown(container.dispose);
      final controller = controllerOf(container);

      await controller.warmUp();
      expect(
        container.read(engineWarmupControllerProvider),
        isA<EngineUnavailable>(),
      );

      // A real provision invalidates the status provider, which rebuilds the
      // engine provider; invalidating directly is the same edge without the 2.6GB.
      container.invalidate(agentEngineProvider);
      await controller.warmUp();

      expect(
        container.read(engineWarmupControllerProvider),
        isA<EngineReady>(),
      );
    });
  });

  group('failures', () {
    test('an engine that throws on initialize reports Failed', () async {
      final container = containerWith(
        _GatedEngine(initializeError: Exception('no metal device')),
      );

      await controllerOf(container).warmUp();

      final state = container.read(engineWarmupControllerProvider);
      expect(state, isA<EngineFailed>());
      expect((state as EngineFailed).message, contains('no metal device'));
    });

    test('a provider that cannot resolve the engine reports Failed', () async {
      final container = containerWith(
        null,
        resolveError: Exception('unreadable support directory'),
      );

      await controllerOf(container).warmUp();

      final state = container.read(engineWarmupControllerProvider);
      expect(state, isA<EngineFailed>());
      expect(
        (state as EngineFailed).message,
        contains('unreadable support directory'),
      );
    });

    // The one branch that exists because `initialize()` returning without throwing
    // is the engine's *claim*, while `isReady` is the interface's answer to the
    // question `AgentLoop.run` actually asks. Getting this wrong does not produce a
    // message, it produces a `StateError` on the tap being screen-recorded.
    test(
      'an engine that loads but is not ready reports Failed, not Ready',
      () async {
        final container = containerWith(
          _GatedEngine(readyAfterInitialize: false),
        );

        await controllerOf(container).warmUp();

        final state = container.read(engineWarmupControllerProvider);
        expect(state, isA<EngineFailed>());
        expect(
          (state as EngineFailed).message,
          contains('not ready to generate'),
        );
      },
    );

    test('warming up again after Failed retries', () async {
      var attempt = 0;
      final good = _GatedEngine();
      final container = ProviderContainer(
        overrides: [
          agentEngineProvider.overrideWith((ref) async {
            if (attempt++ == 0) throw Exception('first attempt');
            return good;
          }),
        ],
      );
      addTearDown(container.dispose);
      final controller = controllerOf(container);

      await controller.warmUp();
      expect(
        container.read(engineWarmupControllerProvider),
        isA<EngineFailed>(),
      );

      container.invalidate(agentEngineProvider);
      await controller.warmUp();

      expect(
        container.read(engineWarmupControllerProvider),
        isA<EngineReady>(),
      );
    });

    // An `Error` is an app defect, not a device that is not ready. Reporting it as
    // "the model failed to load" would put a plausible operational message over a
    // bug — the reason `ToolRegistry.dispatch` catches `on Exception` and not
    // `on Object`, one layer up.
    test('an Error propagates rather than becoming a Failed state', () async {
      final container = containerWith(
        _GatedEngine(initializeError: StateError('broken wiring')),
      );

      await expectLater(
        controllerOf(container).warmUp(),
        throwsA(isA<StateError>()),
      );
    });
  });
}

/// A [FakeLlmEngine] whose `initialize()` can be held open, made to throw, or made
/// to finish without becoming ready.
///
/// Delegates rather than reimplements: everything except the lifecycle knobs is the
/// real fake, so the rules Task 1.8 put there still apply.
class _GatedEngine implements LlmEngine {
  _GatedEngine({this.initializeError, this.readyAfterInitialize = true});

  final FakeLlmEngine _inner = FakeLlmEngine(
    turns: [
      const [LlmToken('ok'), LlmDone()],
    ],
  );

  /// Thrown from [initialize] instead of delegating.
  final Object? initializeError;

  /// When false, [initialize] succeeds and [isReady] stays false — the state the
  /// warm-up controller has to notice.
  final bool readyAfterInitialize;

  Completer<void>? _gate;
  int initializeCalls = 0;

  /// Makes the next [initialize] block until [openGate].
  void gateInitialize() => _gate = Completer<void>();

  void openGate() => _gate?.complete();

  @override
  bool get isReady => readyAfterInitialize && _inner.isReady;

  @override
  Future<void> initialize() async {
    initializeCalls++;
    if (_gate != null) await _gate!.future;
    if (initializeError != null) throw initializeError!;
    await _inner.initialize();
  }

  @override
  Stream<LlmEvent> generate({
    required String prompt,
    List<ToolDefinition> tools = const [],
  }) => _inner.generate(prompt: prompt, tools: tools);

  @override
  Future<void> dispose() => _inner.dispose();
}
