import 'dart:typed_data';

import 'package:field_ops_copilot/engines/fakes/fake_llm_engine.dart';
import 'package:field_ops_copilot/engines/fakes/fake_platform_telemetry.dart';
import 'package:field_ops_copilot/engines/fakes/fake_stt_engine.dart';
import 'package:field_ops_copilot/engines/fakes/fake_vision_engine.dart';
import 'package:field_ops_copilot/engines/llm_engine.dart';
import 'package:field_ops_copilot/engines/tool_schema.dart';
import 'package:field_ops_copilot/engines/platform_telemetry.dart';
import 'package:field_ops_copilot/engines/stt_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FakeLlmEngine', () {
    test(
      'refuses a malformed tool schema, exactly as a device engine does',
      () async {
        // The fake's parity with the real engine is what makes the host suite meaningful:
        // Task 1.9's agent loop and Task 1.10's goldens are tested against this class, so
        // a fake that accepted `{'sku': 'String'}` would let a tool registry pass every
        // host test and throw on the demo device.
        final engine = FakeLlmEngine(
          turns: [
            const [LlmDone()],
          ],
        );
        await engine.initialize();
        addTearDown(engine.dispose);

        expect(
          () => engine.generate(
            prompt: 'E-102',
            tools: const [
              ToolDefinition(
                name: 'get_local_parts_inventory',
                description: 'stock',
                parameters: {'sku': 'String'},
              ),
            ],
          ),
          throwsA(isA<ToolSchemaException>()),
        );
      },
    );

    test('accepts a conforming tool schema', () async {
      final engine = FakeLlmEngine(
        turns: [
          const [LlmDone()],
        ],
      );
      await engine.initialize();
      addTearDown(engine.dispose);

      final events = await engine
          .generate(
            prompt: 'E-102',
            tools: [
              ToolDefinition(
                name: 'get_local_parts_inventory',
                description: 'Check warehouse stock for a SKU.',
                parameters: objectSchema(
                  properties: {
                    'sku': {'type': 'string'},
                  },
                  required: ['sku'],
                ),
              ),
            ],
          )
          .toList();

      expect(events, [const LlmDone()]);
    });

    // TC-FAKE-LLM-01: streams scripted tokens in order.
    test('streams scripted tokens in order', () async {
      final engine = FakeLlmEngine(
        turns: [
          const [LlmToken('Diag'), LlmToken('nosed'), LlmDone()],
        ],
      );
      await engine.initialize();

      final events = await engine.generate(prompt: 'x').toList();
      final tokens = events.whereType<LlmToken>().map((e) => e.text).toList();

      expect(tokens, ['Diag', 'nosed']);
      expect(events.last, isA<LlmDone>());
    });

    // TC-FAKE-LLM-02: emits a structured tool-call event.
    test('emits a structured tool-call event', () async {
      final engine = FakeLlmEngine(
        turns: [
          const [
            LlmToolCall(
              name: 'get_local_parts_inventory',
              arguments: {'sku': 'BRK-990-XP'},
            ),
          ],
        ],
      );
      await engine.initialize();

      final events = await engine.generate(prompt: 'x').toList();
      final call = events.whereType<LlmToolCall>().single;

      expect(call.name, 'get_local_parts_inventory');
      expect(call.arguments['sku'], 'BRK-990-XP');
    });

    test('throws if generate is called before initialize', () {
      final engine = FakeLlmEngine();
      // Asserted without `.toList()`: the throw is synchronous, at the call site, which
      // is the failure mode `GemmaLlmEngine` has. Draining the stream would pass either
      // way and so would not notice the fake deferring it.
      expect(() => engine.generate(prompt: 'x'), throwsStateError);
    });
  });

  group('FakeSttEngine', () {
    test('replays scripted transcript after draining audio', () async {
      final engine = FakeSttEngine(
        script: const [SttTranscript('E-102 error', isFinal: true)],
      );
      await engine.initialize();

      final audio = Stream<Uint8List>.fromIterable([Uint8List(4)]);
      final results = await engine.transcribe(audio).toList();

      expect(results.single.text, 'E-102 error');
      expect(results.single.isFinal, isTrue);
    });
  });

  group('FakeVisionEngine', () {
    test('returns scripted barcode and OCR text', () async {
      final engine = FakeVisionEngine();
      await engine.initialize();

      final result = await engine.analyze(Uint8List(0));

      expect(result.barcodes, contains('SKU-BRK-990'));
      expect(result.text, contains('APEX-9'));
    });
  });

  group('FakePlatformTelemetry', () {
    test('emits pushed thermal and battery events', () async {
      final telemetry = FakePlatformTelemetry();

      final thermalFuture = telemetry.thermalState.first;
      final batteryFuture = telemetry.battery.first;

      telemetry.emitThermal(DeviceThermalState.serious);
      telemetry.emitBattery(const BatteryStatus(level: 0.1, isCharging: false));

      expect(await thermalFuture, DeviceThermalState.serious);
      expect((await batteryFuture).level, 0.1);

      await telemetry.dispose();
    });
  });
}
