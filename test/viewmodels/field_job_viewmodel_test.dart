import 'dart:async';
import 'dart:io';

import 'package:field_ops_copilot/engines/fakes/fake_llm_engine.dart';
import 'package:field_ops_copilot/engines/llm_engine.dart';
import 'package:field_ops_copilot/engines/tool_schema.dart';
import 'package:field_ops_copilot/services/ai/agent_loop.dart';
import 'package:field_ops_copilot/services/ai/base_tool.dart';
import 'package:field_ops_copilot/services/ai/providers.dart';
import 'package:field_ops_copilot/services/ai/tool_call_guard.dart';
import 'package:field_ops_copilot/services/ai/tool_registry.dart';
import 'package:field_ops_copilot/services/ai/tools/get_parts_inventory_tool.dart';
import 'package:field_ops_copilot/services/database/database_initializer.dart';
import 'package:field_ops_copilot/services/database/database_service.dart';
import 'package:field_ops_copilot/services/database/providers.dart';
import 'package:field_ops_copilot/services/inference/engine_warmup_controller.dart';
import 'package:field_ops_copilot/services/inference/providers.dart';
import 'package:field_ops_copilot/viewmodels/field_job_viewmodel.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Unit-tier coverage for the diagnose viewmodel — TC-VM-STREAM-01 and everything
/// around it.
///
/// **Only the model is faked** — the golden suite's rule — and it is the reason these
/// tests are worth more than their length suggests: the database is real and seeded
/// from the shipped asset, and retrieval, compilation, the loop, the guard and the
/// registry are the production objects resolved through the production providers.
/// So a passing test here is a statement about the vertical slice, not about a mock
/// graph. `Aisle 4, Shelf B` is a value in `assets/elevator_manual_seed.json`.
///
/// The fake is reached by overriding `agentEngineProvider`, which is the only way
/// in — see that provider for why it does not fall back to the fake on its own.
/// What makes the substitution safe: `FakeLlmEngine` enforces every contract
/// `GemmaLlmEngine` does, at the same moment, so nothing here passes against a more
/// forgiving world than the device.
void main() {
  late Directory tempDir;
  late String shippedJson;

  setUpAll(() async {
    shippedJson = await File('assets/elevator_manual_seed.json').readAsString();
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('fieldops_field_job');
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  /// A container over a real seeded database and a fake engine scripted with
  /// [turns], warmed up unless [warmUp] is false.
  Future<ProviderContainer> containerOver(
    List<List<LlmEvent>> turns, {
    bool warmUp = true,
    LlmEngine? engine,
    AgentTool Function(DatabaseService database)? tool,
  }) async {
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) async {
          final database = DatabaseService.encrypted(
            file: File('${tempDir.path}/field_job.db'),
            encryptionKey: ref.watch(databaseEncryptionKeyProvider),
          );
          ref.onDispose(database.close);
          return database;
        }),
        seedOutcomeProvider.overrideWith((ref) async {
          final database = await ref.watch(appDatabaseProvider.future);
          return DatabaseInitializer(
            database: database,
            source: _TextSeedSource(shippedJson),
          ).ensureSeeded();
        }),
        agentEngineProvider.overrideWith(
          (ref) async => engine ?? FakeLlmEngine(turns: turns),
        ),
        if (tool != null)
          toolRegistryProvider.overrideWith(
            (ref) async => ToolRegistry([
              tool(await ref.watch(seededDatabaseProvider.future)),
            ]),
          ),
      ],
    );
    addTearDown(container.dispose);
    if (warmUp) {
      await container.read(engineWarmupControllerProvider.notifier).warmUp();
      expect(
        container.read(engineWarmupControllerProvider),
        isA<EngineReady>(),
        reason: 'the fixture itself must be sound before anything is asserted',
      );
    }
    return container;
  }

  /// Records every phase the viewmodel passes through, in order.
  List<FieldJobPhase> phasesOf(ProviderContainer container) {
    final phases = <FieldJobPhase>[];
    container.listen(fieldJobViewModelProvider, (previous, next) {
      if (previous?.phase != next.phase) phases.add(next.phase);
    }, fireImmediately: true);
    return phases;
  }

  LlmToolCall inventoryCall(String sku) => LlmToolCall(
    name: GetPartsInventoryTool.toolName,
    arguments: {GetPartsInventoryTool.skuParameter: sku},
  );

  group('TC-VM-STREAM-01 streaming state', () {
    // The AC, verbatim: "State transitions idle→thinking→done, text accumulates.
    // Assert state sequence + final text."
    test('idle → thinking → done, accumulating the tokens', () async {
      final container = await containerOver([
        const [
          LlmToken('Isolate the main power bus'),
          LlmToken(' and use your Lockout Tagout kit.'),
          LlmDone(),
        ],
      ]);
      final phases = phasesOf(container);

      await container
          .read(fieldJobViewModelProvider.notifier)
          .diagnose('cabin vibrating, E-102');

      expect(phases, [
        FieldJobPhase.idle,
        FieldJobPhase.thinking,
        FieldJobPhase.done,
      ]);
      final state = container.read(fieldJobViewModelProvider);
      expect(
        state.displayText,
        'Isolate the main power bus and use your Lockout Tagout kit.',
      );
      expect(state.isDiagnosis, isTrue);
      expect(state.stopReason, AgentStopReason.answered);
    });

    // The accumulation is asserted *during* the run rather than only at the end,
    // because a viewmodel that buffered every token and published once at
    // completion would satisfy the final-text assertion above and show a blank
    // panel for the whole 2.5-second generation. Tokens on screen as they arrive is
    // the thing being screen-recorded.
    test(
      'each token is published as it arrives, not buffered to the end',
      () async {
        final engine = _PacedEngine(const [
          LlmToken('Diag'),
          LlmToken('nosed'),
          LlmToken(' E-102.'),
          LlmDone(),
        ]);
        final container = await containerOver(const [], engine: engine);
        final seen = <String>[];
        container.listen(fieldJobViewModelProvider, (previous, next) {
          if (previous?.streamedText != next.streamedText) {
            seen.add(next.streamedText);
          }
        });

        final pending = container
            .read(fieldJobViewModelProvider.notifier)
            .diagnose('cabin vibrating, E-102');
        await engine.drain();
        await pending;

        expect(seen, ['Diag', 'Diagnosed', 'Diagnosed E-102.']);
      },
    );

    test('the inquiry is recorded trimmed, and retrieval is exposed', () async {
      final container = await containerOver([
        const [LlmToken('Answer.'), LlmDone()],
      ]);

      await container
          .read(fieldJobViewModelProvider.notifier)
          .diagnose('   cabin vibrating, E-102  ');

      final state = container.read(fieldJobViewModelProvider);
      expect(state.inquiry, 'cabin vibrating, E-102');
      expect(state.retrieval, isNotNull);
      expect(state.retrieval!.entryIds, contains('apex_9_err_102'));
    });

    // `retrieval` is set before the loop runs, so the "grounded in" line is on
    // screen while the answer is still being written rather than appearing with it.
    test('retrieval is visible before the first token', () async {
      final engine = _PacedEngine(const [LlmToken('Answer.'), LlmDone()]);
      final container = await containerOver(const [], engine: engine);

      final pending = container
          .read(fieldJobViewModelProvider.notifier)
          .diagnose('cabin vibrating, E-102');
      await engine.reachedFirstEvent;

      final mid = container.read(fieldJobViewModelProvider);
      expect(mid.phase, FieldJobPhase.thinking);
      expect(mid.retrieval, isNotNull);
      expect(mid.streamedText, isEmpty);

      await engine.drain();
      await pending;
    });
  });

  group('the tool-activity indicator', () {
    // The agent loop emits `AgentToolCallStarted` *before* the query is in flight
    // specifically so this is possible, and bound the same way there: block the
    // tool on a completer and look at the state while it is stuck.
    test('activeTool is set while the lookup runs and cleared after', () async {
      final gate = Completer<void>();
      final container = await containerOver(
        [
          [inventoryCall('BRK-990-XP'), const LlmDone()],
          const [LlmToken('2 units in Aisle 4, Shelf B.'), LlmDone()],
        ],
        tool: (database) =>
            _GatedInventoryTool(gate, GetPartsInventoryTool(database)),
      );

      final pending = container
          .read(fieldJobViewModelProvider.notifier)
          .diagnose('cabin vibrating, E-102');
      await pumpEventQueue();

      final mid = container.read(fieldJobViewModelProvider);
      expect(mid.activeTool, isNotNull);
      expect(mid.activeTool!.call.name, GetPartsInventoryTool.toolName);
      expect(mid.activeTool!.repeated, isFalse);
      expect(mid.invocations, isEmpty);

      gate.complete();
      await pending;

      final end = container.read(fieldJobViewModelProvider);
      expect(end.activeTool, isNull);
      expect(end.invocations, hasLength(1));
      expect(
        end.invocations.single.outcome.payload['aisle'],
        'Aisle 4, Shelf B',
      );
    });

    // **The end-of-run assertion above is not enough.** Dropping
    // `activeTool: null` from the `AgentToolCallCompleted` row left every
    // test green, because `AgentCompleted` clears it too — so the final state was
    // identical and the mask was total. What it changes is the *middle*: the
    // indicator would stay on "Checking inventory…" through the whole second turn,
    // while the answer streams underneath it. That is the most-watched three
    // seconds of the demo, describing work that finished.
    //
    // So the assertion is on the emitted sequence rather than the final state: at
    // the instant the invocation is recorded, nothing is in flight any more.
    test(
      'the indicator clears when the lookup completes, not when the run does',
      () async {
        final container = await containerOver([
          [
            const LlmToken('Checking the warehouse.'),
            inventoryCall('BRK-990-XP'),
            const LlmDone(),
          ],
          const [LlmToken('There are 2 units in Aisle 4, Shelf B.'), LlmDone()],
        ]);
        final emitted = <FieldJobState>[];
        container.listen(
          fieldJobViewModelProvider,
          (previous, next) => emitted.add(next),
        );

        await container
            .read(fieldJobViewModelProvider.notifier)
            .diagnose('cabin vibrating, E-102');

        final atCompletion = emitted.firstWhere(
          (s) => s.invocations.isNotEmpty,
        );
        expect(
          atCompletion.phase,
          FieldJobPhase.thinking,
          reason: 'the run must still be going, or this proves nothing new',
        );
        expect(atCompletion.activeTool, isNull);

        // And it stays clear for the rest of the run, so the second turn streams
        // with no indicator claiming a lookup is happening.
        final duringSecondTurn = emitted.where(
          (s) => s.phase == FieldJobPhase.thinking && s.invocations.isNotEmpty,
        );
        expect(duringSecondTurn, isNotEmpty);
        expect(duringSecondTurn.every((s) => s.activeTool == null), isTrue);
      },
    );

    // The live text is the *current* turn's. Without the reset at the turn
    // boundary the answer would arrive with the first turn's aside glued above it,
    // permanently.
    test(
      'a new turn replaces the visible text rather than appending',
      () async {
        final container = await containerOver([
          [
            const LlmToken('Let me check the warehouse.'),
            inventoryCall('BRK-990-XP'),
            const LlmDone(),
          ],
          const [LlmToken('There are 2 units in Aisle 4, Shelf B.'), LlmDone()],
        ]);

        await container
            .read(fieldJobViewModelProvider.notifier)
            .diagnose('cabin vibrating, E-102');

        final state = container.read(fieldJobViewModelProvider);
        expect(state.streamedText, 'There are 2 units in Aisle 4, Shelf B.');
        expect(state.streamedText, isNot(contains('Let me check')));
      },
    );

    // The consequence of the reset above, and the reason it is not just tidiness:
    // by the time the run ends the live text has already converged on the answer,
    // so settling from `streamedText` to `result.answer` is not a visible jump. A
    // viewmodel that accumulated across turns would flicker here.
    test('the live text has converged on the answer by completion', () async {
      final container = await containerOver([
        [
          const LlmToken('Checking.'),
          inventoryCall('BRK-990-XP'),
          const LlmDone(),
        ],
        const [LlmToken('  2 units, Aisle 4, Shelf B.  '), LlmDone()],
      ]);

      await container
          .read(fieldJobViewModelProvider.notifier)
          .diagnose('cabin vibrating, E-102');

      final state = container.read(fieldJobViewModelProvider);
      expect(state.streamedText.trim(), state.result!.answer);
      expect(state.displayText, state.result!.answer);
    });

    // `arguments` as a bare string rather than an object, which is
    // `GuardFailureReason.argumentsUnreadable` — a refusal, as opposed to
    // `arguments: {}`, which is a perfectly readable *empty* map and reaches
    // `dispatch` as a `missing_parameter` failure instead. The distinction is Task
    // 1.6's and it is the reason this fixture is shaped the way it is.
    test('a refused call attempt is recorded for the activity log', () async {
      final container = await containerOver([
        const [
          LlmToken(
            '{"tool": "get_local_parts_inventory", "arguments": "BRK-990-XP"}',
          ),
          LlmDone(),
        ],
        const [LlmToken('I need the SKU from the manual.'), LlmDone()],
      ]);

      await container
          .read(fieldJobViewModelProvider.notifier)
          .diagnose('cabin vibrating, E-102');

      final state = container.read(fieldJobViewModelProvider);
      expect(state.rejectedCalls, hasLength(1));
      expect(state.isDiagnosis, isTrue);
    });
  });

  group('all three stop reasons are distinguishable', () {
    // The gap the golden suite leaves open: `emptyResponse` has no golden, and this
    // screen is the thing that has to render all three. Each is asserted as a
    // *distinct* pair of (stopReason, isDiagnosis), because the loop already
    // authors non-empty text for all three — so "the answer is non-empty" cannot
    // tell them apart, and a screen that only checked that would render a report of
    // failure as advice.
    test('answered is a diagnosis', () async {
      final container = await containerOver([
        const [LlmToken('Replace the brake pads.'), LlmDone()],
      ]);

      await container
          .read(fieldJobViewModelProvider.notifier)
          .diagnose('cabin vibrating, E-102');

      final state = container.read(fieldJobViewModelProvider);
      expect(state.stopReason, AgentStopReason.answered);
      expect(state.isDiagnosis, isTrue);
      expect(state.displayText, 'Replace the brake pads.');
    });

    test('emptyResponse is not a diagnosis, and is not a blank panel', () async {
      final container = await containerOver([
        const [LlmDone()],
      ]);

      await container
          .read(fieldJobViewModelProvider.notifier)
          .diagnose('cabin vibrating, E-102');

      final state = container.read(fieldJobViewModelProvider);
      expect(state.phase, FieldJobPhase.done);
      expect(state.stopReason, AgentStopReason.emptyResponse);
      expect(state.isDiagnosis, isFalse);
      // The loop authors the text, so there is something to render. The property
      // that matters is that it is *not* empty — a blank panel is the failure
      // `AgentStopReason.emptyResponse` exists to prevent.
      expect(state.displayText, AgentLoop.emptyResponseMessage);
      expect(state.displayText, isNotEmpty);
    });

    test('iterationCapReached is not a diagnosis', () async {
      // Four turns, a different SKU each time, so the cap is what stops it rather
      // than the repeat short circuit — the distinction the `iteration_cap`
      // golden makes, borrowed here.
      final container = await containerOver([
        [inventoryCall('BRK-990-XP'), const LlmDone()],
        [inventoryCall('FLT-440-HYD'), const LlmDone()],
        [inventoryCall('BELT-330-DRV'), const LlmDone()],
        [inventoryCall('BRK-990-ZZ'), const LlmDone()],
      ]);

      await container
          .read(fieldJobViewModelProvider.notifier)
          .diagnose('cabin vibrating, E-102');

      final state = container.read(fieldJobViewModelProvider);
      expect(state.phase, FieldJobPhase.done);
      expect(state.stopReason, AgentStopReason.iterationCapReached);
      expect(state.isDiagnosis, isFalse);
      expect(state.displayText, AgentLoop.iterationCapMessage);
      expect(state.activeTool, isNull);
    });

    // The three render differently only because `isDiagnosis` distinguishes them.
    // Asserted as one statement so the property is bound in one place rather than
    // inferred from the three tests above passing.
    test('exactly one of the three reads as a diagnosis', () async {
      final outcomes = <AgentStopReason, bool>{};
      for (final scenario in [
        (
          AgentStopReason.answered,
          [
            const [LlmToken('Answer.'), LlmDone()],
          ],
        ),
        (
          AgentStopReason.emptyResponse,
          [
            const [LlmDone()],
          ],
        ),
        (
          AgentStopReason.iterationCapReached,
          [
            [inventoryCall('BRK-990-XP'), const LlmDone()],
            [inventoryCall('FLT-440-HYD'), const LlmDone()],
            [inventoryCall('BELT-330-DRV'), const LlmDone()],
            [inventoryCall('BRK-990-ZZ'), const LlmDone()],
          ],
        ),
      ]) {
        final container = await containerOver(scenario.$2);
        await container
            .read(fieldJobViewModelProvider.notifier)
            .diagnose('cabin vibrating, E-102');
        final state = container.read(fieldJobViewModelProvider);
        expect(state.stopReason, scenario.$1);
        outcomes[state.stopReason!] = state.isDiagnosis;
      }

      expect(outcomes, {
        AgentStopReason.answered: true,
        AgentStopReason.emptyResponse: false,
        AgentStopReason.iterationCapReached: false,
      });
    });
  });

  group('refusals and failures', () {
    test('a blank inquiry does nothing at all', () async {
      final container = await containerOver([
        const [LlmToken('should never run'), LlmDone()],
      ]);
      final phases = phasesOf(container);

      await container.read(fieldJobViewModelProvider.notifier).diagnose('   ');

      expect(phases, [FieldJobPhase.idle]);
      expect(container.read(fieldJobViewModelProvider).inquiry, isEmpty);
    });

    // Both engines refuse an overlapping `generate` with a `StateError`, so this
    // guard is the difference between a wasted tap and a crash. The fake refuses it
    // too — it is deliberately no laxer than the device — which is exactly why
    // this can be tested here at all.
    test(
      'a second diagnose while one is running is ignored, not a crash',
      () async {
        final engine = _PacedEngine(const [LlmToken('Answer.'), LlmDone()]);
        final container = await containerOver(const [], engine: engine);
        final notifier = container.read(fieldJobViewModelProvider.notifier);

        final first = notifier.diagnose('cabin vibrating, E-102');
        await engine.reachedFirstEvent;
        await notifier.diagnose('door belt slipping, E-305');

        // The second call did not replace the first run's inquiry.
        expect(
          container.read(fieldJobViewModelProvider).inquiry,
          'cabin vibrating, E-102',
        );

        await engine.drain();
        await first;
        expect(
          container.read(fieldJobViewModelProvider).phase,
          FieldJobPhase.done,
        );
      },
    );

    test('diagnosing before warm-up reports which state it found', () async {
      final container = await containerOver(const [], warmUp: false);

      await container
          .read(fieldJobViewModelProvider.notifier)
          .diagnose('cabin vibrating, E-102');

      final state = container.read(fieldJobViewModelProvider);
      expect(state.phase, FieldJobPhase.failed);
      expect(state.failure, contains('has not started loading'));
      expect(state.isDiagnosis, isFalse);
      expect(state.displayText, isEmpty);
    });

    test(
      'no verified weights is reported as such, not as a loading model',
      () async {
        final container = ProviderContainer(
          overrides: [agentEngineProvider.overrideWith((ref) async => null)],
        );
        addTearDown(container.dispose);
        await container.read(engineWarmupControllerProvider.notifier).warmUp();

        await container
            .read(fieldJobViewModelProvider.notifier)
            .diagnose('cabin vibrating, E-102');

        expect(
          container.read(fieldJobViewModelProvider).failure,
          contains('No verified model weights'),
        );
      },
    );

    // An `Exception` from anywhere in the three lines is a message, not a crash.
    // The database is the realistic source (a key that stopped opening the file).
    test('an Exception during the run becomes a failed state', () async {
      final container = await containerOver(
        const [],
        engine: _ThrowingEngine(Exception('inference isolate died')),
      );

      await container
          .read(fieldJobViewModelProvider.notifier)
          .diagnose('cabin vibrating, E-102');

      final state = container.read(fieldJobViewModelProvider);
      expect(state.phase, FieldJobPhase.failed);
      expect(state.failure, contains('inference isolate died'));
      expect(state.activeTool, isNull);
    });

    // The rule `ToolRegistry.dispatch` writes down, one layer up: an `Error` means
    // the app is broken and must not be dressed as an operational message.
    test('an Error propagates rather than becoming a failed state', () async {
      final container = await containerOver(
        const [],
        engine: _ThrowingEngine(StateError('broken wiring')),
      );

      await expectLater(
        container
            .read(fieldJobViewModelProvider.notifier)
            .diagnose('cabin vibrating, E-102'),
        throwsA(isA<StateError>()),
      );
    });
  });

  // `applyEvent` is public so this one row can be bound: a refusal cannot coexist
  // with a tool in flight through `run`, so the only way to assert
  // `AgentToolCallRejected` leaves `activeTool` alone is to hand the fold both.
  group('applyEvent, for the rows run cannot reach', () {
    test('a rejection does not clear a tool in flight', () {
      const started = AgentToolCallStarted(
        call: LlmToolCall(name: GetPartsInventoryTool.toolName),
        source: GuardSource.nativeEvent,
        repeated: false,
      );
      final withTool = FieldJobViewModel.applyEvent(
        const FieldJobState(),
        started,
      );
      expect(withTool.activeTool, same(started));

      final after = FieldJobViewModel.applyEvent(
        withTool,
        const AgentToolCallRejected(
          GuardFailure(
            reason: GuardFailureReason.argumentsUnreadable,
            message: 'arguments were not a JSON object',
          ),
        ),
      );

      expect(
        after.activeTool,
        same(started),
        reason:
            'a refusal happens before dispatch, so nothing is in flight to '
            'clear — clearing here would imply otherwise',
      );
      expect(after.rejectedCalls, hasLength(1));
    });
  });
}

