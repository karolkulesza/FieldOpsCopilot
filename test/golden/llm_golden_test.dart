/// Task 1.10 — the `llm_golden` snapshot suite.
///
/// Six scripted scenarios are driven through the **real** retrieval router, the
/// real prompt compiler, the real agent loop, the real guard and the real
/// registry over a real seeded database, and the whole transcript of each is
/// compared byte-for-byte against a committed file in `snapshots/`. The only
/// faked thing is the model, because it is the only non-deterministic thing:
/// a golden over the device engine would be a flake generator.
///
/// **What a golden buys that the unit suites do not.** Tasks 1.2–1.9 assert
/// *properties* — this prompt contains that marker, that payload reached the next
/// turn. A golden asserts the **whole artefact**, which is the only assertion
/// that notices a change nobody thought to write a property about: a reworded
/// preamble, a reordered document field, an extra blank line between transcript
/// blocks, a fault code that stopped resolving, a tool payload that gained a key.
/// Every one of those changes the string a 2.6GB model is asked to reason about,
/// and none of them fails a single existing test.
///
/// **What a golden cannot buy, stated so its silence is not read as coverage:**
///
/// * **It cannot notice a field the serializer never recorded.** Deleting a key
///   from `transcript_snapshot.dart` breaks a golden — the committed files are
///   the regression guard for the serializer's completeness — but *adding* a
///   field to `AgentTurn` and forgetting to serialise it is invisible here. Dart
///   has no mirrors in Flutter, so there is no mechanical guard for that; the
///   honest mitigation is that this file lists what is covered and
///   `transcript_snapshot.dart` lists what is deliberately left out.
///
///   **And that guard is not uniform**, which the first version of this sentence
///   glossed as "breaks all six goldens at once" (review finding R0-F7). It holds
///   for the top-level and per-turn keys, which every golden has. Below them it
///   thins out with coverage: invocations per golden are 1, 1, 4, **0**, 2, 2, so
///   the invocation and outcome keys are guarded by five of six; rejections are
///   0, 0, 0, 0, **1**, 0, so `_rejection`'s two keys are guarded by
///   `recovery_ladder` **alone**. That is the thin spot, and it is named rather
///   than averaged away.
/// * **It cannot tell a good transcript from a bad one.** A golden says "this is
///   what the code does", never "this is what the code should do" — which is why
///   each scenario below carries a handful of semantic assertions *beside* the
///   byte comparison. Without them a serializer that emitted `{}` for every run
///   would keep all six goldens green forever.
/// * **It is not a model evaluation.** Nothing here says the answer is good.
library;

import 'dart:convert';
import 'dart:io';

import 'package:field_ops_copilot/engines/fakes/fake_llm_engine.dart';
import 'package:field_ops_copilot/engines/llm_engine.dart';
import 'package:field_ops_copilot/services/ai/agent_loop.dart';
import 'package:field_ops_copilot/services/ai/base_tool.dart';
import 'package:field_ops_copilot/services/ai/tool_call_guard.dart';
import 'package:field_ops_copilot/services/ai/tool_registry.dart';
import 'package:field_ops_copilot/models/form_state_model.dart';
import 'package:field_ops_copilot/services/ai/tools/record_work_order_fields_tool.dart';
import 'package:field_ops_copilot/services/ai/tools/get_parts_inventory_tool.dart';
import 'package:field_ops_copilot/services/database/database_initializer.dart';
import 'package:field_ops_copilot/services/database/database_service.dart';
import 'package:field_ops_copilot/services/rag/prompt_compiler.dart';
import 'package:field_ops_copilot/services/rag/retrieval_router.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_file.dart';
import 'transcript_snapshot.dart';

/// One scenario, driven end to end.
typedef ScenarioRun = ({
  RetrievalResult retrieval,
  List<AgentEvent> events,
  AgentRunResult result,
  Map<String, Object?> snapshot,
});

