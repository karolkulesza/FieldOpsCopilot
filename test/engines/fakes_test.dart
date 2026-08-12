import 'dart:async';
import 'dart:typed_data';

import 'package:field_ops_copilot/services/audio/mic_frame.dart';
import 'package:field_ops_copilot/engines/fakes/fake_llm_engine.dart';
import 'package:field_ops_copilot/engines/fakes/fake_platform_telemetry.dart';
import 'package:field_ops_copilot/engines/fakes/fake_stt_engine.dart';
import 'package:field_ops_copilot/engines/fakes/fake_vision_engine.dart';
import 'package:field_ops_copilot/engines/llm_engine.dart';
import 'package:field_ops_copilot/engines/platform_telemetry.dart';
import 'package:field_ops_copilot/engines/stt_engine.dart';
import 'package:field_ops_copilot/engines/tool_schema.dart';
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

    test('refuses an overlapping turn, as the device engine does', () async {
      // Inference is serialised all the way down on device — one native conversation at
      // a time — so an agent loop that overlapped turns would pass every host test and
      // fail on the device. The fake has to be exactly as strict.
      final engine = FakeLlmEngine(
        turns: [
          const [LlmToken('first'), LlmDone()],
          const [LlmToken('second'), LlmDone()],
        ],
      );
      await engine.initialize();
      addTearDown(engine.dispose);

      final first = engine.generate(prompt: 'a');

      expect(() => engine.generate(prompt: 'b'), throwsStateError);

      // Draining the first turn releases the slot, so the next one is fine.
      expect(await first.toList(), [const LlmToken('first'), const LlmDone()]);
      expect(await engine.generate(prompt: 'b').toList(), [
        const LlmToken('second'),
        const LlmDone(),
      ]);
    });

    test('a cancelled turn releases the slot', () async {
      // A consumer walking away mid-stream must not wedge the engine — the real host
      // clears its turn on cancel too.
      final engine = FakeLlmEngine(
        turns: [
          const [LlmToken('a'), LlmToken('b'), LlmDone()],
          const [LlmDone()],
        ],
      );
      await engine.initialize();
      addTearDown(engine.dispose);

      final subscription = engine.generate(prompt: 'a').listen(null);
      await subscription.cancel();

      expect(() => engine.generate(prompt: 'b'), returnsNormally);
    });

    test('does not revive after dispose', () async {
      // `GemmaLlmEngine` refuses to re-initialise after disposal: its isolate is gone.
      // A fake that quietly revived would let a lifecycle bug through the host suite.
      final engine = FakeLlmEngine(
        turns: [
          const [LlmDone()],
        ],
      );
      await engine.initialize();
      await engine.dispose();

      await expectLater(engine.initialize(), throwsStateError);
      expect(() => engine.generate(prompt: 'x'), throwsStateError);
      expect(engine.isReady, isFalse);
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

      // `Stream<MicFrame>` since Task 2.2 widened the interface — the gap the
      // capture reports has to be able to reach the recogniser.
      final audio = Stream<MicFrame>.fromIterable([
        MicFrame(bytes: Uint8List(4)),
      ]);
      final results = await engine.transcribe(audio).toList();

      expect(results.single.text, 'E-102 error');
      expect(results.single.isFinal, isTrue);
    });

    test('rawText defaults to text when a backend does no post-processing', () {
      const transcript = SttTranscript('E-102 error');
      expect(transcript.rawText, 'E-102 error');
      expect(transcript.segment, 0);
    });

    test('refuses a second concurrent transcription', () async {
      final engine = FakeSttEngine();
      await engine.initialize();

      // Never-closing, so the first transcription is still in flight. The real
      // engine refuses this because one `OnlineStream` exists per recogniser; the
      // fake refuses it so a caller cannot be written against a tolerance the
      // device does not have.
      final first = engine.transcribe(StreamController<MicFrame>().stream);
      first.listen(null);
      await pumpEventQueue();

      expect(
        () => engine.transcribe(const Stream<MicFrame>.empty()),
        throwsStateError,
      );
    });

    test('refuses use after disposal, and refuses to be revived', () async {
      final engine = FakeSttEngine();
      await engine.initialize();
      await engine.dispose();

      expect(engine.isReady, isFalse);
      expect(
        () => engine.transcribe(const Stream<MicFrame>.empty()),
        throwsStateError,
      );
      expect(engine.initialize, throwsStateError);
    });

    test('a completed transcription releases the in-flight guard', () async {
      final engine = FakeSttEngine();
      await engine.initialize();

      await engine
          .transcribe(
            Stream<MicFrame>.fromIterable([MicFrame(bytes: Uint8List(2))]),
          )
          .toList();
      // If the guard leaked, this would throw — which is the failure mode a
      // `finally` exists to prevent and the one nothing would otherwise catch.
      await engine.transcribe(const Stream<MicFrame>.empty()).toList();
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
