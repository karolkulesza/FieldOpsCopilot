import 'dart:async';

import 'package:field_ops_copilot/app.dart';
import 'package:field_ops_copilot/services/ai/agent_loop.dart';
import 'package:field_ops_copilot/services/database/providers.dart';
import 'package:field_ops_copilot/services/inference/engine_warmup_controller.dart';
import 'package:field_ops_copilot/services/models/model_descriptor.dart';
import 'package:field_ops_copilot/services/models/model_provisioner.dart';
import 'package:field_ops_copilot/services/models/model_storage.dart';
import 'package:field_ops_copilot/viewmodels/field_job_viewmodel.dart';
import 'package:field_ops_copilot/views/components/answer_markdown.dart';
import 'package:field_ops_copilot/views/diagnose_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'e2e_fixtures.dart';

/// TC-UI-DEMO-01 — the whole Tier 1 slice, driven through the real UI on a real
/// device, against real weights and the app's own durable database.
///
/// ```sh
/// flutter test integration_test/demo_flow_test.dart -d <device id> \
///   --dart-define=FIELDOPS_MODEL_URI=<resolve URL for the file you licensed> \
///   --dart-define=FIELDOPS_MODEL_SHA256=<its sha256>
/// ```
///
/// Weights, skipping and the opt-in provisioning switch work exactly as in
/// `llm_inference_test.dart` and `agent_loop_e2e_test.dart` — see the first of
/// those for the reasoning.
///
/// **What is different from `agent_loop_e2e_test.dart`, and why this file exists on
/// top of it.** That suite builds the router, the compiler, the registry and the
/// loop by hand, over a throwaway database it seeds itself. This one builds
/// *nothing*: it pumps `FieldOpsApp` with no overrides at all and taps a button. So
/// it is the only test in the repo that exercises Task 1.11's three deferred wirings
/// as the app actually performs them —
///
/// 1. `DatabaseService.openDefault` in the real application-support directory, keyed
///    with the real `databaseEncryptionKeyProvider`;
/// 2. `ensureSeeded()` reached through `rootBundle` and a real `AssetBundle`, which
///    every host test fakes;
/// 3. `deviceLlmEngineProvider` loading the real 2.59GB artifact, warmed up by
///    `EngineWarmupController` from the screen's own post-frame callback.
///
/// Any one of those failing on device is invisible to the whole host suite — no
/// count here, because the one this line first carried went stale in the very next
/// commit (review finding R0-F7). `flutter test` is the source of truth, which is
/// the rule the README already adopted for the same reason.
///
/// **Assertions are fuzzy, as the tier requires.** A model's wording is not a
/// contract. What is asserted is that the run ended because the model answered, that
/// the inventory tool ran against the device's own database, and that the answer
/// carries the stock figure that database holds — read back rather than written as
/// `2`, so a seed change moves the assertion with it. `2 units in Aisle 4, Shelf B`
/// is not a fact about elevators, so a model answering from its weights cannot
/// satisfy it by luck.
///
/// **It also measures the two things only this run can.** Task 1.8 left throughput
/// unmeasured (a one-token reply makes tokens-per-second a restatement of TTFT) and
/// left the load-time UI stall diagnosed only as far as eliminating Metal. This suite
/// generates a real multi-sentence answer through the real screen, and ticks a 16ms
/// timer on the UI isolate across both the warm-up and the generation — so it reports
/// characters per second and the worst frame gap *for the flow being screen-recorded*
/// rather than for a synthetic prompt. Printed, not asserted: a threshold that fails
/// on a warm device would be a flaky test pretending to be an NFR.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final descriptor = ModelCatalog.active;
  late String skipReason;

  setUpAll(() async {
    final storage = await ModelStorage.openDefault();
    final provisioner = ModelProvisioner(storage: storage);
    addTearDown(provisioner.dispose);

    final issue = descriptor.configurationIssue;
    var status = await provisioner.statusOf(descriptor);

    if (issue == null &&
        status != ModelInstallStatus.ready &&
        _provisionIfMissing) {
      debugPrint('[TC-UI-DEMO] provisioning weights first (opt-in)');
      await provisioner.provision(descriptor);
      status = await provisioner.statusOf(descriptor);
    }

    skipReason = switch ((issue, status)) {
      (final issue?, _) =>
        'model source not configured (${issue.name}) — pass '
            'FIELDOPS_MODEL_URI and FIELDOPS_MODEL_SHA256. '
            'License: ${descriptor.licensePage}',
      (_, ModelInstallStatus.absent) =>
        'weights are not installed — pass '
            '--dart-define=$_provisionFlag=true to fetch them as part of this '
            'run, or side-load ${descriptor.soleFile.fileName} into '
            '<app support>/models',
      (_, ModelInstallStatus.unverified) =>
        'weights are present but unverified against the pinned SHA-256',
      (_, ModelInstallStatus.ready) => '',
    };
  });

  testWidgets(
    'TC-UI-DEMO-01: typing a fault and tapping Diagnose renders a grounded answer',
    (tester) async {
      if (skipReason.isNotEmpty) {
        markTestSkipped(skipReason);
        return;
      }

      // No overrides. This is the app, exactly as `main()` runs it — which is the
      // only way the three deferred wirings are under test rather than stubbed.
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const FieldOpsApp(),
        ),
      );
      await tester.pump();

      expect(find.byType(DiagnoseScreen), findsOneWidget);

      // --- wiring 1 and 2: the durable database, its key, and the seed ---------
      //
      // Read through the provider the screen reads. On a first run this is
      // `SeedApplied`; on a re-run over the same install it is `SeedSkipped`, and
      // both are correct — what is asserted is that it resolved rather than threw,
      // and that the manual is queryable afterwards.
      final seed = await container.read(seedOutcomeProvider.future);
      debugPrint('[TC-UI-DEMO-01] seed: $seed');
      final database = await container.read(seededDatabaseProvider.future);
      expect(
        await database.manualEntryByCode('E-102'),
        isNotNull,
        reason: 'the real asset bundle must have reached the real database',
      );

      // --- wiring 3: the weights, loaded before the UI needs to be interactive --
      //
      // The screen's post-frame callback has already started this. Ticking a 16ms
      // timer on the UI isolate across the wait is what turns Task 1.8's stall
      // measurement into a statement about *this* flow: the stall is the same
      // stall, but here it lands while the static "loading" row is on screen.
      // Counted so the per-frame assertion below cannot pass by never running — a
      // guard that was never evaluated is not a guard, and this one is checked on
      // every frame of a multi-second wait.
      var loadingFrames = 0;
      final loadProbe = await _UiIsolateProbe.measure(() async {
        await _pumpUntil(
          tester,
          () =>
              container.read(engineWarmupControllerProvider)
                  is! EngineLoading &&
              container.read(engineWarmupControllerProvider) is! EngineIdle,
          const Duration(minutes: 4),
          onFrame: () {
            if (container.read(engineWarmupControllerProvider)
                is! EngineLoading) {
              return;
            }
            loadingFrames++;
            // The load is where Task 1.8 measured 1445-1728ms of blocked UI
            // isolate. The whole design is that it lands behind a *static* row, so
            // this is asserted on the device, while the stall is happening, rather
            // than inferred from the state afterwards: a frozen indicator reads as
            // a crashed app.
            expect(
              find.byWidgetPredicate((widget) => widget is ProgressIndicator),
              findsNothing,
              reason: 'frame $loadingFrames of the load must not animate',
            );
          },
        );
      });
      final warmup = container.read(engineWarmupControllerProvider);
      debugPrint('[TC-UI-DEMO-01] warm-up: ${warmup.runtimeType}, $loadProbe');
      expect(
        warmup,
        isA<EngineReady>(),
        reason: 'weights verified as ready must load; got $warmup',
      );
      await tester.pump();
      expect(find.text('On-device model ready'), findsOneWidget);

      // The per-frame assertion above is worthless if it never ran. A load that took
      // 7822ms on the demo device cannot have produced zero loading frames, so a
      // zero here means the probe missed the state, not that the screen was clean.
      debugPrint('[TC-UI-DEMO-01] asserted over $loadingFrames loading frames');
      expect(
        loadingFrames,
        greaterThan(0),
        reason: 'the no-animation guard must have been evaluated while loading',
      );

      // --- the demo itself ------------------------------------------------------
      await tester.enterText(
        find.byKey(DiagnoseKeys.inquiryField),
        e2eGroundedInquiry,
      );
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.byKey(DiagnoseKeys.diagnoseButton))
            .onPressed,
        isNotNull,
        reason: 'everything is ready, so the button must be live',
      );

      final runProbe = await _UiIsolateProbe.measure(() async {
        await tester.tap(find.byKey(DiagnoseKeys.diagnoseButton));
        await _pumpUntil(
          tester,
          () =>
              container.read(fieldJobViewModelProvider).phase !=
              FieldJobPhase.thinking,
          const Duration(minutes: 5),
        );
      });

      final job = container.read(fieldJobViewModelProvider);
      debugPrint(
        '[TC-UI-DEMO-01] $runProbe over ${job.result?.turnCount} turns, '
        'answer ${job.displayText.length} chars '
        '(~${(job.displayText.length / (runProbe.elapsed.inMilliseconds / 1000)).toStringAsFixed(0)} chars/s '
        'for the whole flow, tool calls included)',
      );
      debugPrint('[TC-UI-DEMO-01] stop=${job.stopReason?.name}');
      debugPrint('[TC-UI-DEMO-01] answer: ${job.displayText}');

      // The AC: "Answer renders; no exceptions."
      expect(job.phase, FieldJobPhase.done);
      expect(job.stopReason, AgentStopReason.answered);
      expect(job.isDiagnosis, isTrue);
      expect(tester.takeException(), isNull);

      // Rendered, not merely computed — the AC is about the screen.
      await tester.pump();
      expect(
        find.byKey(DiagnoseKeys.outcome(AgentStopReason.answered)),
        findsOneWidget,
      );
      expect(find.text('Repair plan'), findsOneWidget);

      // **The panel renders the answer with its Markdown applied, not raw.** This
      // used to be `find.text(job.displayText)`, and the R0-F5 fix silently broke
      // it: the widget is now a `Text.rich`, and `find.text` matches such a widget
      // by `textSpan.toPlainText()` (`flutter_test/src/finders.dart`,
      // `_matchesNonRichText`), which is the text *after* the delimiters were
      // consumed. Comparing that against the raw `displayText` can never match once
      // the model emits any `**`.
      //
      // The host suite could not have caught it, and that is worth recording: every
      // rendering fixture there used markup-free answer text, so raw and formatted
      // were the same string. Found by reading the finder's source, since this
      // device could not be run at the time.
      //
      // Asserted at the width that matters: the rendered text is the formatted
      // form, and the artefact being screen-recorded contains no raw `**`.
      final renderedAnswer = answerSpans(
        job.displayText,
      ).map((span) => (span as TextSpan).text ?? '').join();
      expect(find.text(renderedAnswer), findsOneWidget);
      expect(
        renderedAnswer,
        isNot(contains('**')),
        reason:
            'the recording must not show raw Markdown; the model emits it '
            'unprompted (14 bold runs in the run-2 answer)',
      );

      // Grounded in the entry the *device's* FTS index retrieved.
      expect(job.retrieval, isNotNull);
      expect(job.retrieval!.entryIds, contains('apex_9_err_102'));
      expect(
        find.textContaining('Traction Brake Pad Wear & Vibration (E-102)'),
        findsOneWidget,
      );

      // The tool ran against the device's own warehouse table, and the answer
      // carries the figure that table holds. Read back so a seed change moves it.
      final part = await database.inventoryPartBySku('BRK-990-XP');
      expect(part, isNotNull);
      expect(
        job.invocations.map((i) => i.call.arguments['sku']),
        contains('BRK-990-XP'),
        reason:
            'the model must have called the inventory tool for the manual\'s '
            'part, or the grounding did not reach it',
      );
      expect(
        job.displayText,
        contains('${part!.stock}'),
        reason: 'the answer must quote the stock the local database returned',
      );
      expect(
        find.text('BRK-990-XP: ${part.stock} in stock at ${part.location}.'),
        findsOneWidget,
        reason: 'the activity line is built from the row, not from the answer',
      );
    },
    timeout: const Timeout(Duration(minutes: 12)),
  );
}

