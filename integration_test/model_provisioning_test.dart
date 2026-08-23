import 'package:field_ops_copilot/services/models/model_descriptor.dart';
import 'package:field_ops_copilot/services/models/model_provisioner.dart';
import 'package:field_ops_copilot/services/models/model_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// TC-PROV-E2E-01 — real download, verify and install, on a device.
///
/// Run manually, once, against the real artifact:
///
/// ```sh
/// flutter test integration_test/model_provisioning_test.dart \
///   --dart-define=FIELDOPS_MODEL_URI=<resolve URL for the file you licensed> \
///   --dart-define=FIELDOPS_MODEL_SHA256=<shasum -a 256 of that file> \
///   --dart-define=FIELDOPS_MODEL_TOKEN=<access token>
/// ```
///
/// It **skips** without those defines rather than failing, because a checkout has
/// no artifact to fetch and CI must not try: the transfer is gigabytes over the
/// network, and some sources additionally gate downloads behind a token. That is
/// also why this lives in `integration_test/`, which `flutter test` does not pick
/// up.
///
/// Scope note, stated plainly: the AC's wording is "engine can load the installed
/// model", and loading is not this suite's job. What this asserts is everything
/// provisioning owns: the bytes arrive, hash to the pinned digest, land at the path
/// an engine will load from, survive an independent re-hash, and are marked
/// no-backup. The load handshake is asserted in
/// `integration_test/llm_inference_test.dart` (TC-LLM-LOAD-01), which consumes
/// this artifact.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final descriptor = ModelCatalog.active;
  final issue = descriptor.configurationIssue;

  testWidgets(
    'downloads, verifies and installs the real model weights',
    (tester) async {
      if (issue != null) {
        // Reported as a skip with the exact remedy rather than a bare `skip:`
        // flag, so whoever runs this sees *why* it did not execute.
        markTestSkipped(
          'model source not configured (${issue.name}) — pass '
          'FIELDOPS_MODEL_URI, FIELDOPS_MODEL_SHA256 and '
          'FIELDOPS_MODEL_TOKEN. License: ${descriptor.licensePage}',
        );
        return;
      }

      final storage = await ModelStorage.openDefault();
      final provisioner = ModelProvisioner(
        storage: storage,
        authToken: _token.isEmpty ? null : _token,
      );
      addTearDown(provisioner.dispose);

      // Start from nothing, so this exercises the download path rather than a
      // receipt left by an earlier run.
      await storage.prepare();
      await storage.deleteArtifact(descriptor);
      expect(await provisioner.statusOf(descriptor), ModelInstallStatus.absent);

      var lastReportedPercent = -1;
      final result = await provisioner.provision(
        descriptor,
        onProgress: (progress) {
          final fraction = progress.fraction;
          if (fraction == null) return;
          final percent = (fraction * 100).floor();
          // A gigabyte-scale transfer emits thousands of samples; log at each
          // whole percent so the run is followable without drowning the output.
          if (percent > lastReportedPercent) {
            lastReportedPercent = percent;
            debugPrint('${progress.phase.name}: $percent%');
          }
        },
      );

      expect(
        result,
        isA<ModelVerified>(),
        reason: _describeFailure(result, descriptor),
      );
      final verified = result as ModelVerified;

      expect(verified.sha256Hex, descriptor.soleFile.sha256Hex);
      expect(verified.file.path, storage.installedFile(descriptor).path);
      expect(await verified.file.length(), verified.sizeBytes);
      expect(verified.source, ModelVerificationSource.download);

      // Backup exclusion is only *observable* on iOS/macOS, where the native call
      // either set `NSURLIsExcludedFromBackupKey` or reported a failure. On Android
      // the exclusion is declared in the manifest and applied by the OS at backup
      // time, so this flag is a constant there — asserting it would be a test that
      // passes whether or not the rules work, which is precisely the trap this
      // repo has learned to avoid. Evidence for the Android leg
      // is the merged manifest at build time (`android:fullBackupContent` and
      // `android:dataExtractionRules`), checked in the build, not here.
      switch (PlatformBackupExclusion.mechanismFor()) {
        case BackupExclusionMechanism.resourceAttribute:
          expect(
            verified.excludedFromBackup,
            isTrue,
            reason: 'the native no-backup call must have succeeded',
          );
        case BackupExclusionMechanism.manifest:
          debugPrint(
            'backup exclusion is declarative on this platform; verify the '
            'merged manifest rather than this flag',
          );
        case BackupExclusionMechanism.none:
          fail('no backup-exclusion mechanism on a shipping platform');
      }

      // Progress actually tracked the transfer rather than jumping to done.
      expect(lastReportedPercent, 100);

      // The cheap readiness check now answers from the receipt.
      expect(await provisioner.statusOf(descriptor), ModelInstallStatus.ready);

      // And an independent re-hash of the bytes on disk agrees.
      final rechecked = await provisioner.verifyInstalled(descriptor);
      expect(rechecked, isA<ModelVerified>());
      expect(
        (rechecked as ModelVerified).source,
        ModelVerificationSource.existingFile,
      );
    },
    // A 2.59GB artifact over a real link; generous, and still bounded.
    timeout: const Timeout(Duration(minutes: 45)),
  );
}

const _token = String.fromEnvironment('FIELDOPS_MODEL_TOKEN');

/// Turns a non-verified outcome into something actionable in the test output.
String _describeFailure(
  ModelProvisionResult result,
  ModelDescriptor descriptor,
) => switch (result) {
  ModelVerified() => 'verified',
  ModelCorrupt(:final actualSha256Hex, :final origin) =>
    '${origin.name} bytes hashed to $actualSha256Hex, expected '
        '${descriptor.soleFile.sha256Hex} — re-check FIELDOPS_MODEL_SHA256 against the '
        'exact revision downloaded',
  ModelDownloadFailed(:final message, :final statusCode) =>
    'download failed${statusCode == null ? '' : ' ($statusCode)'}: $message',
  ModelNotConfigured(:final issue) => 'not configured: ${issue.name}',
  ModelAbsent() => 'nothing installed',
};
