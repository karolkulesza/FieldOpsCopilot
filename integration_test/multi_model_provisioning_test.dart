import 'package:field_ops_copilot/services/models/model_descriptor.dart';
import 'package:field_ops_copilot/services/models/model_provisioner.dart';
import 'package:field_ops_copilot/services/models/model_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// TC-PROV-SET-04 — both models coexist on a real device.
///
/// Provisions the STT set (four real files, 43.65MB total, from the committed
/// ungated source — no defines needed) *next to* whatever LLM install the device
/// carries, and asserts the LLM's on-disk state is untouched by the STT install:
/// same status, same receipts, byte-identical receipt sidecars.
///
/// Run manually on a device:
///
/// ```sh
/// flutter test integration_test/multi_model_provisioning_test.dart
/// ```
///
/// Unlike TC-PROV-E2E-01 this needs **no** `--dart-define`: the STT source and
/// its per-file pins are committed on the catalog entry, which is itself half of
/// what Task 2.0 claims (TC-PROV-CFG-01 pins the other half on the host).
///
/// The LLM's side of "coexist" is asserted against whatever is actually on the
/// device: if the demo iPad's 2.59GB Gemma install is present (in either the
/// flat Task 1.7 layout — which the first status check migrates by rename — or
/// the per-model layout), the test proves the STT install left it alone. On a
/// device with no LLM installed it still proves the two models' paths are
/// disjoint, just against an absent LLM; the stronger run is the one the demo
/// device gives you.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'provisioning the STT set leaves the LLM install untouched',
    (tester) async {
      final llm = ModelCatalog.active;
      final stt = ModelCatalog.byId(ModelCatalog.sttZipformerId)!;
      expect(
        stt.configurationIssue,
        isNull,
        reason: 'the STT config is committed; nothing to pass at build time',
      );

      final storage = await ModelStorage.openDefault();
      final provisioner = ModelProvisioner(storage: storage);
      addTearDown(provisioner.dispose);
      await storage.prepare();

      // Snapshot the LLM's state before the STT install. `statusOf` also runs
      // the legacy-layout migration, so the snapshot is of the post-migration
      // layout — the one the STT install will share a root with.
      final llmStatusBefore = await provisioner.statusOf(llm);
      final llmReceiptBefore = await _receiptBytes(storage, llm);
      final llmFileBefore = await _fileStat(storage, llm);
      debugPrint('[TC-PROV-SET-04] LLM before: ${llmStatusBefore.name}');

      // A clean STT slate, so this exercises the real four-file download.
      await storage.deleteArtifact(stt);
      expect(await provisioner.statusOf(stt), ModelInstallStatus.absent);

      var lastReportedPercent = -1;
      final result = await provisioner.provision(
        stt,
        onProgress: (progress) {
          final fraction = progress.fraction;
          if (fraction == null) return;
          final percent = (fraction * 100).floor();
          if (percent > lastReportedPercent) {
            lastReportedPercent = percent;
            debugPrint(
              '${progress.phase.name} (file ${progress.fileIndex}/'
              '${progress.fileCount}): $percent%',
            );
          }
        },
      );

      expect(result, isA<ModelVerified>(), reason: '$result');
      final verified = result as ModelVerified;
      expect(verified.artifacts, hasLength(4));
      expect(await provisioner.statusOf(stt), ModelInstallStatus.ready);

      // An independent re-hash of all four files agrees with the pins.
      final rechecked = await provisioner.verifyInstalled(stt);
      expect(rechecked, isA<ModelVerified>());

      // The AC's point: the LLM was not touched. Status unchanged, receipt
      // byte-identical, artifact same size and modification time.
      expect(await provisioner.statusOf(llm), llmStatusBefore);
      expect(await _receiptBytes(storage, llm), llmReceiptBefore);
      expect(await _fileStat(storage, llm), llmFileBefore);
    },
    // 43.65MB over a real link, plus hashing; generous, and still bounded.
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

/// The LLM's receipt as a string, or `null` when there is none.
Future<String?> _receiptBytes(ModelStorage storage, ModelDescriptor llm) async {
  final receipt = storage.receiptFile(llm);
  return await receipt.exists() ? receipt.readAsString() : null;
}

/// Size and mtime of the LLM's artifact, or `null` when absent — enough to
/// detect the install being rewritten, without hashing 2.6GB twice in one test.
Future<String?> _fileStat(ModelStorage storage, ModelDescriptor llm) async {
  final file = storage.installedFile(llm);
  if (!await file.exists()) return null;
  final stat = await file.stat();
  return '${stat.size}:${stat.modified.microsecondsSinceEpoch}';
}
