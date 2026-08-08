/// The half of the golden suite that is not about agent loops at all: reading a
/// committed snapshot, comparing it to a fresh one, and — when they differ —
/// saying so in a way a reader can act on.
///
/// **Why this is a separate library with its own tests.** TC-GOLD-02 asks for
/// proof that the harness "actually catches drift", and the only honest way to
/// show that is to *run* a drifted transcript through the comparator and assert
/// on what comes back. That requires the comparison to be a **function
/// returning a value**, not a procedure that calls `fail()` — a test cannot
/// assert that a failure was readable if the failure aborts the test.
/// [reconcileGolden] is that function; [verifyGolden] is the thin shell that
/// does the file IO and turns a verdict into a test failure.
///
/// **Update mode.** `UPDATE_GOLDENS=1 flutter test test/golden` rewrites the
/// snapshots instead of asserting on them. Two properties matter more than the
/// convenience:
///
/// * A rewrite that **changes** a file still fails the test
///   ([GoldenVerdict.rewrite]). So a CI job with the flag set by accident cannot
///   turn a real regression green — it can only be green when the flag changed
///   nothing, which is precisely the harmless case.
/// * The decision is a parameter of [reconcileGolden], not a lookup inside it,
///   so both branches are reachable from an ordinary test. An environment read
///   buried in the comparison would be a line no test could bind — the defect
///   class Task 1.4 paid for with its `assert`ed clamp.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'transcript_snapshot.dart';

/// Directory holding the committed snapshots, relative to the package root.
///
/// `flutter test` runs with the package root as the working directory (the same
/// assumption `agent_loop_test.dart` already makes when it reads
/// `assets/elevator_manual_seed.json`), so a relative path is correct here and a
/// path derived from `Platform.script` would not be.
const String goldenDirectory = 'test/golden/snapshots';

/// Environment variable that switches the suite from asserting to rewriting.
const String updateEnvironmentVariable = 'UPDATE_GOLDENS';

/// Whether [value] — the raw environment string — asks for a rewrite.
///
/// Accepts `1` and `true`; anything else, `null` and the empty string included,
/// means "assert", because the default must be the safe one.
///
/// Split out from [goldensAreBeingUpdated] so it is testable at all. Inline, the
/// predicate can only ever be exercised with whatever the ambient environment
/// happens to hold, so widening it to `value != null` would leave every test
/// green in a normal run — an unbindable line, which is the defect class this
/// repo keeps paying for.
bool updateRequested(String? value) => value == '1' || value == 'true';

/// Whether this process was asked to rewrite the goldens.
bool get goldensAreBeingUpdated =>
    updateRequested(Platform.environment[updateEnvironmentVariable]);

/// What [reconcileGolden] concluded.
enum GoldenVerdict {
  /// The fresh snapshot is byte-identical to the committed one.
  match,

  /// They differ. This is the regression TC-GOLD-02 exists to demonstrate.
  drift,

  /// No golden is committed for this scenario yet.
  ///
  /// Distinct from [drift] because the remedy differs and because a missing file
  /// must never read as a pass: a harness that silently accepts an absent golden
  /// covers nothing while looking like it covers everything.
  absent,

  /// Update mode, and the file was (or must be) written.
  rewrite,
}

/// The verdict plus the message a reader gets.
class GoldenReconciliation {
  const GoldenReconciliation({
    required this.verdict,
    required this.report,
    required this.driftingLines,
  });

  final GoldenVerdict verdict;

  /// Empty exactly when [verdict] is [GoldenVerdict.match].
  final String report;

  /// Size of the changed region after the common prefix and suffix are trimmed —
  /// **not** an edit distance and not "the number of lines that differ".
  ///
  /// Stated narrowly on purpose. For a one-line edit the two coincide; for an
  /// inserted line the region is one line on one side and zero on the other, and
  /// for two edits far apart it spans everything between them. It is here so a
  /// test can say "this drift was small" without pretending the number means
  /// more than it does.
  final int driftingLines;

  bool get passes => verdict == GoldenVerdict.match;
}

/// Compares [actual] against [committed] (`null` when no golden exists).
///
/// Pure: no file IO, no environment reads. See the library doc for why.
GoldenReconciliation reconcileGolden({
  required String scenario,
  required String path,
  required String actual,
  required String? committed,
  bool update = false,
}) {
  if (committed == actual) {
    // Checked before the update branch so update mode is a no-op on an
    // unchanged golden: rewriting an identical file would churn mtimes and, more
    // to the point, would make "the flag changed nothing" indistinguishable from
    // "the flag rewrote a regression".
    return const GoldenReconciliation(
      verdict: GoldenVerdict.match,
      report: '',
      driftingLines: 0,
    );
  }

  if (update) {
    return GoldenReconciliation(
      verdict: GoldenVerdict.rewrite,
      report:
          'Golden rewritten: $path\n'
          '  scenario: $scenario\n'
          '${committed == null ? '  (the file did not exist)\n' : renderDiff(expected: committed, actual: actual)}'
          'The suite still fails, deliberately: $updateEnvironmentVariable is a '
          'generator, not an approval. Read the diff above, then re-run without '
          'it.',
      driftingLines: committed == null
          ? lines(actual).length
          : _driftRegion(lines(committed), lines(actual)).length,
    );
  }

  if (committed == null) {
    return GoldenReconciliation(
      verdict: GoldenVerdict.absent,
      report:
          'No golden committed for scenario "$scenario".\n'
          '  expected file: $path\n'
          'Generate it with:\n'
          '  $updateEnvironmentVariable=1 flutter test test/golden\n'
          'then read the generated file before committing it — a golden nobody '
          'has read is a snapshot of whatever the code did, not a statement '
          'about what it should do.',
      driftingLines: lines(actual).length,
    );
  }

  final expectedLines = lines(committed);
  final actualLines = lines(actual);
  return GoldenReconciliation(
    verdict: GoldenVerdict.drift,
    report:
        'Golden mismatch for scenario "$scenario".\n'
        '  golden: $path\n'
        '${renderDiff(expected: committed, actual: actual)}'
        'If this change is intended, regenerate with:\n'
        '  $updateEnvironmentVariable=1 flutter test test/golden',
    driftingLines: _driftRegion(expectedLines, actualLines).length,
  );
}

