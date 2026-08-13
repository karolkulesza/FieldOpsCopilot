import 'dart:io';

import 'package:field_ops_copilot/app.dart';
import 'package:field_ops_copilot/engines/fakes/fake_llm_engine.dart';
import 'package:field_ops_copilot/engines/llm_engine.dart';
import 'package:field_ops_copilot/services/ai/agent_loop.dart';
import 'package:field_ops_copilot/services/ai/base_tool.dart';
import 'package:field_ops_copilot/services/ai/tool_call_guard.dart';
import 'package:field_ops_copilot/services/ai/tools/get_parts_inventory_tool.dart';
import 'package:field_ops_copilot/services/database/database_initializer.dart';
import 'package:field_ops_copilot/services/database/database_service.dart';
import 'package:field_ops_copilot/services/database/providers.dart';
import 'package:field_ops_copilot/services/database/seed_data.dart';
import 'package:field_ops_copilot/services/inference/engine_warmup_controller.dart';
import 'package:field_ops_copilot/services/inference/providers.dart';
import 'package:field_ops_copilot/services/models/model_descriptor.dart';
import 'package:field_ops_copilot/services/models/model_storage.dart';
import 'package:field_ops_copilot/services/models/providers.dart';
import 'package:field_ops_copilot/services/rag/retrieval_router.dart';
import 'package:field_ops_copilot/viewmodels/field_job_viewmodel.dart';
import 'package:field_ops_copilot/views/diagnose_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Widget coverage for Task 1.11's demo screen.
///
/// **The suite is split in two, and the split is the important design decision
/// here.**
///
/// *Rendering* tests inject a `FieldJobState` and an `EngineWarmupState` directly
/// and assert what is drawn. They are synchronous and cannot flake. This is where
/// every state lives — including the ones a real run reaches only by luck (a tool
/// mid-flight, a refused call, an `emptyResponse` ending) and the one that cannot
/// be reached on a host at all (`EngineLoading` around a 1.5-second UI stall).
/// `field_job_viewmodel_test.dart` already proves the state machine produces these
/// states; there is no value in proving it twice through a widget.
///
/// *Wiring* tests run the real graph — real seeded database, real router,
/// compiler, loop, registry, only the model faked — and go through the button.
/// They prove the screen is connected to the thing the other suite tested.
///
/// The reason for the split is mechanical, not stylistic: a widget test's clock is
/// **faked**, so `pumpAndSettle` returns as soon as no frame is scheduled and
/// happily leaves a pending SQLite future unresolved. Real asynchronous work needs
/// `tester.runAsync` to get a slice of the real event loop ([settleRealAsync]
/// below). That is fine for a couple of end-to-end checks and a poor foundation for
/// twenty rendering assertions.
///
/// Three properties are worth more than the rest:
///
/// 1. **Nothing animates while the model works.** Task 1.8 measured the UI isolate
///    stalling 1445–1728ms during the load and dropping 5–8 frames while tokens
///    stream, so a progress indicator freezes or stutters exactly when it is being
///    watched — and a frozen indicator reads as a crash. Asserted structurally, by
///    walking the tree for `ProgressIndicator`, rather than by trusting the
///    screen's docstring.
/// 2. **The three stop reasons render as three different things.** The loop authors
///    truthful non-empty text for each, so a screen that drew them identically
///    would pass every other test while presenting "the assistant kept requesting
///    lookups" as a repair plan.
/// 3. **A startup failure is a rendered screen, not a thrown error.**
void main() {
  late Directory tempDir;
  late String shippedJson;

  setUpAll(() async {
    shippedJson = await File('assets/elevator_manual_seed.json').readAsString();
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('fieldops_diagnose_screen');
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  /// Every `ProgressIndicator` currently in the tree, anywhere.
  ///
  /// Deliberately unscoped. Scoping it to the diagnose subtree would exempt exactly
  /// the widget most likely to acquire one by accident, and the property being
  /// asserted is about the *screen* a technician is looking at.
  Finder progressIndicators() => find.byWidgetPredicate(
    (widget) => widget is ProgressIndicator,
    description: 'any ProgressIndicator',
  );

  /// Gives real asynchronous work — SQLite I/O, the agent loop — actual time to
  /// run, then turns the resulting state into frames.
  ///
  /// `pumpAndSettle` alone is not enough and the reason is worth stating, because
  /// the failure mode is a *silently* incomplete test: a widget test's `Timer`s and
  /// clock are faked, so `pumpAndSettle` advances the fake clock and stops the
  /// moment no frame is scheduled — which is true while a database future is still
  /// pending. `runAsync` escapes the fake-async zone for the duration of its
  /// callback, which is the only way the real event loop gets a slice.
  Future<void> settleRealAsync(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
  }

  // ---------------------------------------------------------------- rendering

  /// Pumps the screen with [job] and [warmup] injected, and no platform anything.
  ///
  /// `seedOutcomeProvider` is overridden to a resolved value so the startup-failure
  /// banner stays out of the way; the test that wants it overrides it back.
  /// Returns the container, so a test that needs the state to *change* can push a
  /// new one through the stub notifier.
  ///
  /// **Pumping a second `ProviderScope` with different `overrideWith` closures does
  /// not re-apply them** — the provider is already initialised, so the new create
  /// function is ignored and the tree keeps the first state. That silently broke
  /// three tests here (an outcome-panel loop, an icon loop and both scroll tests):
  /// each looked like a production defect and was a fixture defect. Changing state
  /// now goes through [pushJob], which is also the more faithful path, since a real
  /// screen sees a state change rather than a new tree.
  Future<ProviderContainer> pumpState(
    WidgetTester tester, {
    FieldJobState job = const FieldJobState(),
    EngineWarmupState warmup = const EngineReady(_InertEngine()),
    Object? startupError,
    ModelInstallStatus Function(String modelId)? installStatusOf,
  }) async {
    final container = ProviderContainer(
      overrides: [
        modelInstallStatusProvider.overrideWith(
          (ref, modelId) async =>
              installStatusOf?.call(modelId) ?? ModelInstallStatus.ready,
        ),
        seedOutcomeProvider.overrideWith((ref) async {
          if (startupError != null) throw startupError;
          return const SeedSkipped(storedRevision: 1, assetRevision: 1);
        }),
        engineWarmupControllerProvider.overrideWith(() => _StubWarmup(warmup)),
        fieldJobViewModelProvider.overrideWith(() => _StubViewModel(job)),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const FieldOpsApp(),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    return container;
  }

  /// Pushes a new [FieldJobState] into an already-pumped screen and rebuilds.
  Future<void> pushJob(
    WidgetTester tester,
    ProviderContainer container,
    FieldJobState job,
  ) async {
    (container.read(fieldJobViewModelProvider.notifier) as _StubViewModel).push(
      job,
    );
    await tester.pump();
    await tester.pumpAndSettle();
  }

  group('the engine status row', () {
    // The state in which the UI isolate is stalled for 1445-1728ms on the demo
    // device, which is why this is the single most important assertion in the file:
    // a spinner here freezes mid-rotation and reads as a crashed app.
    testWidgets('reports the load without animating anything', (tester) async {
      await pumpState(tester, warmup: const EngineLoading());

      expect(
        find.text('Loading model weights — this takes a few seconds'),
        findsOneWidget,
      );
      expect(progressIndicators(), findsNothing);
    });

    testWidgets('reports readiness', (tester) async {
      await pumpState(tester);

      expect(find.text('On-device model ready'), findsOneWidget);
    });

    // No verified weights is not an error and must not read as one: the banner
    // above already names which flavour it is and offers the action.
    testWidgets('says the agent cannot run when there are no weights', (
      tester,
    ) async {
      await pumpState(tester, warmup: const EngineUnavailable());

      expect(
        find.text('No verified weights on this device — the agent cannot run'),
        findsOneWidget,
      );
    });

    testWidgets('surfaces a load failure with its reason', (tester) async {
      await pumpState(
        tester,
        warmup: const EngineFailed('no Metal device available'),
      );

      expect(find.textContaining('no Metal device available'), findsOneWidget);
    });
  });

  group('the Diagnose button', () {
    testWidgets('is inert until something is typed', (tester) async {
      await pumpState(tester);

      expect(_button(tester).onPressed, isNull);

      await tester.enterText(
        find.byKey(DiagnoseKeys.inquiryField),
        'cabin vibrating, E-102',
      );
      await tester.pump();

      expect(_button(tester).onPressed, isNotNull);
    });

    // TC-PROV-MULTI-01, the half the banner test cannot carry: a missing STT
    // set must not disable typed input. Only the LLM's readiness gates the
    // agent — that is the whole reason `modelInstallStatusProvider` is a
    // family — so with the LLM ready and every other model absent, Diagnose
    // behaves exactly as if nothing else existed.
    testWidgets('stays enabled while the STT model is absent', (tester) async {
      await pumpState(
        tester,
        installStatusOf: (modelId) => modelId == ModelCatalog.active.id
            ? ModelInstallStatus.ready
            : ModelInstallStatus.absent,
      );

      await tester.enterText(
        find.byKey(DiagnoseKeys.inquiryField),
        'cabin vibrating, E-102',
      );
      await tester.pump();

      expect(
        _button(tester).onPressed,
        isNotNull,
        reason: 'a model the agent does not run on must not gate Diagnose',
      );
    });

    testWidgets('whitespace alone does not enable it', (tester) async {
      await pumpState(tester);

      await tester.enterText(find.byKey(DiagnoseKeys.inquiryField), '    ');
      await tester.pump();

      expect(_button(tester).onPressed, isNull);
    });

    // The production graph must never be able to answer from a fake, so with no
    // verified weights there is nowhere to tap at all.
    testWidgets('stays inert while the engine is unavailable', (tester) async {
      await pumpState(tester, warmup: const EngineUnavailable());

      await tester.enterText(
        find.byKey(DiagnoseKeys.inquiryField),
        'cabin vibrating, E-102',
      );
      await tester.pump();

      expect(_button(tester).onPressed, isNull);
    });

    testWidgets('stays inert while the weights are still loading', (
      tester,
    ) async {
      await pumpState(tester, warmup: const EngineLoading());

      await tester.enterText(
        find.byKey(DiagnoseKeys.inquiryField),
        'cabin vibrating, E-102',
      );
      await tester.pump();

      expect(_button(tester).onPressed, isNull);
    });

    testWidgets('reads Diagnosing… and is inert while a run is in flight', (
      tester,
    ) async {
      await pumpState(
        tester,
        job: const FieldJobState(
          phase: FieldJobPhase.thinking,
          inquiry: 'cabin vibrating, E-102',
        ),
      );

      await tester.enterText(
        find.byKey(DiagnoseKeys.inquiryField),
        'cabin vibrating, E-102',
      );
      await tester.pump();

      expect(find.text('Diagnosing…'), findsOneWidget);
      expect(_button(tester).onPressed, isNull);
    });
  });

  group('a run in progress', () {
    testWidgets('streams tokens with nothing animating', (tester) async {
      await pumpState(
        tester,
        job: const FieldJobState(
          phase: FieldJobPhase.thinking,
          inquiry: 'cabin vibrating, E-102',
          streamedText: 'Isolate the main power bus',
        ),
      );

      expect(find.text('Isolate the main power bus'), findsOneWidget);
      expect(progressIndicators(), findsNothing);
      // No outcome panel yet — the run has not ended.
      for (final reason in AgentStopReason.values) {
        expect(find.byKey(DiagnoseKeys.outcome(reason)), findsNothing);
      }
    });

    // Task 1.9 emits `AgentToolCallStarted` before the query is in flight
    // specifically so this can be on screen while it runs. Static, like everything
    // else here.
    testWidgets('shows the lookup in flight, naming the SKU, without animating', (
      tester,
    ) async {
      await pumpState(
        tester,
        job: const FieldJobState(
          phase: FieldJobPhase.thinking,
          inquiry: 'cabin vibrating, E-102',
          activeTool: AgentToolCallStarted(
            call: LlmToolCall(
              name: GetPartsInventoryTool.toolName,
              arguments: {GetPartsInventoryTool.skuParameter: ' brk-990-xp '},
            ),
            source: GuardSource.nativeEvent,
            repeated: false,
          ),
        ),
      );

      expect(find.byKey(DiagnoseKeys.toolActivity), findsOneWidget);
      // Canonicalised, so the line matches what the database was asked for rather
      // than whatever casing the weights emitted.
      expect(
        find.text('Checking local inventory for BRK-990-XP…'),
        findsOneWidget,
      );
      expect(progressIndicators(), findsNothing);
    });

    testWidgets('falls back to a generic label for an unknown tool', (
      tester,
    ) async {
      await pumpState(
        tester,
        job: const FieldJobState(
          phase: FieldJobPhase.thinking,
          activeTool: AgentToolCallStarted(
            call: LlmToolCall(name: 'raise_safety_hazard_alert'),
            source: GuardSource.nativeEvent,
            repeated: false,
          ),
        ),
      );

      expect(find.text('Running raise_safety_hazard_alert…'), findsOneWidget);
    });

    testWidgets('reports a refused call rather than dropping it', (
      tester,
    ) async {
      await pumpState(
        tester,
        job: const FieldJobState(
          phase: FieldJobPhase.thinking,
          rejectedCalls: [
            GuardFailure(
              reason: GuardFailureReason.argumentsUnreadable,
              message: 'arguments were not a JSON object',
            ),
          ],
        ),
      );

      expect(
        find.text(
          'The assistant sent a malformed lookup and was asked to retry.',
        ),
        findsOneWidget,
      );
    });
  });

  group('the completed-lookup line', () {
    // Task 1.5 kept "we do not carry this part" and "we carry it and have none"
    // apart in the payload; the screen has to keep them apart on the page, or that
    // distinction was made for nothing.
    testWidgets('in stock reads as a count and a location', (tester) async {
      await pumpState(
        tester,
        job: _doneWith(
          invocations: [
            _invocation(const {
              'sku': 'BRK-990-XP',
              'in_stock': 2,
              'aisle': 'Aisle 4, Shelf B',
            }),
          ],
        ),
      );

      expect(
        find.text('BRK-990-XP: 2 in stock at Aisle 4, Shelf B.'),
        findsOneWidget,
      );
    });

    testWidgets('zero stock is not the same sentence as not carried', (
      tester,
    ) async {
      await pumpState(
        tester,
        job: _doneWith(
          invocations: [
            _invocation(const {
              'sku': 'BELT-330-DRV',
              'in_stock': 0,
              'aisle': 'Aisle 2, Shelf A',
            }),
          ],
        ),
      );

      expect(
        find.text(
          'BELT-330-DRV is carried but out of stock at Aisle 2, Shelf A.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a part the warehouse does not carry says so', (tester) async {
      await pumpState(
        tester,
        job: _doneWith(
          invocations: [
            _invocation(const {'sku': 'NOT-A-REAL-SKU', 'found': false}),
          ],
        ),
      );

      expect(
        find.text('The warehouse does not carry NOT-A-REAL-SKU.'),
        findsOneWidget,
      );
    });

    testWidgets('a replayed call is marked as already answered', (
      tester,
    ) async {
      await pumpState(
        tester,
        job: _doneWith(
          invocations: [
            _invocation(const {
              'sku': 'BRK-990-XP',
              'in_stock': 2,
              'aisle': 'Aisle 4, Shelf B',
            }, repeated: true),
          ],
        ),
      );

      expect(find.textContaining('(already answered)'), findsOneWidget);
    });

    // `_ToolActivity` had a generic fallback for an unrecognised tool and
    // `_summarise` did not, so the first of the spec's §2.2 tools would have
    // rendered as "null: null in stock" — worse than useless, because it looks
    // like data.
    testWidgets(
      'an unrecognised tool is summarised generically, not as stock',
      (tester) async {
        await pumpState(
          tester,
          job: _doneWith(
            invocations: [
              const AgentToolInvocation(
                call: LlmToolCall(
                  name: 'raise_safety_hazard_alert',
                  arguments: {'severity': 'high'},
                ),
                source: GuardSource.nativeEvent,
                outcome: ToolSuccess(
                  toolName: 'raise_safety_hazard_alert',
                  payload: {'logged': true},
                ),
              ),
            ],
          ),
        );

        expect(
          find.text('raise_safety_hazard_alert completed.'),
          findsOneWidget,
        );
        expect(find.textContaining('in stock'), findsNothing);
        expect(find.textContaining('null'), findsNothing);
      },
    );

    testWidgets('a failed lookup does not report a stock level', (
      tester,
    ) async {
      await pumpState(
        tester,
        job: _doneWith(
          invocations: [
            AgentToolInvocation(
              call: const LlmToolCall(
                name: GetPartsInventoryTool.toolName,
                arguments: {GetPartsInventoryTool.skuParameter: 'BRK-990-XP'},
              ),
              source: GuardSource.nativeEvent,
              outcome: const ToolFailure(
                toolName: GetPartsInventoryTool.toolName,
                code: ToolFailureCode.executionFailed,
                message: 'the lookup failed',
              ),
            ),
          ],
        ),
      );

      expect(
        find.text('Inventory lookup could not be completed.'),
        findsOneWidget,
      );
      expect(find.textContaining('in stock'), findsNothing);
    });
  });

  group('all three stop reasons render differently', () {
    testWidgets('answered is a repair plan', (tester) async {
      await pumpState(
        tester,
        job: _doneWith(
          answer: 'Isolate the main power bus and replace the pads.',
        ),
      );

      expect(
        find.byKey(DiagnoseKeys.outcome(AgentStopReason.answered)),
        findsOneWidget,
      );
      expect(find.text('Repair plan'), findsOneWidget);
      expect(
        find.text('Isolate the main power bus and replace the pads.'),
        findsOneWidget,
      );
    });

    // **Every other fixture in this file uses markup-free answer text, and that is
    // exactly how the R0-F5 fix broke the device test unnoticed.** With raw and
    // formatted identical, nothing here could tell a `Text` from a `Text.rich` or a
    // consumed delimiter from a shown one. This fixture carries the real thing —
    // the shape both device runs returned — so the host suite can.
    testWidgets('an answer containing Markdown is rendered, not shown raw', (
      tester,
    ) async {
      const raw =
          '**Parts Check:**\n'
          'The required part is the **BRK-990-XP**.\n'
          '*   Torx T20 driver';

      await pumpState(tester, job: _doneWith(answer: raw));

      // The delimiters are gone and the bullet is a bullet.
      expect(
        find.text(
          'Parts Check:\n'
          'The required part is the BRK-990-XP.\n'
          '•   Torx T20 driver',
        ),
        findsOneWidget,
      );
      // And nothing on screen still carries the raw syntax.
      expect(find.textContaining('**'), findsNothing);
      expect(find.text(raw), findsNothing);

      // The bold really is bold, so "rendered" is not just "delimiters deleted".
      final answer = tester.widget<Text>(find.textContaining('Parts Check:'));
      final bold = (answer.textSpan! as TextSpan).children!
          .cast<TextSpan>()
          .where((span) => span.style?.fontWeight == FontWeight.bold)
          .map((span) => span.text)
          .toList();
      expect(bold, ['Parts Check:', 'BRK-990-XP']);
    });

    // The gap Task 1.10 handed this task: `emptyResponse` has no golden, and this
    // screen is the thing that has to render all three.
    testWidgets('emptyResponse says so instead of showing a blank panel', (
      tester,
    ) async {
      await pumpState(
        tester,
        job: _doneWith(
          answer: AgentLoop.emptyResponseMessage,
          stopReason: AgentStopReason.emptyResponse,
        ),
      );

      expect(
        find.byKey(DiagnoseKeys.outcome(AgentStopReason.emptyResponse)),
        findsOneWidget,
      );
      expect(find.text('No answer produced'), findsOneWidget);
      expect(find.text(AgentLoop.emptyResponseMessage), findsOneWidget);
      expect(find.text('Repair plan'), findsNothing);
    });

    testWidgets('iterationCapReached is presented as a stop, not a plan', (
      tester,
    ) async {
      await pumpState(
        tester,
        job: _doneWith(
          answer: AgentLoop.iterationCapMessage,
          stopReason: AgentStopReason.iterationCapReached,
        ),
      );

      expect(
        find.byKey(DiagnoseKeys.outcome(AgentStopReason.iterationCapReached)),
        findsOneWidget,
      );
      expect(find.text('Diagnosis stopped'), findsOneWidget);
      expect(find.text(AgentLoop.iterationCapMessage), findsOneWidget);
      expect(find.text('Repair plan'), findsNothing);
    });

    // The property the three tests above only imply: exactly one outcome panel
    // exists at a time and it is the right one. A screen that rendered a second
    // panel, or reused one key for two endings, satisfies each finder above and
    // fails here.
    //
    // One test **per ending**, generated from the enum rather than one test with a
    // loop inside it. The loop version was written first and was wrong: a second
    // `pumpWidget` in the same test reuses the tree and the previous ending's panel
    // was still found, so it failed on its own second iteration. A fresh tester per
    // ending is also what makes the `findsNothing` half meaningful.
    for (final ending in AgentStopReason.values) {
      testWidgets('rendering ${ending.name} shows only its own panel', (
        tester,
      ) async {
        await pumpState(
          tester,
          job: _doneWith(answer: 'text', stopReason: ending),
        );

        for (final reason in AgentStopReason.values) {
          expect(
            find.byKey(DiagnoseKeys.outcome(reason)),
            reason == ending ? findsOneWidget : findsNothing,
            reason: 'rendering ${ending.name}, looked for ${reason.name}',
          );
        }
      });
    }
  });

  group('the grounding line', () {
    testWidgets('names the manual entries the answer is grounded in', (
      tester,
    ) async {
      await pumpState(
        tester,
        job: _doneWith(retrieval: _retrievalOf(const [_e102])),
      );

      expect(
        find.textContaining('Traction Brake Pad Wear & Vibration (E-102)'),
        findsOneWidget,
      );
    });

    testWidgets(
      'an empty retrieval says the assistant was told not to invent',
      (tester) async {
        await pumpState(
          tester,
          job: _doneWith(retrieval: _retrievalOf(const [])),
        );

        expect(find.textContaining('No manual entry matched'), findsOneWidget);
      },
    );
  });

  group('failures are screens, not exceptions', () {
    // Task 1.3 asked for a malformed asset to fail loudly. Loudly means legible:
    // the message names the problem, the button is dead, and nothing was thrown.
    testWidgets('a startup failure is rendered and disables Diagnose', (
      tester,
    ) async {
      await pumpState(
        tester,
        startupError: SeedFormatException(
          'seed asset "revision" must be an integer',
        ),
      );

      expect(find.byKey(DiagnoseKeys.startupFailure), findsOneWidget);
      expect(find.textContaining('revision'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.enterText(
        find.byKey(DiagnoseKeys.inquiryField),
        'cabin vibrating, E-102',
      );
      await tester.pump();
      expect(_button(tester).onPressed, isNull);
    });

    // A run failure is not a startup failure: one says the app is misconfigured,
    // the other says that attempt did not work, and only the second leaves the
    // button worth pressing again.
    testWidgets('a failed run shows its reason and leaves the button live', (
      tester,
    ) async {
      await pumpState(
        tester,
        job: const FieldJobState(
          phase: FieldJobPhase.failed,
          inquiry: 'cabin vibrating, E-102',
          failure: 'This diagnosis could not be completed: isolate died',
        ),
      );

      expect(find.byKey(DiagnoseKeys.runFailure), findsOneWidget);
      expect(find.textContaining('isolate died'), findsOneWidget);
      expect(find.byKey(DiagnoseKeys.startupFailure), findsNothing);

      await tester.enterText(
        find.byKey(DiagnoseKeys.inquiryField),
        'cabin vibrating, E-102',
      );
      await tester.pump();
      expect(_button(tester).onPressed, isNotNull);
    });
  });

  group('R0-F1: weights becoming ready re-triggers the warm-up', () {
    // **The screen's only production `warmUp` call used to be a one-shot post-frame
    // callback**, and this screen is `MaterialApp.home` under a `StatelessWidget`,
    // so `initState` never runs twice. An operator who used the download button
    // `ModelReadinessBanner` offers got "Model ready" from the banner directly above
    // "No verified weights on this device — the agent cannot run" from the status
    // row, with Diagnose dead until restart.
    //
    // Driven the way it actually happens: `modelInstallStatusProvider` flips to
    // `ready` (which is what `provision()` causes by invalidating it), and nothing
    // else is touched.
    testWidgets('a status flip to ready loads the weights and enables Diagnose', (
      tester,
    ) async {
      final engine = _InertEngine();
      var status = ModelInstallStatus.absent;
      final container = ProviderContainer(
        overrides: [
          modelInstallStatusProvider.overrideWith(
            (ref, modelId) async => status,
          ),
          seedOutcomeProvider.overrideWith(
            (ref) async =>
                const SeedSkipped(storedRevision: 1, assetRevision: 1),
          ),
          // Mirrors `deviceLlmEngineProvider`: an engine only exists once the
          // weights are verified. Overriding it to hand one back unconditionally
          // — the first version of this test — made the precondition unreachable,
          // so it passed on an already-ready screen and proved nothing.
          agentEngineProvider.overrideWith((ref) async {
            final installed = await ref.watch(
              modelInstallStatusProvider(
                ref.watch(activeLlmDescriptorProvider).id,
              ).future,
            );
            return installed == ModelInstallStatus.ready ? engine : null;
          }),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const FieldOpsApp(),
        ),
      );
      await tester.pump();
      await settleRealAsync(tester);

      // Precondition: no weights, so nothing loaded and nothing to tap.
      expect(
        container.read(engineWarmupControllerProvider),
        isA<EngineUnavailable>(),
      );
      await tester.enterText(
        find.byKey(DiagnoseKeys.inquiryField),
        'cabin vibrating, E-102',
      );
      await tester.pump();
      expect(_button(tester).onPressed, isNull);

      // What a successful in-app provision does: install, then invalidate.
      status = ModelInstallStatus.ready;
      container.invalidate(modelInstallStatusProvider);
      await settleRealAsync(tester);

      expect(
        container.read(engineWarmupControllerProvider),
        isA<EngineReady>(),
        reason: 'nothing else re-runs warmUp, so the listener has to',
      );
      expect(find.text('On-device model ready'), findsOneWidget);
      expect(
        find.text('No verified weights on this device — the agent cannot run'),
        findsNothing,
        reason: 'the two rows must not contradict each other',
      );
      expect(_button(tester).onPressed, isNotNull);
    });

    // The listener fires on every transition into `ready`, including the ordinary
    // launch where weights were already installed. That must not cost a second load.
    testWidgets('it does not reload weights that were ready at launch', (
      tester,
    ) async {
      final engine = _CountingEngine();
      final container = ProviderContainer(
        overrides: [
          modelInstallStatusProvider.overrideWith(
            (ref, modelId) async => ModelInstallStatus.ready,
          ),
          seedOutcomeProvider.overrideWith(
            (ref) async =>
                const SeedSkipped(storedRevision: 1, assetRevision: 1),
          ),
          agentEngineProvider.overrideWith((ref) async => engine),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const FieldOpsApp(),
        ),
      );
      await tester.pump();
      await settleRealAsync(tester);

      expect(
        container.read(engineWarmupControllerProvider),
        isA<EngineReady>(),
      );
      expect(engine.initializeCalls, 1);
    });
  });

  group('R0-F2: the advice-vs-failure decision is isDiagnosis', () {
    // Four documents claimed the screen branched on `isDiagnosis` while `_Body`
    // re-derived the decision from `stopReason` itself. The duplication is gone;
    // these bind that the *treatment* follows the one question, across all three
    // endings, one test each so a stale tree cannot mask a case.
    for (final reason in AgentStopReason.values) {
      final isAnswer = reason == AgentStopReason.answered;
      final header = switch (reason) {
        AgentStopReason.answered => 'Repair plan',
        AgentStopReason.emptyResponse => 'No answer produced',
        AgentStopReason.iterationCapReached => 'Diagnosis stopped',
      };

      testWidgets(
        '${reason.name} gets the ${isAnswer ? 'answer' : 'failure'} icon',
        (tester) async {
          await pumpState(tester, job: _doneWith(stopReason: reason));

          expect(
            find.byIcon(Icons.check_circle),
            isAnswer ? findsOneWidget : findsNothing,
          );
          expect(
            find.byIcon(Icons.report_problem_outlined),
            isAnswer ? findsNothing : findsOneWidget,
          );
        },
      );

      // **The icon alone was not enough**: mutation M20 — making the header colour
      // a constant `primary` while the icon still followed `isDiagnosis` — survived
      // the icon test. Colour is the louder of the two signals in a recording, so
      // it gets its own guard, tied to the icon rather than to a theme literal so
      // the two cannot drift apart.
      testWidgets('${reason.name} colours its header to match its icon', (
        tester,
      ) async {
        await pumpState(tester, job: _doneWith(stopReason: reason));

        final headerColour = tester
            .widget<Text>(find.text(header))
            .style
            ?.color;
        final icon = tester.widget<Icon>(
          find.descendant(
            of: find.byKey(DiagnoseKeys.outcome(reason)),
            matching: find.byType(Icon),
          ),
        );

        expect(headerColour, isNotNull);
        expect(headerColour, icon.color);
      });
    }

    // And the two treatments must actually differ, or "renders differently" is a
    // claim about identical panels. Read off the widgets rather than compared to
    // theme literals, so it stays true if the palette changes.
    testWidgets('an answer and a failure are not the same colour', (
      tester,
    ) async {
      await pumpState(
        tester,
        job: _doneWith(stopReason: AgentStopReason.answered),
      );
      final answerColour = tester
          .widget<Text>(find.text('Repair plan'))
          .style
          ?.color;

      await pumpState(
        tester,
        job: _doneWith(stopReason: AgentStopReason.iterationCapReached),
      );
      final failureColour = tester
          .widget<Text>(find.text('Diagnosis stopped'))
          .style
          ?.color;

      expect(answerColour, isNotNull);
      expect(failureColour, isNotNull);
      expect(answerColour, isNot(failureColour));
    });
  });

  group('R0-F6: the panel follows a streaming answer', () {
    // A bare `SingleChildScrollView` stays pinned at offset 0 while its content
    // grows, so the measured 1401-character device answer streamed below the fold —
    // which breaks "the live token stream is the progress indicator" exactly when
    // the answer is long enough to matter. `find.text` could not catch it: a
    // scrolled-out `Text` is clipped, not offstage.
    testWidgets('a long streaming answer scrolls itself into view', (
      tester,
    ) async {
      // Deliberately taller than any plausible panel on a phone-sized test surface.
      final long = List.generate(80, (i) => 'Procedure step $i.').join('\n');

      // The state is *pushed* rather than re-pumped: streaming is a state change on
      // a live screen, and that is the path `didUpdateWidget` is written for.
      final container = await pumpState(
        tester,
        job: const FieldJobState(
          phase: FieldJobPhase.thinking,
          inquiry: 'cabin vibrating, E-102',
          streamedText: 'Isolate the main power bus.',
        ),
      );
      expect(
        _panelScrollController(tester).offset,
        0,
        reason: 'nothing to scroll yet',
      );

      await pushJob(
        tester,
        container,
        FieldJobState(
          phase: FieldJobPhase.thinking,
          inquiry: 'cabin vibrating, E-102',
          streamedText: long,
        ),
      );

      final after = _panelScrollController(tester);
      expect(
        after.position.maxScrollExtent,
        greaterThan(0),
        reason: 'the fixture must actually overflow, or this proves nothing',
      );
      // **Exact equality**, which is review finding R1-F4. This was
      // `closeTo(…, 24)`, justified by a "measured lag on this fixture of 16px" —
      // and the reviewer showed the assertion holds exactly, so the tolerance was
      // 24px of slack guarding nothing. The 16px was real when I saw it but was an
      // artefact of the fixture at the time, which re-pumped the whole tree instead
      // of pushing state through the notifier; that fixture no longer exists, so
      // neither does the lag. A tolerance justified by an unreproducible number is
      // the species of claim round 0 was about.
      expect(after.offset, after.position.maxScrollExtent);
    });

    // **The property the code claimed and did not have** — review finding R1-F1.
    // The reviewer's probe: scroll to the top mid-generation, push one more token,
    // and the panel returned to exactly `maxScrollExtent`. A technician re-reading a
    // procedure while the answer is still arriving was yanked back on every token.
    testWidgets('a reader who scrolls up mid-generation is not yanked back', (
      tester,
    ) async {
      final long = List.generate(80, (i) => 'Procedure step $i.').join('\n');
      // Started short and *grown*, because the follow triggers on an update rather
      // than a first build — a panel that opens with long text has nothing that grew
      // and correctly stays put. My first version asserted the precondition on a
      // first build and failed on it.
      final container = await pumpState(
        tester,
        job: const FieldJobState(
          phase: FieldJobPhase.thinking,
          inquiry: 'cabin vibrating, E-102',
          streamedText: 'Isolate the main power bus.',
        ),
      );
      await pushJob(
        tester,
        container,
        FieldJobState(
          phase: FieldJobPhase.thinking,
          inquiry: 'cabin vibrating, E-102',
          streamedText: long,
        ),
      );

      // Following, as it should be.
      final atBottom = _panelScrollController(tester);
      expect(atBottom.position.maxScrollExtent, greaterThan(0));
      expect(atBottom.offset, atBottom.position.maxScrollExtent);

      // The technician scrolls up to re-read the earlier steps.
      atBottom.jumpTo(0);
      await tester.pump();
      expect(_panelScrollController(tester).offset, 0);

      // One more token arrives.
      await pushJob(
        tester,
        container,
        FieldJobState(
          phase: FieldJobPhase.thinking,
          inquiry: 'cabin vibrating, E-102',
          streamedText: '$long\nProcedure step 80.',
        ),
      );

      final after = _panelScrollController(tester);
      expect(
        after.offset,
        0,
        reason:
            'the reader scrolled deliberately; the stream must not overrule it',
      );
      expect(
        after.position.maxScrollExtent,
        greaterThan(0),
        reason:
            'the content still grew, so the follow was skipped rather than '
            'having nothing to do',
      );
    });

    // **The same property as R1-F1, driven by a finger instead of a `jumpTo`** —
    // review finding **R12-F0**, reported from the device as "I could not scroll
    // anything" while the answer streamed.
    //
    // R1-F1's test above scrolls with `_scroll.jumpTo(0)`. That is a *programmatic*
    // move with no drag to dispose, so it exercises the offset guard and never the
    // mechanism that actually failed: `jumpTo` opens with `goIdle()`, `goIdle`
    // disposes the active drag, and every token therefore cancelled the reader's
    // in-flight gesture before it could travel the `_followSlack` pixels that would
    // have released the follow. The panel was not merely overruling the reader, it
    // was unscrollable — and that presents as the app being busy, which is why it
    // survived eleven review rounds, two device runs and a screen recording.
    //
    // Measured with the matched control below: the *same* 288px drag moves the
    // offset when no tokens arrive and does not when they do. Both directions are
    // asserted, because a fix that simply stopped following would pass the first
    // assertion alone.
    // **Run under both platforms' physics, because the demo device is not the test
    // default.** `flutter_test` reports `TargetPlatform.android`, which selects
    // `ClampingScrollPhysics`; the iPad this ships on uses `BouncingScrollPhysics`,
    // where a drag past the extent is allowed and settles back. Binding one and
    // shipping the other is the same "bound at the wrong width" mistake R12-F0 was,
    // one level over — so the platform is a parameter rather than an assumption.
    // `variant:` rather than setting `debugDefaultTargetPlatformOverride` by hand:
    // the binding asserts foundation debug vars are unset at the *end of the test
    // body*, before `addTearDown` runs, so the hand-rolled version fails on its own
    // cleanup.
    testWidgets(
      'a finger can drag the panel while tokens are arriving',
      (tester) async {
        Future<(double before, double afterDrag, double afterNextToken)> drag({
          required bool tokensArrive,
        }) async {
          final long = List.generate(
            80,
            (i) => 'Procedure step $i.',
          ).join('\n');
          final container = await pumpState(
            tester,
            job: const FieldJobState(
              phase: FieldJobPhase.thinking,
              inquiry: 'cabin vibrating, E-102',
              streamedText: 'Isolate the main power bus.',
            ),
          );
          await pushJob(
            tester,
            container,
            FieldJobState(
              phase: FieldJobPhase.thinking,
              inquiry: 'cabin vibrating, E-102',
              streamedText: long,
            ),
          );

          final before = _panelScrollController(tester).offset;
          final gesture = await tester.startGesture(
            tester.getCenter(find.byKey(DiagnoseKeys.resultPanel)),
          );
          await tester.pump();

          var text = long;
          for (var i = 0; i < 12; i++) {
            // Positive dy drags the finger *down*, revealing earlier text, so a
            // working panel moves the offset down from the bottom.
            await gesture.moveBy(const Offset(0, 24));
            if (tokensArrive) {
              text = '$text\nProcedure step ${80 + i}.';
              (container.read(fieldJobViewModelProvider.notifier)
                      as _StubViewModel)
                  .push(
                    FieldJobState(
                      phase: FieldJobPhase.thinking,
                      inquiry: 'cabin vibrating, E-102',
                      streamedText: text,
                    ),
                  );
            }
            await tester.pump(const Duration(milliseconds: 16));
          }
          await gesture.up();
          await tester.pumpAndSettle();
          final afterDrag = _panelScrollController(tester).offset;

          // One more token *after* the finger lifts. This is R1-F1's own property,
          // asserted for the first time against a scroll a reader actually performed:
          // the drag flag is clear by now, so the offset guard alone must hold the
          // position.
          (container.read(fieldJobViewModelProvider.notifier) as _StubViewModel)
              .push(
                FieldJobState(
                  phase: FieldJobPhase.thinking,
                  inquiry: 'cabin vibrating, E-102',
                  streamedText: '$text\nProcedure step 99.',
                ),
              );
          await tester.pump();
          return (before, afterDrag, _panelScrollController(tester).offset);
        }

        final control = await drag(tokensArrive: false);
        expect(
          control.$2,
          lessThan(control.$1),
          reason: 'control: with nothing streaming, a drag must move the panel',
        );

        final streaming = await drag(tokensArrive: true);
        expect(
          streaming.$2,
          lessThan(streaming.$1),
          reason:
              'the reader dragged 288px while tokens arrived; before R12-F0 the '
              'offset ended pinned to maxScrollExtent because each token disposed '
              'the drag',
        );
        expect(
          streaming.$3,
          streaming.$2,
          reason:
              'and the token after the finger lifted must not haul them back — '
              'R1-F1, from a real drag rather than a jumpTo',
        );
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.iOS,
      }),
    );

    // **The other half of R12-F0's claim: releasing the follow must be reversible.**
    // `_readerIsDragging` clears on any `ScrollEndNotification`, and the comment on
    // it says a reader who returns to the bottom resumes following. Nothing bound
    // that — `TestGesture.moveBy` defaults to `timeStamp: Duration.zero`, so no test
    // in this file produces a ballistic scroll at all, and a flag that latched true
    // after a fling would disable following silently and forever. That would be a
    // worse defect than the one R12-F0 fixed.
    testWidgets('a reader who flings back to the bottom follows again', (
      tester,
    ) async {
      final long = List.generate(80, (i) => 'Procedure step $i.').join('\n');
      final container = await pumpState(
        tester,
        job: const FieldJobState(
          phase: FieldJobPhase.thinking,
          inquiry: 'cabin vibrating, E-102',
          streamedText: 'Isolate the main power bus.',
        ),
      );
      await pushJob(
        tester,
        container,
        FieldJobState(
          phase: FieldJobPhase.thinking,
          inquiry: 'cabin vibrating, E-102',
          streamedText: long,
        ),
      );
      final panel = find.byKey(DiagnoseKeys.resultPanel);

      // Away from the bottom, with real velocity so the scroll goes ballistic.
      await tester.fling(panel, const Offset(0, 400), 1000);
      await tester.pumpAndSettle();
      final away = _panelScrollController(tester);
      expect(
        away.offset,
        lessThan(away.position.maxScrollExtent),
        reason: 'precondition: the fling left the bottom',
      );

      // And back down again.
      await tester.fling(panel, const Offset(0, -400), 1000);
      await tester.pumpAndSettle();
      final back = _panelScrollController(tester);
      expect(
        back.offset,
        // `closeTo`, not equality — Task 2.3. The fling settles through a
        // *ballistic simulation*, so where it lands is arithmetic over the
        // panel's extent rather than a `jumpTo`, and changing the panel's height
        // (2.3 gave the work order two fifths of the column) moved the residue
        // from exactly 0 to 8e-13. Equality here was passing on the layout rather
        // than on the property. The property is "the reader is back at the
        // bottom", and the slack that governs the follow is 48 logical pixels, so
        // a tolerance three orders of magnitude below one pixel cannot admit a
        // reader who is not.
        closeTo(back.position.maxScrollExtent, 0.001),
        reason: 'precondition: the reader returned to the bottom',
      );

      // The next token must follow. If the drag flag had latched, it would not.
      await pushJob(
        tester,
        container,
        FieldJobState(
          phase: FieldJobPhase.thinking,
          inquiry: 'cabin vibrating, E-102',
          streamedText: '$long\nProcedure step 80.',
        ),
      );
      final after = _panelScrollController(tester);
      expect(after.offset, after.position.maxScrollExtent);
    });

    // **The slack's value, bound in the direction that constrains it** — review
    // finding R2-F4 measured that `_followSlack = 0` survived the suite, so nothing
    // held the constant except an upper bound. A reader who nudges up by less than a
    // line has not asked to stop following, and this is the case that says so.
    testWidgets('a nudge smaller than the slack keeps following', (
      tester,
    ) async {
      final long = List.generate(80, (i) => 'Procedure step $i.').join('\n');
      final container = await pumpState(
        tester,
        job: const FieldJobState(
          phase: FieldJobPhase.thinking,
          inquiry: 'cabin vibrating, E-102',
          streamedText: 'Isolate the main power bus.',
        ),
      );
      await pushJob(
        tester,
        container,
        FieldJobState(
          phase: FieldJobPhase.thinking,
          inquiry: 'cabin vibrating, E-102',
          streamedText: long,
        ),
      );

      // Nudge up by 20px — well inside the 48px band, and far too small to be a
      // deliberate "stop following".
      final controller = _panelScrollController(tester);
      final nudged = controller.position.maxScrollExtent - 20;
      controller.jumpTo(nudged);
      await tester.pump();

      await pushJob(
        tester,
        container,
        FieldJobState(
          phase: FieldJobPhase.thinking,
          inquiry: 'cabin vibrating, E-102',
          streamedText: '$long\nProcedure step 80.',
        ),
      );

      final after = _panelScrollController(tester);
      expect(
        after.offset,
        after.position.maxScrollExtent,
        reason: 'a 20px nudge is not a request to leave the stream',
      );
      expect(
        after.offset,
        greaterThan(nudged),
        reason: 'and the panel actually moved, so this is not a no-op',
      );
    });

    // And the follow resumes once the reader returns to the bottom — otherwise the
    // guard above would be a one-way door out of following the stream.
    testWidgets('scrolling back to the bottom resumes the follow', (
      tester,
    ) async {
      final long = List.generate(80, (i) => 'Procedure step $i.').join('\n');
      final container = await pumpState(
        tester,
        job: const FieldJobState(
          phase: FieldJobPhase.thinking,
          inquiry: 'cabin vibrating, E-102',
          streamedText: 'Isolate the main power bus.',
        ),
      );
      await pushJob(
        tester,
        container,
        FieldJobState(
          phase: FieldJobPhase.thinking,
          inquiry: 'cabin vibrating, E-102',
          streamedText: long,
        ),
      );

      _panelScrollController(tester).jumpTo(0);
      await tester.pump();
      _panelScrollController(
        tester,
      ).jumpTo(_panelScrollController(tester).position.maxScrollExtent);
      await tester.pump();

      await pushJob(
        tester,
        container,
        FieldJobState(
          phase: FieldJobPhase.thinking,
          inquiry: 'cabin vibrating, E-102',
          streamedText: '$long\nProcedure step 80.',
        ),
      );

      final after = _panelScrollController(tester);
      expect(after.offset, after.position.maxScrollExtent);
    });

    // The two limits on the follow, both deliberate: a finished answer is left where
    // the reader put it, so they can scroll up to re-read without being yanked back.
    testWidgets('a finished answer is not scrolled', (tester) async {
      final long = List.generate(80, (i) => 'Procedure step $i.').join('\n');

      final container = await pumpState(
        tester,
        job: _doneWith(answer: 'short'),
      );
      await pushJob(tester, container, _doneWith(answer: long));

      final controller = _panelScrollController(tester);
      expect(controller.position.maxScrollExtent, greaterThan(0));
      expect(controller.offset, 0);
    });
  });

  // ------------------------------------------ guards the review found unbound

  group('R0-F9: guards with correct code and nothing holding them', () {
    // The doc says "One line per refusal, counted rather than iterated", and the
    // README argues the count is the point — "silently hiding them would make a
    // four-turn run look like an inexplicably slow two-turn one". Every earlier test
    // used a single failure, so replacing the loop with `if (isNotEmpty)` survived
    // the whole suite.
    testWidgets('two refusals render two lines, not one', (tester) async {
      const refusal = GuardFailure(
        reason: GuardFailureReason.argumentsUnreadable,
        message: 'arguments were not a JSON object',
      );
      await pumpState(
        tester,
        job: const FieldJobState(
          phase: FieldJobPhase.thinking,
          rejectedCalls: [refusal, refusal],
        ),
      );

      expect(
        find.text(
          'The assistant sent a malformed lookup and was asked to retry.',
        ),
        findsNWidgets(2),
      );
    });

    // The sibling of the "null: null in stock" defect fixed one function away in
    // `8ca9e6c`: dropping the null guard rendered "…in stock at null." All five
    // seeded rows have a location, so only a synthetic row reaches this.
    testWidgets('a row with no location omits the location, not renders null', (
      tester,
    ) async {
      await pumpState(
        tester,
        job: _doneWith(
          invocations: [
            _invocation(const {
              'sku': 'BRK-990-XP',
              'in_stock': 3,
              'aisle': null,
            }),
          ],
        ),
      );

      expect(find.text('BRK-990-XP: 3 in stock.'), findsOneWidget);
      expect(find.textContaining('null'), findsNothing);
      expect(find.textContaining(' at '), findsNothing);
    });

    // `_labelFor`'s `sku.trim().isNotEmpty` half: a blank SKU must fall back to the
    // unqualified label rather than announcing a lookup for nothing.
    testWidgets('a blank SKU falls back to the unqualified tool label', (
      tester,
    ) async {
      await pumpState(
        tester,
        job: const FieldJobState(
          phase: FieldJobPhase.thinking,
          activeTool: AgentToolCallStarted(
            call: LlmToolCall(
              name: GetPartsInventoryTool.toolName,
              arguments: {GetPartsInventoryTool.skuParameter: '   '},
            ),
            source: GuardSource.nativeEvent,
            repeated: false,
          ),
        ),
      );

      expect(find.text('Checking local inventory…'), findsOneWidget);
    });

    // `_notReadyMessage`'s remaining two branches. The doc's whole argument is that
    // naming *which* state matters ("'the model is not ready' without saying whether
    // that is loading, absent or failed is the least useful sentence available"), so
    // each branch needs its own words.
    testWidgets('diagnosing mid-load says the model is still loading', (
      tester,
    ) async {
      final container = ProviderContainer(
        overrides: [
          engineWarmupControllerProvider.overrideWith(
            () => _StubWarmup(const EngineLoading()),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(fieldJobViewModelProvider.notifier)
          .diagnose('cabin vibrating, E-102');

      expect(
        container.read(fieldJobViewModelProvider).failure,
        'The on-device model is still loading.',
      );
    });

    testWidgets('diagnosing after a load failure quotes the load failure', (
      tester,
    ) async {
      final container = ProviderContainer(
        overrides: [
          engineWarmupControllerProvider.overrideWith(
            () => _StubWarmup(const EngineFailed('no Metal device')),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(fieldJobViewModelProvider.notifier)
          .diagnose('cabin vibrating, E-102');

      final failure = container.read(fieldJobViewModelProvider).failure;
      expect(failure, contains('unavailable'));
      expect(failure, contains('no Metal device'));
    });
  });

  // ------------------------------------------------------------------- wiring

  /// Pumps the app over the **real** graph: real seeded database, real router,
  /// compiler, loop, guard and registry. Only the model is faked.
  ///
  /// Returns the container, so a test can *listen* to the viewmodel instead of
  /// sampling frames. That is not a convenience either — see the phase-sequence
  /// test for why sampling cannot work here.
  Future<ProviderContainer> pumpWired(
    WidgetTester tester,
    List<List<LlmEvent>> turns,
  ) async {
    final container = ProviderContainer(
      overrides: [
        modelInstallStatusProvider.overrideWith(
          (ref, modelId) async => ModelInstallStatus.ready,
        ),
        appDatabaseProvider.overrideWith((ref) async {
          final database = DatabaseService.encrypted(
            file: File('${tempDir.path}/wired.db'),
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
          (ref) async => FakeLlmEngine(turns: turns),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const FieldOpsApp(),
      ),
    );
    await tester.pump();
    await settleRealAsync(tester);
    return container;
  }

  group('wired to the real slice', () {
    // The whole point of the screen, through the button, with nothing stubbed but
    // the weights. `Aisle 4, Shelf B` and `2` come out of the seeded warehouse
    // table, so this fails if the tool is wired to an empty database.
    testWidgets('a typed inquiry produces a grounded answer and a real lookup', (
      tester,
    ) async {
      await pumpWired(tester, [
        [
          const LlmToken('Let me check the warehouse.'),
          const LlmToolCall(
            name: GetPartsInventoryTool.toolName,
            arguments: {GetPartsInventoryTool.skuParameter: 'BRK-990-XP'},
          ),
          const LlmDone(),
        ],
        const [
          LlmToken('Replace the pads; 2 units are in Aisle 4, Shelf B.'),
          LlmDone(),
        ],
      ]);

      expect(find.text('On-device model ready'), findsOneWidget);
      await tester.enterText(
        find.byKey(DiagnoseKeys.inquiryField),
        'cabin vibrating, E-102',
      );
      await tester.pump();
      await tester.tap(find.byKey(DiagnoseKeys.diagnoseButton));
      await settleRealAsync(tester);

      // Grounded in the manual entry retrieval found, from the real FTS index.
      expect(
        find.textContaining('Traction Brake Pad Wear & Vibration (E-102)'),
        findsOneWidget,
      );
      // The lookup line is built from the database's own row, not the script.
      expect(
        find.text('BRK-990-XP: 2 in stock at Aisle 4, Shelf B.'),
        findsOneWidget,
      );
      // And the answer is the *second* turn's text, not both turns concatenated.
      expect(
        find.byKey(DiagnoseKeys.outcome(AgentStopReason.answered)),
        findsOneWidget,
      );
      expect(
        find.text('Replace the pads; 2 units are in Aisle 4, Shelf B.'),
        findsOneWidget,
      );
      expect(find.textContaining('Let me check the warehouse'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    // **The tap really drives the state machine, asserted by listening rather than
    // by looking at a frame — and the reason is a measurement, not a preference.**
    //
    // The first version of this test tapped, pumped one frame, and asserted the
    // button was disabled. It failed: `onPressed` was already non-null again. The
    // cause is that on the host this graph is *too fast to observe*. `drift`'s
    // `NativeDatabase` runs sqlite3 synchronously in-process (not
    // `createInBackground`), and `FakeLlmEngine` replays a turn as fast as it is
    // drained, so retrieval, compilation, both model turns and the inventory query
    // all complete inside the microtasks that `tester.tap` awaits — before the
    // first frame after the tap exists. There is no frame in which the run is in
    // flight.
    //
    // So the intermediate *rendering* is bound by injecting a `thinking` state
    // (see 'reads Diagnosing… and is inert while a run is in flight'), and what is
    // bound here is the thing only the wired graph can show: the button's callback
    // reaches the real viewmodel and drives it through the real phases. On device
    // the run takes seconds and the frames exist, which is
    // `integration_test/demo_flow_test.dart`.
    testWidgets('the button drives the real state machine idle→thinking→done', (
      tester,
    ) async {
      final container = await pumpWired(tester, [
        const [LlmToken('Answer.'), LlmDone()],
      ]);
      final phases = <FieldJobPhase>[];
      container.listen(fieldJobViewModelProvider, (previous, next) {
        if (previous?.phase != next.phase) phases.add(next.phase);
      }, fireImmediately: true);

      await tester.enterText(
        find.byKey(DiagnoseKeys.inquiryField),
        'cabin vibrating, E-102',
      );
      await tester.pump();
      expect(_button(tester).onPressed, isNotNull);

      await tester.tap(find.byKey(DiagnoseKeys.diagnoseButton));
      await settleRealAsync(tester);

      expect(phases, [
        FieldJobPhase.idle,
        FieldJobPhase.thinking,
        FieldJobPhase.done,
      ]);
      expect(_button(tester).onPressed, isNotNull);
      expect(find.text('Diagnose'), findsOneWidget);
      expect(find.text('Answer.'), findsOneWidget);
    });
  });
}

FilledButton _button(WidgetTester tester) =>
    tester.widget<FilledButton>(find.byKey(DiagnoseKeys.diagnoseButton));

/// The result panel's own `ScrollController`, read off the live widget.
///
/// Reaching for the widget rather than a test-owned controller on purpose: the
/// property under test is that *the screen* scrolls itself, and a controller the
/// test supplied would only prove the test can scroll.
ScrollController _panelScrollController(WidgetTester tester) => tester
    .widget<SingleChildScrollView>(
      find.descendant(
        of: find.byKey(DiagnoseKeys.resultPanel),
        matching: find.byType(SingleChildScrollView),
      ),
    )
    .controller!;

/// A finished run, for rendering tests.
///
/// `turns` is a single real [AgentTurn] rather than an empty list, because
/// `AgentRunResult` documents its turns as never empty and a fixture that
/// contradicts the type it stands in for is the trap Task 1.8 recorded.
FieldJobState _doneWith({
  String answer = 'An answer.',
  AgentStopReason stopReason = AgentStopReason.answered,
  List<AgentToolInvocation> invocations = const [],
  RetrievalResult? retrieval,
}) => FieldJobState(
  phase: FieldJobPhase.done,
  inquiry: 'cabin vibrating, E-102',
  streamedText: answer,
  invocations: invocations,
  retrieval: retrieval,
  result: AgentRunResult(
    answer: answer,
    stopReason: stopReason,
    turns: [
      AgentTurn(
        index: 0,
        prompt: '[MANUAL DOCUMENT]…',
        text: answer,
        invocations: invocations,
        rejectedCalls: const [],
        textScannedForCall: false,
      ),
    ],
  ),
);

AgentToolInvocation _invocation(
  Map<String, Object?> payload, {
  bool repeated = false,
}) => AgentToolInvocation(
  call: LlmToolCall(
    name: GetPartsInventoryTool.toolName,
    arguments: {
      GetPartsInventoryTool.skuParameter: payload['sku'] as String? ?? '',
    },
  ),
  source: GuardSource.nativeEvent,
  outcome: ToolSuccess(
    toolName: GetPartsInventoryTool.toolName,
    payload: payload,
  ),
  repeated: repeated,
);

RetrievalResult _retrievalOf(List<ManualEntryRow> entries) => RetrievalResult(
  rawQuery: 'cabin vibrating, E-102',
  entries: entries,
  codeHitIds: {for (final e in entries) e.id},
  ftsHitIds: const {},
  resolvedCodes: const ['E-102'],
  unresolvedCodes: const [],
  searchedTerms: const ['cabin', 'vibrating'],
);

const ManualEntryRow _e102 = ManualEntryRow(
  id: 'apex_9_err_102',
  section: 'Brake Systems',
  code: 'E-102',
  title: 'Traction Brake Pad Wear & Vibration',
  symptoms: 'High-pitched squealing during deceleration.',
  procedure: 'Isolate the main elevator power bus.',
  requiredTools: '["Torx T20"]',
  requiredParts: '["BRK-990-XP"]',
);

/// Seed source over an in-memory string. Same shape as `agent_loop_test.dart`'s.
class _TextSeedSource implements SeedSource {
  const _TextSeedSource(this._json);

  final String _json;

  @override
  String get seedId => AssetBundleSeedSource.defaultSeedId;

  @override
  Future<String> loadSeedJson() async => _json;
}

/// Returns a fixed [FieldJobState] and records whether the button called it.
///
/// `diagnose` is overridden to record rather than run, because these tests are
/// about what is *drawn* for a state — `field_job_viewmodel_test.dart` owns what
/// produces the state.
class _StubViewModel extends FieldJobViewModel {
  _StubViewModel(this._state);

  final FieldJobState _state;

  @override
  FieldJobState build() => _state;

  @override
  Future<void> diagnose(String rawInquiry) async {}

  /// Publishes [next], the way a real run would. See `pumpState`'s doc for why a
  /// second `pumpWidget` cannot do this.
  void push(FieldJobState next) => state = next;
}

/// Returns a fixed [EngineWarmupState], and does not load anything.
class _StubWarmup extends EngineWarmupController {
  _StubWarmup(this._state);

  final EngineWarmupState _state;

  @override
  EngineWarmupState build() => _state;

  @override
  Future<void> warmUp() async {}
}

/// An engine that counts its loads, for the "already ready at launch" case.
class _CountingEngine implements LlmEngine {
  bool _ready = false;
  int initializeCalls = 0;

  @override
  bool get isReady => _ready;

  @override
  Future<void> initialize() async {
    initializeCalls++;
    _ready = true;
  }

  @override
  Stream<LlmEvent> generate({
    required String prompt,
    List<ToolDefinition> tools = const [],
  }) => const Stream<LlmEvent>.empty();

  @override
  Future<void> dispose() async {}
}

/// Stands in for a loaded engine in an [EngineReady] the screen only reads the
/// *type* of. Nothing calls it; a `const` instance keeps `pumpState`'s default
/// `const`.
class _InertEngine implements LlmEngine {
  const _InertEngine();

  @override
  bool get isReady => true;

  @override
  Future<void> initialize() async {}

  @override
  Stream<LlmEvent> generate({
    required String prompt,
    List<ToolDefinition> tools = const [],
  }) => const Stream<LlmEvent>.empty();

  @override
  Future<void> dispose() async {}
}
