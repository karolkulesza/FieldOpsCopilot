/// Dependency-injection seam for on-device inference.
///
/// Mirrors `lib/engines/providers.dart` and `lib/services/models/providers.dart`:
/// the runtime binds real implementations and tests override these rather than
/// reaching for concrete types.
///
/// **`llmEngineProvider` deliberately still binds the fake.** Every existing unit
/// and widget test resolves it, and none of them can load 2.6GB of weights — a
/// provider that quietly became device-backed would break the host suite and, worse,
/// would make the app try to load a model on the way to the first frame. The real
/// engine is [deviceLlmEngineProvider], and Task 1.11 flips the app over by
/// overriding `llmEngineProvider` with it inside a `ProviderScope` on device. Nothing
/// upstream of the interface changes when it does.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../engines/impl/gemma_llm_engine.dart';
import '../models/model_descriptor.dart';
import '../models/model_storage.dart';
import '../models/providers.dart';
import 'inference_config.dart';

/// The inference configuration for the currently installed model, or `null` when
/// there is nothing safe to load.
///
/// `null` is a first-class answer here, and the condition is deliberately strict:
/// only [ModelInstallStatus.ready] — weights present *and* vouched for against the
/// pinned SHA-256 — produces a config. `unverified` does not. That rule is the reason
/// Task 1.7 exists: an engine that loads bytes nothing has hashed turns "the model is
/// ready" into a statement about a file that happens to be at the right path, which
/// is exactly what a half-finished download leaves behind.
final inferenceConfigProvider = FutureProvider<InferenceConfig?>((ref) async {
  final descriptor = ref.watch(activeModelDescriptorProvider);
  final status = await ref.watch(modelInstallStatusProvider.future);
  if (status != ModelInstallStatus.ready) return null;

  final storage = await ref.watch(modelStorageProvider.future);
  return InferenceConfig(
    modelPath: storage.installedFile(descriptor).path,
    family: inferenceFamilyFor(descriptor.id),
  );
});

/// The on-device engine for the installed model, or `null` when no verified weights
/// are present.
///
/// Returns an engine that has **not** been initialised: loading is seconds of work
/// and gigabytes of memory, so it is triggered by a deliberate user action rather
/// than by something reading a provider. Disposal is wired here because forgetting it
/// leaks a whole isolate holding the model.
final deviceLlmEngineProvider = FutureProvider<GemmaLlmEngine?>((ref) async {
  final config = await ref.watch(inferenceConfigProvider.future);
  if (config == null) return null;

  final engine = GemmaLlmEngine(config: config);
  ref.onDispose(engine.dispose);
  return engine;
});

/// Maps a catalog model id to the tool-calling dialect its weights speak.
///
/// Not cosmetic: pick wrong and tool calls silently stop arriving, because Gemma 4's
/// native tool tokens do not exist in a Gemma 3 bundle. An unknown id falls back to
/// the primary family and says so, on the same reasoning as
/// `ModelCatalog.active` — a typo in a `--dart-define` should surface as a readable
/// failure at load time, not a crash before the first frame.
@visibleForTesting
GemmaModelFamily inferenceFamilyFor(String modelId) {
  switch (modelId) {
    case ModelCatalog.gemma4E2bId:
      return GemmaModelFamily.gemma4;
    case ModelCatalog.gemma31bId:
      return GemmaModelFamily.gemma3;
    default:
      debugPrint(
        'unknown model id "$modelId"; assuming the Gemma 4 tool-calling '
        'dialect. If these weights are not Gemma 4, native tool calls will '
        'not arrive.',
      );
      return GemmaModelFamily.gemma4;
  }
}
