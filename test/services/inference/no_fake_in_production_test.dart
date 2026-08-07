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
///   mutation only ever reports `NO_COMPILE`. That was review mutation M36.
///
/// **This file has now been wrong twice, and both times a mutation found it. That
/// history is why it is shaped the way it is.**
///
/// 1. The first version scanned for the string `FakeLlmEngine` outside an
///    allow-list — one that includes `lib/engines/providers.dart`, whose *job* is
///    binding fakes. So a fake bound there under a new name and consumed from the
///    inference path was invisible (M36, retargeted).
/// 2. The second version added an import check, but only over a hand-listed set of
///    "production" directories that **did not include `lib/main.dart`** — the file
///    holding the app's only root `ProviderScope`, and therefore the single most
///    likely home for exactly this override. Review finding **R1-F3**: a `main.dart`
///    importing `engines/providers.dart` and overriding `agentEngineProvider` with
///    `llmEngineProvider` compiles, answers every inquiry from a script, and
///    survived all four tests here.
/// 3. And **neither detector could be disabled detectably** (review finding
///    **R1-F2**): `if (false && …)` on either one left every test green, because a
///    scan is only ever run over a tree with nothing to find, so a dead detector and
///    a clean tree look identical. The test written as the answer to that grepped the
///    fake's file directly and never ran the scan at all — a canary on the search
///    literal, not on the detector.
///
/// So the scan is now **one function over the whole of `lib/`**, exempting
/// `lib/engines/` rather than enumerating what to include ("what may not" is a
/// closed question; "what counts as production" is not), and it is exercised in
/// **both directions** — empty for the real tree, and *reporting the offender* when
/// pointed at a tree that has one. A detector that has only ever returned empty is
/// not a detector.
void main() {
  /// The one subtree where naming or binding a fake is legitimate: the fakes
  /// themselves and the Tier 0 DI seam that binds them, which still serves
  /// `SttEngine` / `VisionEngine` / `PlatformTelemetry` — none of which has a real
  /// backend yet.
  ///
  /// An exemption rather than an inclusion list. `lib/main.dart` being absent from
  /// an inclusion list is what R1-F3 was; a subtree that is *allowed* to mention
  /// fakes is a closed set, so it cannot acquire a hole by omission.
  const exemptPrefix = 'lib/engines/';

  /// Every `lib/` file that mentions a fake engine or reaches the seam that binds
  /// one, as `path -> [line numbers]`.
  ///
  /// Takes its roots and exemption as parameters so the positive path is testable:
  /// pointed at `lib/engines/` with nothing exempt, it must *find* something.
  Map<String, List<int>> scan({required String root, required String exempt}) {
    final offenders = <String, List<int>>{};

    for (final entity in Directory(root).listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final path = entity.path.replaceAll(r'\', '/');
      if (exempt.isNotEmpty && path.startsWith(exempt)) continue;

      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final trimmed = lines[i].trimLeft();
        // Doc and line comments are where the *reason* for this rule is written
        // down, so they must be able to name the class. Only code counts.
        if (trimmed.startsWith('//')) continue;
        final namesAFake =
            trimmed.contains('FakeLlmEngine') ||
            trimmed.contains('engines/fakes/');
        // The import check is the half R1-F3 needed: a fake can be bound in the
        // exempt seam under any name, so reaching that seam at all is the boundary.
        final reachesTheSeam =
            trimmed.startsWith('import ') &&
            trimmed.contains('engines/providers.dart');
        if (namesAFake || reachesTheSeam) {
          offenders.putIfAbsent(path, () => []).add(i + 1);
        }
      }
    }
    return offenders;
  }

  test('no production file names a fake or reaches the seam that binds one', () {
    expect(
      scan(root: 'lib', exempt: exemptPrefix),
      isEmpty,
      reason:
          'a production reference to a fake engine — or an import of the seam '
          'that binds one — means the app can answer from a script on a device '
          'where the model never ran, which is indistinguishable from success '
          'in a recording',
    );
  });

  group('the detector can actually detect', () {
    // R1-F2: both detectors were disableable without a single test noticing,
    // because a scan is only ever run over a tree with nothing to find. These run
    // it over a tree that *does*, so a dead detector fails here.
    test('it reports a file that names a fake', () {
      final found = scan(root: 'lib/engines', exempt: '');

      expect(
        found.keys,
        contains('lib/engines/fakes/fake_llm_engine.dart'),
        reason: 'detector 1 (the FakeLlmEngine name) must find the fake itself',
      );
      expect(found['lib/engines/fakes/fake_llm_engine.dart'], isNotEmpty);
    });

    test('it reports a file that imports the fake-binding seam', () {
      final probe = Directory.systemTemp.createTempSync('fieldops_scan_probe');
      addTearDown(() => probe.deleteSync(recursive: true));
      final root = probe.path.replaceAll(r'\', '/');
      File('$root/offender.dart').writeAsStringSync(
        "import '../../engines/providers.dart';\n"
        'void main() {}\n',
      );

      final found = scan(root: root, exempt: '');

      expect(
        found['$root/offender.dart'],
        [1],
        reason: 'detector 2 (the seam import) must find it, on line 1',
      );
    });

    // The exact shape R1-F3 demonstrated, written to a probe tree rather than to
    // the real `lib/main.dart`: an override that binds the fake seam into
    // `agentEngineProvider`. If this stops being reported, the hole is back.
    test('it reports the R1-F3 shape — a root ProviderScope override', () {
      final probe = Directory.systemTemp.createTempSync('fieldops_scan_main');
      addTearDown(() => probe.deleteSync(recursive: true));
      final root = probe.path.replaceAll(r'\', '/');
      File('$root/main.dart').writeAsStringSync('''
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'engines/providers.dart';
import 'services/inference/providers.dart';
import 'app.dart';

void main() {
  runApp(
    ProviderScope(
      overrides: [
        agentEngineProvider.overrideWith((ref) async => ref.watch(llmEngineProvider)),
      ],
      child: const FieldOpsApp(),
    ),
  );
}
''');

      expect(scan(root: root, exempt: '').keys, contains('$root/main.dart'));
    });

    // And a clean tree must come back empty, or the two tests above would pass on
    // a detector that reports everything.
    test('it reports nothing for a file with no fake and no seam import', () {
      final probe = Directory.systemTemp.createTempSync('fieldops_scan_clean');
      addTearDown(() => probe.deleteSync(recursive: true));
      final root = probe.path.replaceAll(r'\', '/');
      File('$root/clean.dart').writeAsStringSync(
        "import 'package:flutter/material.dart';\n"
        '/// Mentions FakeLlmEngine only in a doc comment.\n'
        'void main() {}\n',
      );

      expect(scan(root: root, exempt: ''), isEmpty);
    });
  });

  group('the scan covers what it claims to', () {
    // R1-F3's root cause was coverage, not detection: the file that mattered was
    // simply not in the scanned set. Asserted directly, so narrowing the scan is a
    // visible edit rather than a silent one.
    test('the scanned set includes main.dart and app.dart', () {
      final scanned = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .map((f) => f.path.replaceAll(r'\', '/'))
          .where((p) => p.endsWith('.dart') && !p.startsWith(exemptPrefix))
          .toSet();

      expect(scanned, contains('lib/main.dart'));
      expect(scanned, contains('lib/app.dart'));
      expect(scanned, contains('lib/services/inference/providers.dart'));
      expect(scanned, contains('lib/viewmodels/field_job_viewmodel.dart'));
      expect(scanned, contains('lib/views/diagnose_screen.dart'));
    });

    // The exemption is a prefix, so it cannot grow to cover a file by omission —
    // but it could be widened deliberately. Pin what it must never swallow.
    test('the exemption does not cover the seam it protects', () {
      for (final path in [
        'lib/main.dart',
        'lib/app.dart',
        'lib/services/inference/providers.dart',
        'lib/viewmodels/field_job_viewmodel.dart',
        'lib/views/diagnose_screen.dart',
      ]) {
        expect(path.startsWith(exemptPrefix), isFalse, reason: path);
      }
    });
  });
}
