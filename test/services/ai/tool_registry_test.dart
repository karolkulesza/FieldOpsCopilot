import 'dart:convert';
import 'dart:io';

import 'package:field_ops_copilot/engines/fakes/fake_llm_engine.dart';
import 'package:field_ops_copilot/engines/llm_engine.dart';
import 'package:field_ops_copilot/engines/tool_schema.dart';
import 'package:field_ops_copilot/services/ai/base_tool.dart';
import 'package:field_ops_copilot/services/ai/tool_registry.dart';
import 'package:field_ops_copilot/services/ai/tools/get_parts_inventory_tool.dart';
import 'package:field_ops_copilot/services/database/database_initializer.dart';
import 'package:field_ops_copilot/services/database/database_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' show SqliteException;

/// Unit-tier coverage for Task 1.5's tool registry.
///
/// Every inventory assertion runs against a real encrypted database seeded from the
/// **shipped** `assets/elevator_manual_seed.json`, following 1.3 and 1.4: the expected
/// payload in TC-TOOL-EXEC-01 (`in_stock: 2`, `Aisle 4, Shelf B`) is a property of that
/// exact asset, and a fixture would let this suite stay green while the bundled data
/// stopped producing it.
void main() {
  late Directory tempDir;
  late DatabaseService db;
  late ToolRegistry registry;
  late String shippedJson;

  setUpAll(() async {
    shippedJson = await File('assets/elevator_manual_seed.json').readAsString();
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('fieldops_tools_test');
    db = DatabaseService.encrypted(
      file: File('${tempDir.path}/tools.db'),
      encryptionKey: 'tool-registry-test-key',
    );
    await DatabaseInitializer(
      database: db,
      source: _TextSeedSource(shippedJson),
    ).ensureSeeded();
    registry = ToolRegistry([GetPartsInventoryTool(db)]);
  });

  tearDown(() async {
    await db.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<ToolOutcome> callInventory(Map<String, Object?> arguments) =>
      registry.dispatch(
        LlmToolCall(name: GetPartsInventoryTool.toolName, arguments: arguments),
      );

  // ---------------------------------------------------------------------------
  // TC-TOOL-REG-01 — definition generation
  // ---------------------------------------------------------------------------
  group('TC-TOOL-REG-01 definition generation', () {
    test('declares get_local_parts_inventory with a required string sku', () {
      expect(registry.toolNames, [GetPartsInventoryTool.toolName]);

      final definition = registry.definitions.single;
      expect(definition.name, 'get_local_parts_inventory');
      expect(definition.description, isNotEmpty);

      // The AC's three claims, asserted against the map the plugin is actually
      // handed rather than against a convenience getter: `sku` present, typed
      // `string`, and named in `required`.
      expect(definition.parameters['type'], 'object');
      final properties =
          definition.parameters['properties'] as Map<String, Object?>;
      expect(properties.keys, ['sku']);
      final skuSchema = properties['sku'] as Map<String, Object?>;
      expect(skuSchema['type'], 'string');
      expect(skuSchema['description'], isNotEmpty);
      expect(definition.parameters['required'], ['sku']);
    });

    test('the emitted definition satisfies the engine-side schema contract', () {
      // The assertion above pins the map's *contents*; this one pins that the map
      // is a shape the runtime accepts, using the same validator both `LlmEngine`
      // implementations run at registration. Without it, TC-TOOL-REG-01 would be a
      // restatement of the literal in `get_parts_inventory_tool.dart` — the exact
      // failure Task 1.8's review named, where a definition passes the host suite
      // and throws on device.
      expect(validateToolDefinition(registry.definitions.single), isEmpty);
    });

    test('an engine accepts the registry as-is', () async {
      // The end of the chain the two tests above only approach: hand
      // `registry.definitions` to an actual `LlmEngine` and require that it does not
      // throw. `FakeLlmEngine` runs `assertToolDefinitionsUsable` at the call site
      // for exactly this reason (Task 1.8, review round 2).
      final engine = FakeLlmEngine(
        turns: [
          const [LlmToken('ok'), LlmDone()],
        ],
      );
      addTearDown(engine.dispose);
      await engine.initialize();

      await expectLater(
        engine
            .generate(prompt: 'anything', tools: registry.definitions)
            .toList(),
        completes,
      );
    });

    test('rejects a tool whose parameters are not a JSON-Schema object', () {
      // The plausible mistake 1.8 documented: a bare name-to-type map. It reads like
      // a schema, passes analysis, and on the Gemma 3 path is written into the prompt
      // verbatim.
      expect(
        () => ToolRegistry([
          _StubTool(
            const ToolDefinition(
              name: 'bare_map_tool',
              description: 'takes a sku',
              parameters: {'sku': 'String'},
            ),
          ),
        ]),
        throwsA(isA<ToolSchemaException>()),
      );
    });

    test('rejects two tools registered under the same name', () {
      // Guards the constructor's ordering: validating a name-keyed map instead of the
      // list would collapse these two into one entry and this test would pass for the
      // wrong reason — nothing to detect rather than detection working.
      expect(
        () => ToolRegistry([
          GetPartsInventoryTool(db),
          GetPartsInventoryTool(db),
        ]),
        throwsA(
          isA<ToolSchemaException>().having(
            (e) => e.problems.map((p) => p.message).join(),
            'problems',
            contains('declared more than once'),
          ),
        ),
      );
    });

    test('preserves registration order across definitions and names', () {
      final ordered = ToolRegistry([
        _StubTool(_stubDefinition('alpha')),
        GetPartsInventoryTool(db),
        _StubTool(_stubDefinition('omega')),
      ]);
      expect(ordered.toolNames, [
        'alpha',
        GetPartsInventoryTool.toolName,
        'omega',
      ]);
      expect(ordered.definitions.map((d) => d.name), [
        'alpha',
        GetPartsInventoryTool.toolName,
        'omega',
      ]);
    });
  });

  // ---------------------------------------------------------------------------
  // TC-TOOL-EXEC-01 — routing
  // ---------------------------------------------------------------------------
  group('TC-TOOL-EXEC-01 routing', () {
    test('routes to the DB-backed executor and returns the AC payload', () async {
      final outcome = await callInventory({'sku': 'BRK-990-XP'});

      expect(outcome, isA<ToolSuccess>());
      // Whole-map equality, not `containsPair`: the payload *is* the interface with
      // the model, so an extra key is a change to the prompt the next turn sees.
      expect(outcome.payload, {
        'sku': 'BRK-990-XP',
        'in_stock': 2,
        'aisle': 'Aisle 4, Shelf B',
      });
      expect(outcome.toolName, GetPartsInventoryTool.toolName);
    });

    test('the payload came from the database, not from a constant', () async {
      // Without this the test above passes against a hardcoded map. Change the row
      // and the payload must follow.
      await db.upsertInventoryParts([
        InventoryPartRow(
          sku: 'BRK-990-XP',
          name: 'Traction Brake Pad Assembly',
          stock: 41,
          location: 'Aisle 9, Shelf Z',
        ),
      ]);

      final outcome = await callInventory({'sku': 'BRK-990-XP'});
      expect(outcome.payload, {
        'sku': 'BRK-990-XP',
        'in_stock': 41,
        'aisle': 'Aisle 9, Shelf Z',
      });
    });

    test('the model\'s casing and padding still resolve', () async {
      // The reason 1.3 put `normalizeSku` in the query rather than here: the argument
      // arrives from weights. All four forms must reach the same row *and* echo the
      // stored spelling back.
      for (final spelling in [
        'brk-990-xp',
        ' BRK-990-XP ',
        '  brk-990-XP\n',
        'Brk-990-Xp',
      ]) {
        final outcome = await callInventory({'sku': spelling});
        expect(outcome.payload, {
          'sku': 'BRK-990-XP',
          'in_stock': 2,
          'aisle': 'Aisle 4, Shelf B',
        }, reason: spelling);
      }
    });

    test('zero stock is distinguishable from an unknown SKU', () async {
      // The pair `BELT-330-DRV` was seeded at zero stock to make possible. "We do not
      // carry it" and "we carry it and have none" are different answers to a
      // technician, and only the payload shape can tell the model which is true.
      final stockedButEmpty = await callInventory({'sku': 'BELT-330-DRV'});
      expect(stockedButEmpty.payload, {
        'sku': 'BELT-330-DRV',
        'in_stock': 0,
        'aisle': 'Aisle 1, Shelf C',
      });

      final notCarried = await callInventory({'sku': 'BELT-330-XXX'});
      expect(notCarried.payload, {'sku': 'BELT-330-XXX', 'found': false});

      expect(stockedButEmpty.payload, isNot(notCarried.payload));
    });

    test('an unknown SKU is a success, not a failure', () async {
      // A SKU the model invented is a normal tool result — 1.3's `null` return, all
      // the way up. If this came back as a `ToolFailure` the agent loop would treat a
      // perfectly good answer ("we don't stock that") as an error to recover from.
      final outcome = await callInventory({'sku': 'NOPE-000-XX'});
      expect(outcome, isA<ToolSuccess>());
      expect(outcome.payload, {'sku': 'NOPE-000-XX', 'found': false});
    });

    test('the unknown-SKU echo is canonicalised', () async {
      final outcome = await callInventory({'sku': '  nope-000-xx '});
      expect(outcome.payload['sku'], 'NOPE-000-XX');
    });

    test('a row with no location reports aisle: null', () async {
      await db.upsertInventoryParts([
        const InventoryPartRow(
          sku: 'LOC-000-NUL',
          name: 'Unshelved Spare',
          stock: 3,
        ),
      ]);

      final outcome = await callInventory({'sku': 'LOC-000-NUL'});
      expect(outcome.payload, {
        'sku': 'LOC-000-NUL',
        'in_stock': 3,
        'aisle': null,
      });
      // Present-and-null, not absent — the distinction the executor documents.
      expect(outcome.payload.containsKey('aisle'), isTrue);
    });

    test('every payload survives a JSON round-trip', () async {
      // The agent loop serialises these into the next turn. A payload holding a
      // non-encodable value would throw inside the loop, one layer from where the
      // mistake is.
      for (final arguments in <Map<String, Object?>>[
        {'sku': 'BRK-990-XP'},
        {'sku': 'BELT-330-DRV'},
        {'sku': 'NOPE-000-XX'},
        <String, Object?>{},
        {'sku': 7},
      ]) {
        final outcome = await callInventory(arguments);
        expect(
          jsonDecode(jsonEncode(outcome.payload)),
          outcome.payload,
          reason: '$arguments',
        );
      }
    });

    test('extra arguments the model invented are ignored', () async {
      final outcome = await callInventory({
        'sku': 'BRK-990-XP',
        'warehouse': 'Berlin',
        'quantity': 4,
      });
      expect(outcome, isA<ToolSuccess>());
      expect(outcome.payload['in_stock'], 2);
    });

    test('every seeded SKU routes to its own row', () async {
      // A registry that returned the same row for everything would pass the AC.
      final expected = {
        'BRK-990-XP': 2,
        'FLT-440-HYD': 5,
        'BELT-330-DRV': 0,
        'CAL-050-KIT': 12,
        'SNS-770-OPT': 1,
      };
      for (final entry in expected.entries) {
        final outcome = await callInventory({'sku': entry.key});
        expect(outcome.payload['sku'], entry.key, reason: entry.key);
        expect(outcome.payload['in_stock'], entry.value, reason: entry.key);
      }
    });
  });

  // ---------------------------------------------------------------------------
  // TC-TOOL-FAIL-01 — missing parameter
  // ---------------------------------------------------------------------------
  group('TC-TOOL-FAIL-01 missing parameter', () {
    test('empty arguments produce an error naming the missing sku', () async {
      final outcome = await callInventory(const {});

      expect(outcome, isA<ToolFailure>());
      final failure = outcome as ToolFailure;
      expect(failure.code, ToolFailureCode.missingParameter);
      expect(failure.parameter, 'sku');

      // The AC's "error key + field name", asserted on the payload the model reads
      // rather than on the Dart object it happens to be built from.
      expect(outcome.payload['error'], 'missing_parameter');
      expect(outcome.payload['parameter'], 'sku');
      expect(outcome.payload['message'], contains('sku'));
    });

    test('no exception escapes dispatch for a malformed call', () async {
      // A throw here would propagate into the agent loop, whose recovery is to feed
      // the payload back — so a thrown argument error is a hang or a crash, not a
      // retry.
      await expectLater(callInventory(const {}), completes);
    });

    test('a null sku is missing, not invalid', () async {
      final outcome = await callInventory(const {'sku': null});
      expect((outcome as ToolFailure).code, ToolFailureCode.missingParameter);
      expect(outcome.payload['parameter'], 'sku');
      expect(outcome.payload['message'], contains('null'));
    });

    test('a blank sku is missing rather than an empty warehouse', () async {
      // The case that could plausibly have gone the other way: `inventoryPartBySku`
      // returns `null` for a blank SKU, so routing this to `found: false` would have
      // been one line shorter — and would have told the model a part is unstocked
      // when it never named one.
      for (final blank in ['', '   ', '\t\n']) {
        final outcome = await callInventory({'sku': blank});
        expect(outcome, isA<ToolFailure>(), reason: 'blank: "$blank"');
        expect(
          (outcome as ToolFailure).code,
          ToolFailureCode.missingParameter,
          reason: 'blank: "$blank"',
        );
        expect(outcome.payload['message'], contains('blank'));
      }
    });

    test(
      'the three missing-shapes are one code but distinct messages',
      () async {
        final absent = await callInventory(const {});
        final nulled = await callInventory(const {'sku': null});
        final blank = await callInventory(const {'sku': '  '});

        for (final outcome in [absent, nulled, blank]) {
          expect(
            (outcome as ToolFailure).code,
            ToolFailureCode.missingParameter,
          );
        }
        final messages = {
          absent.payload['message'],
          nulled.payload['message'],
          blank.payload['message'],
        };
        expect(messages, hasLength(3));
      },
    );

    test('a non-string sku is invalid, not coerced', () async {
      for (final wrong in <Object>[
        7,
        true,
        3.5,
        ['BRK-990-XP'],
      ]) {
        final outcome = await callInventory({'sku': wrong});
        expect(outcome, isA<ToolFailure>(), reason: '$wrong');
        final failure = outcome as ToolFailure;
        expect(
          failure.code,
          ToolFailureCode.invalidParameter,
          reason: '$wrong',
        );
        expect(failure.parameter, 'sku');
        expect(outcome.payload['error'], 'invalid_parameter');
        expect(outcome.payload['message'], contains('string'));
      }
    });

    test('an unknown tool name is a failure listing what exists', () async {
      final outcome = await registry.dispatch(
        const LlmToolCall(name: 'get_remote_parts_inventory'),
      );

      final failure = outcome as ToolFailure;
      expect(failure.code, ToolFailureCode.unknownTool);
      expect(failure.toolName, 'get_remote_parts_inventory');
      expect(outcome.payload['error'], 'unknown_tool');
      // The available set is in the message so a model that guessed a near-miss name
      // can correct itself on the next turn.
      expect(
        outcome.payload['message'],
        contains(GetPartsInventoryTool.toolName),
      );
      expect(outcome.payload.containsKey('parameter'), isFalse);
    });

    test('tool names match exactly, including case', () async {
      final outcome = await registry.dispatch(
        const LlmToolCall(name: 'Get_Local_Parts_Inventory'),
      );
      expect((outcome as ToolFailure).code, ToolFailureCode.unknownTool);
    });

    test('an Exception from a tool becomes execution_failed', () async {
      final throwing = ToolRegistry([
        _ThrowingTool(_stubDefinition('flaky'), const FormatException('boom')),
      ]);

      final outcome = await throwing.dispatch(const LlmToolCall(name: 'flaky'));

      final failure = outcome as ToolFailure;
      expect(failure.code, ToolFailureCode.executionFailed);
      expect(failure.cause, isA<FormatException>());
      expect(outcome.payload['error'], 'execution_failed');
      // The one thing the payload must NOT do: quote the underlying error. An
      // exception's text routinely carries file paths, SQL and row values, and the
      // payload is prompt text.
      expect(outcome.payload['message'], isNot(contains('boom')));
      expect(jsonEncode(outcome.payload), isNot(contains('boom')));
    });

    test('a real driver exception becomes execution_failed', () async {
      // The test above uses a synthetic `FormatException`, which proves the catch
      // clause fires but not that anything in this app's stack lands in it. This one
      // goes through the real driver: `SqliteException` is declared
      // `implements Exception`, so a genuine SQL failure is recoverable by the loop.
      // Verified in the package rather than assumed —
      // sqlite3-3.3.4/lib/src/exception.dart declares
      // `final class SqliteException implements Exception`.
      final failing = ToolRegistry([
        _BadSqlTool(_stubDefinition('bad_sql'), db),
      ]);

      final outcome = await failing.dispatch(
        const LlmToolCall(name: 'bad_sql'),
      );

      final failure = outcome as ToolFailure;
      expect(failure.code, ToolFailureCode.executionFailed);
      expect(failure.cause, isA<SqliteException>());
      // And the driver's message — which quotes the offending SQL — does not reach
      // the model.
      expect(jsonEncode(outcome.payload), isNot(contains('nonexistent_table')));
    });

    test('a closed database propagates instead of reaching the model', () async {
      // Not the classification this test originally assumed, and the correction is
      // worth keeping rather than papering over: drift raises
      // `StateError: Can't re-open a database after closing it`, an **Error**, so the
      // `on Exception` policy propagates it. That is the right answer and it is drift's
      // own classification — closing the database out from under a running agent loop
      // is a lifecycle defect in this app, not something the model can retry its way
      // out of. Contrast with the driver exception above, which is recoverable.
      await db.close();

      await expectLater(
        callInventory({'sku': 'BRK-990-XP'}),
        throwsA(isA<StateError>()),
      );
    });

    test(
      'an Error from a tool propagates instead of reaching the model',
      () async {
        // The deliberate asymmetry with the test above. An `Error` means the app is
        // broken; handing it to the model as `execution_failed` would get it
        // paraphrased to a technician and retried. `on Exception` rather than
        // `on Object` is what makes this hold — pinned so nobody widens it.
        final broken = ToolRegistry([
          _ThrowingTool(_stubDefinition('broken'), StateError('bug')),
        ]);

        await expectLater(
          broken.dispatch(const LlmToolCall(name: 'broken')),
          throwsA(isA<StateError>()),
        );
      },
    );

    test('a failed call still names the tool it was aimed at', () async {
      final outcome = await callInventory(const {});
      expect(outcome.toolName, GetPartsInventoryTool.toolName);
    });
  });

  // ---------------------------------------------------------------------------
  // Registry surface
  // ---------------------------------------------------------------------------
  group('registry surface', () {
    test('toolNamed resolves a registered tool and nothing else', () {
      expect(
        registry.toolNamed(GetPartsInventoryTool.toolName),
        isA<GetPartsInventoryTool>(),
      );
      expect(registry.toolNamed('nope'), isNull);
    });

    test('an empty registry declares nothing and rejects every call', () async {
      final empty = ToolRegistry(const []);
      expect(empty.definitions, isEmpty);
      expect(empty.toolNames, isEmpty);

      final outcome = await empty.dispatch(
        const LlmToolCall(name: GetPartsInventoryTool.toolName),
      );
      expect((outcome as ToolFailure).code, ToolFailureCode.unknownTool);
    });

    test('an argument-less tool is legitimate', () async {
      // `tool_schema.dart` allows an empty `parameters` map, and the registry must
      // not have added a rule of its own.
      final noArgs = ToolRegistry([
        _StubTool(
          const ToolDefinition(
            name: 'read_technician_profile',
            description: 'Returns the signed-in technician profile.',
          ),
          payload: const {'id': 'tech-1'},
        ),
      ]);
      final outcome = await noArgs.dispatch(
        const LlmToolCall(name: 'read_technician_profile'),
      );
      expect(outcome, isA<ToolSuccess>());
      expect(outcome.payload, {'id': 'tech-1'});
    });

    test('the tool list cannot be mutated after construction', () {
      final tools = <AgentTool>[GetPartsInventoryTool(db)];
      final built = ToolRegistry(tools);
      tools.add(_StubTool(_stubDefinition('late_arrival')));

      // The copy is what keeps `definitions` and the dispatch table in agreement: a
      // tool added after the model was told about the set would be dispatchable but
      // undeclared.
      expect(built.toolNames, [GetPartsInventoryTool.toolName]);
      expect(built.toolNamed('late_arrival'), isNull);
    });
  });
}

ToolDefinition _stubDefinition(String name) => ToolDefinition(
  name: name,
  description: 'Test tool named $name.',
  parameters: objectSchema(
    properties: {
      'value': {'type': 'string', 'description': 'anything'},
    },
  ),
);

/// A tool that returns [payload] without touching anything.
class _StubTool extends AgentTool {
  _StubTool(this.definition, {this.payload = const {'ok': true}});

  @override
  final ToolDefinition definition;

  final Map<String, Object?> payload;

  @override
  Future<Map<String, Object?>> execute(Map<String, Object?> arguments) async =>
      payload;
}

/// A tool that always throws [error], to exercise the two catch policies.
class _ThrowingTool extends AgentTool {
  _ThrowingTool(this.definition, this.error);

  @override
  final ToolDefinition definition;

  final Object error;

  @override
  Future<Map<String, Object?>> execute(Map<String, Object?> arguments) async =>
      throw error;
}

/// A tool that provokes a real [SqliteException] from the driver.
class _BadSqlTool extends AgentTool {
  _BadSqlTool(this.definition, this._database);

  @override
  final ToolDefinition definition;

  final DatabaseService _database;

  @override
  Future<Map<String, Object?>> execute(Map<String, Object?> arguments) async {
    await _database.customSelect('SELECT * FROM nonexistent_table').get();
    return const {'unreachable': true};
  }
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