/// Pumps until [condition] holds, or fails after [limit], running [onFrame] after
/// every pumped frame.
///
/// `pumpAndSettle` cannot be used: tokens arriving keep scheduling frames for
/// seconds, so it would either return early or run to its own deadline. This polls
/// the condition between frames, which is what "wait for the model" actually means.
///
/// [onFrame] exists so an assertion can be made about frames *during* the wait
/// rather than about the state after it. That distinction is the whole reason it is
/// here: the first version of this file asserted "no `ProgressIndicator` while the
/// weights load" *after* the wait returned, i.e. once the state was already
/// `EngineReady` — a correct check described at the wrong width, which is the
/// failure mode this project keeps recording. The stall is only observable while it
/// is happening.
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition,
  Duration limit, {
  void Function()? onFrame,
}) async {
  final deadline = Stopwatch()..start();
  while (!condition()) {
    if (deadline.elapsed > limit) {
      fail('timed out after ${limit.inSeconds}s waiting for the condition');
    }
    await tester.pump(const Duration(milliseconds: 50));
    onFrame?.call();
    // Real work — the isolate handshake, sqlite3, the token stream — needs the real
    // event loop, which a pumped frame alone does not give it.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
  }
}

/// Ticks a 16ms timer on the UI isolate while [body] runs, and reports the worst
/// gap between ticks.
///
/// The same instrument as `llm_inference_test.dart`'s, pointed at the UI flow rather
/// than at a bare engine call. A gap far above 16ms is the UI isolate having been
/// blocked, which at 16.7ms per frame is dropped frames — visible in a recording,
/// which is the whole reason Task 1.11 cares.
class _UiIsolateProbe {
  _UiIsolateProbe(this.worstGap, this.ticks, this.elapsed);

