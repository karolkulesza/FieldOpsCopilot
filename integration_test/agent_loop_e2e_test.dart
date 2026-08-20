import 'dart:io';

import 'package:field_ops_copilot/engines/impl/gemma_llm_engine.dart';
import 'package:field_ops_copilot/services/ai/agent_loop.dart';
import 'package:field_ops_copilot/services/ai/base_tool.dart';
import 'package:field_ops_copilot/services/ai/tool_registry.dart';
import 'package:field_ops_copilot/services/ai/tools/get_parts_inventory_tool.dart';
import 'package:field_ops_copilot/services/database/database_initializer.dart';
import 'package:field_ops_copilot/services/database/database_service.dart';
import 'package:field_ops_copilot/services/inference/inference_config.dart';
import 'package:field_ops_copilot/services/inference/providers.dart';
import 'package:field_ops_copilot/services/models/model_descriptor.dart';
import 'package:field_ops_copilot/services/models/model_provisioner.dart';
import 'package:field_ops_copilot/services/models/model_storage.dart';
import 'package:field_ops_copilot/services/rag/prompt_compiler.dart';
import 'package:field_ops_copilot/services/rag/retrieval_router.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'e2e_fixtures.dart';

/// TC-AGENT-E2E-01 — the whole retrieve-to-answer slice on a real device, against real
/// weights and the real seeded database.
///
/// ```sh
/// flutter test integration_test/agent_loop_e2e_test.dart -d <device id> \
///   --dart-define=FIELDOPS_MODEL_URI=<resolve URL for the file you licensed> \
///   --dart-define=FIELDOPS_MODEL_SHA256=<its sha256>
/// ```
///
/// Everything about weights, skipping and the opt-in provisioning switch works
/// exactly as in `llm_inference_test.dart`, and for the same reasons — see that
/// file's header. What is different is what is under test: 1.8 proved the model
/// emits a structured tool call from a *hand-written* grounded prompt, and this
/// suite replaces every hand-written part with the real one. The prompt comes
/// from the real prompt compiler over the seeded database, the tool is the real
/// registry's over that same database, and the round trip is the real agent loop.
///
/// **Assertions are fuzzy, and deliberately so.** A model's wording is not a
/// contract. What is asserted is that the loop completed rather than hitting its
/// cap, that it called the inventory tool for the SKU the manual names, and that
/// the answer contains the stock figure the *database* holds — the property the
/// whole grounding path exists to produce, and the one a model answering from
/// its weights cannot satisfy by luck, because 2 units in Aisle 4, Shelf B is
/// not a fact about elevators.
///
/// It also prints the one measurement only a device can settle: the character
/// length of both turns' prompts against `InferenceConfig.defaultContextTokens`. The
/// host suite bounds those characters; only this run can say whether the window
/// holds them.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final descriptor = ModelCatalog.active;

  GemmaLlmEngine? engine;
  DatabaseService? db;
  Directory? tempDir;
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
      debugPrint('[TC-AGENT] provisioning weights first (opt-in)');
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
    if (skipReason.isNotEmpty) return;

    // A throwaway database per run, seeded from the bundled asset through the
    // real `rootBundle` path. The demo flow owns the durable database and the key
    // that goes with it; this suite only needs the seed to be the shipped one.
    tempDir = await Directory.systemTemp.createTemp('fieldops_agent_e2e');
    final database = DatabaseService.encrypted(
      file: File('${tempDir!.path}/agent_e2e.db'),
      encryptionKey: 'agent-e2e-integration-key',
    );
    final seed = await DatabaseInitializer(database: database).ensureSeeded();
    debugPrint('[TC-AGENT] seed: ${seed.runtimeType}');
    db = database;

    final candidate = GemmaLlmEngine(
      config: InferenceConfig(
        modelPath: storage.installedFile(descriptor).path,
        family: inferenceFamilyFor(descriptor.id),
      ),
    );
    await candidate.initialize();
    engine = candidate;
  });

  tearDownAll(() async {
    await engine?.dispose();
    await db?.close();
    if (tempDir?.existsSync() ?? false) {
      await tempDir!.delete(recursive: true);
    }
  });

  testWidgets(
    'TC-AGENT-E2E-01: a typed inquiry produces a grounded answer with real stock',
    (tester) async {
      if (skipReason.isNotEmpty) {
        markTestSkipped(skipReason);
        return;
      }
      final database = db!;

      // The AC's input, typed as a technician would. Shared with the host
      // suite, which checks this premise in CI — see `e2e_fixtures.dart`.
      final retrieved = await RetrievalRouter(
        database,
      ).retrieve(e2eGroundedInquiry);
      // A premise, not an assertion about the loop: if retrieval missed, every
      // downstream failure would be misattributed to the model.
      expect(retrieved.entryIds, contains('apex_9_err_102'));

      final prompt = const PromptCompiler().compile(retrieved);
      final registry = ToolRegistry([GetPartsInventoryTool(database)]);
      final loop = AgentLoop(engine: engine!, registry: registry);

      // Timed per turn as well as overall. The first device run reported only
      // a total (11332ms for two turns), which cannot be turned into a
      // throughput figure — and throughput is still unmeasured, with the recorded
      // "2.7 tok/s" being arithmetic rather than a measurement. A per-turn split
      // plus the generated character count is what makes the next run able to
      // close that.
      final stopwatch = Stopwatch()..start();
      final turnElapsed = <int>[];
      var lastMark = 0;
      final result = await loop
          .run(prompt)
          .map((event) {
            if (event is AgentTurnStarted && event.index > 0) {
              turnElapsed.add(stopwatch.elapsedMilliseconds - lastMark);
              lastMark = stopwatch.elapsedMilliseconds;
            }
            return event;
          })
          .fold<AgentRunResult?>(
            null,
            (acc, e) => e is AgentCompleted ? e.result : acc,
          )
          .then((r) => r!);
      stopwatch.stop();
      turnElapsed.add(stopwatch.elapsedMilliseconds - lastMark);

      for (final turn in result.turns) {
        final ms = turn.index < turnElapsed.length
            ? turnElapsed[turn.index]
            : -1;
        debugPrint(
          '[TC-AGENT-E2E-01] turn ${turn.index}: '
          'prompt ${turn.prompt.length} chars, '
          'text ${turn.text.length} chars, '
          'tools ${turn.invocations.length}, '
          'rejected ${turn.rejectedCalls.length}, '
          'elapsed ${ms}ms'
          '${turn.text.isEmpty || ms <= 0 ? '' : ' (~${(turn.text.length / (ms / 1000)).toStringAsFixed(0)} chars/s generated)'}',
        );
      }
      debugPrint(
        '[TC-AGENT-E2E-01] stop=${result.stopReason.name} '
        'turns=${result.turnCount} '
        'elapsed=${stopwatch.elapsedMilliseconds}ms '
        'context=${InferenceConfig.defaultContextTokens} tokens',
      );
      debugPrint('[TC-AGENT-E2E-01] answer: ${result.answer}');

      // The loop finished because the model answered, not because a bound fired.
      expect(result.stopReason, AgentStopReason.answered);
      expect(result.turnCount, greaterThanOrEqualTo(2));

      // It called the inventory tool for the SKU E-102's procedure names, and the
      // call succeeded. Nothing is asserted about *how* it was phrased.
      final inventoryCalls = result.invocations.where(
        (i) => i.call.name == GetPartsInventoryTool.toolName,
      );
      expect(inventoryCalls, isNotEmpty);
      expect(
        inventoryCalls.map((i) => i.call.arguments['sku']),
        contains('BRK-990-XP'),
      );
      expect(
        inventoryCalls.every((i) => i.outcome is ToolSuccess),
        isTrue,
        reason: 'a failed lookup means the tool never reached the database',
      );

      // The answer carries the stock figure the database holds. Read back rather
      // than written as `2`, so a seed change moves the assertion with it.
      final part = await database.inventoryPartBySku('BRK-990-XP');
      expect(part, isNotNull);
      expect(
        result.answer,
        contains('${part!.stock}'),
        reason: 'the answer must quote the stock the tool returned',
      );
      expect(result.answer.toUpperCase(), contains('BRK-990-XP'));
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );

  testWidgets(
    'TC-AGENT-E2E-01b: an inquiry with no manual entry is refused, not invented',
    (tester) async {
      if (skipReason.isNotEmpty) {
        markTestSkipped(skipReason);
        return;
      }
      final database = db!;

      // The other half of grounding, and the half a happy-path test cannot see:
      // the prompt compiler's no-match block tells the model there is no entry and
      // not to call any tool. If the loop still produces a confident procedure, the
      // grounding is decorative.
      // The fixture is shared with the host suite, which pins this premise in
      // CI. It had to be: the first one — "the hydraulic ram on the loading
      // crane is leaking" — retrieved two entries, so this test failed here on
      // device, before the model was asked anything. `hydraulic` is in the
      // manual (E-204's symptoms name the hydraulic manifold), and separately
      // the stop words `the`/`on`/`is` each match on their own. See
      // `e2e_fixtures.dart` and `tc_agent_e2e_premises_test.dart`.
      final retrieved = await RetrievalRouter(
        database,
      ).retrieve(e2eNoMatchInquiry);
      expect(
        retrieved.isEmpty,
        isTrue,
        reason: 'pinned on the host by tc_agent_e2e_premises_test.dart',
      );

      final registry = ToolRegistry([GetPartsInventoryTool(database)]);
      final loop = AgentLoop(engine: engine!, registry: registry);
      final result = await loop.runToCompletion(
        const PromptCompiler().compile(retrieved),
      );

      debugPrint('[TC-AGENT-E2E-01b] answer: ${result.answer}');
      debugPrint(
        '[TC-AGENT-E2E-01b] stop=${result.stopReason.name} '
        'tools=${result.invocations.length}',
      );

      expect(result.stopReason, AgentStopReason.answered);
      // Fuzzy, as the tier requires: no tool call is a *structural* fact the
      // no-match block asks for, and it is checkable without pinning wording.
      expect(result.invocations, isEmpty);
      // And the one SKU it could plausibly hallucinate is not in the answer.
      expect(result.answer.toUpperCase(), isNot(contains('BRK-990-XP')));
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

/// Build flag that lets this suite fetch the weights when the container is empty.
const String _provisionFlag = 'FIELDOPS_TEST_PROVISION';

const bool _provisionIfMissing = bool.fromEnvironment(_provisionFlag);
