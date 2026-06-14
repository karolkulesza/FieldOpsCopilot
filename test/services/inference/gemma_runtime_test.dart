import 'package:field_ops_copilot/engines/llm_engine.dart';
import 'package:field_ops_copilot/services/inference/gemma_runtime.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_test/flutter_test.dart';

/// Covers the translation from the plugin's response hierarchy to this app's
/// [LlmEvent]s — the part of `GemmaRuntime` that does not need a model.
///
/// It is worth its own suite because it is the seam most likely to rot: the plugin's
/// `ModelResponse` hierarchy is sealed *there*, not here, so a new variant added
/// upstream becomes a compile error in `llmEventsFor` — and a `default` branch, had
/// one been written, would have silently swallowed it instead.
void main() {
  group('llmEventsFor', () {
    test('a text token becomes one LlmToken', () {
      expect(llmEventsFor(const TextResponse('Diag')), [
        const LlmToken('Diag'),
      ]);
    });

    test('an empty token produces nothing', () {
      // Empty chunks carry no information and would appear as spurious items in the
      // golden snapshots Task 1.10 commits.
      expect(llmEventsFor(const TextResponse('')), isEmpty);
    });

    test('whitespace is kept — it is part of the answer', () {
      // Tokens arrive pre-split; dropping a lone space would run words together in
      // the rendered answer.
      expect(llmEventsFor(const TextResponse(' ')), [const LlmToken(' ')]);
    });

    test('a function call becomes a structured tool call', () {
      final events = llmEventsFor(
        const FunctionCallResponse(
          name: 'get_local_parts_inventory',
          args: {'sku': 'BRK-990-XP'},
        ),
      );

      final call = events.single as LlmToolCall;
      expect(call.name, 'get_local_parts_inventory');
      expect(call.arguments, {'sku': 'BRK-990-XP'});
    });

    test('parallel calls are flattened into one event each', () {
      // Gemma 4 can emit several calls in a single turn. Flattening here means the
      // agent loop only ever handles one call per event, instead of every consumer
      // having to know about a second shape.
      final events = llmEventsFor(
        const ParallelFunctionCallResponse(
          calls: [
            FunctionCallResponse(
              name: 'get_local_parts_inventory',
              args: {'sku': 'BRK-990-XP'},
            ),
            FunctionCallResponse(
              name: 'search_technical_manuals',
              args: {'query': 'brake vibration'},
            ),
          ],
        ),
      );

      expect(events, hasLength(2));
      expect((events[0] as LlmToolCall).name, 'get_local_parts_inventory');
      expect((events[1] as LlmToolCall).arguments['query'], 'brake vibration');
    });

    test('the tool arguments are copied out of the plugin\'s map', () {
      // The plugin's map is `Map<String, dynamic>` decoded from model output. Taking
      // a copy is what makes the declared `Map<String, Object?>` on `LlmToolCall`
      // true, and stops a later mutation on either side from surprising the other.
      final args = <String, dynamic>{'sku': 'BRK-990-XP'};
      final call =
          llmEventsFor(FunctionCallResponse(name: 'x', args: args)).single
              as LlmToolCall;

      args['sku'] = 'MUTATED';

      expect(call.arguments['sku'], 'BRK-990-XP');
    });

    test('a thinking trace produces nothing', () {
      // This app never asks for thinking mode; the plugin's filter is a safety net
      // for bundles that emit `<think>` anyway. A reasoning trace is not something
      // to show a technician or to snapshot in a golden file.
      expect(llmEventsFor(const ThinkingResponse('let me see…')), isEmpty);
    });
  });
}