/// Renders the changed region of a line-based diff, `-` for the golden and `+`
/// for this run.
///
/// A positional line-by-line comparison would report every line after an
/// insertion as different, which is technically true and useless. Trimming the
/// common prefix and the common suffix first costs ten lines of code and turns
/// "212 lines differ" into "one line was added, here it is". It is deliberately
/// **not** a real LCS diff: two edits far apart are reported as one region
/// spanning both, which is honest about what the harness computed.
String renderDiff({
  required String expected,
  required String actual,
  int maxLinesPerSide = 20,
}) {
  final expectedLines = lines(expected);
  final actualLines = lines(actual);
  final region = _driftRegion(expectedLines, actualLines);

  final buffer = StringBuffer()
    ..writeln(
      '  ${expectedLines.length} line(s) in the golden, '
      '${actualLines.length} in this run; '
      'first difference at line ${region.start + 1}',
    );

  void emit(String marker, List<String> lines, int from, int to) {
    final shown = (to - from).clamp(0, maxLinesPerSide);
    for (var i = from; i < from + shown; i++) {
      buffer.writeln('  $marker ${i + 1}: ${lines[i]}');
    }
    final hidden = (to - from) - shown;
    if (hidden > 0) {
      buffer.writeln('  $marker … $hidden more line(s)');
    }
  }

  emit('-', expectedLines, region.start, region.expectedEnd);
  emit('+', actualLines, region.start, region.actualEnd);
  return buffer.toString();
}

/// The span that differs, after trimming the shared prefix and suffix.
_DriftRegion _driftRegion(List<String> expected, List<String> actual) {
  var start = 0;
  final shortest = expected.length < actual.length
      ? expected.length
      : actual.length;
  while (start < shortest && expected[start] == actual[start]) {
    start++;
  }
  var tail = 0;
  while (tail < shortest - start &&
      expected[expected.length - 1 - tail] ==
          actual[actual.length - 1 - tail]) {
    tail++;
  }
  return _DriftRegion(
    start: start,
    expectedEnd: expected.length - tail,
    actualEnd: actual.length - tail,
  );
}

class _DriftRegion {
  const _DriftRegion({
    required this.start,
    required this.expectedEnd,
    required this.actualEnd,
  });

  final int start;
  final int expectedEnd;
  final int actualEnd;

  /// Lines in the region, taking the wider side.
  int get length {
    final expected = expectedEnd - start;
    final actual = actualEnd - start;
    return expected > actual ? expected : actual;
  }
}

/// Path of the golden for [scenario].
String goldenPathFor(String scenario) =>
    p.join(goldenDirectory, '$scenario.json');

/// Reconciles [snapshot] against [file], writing it when [update] asks for a
/// rewrite, and returns the verdict **without failing anything**.
///
/// The filesystem half, taken as parameters rather than read from the ambient
/// environment and the committed directory — which is review finding R0-F2 and
/// the same lesson [reconcileGolden] already learned one layer up. With the
/// `File` and the flag baked in, the write was a line **no test could reach**:
/// `goldensAreBeingUpdated` reads the process environment, Dart cannot change it
/// in-process, so under `flutter test` the rewrite branch never executed.
/// Deleting both of its statements left all 552 tests green. Worse, the test that
/// *claimed* to bind it wrote the file itself and never called this function, so
/// the comment asserting the property was the only thing holding it.
///
/// Why the write matters enough to bind: `UPDATE_GOLDENS=1 flutter test
/// test/golden` is the documented regeneration path, and a broken write would
/// keep printing `Golden rewritten: <path>` and failing the suite while changing
/// nothing on disk — from the operator's side, indistinguishable from working.
GoldenReconciliation applyGolden({
  required String scenario,
  required Map<String, Object?> snapshot,
  required File file,
  required bool update,
}) {
  final actual = encodeSnapshot(snapshot);
  final reconciliation = reconcileGolden(
    scenario: scenario,
    path: file.path,
    actual: actual,
    committed: file.existsSync() ? file.readAsStringSync() : null,
    update: update,
  );

  if (reconciliation.verdict == GoldenVerdict.rewrite) {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(actual);
  }
  return reconciliation;
}

/// Asserts [snapshot] matches the committed golden for [scenario], writing it
/// instead when [goldensAreBeingUpdated].
///
/// The only part of this library that fails a test. Everything else it does is
/// [applyGolden]'s, so that the write is reachable from an ordinary test.
void verifyGolden({
  required String scenario,
  required Map<String, Object?> snapshot,
}) {
  final reconciliation = applyGolden(
    scenario: scenario,
    snapshot: snapshot,
    file: File(goldenPathFor(scenario)),
    update: goldensAreBeingUpdated,
  );
  if (!reconciliation.passes) {
    fail(reconciliation.report);
  }
}
