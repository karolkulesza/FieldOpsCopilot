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
  /// The subtree production may not reach into, except for [openFiles].
  const exemptPrefix = 'lib/engines/';

  /// **The only files inside the exemption production is allowed to reach**, each
  /// with the reason it is allowed.
  ///
  /// This is the fix for review finding **R5-F1**, and it inverts the seed the same
  /// way R2-F1 inverted the scanned set. Pass 1 used to ask *"does this exempt file
  /// name a fake?"* — two string literals matched against line text. That found **2
  /// of the 11 files** in `lib/engines/`, missed three of the four fakes outright,
  /// and worked at all only because the seam happens to contain the literal
  /// `FakeLlmEngine`. A fifth fake under any other name — the reviewer used
  /// `ScriptedLlmEngine` — was invisible, and a `main.dart` binding it into
  /// `agentEngineProvider` passed the whole suite with a scripted engine answering
  /// every inquiry.
  ///
  /// So the question is no longer "which of these is a fake" (an open set, guessed
  /// by name) but **"which of these may production touch"** (a closed set, three
  /// files, each justified). Everything else under `lib/engines/` is off-limits
  /// whether or not it names a fake, whether or not it is a fake at all.
  ///
  /// **It fails closed, which is the whole point.** Add a file to `lib/engines/` and
  /// it is restricted by default: a new fake is covered automatically, and a new
  /// *interface* produces a test failure telling you to justify it here. The old
  /// seed failed open — forget the naming convention and the guard went quiet.
  const openFiles = {
    // The `LlmEngine` interface itself. Eleven production files import it; it
    // declares no implementation.
    'lib/engines/llm_engine.dart',
    // `ToolDefinition` / `objectSchema`, which the registry and the tools need.
    'lib/engines/tool_schema.dart',
    // The device engine — the one implementation production is *supposed* to reach.
    'lib/engines/impl/gemma_llm_engine.dart',
  };

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
  /// The narrowing is [UriBasedDirective], **not a list of the two subtypes that
  /// happen to implement it today.** Raised as a non-blocking review note after
  /// round 5, and taken because it is the same mistake as R5-F1 one level down:
  /// `is NamespaceDirective || is PartDirective` is exhaustive by *inspection of one
  /// package version*, so a future `UriBasedDirective` subtype would be skipped in
  /// silence — this file's signature failure. Asking the supertype is closed by
  /// construction. Checked against `analyzer-12.1.0`'s own hierarchy rather than
  /// assumed: `NamespaceDirectiveImpl` and `PartDirectiveImpl` both extend
  /// `UriBasedDirectiveImpl`, and `PartOfDirectiveImpl` extends `DirectiveImpl`
  /// directly — so this covers exactly what the enumeration did, and keeps covering
  /// whatever is added.
  Iterable<(int, String)> directiveUris(String source) sync* {
    final unit = parseString(content: source, throwIfDiagnostics: false).unit;
    for (final directive in unit.directives) {
      if (directive is! UriBasedDirective) continue;
      final line = unit.lineInfo.getLocation(directive.offset).lineNumber;
      final uri = directive.uri.stringValue;
      if (uri != null) yield (line, uri);
      // Every `if (…)` configuration too — which is where R3-F1's fake-bearing URI
      // hid. Only `import`/`export` can carry them, so the narrowing stays here.
      if (directive is NamespaceDirective) {
        for (final configuration in directive.configurations) {
          final conditional = configuration.uri.stringValue;
          if (conditional != null) yield (line, conditional);
        }
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
  Map<String, List<int>> scan({
    required String root,
    required String exempt,
    Set<String> open = const {},
  }) {
    final sources = <String, String>{};
    for (final entity in Directory(root).listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      sources[entity.path.replaceAll(r'\', '/')] = entity.readAsStringSync();
    }

    bool isExempt(String path) => exempt.isNotEmpty && path.startsWith(exempt);

    Iterable<String> reachedBy(String path) => directiveUris(sources[path]!)
        .map((d) => resolveUri(uri: d.$2, fromFile: path, root: root))
        .whereType<String>();

    // **Pass 1 — what inside the exemption production may not reach.**
    //
    // Everything under the exemption except [open], rather than "whatever names a
    // fake" (R5-F1). Closed by construction and failing closed: a new file is
    // restricted until someone justifies it.
    final restricted = <String>{
      for (final path in sources.keys)
        if (isExempt(path) && !open.contains(path)) path,
    };

    // The closure R3-F1 bought, applied to what remains: an *open* file that reaches
    // a restricted one is itself restricted, so the three exceptions cannot be used
    // as a doorway. Iterated, because an open file could reach another open file
    // that later becomes restricted.
    for (var changed = true; changed;) {
      changed = false;
      for (final path in sources.keys) {
        if (!isExempt(path) || restricted.contains(path)) continue;
        if (reachedBy(path).any(restricted.contains)) {
          restricted.add(path);
          changed = true;
        }
      }
    }

    // **Pass 2 — who names a fake, or reaches something restricted.**
    final offenders = <String, List<int>>{};
    void report(String path, int line) {
      final at = offenders.putIfAbsent(path, () => []);
      if (!at.contains(line)) at.add(line);
    }

    for (final path in sources.keys) {
      if (isExempt(path)) continue;
      final lines = sources[path]!.split('\n');
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i].trimLeft();
        if (!isComment(line) && namesAFake(line)) report(path, i + 1);
      }
      for (final (line, uri) in directiveUris(sources[path]!)) {
        final target = resolveUri(uri: uri, fromFile: path, root: root);
        if (target != null && restricted.contains(target)) report(path, line);
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
      scan(root: 'lib', exempt: exemptPrefix, open: openFiles),
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
        // The fake has to *exist* for the closure to have a restricted file to
        // reach. Under the old name-based seed it did not — `demo_seam.dart` was
        // seeded by containing the word — so this probe passed without the target
        // being present. Inverting the seed to location made that latent
        // incompleteness in the fixture visible, which is a better outcome than the
        // seed staying name-based.
        'engines/fakes/fake_llm_engine.dart': 'class FakeLlmEngine {}\n',
        'engines/demo_seam.dart':
            "import 'fakes/fake_llm_engine.dart';\n"
            'final demoEngineProvider = Provider((ref) => FakeLlmEngine());\n',
        'main.dart':
            "import 'engines/demo_seam.dart';\n"
            'void main() {}\n',
      });

      // `demo_seam.dart` declared **open**, so only the closure can flag it.
      final found = scan(
        root: root,
        exempt: '$root/engines/',
        open: {'$root/engines/demo_seam.dart'},
      );

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

      // `seam.dart` open, so the wrapped directive *inside* it is what has to be
      // read for the closure to fire at all.
      expect(
        scan(
          root: root,
          exempt: '$root/engines/',
          open: {'$root/engines/seam.dart', '$root/engines/stub.dart'},
        )['$root/main.dart'],
        [1],
      );
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

      // Both hops declared **open**, so the location seed does not flag them and
      // only an *iterating* closure reaches `providers.dart` and drags them back
      // in. Without this the test flags by location and says nothing about the
      // closure — which is what it did for one commit after the seed was inverted,
      // caught by disabling the closure and finding this test still green.
      expect(
        scan(
          root: root,
          exempt: '$root/engines/',
          open: {'$root/engines/hop1.dart', '$root/engines/hop2.dart'},
        )['$root/main.dart'],
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
    test('importing an OPEN exempt file is not an offence', () {
      final root = probeTree('innocent', {
        'engines/llm_engine.dart': 'abstract class LlmEngine {}\n',
        'main.dart': "import 'engines/llm_engine.dart';\n",
      });

      expect(
        scan(
          root: root,
          exempt: '$root/engines/',
          open: {'$root/engines/llm_engine.dart'},
        ),
        isEmpty,
        reason: 'the interface is what production is supposed to import',
      );
    });

    // …and the same file, *not* declared open, is off-limits. This is R5-F1's
    // inversion in one pair: membership of the open set is the whole question, and
    // nothing about the file's name or contents enters into it.
    test('the same import IS an offence when the file is not open', () {
      final root = probeTree('not_open', {
        'engines/llm_engine.dart': 'abstract class LlmEngine {}\n',
        'main.dart': "import 'engines/llm_engine.dart';\n",
      });

      expect(scan(root: root, exempt: '$root/engines/')['$root/main.dart'], [
        1,
      ]);
    });
  });

  group('R5-F1: the seed is a closed set, and it fails closed', () {
    // The reviewer's shape: a fifth engine that never contains the word the old
    // seed looked for, outside `fakes/`, bound into `agentEngineProvider` from
    // `main.dart`. Under the name-matching seed this passed the entire suite with a
    // scripted engine answering every technician inquiry.
    test('a fake under a novel name, outside fakes/, is still restricted', () {
      final root = probeTree('novel_name', {
        'engines/llm_engine.dart': 'abstract class LlmEngine {}\n',
        'engines/scripted_engine.dart':
            "import 'llm_engine.dart';\n"
            'class ScriptedLlmEngine implements LlmEngine {}\n',
        'main.dart': "import 'engines/scripted_engine.dart';\n",
      });

      expect(
        scan(
          root: root,
          exempt: '$root/engines/',
          open: {'$root/engines/llm_engine.dart'},
        )['$root/main.dart'],
        [1],
        reason:
            'nothing here spells "Fake"; membership of the open set is what '
            'decides, not the name',
      );
    });

    // **Fails closed.** A new file in the exemption is restricted before anyone has
    // looked at it, so forgetting to classify one makes the guard *stricter*. The
    // old seed failed open: forget the naming convention and it went quiet.
    test('a brand-new exempt file is restricted by default', () {
      final root = probeTree('newcomer', {
        'engines/llm_engine.dart': 'abstract class LlmEngine {}\n',
        'engines/newcomer.dart': 'const somethingHarmless = 0;\n',
        'main.dart': "import 'engines/newcomer.dart';\n",
      });

      expect(
        scan(
          root: root,
          exempt: '$root/engines/',
          open: {'$root/engines/llm_engine.dart'},
        )['$root/main.dart'],
        [1],
        reason: 'nothing suspicious in the file at all — that is the point',
      );
    });

    // The open set is a doorway only for itself: an open file that reaches a
    // restricted one becomes restricted, which is R3-F1's closure surviving the
    // seed's inversion.
    test('an open file that reaches a restricted one loses its exemption', () {
      final root = probeTree('open_doorway', {
        'engines/secret.dart': 'class ScriptedLlmEngine {}\n',
        'engines/llm_engine.dart':
            "export 'secret.dart';\n"
            'abstract class LlmEngine {}\n',
        'main.dart': "import 'engines/llm_engine.dart';\n",
      });

      expect(
        scan(
          root: root,
          exempt: '$root/engines/',
          open: {'$root/engines/llm_engine.dart'},
        )['$root/main.dart'],
        [1],
        reason: 'declaring a file open cannot launder what it re-exports',
      );
    });

    // The real tree's classification, asserted rather than assumed — the old seed
    // found 2 of 11 and missed three of the four fakes, and nothing said so.
    test('every fake in the real tree is restricted', () {
      final fakes = Directory('lib/engines/fakes')
          .listSync()
          .whereType<File>()
          .map((f) => f.path.replaceAll(r'\', '/'))
          .where((path) => path.endsWith('.dart'))
          .toList();

      expect(fakes, hasLength(4), reason: 'four fakes ship today');
      for (final fake in fakes) {
        expect(openFiles, isNot(contains(fake)), reason: fake);
      }
      expect(openFiles, isNot(contains('lib/engines/providers.dart')));
    });

    // The open set is three files and growing it must be a deliberate, visible
    // edit — each entry carries its justification in the constant's doc.
    test('the open set is exactly the three production needs', () {
      expect(openFiles, {
        'lib/engines/llm_engine.dart',
        'lib/engines/tool_schema.dart',
        'lib/engines/impl/gemma_llm_engine.dart',
      });
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

    // **`throwIfDiagnostics: false` fails open, and nothing used to notice.** Raised
    // as a non-blocking review note after round 5 and taken, because the failure mode
    // it describes is the one this file specialises in: a file the parser cannot read
    // yields whatever `unit.directives` survived recovery, and the scan reports it
    // clean — silently, with the suite green.
    //
    // It is not reachable today (syntax garbage still recovers directives, and
    // `flutter analyze` gates malformed source anyway), which is why it was a note
    // and not a finding. But `analyzer` is pinned `^12.1.0` against an SDK constraint
    // of `^3.12.2` and those move independently: a language feature the bundled front
    // end accepts and analyzer 12 does not would degrade this guard to silence. This
    // converts that degradation into a failing test.
    //
    // Kept as a separate assertion rather than a throw inside [directiveUris],
    // deliberately — the probe trees deliberately feed it malformed source (P2/P2b
    // are *about* recovery), so the parse must stay tolerant. What must not be
    // tolerant is the parse of the **real tree**, which is what this asserts.
    test('the parser reads every real production file without recovering', () {
      final unreadable = <String, List<String>>{};
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final result = parseString(
          content: entity.readAsStringSync(),
          throwIfDiagnostics: false,
        );
        if (result.errors.isNotEmpty) {
          unreadable[entity.path.replaceAll(r'\', '/')] = result.errors
              .map((e) => e.message)
              .toList();
        }
      }

      expect(
        unreadable,
        isEmpty,
        reason:
            'a file the parser cannot read is scanned from a recovered AST, so its '
            'directives are whatever survived — the guard would pass in silence',
      );
    });
  });
}
