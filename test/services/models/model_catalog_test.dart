import 'package:field_ops_copilot/services/models/model_descriptor.dart';
import 'package:flutter_test/flutter_test.dart';

/// TC-PROV-CFG-01: the two configuration paths are independent.
///
/// The STT repository is ungated `apache-2.0`, so its sources and per-file pins
/// are **committed** on the catalog entry; the Gemma artifact is licence-gated,
/// so its source and pin arrive only via `--dart-define`. The host test runner
/// passes no defines, which makes this suite exactly the environment the AC
/// describes: "no `--dart-define` at all".
void main() {
  group('TC-PROV-CFG-01: committed config for an ungated model', () {
    test('the STT descriptor is fully configured with no defines', () {
      final stt = ModelCatalog.byId(ModelCatalog.sttZipformerId);

      expect(stt, isNotNull);
      expect(
        stt!.configurationIssue,
        isNull,
        reason:
            'sources and pins are committed, nothing is supplied at build '
            'time',
      );
      // Four files, each individually pinned and sourced — a set-level check
      // alone could hide one unpinned member.
      expect(stt.files, hasLength(4));
      for (final file in stt.files) {
        expect(file.downloadUri, isNotNull, reason: file.fileName);
        expect(file.hasPinnedHash, isTrue, reason: file.fileName);
        expect(file.approximateSizeBytes, isPositive, reason: file.fileName);
      }
      // The measured artifact shape: 43,649,301 bytes across the four files
      // (HuggingFace paths-info, 2026-08-10).
      expect(stt.approximateSizeBytes, 43649301);
    });

    test('the LLM descriptor still reports missingSource without defines', () {
      final llm = ModelCatalog.active;

      expect(
        llm.configurationIssue,
        ModelConfigurationIssue.missingSource,
        reason:
            'a gated artifact must not acquire a committed source as a '
            'side effect of the STT entry gaining one',
      );
    });

    test('the provisioned list is the LLM first, then the STT set', () {
      final provisioned = ModelCatalog.provisioned;

      expect(provisioned, hasLength(2));
      expect(provisioned.first.id, ModelCatalog.active.id);
      expect(provisioned.last.id, ModelCatalog.sttZipformerId);
    });

    test('every STT download URL points at the repository the licence page '
        'names', () {
      final stt = ModelCatalog.byId(ModelCatalog.sttZipformerId)!;

      for (final file in stt.files) {
        expect(
          file.downloadUri.toString(),
          startsWith(stt.licensePage),
          reason:
              'the committed source and the page an operator is sent to must '
              'be the same repository',
        );
      }
    });
  });
}
