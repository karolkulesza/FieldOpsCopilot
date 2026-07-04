import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A source-level guard on the one property this project cannot afford to lose:
/// **the production graph never answers from `FakeLlmEngine`.**
///
/// `agentEngineProvider` returns `null` rather than falling back to the fake,
/// because a fallback produces an app that answers a technician fluently, in
/// well-formatted prose, from a scripted list — on a device where the model never
/// ran. That is indistinguishable from success in a screen recording, which is the
/// artefact Task 1.11 exists to produce.
///
/// **Why this is a source test and not a mutation or a behavioural one**, stated
/// because a test that reads files is unusual enough to need a reason:
///
/// * A *behavioural* test cannot reach the real `agentEngineProvider` body on a
///   host. Its chain is `deviceLlmEngineProvider` → `inferenceConfigProvider` →
///   `modelInstallStatusProvider` → `ModelStorage.openDefault()`, which is a
///   platform channel. Every host test that touches the seam overrides it, so none
///   of them says anything about the real one.
/// * A *mutation* cannot express the defect either. Adding the fallback to
///   `lib/services/inference/providers.dart` requires importing
///   `engines/providers.dart` or `engines/fakes/`, and the mutation harness applies
///   one contiguous string replacement — it cannot add an import as well, so the
///   mutation only ever reports `NO_COMPILE`. That was review-round mutation M36,
///   and it is recorded as inexpressible rather than as passing.
///
/// What *is* checkable, cheaply and exactly, is that no file on the production path
/// so much as mentions a fake. That is a stronger statement than any single
/// behavioural test: it holds for code nobody has written yet.
void main() {
  /// Where a fake is legitimate: the fakes themselves, and the Tier 0 DI seam that
  /// binds them for tests and for `SttEngine`/`VisionEngine`/`PlatformTelemetry`,
  /// none of which has a real backend yet.
  const allowed = {
    'lib/engines/fakes/fake_llm_engine.dart',
    'lib/engines/fakes/fake_stt_engine.dart',
    'lib/engines/fakes/fake_vision_engine.dart',
    'lib/engines/fakes/fake_platform_telemetry.dart',
    'lib/engines/providers.dart',
  };

  test('nothing on the production inference path references a fake engine', () {
    final offenders = <String, List<int>>{};

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final path = entity.path.replaceAll(r'\', '/');
      if (allowed.contains(path)) continue;

      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        // Doc comments are where the *reason* for this rule is written down, so
        // they must be able to name the class. Only code counts.
        if (line.trimLeft().startsWith('///')) continue;
        if (line.trimLeft().startsWith('//')) continue;
        if (line.contains('FakeLlmEngine') || line.contains('engines/fakes/')) {
          offenders.putIfAbsent(path, () => []).add(i + 1);
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'a production reference to a fake engine means the app can answer '
          'from a script on a device where the model never ran, which is '
          'indistinguishable from success in a recording. Offending lines: '
          '$offenders',
    );
  });

  // **The scan above has a hole, and the mutation that found it is why this second
  // test exists.** `lib/engines/providers.dart` is allow-listed wholesale, because
  // binding fakes is its job for the three engine seams with no real backend yet.
  // So a fake could be bound *there* under a new name and consumed from the
  // inference path without the string `FakeLlmEngine` ever appearing in a
  // non-allow-listed file — mutation M36 did exactly that and survived.
  //
  // The real boundary is therefore the **import**: nothing on the path from the
  // demo screen to the engine may reach the seam that binds fakes at all. Nothing
  // does today (deleting the Tier 0 home screen removed the last consumer), which
  // is what makes this checkable rather than aspirational.
  test('the production path does not import the fake-binding seam', () {
    const productionPaths = [
      'lib/services/inference/',
      'lib/services/ai/',
      'lib/services/rag/',
      'lib/viewmodels/',
      'lib/views/',
    ];
    final offenders = <String>[];

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final path = entity.path.replaceAll(r'\', '/');
      if (!productionPaths.any(path.startsWith)) continue;

      for (final line in entity.readAsLinesSync()) {
        final trimmed = line.trimLeft();
        if (!trimmed.startsWith('import ')) continue;
        if (trimmed.contains('engines/providers.dart')) offenders.add(path);
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'these files can reach a fake-bound provider without naming a fake, '
          'which the scan above cannot see: $offenders',
    );
  });

  // The guard above is worthless if its allow-list has quietly grown to cover the
  // file it is meant to protect. Named explicitly, so widening it is a visible edit
  // rather than a silent one.
  test('the allow-list does not cover the inference seam it protects', () {
    expect(allowed, isNot(contains('lib/services/inference/providers.dart')));
    expect(allowed, isNot(contains('lib/viewmodels/field_job_viewmodel.dart')));
    expect(allowed, isNot(contains('lib/views/diagnose_screen.dart')));
  });

  // And the detector has to be able to fail. A guard nobody has watched fail is the
  // thing this project keeps paying for, so this asserts the scan finds what it is
  // looking for when it *is* there — using the fake's own file, which the
  // allow-list exempts precisely because it legitimately contains the name.
  test('the scan does detect the string it searches for', () {
    final fake = File(
      'lib/engines/fakes/fake_llm_engine.dart',
    ).readAsStringSync();

    expect(
      fake,
      contains('FakeLlmEngine'),
      reason:
          'if this file stopped containing the name, the scan above would '
          'pass by searching for something that no longer exists',
    );
  });
}
