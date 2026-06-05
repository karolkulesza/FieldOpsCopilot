import 'dart:typed_data';

import 'package:field_ops_copilot/engines/fakes/fake_llm_engine.dart';
import 'package:field_ops_copilot/engines/fakes/fake_platform_telemetry.dart';
import 'package:field_ops_copilot/engines/fakes/fake_stt_engine.dart';
import 'package:field_ops_copilot/engines/fakes/fake_vision_engine.dart';
import 'package:field_ops_copilot/engines/llm_engine.dart';
import 'package:field_ops_copilot/engines/platform_telemetry.dart';
import 'package:field_ops_copilot/engines/stt_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FakeLlmEngine', () {
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
      expect(() => engine.generate(prompt: 'x').toList(), throwsStateError);
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
