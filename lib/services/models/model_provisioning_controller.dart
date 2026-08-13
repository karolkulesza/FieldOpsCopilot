/// The user-facing trigger for provisioning model weights.
///
/// Task 1.7 built everything underneath this — download with progress, streaming
/// SHA-256, atomic install, per-model serialisation — and deliberately shipped no way
/// to *start* it, leaving the trigger to the task that first needs the weights
/// resident. That is this one.
///
/// Task 2.0 made it a **family keyed by model id**: the banner shows one row per
/// provisioned model, and each row needs its own trigger, its own progress and its
/// own failure — a shared notifier would show the STT download's progress bar under
/// the LLM's label. The sticky-rejection rule below is per model for the same
/// reason: a bad Gemma pin must not block fetching the STT set.
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
  const ProvisioningRunning({
    required this.phase,
    this.fraction,
    this.fileIndex = 1,
    this.fileCount = 1,
  });

  final ModelProvisionPhase phase;

  /// Completed share in `0.0..1.0`, or `null` when the total is genuinely unknown —
  /// the UI then shows an indeterminate indicator rather than a made-up percentage.
  final double? fraction;

  /// Which file of the set is in flight (1-based), and how many there are —
  /// straight from [ModelProvisionProgress]. `1 of 1` for a single-file model,
  /// which the UI renders as no annotation at all.
  final int fileIndex;
  final int fileCount;
}

/// Verified weights are installed.
final class ProvisioningSucceeded extends ModelProvisioningState {
  const ProvisioningSucceeded({required this.sizeBytes, required this.source});

  /// Total bytes across the model's whole file set.
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

/// Drives [ModelProvisioner] for one provisioned model on behalf of the UI.
class ModelProvisioningController extends Notifier<ModelProvisioningState> {
  ModelProvisioningController(this.modelId);

  /// Which provisioned model this instance is the trigger for — the family
  /// argument.
  final String modelId;

  /// Pin fingerprint that a download has already been proven to disagree with.
  ///
  /// Held rather than a bare "failed" flag so the block lifts exactly when it should:
  /// a new pin (a corrected `--dart-define`, a moved revision) is a genuinely
  /// different question and is allowed to fetch. A *fingerprint* over the whole file
  /// set rather than Task 1.7's single hash, because any one member pin moving makes
  /// the download a different question. Session-scoped on purpose — it guards
  /// against a repeated tap, not against a relaunch, and persisting it would mean a
  /// user could never recover a device whose flash really did corrupt one download.
  String? _rejectedPins;

  @override
  ModelProvisioningState build() => const ProvisioningIdle();

  /// Fetches and verifies this model's weights, unless a previous download of
  /// these exact pins already failed verification.
  Future<void> provision() async {
    if (state is ProvisioningRunning) return;

    final descriptor = ref.read(modelDescriptorProvider(modelId));
    if (descriptor == null) {
      // A trigger for a model this build does not provision. Unreachable from
      // the banner, which builds its rows from the same list this provider
      // reads — but a notifier is public API and "do nothing silently" would
      // leave the tapper staring at an idle button.
      state = ProvisioningFailed(
        message: 'this build does not provision a model with id "$modelId".',
        retryable: false,
      );
      return;
    }

    if (_rejectedPins == descriptor.pinFingerprint) {
      state = const ProvisioningFailed(
        message:
            'the last download of this artifact hashed to something other than '
            'the pinned digest. Re-downloading would transfer it again and fail '
            'the same way. Check that the source and pinned SHA-256 describe '
            'the same revision.',
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
          fileIndex: progress.fileIndex,
          fileCount: progress.fileCount,
        );
      },
    );

    state = _stateFor(result, descriptor);
    // Readiness is what gates the engine, and it is cached; a completed provisioning
    // has to invalidate it or the UI keeps reporting the state from before the
    // download. This model's instance only: the family sibling of a model this
    // run never touched has nothing to re-read.
    ref.invalidate(modelInstallStatusProvider(modelId));
  }

  ModelProvisioningState _stateFor(
    ModelProvisionResult result,
    ModelDescriptor descriptor,
  ) {
    switch (result) {
      case ModelVerified(:final sizeBytes, :final source):
        // A later re-verification of a *good* install must be able to clear an old
        // rejection; otherwise a device that recovered stays blocked.
        _rejectedPins = null;
        return ProvisioningSucceeded(sizeBytes: sizeBytes, source: source);

      case ModelCorrupt(
        :final fileName,
        :final actualSha256Hex,
        :final expectedSha256Hex,
        :final origin,
      ):
        // Only *downloaded* bytes make a pin sticky. An installed file failing the
        // pin is the ordinary upgrade path — the pin moved to a new revision — and
        // downloading the replacement is exactly the right response.
        if (origin == ModelByteOrigin.download) {
          _rejectedPins = descriptor.pinFingerprint;
          return ProvisioningFailed(
            message:
                '$fileName downloaded completely but hashed to '
                '$actualSha256Hex instead of $expectedSha256Hex. The URL and '
                'the pinned digest describe different bytes; fix the '
                'configuration rather than retrying.',
            retryable: false,
          );
        }
        return ProvisioningFailed(
          message:
              'the installed $fileName does not match the pinned digest '
              '($actualSha256Hex). It will be replaced by a fresh download.',
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

/// The provisioning trigger the UI reads — one per provisioned model, keyed by
/// model id.
final modelProvisioningControllerProvider =
    NotifierProvider.family<
      ModelProvisioningController,
      ModelProvisioningState,
      String
    >(ModelProvisioningController.new);
