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

  /// Comments are where the *reason* for this rule is written down, so they must be
  /// able to name the class. Only code counts — and this is `startsWith`, not
  /// `contains`, so a trailing `// …` cannot hide a live line (R2-F3).
  bool isComment(String line) => line.startsWith('//');

  /// A code line that names a fake engine directly.
  bool namesAFake(String line) =>
      line.contains('FakeLlmEngine') || line.contains('engines/fakes/');

  /// Every file an `import` / `export` / `part` directive on [line] can reach.
  ///
  /// **A list, not one URI, because a conditional import carries several** — review
  /// finding R3-F1: `import 'stub.dart' if (dart.library.io) '…/providers.dart';`
  /// has two, and the earlier version captured only the first. That is the worst
  /// possible direction to miss in, because `dart.library.io` is the branch taken on
  /// iOS and Android — the miss would be on the device and the hit on a platform
  /// this app does not ship to.
  ///
  /// `export` is here because omitting it was R2-F1's Evidence B: a one-line barrel
  /// re-exporting the seam defeated a check that only looked for `import `.
  final directiveStart = RegExp(r'^(?:import|export|part)\s');
  final quotedUri = RegExp('''['"]([^'"]+)['"]''');

  /// Every directive in [lines] as `(startIndex, wholeText)`, with continuation
  /// lines joined.
  ///
  /// **Line-based matching is not enough, and this is review round 4's finding.**
  /// A directive can wrap, and the fake-bearing URI then sits on a continuation
  /// line that does not start with `import`:
  ///
  /// ```dart
  /// import 'seam_stub.dart'
  ///     if (dart.library.io) 'package:field_ops_copilot/engines/providers.dart';
  /// ```
  ///
  /// The first line yields only the stub; the second is not a directive start, so a
  /// per-line scan never sees the second URI at all. That is not a contrived
  /// evasion — **`dart format` produces exactly this wrap**, and reports the file
  /// above as already formatted, so it is what the toolchain does to any conditional
  /// import with a long `package:` URI. Combined with `dart.library.io` being the
  /// branch taken on iOS and Android, the miss was again on the device.
  Iterable<(int, String)> directivesIn(List<String> lines) sync* {
    for (var i = 0; i < lines.length; i++) {
      final head = lines[i].trimLeft();
      if (isComment(head) || !directiveStart.hasMatch(head)) continue;
      final buffer = StringBuffer(head);
      var j = i;
      // Directives end at the first `;`. Bounded by the file, so a malformed
      // source cannot spin.
      while (!buffer.toString().contains(';') && j + 1 < lines.length) {
        j++;
        buffer
          ..write(' ')
          ..write(lines[j].trimLeft());
      }
      yield (i, buffer.toString());
    }
  }

  Iterable<String> directiveTargets({
    required String line,
    required String fromFile,
    required String root,
  }) {
    if (!directiveStart.hasMatch(line)) return const [];
    return quotedUri
        .allMatches(line)
        .map((match) => match.group(1)!)
        .map((uri) {
          // This package's own `package:` form addresses the scan root — `lib/` for
          // the real tree. Resolved against [root] rather than a hard-coded `lib/`
          // so a probe tree can exercise this branch at all; the first version
          // hard-coded it and the probe silently tested nothing (R2-F3).
          const self = 'package:field_ops_copilot/';
          if (uri.startsWith(self)) {
            // Normalised like the relative branch. Not normalising it was the third
            // gap in R3-F1: `package:…/./engines/providers.dart` resolved to a path
            // with the `./` still in it and missed the set.
            return p.normalize('$root/${uri.substring(self.length)}');
          }
          // Anything else absolute is someone else's code.
          if (uri.startsWith('dart:') || uri.startsWith('package:')) {
            return null;
          }
          return p.normalize(p.join(p.dirname(fromFile), uri));
        })
        .whereType<String>()
        .map((path) => path.replaceAll(r'\', '/'));
  }

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

    /// Code lines of [path], comments dropped.
    Iterable<String> codeLines(String path) =>
        lines[path]!.map((l) => l.trimLeft()).where((l) => !isComment(l));

    // **Pass 1 — the exempt files that bear a fake, to closure.**
    //
    // A *fixed point*, not a single sweep, and that is review finding R3-F1. The
    // single-sweep version asked only "does this exempt file name a fake", which
    // left an exempt file that *reaches* one invisible to both passes: pass 2 skips
    // it for being exempt, and pass 1 declined to flag it for not naming a fake. So
    // a two-line wrapper inside `lib/engines/` — `import 'providers.dart'; final
    // demoEngineProvider = llmEngineProvider;` — laundered the reference, and
    // everything downstream inherited the blind spot. My non-transitivity argument
    // assumed the laundering file was non-exempt; it need not be.
    //
    // Iterating to closure is what makes that argument true rather than nearly
    // true: every path out of the exemption now terminates at a pass-1 file. The
    // exemption is eleven files, so the cost is nil.
    final fakeBearing = <String>{
      for (final path in lines.keys)
        if (isExempt(path) && codeLines(path).any(namesAFake)) path,
    };
    for (var changed = true; changed;) {
      changed = false;
      for (final path in lines.keys) {
        if (!isExempt(path) || fakeBearing.contains(path)) continue;
        final reachesOne = directivesIn(lines[path]!).any(
          (directive) => directiveTargets(
            line: directive.$2,
            fromFile: path,
            root: root,
          ).any(fakeBearing.contains),
        );
        if (reachesOne) {
          fakeBearing.add(path);
          changed = true;
        }
      }
    }

    // **Pass 2 — who names a fake, or reaches one of pass 1's files.**
    //
    // Non-transitive *outside* the exemption, and that is sound now that pass 1 is
    // closed: any chain from production code into the exemption must cross the
    // boundary at some non-exempt file, and that file's directive resolves to a
    // pass-1 member. A barrel does not launder the reference, it becomes the
    // offender.
    final offenders = <String, List<int>>{};
    for (final entry in lines.entries) {
      if (isExempt(entry.key)) continue;
      // Naming a fake is a per-line property.
      for (var i = 0; i < entry.value.length; i++) {
        final line = entry.value[i].trimLeft();
        if (isComment(line) || !namesAFake(line)) continue;
        offenders.putIfAbsent(entry.key, () => []).add(i + 1);
      }
      // Reaching one is a per-*directive* property, because a directive can wrap.
      // Reported at the line the directive starts on.
      for (final directive in directivesIn(entry.value)) {
        final reachesOne = directiveTargets(
          line: directive.$2,
          fromFile: entry.key,
          root: root,
        ).any(fakeBearing.contains);
        if (reachesOne) {
          final at = directive.$1 + 1;
          final found = offenders.putIfAbsent(entry.key, () => []);
          if (!found.contains(at)) found.add(at);
        }
      }
      offenders[entry.key]?.sort();
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

    // **R3-F1's wrapper — the shape that broke the transitivity argument.** An
    // exempt file that *reaches* a fake without naming one. Pass 2 skips it for being
    // exempt; the single-sweep pass 1 declined to flag it for not naming a fake, so
    // the reference was laundered and the consumer was invisible.
    test(
      'it reports a consumer of an exempt file that only reaches a fake',
      () {
        final root = probeTree('wrapper', {
          'engines/providers.dart':
              'final llmEngineProvider = Provider((ref) => FakeLlmEngine());\n',
          'engines/demo_seam.dart':
              "import 'providers.dart';\n"
              'final demoEngineProvider = llmEngineProvider;\n',
          'main.dart': "import 'engines/demo_seam.dart';\n",
        });

        final found = scan(root: root, exempt: '$root/engines/');

        expect(
          found['$root/main.dart'],
          [1],
          reason:
              'the wrapper names no fake, so only a closed pass 1 catches this',
        );
      },
    );

    // The closure has to iterate, not just look one hop. Two wrappers in a chain.
    test('pass 1 closes over a chain of exempt wrappers', () {
      final root = probeTree('chain', {
        'engines/providers.dart': 'final p = FakeLlmEngine();\n',
        'engines/hop1.dart': "export 'providers.dart';\n",
        'engines/hop2.dart': "export 'hop1.dart';\n",
        'main.dart': "import 'engines/hop2.dart';\n",
      });

      expect(
        scan(root: root, exempt: '$root/engines/')['$root/main.dart'],
        [1],
        reason:
            'two hops inside the exemption, so a single sweep is not enough',
      );
    });

    // **R3-F1's conditional import.** The regex captured only the first URI, and
    // `dart.library.io` is the branch taken on iOS and Android — so the miss was on
    // the device and the hit on a platform this app does not ship to.
    test('it reads every URI of a conditional import', () {
      final root = probeTree('conditional', {
        'engines/providers.dart': 'final p = FakeLlmEngine();\n',
        'stub.dart': 'const stub = 0;\n',
        'main.dart':
            "import 'stub.dart'"
            " if (dart.library.io) 'engines/providers.dart';\n",
      });

      expect(
        scan(root: root, exempt: '$root/engines/')['$root/main.dart'],
        [1],
        reason: 'the fake-bearing URI is the second one on the line',
      );
    });

    // **The wrapped directive — round 4's finding, and the one that matters most of
    // these because the *formatter* produces it.** A conditional import with a long
    // `package:` URI does not fit on one line, so `dart format` wraps it; the
    // fake-bearing URI then sits on a continuation line that does not start with
    // `import`, and a per-line scan never sees it. Verified against the real
    // `lib/main.dart`, where `dart format` reported the wrapped file as *already
    // formatted*.
    test('it reads a directive that wraps across lines', () {
      final root = probeTree('wrapped', {
        'engines/providers.dart': 'final p = FakeLlmEngine();\n',
        'seam_stub.dart': 'const stub = 0;\n',
        // Exactly the shape `dart format` emits.
        'main.dart':
            "import 'seam_stub.dart'\n"
            "    if (dart.library.io) "
            "'package:field_ops_copilot/engines/providers.dart';\n",
      });

      expect(
        scan(root: root, exempt: '$root/engines/')['$root/main.dart'],
        [1],
        reason:
            'reported at the line the directive starts on, not the '
            'continuation line that happens to carry the URI',
      );
    });

    // The same wrap one level in: a *pass 1* file whose own directive wraps. If the
    // closure read lines rather than directives, the chain would break here instead.
    test('a wrapped directive inside the exemption still feeds pass 1', () {
      final root = probeTree('wrapped_exempt', {
        'engines/providers.dart': 'final p = FakeLlmEngine();\n',
        'engines/stub.dart': 'const stub = 0;\n',
        'engines/seam.dart':
            "export 'stub.dart'\n"
            "    if (dart.library.io) 'providers.dart';\n",
        'main.dart': "import 'engines/seam.dart';\n",
      });

      expect(scan(root: root, exempt: '$root/engines/')['$root/main.dart'], [
        1,
      ]);
    });

    // **R3-F1's normalisation gap.** Relative URIs were normalised and `package:`
    // ones were not, so a `./` in the middle slipped past the set membership check.
    test('it normalises this package\'s package: URIs too', () {
      final root = probeTree('normalise', {
        'engines/providers.dart': 'final p = FakeLlmEngine();\n',
        'main.dart':
            "import 'package:field_ops_copilot/./engines/providers.dart';\n",
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
