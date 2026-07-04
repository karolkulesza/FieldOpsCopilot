import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_test/flutter_test.dart';

/// Collects every provider-override site: `overrideWith…(…)` calls and any
/// `overrides:` argument (which is how `ProviderScope` takes them).
///
/// The other half of **R6-F1**. These names are Riverpod's API, not this project's
/// convention — which is what makes the set closed. A fake cannot reach the running
/// app without one of them, whatever it is called and wherever it lives.
class _OverrideCollector extends RecursiveAstVisitor<void> {
  final sites = <(int offset, String what)>[];

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final name = node.methodName.name;
    if (name.startsWith('overrideWith')) sites.add((node.offset, '$name(…)'));
    super.visitMethodInvocation(node);
  }

  @override
  void visitNamedExpression(NamedExpression node) {
    if (node.name.label.name == 'overrides') {
      sites.add((node.offset, 'overrides: …'));
    }
    super.visitNamedExpression(node);
  }
}

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

      // No `open:` set, and no comment claiming one. R6-F3: this case used to pass
      // `open: {seam.dart, stub.dart}` — two files this probe tree does not contain —
      // under a comment describing a wrapped directive that is not here either. Both
      // were copied from the wrapped-directive case below. Deleting the argument left
      // the file green, which is what makes it worth recording: an inert argument
      // reads as coverage. What this case actually tests is the `package:` branch of
      // [resolveUri], and that is all it now claims.
      expect(scan(root: root, exempt: '$root/engines/')['$root/main.dart'], [
        1,
      ]);
    });

    // **R3-F1's wrapper — the shape that broke the transitivity argument.** An
    // exempt file that *reaches* a fake without naming one. Pass 2 skips it for being
    // exempt; the single-sweep pass 1 declined to flag it for not naming a fake, so
    // the reference was laundered and the consumer was invisible.
    test('it reports a consumer of an exempt file that only reaches a fake', () {
      final root = probeTree('wrapper', {
        'engines/providers.dart':
            'final llmEngineProvider = Provider((ref) => FakeLlmEngine());\n',
        'engines/demo_seam.dart':
            "import 'providers.dart';\n"
            'final demoEngineProvider = llmEngineProvider;\n',
        'main.dart': "import 'engines/demo_seam.dart';\n",
      });

      // `demo_seam.dart` declared **open**, so the closure is the only thing that
      // can restrict it. R6-F2: without this the wrapper was restricted by
      // *location* under R5-F1's inversion, so this test — R3-F1's own regression
      // test, the finding that cost a round — passed with the closure deleted. Its
      // stated reason had stopped being true of what executed.
      final found = scan(
        root: root,
        exempt: '$root/engines/',
        open: {'$root/engines/demo_seam.dart'},
      );

      expect(
        found['$root/main.dart'],
        [1],
        reason:
            'the wrapper names no fake, so only a closed pass 1 catches this',
      );
    });

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

      // `seam.dart` open — R6-F2 again, and this is the one whose vacuity my own
      // R5-F2 answer diagnosed without recognising: the 7→6 drop happened because
      // this file stopped needing its conditional import to be seeded. That was the
      // vacuity, recorded as an explanation of a count.
      expect(
        scan(
          root: root,
          exempt: '$root/engines/',
          open: {'$root/engines/seam.dart'},
        )['$root/main.dart'],
        [1],
      );
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

  // **The sink, which six rounds of this file never looked at (R6-F1).**
  //
  // Everything above asks where an engine comes *from*: which file is a fake, which
  // directive reaches it, which URI form hides the reach. Six times that question has
  // been answered and six times the next round moved the fake somewhere the answer did
  // not cover — a new name, a new directory, a new directive shape. The seventh hole
  // was a `ScriptedDemoEngine` in `lib/services/inference/`, importing only the *open*
  // `llm_engine.dart`: outside the exemption, so nothing classified it at all.
  //
  // These two tests ask where an engine goes *to*, and that question has an answer
  // that does not depend on a fake's name or location.
  //
  // **Two claims that used to stand here were false, and each was falsified by
  // compiling the thing it said was impossible.** Kept as text because the file's
  // history is its design:
  //
  // * *"Every one of the seven demonstrated exploits ends in the same statement — an
  //   override of `agentEngineProvider`."* True of the seven at the time, false as a
  //   rule: a scripted engine returned from `agentEngineProvider`'s **body** needs no
  //   override anywhere, is analyze-clean, and leaves the override test green. That
  //   one is caught by the contract sink, not by this one.
  // * *"Every fake has to implement `LlmEngine` to be usable at all."* R9-F1
  //   falsified it — a scripted `InferenceHost` answers through the *real*
  //   `GemmaLlmEngine`, which is a state machine over an injected collaborator.
  //
  // So neither test is closed by construction on its own, and saying so is the point:
  // the override sink catches the wiring, the contract sink catches the type, and
  // **the two are complementary rather than each sufficient.**
  //
  // **This used to continue "and every fake has to implement `LlmEngine` to be usable
  // at all", and R9-F1 falsified it by compiling one that does not.** A scripted
  // `InferenceHost` answers through the *real* `GemmaLlmEngine`, because that engine
  // is a state machine over an injected collaborator. So the guarded surface is
  // [scriptableContracts] — the whole token path — and the honest claim is narrower:
  // an implementation of *any* contract on that path must live in an approved file.
  group('the sink: how an engine reaches the running app', () {
    /// Every `.dart` under `lib/`, as path → source.
    Map<String, String> productionSources() {
      final sources = <String, String>{};
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        sources[entity.path.replaceAll(r'\', '/')] = entity.readAsStringSync();
      }
      return sources;
    }

    // Production wires its graph by *declaring* providers, never by overriding them.
    // Overriding is a test's tool, and the doc has said so in prose since round 0 —
    // "the fake is still exactly one line away from any *test* that wants it … a
    // deliberate act in a test file". It had simply never been asserted, and it was
    // the statement all seven exploits *known at the time* went through — not, as an
    // earlier version of this line said, the one every exploit needs. See the group
    // doc above: a scripted engine returned from `agentEngineProvider`'s own body
    // needs no override at all, and is caught by the contract sink instead.
    //
    // No allow-list, deliberately: there is nothing to allow today, and the first
    // production override should be a conversation rather than an entry in a set.
    /// Override sites in [sources], as `path -> ['overrideWith(…)', …]`.
    ///
    /// Takes its sources as a parameter for the reason `scan` does, and R7-F3 is what
    /// it cost not to: both sink detectors used to read `lib/` directly, so neither
    /// had a positive path and **both could be disabled with the file green.** That
    /// is R1-F2 verbatim, on new code, five rounds later — and it is *how* R7-F1 and
    /// R7-F2 survived. A detector that has only ever returned empty is not a
    /// detector.
    Map<String, List<String>> overrideSites(Map<String, String> sources) {
      final offenders = <String, List<String>>{};
      sources.forEach((path, source) {
        final collector = _OverrideCollector();
        parseString(
          content: source,
          throwIfDiagnostics: false,
        ).unit.accept(collector);
        if (collector.sites.isNotEmpty) {
          offenders[path] = collector.sites.map((s) => s.$2).toList();
        }
      });
      return offenders;
    }

    test('no production file overrides a provider', () {
      expect(
        overrideSites(productionSources()),
        isEmpty,
        reason:
            'overriding a provider in lib/ is how every fake in this review reached '
            'the app; production declares its graph, tests override it',
      );
    });

    // **Every interface a scripted answer can enter through, not just the top one —
    // R9-F1.** The guard watched `LlmEngine` for four rounds while the actual seam
    // was one interface down. `GemmaLlmEngine` is a state machine over an *injected*
    // collaborator — its own doc says it "takes an `InferenceHost` rather than
    // building one", `initialize()` is `_host.start(config)` and `generate()` is
    // `return _host.generate(…)` verbatim. So an `InferenceHost` returning canned
    // tokens produces a scripted demo through the **real** `GemmaLlmEngine`, and
    // `InferenceHost` is not an `LlmEngine`, so nothing here saw it. The reviewer ran
    // it end to end: with no verified weights the real `agentEngineProvider` returned
    // a ready engine reporting a `gpu` backend and answered from a script.
    //
    // The lesson is the one this file keeps relearning at a new level: *dependency
    // injection means every injected interface is a seam*, so the guarded set is the
    // set of contracts an answer can be scripted through, not the one at the top.
    //
    // **So this is the whole token path, not just the one the reviewer named** —
    // adding only `InferenceHost` would be patching the instance instead of asking
    // the question, which is the move that has bought exactly one round, five times.
    // `InferenceRuntime` is the same seam one level further down, injected at
    // `inference_isolate.dart:462` and `:547`, and its own doc says the host can be
    // "driven on the host against a scripted [InferenceRuntime]" — the evasion is
    // written in the source as an intended capability.
    //
    // **What is deliberately *not* here, and why.** `SeedSource` and `AgentTool` can
    // both feed the model false input, but the model still generates the answer, so
    // they break "the corpus is genuine" rather than "a model ran" — a real property
    // and a different one. `VisionEngine`, `SttEngine`, `PlatformTelemetry`,
    // `ModelDownloader` and `BackupExclusion` are not on the answer path at all.
    // If a future feature puts one of them there, it belongs here.
    const scriptableContracts = {
      'LlmEngine',
      'InferenceHost',
      'InferenceRuntime',
    };

    // The interface is a far smaller and more stable surface than the fake's name.
    // `LlmEngine` cannot be renamed without a compile error at every call site,
    // whereas `FakeLlmEngine` was only ever a convention — which is exactly how R5-F1
    // and R6-F1 got through.
    //
    // **Keyed on `(file, declaration)`, not on file — R7-F1.** A set of *files* while
    // the property is per-*declaration* means appending a second class to an
    // already-approved file is invisible: `declarations.keys` is unchanged, so even
    // the anti-rot equality below still passed. A scripted engine appended to
    // `gemma_llm_engine.dart` and returned from `agentEngineProvider` needed no
    // override, no new file and no new import, and the suite stayed 654 green.
    const approvedImplementations = {
      // The device engine — the implementation production is *supposed* to reach.
      ('lib/engines/impl/gemma_llm_engine.dart', 'GemmaLlmEngine'),
      // The fake, which lives inside the exemption where the scan above confines it.
      ('lib/engines/fakes/fake_llm_engine.dart', 'FakeLlmEngine'),
      // The real host `GemmaLlmEngine` delegates to — R9-F1. The only one in `lib/`.
      ('lib/services/inference/inference_isolate.dart', 'IsolateInferenceHost'),
      // The real runtime the host drives, one seam further down.
      ('lib/services/inference/gemma_runtime.dart', 'GemmaRuntime'),
    };

    /// Every `(file, declaration)` under [root] whose type reaches `LlmEngine`,
    /// **asked of the resolved type system rather than of the syntax.**
    ///
    /// This is the fix for **R8-F1**, and it is the move round 5 made one level up
    /// when it replaced the directive regex with a parser. The syntactic version
    /// asked "which declarations name `LlmEngine` in a supertype clause", and that
    /// question has an unbounded number of spellings: it lost to a fifth declaration
    /// form (R7-F2), to four unbound collector arms (R8-F2), and finally to
    /// `typedef DemoEngineContract = LlmEngine;` — because the seed was a *name*, and
    /// Dart has a keyword for renaming a type. `allSupertypes` has no spellings. It
    /// is transitive by construction, so there is no closure to iterate; it covers
    /// every declaration form, so there is no list to keep; and it resolves aliases,
    /// so the seed is the type rather than the identifier.
    ///
    /// **The reviewer was asked whether the cost was worth paying and said yes.**
    /// Both objections in the previous round are settled: it costs ~10s against a
    /// ~15s suite, which is the price of the last enumeration in this file; and the
    /// SDK path is *derived*, not hardcoded — `FLUTTER_ROOT` is set inside
    /// `flutter test` (verified: `/opt/homebrew/share/flutter`), which was the
    /// factual error in my argument for keeping the syntax version.
    ///
    /// Takes [root] as a parameter so it has a positive path (**R7-F3**), and a probe
    /// tree resolves without any package config as long as it declares its own
    /// `LlmEngine` and imports it relatively.
    Future<Set<(String, String)>> engineDeclarations(String root) async {
      final flutterRoot = Platform.environment['FLUTTER_ROOT'];
      final collection = AnalysisContextCollection(
        includedPaths: [Directory(root).absolute.path],
        sdkPath: flutterRoot == null ? null : '$flutterRoot/bin/cache/dart-sdk',
      );

      final declared = <(String, String)>{};
      final unresolved = <String>[];
      for (final context in collection.contexts) {
        for (final path in context.contextRoot.analyzedFiles()) {
          if (!path.endsWith('.dart')) continue;
          final unit = await context.currentSession.getResolvedUnit(path);
          // **Not `continue`.** Skipping a file that would not resolve is the
          // fail-open shape this file has already been caught by once, in the
          // parser's `throwIfDiagnostics: false`. A file that cannot be resolved is
          // a file this guard did not check, and that must fail rather than pass.
          if (unit is! ResolvedUnitResult) {
            unresolved.add(path);
            continue;
          }
          final library = unit.libraryElement;
          // Every element kind that can carry supertypes. Unlike the syntactic
          // collector this is not load-bearing: a kind omitted here is one whose
          // declarations are not examined, but each kind's *supertypes* come from
          // `allSupertypes`, which is where every previous miss lived.
          final interfaces = <InterfaceElement>[
            ...library.classes,
            ...library.mixins,
            ...library.enums,
            ...library.extensionTypes,
          ];
          for (final element in interfaces) {
            final isEngine = element.allSupertypes.any(
              (type) => scriptableContracts.contains(type.element.name),
            );
            if (isEngine) {
              declared.add((
                p.relative(path, from: Directory.current.path),
                element.name ?? '<unnamed>',
              ));
            }
          }
        }
      }

      expect(unresolved, isEmpty, reason: 'these files were never checked');
      return declared;
    }

    // **A tripwire, and it is worth being exact about what it is not.** Deriving the
    // corpus from [scriptableContracts] stops a contract being added without being
    // probed — but it also means *removing* one removes its probe, so the corpus can
    // never catch a narrowing. That is the pairwise weakness R9's note N3 identified,
    // and I made it worse before I made it better: dropping `'InferenceRuntime'`
    // together with its approved pair is one coherent edit that left every other test
    // green.
    //
    // Nothing computable defends against that, because "which contracts can script an
    // answer" is a judgement about this app rather than a property of the code. So
    // this asserts the judgement literally. It does not make narrowing impossible; it
    // makes narrowing *loud* — you must delete a test whose name says what you are
    // giving up, which is the difference between a decision and a slip.
    test('the guarded contract set is the whole token path', () {
      expect(
        scriptableContracts,
        {'LlmEngine', 'InferenceHost', 'InferenceRuntime'},
        reason:
            'narrowing this set is exactly how R9-F1 shipped: the guard watched '
            'LlmEngine while a scripted InferenceHost answered through the real '
            'engine. Removing a name here needs an argument, not an edit.',
      );
    });

    test(
      'every implementation of a scriptable contract lives in an approved file',
      () async {
        final declared = await engineDeclarations('lib');

        expect(
          declared.difference(approvedImplementations),
          isEmpty,
          reason:
              'a new LlmEngine implementation is how a scripted engine reaches the '
              'demo; adding one must be a visible edit to this set',
        );
        // Both approved declarations must still exist, or the set has rotted into a
        // list of names that no longer mean anything — the failure mode of every
        // allow-list this file has carried.
        expect(declared, approvedImplementations);
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );

    // **The positive path for both sinks — R7-F3.** Everything above asserts the real
    // tree is clean, which a detector that never fires satisfies perfectly. These run
    // the same two functions over trees built to offend, and over one built not to.
    group('the sinks can actually detect', () {
      test('an overrideWith call is reported', () {
        expect(
          overrideSites({
            'main.dart':
                'void main() {\n'
                '  runApp(ProviderScope(overrides: const []));\n'
                '}\n',
            'other.dart':
                'final x = engineProvider.overrideWith((ref) => 1);\n',
          }),
          {
            'main.dart': ['overrides: …'],
            'other.dart': ['overrideWith(…)'],
          },
        );
      });

      test('a file that overrides nothing is not reported', () {
        expect(
          overrideSites({
            'clean.dart':
                'final engineProvider = Provider((ref) => RealEngine());\n',
          }),
          isEmpty,
          reason:
              'a detector that reports everything passes the real-tree assertion '
              'for the wrong reason',
        );
      });

      // **One corpus, resolved once, covering every shape this sink has ever lost
      // to.** Each line is a finding: the two-hop chain is the case that defeated
      // round 7's one-hop check; the three-hop chain is one deeper than a
      // single-sweep closure reached; the second declaration in an approved file is
      // R7-F1; the five declaration forms are R7-F2; the `with`-a-mixin route is
      // R8-F2's exploit; and the typedef is R8-F1, the one that retired the
      // syntactic version entirely.
      //
      // A probe tree resolves with no package config because it declares its own
      // `LlmEngine` and imports it relatively — which is the only reason the
      // resolved detector could keep the positive path R7-F3 bought.
      test(
        'every route to LlmEngine is reported, and nothing else is',
        () async {
          final dir = Directory.systemTemp.createTempSync('fieldops_sink');
          addTearDown(() => dir.deleteSync(recursive: true));
          // **Every guarded contract, derived from the set rather than named here —
          // R9-F1's note N3.** The corpus used to declare `LlmEngine` alone, so only
          // that entry was bound independently. The rest were bound *pairwise*:
          // dropping `'InferenceRuntime'` from [scriptableContracts] together with
          // its approved pair is one coherent edit that left the guard green and
          // silently narrowed it back to where R9-F1 lived. Generating the corpus
          // from the set closes **half** of that, and only half: a contract added to
          // the set is probed automatically, so coverage cannot lag the set. A
          // contract *removed* takes its probe with it, so this test cannot catch a
          // narrowing and does not claim to — that is what
          // `the guarded contract set is the whole token path` is for. An earlier
          // version of this comment said "one removed fails here whatever else is
          // edited", which was false and contradicted the tripwire's own comment a
          // hundred lines above.
          File('${dir.path}/contracts.dart').writeAsStringSync(
            [
              for (final contract in scriptableContracts)
                'abstract interface class $contract {}',
            ].join('\n'),
          );
          File('${dir.path}/offenders.dart').writeAsStringSync(
            "import 'contracts.dart';\n"
            "${[for (final c in scriptableContracts) 'class Probe$c implements $c {}'].join('\n')}\n"
            // direct
            'class AsImplements implements LlmEngine {}\n'
            // two hops, and three — a single sweep declared child-first misses these
            'class AsExtends extends AsImplements {}\n'
            'class AsExtendsDeeper extends AsExtends {}\n'
            // R7-F1: a second declaration beside an approved one
            'class SecondInFile implements LlmEngine {}\n'
            // the remaining declaration forms (R7-F2)
            'mixin AsMixinOn on AsImplements {}\n'
            'enum AsEnum implements LlmEngine { one }\n'
            'extension type AsExtensionType(int v) implements LlmEngine {}\n'
            'class AsAlias = Object with AsMixinImplements;\n'
            // R8-F2: reached through `with`, which had no positive path
            'mixin AsMixinImplements implements LlmEngine {}\n'
            'class AsWith with AsMixinImplements {}\n'
            // R8-F1: the interface under another name
            'typedef Contract = LlmEngine;\n'
            'class AsTypedef implements Contract {}\n'
            // and one that is not an engine at all
            'class NotAnEngine {}\n',
          );

          final declared = await engineDeclarations(dir.path);

          expect(declared.map((d) => d.$2).toSet(), {
            for (final contract in scriptableContracts) 'Probe$contract',
            'AsImplements',
            'AsExtends',
            'AsExtendsDeeper',
            'SecondInFile',
            'AsMixinOn',
            'AsEnum',
            'AsExtensionType',
            'AsAlias',
            'AsMixinImplements',
            'AsWith',
            'AsTypedef',
          });
        },
        timeout: const Timeout(Duration(minutes: 5)),
      );
    });
  });
}
