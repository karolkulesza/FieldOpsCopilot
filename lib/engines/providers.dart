import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'fakes/fake_llm_engine.dart';
import 'fakes/fake_stt_engine.dart';
import 'llm_engine.dart';
import 'stt_engine.dart';

/// The dependency-injection seam the engine interfaces were introduced for.
///
/// These two providers bind the **fakes**, and that is deliberate rather than
/// unfinished. The device bindings live beside the code that needs them —
/// `deviceLlmEngineProvider` in `services/inference/providers.dart` and
/// `deviceSttEngineProvider` in `services/audio/providers.dart` — because each
/// has to await a provisioned, digest-verified model before it can answer, and
/// neither can be a synchronous `Provider`. What stays here is the host-side
/// default a widget test resolves without arranging anything.
///
/// `test/services/inference/no_fake_in_production_test.dart` is what keeps that
/// separation honest: this file is inside the exemption where naming a fake is
/// legitimate, and nothing on the production answer path may reach it.

final llmEngineProvider = Provider<LlmEngine>((ref) {
  final engine = FakeLlmEngine(
    turns: [
      const [
        LlmToken('This answer came from the fake engine, '),
        LlmToken('not from the device model.'),
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
