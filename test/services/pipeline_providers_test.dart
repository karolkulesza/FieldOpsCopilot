import 'dart:io';

import 'package:field_ops_copilot/engines/llm_engine.dart';
import 'package:field_ops_copilot/models/form_state_model.dart';
import 'package:field_ops_copilot/services/ai/base_tool.dart';
import 'package:field_ops_copilot/services/ai/providers.dart';
import 'package:field_ops_copilot/services/ai/tools/get_parts_inventory_tool.dart';
import 'package:field_ops_copilot/services/ai/tools/record_work_order_fields_tool.dart';
import 'package:field_ops_copilot/services/database/database_initializer.dart';
import 'package:field_ops_copilot/services/database/database_service.dart';
import 'package:field_ops_copilot/services/database/providers.dart';
import 'package:field_ops_copilot/services/rag/prompt_compiler.dart';
import 'package:field_ops_copilot/services/rag/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Unit-tier coverage for Task 1.11's second deferred wiring: the retrieval and
/// agent halves of the slice, finally given production call sites.
///
/// Tasks 1.4 and 1.5 shipped `RetrievalRouter`, `PromptCompiler`, `ToolRegistry`
/// and `GetPartsInventoryTool` with no provider and no call site, and five task
/// rows record the same reason: each needs a `DatabaseService`, and a database
/// needed a key. These tests are about the *wiring*, not about those classes —
/// their behaviour is bound by `retrieval_router_test.dart`,
/// `prompt_compiler_test.dart` and `tool_registry_test.dart`. What is new here is
/// that the objects the app resolves are built over the **seeded** database, and
/// that they compose.
void main() {
  late Directory tempDir;
  late String shippedJson;

  setUpAll(() async {
    shippedJson = await File('assets/elevator_manual_seed.json').readAsString();
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('fieldops_pipeline');
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  /// Everything real except the two things a host cannot have: the
  /// application-support directory and the asset bundle.
  ProviderContainer container() {
    final result = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) async {
          final database = DatabaseService.encrypted(
            file: File('${tempDir.path}/pipeline.db'),
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
      ],
    );
    addTearDown(result.dispose);
    return result;
  }

  group('retrievalRouterProvider', () {
    // The wiring property: the router the app resolves searches a database that
    // already has the manual in it. Read *first*, before anything else touches the
    // seed, so a dropped ordering dependency shows up here as an empty result
    // rather than as a passing test.
    test('routes over the seeded manual', () async {
      final router = await container().read(retrievalRouterProvider.future);

      final result = await router.retrieve('cabin vibrating, E-102');

      expect(result.entryIds, contains('apex_9_err_102'));
      expect(result.resolvedCodes, contains('E-102'));
    });
  });

  group('toolRegistryProvider', () {
    // Order matters and is asserted rather than sorted: it is the order the model
    // is told about them, and `providers.dart` puts the grounded lookup first
    // deliberately. Task 2.3 added the second one.
    test('declares both tools to the model, lookup first', () async {
      final registry = await container().read(toolRegistryProvider.future);

      expect(registry.toolNames, [
        GetPartsInventoryTool.toolName,
        RecordWorkOrderFieldsTool.toolName,
      ]);
      expect(registry.definitions.first.parameters['required'], [
        GetPartsInventoryTool.skuParameter,
      ]);
      expect(registry.definitions.last.parameters['required'], [
        formUpdatesArgument,
      ]);
    });

    // The form tool is pure and reads nothing, so unlike the lookup below it needs
    // no database — but it does need to be *reachable* through the wired registry,
    // which is the half a unit test of the tool itself cannot cover.
    test('dispatches the form tool through the wired registry', () async {
      final registry = await container().read(toolRegistryProvider.future);

      final outcome = await registry.dispatch(
        const LlmToolCall(
          name: RecordWorkOrderFieldsTool.toolName,
          arguments: {
            formUpdatesArgument: {'fault_code': 'E-102'},
          },
        ),
      );

      expect(outcome, isA<ToolSuccess>());
      expect(outcome.payload[RecordWorkOrderFieldsTool.recordedKey], {
        'fault_code': 'E-102',
      });
    });

    // The tool reads the database, so this is the wiring assertion that matters:
    // a registry built over an unseeded database answers `found: false` for a SKU
    // the warehouse holds — a plausible payload that would send the model on to
    // tell a technician the part is not carried.
    test('dispatches against the seeded inventory, not an empty one', () async {
      final registry = await container().read(toolRegistryProvider.future);

      final outcome = await registry.dispatch(
        const LlmToolCall(
          name: GetPartsInventoryTool.toolName,
          arguments: {GetPartsInventoryTool.skuParameter: 'BRK-990-XP'},
        ),
      );

      expect(outcome, isA<ToolSuccess>());
      expect(outcome.payload['in_stock'], 2);
      expect(outcome.payload['aisle'], 'Aisle 4, Shelf B');
    });
  });

  group('promptCompilerProvider', () {
    test('yields a compiler at the default document budget', () async {
      final compiler = container().read(promptCompilerProvider);

      expect(compiler.maxDocuments, const PromptCompiler().maxDocuments);
    });
  });

  // Task 1.11's brief calls the composition "three lines", and this is those three
  // lines through the resolved providers rather than through hand-built objects.
  // It is a wiring test, so it asserts the *shape* the loop is handed — the spec's
  // §5.2 markers, the retrieved procedure and the technician's words — and leaves
  // the prompt's exact text to `prompt_compiler_test.dart` and the six goldens.
  group('the composition', () {
    test('router → compiler produces a grounded prompt for the loop', () async {
      final c = container();
      final router = await c.read(retrievalRouterProvider.future);
      final compiler = c.read(promptCompilerProvider);

      final prompt = compiler.compile(
        await router.retrieve('cabin vibrating, E-102'),
      );

      expect(prompt, contains(PromptCompiler.manualDocumentMarker));
      expect(prompt, contains(PromptCompiler.userInquiryMarker));
      expect(prompt, contains('BRK-990-XP'));
      expect(prompt, contains('cabin vibrating, E-102'));
      expect(prompt, isNot(contains(PromptCompiler.noMatchNotice)));
    });

    // The SKU the prompt names is the SKU the registry can answer for. Stated as a
    // test because the two halves are wired independently and nothing else would
    // notice them drifting apart: a manual naming a part the warehouse table has
    // never heard of is a grounded prompt that leads to an ungrounded answer.
    test('the part the prompt names is one the registry can look up', () async {
      final c = container();
      final router = await c.read(retrievalRouterProvider.future);
      final registry = await c.read(toolRegistryProvider.future);

      final retrieved = await router.retrieve('cabin vibrating, E-102');
      final sku = retrieved.entries.first.requiredPartsList.single;

      final outcome = await registry.dispatch(
        LlmToolCall(
          name: GetPartsInventoryTool.toolName,
          arguments: {GetPartsInventoryTool.skuParameter: sku},
        ),
      );

      expect(outcome, isA<ToolSuccess>());
      expect(outcome.payload['sku'], sku);
    });
  });
}

/// Seed source over an in-memory string, so the shipped asset is used without a
/// `rootBundle` and its binding. Same shape as `agent_loop_test.dart`'s.
class _TextSeedSource implements SeedSource {
  const _TextSeedSource(this._json);

  final String _json;

  @override
  String get seedId => AssetBundleSeedSource.defaultSeedId;

  @override
  Future<String> loadSeedJson() async => _json;
}
