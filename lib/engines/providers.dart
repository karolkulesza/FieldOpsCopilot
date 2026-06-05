import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'fakes/fake_llm_engine.dart';
import 'fakes/fake_platform_telemetry.dart';
import 'fakes/fake_stt_engine.dart';
import 'fakes/fake_vision_engine.dart';
import 'llm_engine.dart';
import 'platform_telemetry.dart';
import 'stt_engine.dart';
import 'vision_engine.dart';

/// Central dependency-injection seam for the on-device engines.
///
/// The skeleton binds the deterministic fakes. On-device implementations are
/// swapped in later by overriding these providers in `ProviderScope`, so no
/// upstream code depends on a concrete backend.

final llmEngineProvider = Provider<LlmEngine>((ref) {
  final engine = FakeLlmEngine(
    turns: [
      const [
        LlmToken('FieldOps Copilot '),
        LlmToken('skeleton is running '),
        LlmToken('on the fake engine.'),
        LlmDone(),
      ],
    ],
  );
  ref.onDispose(engine.dispose);
  return engine;
});

final sttEngineProvider = Provider<SttEngine>((ref) {
  final engine = FakeSttEngine();
  ref.onDispose(engine.dispose);
  return engine;
});

final visionEngineProvider = Provider<VisionEngine>((ref) {
  final engine = FakeVisionEngine();
  ref.onDispose(engine.dispose);
  return engine;
});

final platformTelemetryProvider = Provider<PlatformTelemetry>((ref) {
  final telemetry = FakePlatformTelemetry();
  ref.onDispose(telemetry.dispose);
  return telemetry;
});
