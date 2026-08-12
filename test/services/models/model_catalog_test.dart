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

    // R0-F1: the STT id is a documented catalog value an operator can pass as
    // FIELDOPS_MODEL_ID, and before the fix it crashed every reader of
    // `active` with a StateError out of `soleFile` — before the first frame.
    test('a multi-file FIELDOPS_MODEL_ID falls back to the primary LLM '
        'instead of throwing', () {
      final active = ModelCatalog.activeFor(ModelCatalog.sttZipformerId);

      expect(active.id, ModelCatalog.gemma4E2bId);
      expect(active.files, hasLength(1));
    });

    test('an unknown FIELDOPS_MODEL_ID falls back to the primary LLM', () {
      expect(ModelCatalog.activeFor('a-typo').id, ModelCatalog.gemma4E2bId);
    });

    test('a known single-file FIELDOPS_MODEL_ID is honoured', () {
      expect(
        ModelCatalog.activeFor(ModelCatalog.gemma31bId).id,
        ModelCatalog.gemma31bId,
      );
    });

    // R0-F3: the access token pairs with the define-configured source; the
    // committed STT entry must decline it, the Gemma entries (including the
    // gated 3 1B) must keep it.
    test('only the define-configured models send the access token', () {
      expect(
        ModelCatalog.byId(ModelCatalog.sttZipformerId)!.sendsAuthToken,
        isFalse,
      );
      expect(
        ModelCatalog.byId(ModelCatalog.gemma4E2bId)!.sendsAuthToken,
        isTrue,
      );
      expect(
        ModelCatalog.byId(ModelCatalog.gemma31bId)!.sendsAuthToken,
        isTrue,
      );
      // And the overlay must not lose the flag on its way to `active`.
      expect(ModelCatalog.active.sendsAuthToken, isTrue);
    });

    test('the provisioned list is the LLM first, then the STT set', () {
      final provisioned = ModelCatalog.provisioned;

      expect(provisioned, hasLength(2));
      expect(provisioned.first.id, ModelCatalog.active.id);
      expect(provisioned.last.id, ModelCatalog.sttZipformerId);
    });

    test('pinFingerprint moves when any member pin moves', () {
      // The controller's sticky-rejection rule compares this string; a
      // fingerprint that ignored a member would keep a set blocked after the
      // operator corrected exactly the pin that was wrong.
      ModelDescriptor withPins(List<String> pins) => ModelDescriptor.fileSet(
        id: 'set',
        displayName: 'Set',
        licensePage: 'https://example.invalid',
        files: [
          for (final (i, pin) in pins.indexed)
            ModelArtifactFile(fileName: 'f$i', sha256Hex: pin),
        ],
      );

      final base = withPins(['a' * 64, 'b' * 64, 'c' * 64]);
      expect(
        base.pinFingerprint,
        withPins(['a' * 64, 'b' * 64, 'c' * 64]).pinFingerprint,
      );
      // Each member participates — including the last.
      for (var i = 0; i < 3; i++) {
        final pins = ['a' * 64, 'b' * 64, 'c' * 64];
        pins[i] = 'd' * 64;
        expect(
          withPins(pins).pinFingerprint,
          isNot(base.pinFingerprint),
          reason: 'member $i must be part of the fingerprint',
        );
      }
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
