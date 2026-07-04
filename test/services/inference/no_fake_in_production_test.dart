import 'dart:io';

import 'package:path/path.dart' as p;
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
/// **Why a source test rather than a mutation or a behavioural one.** A behavioural
/// test cannot reach the real `agentEngineProvider` on a host: its chain ends in
/// `ModelStorage.openDefault()`, a platform channel, and every host test that touches
/// the seam overrides it. A mutation cannot express the defect either, because adding
/// the fallback needs an added import *and* a changed body, and the harness applies
/// one contiguous replacement (review mutation M36).
///
/// **This file has been wrong three times, and every time the same way. That history
/// is the design.**
///
/// 1. It scanned for the string `FakeLlmEngine` outside an allow-list that included
///    `lib/engines/providers.dart`, whose *job* is binding fakes — so a fake bound
///    there under a new name was invisible (M36, retargeted).
/// 2. It added an import check over a hand-listed set of "production" directories
///    that omitted **`lib/main.dart`** — the file holding the app's only root
///    `ProviderScope`, and therefore the likeliest home for exactly this override
///    (**R1-F3**).
/// 3. Inverting to "scan everything, exempt `lib/engines/`" fixed *which files are
///    scanned* — permanently, and there is a coverage test for it — but not *what
///    counts as reaching a fake*. That was still an enumeration: one directory and one
///    filename. So the exempt zone was a subtree while the boundary into it named a
///    single file, which is an inclusion list of size one. **R2-F2** demonstrated two
///    ways through: a *second* fake-binding file inside the exemption
///    (`engines/demo_seam.dart`) consumed by the real `main.dart`, and an `export`
///    barrel, since `startsWith('import ')` does not match `export`.
///
/// **So the boundary is now computed, not listed.** Two passes over one walk:
///
/// * **Pass 1** finds every file *inside* the exemption that mentions a fake. Those
///   are the fake-bearing files. Today that is the four fakes and
///   `engines/providers.dart`; nothing names them.
/// * **Pass 2** flags any file *outside* the exemption that either mentions a fake
///   itself, or has an `import`/`export`/`part` directive resolving to one of pass
///   1's files.
///
/// That needs no literal, and it survives a fifth fake, a renamed seam or a second
/// one. **Transitivity is not needed and that is a property rather than a shortcut:**
/// any chain from production code to a fake-bearing file must pass through some
/// non-exempt file that references it *directly*, and that file is itself flagged. A
/// barrel does not launder the reference, it becomes the offender.
///
/// What the exemption still buys is only what it always did: `lib/engines/` may name
/// fakes, because the Tier 0 DI seam legitimately binds them for `SttEngine`,
/// `VisionEngine` and `PlatformTelemetry`, none of which has a real backend yet. The
/// *exemption* never acquired a hole — both R1-F3 and R2-F1 came from the other side
/// of the boundary, which is the sentence the earlier version of this doc got wrong.
void main() {
  /// The one subtree allowed to name a fake. A closed set, and unlike an inclusion
  /// list it cannot acquire a hole by omission.
  const exemptPrefix = 'lib/engines/';

  /// A code line that names a fake engine directly.
  bool namesAFake(String line) =>
      line.contains('FakeLlmEngine') || line.contains('engines/fakes/');

  /// The URI of an `import` / `export` / `part` directive, or `null`.
  ///
  /// `export` is here because omitting it was R2-F1's Evidence B: a one-line barrel
  /// re-exporting the seam defeated a check that only looked for `import `.
  final directive = RegExp('''^(?:import|export|part)\\s+['"]([^'"]+)['"]''');
  String? directiveTarget({
    required String line,
    required String fromFile,
    required String root,
  }) {
    final uri = directive.firstMatch(line)?.group(1);
    if (uri == null) return null;
    // This package's own `package:` form addresses the scan root — `lib/` for the
    // real tree. Resolved against [root] rather than a hard-coded `lib/` so a probe
    // tree can exercise this branch at all; the first version hard-coded it and the
    // probe silently tested nothing.
    const self = 'package:field_ops_copilot/';
    if (uri.startsWith(self)) return '$root/${uri.substring(self.length)}';
    // Anything else absolute is someone else's code.
    if (uri.startsWith('dart:') || uri.startsWith('package:')) return null;
    return p.normalize(p.join(p.dirname(fromFile), uri)).replaceAll(r'\', '/');
  }

  /// Comments are where the *reason* for this rule is written down, so they must be
  /// able to name the class. Only code counts — and this is `startsWith`, not
  /// `contains`, so a trailing `// …` cannot hide a live line (R2-F3).
  bool isComment(String line) => line.startsWith('//');

  /// Offenders under [root], as `path -> [line numbers]`.
  ///
  /// Takes its root and exemption as parameters so the positive path is testable: a
  /// detector that has only ever returned empty is not a detector (R1-F2).
  Map<String, List<int>> scan({required String root, required String exempt}) {
    final lines = <String, List<String>>{};
    for (final entity in Directory(root).listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      lines[entity.path.replaceAll(r'\', '/')] = entity.readAsLinesSync();
    }

    bool isExempt(String path) => exempt.isNotEmpty && path.startsWith(exempt);

    // Pass 1 — which exempt files bear a fake.
    final fakeBearing = <String>{
      for (final entry in lines.entries)
        if (isExempt(entry.key))
          if (entry.value.any((l) => !isComment(l.trimLeft()) && namesAFake(l)))
            entry.key,
    };

    // Pass 2 — who names a fake, or reaches one of pass 1's files.
    final offenders = <String, List<int>>{};
    for (final entry in lines.entries) {
      if (isExempt(entry.key)) continue;
      for (var i = 0; i < entry.value.length; i++) {
        final line = entry.value[i].trimLeft();
        if (isComment(line)) continue;
        final target = directiveTarget(
          line: line,
          fromFile: entry.key,
          root: root,
        );
        if (namesAFake(line) ||
            (target != null && fakeBearing.contains(target))) {
          offenders.putIfAbsent(entry.key, () => []).add(i + 1);
        }
      }
    }
    return offenders;
  }

  /// Writes [files] into a throwaway tree and returns its root.
  String probeTree(String name, Map<String, String> files) {
    final dir = Directory.systemTemp.createTempSync('fieldops_scan_$name');
    addTearDown(() => dir.deleteSync(recursive: true));
    final root = dir.path.replaceAll(r'\', '/');
    for (final entry in files.entries) {
      final file = File('$root/${entry.key}');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(entry.value);
    }
    return root;
  }

  test('no production file names a fake or reaches one', () {
    expect(
      scan(root: 'lib', exempt: exemptPrefix),
      isEmpty,
      reason:
          'a production reference to a fake engine — directly, or through any '
          'file inside lib/engines/ that binds one — means the app can answer '
          'from a script on a device where the model never ran, which is '
          'indistinguishable from success in a recording',
    );
  });

  group('the detector can actually detect', () {
    // R1-F2: a scan only ever run over a tree with nothing to find cannot be told
    // from a dead one. Every case below runs it over a tree that has something.
    test('it reports a file that names a fake directly', () {
      final root = probeTree('direct', {
        'offender.dart': 'final e = FakeLlmEngine();\n',
      });

      expect(scan(root: root, exempt: '')['$root/offender.dart'], [1]);
    });

    // **R2-F1 Evidence A.** A *second* fake-binding file inside the exemption,
    // consumed from outside it. The old scan missed this because the boundary named
    // one filename; the computed boundary finds it because pass 1 discovers the file
    // rather than being told about it.
    test('it reports a consumer of any fake-bearing exempt file', () {
      final root = probeTree('evidence_a', {
        'engines/demo_seam.dart':
            "import 'fakes/fake_llm_engine.dart';\n"
            'final demoEngineProvider = Provider((ref) => FakeLlmEngine());\n',
        'main.dart':
            "import 'engines/demo_seam.dart';\n"
            'void main() {}\n',
      });

      final found = scan(root: root, exempt: '$root/engines/');

      expect(
        found['$root/main.dart'],
        [1],
        reason: 'the consumer is the offender; the seam file is exempt',
      );
      expect(
        found.containsKey('$root/engines/demo_seam.dart'),
        isFalse,
        reason: 'binding a fake inside the exemption is legitimate',
      );
    });

    // **R2-F1 Evidence B.** `export` rather than `import`.
    test('it reports an export barrel, not just an import', () {
      final root = probeTree('evidence_b', {
        'engines/providers.dart': 'final p = FakeLlmEngine();\n',
        'services/seam.dart': "export '../engines/providers.dart';\n",
        'main.dart': "import 'services/seam.dart';\n",
      });

      final found = scan(root: root, exempt: '$root/engines/');

      expect(
        found['$root/services/seam.dart'],
        [1],
        reason:
            'the barrel re-exports a fake-bearing file, so it is an offender',
      );
      // And the transitivity argument: `main.dart` need not be flagged, because the
      // barrel it goes through already is. A chain cannot launder the reference.
      expect(found, isNotEmpty);
    });

    // The `package:` form of the same reference, which a refactor to absolute
    // imports would produce.
    test('it resolves this package\'s own package: imports', () {
      final root = probeTree('package_form', {
        'engines/providers.dart': 'final p = FakeLlmEngine();\n',
        'main.dart':
            "import 'package:field_ops_copilot/engines/providers.dart';\n",
      });

      expect(scan(root: root, exempt: '$root/engines/')['$root/main.dart'], [
        1,
      ]);
    });

    // R2-F3: the comment skip is `startsWith`, not `contains`. Under `contains` any
    // code line with a trailing comment would be invisible — and the clean-probe
    // case below cannot tell the two apart, because it uses a `///` line.
    test('a trailing comment does not hide a live line', () {
      final root = probeTree('trailing', {
        'offender.dart': 'final e = FakeLlmEngine(); // bind the fake\n',
      });

      expect(scan(root: root, exempt: '')['$root/offender.dart'], [1]);
    });

    // And a clean tree must come back empty, or every case above would pass on a
    // detector that reported everything.
    test('it reports nothing for a clean file', () {
      final root = probeTree('clean', {
        'clean.dart':
            "import 'package:flutter/material.dart';\n"
            '/// Mentions FakeLlmEngine only in a doc comment.\n'
            '// And in a line comment.\n'
            'void main() {}\n',
      });

      expect(scan(root: root, exempt: ''), isEmpty);
    });

    // A non-fake-bearing file inside the exemption may be imported freely — the
    // real graph does exactly this for `llm_engine.dart` and `gemma_llm_engine.dart`.
    test('importing an exempt file that bears no fake is not an offence', () {
      final root = probeTree('innocent', {
        'engines/llm_engine.dart': 'abstract class LlmEngine {}\n',
        'main.dart': "import 'engines/llm_engine.dart';\n",
      });

      expect(scan(root: root, exempt: '$root/engines/'), isEmpty);
    });
  });

  group('the scan covers what it claims to', () {
    // R1-F3's root cause was coverage: the file that mattered was not in the scanned
    // set. Asserted directly, so narrowing it is a visible edit.
    test('the scanned set includes main.dart and app.dart', () {
      final scanned = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .map((f) => f.path.replaceAll(r'\', '/'))
          .where((path) => path.endsWith('.dart'))
          .where((path) => !path.startsWith(exemptPrefix))
          .toSet();

      expect(scanned, contains('lib/main.dart'));
      expect(scanned, contains('lib/app.dart'));
      expect(scanned, contains('lib/services/inference/providers.dart'));
      expect(scanned, contains('lib/viewmodels/field_job_viewmodel.dart'));
      expect(scanned, contains('lib/views/diagnose_screen.dart'));
    });

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

    // Pass 1 must actually find something in the real tree, or pass 2 has an empty
    // set to compare against and the whole guard is vacuous. This is the assertion
    // that would have caught a pass-1 regression before R2-F1's shape reopened.
    test('pass 1 finds the real fake-bearing files', () {
      // Re-derived rather than asserted from a list, so adding a fake does not
      // require editing this test — only that at least the seam is found.
      final fakeBearing = Directory(exemptPrefix)
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .where(
            (f) => f.readAsLinesSync().any(
              (l) => !l.trimLeft().startsWith('//') && namesAFake(l),
            ),
          )
          .map((f) => f.path.replaceAll(r'\', '/'))
          .toSet();

      expect(
        fakeBearing,
        contains('lib/engines/providers.dart'),
        reason: 'the Tier 0 seam binds the fake, so it must be discovered',
      );
      expect(
        fakeBearing,
        contains('lib/engines/fakes/fake_llm_engine.dart'),
        reason: 'the fake itself must be discovered',
      );
    });
  });
}
