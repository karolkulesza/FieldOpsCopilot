import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
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

  /// Every URI a directive can reach, and the line it starts on — **from the Dart
  /// parser, not a regular expression.**
  ///
  /// **This is the fifth version of this logic, and the first that is not an
  /// enumeration.** The previous four were regexes, and each review round found the
  /// case adjacent to the one just fixed:
  ///
  /// | round | what got through |
  /// |---|---|
  /// | R2-F1 | a wrapper, and an `export` barrel (`startsWith('import ')`) |
  /// | R3-F1 | a conditional import — only the first URI was read |
  /// | R4 addendum | a directive `dart format` had wrapped across lines |
  /// | R4-F1/F2/F3 | a `;` or an apostrophe **inside a comment**; adjacent-string URI concatenation; `import'x';` with no space |
  ///
  /// The last row is the one that settles the design. Joining lines until a `;` and
  /// pairing quotes across the result cannot work, because neither step knows what a
  /// comment is: `// no dart:io on web; the device takes the branch below` ends the
  /// join early, and `// don't reach for the stub` derails the quote pairing. Both
  /// were demonstrated in the real `lib/main.dart`, both `dart format`-stable, both
  /// binding `agentEngineProvider` to the fake with the whole suite green — and the
  /// matched controls (`;`→`,`, `don't`→`do not`) were caught. **One character in a
  /// comment flipped the guard.**
  ///
  /// A parser knows what a comment is, what an adjacent-string literal is, and where
  /// a directive ends. `uri.stringValue` also folds `'package:…/engines/'
  /// 'providers.dart'` into one URI, which R4-F2 showed the extraction never could.
  /// This is the same move R2-F1's fix made one level up: compute the answer rather
  /// than enumerate the ways of getting it wrong.
  Iterable<(int, String)> directiveUris(String source) sync* {
    final unit = parseString(content: source, throwIfDiagnostics: false).unit;
    for (final directive in unit.directives) {
      final line = unit.lineInfo.getLocation(directive.offset).lineNumber;
      if (directive is NamespaceDirective) {
        // `import` and `export`, including every `if (…)` configuration — which is
        // where R3-F1's fake-bearing URI hid.
        final uri = directive.uri.stringValue;
        if (uri != null) yield (line, uri);
        for (final configuration in directive.configurations) {
          final conditional = configuration.uri.stringValue;
          if (conditional != null) yield (line, conditional);
        }
      } else if (directive is PartDirective) {
        final uri = directive.uri.stringValue;
        if (uri != null) yield (line, uri);
      }
    }
  }

  /// [uri] as a path under [root], or `null` when it is someone else's code.
  String? resolveUri({
    required String uri,
    required String fromFile,
    required String root,
  }) {
    // This package's own `package:` form addresses the scan root — `lib/` for the
    // real tree. Resolved against [root] rather than a hard-coded `lib/` so a probe
    // tree can exercise this branch at all; the first version hard-coded it and the
    // probe silently tested nothing (R2-F3). Normalised like the relative branch,
    // which it was not in R3-F1.
    const self = 'package:field_ops_copilot/';
    if (uri.startsWith(self)) {
      return p
          .normalize('$root/${uri.substring(self.length)}')
          .replaceAll(r'\', '/');
    }
    if (uri.startsWith('dart:') || uri.startsWith('package:')) return null;
    return p.normalize(p.join(p.dirname(fromFile), uri)).replaceAll(r'\', '/');
  }

  /// Offenders under [root], as `path -> [line numbers]`.
  ///
  /// Takes its root and exemption as parameters so the positive path is testable: a
  /// detector that has only ever returned empty is not a detector (R1-F2).
  Map<String, List<int>> scan({required String root, required String exempt}) {
    final sources = <String, String>{};
    for (final entity in Directory(root).listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      sources[entity.path.replaceAll(r'\', '/')] = entity.readAsStringSync();
    }

    bool isExempt(String path) => exempt.isNotEmpty && path.startsWith(exempt);

    /// Lines of [path] that are code, for the names-a-fake check. Still a string
    /// scan, because naming a fake is a lexical property and a comment mentioning
    /// the class by name is legitimate — this file is full of them.
    Iterable<String> codeLines(String path) => sources[path]!
        .split('\n')
        .map((line) => line.trimLeft())
        .where((line) => !isComment(line));

    Iterable<String> reachedBy(String path) => directiveUris(sources[path]!)
        .map((d) => resolveUri(uri: d.$2, fromFile: path, root: root))
        .whereType<String>();

    // **Pass 1 — the exempt files that bear a fake, to closure.**
    //
    // A *fixed point*, not a single sweep (R3-F1): an exempt file that merely
    // *reaches* a fake was invisible to both passes, because pass 2 skips it for
    // being exempt and a one-sweep pass 1 only looked for a direct mention. Closure
    // is what makes pass 2's non-transitivity sound — every path out of the
    // exemption now terminates at a pass-1 member. Eleven files, so the cost is nil.
    final fakeBearing = <String>{
      for (final path in sources.keys)
        if (isExempt(path) && codeLines(path).any(namesAFake)) path,
    };
    for (var changed = true; changed;) {
      changed = false;
      for (final path in sources.keys) {
        if (!isExempt(path) || fakeBearing.contains(path)) continue;
        if (reachedBy(path).any(fakeBearing.contains)) {
          fakeBearing.add(path);
          changed = true;
        }
      }
    }

    // **Pass 2 — who names a fake, or reaches one of pass 1's files.**
    final offenders = <String, List<int>>{};
    void report(String path, int line) {
      final at = offenders.putIfAbsent(path, () => []);
      if (!at.contains(line)) at.add(line);
    }

    for (final path in sources.keys) {
      if (isExempt(path)) continue;
      // Naming a fake is a per-line property.
      final lines = sources[path]!.split('\n');
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i].trimLeft();
        if (!isComment(line) && namesAFake(line)) report(path, i + 1);
      }
      // Reaching one is a per-*directive* property, reported at the directive's
      // own line, which the parser supplies rather than the scan guessing.
      for (final (line, uri) in directiveUris(sources[path]!)) {
        final target = resolveUri(uri: uri, fromFile: path, root: root);
        if (target != null && fakeBearing.contains(target)) report(path, line);
      }
      offenders[path]?.sort();
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

    // **The four shapes that defeated the regex, and the reason this uses a
    // parser.** Every one of these is valid Dart, `dart format`-stable, and was
    // demonstrated in the real `lib/main.dart` binding `agentEngineProvider` to the
    // fake with the whole suite green (review round 4: R4-F1, R4-F2, R4-F3). Three
    // of the four turn on a single character — inside a *comment*.
    //
    // They are grouped deliberately: no one of them is interesting on its own, and
    // together they are the argument for `package:analyzer`. Any of them can be
    // reintroduced by going back to string matching, which is exactly the mistake
    // this table exists to make expensive.
    for (final shape in const [
      (
        'a `;` inside a trailing comment on the head line',
        "import 'stub.dart' // no dart:io on web; the device takes it below\n"
            "    if (dart.library.io) 'engines/providers.dart';\n",
      ),
      (
        'an apostrophe inside an interleaved comment',
        "import 'stub.dart'\n"
            "    // don't reach for the stub\n"
            "    if (dart.library.io) 'engines/providers.dart';\n",
      ),
      (
        'adjacent-string URI concatenation',
        "import 'engines/' 'providers.dart';\n",
      ),
      ('no whitespace after the keyword', "import'engines/providers.dart';\n"),
    ]) {
      test('it reads ${shape.$1}', () {
        final root = probeTree('shape_${shape.$1.hashCode}', {
          'engines/providers.dart': 'final p = FakeLlmEngine();\n',
          'stub.dart': 'const stub = 0;\n',
          'main.dart': shape.$2,
        });

        expect(
          scan(root: root, exempt: '$root/engines/')['$root/main.dart'],
          [1],
          reason: shape.$1,
        );
      });
    }

    // **The matched controls the review ran**, kept because they are what make the
    // three comment cases evidence rather than anecdote: with the one character
    // changed, the *old* regex caught them. If a future version passes the four
    // above by accident, these still have to pass too.
    for (final control in const [
      (
        'a `,` instead of a `;` in the comment',
        'no dart:io on web, the device',
      ),
      ('"do not" instead of "don\'t"', 'do not reach for the stub'),
    ]) {
      test('control: ${control.$1}', () {
        final root = probeTree('control_${control.$1.hashCode}', {
          'engines/providers.dart': 'final p = FakeLlmEngine();\n',
          'stub.dart': 'const stub = 0;\n',
          'main.dart':
              "import 'stub.dart' // ${control.$2}\n"
              "    if (dart.library.io) 'engines/providers.dart';\n",
        });

        expect(scan(root: root, exempt: '$root/engines/')['$root/main.dart'], [
          1,
        ]);
      });
    }

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
