/// Dependency-injection seam for model provisioning.
///
/// Mirrors `lib/engines/providers.dart`: the runtime binds real implementations,
/// and tests override these rather than reaching for the concrete types. The
/// storage and provisioner providers are async because resolving the
/// application-support directory is a platform call.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../retry_policy.dart';
import 'model_descriptor.dart';
import 'model_provisioner.dart';
import 'model_storage.dart';

/// The model this build provisions, resolved from the build-time
/// `--dart-define`s. See [ModelCatalog].
final activeModelDescriptorProvider = Provider<ModelDescriptor>(
  (ref) => ModelCatalog.active,
);

/// Access token for the model host, or `null` when none was supplied.
///
/// Many sources need none: a repository that does not gate downloads (the primary
/// LiteRT-LM build does not) is fetched anonymously, and provisioning sends no
/// `Authorization` header at all. A token is only required by a gated source — the
/// Gemma 3 1B fallback repository is one.
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

/// Install state of the active model — what the UI's readiness indicator reads.
///
/// Deliberately the *cheap* check (receipt, no re-hash), because it runs on the
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
final modelInstallStatusProvider = FutureProvider<ModelInstallStatus>(
  retry: noRetry,
  (ref) async {
    final provisioner = await ref.watch(modelProvisionerProvider.future);
    return provisioner.statusOf(ref.watch(activeModelDescriptorProvider));
  },
);

const _configuredToken = String.fromEnvironment('FIELDOPS_MODEL_TOKEN');
