/// Dependency-injection seam for model provisioning.
///
/// Mirrors `lib/engines/providers.dart`: the runtime binds real implementations,
/// and tests override these rather than reaching for the concrete types. The
/// storage and provisioner providers are async because resolving the
/// application-support directory is a platform call.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

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
final modelStorageProvider = FutureProvider<ModelStorage>(
  (ref) => ModelStorage.openDefault(),
);

/// Provisioner wired to real storage, the real transport and the configured
/// token.
final modelProvisionerProvider = FutureProvider<ModelProvisioner>((ref) async {
  final storage = await ref.watch(modelStorageProvider.future);
  final provisioner = ModelProvisioner(
    storage: storage,
    authToken: ref.watch(modelAccessTokenProvider),
  );
  // Releases the HTTP client; a provisioner outliving its transport would hold
  // an idle connection pool open for the life of the app.
  ref.onDispose(provisioner.dispose);
  return provisioner;
});

/// Install state of the active model — what the UI's readiness indicator reads.
///
/// Deliberately the *cheap* check (receipt, no re-hash), because it runs on the
/// way to the first frame. An explicit re-hash is
/// [ModelProvisioner.verifyInstalled], invoked on demand rather than at startup.
final modelInstallStatusProvider = FutureProvider<ModelInstallStatus>((
  ref,
) async {
  final provisioner = await ref.watch(modelProvisionerProvider.future);
  return provisioner.statusOf(ref.watch(activeModelDescriptorProvider));
});

const _configuredToken = String.fromEnvironment('FIELDOPS_MODEL_TOKEN');
