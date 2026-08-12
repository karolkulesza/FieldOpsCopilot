/// Dependency-injection seam for model provisioning.
///
/// Mirrors `lib/engines/providers.dart`: the runtime binds real implementations,
/// and tests override these rather than reaching for the concrete types. The
/// storage and provisioner providers are async because resolving the
/// application-support directory is a platform call.
///
/// **What changed in Task 2.0.** Task 1.7's providers described *the* model —
/// one descriptor, one install status, one provisioning trigger. This build
/// provisions two (the active LLM and the committed-config STT set), so
/// everything that was singular is now keyed by model id:
/// [modelDescriptorProvider], [modelInstallStatusProvider] and
/// `modelProvisioningControllerProvider` are `.family` providers, and
/// [provisionedModelDescriptorsProvider] is the list the readiness UI iterates.
/// [activeLlmDescriptorProvider] keeps its job — naming the one model the *agent*
/// needs — because "which LLM does inference load" is still a singular question
/// even when provisioning is not.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../retry_policy.dart';
import 'model_descriptor.dart';
import 'model_provisioner.dart';
import 'model_storage.dart';

/// The LLM this build provisions and the agent runs on, resolved from the
/// build-time `--dart-define`s. See [ModelCatalog].
///
/// Renamed from `activeModelDescriptorProvider` in Task 2.0, because "the active
/// model" stopped being a coherent phrase the moment there were two: this is the
/// active **LLM**, the model `inferenceConfigProvider` loads and the one Diagnose
/// cannot run without. The STT model is neither active nor inactive — it is
/// simply provisioned — and a missing STT set must never gate the agent
/// (TC-PROV-MULTI-01).
final activeLlmDescriptorProvider = Provider<ModelDescriptor>(
  (ref) => ModelCatalog.active,
);

/// Every model this build provisions — what the readiness banner renders, one
/// row each, LLM first. See [ModelCatalog.provisioned].
final provisionedModelDescriptorsProvider = Provider<List<ModelDescriptor>>(
  (ref) => ModelCatalog.provisioned,
);

/// The provisioned model with the given id, or `null` when this build
/// provisions no such model.
///
/// Resolved against [provisionedModelDescriptorsProvider] rather than
/// [ModelCatalog.byId] so an override of the list in a test overrides every
/// per-model provider with it — the family's argument is a plain string, and a
/// lookup that bypassed the provider graph would bypass the override too.
final modelDescriptorProvider = Provider.family<ModelDescriptor?, String>((
  ref,
  modelId,
) {
  for (final descriptor in ref.watch(provisionedModelDescriptorsProvider)) {
    if (descriptor.id == modelId) return descriptor;
  }
  return null;
});

/// Access token for the model host, or `null` when none was supplied.
///
/// Many sources need none: a repository that does not gate downloads is fetched
/// anonymously, and provisioning sends no `Authorization` header at all. Both of
/// this build's committed models are in that category — the primary LiteRT-LM
/// Gemma build and the `apache-2.0` STT set. A token is only required by a gated
/// source; the Gemma 3 1B fallback repository is one.
///
/// Where a token *is* needed, note that `--dart-define` bakes it into the binary,
/// which is fine for a development or demo build and **not** a shipping pattern:
/// anyone with the app has the credential. The fleet answer is in the README's OTA
/// section — a short-lived signed URL issued per device by an enterprise backend —
/// and it slots in behind this provider without touching the provisioner.
final modelAccessTokenProvider = Provider<String?>(
  (ref) => _configuredToken.isEmpty ? null : _configuredToken,
);

/// The app's real model directory, marked no-backup.
///
/// [noRetry] for the same reason as [modelInstallStatusProvider], and it has to be
/// here too: this is upstream of it, so a retrying storage provider would keep the
/// whole chain in `AsyncLoading` regardless of what the ones below it declare.
final modelStorageProvider = FutureProvider<ModelStorage>(
  retry: noRetry,
  (ref) => ModelStorage.openDefault(),
);

/// Provisioner wired to real storage, the real transport and the configured
/// token.
///
/// Still one instance for every model, not one per model: its serialisation
/// queue is keyed by model id internally, so operations on one model queue
/// behind each other while two models proceed independently — and a per-model
/// provisioner would silently *lose* that first property.
final modelProvisionerProvider = FutureProvider<ModelProvisioner>(
  retry: noRetry,
  (ref) async {
    final storage = await ref.watch(modelStorageProvider.future);
    final provisioner = ModelProvisioner(
      storage: storage,
      authToken: ref.watch(modelAccessTokenProvider),
    );
    // Releases the HTTP client; a provisioner outliving its transport would hold
    // an idle connection pool open for the life of the app.
    ref.onDispose(provisioner.dispose);
    return provisioner;
  },
);

/// Install state of one provisioned model, keyed by model id — what the UI's
/// readiness indicator reads, one instance per banner row.
///
/// Per model and *independent* on purpose: the STT set being absent must leave
/// the LLM's instance untouched, because the LLM's instance is what gates the
/// agent engine (TC-PROV-MULTI-01). An id this build does not provision resolves
/// to [ModelInstallStatus.absent] rather than throwing — there are no weights
/// for it here, and the startup path must not crash over a stale watcher.
///
/// Deliberately the *cheap* check (receipts, no re-hash), because it runs on the
/// way to the first frame. An explicit re-hash is
/// [ModelProvisioner.verifyInstalled], invoked on demand rather than at startup.
///
/// [noRetry] added by Task 1.11, and it changes what the banner *does* rather than
/// only how fast. Riverpod 3 retries a thrown `Exception` ten times with backoff,
/// which for this provider means the banner sits on "Checking model…" for around
/// half a minute and then shows "Model status unavailable" — a state its own doc
/// says must be distinguishable from ready and absent, arriving so late it reads as
/// a hang instead. The failure it reports (no platform channel, an unreadable
/// support directory) does not resolve itself, and the banner already carries the
/// operator's next action. See `../retry_policy.dart`.
final modelInstallStatusProvider =
    FutureProvider.family<ModelInstallStatus, String>(retry: noRetry, (
      ref,
      modelId,
    ) async {
      final descriptor = ref.watch(modelDescriptorProvider(modelId));
      if (descriptor == null) return ModelInstallStatus.absent;
      final provisioner = await ref.watch(modelProvisionerProvider.future);
      return provisioner.statusOf(descriptor);
    });

const _configuredToken = String.fromEnvironment('FIELDOPS_MODEL_TOKEN');
