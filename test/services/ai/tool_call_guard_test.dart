import 'dart:convert';
import 'dart:io';

import 'package:field_ops_copilot/engines/llm_engine.dart';
import 'package:field_ops_copilot/services/ai/base_tool.dart';
import 'package:field_ops_copilot/services/ai/tool_call_guard.dart';
import 'package:field_ops_copilot/services/ai/tool_registry.dart';
import 'package:field_ops_copilot/services/ai/tools/get_parts_inventory_tool.dart';
import 'package:field_ops_copilot/services/database/database_initializer.dart';
import 'package:field_ops_copilot/services/database/database_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Unit-tier coverage for Task 1.6's defensive tool-call guard.
///
/// Two things this suite deliberately does *not* fake:
///
/// * **the tool name** — every guard here is built from `registry.toolNames`, so a test
///   asserting that `Get_Local_Parts_Inventory` canonicalises is asserting it against
///   the name Task 1.5 actually declares. A hard-coded name list would let this suite
///   stay green while the registry renamed the tool out from under it.
/// * **the consumer** — the composition group dispatches guarded calls through a real
///   `ToolRegistry` over a real seeded database, because the whole claim of this task is
///   that its output feeds straight into `dispatch`. Asserting the guard's return value
///   alone would leave that claim untested.
void main() {
  const toolName = GetPartsInventoryTool.toolName;

  // A guard over the shipped registry's names, built without a database: everything
  // except the composition group needs the names and nothing else.
  final guard = ToolCallGuard(const [toolName]);

  /// The call inside [result], failing the test with the failure's message otherwise.
  LlmToolCall guardedCall(GuardResult result) {
    expect(
      result,
      isA<GuardedCall>(),
      reason: 'expected a guarded call, got $result',
    );
    return (result as GuardedCall).call;
  }

  // ---------------------------------------------------------------------------
  // TC-GUARD-OK-01 — a well-formed native event passes through
  // ---------------------------------------------------------------------------
  group('TC-GUARD-OK-01 native event passes through', () {
    test('returns the identical call instance, unchanged', () {
      const call = LlmToolCall(
        name: toolName,
        arguments: {'sku': 'BRK-990-XP'},
      );

      final result = guard.inspectEvent(call);

      // The AC's method is "assert identity", and it is meant literally: the guard
      // rewrites nothing on the primary path, so the object the runtime produced is the
      // object handed to `dispatch`. `identical` rather than `==` on purpose —
      // `LlmToolCall` defines no `==`, so an equality check here would be an identity
      // check wearing a disguise, and would start passing for a copy the day someone
      // adds value equality.
      final guarded = result as GuardedCall;
      expect(identical(guarded.call, call), isTrue);
      expect(guarded.source, GuardSource.nativeEvent);
      expect(guarded.renamedFrom, isNull);

      // Named separately from the identity assertion above: identity would still hold
      // if the guard had mutated the map in place.
      expect(guarded.call.name, toolName);
      expect(guarded.call.arguments, {'sku': 'BRK-990-XP'});
    });

    test('passes through a native call with no arguments', () {
      const call = LlmToolCall(name: toolName);

      final guarded = guard.inspectEvent(call) as GuardedCall;

      expect(identical(guarded.call, call), isTrue);
      expect(guarded.call.arguments, isEmpty);
    });

    test('passes through a name it does not know, so dispatch can reject it', () {
      // The rule this pins: a guard failure means "there is no tool call here", not
      // "that tool does not exist". Turning an unknown name into a `GuardFailure` would
      // give one condition two different reports depending on which layer saw it first.
      const call = LlmToolCall(name: 'schedule_followup_appointment');

      final guarded = guard.inspectEvent(call) as GuardedCall;

      expect(identical(guarded.call, call), isTrue);
      expect(guarded.call.name, 'schedule_followup_appointment');
    });
  });

  // ---------------------------------------------------------------------------
  // TC-GUARD-TXT-01 — a prose-wrapped JSON call is extracted
  // ---------------------------------------------------------------------------
  group('TC-GUARD-TXT-01 prose-wrapped JSON extracted', () {
    test('extracts the call from the AC input verbatim', () {
      // The AC's input string, character for character.
      const text =
          'Here is your tool call:\n\n{"tool":"get_local_parts_inventory",'
          '"arguments":{"sku":"BRK-990-XP"}}';

      final result = guard.inspectText(text);

      final call = guardedCall(result);
      expect(call.name, 'get_local_parts_inventory');
      expect(call.arguments, {'sku': 'BRK-990-XP'});
      expect((result as GuardedCall).source, GuardSource.text);
      expect(result.renamedFrom, isNull);
    });

    test('extracts a call from a fenced code block with prose either side', () {
      const text = '''
I'll check the warehouse for you.

```json
{
  "tool": "get_local_parts_inventory",
  "arguments": { "sku": "BRK-990-XP" }
}
```

Once I have the stock level I'll finish the plan.''';

      final call = guardedCall(guard.inspectText(text));

      // No fence syntax is enumerated anywhere in the guard — the scan looks for a JSON
      // object, so a fence, an XML-ish tag and a bare object are the same input to it.
      expect(call.name, toolName);
      expect(call.arguments, {'sku': 'BRK-990-XP'});
    });

    test('extracts a call wrapped in a tool-call tag', () {
      const text =
          '<tool_call>{"name": "get_local_parts_inventory", '
          '"arguments": {"sku": "BRK-990-XP"}}</tool_call>';

      expect(guardedCall(guard.inspectText(text)).name, toolName);
    });

    test('reads the OpenAI-shaped envelope', () {
      const text =
          '{"type": "function", "function": {"name": '
          '"get_local_parts_inventory", "arguments": "{\\"sku\\": '
          '\\"BRK-990-XP\\"}"}}';

      final call = guardedCall(guard.inspectText(text));

      // Two leniencies in one input: the call is nested under `function`, and its
      // arguments arrive as a JSON *string* rather than an object.
      //
      // The nesting costs no code — the scan offers the inner object as its own
      // candidate once the outer one is rejected for carrying no name string. This
      // comment used to credit an explicit recursion in `_callFromObject`; deleting that
      // recursion left this test green, which is what proved the scan had been doing the
      // work, so the recursion is gone.
      expect(call.name, toolName);
      expect(call.arguments, {'sku': 'BRK-990-XP'});
    });

    test('a decoded argument that jsonEncode would refuse is a failure', () {
      // R0-F1: this path skipped the encodability probe because decoded arguments were
      // claimed "JSON-encodable by construction". A numeric literal that overflows a
      // double decodes to `Infinity`, which `jsonEncode` refuses — so the guard was
      // handing the agent loop the exact value whose serialisation throws an
      // uncatchable `Error`. Measured: `jsonDecode('{"n": 1e400}')` yields `Infinity`.
      const text = '{"tool": "$toolName", "arguments": {"qty": 1e400}}';

      final result = guard.inspectText(text);

      expect(result, isA<GuardFailure>());
      expect(
        (result as GuardFailure).reason,
        GuardFailureReason.argumentsNotEncodable,
      );
    });

    test('the overflow case really does decode to a value jsonEncode refuses', () {
      // The premise of the test above, asserted rather than assumed — otherwise it could
      // go green for some unrelated parse failure and still leave the hole open.
      final decoded = jsonDecode('{"qty": 1e400}') as Map<String, Object?>;

      expect(decoded['qty'], isA<double>());
      expect((decoded['qty']! as double).isFinite, isFalse);
      expect(
        () => jsonEncode(decoded),
        throwsA(isA<JsonUnsupportedObjectError>()),
      );
    });

    test('a nested decoded overflow is caught too', () {
      const text = '{"tool": "$toolName", "arguments": {"a": {"b": [1e999]}}}';

      expect(
        (guard.inspectText(text) as GuardFailure).reason,
        GuardFailureReason.argumentsNotEncodable,
      );
    });

    test('accepts each name key alias', () {
      for (final key in ['tool', 'tool_name', 'name', 'function_name']) {
        final text =
            '{"$key": "$toolName", "arguments": {"sku": "BRK-990-XP"}}';
        expect(
          guardedCall(guard.inspectText(text)).name,
          toolName,
          reason: 'name key "$key" should be read',
        );
      }
    });

    test('accepts each argument key alias', () {
      for (final key in ['arguments', 'args', 'parameters', 'input']) {
        final text = '{"tool": "$toolName", "$key": {"sku": "BRK-990-XP"}}';
        expect(
          guardedCall(guard.inspectText(text)).arguments,
          {'sku': 'BRK-990-XP'},
          reason: 'argument key "$key" should be read',
        );
      }
    });

    test('an unbalanced brace inside a string value does not truncate it', () {
      // The reason `_matchingBrace` tracks string state rather than counting braces:
      // a SKU containing a brace is nonsense, but a *procedure step* quoted into an
      // argument is not, and one unbalanced brace in a string would otherwise cut the
      // object short and leave the whole call unparseable.
      //
      // The fixture must be **unbalanced** for that to be what is tested. It was
      // `"A}B{C"` — a matched `}`…`{` pair, which a plain brace counter walks straight
      // through to the same closing brace, so the test was green with or without string
      // tracking and its comment claimed otherwise (R0-F2). With `"A}B"` a counter closes
      // on the in-string `}`, the extent loses its final `}`, and `jsonDecode` rejects it.
      const text = '{"tool": "$toolName", "arguments": {"sku": "A}B"}}';

      expect(guardedCall(guard.inspectText(text)).arguments, {'sku': 'A}B'});
    });

    test('the first name key and argument key in preference order win', () {
      // `_nameKeys` and `_argumentKeys` are documented "in preference order" and nothing
      // bound that: no other fixture carries two name keys or two argument keys, so
      // reversing either list failed no test (R0-F3). An object with both has to resolve
      // somehow, and this is the answer — `tool` before `name`, `arguments` before
      // `parameters`.
      const text =
          '{"tool": "$toolName", "name": "some_other_tool", '
          '"arguments": {"sku": "BRK-990-XP"}, "parameters": {"sku": "WRONG-000"}}';

      final call = guardedCall(guard.inspectText(text));

      expect(call.name, toolName);
      expect(call.arguments, {'sku': 'BRK-990-XP'});
    });

    test('an escaped quote inside a string value does not end it', () {
      const text =
          r'{"tool": "get_local_parts_inventory", '
          r'"arguments": {"sku": "A\"}B"}}';

      expect(guardedCall(guard.inspectText(text)).arguments, {'sku': 'A"}B'});
    });

    test('extracts a call from inside a JSON array', () {
      const text =
          '[{"tool": "$toolName", "arguments": {"sku": "BRK-990-XP"}}]';

      // The scan starts at every `{`, so a top-level array needs no special case.
      expect(guardedCall(guard.inspectText(text)).name, toolName);
    });

    test('skips JSON that is not a call and takes the first usable object', () {
      const text =
          'State: {"status": "thinking", "step": 2}. '
          'Also {"name": "Bob", "age": 3}. '
          'Now calling: {"tool": "$toolName", "arguments": {"sku": "PLC-77-CTRL"}}';

      final call = guardedCall(guard.inspectText(text));

      // `{"name": "Bob", "age": 3}` is the case the evidence rule exists for: it has a
      // name key, so without that rule it would win here and this assertion would read
      // `Bob`.
      expect(call.name, toolName);
      expect(call.arguments, {'sku': 'PLC-77-CTRL'});
    });

    test('takes the first of two textual calls', () {
      const text =
          '{"tool": "$toolName", "arguments": {"sku": "FIRST-000-AA"}} then '
          '{"tool": "$toolName", "arguments": {"sku": "SECOND-000-BB"}}';

      expect(guardedCall(guard.inspectText(text)).arguments, {
        'sku': 'FIRST-000-AA',
      });
    });

    test('an absent arguments key yields an empty map, not a failure', () {
      // A tool may legitimately take none, and for one that does not, `{}` reaches the
      // registry as `missing_parameter` — accurate, since the model named no value.
      final call = guardedCall(guard.inspectText('{"tool": "$toolName"}'));

      expect(call.arguments, isEmpty);
    });

    test('an explicitly null arguments value yields an empty map', () {
      final call = guardedCall(
        guard.inspectText('{"tool": "$toolName", "arguments": null}'),
      );

      expect(call.arguments, isEmpty);
    });

    test('extracted arguments survive a jsonEncode round-trip', () {
      // Task 1.9 serialises the attempted call into the next turn, so this is a
      // property of the guard's output rather than a curiosity.
      const text =
          '{"tool": "$toolName", "arguments": {"sku": "BRK-990-XP", '
          '"nested": {"a": [1, 2.5, true, null]}}}';

      final call = guardedCall(guard.inspectText(text));

      expect(jsonDecode(jsonEncode(call.arguments)), call.arguments);
    });
  });

  // ---------------------------------------------------------------------------
  // TC-GUARD-BAD-01 — unparseable input becomes a typed failure, never a throw
  // ---------------------------------------------------------------------------
  group('TC-GUARD-BAD-01 unparseable input yields a typed failure', () {
    test('garbage text is a noToolCallFound failure and does not throw', () {
      const garbage = r'''
Sure!! ###{{{ tool call:: get inventory ]] "sku" -> BRK-990-XP <<<
{unquoted: nope, "trailing":,} }}} ???''';

      // The "no throw" half of the AC is asserted first and separately: a throw here
      // would propagate into the agent loop, whose recovery for a bad call is to feed a
      // payload back — it has nothing to feed back if the guard blew up.
      late final GuardResult result;
      expect(() => result = guard.inspectText(garbage), returnsNormally);

      expect(result, isA<GuardFailure>());
      final failure = result as GuardFailure;
      expect(failure.reason, GuardFailureReason.noToolCallFound);
      expect(failure.message, isNotEmpty);
    });

    for (final entry in const {
      'empty string': '',
      'whitespace only': '   \n\t ',
      'plain prose': 'The brake pad is worn; replace it and re-test the car.',
      'unbalanced open brace': '{"tool": "get_local_parts_inventory"',
      'braces with no JSON in them': 'oh no {{{{{{{{',
      'a JSON array of scalars': '[1, 2, 3]',
      'a JSON scalar': '"get_local_parts_inventory"',
      'an object with no name key': '{"sku": "BRK-990-XP"}',
      'a name key that is not a string': '{"tool": 42}',
      'an unknown name with no arguments key': '{"name": "Bob", "age": 3}',
    }.entries) {
      test('${entry.key} is noToolCallFound', () {
        final result = guard.inspectText(entry.value);

        expect(result, isA<GuardFailure>(), reason: 'input: ${entry.value}');
        expect(
          (result as GuardFailure).reason,
          GuardFailureReason.noToolCallFound,
        );
      });
    }

    test('a blank name beside an arguments key is emptyToolName', () {
      // Reported as a malformed call rather than "no call", because the arguments key is
      // the evidence that a call was attempted — the same evidence rule that keeps
      // `{"name": "Bob"}` out of the call path.
      final result = guard.inspectText('{"tool": "   ", "arguments": {}}');

      expect((result as GuardFailure).reason, GuardFailureReason.emptyToolName);
    });

    for (final entry in const {
      'a list': '{"tool": "get_local_parts_inventory", "arguments": [1, 2]}',
      'a number': '{"tool": "get_local_parts_inventory", "arguments": 7}',
      'a bool': '{"tool": "get_local_parts_inventory", "arguments": true}',
      'a non-JSON string':
          '{"tool": "get_local_parts_inventory", "arguments": "BRK-990-XP"}',
      'a JSON array string':
          '{"tool": "get_local_parts_inventory", "arguments": "[1,2]"}',
    }.entries) {
      test('arguments as ${entry.key} is argumentsUnreadable', () {
        final result = guard.inspectText(entry.value);

        expect(result, isA<GuardFailure>(), reason: 'input: ${entry.value}');
        expect(
          (result as GuardFailure).reason,
          GuardFailureReason.argumentsUnreadable,
        );
      });
    }

    test('positional arguments are refused rather than mapped onto sku', () {
      // Deliberate: `["BRK-990-XP"]` → `{"sku": …}` would work only for a
      // single-parameter tool and would silently mis-assign the moment a tool takes two.
      final result = guard.inspectText(
        '{"tool": "$toolName", "arguments": ["BRK-990-XP"]}',
      );

      expect(
        (result as GuardFailure).reason,
        GuardFailureReason.argumentsUnreadable,
      );
    });

    test('a specific failure outranks noToolCallFound', () {
      // Two candidates, neither usable: the malformed call is the more useful report,
      // so scan order must not decide this — the unusable-but-shaped object comes
      // *second* here on purpose.
      const text =
          '{"status": "thinking"} then {"tool": "$toolName", "arguments": 7}';

      final result = guard.inspectText(text);

      expect(
        (result as GuardFailure).reason,
        GuardFailureReason.argumentsUnreadable,
      );
    });

    test('a usable candidate outranks an earlier malformed one', () {
      const text =
          '{"tool": "$toolName", "arguments": 7} then '
          '{"tool": "$toolName", "arguments": {"sku": "BRK-990-XP"}}';

      expect(guardedCall(guard.inspectText(text)).arguments, {
        'sku': 'BRK-990-XP',
      });
    });

    test('the failure message never quotes the offending text back', () {
      // A malformed call is model output; echoing it verbatim into the next prompt
      // invites the model to repeat it, and §3.2's device boundary includes the prompt.
      const secret = 'ACME-INTERNAL-9931';
      final result =
          guard.inspectText('{"tool": "$toolName", "arguments": "$secret"}')
              as GuardFailure;

      expect(result.message, isNot(contains(secret)));
      expect(result.toString(), isNot(contains(secret)));
    });
  });

  // ---------------------------------------------------------------------------
  // Malformed native events
  // ---------------------------------------------------------------------------
  group('malformed native events', () {
    test('a whitespace-only name is emptyToolName', () {
      // Worth having rather than assuming the isolate wire caught it: `decodeEvent`
      // rejects `name.isEmpty`, so `""` never survives the hop — but `" "` is not
      // empty and does.
      final result = guard.inspectEvent(const LlmToolCall(name: '   '));

      expect((result as GuardFailure).reason, GuardFailureReason.emptyToolName);
    });

    test('an empty name is emptyToolName', () {
      final result = guard.inspectEvent(const LlmToolCall(name: ''));

      expect((result as GuardFailure).reason, GuardFailureReason.emptyToolName);
    });

    final unencodable = <String, Object?>{
      'a DateTime': DateTime.utc(2026, 6, 21),
      'a non-finite double': double.nan,
      'infinity': double.infinity,
      'an arbitrary object': Object(),
      'a nested unencodable value': {
        'outer': [1, Object()],
      },
      'a value that is a map with non-string keys': {1: 'one'},
    };
    for (final entry in unencodable.entries) {
      test('arguments holding ${entry.key} are argumentsNotEncodable', () {
        final value = entry.value;
        final result = guard.inspectEvent(
          LlmToolCall(name: toolName, arguments: {'sku': value}),
        );

        expect(
          result,
          isA<GuardFailure>(),
          reason: 'value: $value (${value.runtimeType})',
        );
        expect(
          (result as GuardFailure).reason,
          GuardFailureReason.argumentsNotEncodable,
        );
      });
    }

    test('encodable nested arguments pass through', () {
      const call = LlmToolCall(
        name: toolName,
        arguments: {
          'sku': 'BRK-990-XP',
          'nested': {
            'list': [1, 2.5, true, null, 'x'],
          },
        },
      );

      final guarded = guard.inspectEvent(call) as GuardedCall;

      expect(identical(guarded.call, call), isTrue);
      // The predicate's job is that this cannot throw; asserting the walk accepted the
      // value is only half of it.
      expect(jsonEncode(guarded.call.arguments), isNotEmpty);
    });

    test('the name is checked before the arguments', () {
      // Ordering is asserted rather than assumed: a nameless call with unencodable
      // arguments has two problems and the more fundamental one is the useful report.
      final result = guard.inspectEvent(
        LlmToolCall(name: '  ', arguments: {'sku': Object()}),
      );

      expect((result as GuardFailure).reason, GuardFailureReason.emptyToolName);
    });
  });

  // ---------------------------------------------------------------------------
  // Near-miss name resolution
  // ---------------------------------------------------------------------------
  group('near-miss name resolution', () {
    for (final entry in const {
      'upper case': 'GET_LOCAL_PARTS_INVENTORY',
      'title case': 'Get_Local_Parts_Inventory',
      'camel case': 'getLocalPartsInventory',
      'hyphens': 'get-local-parts-inventory',
      'spaces': 'get local parts inventory',
      'dots': 'get.local.parts.inventory',
      'surrounding whitespace': '  get_local_parts_inventory  ',
      'a scoped prefix': 'functions.get_local_parts_inventory',
      'a slashed prefix': 'tools/get_local_parts_inventory',
    }.entries) {
      test('${entry.key} resolves to the declared name', () {
        final result = guard.inspectEvent(LlmToolCall(name: entry.value));

        final guarded = result as GuardedCall;
        expect(guarded.call.name, toolName);
        expect(
          guarded.renamedFrom,
          entry.value,
          reason: 'the spelling the model emitted should be recorded',
        );
      });
    }

    test('resolution applies on the text path too', () {
      final result = guard.inspectText(
        '{"tool": "Get-Local-Parts-Inventory", "args": {"sku": "BRK-990-XP"}}',
      );

      expect(guardedCall(result).name, toolName);
      // `renamedFrom` on the text path could be deleted with all tests green while its
      // native twin was bound ten times over (R0-F4) — a property with a correct
      // implementation and no guard.
      expect((result as GuardedCall).renamedFrom, 'Get-Local-Parts-Inventory');
    });

    test('arguments are carried through a rename untouched', () {
      const arguments = {'sku': 'BRK-990-XP'};
      final guarded =
          guard.inspectEvent(
                const LlmToolCall(
                  name: 'getLocalPartsInventory',
                  arguments: arguments,
                ),
              )
              as GuardedCall;

      expect(guarded.call.arguments, same(arguments));
    });

    test('an unrelated name is left exactly as spelled', () {
      final guarded =
          guard.inspectEvent(const LlmToolCall(name: 'book_appointment'))
              as GuardedCall;

      expect(guarded.call.name, 'book_appointment');
      expect(guarded.renamedFrom, isNull);
    });

    test('a name that only shares a prefix is not resolved', () {
      // The rule is exact-equality-after-normalisation, not fuzzy matching: dispatching
      // to the wrong tool is worse than the `unknown_tool` a model can recover from.
      final guarded =
          guard.inspectEvent(const LlmToolCall(name: 'get_local_parts'))
              as GuardedCall;

      expect(guarded.call.name, 'get_local_parts');
    });

    test('two known names that normalise alike are left alone', () {
      final ambiguous = ToolCallGuard(const ['get_parts', 'getParts']);

      // Neither spelling can be resolved *from a third one*, because the guard cannot
      // tell which was meant. Both exact spellings still pass through untouched.
      final guessed =
          ambiguous.inspectEvent(const LlmToolCall(name: 'GET-PARTS'))
              as GuardedCall;
      expect(guessed.call.name, 'GET-PARTS');
      expect(guessed.renamedFrom, isNull);

      for (final exact in ['get_parts', 'getParts']) {
        final guarded =
            ambiguous.inspectEvent(LlmToolCall(name: exact)) as GuardedCall;
        expect(guarded.call.name, exact);
        expect(guarded.renamedFrom, isNull);
      }
    });

    test('the whole name beats its own trailing segment', () {
      // The defect this exists for: with both names registered, `get.parts` has a
      // *whole-name* normalised match (`getparts`) and a *segment* exact match
      // (`parts`). Resolving segments before finishing the whole name dispatches to a
      // tool the model did not name. It needs a fixture where the two disagree — with
      // only one of these names registered, every candidate order gives one answer.
      final ordered = ToolCallGuard(const ['getparts', 'parts']);

      final guarded =
          ordered.inspectEvent(const LlmToolCall(name: 'get.parts'))
              as GuardedCall;

      expect(guarded.call.name, 'getparts');
      expect(guarded.renamedFrom, 'get.parts');
    });

    test('an exact segment beats an ambiguous normalisation', () {
      // Binds the exact-before-normalised half of the same ordering, and it is the only
      // input that can: `get_parts` and `getParts` normalise alike, so the normalised
      // lookup for the segment is *ambiguous* and refuses to guess. Only the exact pass
      // resolves this; without it the name falls through unchanged to `unknown_tool`.
      //
      // The test this replaced claimed to bind the exact pass and did not — it asserted
      // that two colliding names each pass through untouched, which is the ambiguity
      // rule, and deleting the exact pass left it green.
      final ambiguous = ToolCallGuard(const ['get_parts', 'getParts']);

      final guarded =
          ambiguous.inspectEvent(const LlmToolCall(name: 'functions.get_parts'))
              as GuardedCall;

      expect(guarded.call.name, 'get_parts');
    });

    test('a guard with no known names resolves nothing', () {
      // Stated as a test because it is a real degradation rather than a no-op: with no
      // names, the text path can only recognise a call by its shape, and no spelling is
      // ever corrected.
      final blind = ToolCallGuard(const []);

      final guarded =
          blind.inspectEvent(
                const LlmToolCall(name: 'GET_LOCAL_PARTS_INVENTORY'),
              )
              as GuardedCall;
      expect(guarded.call.name, 'GET_LOCAL_PARTS_INVENTORY');

      // Shape still works — a name plus an arguments key.
      expect(
        guardedCall(
          blind.inspectText('{"tool": "anything", "arguments": {}}'),
        ).name,
        'anything',
      );
      // Without the arguments key there is no evidence left, so nothing is found.
      expect(
        (blind.inspectText('{"tool": "anything"}') as GuardFailure).reason,
        GuardFailureReason.noToolCallFound,
      );
    });

    test('knownToolNames is exposed in order and cannot be mutated', () {
      final ordered = ToolCallGuard(const ['b_tool', 'a_tool']);

      expect(ordered.knownToolNames, ['b_tool', 'a_tool']);
      expect(() => ordered.knownToolNames.add('c'), throwsUnsupportedError);
    });
  });

  // ---------------------------------------------------------------------------
  // Composition: the guard's output feeds straight into ToolRegistry.dispatch
  // ---------------------------------------------------------------------------
  group('composes with ToolRegistry.dispatch', () {
    late Directory tempDir;
    late DatabaseService db;
    late ToolRegistry registry;
    late ToolCallGuard registryGuard;
    late String shippedJson;

    setUpAll(() async {
      shippedJson = await File(
        'assets/elevator_manual_seed.json',
      ).readAsString();
    });

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('fieldops_guard_test');
      db = DatabaseService.encrypted(
        file: File('${tempDir.path}/guard.db'),
        encryptionKey: 'tool-call-guard-test-key',
      );
      await DatabaseInitializer(
        database: db,
        source: _TextSeedSource(shippedJson),
      ).ensureSeeded();
      registry = ToolRegistry([GetPartsInventoryTool(db)]);
      registryGuard = ToolCallGuard(registry.toolNames);
    });

    tearDown(() async {
      await db.close();
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('a prose-wrapped call dispatches to the real inventory row', () async {
      const text =
          'Let me check stock.\n\n{"tool": "get_local_parts_inventory", '
          '"arguments": {"sku": "BRK-990-XP"}}';

      final outcome = await registry.dispatch(
        guardedCall(registryGuard.inspectText(text)),
      );

      // The same payload TC-TOOL-EXEC-01 pins, reached through the degraded path — this
      // is the end-to-end claim of the task, so it asserts the whole map.
      expect(outcome, isA<ToolSuccess>());
      expect(outcome.payload, {
        'sku': 'BRK-990-XP',
        'in_stock': 2,
        'aisle': 'Aisle 4, Shelf B',
      });
    });

    test('a canonicalised near-miss name dispatches', () async {
      final outcome = await registry.dispatch(
        guardedCall(
          registryGuard.inspectText(
            '{"name": "Get Local Parts Inventory", '
            '"parameters": {"sku": "brk-990-xp"}}',
          ),
        ),
      );

      // The name was canonicalised by the guard; the *SKU* casing is Task 1.3's
      // normaliser, and both have to hold for this to land on the row.
      expect(outcome.payload['in_stock'], 2);
    });

    test('an unresolvable name reaches dispatch as unknown_tool', () async {
      final outcome = await registry.dispatch(
        guardedCall(
          registryGuard.inspectText(
            '{"tool": "check_the_van", "arguments": {"sku": "BRK-990-XP"}}',
          ),
        ),
      );

      // The division of labour, asserted rather than described: the guard recovered a
      // call, and the *registry* reported the unknown tool — with `unknown_tool`, not
      // any guard reason.
      expect(outcome, isA<ToolFailure>());
      expect((outcome as ToolFailure).code, ToolFailureCode.unknownTool);
      expect(outcome.payload['error'], 'unknown_tool');
    });

    test('a call with no arguments dispatches to missing_parameter', () async {
      final outcome = await registry.dispatch(
        guardedCall(registryGuard.inspectText('{"tool": "$toolName"}')),
      );

      // Why an absent arguments key is `{}` rather than a guard failure: this is the
      // report the model can act on.
      expect((outcome as ToolFailure).code, ToolFailureCode.missingParameter);
      expect(outcome.payload['parameter'], 'sku');
    });

    test('a declaration echoed back as text is a recoverable turn', () async {
      // The documented residual: a declaration and a call share their key names, so the
      // guard reads this as a call whose arguments are the schema. Recorded here as the
      // behaviour it actually produces rather than left as prose.
      final echoed = jsonEncode({
        'name': registry.definitions.single.name,
        'description': registry.definitions.single.description,
        'parameters': registry.definitions.single.parameters,
      });

      final outcome = await registry.dispatch(
        guardedCall(registryGuard.inspectText(echoed)),
      );

      expect((outcome as ToolFailure).code, ToolFailureCode.missingParameter);
    });

    test('the guard is built from the registry, not a literal', () {
      // Binds the two together: renaming the tool moves both sides at once, so no test
      // in this file can go on asserting a name the registry no longer declares.
      expect(registryGuard.knownToolNames, registry.toolNames);
      expect(registry.toolNames, [toolName]);
    });
  });
}

/// Feeds a seed JSON string straight to `DatabaseInitializer`, so the composition group
/// runs against the shipped asset without a `rootBundle`.
class _TextSeedSource implements SeedSource {
  const _TextSeedSource(this._json);

  final String _json;

  @override
  String get seedId => 'elevator_manual_seed';

  @override
  Future<String> loadSeedJson() async => _json;
}