/// Seed source over an in-memory string. Same shape as `agent_loop_test.dart`'s.
class _TextSeedSource implements SeedSource {
  const _TextSeedSource(this._json);

  final String _json;

  @override
  String get seedId => AssetBundleSeedSource.defaultSeedId;

  @override
  Future<String> loadSeedJson() async => _json;
}

/// An engine that hands out its events one at a time, so a test can look at the
/// viewmodel *between* them.
///
/// Not a replacement for `FakeLlmEngine` — it wraps the lifecycle rules by
/// delegating `initialize`/`isReady`/`dispose` to one, and only the stream is
/// hand-paced. Pacing is the whole point: `FakeLlmEngine` replays a turn as fast as
/// the consumer drains it, which cannot express "the second token has not arrived
/// yet".
class _PacedEngine implements LlmEngine {
  _PacedEngine(this._events);

  final List<LlmEvent> _events;
  final FakeLlmEngine _lifecycle = FakeLlmEngine();
  final Completer<void> _firstEvent = Completer<void>();
  final List<Completer<void>> _gates = [];

  /// Completes once the consumer has asked for the first event.
  Future<void> get reachedFirstEvent => _firstEvent.future;

  /// Releases every event, in order.
  Future<void> drain() async {
    while (_gates.length < _events.length) {
      await pumpEventQueue();
      if (_gates.isNotEmpty && !_gates.last.isCompleted) _gates.last.complete();
    }
    for (final gate in _gates) {
      if (!gate.isCompleted) gate.complete();
    }
    await pumpEventQueue();
  }