  static const Duration _tick = Duration(milliseconds: 16);

  final Duration worstGap;
  final int ticks;
  final Duration elapsed;

  static Future<_UiIsolateProbe> measure(Future<void> Function() body) async {
    final total = Stopwatch()..start();
    final sinceLastTick = Stopwatch()..start();
    var worstGap = Duration.zero;
    var ticks = 0;

    final timer = Timer.periodic(_tick, (_) {
      ticks++;
      final gap = sinceLastTick.elapsed;
      if (gap > worstGap) worstGap = gap;
      sinceLastTick
        ..reset()
        ..start();
    });
    try {
      await body();
    } finally {
      timer.cancel();
      total.stop();
    }
    return _UiIsolateProbe(worstGap, ticks, total.elapsed);
  }

  /// Dropped frames at a 16.7ms budget, derived on the page rather than quoted —
  /// so a reader can check it against [worstGap] instead of trusting it.
  int get droppedFrames => (worstGap.inMilliseconds / 16.7).floor();

  @override
  String toString() =>
      'ui isolate: $ticks ticks over ${elapsed.inMilliseconds}ms, '
      'worst gap ${worstGap.inMilliseconds}ms (~$droppedFrames frames)';
}

/// Build flag that lets this suite fetch the weights when the container is empty.
const String _provisionFlag = 'FIELDOPS_TEST_PROVISION';

const bool _provisionIfMissing = bool.fromEnvironment(_provisionFlag);
