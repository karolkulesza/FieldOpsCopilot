/// Unit-tier coverage for the golden harness itself.
///
/// Split from `llm_golden_test.dart` because the two answer different
/// questions. That file asks "does the loop still produce this transcript"; this
/// one asks "is the machinery that answers that question trustworthy" — and the
/// answer matters more, because every claim the six goldens make is routed
/// through it. A harness whose comparator returned `match` unconditionally would
/// leave all six green forever.
///
/// Four properties, in the order they can fail:
///
/// 1. **[lines] is lossless**, or a prompt does not survive a round trip and the
///    golden is a lossy record of something else.
/// 2. **[encodeSnapshot] is deterministic and ASCII**, or the goldens flake.
/// 3. **[reconcileGolden] separates the four verdicts**, or a missing golden
///    reads as a pass.
/// 4. **[renderDiff] points at the change**, which is the whole of TC-GOLD-02's
///    "readable".
library;

import 'dart:convert';
import 'dart:io';

import 'package:field_ops_copilot/services/ai/agent_loop.dart';
import 'package:field_ops_copilot/services/rag/retrieval_router.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_file.dart';
import 'transcript_snapshot.dart';

void main() {
  group('lines is lossless', () {
    // The property, not a sample of it: whatever `lines` does to a string,
    // rejoining must give the string back. The shape that matters most is a
    // *trailing* newline — it must produce a trailing `''` rather than being
    // swallowed, or a transcript ending in a blank line snapshots identically to
    // one that does not.
    //
    // The exotic separators are spelled with [String.fromCharCode] rather than
    // pasted in. Task 1.9 paid for that lesson: its hostile list carried a
    // literal U+2028, invisible in the source, and the assertions beside it
    // could never have failed on it. A separator you cannot see is a fixture
    // nobody has read.
    final hostile = <String>[
      '',
      'one line',
      'two\nlines',
      '\n',
      '\n\n\n',
      'trailing\n',
      '\nleading',
      'windows\r\nstyle',
      'tab\tand spaces  ',
      'line separator ${String.fromCharCode(0x2028)} here',
      'paragraph separator ${String.fromCharCode(0x2029)} here',
      'next line ${String.fromCharCode(0x0085)} here',
      'delete ${String.fromCharCode(0x007f)} here',
      'emoji ${String.fromCharCodes([0xd83d, 0xdee0])} tool',
    ];

    for (final text in hostile) {
      test('round-trips ${visibly(text)}', () {
        expect(lines(text).join('\n'), text);
      });
    }

    test('a trailing newline is a trailing empty line, not a dropped one', () {
      expect(lines('a\n'), ['a', '']);
      expect(lines('a'), ['a']);
      // Which is the difference the assertion above would miss on its own.
      expect(lines('a\n'), isNot(lines('a')));
    });
  });

  group('encodeSnapshot', () {
    Map<String, Object?> snapshotWith(Object? value) => {
      'scenario': 'probe',
      'value': value,
    };

    test('is byte-identical for equal input', () {
      // Cheap, and it is the property the whole suite rests on: `JsonEncoder`
      // preserves map insertion order, and every map here is built by a literal,
      // so two runs of the same scenario cannot disagree about key order.
      expect(
        encodeSnapshot(snapshotWith('x')),
        encodeSnapshot(snapshotWith('x')),
      );
    });

    test('ends with exactly one newline', () {
      final encoded = encodeSnapshot(snapshotWith('x'));
      expect(encoded, endsWith('}\n'));
      expect(encoded, isNot(endsWith('\n\n')));
    });

    test('escapes every code unit outside printable ASCII', () {
      // The four `jsonEncode` leaves raw (Task 1.9's R0-F1 measured them), an em
      // dash, and an astral-plane character. Spelled by code point for the same
      // reason as the list above: this test's entire subject is characters you
      // cannot see in a source file.
      //
      // The em dash is the one that also occurs in real data:
      // `AgentLoop.continueAfterResults` contains one, so **five of the six**
      // committed goldens carry a `\u2014` (counted: 1, 1, 6, 0, 7, 3). The
      // exception is `no_manual_match`, which is a single turn with no tool call
      // — the loop never appends a `[CONTINUE]` block, so that golden has no
      // escape of any kind in it. The first version of this comment said "every
      // committed golden exercises this case", which was one `grep -c` from being
      // checked (review finding R0-F3).
      final raw = [
        'nel:${String.fromCharCode(0x0085)}',
        'ls:${String.fromCharCode(0x2028)}',
        'ps:${String.fromCharCode(0x2029)}',
        'del:${String.fromCharCode(0x007f)}',
        'dash:${String.fromCharCode(0x2014)}',
        'astral:${String.fromCharCodes([0xd83d, 0xdee0])}',
      ].join(' ');
      final encoded = encodeSnapshot(snapshotWith(raw));

      expect(
        encoded.codeUnits.every(
          (unit) => unit == 0x0a || (unit >= 0x20 && unit <= 0x7e),
        ),
        isTrue,
        reason: 'encodeSnapshot left a non-ASCII code unit in:\n$encoded',
      );
      expect(encoded, contains(r'\u0085'));
      expect(encoded, contains(r'\u2028'));
      expect(encoded, contains(r'\u2029'));
      expect(encoded, contains(r'\u007f'));
      expect(encoded, contains(r'\u2014'));
      // A surrogate pair is escaped as its two code units, which is exactly what
      // JSON specifies for a character outside the BMP.
      expect(encoded, contains(r'\ud83d\udee0'));
    });

    test('is lossless - the escaping decodes back to the same value', () {
      // The reason to escape rather than strip. A golden that mangled its input
      // would be a snapshot of the harness rather than of the run.
      final raw =
          'ls:${String.fromCharCode(0x2028)} '
          'ps:${String.fromCharCode(0x2029)} '
          'nel:${String.fromCharCode(0x0085)} '
          'astral:${String.fromCharCodes([0xd83d, 0xdee0])}';
      final decoded =
          jsonDecode(encodeSnapshot(snapshotWith(raw))) as Map<String, Object?>;
      expect(decoded['value'], raw);
    });

    test('set-typed retrieval hits are sorted, not insertion-ordered', () {
      // No committed scenario retrieves two hits whose insertion order differs
      // from sorted order, so this is the only place the rule can be bound —
      // which is exactly why `sortedHits` is public. Built by hand with a
      // `LinkedHashSet` that disagrees: without the sort, the snapshot inherits
      // whatever order the router happened to insert in, and a golden would then
      // depend on an implementation detail of a `Set`.
      final insertionOrdered = <String>{'zzz_last', 'aaa_first'};
      expect(insertionOrdered.toList(), ['zzz_last', 'aaa_first']);
      expect(sortedHits(insertionOrdered), ['aaa_first', 'zzz_last']);

      final snapshot = transcriptSnapshot(
        scenario: 'probe',
        retrieval: const RetrievalResult(
          rawQuery: 'two hits',
          entries: [],
          codeHitIds: {'zzz_last', 'aaa_first'},
          ftsHitIds: {'zzz_last', 'aaa_first'},
          resolvedCodes: [],
          unresolvedCodes: [],
          searchedTerms: [],
        ),
        events: const [],
        result: const AgentRunResult(
          answer: 'x',
          stopReason: AgentStopReason.answered,
          turns: [],
        ),
      );
      final retrieval = snapshot['retrieval']! as Map<String, Object?>;
      expect(retrieval['codeHitIds'], ['aaa_first', 'zzz_last']);
      expect(retrieval['ftsHitIds'], ['aaa_first', 'zzz_last']);
    });

    test('keeps the indentation newlines it must not escape', () {
      // `_asciiOnly` excludes `\n` from its class on purpose: the encoder emits
      // real newlines between tokens, and escaping those would collapse the file
      // to one line — which would still be valid JSON, still lossless, and
      // useless to diff. This is the assertion that notices.
      final encoded = encodeSnapshot(snapshotWith('x'));
      expect(lines(encoded).length, greaterThan(3));
      expect(encoded, contains('\n  "value": "x"'));
    });
  });

  group('reconcileGolden', () {
    const scenario = 'probe';
    const path = 'test/golden/snapshots/probe.json';

    GoldenReconciliation reconcile({
      required String actual,
      required String? committed,
      bool update = false,
    }) => reconcileGolden(
      scenario: scenario,
      path: path,
      actual: actual,
      committed: committed,
      update: update,
    );

    test('identical text matches, and the report is empty', () {
      final result = reconcile(actual: 'a\nb\n', committed: 'a\nb\n');
      expect(result.verdict, GoldenVerdict.match);
      expect(result.passes, isTrue);
      expect(result.report, isEmpty);
      expect(result.driftingLines, 0);
    });

    test('a difference is drift, and the report is actionable', () {
      final result = reconcile(actual: 'a\nB\n', committed: 'a\nb\n');
      expect(result.verdict, GoldenVerdict.drift);
      expect(result.passes, isFalse);
      expect(result.report, contains(scenario));
      expect(result.report, contains(path));
      expect(result.report, contains('- 2: b'));
      expect(result.report, contains('+ 2: B'));
      expect(result.report, contains('$updateEnvironmentVariable=1'));
      expect(result.driftingLines, 1);
    });

    test('an absent golden is not a pass', () {
      // The failure this enum value exists for. A harness that treated a missing
      // file as "nothing to compare, therefore fine" would report full coverage
      // over an empty directory.
      final result = reconcile(actual: 'a\n', committed: null);
      expect(result.verdict, GoldenVerdict.absent);
      expect(result.passes, isFalse);
      expect(result.report, contains('No golden committed'));
      expect(result.report, contains(path));
    });

    test('update mode is a no-op on an unchanged golden', () {
      // Checked before the update branch, so "the flag changed nothing" and "the
      // flag rewrote a regression" are different verdicts rather than one.
      final result = reconcile(actual: 'a\n', committed: 'a\n', update: true);
      expect(result.verdict, GoldenVerdict.match);
      expect(result.passes, isTrue);
    });

    test('update mode on a changed golden rewrites AND still fails', () {
      // The property that makes `UPDATE_GOLDENS` safe to have at all: a CI job
      // with it set by accident cannot turn a real regression green.
      final result = reconcile(
        actual: 'a\nB\n',
        committed: 'a\nb\n',
        update: true,
      );
      expect(result.verdict, GoldenVerdict.rewrite);
      expect(result.passes, isFalse);
      expect(result.report, contains('generator, not an approval'));
      // The diff is in the rewrite report too — a regenerated golden nobody read
      // is the same problem as a golden nobody wrote.
      expect(result.report, contains('- 2: b'));
      expect(result.report, contains('+ 2: B'));
    });

    test('update mode on an absent golden says the file did not exist', () {
      final result = reconcile(actual: 'a\n', committed: null, update: true);
      expect(result.verdict, GoldenVerdict.rewrite);
      expect(result.report, contains('did not exist'));
    });
  });

  group('renderDiff points at the change', () {
    String diffOf(List<String> expected, List<String> actual) => renderDiff(
      expected: '${expected.join('\n')}\n',
      actual: '${actual.join('\n')}\n',
    );

    test('a one-line edit deep in a long file reports one line a side', () {
      // The case a positional comparison gets right too. It is here as the
      // baseline for the two below, which it gets wrong.
      final expected = [for (var i = 0; i < 200; i++) 'line $i'];
      final actual = [...expected]..[120] = 'line 120 changed';

      final diff = diffOf(expected, actual);
      expect(diff, contains('first difference at line 121'));
      expect(diff, contains('- 121: line 120'));
      expect(diff, contains('+ 121: line 120 changed'));
      // One line a side, not eighty.
      expect(diff.split('\n').where((l) => l.contains('- 1')), hasLength(1));
    });

    test('an inserted line is one added line, not a shifted tail', () {
      // Why the prefix/suffix trimming exists. Positionally, inserting at index
      // 5 of 200 makes every later line "differ"; here it is one `+` and no `-`.
      final expected = [for (var i = 0; i < 200; i++) 'line $i'];
      final actual = [...expected]..insert(5, 'inserted');

      final diff = diffOf(expected, actual);
      expect(diff, contains('+ 6: inserted'));
      expect(diff, isNot(contains('- 6:')));
      // 201 and 202, not 200 and 201: `diffOf` terminates both texts with a
      // newline, and `lines` counts the trailing empty line rather than dropping
      // it — the same convention the committed goldens are measured under.
      expect(diff, contains('201 line(s) in the golden, 202 in this run'));
    });

    test('a deleted line is one removed line', () {
      final expected = [for (var i = 0; i < 50; i++) 'line $i'];
      final actual = [...expected]..removeAt(10);

      final diff = diffOf(expected, actual);
      expect(diff, contains('- 11: line 10'));
      expect(diff, isNot(contains('+ 11:')));
    });

    test('a wide region is capped and says how much it hid', () {
      // A diff that dumps 300 lines is as unreadable as no diff.
      final expected = [for (var i = 0; i < 300; i++) 'line $i'];
      final actual = [for (var i = 0; i < 300; i++) 'other $i'];

      final diff = renderDiff(
        expected: expected.join('\n'),
        actual: actual.join('\n'),
        maxLinesPerSide: 5,
      );
      expect(diff, contains('- 1: line 0'));
      expect(diff, contains('- 5: line 4'));
      expect(diff, isNot(contains('- 6: line 5')));
      expect(diff, contains('- … 295 more line(s)'));
      expect(diff, contains('+ … 295 more line(s)'));
    });

    test('two distant edits are one region, and that is what it claims', () {
      // The documented limitation, bound so it cannot silently become something
      // else. `_driftRegion` trims a shared prefix and suffix; it does not
      // compute an edit script, so two changes 100 lines apart are reported as
      // one region spanning both. The alternative — claiming to be a real diff —
      // is the kind of unbacked claim this repo keeps paying for.
      final expected = [for (var i = 0; i < 200; i++) 'line $i'];
      final actual = [...expected]
        ..[20] = 'changed a'
        ..[120] = 'changed b';

      final diff = diffOf(expected, actual);
      expect(diff, contains('first difference at line 21'));
      expect(diff, contains('- … 81 more line(s)'));
    });
  });

  group('verifyGolden, the shell around all of it', () {
    // The one part that touches the filesystem. Exercised through a scratch
    // directory rather than the committed snapshots, so a bug in these tests
    // cannot rewrite a golden.
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('fieldops_golden_shell');
    });

    tearDown(() async {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    });

    test('a rewrite lands exactly what encodeSnapshot produced', () {
      // The write, exercised through the shipped function. The previous version
      // of this test claimed to bind it and did not: it wrote the file itself
      // with `..writeAsStringSync(encodeSnapshot(snapshot))` and never called
      // `verifyGolden`, so the comment asserting the property was the only thing
      // holding it (review finding R0-F2). Deleting both statements of the write
      // left all 552 tests green.
      final snapshot = {
        'scenario': 'probe',
        'value': 'dash ${String.fromCharCode(0x2014)} here',
      };
      final file = File('${tempDir.path}/nested/probe.json');
      expect(file.existsSync(), isFalse);

      final first = applyGolden(
        scenario: 'probe',
        snapshot: snapshot,
        file: file,
        update: true,
      );

      expect(first.verdict, GoldenVerdict.rewrite);
      expect(first.passes, isFalse, reason: 'a generator is not an approval');
      // The parent directory did not exist: `createSync(recursive: true)` is part
      // of the write and a fresh scenario is exactly when it is needed.
      expect(file.existsSync(), isTrue);
      // Byte-for-byte, because the *next* run compares against these bytes — any
      // transformation on the way to disk makes a regenerated golden fail
      // immediately, which reads as a broken suite rather than a broken write.
      expect(file.readAsStringSync(), encodeSnapshot(snapshot));
      // The em dash proves the ASCII escaping survives the round trip to disk —
      // and it is asserted in its *escaped* form, because that is what a golden
      // holds. The first version of this line looked for the raw character and
      // failed immediately, which is the third time in this task that a literal
      // non-ASCII character in a fixture has been wrong where the escape was
      // right.
      expect(file.readAsStringSync(), contains(r'\u2014'));
      expect(file.readAsStringSync(), isNot(contains('\u2014')));

      // And the second pass over an unchanged golden matches, through the same
      // function — which is the property a regeneration workflow depends on.
      final second = applyGolden(
        scenario: 'probe',
        snapshot: snapshot,
        file: file,
        update: true,
      );
      expect(second.verdict, GoldenVerdict.match);
      expect(second.passes, isTrue);
    });

    test('a drift writes nothing when not updating', () {
      // The other half, and the one that matters for CI: an ordinary run must
      // never touch the committed snapshots. Without this, a write condition
      // widened to `if (!reconciliation.passes)` would silently accept every
      // regression by overwriting the evidence — which is precisely what the
      // mutation harness's M29 does, and precisely why its run has to revert the
      // whole `test/golden` surface rather than the file it edited.
      final file = File(
        '${tempDir.path}/probe.json',
      )..writeAsStringSync(encodeSnapshot({'scenario': 'probe', 'value': 'a'}));
      final before = file.readAsStringSync();

      final result = applyGolden(
        scenario: 'probe',
        snapshot: {'scenario': 'probe', 'value': 'CHANGED'},
        file: file,
        update: false,
      );

      expect(result.verdict, GoldenVerdict.drift);
      expect(file.readAsStringSync(), before);
    });

    test('an absent golden writes nothing when not updating', () {
      final file = File('${tempDir.path}/never_written.json');

      final result = applyGolden(
        scenario: 'never_written',
        snapshot: const {'scenario': 'never_written'},
        file: file,
        update: false,
      );

      expect(result.verdict, GoldenVerdict.absent);
      expect(file.existsSync(), isFalse);
    });

    test('goldenPathFor lands in the committed snapshot directory', () {
      expect(goldenPathFor('probe'), '$goldenDirectory/probe.json');
    });

    test(
      'verifyGolden fails the test when a committed golden disagrees',
      () {
        // The `fail()` in `verifyGolden` is what makes all six scenario tests mean
        // anything, and nothing else in this repo exercises it: TC-GOLD-02 goes
        // through `reconcileGolden` directly, precisely because it needs a value
        // rather than an abort. Delete the `fail` and every golden passes forever.
        //
        // Skipped under `UPDATE_GOLDENS`, where this call would *rewrite* a
        // committed golden with the nonsense below rather than reject it.
        expect(
          () => verifyGolden(
            scenario: 'e102_native_tool_call',
            snapshot: const {'scenario': 'e102_native_tool_call', 'turns': []},
          ),
          throwsA(isA<TestFailure>()),
        );
        // And the committed file is untouched — a failing comparison must not
        // write.
        expect(
          File(goldenPathFor('e102_native_tool_call')).readAsStringSync(),
          contains('"in_stock": 2'),
        );
      },
      skip: _skipWhenUpdating,
    );

    test('updateRequested accepts only the two documented spellings', () {
      // The predicate, not the ambient environment. Inline this into
      // `goldensAreBeingUpdated` and widening it to `value != null` leaves every
      // test green in a normal run, because the variable is unset there.
      expect(updateRequested('1'), isTrue);
      expect(updateRequested('true'), isTrue);
      expect(updateRequested(null), isFalse);
      expect(updateRequested(''), isFalse);
      expect(updateRequested('0'), isFalse);
      expect(updateRequested('false'), isFalse);
      expect(updateRequested('yes'), isFalse);
      // Case-sensitive, deliberately: two spellings are enough, and a
      // case-folding rule nobody asked for is a rule nobody tested.
      expect(updateRequested('TRUE'), isFalse);
    });

    test('the update flag is off in an ordinary run', () {
      // `flutter test` without `UPDATE_GOLDENS` must assert rather than rewrite.
      // If this fails, the suite has been silently regenerating itself.
      expect(goldensAreBeingUpdated, isFalse, skip: _skipWhenUpdating);
      // Stated as a derivation too, so the test says *why* it is false rather
      // than only that it is.
      expect(
        goldensAreBeingUpdated,
        updateRequested(Platform.environment[updateEnvironmentVariable]),
      );
    });
  });
}

/// Why the assertion above is skipped in a generating run rather than deleted.
///
/// The test states the shipped default — asserting, not rewriting — which is
/// true of every run except the one deliberately regenerating the goldens.
/// Skipping there keeps the assertion meaningful in CI instead of weakening it
/// to a tautology that passes in both modes.
final Object? _skipWhenUpdating = goldensAreBeingUpdated
    ? 'run with $updateEnvironmentVariable set'
    : null;

/// [text] with every non-printable-ASCII code unit escaped, for use in a test
/// *name*.
///
/// A test whose name contains a raw U+2028 is a test whose name contains a line
/// break as far as the expanded reporter and the mutation harness's output
/// parser are concerned — and the harness keys its results by test name.
String visibly(String text) => text.replaceAllMapped(
  RegExp(r'[^\x20-\x7E]'),
  (m) => '\\u${m[0]!.codeUnitAt(0).toRadixString(16).padLeft(4, '0')}',
);