  @override
  bool get isReady => _lifecycle.isReady;

  @override
  Future<void> initialize() => _lifecycle.initialize();

  @override
  Stream<LlmEvent> generate({
    required String prompt,
    List<ToolDefinition> tools = const [],
  }) {
    assertToolDefinitionsUsable(tools);
    return _paced();
  }

  Stream<LlmEvent> _paced() async* {
    for (final event in _events) {
      final gate = Completer<void>();
      _gates.add(gate);
      if (!_firstEvent.isCompleted) _firstEvent.complete();
      await gate.future;
      yield event;
    }
  }

  @override
  Future<void> dispose() => _lifecycle.dispose();
}

/// An engine whose `generate` throws [_error] at the call site.
class _ThrowingEngine implements LlmEngine {
  _ThrowingEngine(this._error);

  final Object _error;
  final FakeLlmEngine _lifecycle = FakeLlmEngine();

  @override
  bool get isReady => _lifecycle.isReady;

  @override
  Future<void> initialize() => _lifecycle.initialize();

  @override
  Stream<LlmEvent> generate({
    required String prompt,
    List<ToolDefinition> tools = const [],
  }) => throw _error;

  @override
  Future<void> dispose() => _lifecycle.dispose();
}

/// The real inventory tool, held open on a completer so the "checking inventory…"
/// state can be observed while the query is in flight. The agent-loop suite
/// blocks the tool the same way and for the same reason.
///
/// Delegates rather than stubs, so the payload the viewmodel records is the one the
/// seeded database actually produces — and [definition] forwards to the real one, so
/// what is declared to the engine is unchanged. Both fields are `final`, which is
/// what makes `definition` **stable** in the sense `AgentTool` requires: the
/// registry snapshots its dispatch map from it once and re-reads it per access
/// elsewhere.
class _GatedInventoryTool extends AgentTool {
  _GatedInventoryTool(this._gate, this._inner);

  final Completer<void> _gate;
  final GetPartsInventoryTool _inner;

  @override
  ToolDefinition get definition => _inner.definition;

  @override
  Future<Map<String, Object?>> execute(Map<String, Object?> arguments) async {
    await _gate.future;
    return _inner.execute(arguments);
  }
}
