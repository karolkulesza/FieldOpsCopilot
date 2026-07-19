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
/// engine is [deviceLlmEngineProvider].
///
/// **How the app actually flipped over to the device engine, which is not what
/// this paragraph
/// used to predict.** The prediction was "override `llmEngineProvider` with
/// [deviceLlmEngineProvider] inside a `ProviderScope`", and that override does not
/// type-check: `llmEngineProvider` is a synchronous `Provider<LlmEngine>` and
/// resolving the device engine means awaiting a verified model path, so the real
/// binding is unavoidably a `Future`. The seam the app resolves is therefore
/// [agentEngineProvider], and the difference is not only mechanical — see that
/// provider for why it answers `null` rather than falling back to the fake.
/// Nothing upstream of the `LlmEngine` interface changed, which was the part of
/// the prediction that mattered.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../engines/impl/gemma_llm_engine.dart';
import '../../engines/llm_engine.dart';
import '../models/model_descriptor.dart';
import '../models/model_storage.dart';
import '../models/providers.dart';
import '../retry_policy.dart';
import 'inference_config.dart';

/// The inference configuration for the currently installed model, or `null` when
/// there is nothing safe to load.
///
/// `null` is a first-class answer here, and the condition is deliberately strict:
/// only [ModelInstallStatus.ready] — weights present *and* vouched for against the
/// pinned SHA-256 — produces a config. `unverified` does not. That rule is the whole
/// reason provisioning verifies at all: an engine that loads bytes nothing has hashed turns "the model is
/// ready" into a statement about a file that happens to be at the right path, which
/// is exactly what a half-finished download leaves behind.
final inferenceConfigProvider = FutureProvider<InferenceConfig?>(
  retry: noRetry,
  (ref) async {
    final descriptor = ref.watch(activeLlmDescriptorProvider);
    // The *LLM's* family instance, and only that one: the STT set has its own
    // readiness, and an absent STT model must not stop the agent from loading
    // (TC-PROV-MULTI-01).
    final status = await ref.watch(
      modelInstallStatusProvider(descriptor.id).future,
    );
    if (status != ModelInstallStatus.ready) return null;

    final storage = await ref.watch(modelStorageProvider.future);
    return InferenceConfig(
      modelPath: storage.installedFile(descriptor).path,
      family: inferenceFamilyFor(descriptor.id),
    );
  },
);

/// The on-device engine for the installed model, or `null` when no verified weights
/// are present.
///
/// Returns an engine that has **not** been initialised: loading is seconds of work
/// and gigabytes of memory, so it is triggered by a deliberate user action rather
/// than by something reading a provider. Disposal is wired here because forgetting it
/// leaks a whole isolate holding the model.
///
/// [noRetry], deliberately: this sits on the path to the first interactive
/// frame, and Riverpod 3's default would hold the screen in `AsyncLoading` for
/// around half a minute over a failure that is settled on the first attempt. See
/// `retry_policy.dart`.
final deviceLlmEngineProvider = FutureProvider<GemmaLlmEngine?>(
  retry: noRetry,
  (ref) async {
    final config = await ref.watch(inferenceConfigProvider.future);
    if (config == null) return null;

    final engine = GemmaLlmEngine(config: config);
    ref.onDispose(engine.dispose);
    return engine;
  },
);

/// The `LlmEngine` the demo screen runs the agent loop on: the device engine, or
/// `null` when this device has no verified weights.
///
/// **It never falls back to `FakeLlmEngine`, and that is the decision worth
/// reading.** The fallback is one line and it is tempting, because it would make
/// the screen work everywhere. What it would actually produce is an app that
/// answers a technician's inquiry fluently, in well-formatted prose, from a
/// scripted list — on a machine where the model never ran. There is no failure
/// mode of this project worse than that, because it is indistinguishable from
/// success in a screen recording, which is the artefact this app exists to make.
/// So `null` is a first-class answer and the screen renders it as "no verified
/// weights on this device", with the banner above it naming the next step.
///
/// The fake is still exactly one line away from any test that wants it — an
/// override of *this* provider — which is a deliberate act in a test file rather
/// than a default nobody chose. The fakes' house rule makes that safe: the fake enforces
/// every contract the device engine does, at the same moment, so what passes here
/// against the fake is not passing against a more forgiving world.
///
/// Interface-typed rather than `GemmaLlmEngine`-typed for the same reason: a
/// concrete return type is a provider a fake cannot be substituted into.
final agentEngineProvider = FutureProvider<LlmEngine?>(
  retry: noRetry,
  (ref) => ref.watch(deviceLlmEngineProvider.future),
);

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
