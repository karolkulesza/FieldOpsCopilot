/// The user-facing trigger for provisioning model weights.
///
/// Task 1.7 built everything underneath this — download with progress, streaming
/// SHA-256, atomic install, per-model serialisation — and deliberately shipped no way
/// to *start* it, leaving the trigger to the task that first needs the weights
/// resident. That is this one.
///
/// It carries one rule 1.7 wrote down explicitly, and it is the reason this is a
/// notifier rather than a button calling `provision()`: **a download that failed its
/// digest is sticky.** The provisioner is happy to try again, and on a mistyped pin it
/// will fail again, identically, after transferring 2.6GB. A tap-to-retry button over
/// that behaviour is a way to burn a technician's data plan on a configuration error.
/// So [ModelProvisioningController] refuses to re-download until something that could
/// change the outcome changes.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'model_descriptor.dart';
import 'model_provisioner.dart';
import 'providers.dart';

/// What provisioning is doing, or what came of it.
@immutable
sealed class ModelProvisioningState {
  const ModelProvisioningState();
}

/// Nothing has been attempted in this session.
final class ProvisioningIdle extends ModelProvisioningState {
  const ProvisioningIdle();
}

/// A transfer or verification is running.
final class ProvisioningRunning extends ModelProvisioningState {
  const ProvisioningRunning({required this.phase, this.fraction});

  final ModelProvisionPhase phase;

  /// Completed share in `0.0..1.0`, or `null` when the total is genuinely unknown —
  /// the UI then shows an indeterminate indicator rather than a made-up percentage.
  final double? fraction;
}

/// Verified weights are installed.
final class ProvisioningSucceeded extends ModelProvisioningState {
  const ProvisioningSucceeded({required this.sizeBytes, required this.source});

  final int sizeBytes;
  final ModelVerificationSource source;
}

/// Provisioning failed, with the operator's next step.
final class ProvisioningFailed extends ModelProvisioningState {
  const ProvisioningFailed({required this.message, required this.retryable});

  final String message;

  /// Whether tapping again could plausibly do anything different.
  ///
  /// False for the sticky case: bytes that arrived intact and hashed to the wrong
  /// value mean the URL and the pin disagree, and *nothing* about a retry changes
  /// that — it just moves the same gigabytes again.
  final bool retryable;
}

/// Drives [ModelProvisioner] on behalf of the UI.
class ModelProvisioningController extends Notifier<ModelProvisioningState> {
  /// Digest that a download has already been proven to disagree with.
  ///
  /// Held rather than a bare "failed" flag so the block lifts exactly when it should:
  /// a new pin (a corrected `--dart-define`, a moved revision) is a genuinely
  /// different question and is allowed to fetch. Session-scoped on purpose — it
  /// guards against a repeated tap, not against a relaunch, and persisting it would
  /// mean a user could never recover a device whose flash really did corrupt one
  /// download.
  String? _rejectedPin;

  @override
  ModelProvisioningState build() => const ProvisioningIdle();

  /// Fetches and verifies the active model's weights, unless a previous download of
  /// this exact pin already failed verification.
  Future<void> provision() async {
    if (state is ProvisioningRunning) return;

    final descriptor = ref.read(activeModelDescriptorProvider);
    if (_rejectedPin == descriptor.sha256Hex) {
      state = ProvisioningFailed(
        message:
            'the last download of this artifact hashed to something other than '
            'the pinned digest. Re-downloading would transfer it again and fail '
            'the same way. Check FIELDOPS_MODEL_URI and FIELDOPS_MODEL_SHA256 '
            'describe the same revision.',
        retryable: false,
      );
      return;
    }

    state = const ProvisioningRunning(phase: ModelProvisionPhase.downloading);
    final provisioner = await ref.read(modelProvisionerProvider.future);

    final result = await provisioner.provision(
      descriptor,
      onProgress: (progress) {
        // Progress after a teardown would write into a disposed notifier; the
        // callback fires once per chunk, so this is not hypothetical.
        if (state is! ProvisioningRunning) return;
        state = ProvisioningRunning(
          phase: progress.phase,
          fraction: progress.fraction,
        );
      },
    );

    state = _stateFor(result, descriptor);
    // Readiness is what gates the engine, and it is cached; a completed provisioning
    // has to invalidate it or the UI keeps reporting the state from before the
    // download.
    ref.invalidate(modelInstallStatusProvider);
  }

  ModelProvisioningState _stateFor(
    ModelProvisionResult result,
    ModelDescriptor descriptor,
  ) {
    switch (result) {
      case ModelVerified(:final sizeBytes, :final source):
        // A later re-verification of a *good* install must be able to clear an old
        // rejection; otherwise a device that recovered stays blocked.
        _rejectedPin = null;
        return ProvisioningSucceeded(sizeBytes: sizeBytes, source: source);

      case ModelCorrupt(
        :final actualSha256Hex,
        :final expectedSha256Hex,
        :final origin,
      ):
        // Only *downloaded* bytes make a pin sticky. An installed file failing the
        // pin is the ordinary upgrade path — the pin moved to a new revision — and
        // downloading the replacement is exactly the right response.
        if (origin == ModelByteOrigin.download) {
          _rejectedPin = descriptor.sha256Hex;
          return ProvisioningFailed(
            message:
                'the download completed but hashed to $actualSha256Hex instead '
                'of $expectedSha256Hex. The URL and the pinned digest describe '
                'different bytes; fix the configuration rather than retrying.',
            retryable: false,
          );
        }
        return ProvisioningFailed(
          message:
              'the installed weights do not match the pinned digest '
              '($actualSha256Hex). They will be replaced by a fresh download.',
          retryable: true,
        );

      case ModelDownloadFailed(:final message, :final statusCode):
        // Transport failures are the retryable kind by definition: a basement with
        // no signal is the app's whole premise.
        return ProvisioningFailed(
          message: statusCode == null ? message : 'HTTP $statusCode: $message',
          retryable: true,
        );

      case ModelNotConfigured(:final issue):
        return ProvisioningFailed(
          message: switch (issue) {
            ModelConfigurationIssue.missingSource =>
              'no model source configured — set FIELDOPS_MODEL_URI (license: '
                  '${descriptor.licensePage}).',
            ModelConfigurationIssue.unpinnedHash =>
              'no SHA-256 pinned — set FIELDOPS_MODEL_SHA256. Weights are never '
                  'installed unverified.',
          },
          // Nothing was transferred and nothing about the build changed, so a retry
          // is pointless until a define does.
          retryable: false,
        );

      case ModelAbsent():
        // `provision()` never returns this — it is `verifyInstalled`'s answer — but
        // the switch is exhaustive and a silent fall-through here would be a lie
        // about state.
        return const ProvisioningFailed(
          message: 'nothing was installed and nothing was fetched',
          retryable: true,
        );
    }
  }
}

/// The provisioning trigger the UI reads.
final modelProvisioningControllerProvider =
    NotifierProvider<ModelProvisioningController, ModelProvisioningState>(
      ModelProvisioningController.new,
    );
