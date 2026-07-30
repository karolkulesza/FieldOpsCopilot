import 'package:field_ops_copilot/engines/llm_engine.dart';
import 'package:field_ops_copilot/services/inference/inference_config.dart';
import 'package:field_ops_copilot/services/inference/inference_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

/// The wire format is the contract between two isolates, and a device is the worst
/// possible place to discover it is wrong: a mis-encoded field there shows up as a
/// model that "does nothing" with no stack trace crossing the boundary. So every
/// message is round-tripped here, on the host, in CI.
void main() {
  group('event encoding', () {
    test('a token survives the round trip', () {
      final decoded = decodeEvent(encodeEvent(const LlmToken('Diag')));
      expect(decoded, isA<LlmToken>());
      expect((decoded as LlmToken).text, 'Diag');
    });

    test('a tool call keeps its name and every argument value type', () {
      // Deliberately mixed types: tool arguments come back as decoded JSON, and an
      // encoder that stringified them would break the registry's `sku` lookup in a
      // way no type checker catches.
      const call = LlmToolCall(
        name: 'get_local_parts_inventory',
        arguments: {
          'sku': 'BRK-990-XP',
          'quantity': 2,
          'urgent': true,
          'note': null,
        },
      );

      final decoded = decodeEvent(encodeEvent(call)) as LlmToolCall;

      expect(decoded.name, 'get_local_parts_inventory');
      expect(decoded.arguments, {
        'sku': 'BRK-990-XP',
        'quantity': 2,
        'urgent': true,
        'note': null,
      });
    });

    test('the encoded arguments are a copy, not the caller\'s map', () {
      // The map handed to the encoder is the one the plugin decoded from the
      // model's JSON. If the encoding aliased it, a later mutation on either side
      // would silently change what the other sees — the sort of bug that only
      // appears once the agent loop starts rewriting arguments.
      final arguments = <String, Object?>{'sku': 'BRK-990-XP'};
      final wire = encodeEvent(LlmToolCall(name: 'x', arguments: arguments));

      arguments['sku'] = 'MUTATED';

      expect((decodeEvent(wire) as LlmToolCall).arguments['sku'], 'BRK-990-XP');
    });

    test('done survives the round trip', () {
      expect(decodeEvent(encodeEvent(const LlmDone())), isA<LlmDone>());
    });

    test('an unknown event kind is rejected rather than dropped', () {
      // Dropping it would turn a protocol mismatch into a turn that hangs waiting
      // for a terminal event that was mis-spelled.
      expect(
        () => decodeEvent({kindKey: 'thinking'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('a token event with no text is rejected', () {
      expect(
        () => decodeEvent({kindKey: 'token'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('a tool event with no name is rejected', () {
      // A nameless call cannot be routed to a tool, so accepting it would only move
      // the failure into the registry.
      expect(
        () => decodeEvent({kindKey: 'tool', 'name': '', 'arguments': {}}),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('tool definitions', () {
    test('name, description and the schema all survive', () {
      const definition = ToolDefinition(
        name: 'get_local_parts_inventory',
        description: 'Look up warehouse stock for a part SKU.',
        parameters: {
          'type': 'object',
          'properties': {
            'sku': {'type': 'string', 'description': 'Part number'},
          },
          'required': ['sku'],
        },
      );

      final decoded = decodeToolDefinition(encodeToolDefinition(definition));

      expect(decoded.name, definition.name);
      expect(decoded.description, definition.description);
      // The nested schema is what the model is actually shown; a shallow copy that
      // lost `properties` would produce a tool with no arguments.
      expect(decoded.parameters, definition.parameters);
    });

    test('an argument-less tool round-trips as an empty schema', () {
      const definition = ToolDefinition(name: 'ping', description: 'no args');
      expect(
        decodeToolDefinition(encodeToolDefinition(definition)).parameters,
        isEmpty,
      );
    });

    test('a definition with no name is rejected', () {
      expect(
        () => decodeToolDefinition({'description': 'x'}),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('requests', () {
    test('load carries the config through unchanged', () {
      const config = InferenceConfig(
        modelPath: '/models/gemma-4-e2b-it-int4.litertlm',
        family: GemmaModelFamily.gemma3,
        backend: InferenceBackend.gpu,
        contextTokens: 4096,
        maxOutputTokens: 128,
        topK: 40,
        temperature: 0.4,
        randomSeed: 7,
      );

      final decoded =
          InferenceRequest.fromWire(LoadRequest(config.toWire()).toWire())
              as LoadRequest;
      final restored = InferenceConfig.fromWire(decoded.config);

      expect(restored.modelPath, config.modelPath);
      expect(restored.family, GemmaModelFamily.gemma3);
      expect(restored.backend, InferenceBackend.gpu);
      expect(restored.contextTokens, 4096);
      expect(restored.maxOutputTokens, 128);
      expect(restored.topK, 40);
      expect(restored.temperature, 0.4);
      expect(restored.randomSeed, 7);
    });

    test('generate carries the turn id, prompt and tools', () {
      const request = GenerateRequest(
        turnId: 42,
        prompt: '[MANUAL DOCUMENT]\nE-102…',
        tools: [
          ToolDefinition(
            name: 'get_local_parts_inventory',
            description: 'stock lookup',
            parameters: {
              'type': 'object',
              'properties': {
                'sku': {'type': 'string'},
              },
            },
          ),
        ],
      );

      final decoded =
          InferenceRequest.fromWire(request.toWire()) as GenerateRequest;

      expect(decoded.turnId, 42);
      expect(decoded.prompt, request.prompt);
      expect(decoded.tools, hasLength(1));
      expect(decoded.tools.single.name, 'get_local_parts_inventory');
    });

    test('stop carries the turn id it means to stop', () {
      // The id is the whole point of the message: a stop without one would cancel
      // whatever happens to be running, including the *next* turn.
      final decoded =
          InferenceRequest.fromWire(const StopRequest(9).toWire())
              as StopRequest;
      expect(decoded.turnId, 9);
    });

    test('shutdown round-trips', () {
      expect(
        InferenceRequest.fromWire(const ShutdownRequest().toWire()),
        isA<ShutdownRequest>(),
      );
    });

    test('an unknown request kind is rejected', () {
      expect(
        () => InferenceRequest.fromWire({kindKey: 'embed'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('a generate request with no turn id is rejected', () {
      expect(
        () => InferenceRequest.fromWire({
          kindKey: GenerateRequest.kind,
          'prompt': 'hi',
          'tools': <Object?>[],
        }),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('replies', () {
    test('loaded carries the runtime measurements', () {
      const runtime = LoadedRuntime(
        backend: 'gpu',
        loadMillis: 4321,
        contextTokens: 2048,
      );

      final decoded =
          InferenceReply.fromWire(LoadedReply(runtime.toWire()).toWire())
              as LoadedReply;
      final restored = LoadedRuntime.fromWire(decoded.runtime);

      expect(restored.backend, 'gpu');
      expect(restored.loadMillis, 4321);
      expect(restored.contextTokens, 2048);
    });

    test('a runtime report with no backend reads as unknown, not as a crash', () {
      // The FFI layer legitimately does not always name a backend, and "unknown"
      // is a truthful answer where a thrown error would fail a good load.
      final restored = LoadedRuntime.fromWire({
        'loadMillis': 10,
        'contextTokens': 1024,
      });
      expect(restored.backend, LoadedRuntime.unknownBackend);
    });

    test('a runtime report with no load time is rejected', () {
      // A defaulted 0 would read as an instant load of a 2.6GB model — the one
      // measurement this task exists to produce.
      expect(
        () => LoadedRuntime.fromWire({'backend': 'gpu', 'contextTokens': 1024}),
        throwsA(isA<FormatException>()),
      );
    });

    test('an event reply carries its event', () {
      final decoded =
          InferenceReply.fromWire(const EventReply(LlmToken('OK')).toWire())
              as EventReply;
      expect((decoded.event as LlmToken).text, 'OK');
    });

    test('a failure keeps its message and its engine-lost flag', () {
      final decoded =
          InferenceReply.fromWire(
                const FailureReply(
                  message: 'model load failed: no such file',
                  stateful: true,
                ).toWire(),
              )
              as FailureReply;

      expect(decoded.message, contains('no such file'));
      // Distinguishing a lost engine from a failed turn is what stops the app
      // either retrying forever or re-loading gigabytes for nothing.
      expect(decoded.stateful, isTrue);
    });

    test('a failure defaults to turn-scoped', () {
      final decoded =
          InferenceReply.fromWire(
                const FailureReply(message: 'generation failed').toWire(),
              )
              as FailureReply;
      expect(decoded.stateful, isFalse);
    });

    test('an unknown reply kind is rejected', () {
      expect(
        () => InferenceReply.fromWire({kindKey: 'progress'}),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('config decoding', () {
    test('a missing model path is rejected', () {
      final wire = const InferenceConfig(modelPath: '/m.litertlm').toWire()
        ..remove('modelPath');
      expect(
        () => InferenceConfig.fromWire(wire),
        throwsA(isA<FormatException>()),
      );
    });

    test('an empty model path is rejected', () {
      // "" would reach the engine as a load of nothing, and the native error for
      // that is far less readable than this one.
      expect(
        () => InferenceConfig.fromWire(
          const InferenceConfig(modelPath: '/m.litertlm').toWire()
            ..['modelPath'] = '',
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('an unknown model family is rejected rather than defaulted', () {
      // Defaulting would load Gemma 4's tool-calling path onto Gemma 3 weights,
      // where native tool tokens do not exist — the model would simply never appear
      // to call a tool.
      expect(
        () => InferenceConfig.fromWire(
          const InferenceConfig(modelPath: '/m.litertlm').toWire()
            ..['family'] = 'gemma5',
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('an integer temperature is accepted as a double', () {
      // JSON has one number type; a config that travelled as `1` must not fail to
      // decode into a double field.
      final wire = const InferenceConfig(modelPath: '/m.litertlm').toWire()
        ..['temperature'] = 1;
      expect(InferenceConfig.fromWire(wire).temperature, 1.0);
    });

    test('a non-numeric context window is rejected', () {
      expect(
        () => InferenceConfig.fromWire(
          const InferenceConfig(modelPath: '/m.litertlm').toWire()
            ..['contextTokens'] = '2048',
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