void main() {
  late Directory tempDir;
  late DatabaseService db;
  late ToolRegistry registry;
  late String shippedJson;

  setUpAll(() async {
    shippedJson = await File('assets/elevator_manual_seed.json').readAsString();
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('fieldops_llm_golden_test');
    db = DatabaseService.encrypted(
      file: File('${tempDir.path}/golden.db'),
      encryptionKey: 'llm-golden-test-key',
    );
    await DatabaseInitializer(
      database: db,
      source: _TextSeedSource(shippedJson),
    ).ensureSeeded();
    // **The production tool set, not a subset — Task 2.3.** This registry is what
    // builds the loop's `ToolCallGuard`, so the set of known names is part of what
    // the goldens pin: a near-miss the guard canonicalises depends on which names
    // exist. A golden suite running one tool while the app ships two would stop
    // being a snapshot of the artefact and become a snapshot of a fixture.
    registry = ToolRegistry([
      GetPartsInventoryTool(db),
      RecordWorkOrderFieldsTool(),
    ]);
  });

  tearDown(() async {
    await db.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  /// Retrieves, compiles, runs and serialises one scenario.
  ///
  /// [compiler] is a parameter for exactly one reason: TC-GOLD-02 needs to drive
  /// the same scenario through a **drifted prompt template** and watch the
  /// harness catch it. Every other caller takes the default.
  Future<ScenarioRun> runScenario({
    required String scenario,
    required String inquiry,
    required List<List<LlmEvent>> turns,
    PromptCompiler compiler = const PromptCompiler(),
    int maxTurns = AgentLoop.defaultMaxTurns,
  }) async {
    final retrieval = await RetrievalRouter(db).retrieve(inquiry);
    final prompt = compiler.compile(retrieval);
    final engine = FakeLlmEngine(turns: turns);
    await engine.initialize();
    addTearDown(engine.dispose);

    final loop = AgentLoop(
      engine: engine,
      registry: registry,
      maxTurns: maxTurns,
    );
    final events = <AgentEvent>[];
    AgentRunResult? result;
    await for (final event in loop.run(prompt)) {
      events.add(event);
      if (event is AgentCompleted) result = event.result;
    }
    // Not an `expect`: a null here means the loop's own contract broke, and every
    // assertion after it would be about a fabricated run.
    if (result == null) throw StateError('the loop never completed');

    return (
      retrieval: retrieval,
      events: events,
      result: result,
      snapshot: transcriptSnapshot(
        scenario: scenario,
        retrieval: retrieval,
        events: events,
        result: result,
      ),
    );
  }

  LlmToolCall inventoryCall(String sku) => LlmToolCall(
    name: GetPartsInventoryTool.toolName,
    arguments: {'sku': sku},
  );

  // ---------------------------------------------------------------------------
  // The scenarios. Each is (a) a committed golden and (b) a few assertions that
  // say what the transcript is *supposed* to be, so a golden can never quietly
  // become a snapshot of nothing.
  // ---------------------------------------------------------------------------

  group('TC-GOLD-01 snapshot match', () {
    test('e102_native_tool_call — the spec\'s §5.2 walkthrough', () async {
      // The AC's scenario. Fault code resolves structurally, one document is
      // compiled, the model emits a native call for the SKU the manual names,
      // the real database answers, and the second turn is asked with that answer
      // embedded.
      final run = await runScenario(
        scenario: e102Scenario,
        inquiry: e102Inquiry,
        turns: e102Script(),
      );

      verifyGolden(scenario: e102Scenario, snapshot: run.snapshot);

      // What the golden is supposed to be showing.
      expect(run.result.stopReason, AgentStopReason.answered);
      expect(run.retrieval.resolvedCodes, ['E-102']);
      final invocation = run.result.invocations.single;
      expect(invocation.source, GuardSource.nativeEvent);
      expect(invocation.outcome, isA<ToolSuccess>());
      expect(invocation.outcome.payload['in_stock'], 2);
      expect(run.result.turns[1].prompt, contains('"in_stock":2'));
    });

    test('e305_degraded_text_call — guard, rename, and zero stock', () async {
      // Three things at once, all of which the happy path cannot show: the
      // degraded path (no native event — the call is recovered from prose), a
      // name the model misspelled and the guard canonicalised, and the
      // out-of-stock payload shape. `BELT-330-DRV` is seeded at zero on purpose.
      //
      // The inquiry is 1.2's hostile string, so this golden also pins the
      // sanitizer's terms and `PromptCompiler.escapeQuotes` — the inquiry block
      // is the one place the technician's own quotes reach the prompt.
      final run = await runScenario(
        scenario: 'e305_degraded_text_call',
        inquiry: 'door won\'t close - "stuck" (E-305)',
        turns: [
          [
            const LlmToken('The door belt is the likely cause. Let me check. '),
            const LlmToken(
              '{"tool": "GetLocalPartsInventory", '
              '"arguments": {"sku": " belt-330-drv "}}',
            ),
            const LlmDone(),
          ],
          [
            const LlmToken(
              'The drive belt BELT-330-DRV is out of stock locally (0 units, '
              'Aisle 1, Shelf C). Tension the existing belt by two bolt '
              'rotations if slack exceeds 10mm and order a replacement.',
            ),
            const LlmDone(),
          ],
        ],
      );

      verifyGolden(scenario: 'e305_degraded_text_call', snapshot: run.snapshot);

      final invocation = run.result.invocations.single;
      expect(invocation.source, GuardSource.text);
      expect(invocation.renamedFrom, 'GetLocalPartsInventory');
      expect(invocation.call.name, GetPartsInventoryTool.toolName);
      expect(invocation.outcome.payload['in_stock'], 0);
      // The echo is dropped on this path (1.9's R0-F5/R1-F1): the second prompt
      // must not contain a marker-mangled copy of the JSON the model got right.
      expect(
        run.result.turns[1].prompt,
        isNot(contains(AgentLoop.assistantMarker)),
      );
    });

    test('no_manual_match — nothing retrieved, no tool called', () async {
      final run = await runScenario(
        scenario: 'no_manual_match',
        inquiry: 'escalator handrail torn',
        turns: [
          [
            const LlmToken(
              'The offline manual has no entry for an escalator handrail fault. '
              'Please read the exact fault code from the controller so I can '
              'look it up.',
            ),
            const LlmDone(),
          ],
        ],
      );

      verifyGolden(scenario: 'no_manual_match', snapshot: run.snapshot);

      // The premise: the no-match branch is only meaningful if retrieval really
      // came back empty. `OR`-joined FTS terms match generously (1.2's note), so
      // an inquiry that *looks* unrelated often still hits a document.
      expect(run.retrieval.entries, isEmpty);
      expect(
        run.result.turns.single.prompt,
        contains(PromptCompiler.noMatchNotice),
      );
      expect(run.result.invocations, isEmpty);
      expect(run.result.stopReason, AgentStopReason.answered);
    });

    test('iteration_cap — four tool turns and a stop', () async {
      // Each turn calls a *different* SKU, so the repeat short circuit is not
      // what ends this run — the cap is. (1.9's TC-AGENT-LOOP-02 makes the same
      // distinction; a golden that conflated them would pin the wrong bound.)
      // Four turns also makes this one of the two widest transcripts in the suite
      // — though **not the widest**, which the first version of this comment
      // claimed while calling it "the context ceiling" (review finding R0-F4).
      // Measured over the committed goldens, widest prompt in characters: e102
      // 1485, e305 1363, iteration_cap **2347**, no_manual_match 620,
      // recovery_ladder **2363**, unknown_tool_repeated 2012.
      //
      // The two leaders are 16 characters apart — 0.7% — so they are effectively
      // tied, and **no causal account of the margin is offered here**, because the
      // first attempt at one was wrong twice over (R1-F1): it said "a rejection
      // block plus three tool blocks outweigh four tool blocks" when the widest
      // prompts (turn 3 in both) carry *one rejection plus two* tool blocks against
      // *three*, and the direction does not follow from block composition anyway —
      // `iteration_cap`'s is 47 lines against 45 and has the extra tool block while
      // being the shorter of the two. The transcripts differ in several dimensions
      // at once (block counts, which `[CONTINUE]` instruction each turn earns,
      // scripted assistant text), and attributing 16 characters to one of them
      // would be a third guess. The figures are the result; the explanation was
      // never needed.
      //
      // Neither is a ceiling either: 1.9 measured ~2900 for a *two*-document prompt
      // and every scenario here retrieves exactly one document.
      final run = await runScenario(
        scenario: 'iteration_cap',
        inquiry: 'cabin vibrating, E-102',
        turns: [
          for (final sku in [
            'BRK-990-XP',
            'CAL-050-KIT',
            'FLT-440-HYD',
            'SNS-770-OPT',
          ])
            [
              LlmToken('Checking $sku as well.'),
              inventoryCall(sku),
              const LlmDone(),
            ],
        ],
      );

      verifyGolden(scenario: 'iteration_cap', snapshot: run.snapshot);

      expect(run.result.stopReason, AgentStopReason.iterationCapReached);
      expect(run.result.turnCount, AgentLoop.defaultMaxTurns);
      expect(run.result.answer, AgentLoop.iterationCapMessage);
      expect(
        run.result.invocations.map((i) => i.repeated),
        everyElement(isFalse),
      );
    });

    test('recovery_ladder — rejected, then malformed, then right', () async {
      // The full recovery path in one transcript: a call the *guard* refuses
      // (no tool name), then a call the *registry* refuses (no argument), then a
      // call that works, then the answer. Four turns — exactly `maxTurns`, and
      // ending in an answer rather than at the cap, which is the boundary a
      // golden is better at pinning than an assertion.
      final run = await runScenario(
        scenario: 'recovery_ladder',
        inquiry: 'cabin vibrating, E-102',
        turns: [
          [
            const LlmToken('Looking up the part.'),
            LlmToolCall(name: '  ', arguments: const {'sku': 'BRK-990-XP'}),
            const LlmDone(),
          ],
          [
            const LlmToken('Sorry — calling the inventory tool properly now.'),
            LlmToolCall(
              name: GetPartsInventoryTool.toolName,
              arguments: const {},
            ),
            const LlmDone(),
          ],
          [
            const LlmToken('With the SKU this time.'),
            inventoryCall('BRK-990-XP'),
            const LlmDone(),
          ],
          [
            const LlmToken(
              'BRK-990-XP is in stock: 2 units at Aisle 4, Shelf B. Replace '
              'both pad assemblies and re-set caliper clearance to 0.5mm.',
            ),
            const LlmDone(),
          ],
        ],
      );

      verifyGolden(scenario: 'recovery_ladder', snapshot: run.snapshot);

      expect(run.result.stopReason, AgentStopReason.answered);
      expect(run.result.turnCount, 4);
      expect(
        run.result.turns[0].rejectedCalls.single.reason,
        GuardFailureReason.emptyToolName,
      );
      // A guard refusal and a dispatch failure are different layers refusing,
      // and the transcript must not blur them: the first turn produced no
      // invocation at all, the second produced one that failed.
      expect(run.result.turns[0].invocations, isEmpty);
      expect(
        (run.result.turns[1].invocations.single.outcome as ToolFailure).code,
        ToolFailureCode.missingParameter,
      );
      expect(
        run.result.turns[2].invocations.single.outcome,
        isA<ToolSuccess>(),
      );
      expect(
        run.result.turns[1].prompt,
        contains(AgentLoop.rejectedCallMarker),
      );
    });

    test('unknown_tool_repeated — a hallucinated tool, asked twice', () async {
      // The rule 1.6 spent seven rounds protecting: an unresolvable name is
      // **not** a guard failure — it passes through and `dispatch` answers
      // `unknown_tool`. Asking again replays the recorded outcome instead of
      // dispatching a second time, which is the one bound in this loop that is
      // *not* what terminates it.
      final run = await runScenario(
        scenario: 'unknown_tool_repeated',
        inquiry: 'cabin vibrating, E-102',
        turns: [
          [
            const LlmToken('Checking the warehouse.'),
            LlmToolCall(
              name: 'check_warehouse_stock',
              arguments: const {'sku': 'BRK-990-XP'},
            ),
            const LlmDone(),
          ],
          [
            const LlmToken('Trying that again.'),
            LlmToolCall(
              name: 'check_warehouse_stock',
              arguments: const {'sku': 'BRK-990-XP'},
            ),
            const LlmDone(),
          ],
          [
            const LlmToken(
              'I could not query local stock, so I will not state a stock '
              'level. Replace the BRK-990-XP pad assemblies once you have '
              'confirmed availability.',
            ),
            const LlmDone(),
          ],
        ],
      );

      verifyGolden(scenario: 'unknown_tool_repeated', snapshot: run.snapshot);

      expect(run.result.invocations, hasLength(2));
      final first = run.result.invocations[0];
      final second = run.result.invocations[1];
      expect(first.repeated, isFalse);
      expect(second.repeated, isTrue);
      expect((first.outcome as ToolFailure).code, ToolFailureCode.unknownTool);
      // A replay, not a re-execution: same outcome instance, same payload.
      expect(second.outcome, same(first.outcome));
      expect(run.result.stopReason, AgentStopReason.answered);
    });

    test('form_autofill — the work order recorded and a question asked', () async {
      // **Task 2.3's path through the same pipeline**, which is the whole reason
      // this suite exists rather than a set of assertions: what is pinned is the
      // *artefact* — the tool the model was declared, the arguments it sent, the
      // payload it got back, and the exact text of the next turn's prompt with
      // that payload embedded. An assertion would check one of those.
      //
      // Two turns rather than one, because a recording that is never followed by
      // an answer is not a run a technician sees. The clarification rides on the
      // same call as the fields, which is the shape the tool declares and the one
      // `ClarificationHost` is built around.
      final run = await runScenario(
        scenario: 'form_autofill',
        inquiry: 'cabin vibrating, E-102',
        turns: [
          [
            const LlmToken('Recording what I have so far. '),
            const LlmToolCall(
              name: RecordWorkOrderFieldsTool.toolName,
              arguments: {
                formUpdatesArgument: {
                  'fault_code': 'E-102',
                  'required_parts': 'BRK-990-XP',
                  'elevator_colour': 'green',
                },
                clarificationArgument: {
                  'field': 'safety_checkpoints',
                  'question': 'Which isolation did you perform?',
                  'options': ['Breaker 4A locked out', 'Full car isolation'],
                },
              },
            ),
            const LlmDone(),
          ],
          [
            const LlmToken(
              'Replace the traction brake pad assemblies (BRK-990-XP). I have '
              'filled in the fault code and the part; tell me which isolation '
              'you performed and I will record it.',
            ),
            const LlmDone(),
          ],
        ],
      );

      verifyGolden(scenario: 'form_autofill', snapshot: run.snapshot);

      // What the golden is supposed to be showing, and each line is a decision
      // the tool makes rather than a restatement of the script.
      expect(run.result.stopReason, AgentStopReason.answered);
      final invocation = run.result.invocations.single;
      expect(invocation.outcome, isA<ToolSuccess>());
      final payload = invocation.outcome.payload;
      // A refused field sits beside recorded ones — the call succeeded.
      expect(payload[RecordWorkOrderFieldsTool.recordedKey], {
        'fault_code': 'E-102',
        'required_parts': 'BRK-990-XP',
      });
      expect(payload[RecordWorkOrderFieldsTool.refusedKey], hasLength(1));
      expect(payload[RecordWorkOrderFieldsTool.askedKey], isNotNull);
      // And the payload the *screen* reads is the payload the *model* was given.
      expect(recordedFieldsOf(payload), {
        WorkOrderField.faultCode: 'E-102',
        WorkOrderField.requiredParts: 'BRK-990-XP',
      });
      expect(askedClarificationOf(payload)?.options, [
        'Breaker 4A locked out',
        'Full car isolation',
      ]);
      // The next turn carries the recording back, which is what makes the model
      // able to say what it filled in.
      expect(run.result.turns[1].prompt, contains('"fault_code":"E-102"'));
    });

    test('every committed golden belongs to a scenario above', () async {
      // A golden nobody runs is worse than no golden: it looks like coverage,
      // never fails, and rots. Cheap to prevent, so prevented.
      final committed =
          Directory(goldenDirectory)
              .listSync()
              .whereType<File>()
              .where((f) => f.path.endsWith('.json'))
              .map((f) => f.uri.pathSegments.last.replaceAll('.json', ''))
              .toList()
            ..sort();
      expect(committed, _scenarioNames);
    });
  });

  // ---------------------------------------------------------------------------
  // TC-GOLD-02 — the harness catches drift, demonstrated rather than asserted
  // about. Each case runs a genuinely changed pipeline, serialises it with the
  // real serializer, and reconciles it against the **committed** golden.
  // ---------------------------------------------------------------------------

  group('TC-GOLD-02 regression detected', () {
    /// Reconciles a run against the committed golden without failing the test.
    ///
    /// [verifyGolden] calls `fail()`, which is right for a scenario test and
    /// useless here: a test cannot assert that a failure was *readable* if the
    /// failure aborts it. This goes through the same pure [reconcileGolden] the
    /// shell uses, so what is measured is the shipped comparison and not a
    /// parallel one.
    GoldenReconciliation reconcileAgainstCommitted(
      String scenario,
      Map<String, Object?> snapshot,
    ) {
      final path = goldenPathFor(scenario);
      return reconcileGolden(
        scenario: scenario,
        path: path,
        actual: encodeSnapshot(snapshot),
        committed: File(path).readAsStringSync(),
      );
    }

    /// Every case below drives **TC-GOLD-01's own scenario**, unchanged except
    /// for the one thing under test. Sharing the script rather than writing a
    /// look-alike is what makes "the drifted run mismatched" attributable: the
    /// baseline is the committed golden itself, not a second transcript that
    /// merely resembles it.
    Future<ScenarioRun> e102({PromptCompiler? compiler}) => runScenario(
      scenario: e102Scenario,
      inquiry: e102Inquiry,
      turns: e102Script(),
      compiler: compiler ?? const PromptCompiler(),
    );

    test('the undrifted run of this very script matches', () async {
      // The premise of every case below. Without it, "the drifted run
      // mismatched" is unattributable — a mismatch could just as well mean this
      // helper never matched anything.
      final run = await e102();
      final reconciliation = reconcileAgainstCommitted(
        e102Scenario,
        run.snapshot,
      );

      expect(
        reconciliation.verdict,
        GoldenVerdict.match,
        reason:
            'TC-GOLD-02 measures nothing unless the baseline matches; '
            'report was:\n${reconciliation.report}',
      );
    });

    test('an altered prompt template is caught, with a readable diff', () async {
      final run = await e102(compiler: const _DriftedPromptCompiler());
      final reconciliation = reconcileAgainstCommitted(
        e102Scenario,
        run.snapshot,
      );

      expect(reconciliation.verdict, GoldenVerdict.drift);
      expect(reconciliation.passes, isFalse);

      // "Readable" is the AC's word, so it is spelled out as four checkable
      // things rather than left to taste: the reader is told which file, which
      // line, what the golden said, and what this run produced instead.
      final report = reconciliation.report;
      expect(report, contains(goldenPathFor(e102Scenario)));
      expect(report, contains('first difference at line'));
      expect(report, contains('- '));
      expect(report, contains('+ '));
      expect(report, contains('"Section: Brake Systems"'));
      expect(report, contains('"Sect: Brake Systems"'));
      expect(report, contains('$updateEnvironmentVariable=1'));

      // And the reported region is bounded rather than "everything after line
      // 40". Measured, because the first version of this assertion guessed
      // `lessThan(6)` and the answer is 46 of the golden's 152 lines: the
      // compiled prompt is embedded in *both* turns, so the altered line occurs
      // twice, and `_driftRegion` trims a common prefix and suffix rather than
      // computing an edit script — two changes far apart are one region spanning
      // both. That is the limitation `renderDiff` documents, demonstrated here
      // instead of asserted there.
      final golden = lines(
        File(goldenPathFor(e102Scenario)).readAsStringSync(),
      );
      expect(golden, hasLength(153)); // 152 lines + the trailing newline's ''
      expect(reconciliation.driftingLines, 46);
      // Which is why the report is capped: 46 lines a side would bury the
      // change it is reporting.
      expect(report, contains('more line(s)'));
    });

    test('a changed database row is caught', () async {
      // The other half of what the prompt is made of. This is the drift a
      // property test is least likely to catch, because every assertion about
      // the payload was written from the seed asset in the first place.
      await db.upsertInventoryParts([
        const InventoryPartRow(
          sku: 'BRK-990-XP',
          name: 'Traction Brake Pad Assembly',
          stock: 41,
          location: 'Aisle 9, Shelf Z',
        ),
      ]);

      final reconciliation = reconcileAgainstCommitted(
        e102Scenario,
        (await e102()).snapshot,
      );

      expect(reconciliation.verdict, GoldenVerdict.drift);
      expect(reconciliation.report, contains('Aisle 9, Shelf Z'));
    });

    test('a changed model turn is caught', () async {
      final run = await runScenario(
        scenario: e102Scenario,
        inquiry: e102Inquiry,
        turns: [
          e102Script().first,
          [
            const LlmToken('BRK-990-XP: 41 units, Aisle 9, Shelf Z.'),
            const LlmDone(),
          ],
        ],
      );

      expect(
        reconcileAgainstCommitted(e102Scenario, run.snapshot).verdict,
        GoldenVerdict.drift,
      );
    });

    test('a dropped turn is caught, and the line counts say so', () async {
      // A shorter transcript, not a changed one. Reported as a length change
      // rather than as a wall of shifted lines.
      final run = await runScenario(
        scenario: e102Scenario,
        inquiry: e102Inquiry,
        turns: [
          [
            const LlmToken('BRK-990-XP: 2 units, Aisle 4, Shelf B.'),
            const LlmDone(),
          ],
        ],
      );
      final reconciliation = reconcileAgainstCommitted(
        e102Scenario,
        run.snapshot,
      );

      expect(reconciliation.verdict, GoldenVerdict.drift);
      expect(reconciliation.report, contains('line(s) in the golden'));
    });

    test('a missing golden is not a pass', () async {
      final reconciliation = reconcileGolden(
        scenario: 'a_scenario_nobody_committed',
        path: goldenPathFor('a_scenario_nobody_committed'),
        actual: encodeSnapshot((await e102()).snapshot),
        committed: null,
      );

      expect(reconciliation.verdict, GoldenVerdict.absent);
      expect(reconciliation.passes, isFalse);
      expect(reconciliation.report, contains('$updateEnvironmentVariable=1'));
    });
  });

  group('what the goldens are trusted to be', () {
    test(
      'every AgentTurnStarted prompt is the prompt the turn recorded',
      () async {
        // `transcript_snapshot.dart` omits the event's prompt because it is
        // byte-identical to the turn's, which makes that a claim rather than an
        // observation. This is the observation. Run over the ladder scenario
        // because it is the one with four different prompts.
        final run = await runScenario(
          scenario: 'recovery_ladder',
          inquiry: 'cabin vibrating, E-102',
          turns: [
            [inventoryCall('BRK-990-XP'), const LlmDone()],
            [inventoryCall('CAL-050-KIT'), const LlmDone()],
            [const LlmToken('Both parts are on the shelf.'), const LlmDone()],
          ],
        );

        final started = run.events.whereType<AgentTurnStarted>().toList();
        expect(started, hasLength(run.result.turnCount));
        for (final event in started) {
          expect(event.prompt, run.result.turns[event.index].prompt);
        }
      },
    );

    test('every committed golden is valid, ASCII-only JSON', () async {
      for (final scenario in _scenarioNames) {
        final text = File(goldenPathFor(scenario)).readAsStringSync();
        expect(
          text.codeUnits.every(
            (unit) => unit == 0x0a || (unit >= 0x20 && unit <= 0x7e),
          ),
          isTrue,
          reason:
              '$scenario.json carries a code unit outside printable ASCII; '
              'encodeSnapshot is supposed to escape those so no tool can '
              'mistake U+2028 for a line break',
        );
        expect(text, endsWith('\n'));
        expect(() => jsonDecode(text), returnsNormally);
      }
    });

    test('no golden is trivially empty', () async {
      // The failure mode that would make every test above pass forever: a
      // serializer that returns nothing much, snapshotted and committed.
      for (final scenario in _scenarioNames) {
        final decoded =
            jsonDecode(File(goldenPathFor(scenario)).readAsStringSync())
                as Map<String, Object?>;
        expect(decoded['scenario'], scenario);
        expect(decoded['turns'], isA<List<Object?>>());
        expect((decoded['turns']! as List<Object?>), isNotEmpty);
        expect((decoded['events']! as List<Object?>), isNotEmpty);
        final firstTurn =
            (decoded['turns']! as List<Object?>).first! as Map<String, Object?>;
        expect((firstTurn['prompt']! as List<Object?>).length, greaterThan(5));
      }
    });
  });
}

/// The AC's scenario, named once because two groups drive it: TC-GOLD-01 commits
/// it, and TC-GOLD-02 perturbs it one thing at a time and reconciles against
/// that same commit.
const String e102Scenario = 'e102_native_tool_call';
const String e102Inquiry = 'cabin vibrating, E-102';

/// TC-GOLD-01's E-102 script, as a function rather than a constant.
///
/// `FakeLlmEngine` consumes its turn list, and a shared mutable list handed to
/// two engines is the kind of coupling that makes one test's failure depend on
/// another's order. A fresh list per call costs nothing.
List<List<LlmEvent>> e102Script() => [
  [
    const LlmToken(
      'Cabin vibration at the landings with E-102 points at brake pad wear. ',
    ),
    const LlmToken('Checking local stock for the pad assembly.'),
    LlmToolCall(
      name: GetPartsInventoryTool.toolName,
      arguments: const {'sku': 'BRK-990-XP'},
    ),
    const LlmDone(),
  ],
  [
    const LlmToken(
      'Replace the traction brake pad assemblies. BRK-990-XP is in stock: 2 '
      'units at Aisle 4, Shelf B. Lock out breaker 4A, pull the cowl with a '
      'Torx T20, and set caliper clearance to 0.5mm.',
    ),
    const LlmDone(),
  ],
];

/// The scenarios this file drives, sorted. The directory listing is checked
/// against it so a stale golden cannot linger.
final List<String> _scenarioNames = [
  'e102_native_tool_call',
  'e305_degraded_text_call',
  'form_autofill',
  'iteration_cap',
  'no_manual_match',
  'recovery_ladder',
  'unknown_tool_repeated',
]..sort();

/// A prompt template with one line changed — TC-GOLD-02's "intentionally
/// altered prompt template".
///
/// Subclasses the real compiler and rewrites its output, rather than editing
/// `prompt_compiler.dart` by hand and describing the result in prose. That
/// distinction is the whole of this repo's recorded lesson about claims: a
/// mutation nobody can re-run is a sentence, and this one runs on every CI push.
class _DriftedPromptCompiler extends PromptCompiler {
  const _DriftedPromptCompiler();

  @override
  String compile(RetrievalResult result) =>
      super.compile(result).replaceAll('Section: ', 'Sect: ');
}

/// Feeds seed JSON straight to the initializer, bypassing the asset bundle.
class _TextSeedSource implements SeedSource {
  const _TextSeedSource(this.json);

  final String json;

  @override
  String get seedId => 'elevator_manual_seed';

  @override
  Future<String> loadSeedJson() async => json;
}
