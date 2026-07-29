import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:field_ops_copilot/services/database/database_service.dart';
import 'package:field_ops_copilot/services/database/fts_query_sanitizer.dart';
import 'package:field_ops_copilot/services/database/tables/manual_fts_table.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

/// Unit-tier coverage for Task 1.2 (FTS5 manual index + query sanitizer).
///
/// Every test runs against a real encrypted database file and the real FTS5
/// module from the bundled SQLite3MultipleCiphers build — the tokenizer, the
/// Porter stemmer and `bm25()` ranking are the things under test, so faking
/// them out would test nothing.
void main() {
  late Directory tempDir;
  late DatabaseService db;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('fieldops_fts_test');
    db = DatabaseService.encrypted(
      file: File('${tempDir.path}/manual.db'),
      encryptionKey: 'fts-test-key',
    );
  });

  tearDown(() async {
    await db.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<void> seed() => db.upsertManualEntries(_seedEntries);

  Future<List<String>> search(String raw, {int limit = 10}) async {
    final rows = await db.searchManualEntries(raw, limit: limit);
    return rows.map((r) => r.id).toList();
  }

  group('seeding', () {
    // TC-FTS-SEED-01: bulk insert of the seed manual populates the FTS index.
    //
    // Both halves matter. The document count reads `manual_fts_docsize`, the
    // shadow table holding one row per *indexed* document — an unconstrained
    // COUNT over `manual_fts` itself would be answered from the content table
    // and would pass with the triggers dropped. The per-entry searches then
    // prove each document is individually reachable through the index.
    test('bulk insert indexes every seed entry', () async {
      await seed();

      expect(await db.manualFtsIndexedDocumentCount(), 3);
      expect(await db.select(db.manualEntries).get(), hasLength(3));

      // A term unique to each entry, so all three index entries are exercised.
      expect(await search('traction'), ['apex_9_err_102']);
      expect(await search('proportional'), ['apex_9_err_204']);
      expect(await search('clutches'), ['apex_9_err_305']);
    });

    test('the document count reads the index, not the content table', () async {
      // Pins the distinction the count exists for: with the insert trigger gone,
      // the content table fills but the index stays empty.
      await db.customStatement('DROP TRIGGER manual_entries_after_insert');
      await seed();

      expect(await db.select(db.manualEntries).get(), hasLength(3));
      expect(await db.manualFtsIndexedDocumentCount(), 0);
      expect(await search('traction'), isEmpty);

      // ...and the documented recovery repopulates it from the content table.
      await db.rebuildManualFtsIndex();

      expect(await db.manualFtsIndexedDocumentCount(), 3);
      expect(await search('traction'), ['apex_9_err_102']);
    });

    test('re-inserting the same ids does not duplicate index rows', () async {
      await seed();
      await seed();

      expect(await db.manualFtsIndexedDocumentCount(), 3);
      // A duplicated document would return the same id twice.
      expect(await search('traction'), ['apex_9_err_102']);
    });

    test('the update trigger keeps the index in sync', () async {
      await seed();

      // "ledger" occurs only in E-204's symptom prose, so rewriting that column
      // must make the term unfindable — proving the update trigger unwound the
      // old terms instead of leaving a stale index entry behind.
      expect(await search('ledger'), ['apex_9_err_204']);

      final entry = _seedEntries
          .firstWhere((e) => e.id == 'apex_9_err_204')
          .copyWith(
            symptoms: 'Levelling inaccuracies, rough ride transitions.',
          );
      await db.upsertManualEntries([entry]);

      expect(await search('ledger'), isEmpty);
      expect(await db.manualFtsIndexedDocumentCount(), 3);
    });

    test('deleting an entry removes it from the index', () async {
      await seed();

      await (db.delete(
        db.manualEntries,
      )..where((t) => t.id.equals('apex_9_err_204'))).go();

      expect(await db.manualFtsIndexedDocumentCount(), 2);
      expect(await search('hydraulic'), isEmpty);
    });
  });

  group('migration', () {
    // The manual table, its FTS5 index and the sync triggers arrive in schema
    // v2; an app installed before Task 1.2 upgrades into them. Exercised by
    // tearing the v2 objects back down, rewinding user_version, and reopening.
    test('v1 database upgrades to the manual index', () async {
      final file = File('${tempDir.path}/migrate.db');
      final v1 = DatabaseService.encrypted(
        file: file,
        encryptionKey: 'migrate-key',
      );
      for (final stmt in const [
        'DROP TRIGGER manual_entries_after_insert',
        'DROP TRIGGER manual_entries_after_delete',
        'DROP TRIGGER manual_entries_after_update',
        'DROP TABLE manual_fts',
        'DROP TABLE manual_entries',
        'PRAGMA user_version = 1',
      ]) {
        await v1.customStatement(stmt);
      }
      await v1.close();

      final v2 = DatabaseService.encrypted(
        file: file,
        encryptionKey: 'migrate-key',
      );
      addTearDown(v2.close);

      // Upgrading recreates the table, the FTS index and the triggers: a fresh
      // insert must be searchable immediately.
      await v2.upsertManualEntries(_seedEntries);

      expect(await v2.manualFtsIndexedDocumentCount(), 3);
      final ids = await v2.searchManualEntries('squeal');
      expect(ids.map((r) => r.id), hasLength(2));

      // The b-tree index is a *separate* schema entity from the table, so
      // `createTable` alone would leave upgraded installs without it.
      final indexes = await v2
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type = 'index' "
            "AND name = 'idx_manual_entries_code'",
          )
          .get();
      expect(indexes, hasLength(1));
    });
  });

  group('full-text matching', () {
    setUp(seed);

    // TC-FTS-MATCH-01: the AC's input, plus the assertion that actually depends
    // on the stemmer. "vibrating brake" alone would pass without porter, because
    // "brake" is a literal hit in E-102's title, section and procedure — with an
    // OR-join one matching term is enough. "vibrating" on its own has no literal
    // occurrence anywhere: the manual says "vibration", so it can only match
    // through the porter stem `vibrat`.
    test('vibrating brake finds the brake-wear entry', () async {
      expect(await search('vibrating brake'), ['apex_9_err_102']);
      expect(await search('vibrating'), ['apex_9_err_102']);
    });

    // TC-FTS-MATCH-03: a stem shared by two entries returns both. Also
    // porter-only — the manual says "squealing", never "squeal".
    test('squeal matches squealing in two entries', () async {
      expect(
        await search('squeal'),
        containsAll(<String>['apex_9_err_102', 'apex_9_err_305']),
      );
      expect(await search('squeal'), hasLength(2));
    });

    test('title is indexed', () async {
      // "traction" occurs *only* in E-102's title — not in its section, symptoms
      // or procedure — so this fails if `title` leaves the FTS column list.
      // (A term like "clutches" would not prove it: E-305's procedure says
      // "door clutch alignment", which porter stems to the same token.)
      expect(await search('traction'), ['apex_9_err_102']);
    });

    test('section is indexed', () async {
      // Likewise "systems" occurs only in E-102's section, "Brake Systems".
      // ("valving" would not prove it — the title and procedure both say
      // "valve", which stems to `valv` just as "valving" does.)
      expect(await search('systems'), ['apex_9_err_102']);
    });

    test('ranking puts the title match first', () async {
      // Both terms are literal hits in their entry's title, section and
      // procedure, so both entries match; E-305 leads because "belt" is also
      // repeated in its symptom prose, which bm25 weights above the procedure.
      final ids = await search('belt brake');
      expect(ids.first, 'apex_9_err_305');
      expect(ids, containsAll(<String>['apex_9_err_102', 'apex_9_err_305']));
    });

    test('unknown terms return no rows rather than throwing', () async {
      expect(await search('unknown machinery broken'), isEmpty);
    });

    test('limit caps the result set', () async {
      expect(await search('squeal', limit: 1), hasLength(1));
    });

    test('blank input returns no rows without touching MATCH', () async {
      // An empty MATCH expression is itself an FTS5 syntax error, so the guard
      // in searchManualEntries must short-circuit before the query runs.
      expect(await search('   '), isEmpty);
      expect(await search('?!?'), isEmpty);
    });
  });

  group('fault-code lookup (structured, not FTS)', () {
    setUp(seed);

    // TC-FTS-MATCH-02: exact match on the structured column.
    test('exact code lookup returns the entry', () async {
      final row = await db.manualEntryByCode('E-204');

      expect(row?.id, 'apex_9_err_204');
    });

    test('lookup normalizes case and surrounding whitespace', () async {
      expect((await db.manualEntryByCode('  e-204 '))?.id, 'apex_9_err_204');
    });

    test('unknown or blank code yields null', () async {
      expect(await db.manualEntryByCode('E-999'), isNull);
      expect(await db.manualEntryByCode('   '), isNull);
    });

    test('the code column is not part of the FTS index', () async {
      // The invariant the plan asks for: `code` is a structured column, so it is
      // not an fts5 column at all. A column-filtered MATCH against it is a
      // hard error, which is the only way to assert its absence — note that the
      // code *text* is still findable through prose (the symptom paragraphs
      // repeat "fault code E-102"), so a plain search proves nothing here.
      await expectLater(
        db
            .customSelect(
              'SELECT * FROM manual_fts WHERE manual_fts MATCH ?1',
              variables: [Variable<String>('code:"E-102"')],
            )
            .get(),
        throwsA(isA<SqliteException>()),
      );
    });

    test('the lookup uses the code index rather than scanning', () async {
      // Explains the SQL `manualEntryByCode` *actually emits*, not a hand-written
      // equivalent: explaining a literal string would stay green if the method
      // regressed to `upper(code)`, since the string would still say `code = ?`.
      final context = db.manualEntryByCodeQuery('E-204').constructQuery();

      // The regression this guards: any function around the column makes the
      // index unusable. Matched case-insensitively — drift emits `UPPER(`, so a
      // lower-case-only matcher would accept the very mutation it exists to
      // catch — and the bare column comparison is asserted positively, since
      // `UPPER("code") = ?` contains `"code"` but not `"code" =`.
      expect(context.sql.toLowerCase(), isNot(contains('upper(')));
      expect(context.sql, contains('"code" ='));

      final plan = await db
          .customSelect(
            'EXPLAIN QUERY PLAN ${context.sql}',
            variables: context.boundVariables
                .map((v) => Variable<Object>(v as Object))
                .toList(),
          )
          .get();

      expect(
        plan.map((r) => r.read<String>('detail')).join('\n'),
        contains('idx_manual_entries_code'),
      );
    });

    test('a code stored in lower case is still found', () async {
      // The one scenario that justifies COLLATE NOCASE over a plain `.equals()`:
      // a write path that skips `upsertManualEntries` (Task 1.3's seeder is the
      // obvious candidate) and therefore never canonicalises the code. Inserting
      // through `into(...)` deliberately bypasses normalizeFaultCode, so the
      // collation is the only thing that can make this match.
      await db
          .into(db.manualEntries)
          .insert(
            _seedEntries.first.copyWith(id: 'apex_9_err_666', code: 'e-666'),
          );

      final stored = await db.select(db.manualEntries).get();
      expect(
        stored.firstWhere((r) => r.id == 'apex_9_err_666').code,
        'e-666',
        reason:
            'the row must really be stored lower-case for this to mean '
            'anything',
      );

      expect((await db.manualEntryByCode('E-666'))?.id, 'apex_9_err_666');
    });

    test('the code column is NOT NULL', () async {
      // `customConstraint` replaces drift's entire generated constraint string,
      // so NOT NULL is restated by hand there — a typo would drop it silently
      // along with the collation.
      await expectLater(
        db.customStatement(
          "INSERT INTO manual_entries "
          '(id, section, code, title, symptoms, procedure) '
          "VALUES ('x', 's', NULL, 't', 'sy', 'p')",
        ),
        throwsA(isA<SqliteException>()),
      );
    });

    test('stored codes are canonicalised on write', () async {
      await db.upsertManualEntries([
        _seedEntries.first.copyWith(id: 'apex_9_err_777', code: ' e-777 '),
      ]);

      final row = await db.manualEntryByCode('E-777');
      expect(row?.code, 'E-777');
    });
  });

  group('sanitizer', () {
    setUp(seed);

    // TC-FTS-SAN-01: hostile punctuation must not reach the FTS5 parser.
    test(
      'hostile input does not throw and still finds the door entry',
      () async {
        const hostile = 'door won\'t close - "stuck" (E-305)';

        // The raw string really is a syntax error — this is the bug being fixed.
        await expectLater(
          db.searchManualEntriesRanked(hostile, 10).get(),
          throwsA(isA<SqliteException>()),
        );

        // Sanitized, the same input runs and ranks the door entry first.
        final ids = await search(hostile);
        expect(ids, isNotEmpty);
        expect(ids.first, 'apex_9_err_305');
      },
    );

    // TC-FTS-SAN-02: FTS5 operator words are neutralised into plain terms.
    test('operator words are searched literally', () async {
      const operators = 'belt AND door OR NEAR';

      final ids = await search(operators);
      expect(ids, contains('apex_9_err_305'));

      // Every term is quoted, so nothing is left to parse as an operator.
      expect(
        FtsQuerySanitizer.sanitize(operators),
        '"belt" OR "AND" OR "door" OR "OR" OR "NEAR"',
      );
    });

    test('term-list search is guarded for a router that consumes the code', () async {
      // The Task 1.4 shape: extract "E-102", handle it structurally, search on
      // what is left. When the input is *only* a code there is nothing left, and
      // an empty MATCH expression is an FTS5 syntax error — so the guard has to
      // live on this path too, not only on the raw-text one.
      final terms = FtsQuerySanitizer.terms('E-102');
      expect(terms, ['E-102']);

      // Both reach the empty-expression guard: `sanitizeTerms` normalises each
      // incoming term the same way raw text is normalised, so a whitespace-only
      // term disappears rather than becoming the phrase `"   "`.
      expect(FtsQuerySanitizer.sanitizeTerms(const ['   ']), isEmpty);
      expect(await db.searchManualEntriesByTerms(const []), isEmpty);
      expect(await db.searchManualEntriesByTerms(const ['   ']), isEmpty);

      // The generated query is the path that has no guard — proving the guard is
      // load-bearing rather than defensive decoration.
      await expectLater(
        db.searchManualEntriesRanked('', 10).get(),
        throwsA(isA<SqliteException>()),
      );

      // With residual terms it behaves like the raw-text entry point.
      final ids = await db.searchManualEntriesByTerms(['squealing', 'belt']);
      expect(ids.map((r) => r.id), contains('apex_9_err_305'));
    });

    test('sanitizes syntax characters out of terms', () async {
      expect(
        FtsQuerySanitizer.sanitize('door won\'t close - "stuck" (E-305)'),
        '"door" OR "won\'t" OR "close" OR "stuck" OR "E-305"',
      );
    });

    test('column filters, wildcards and quotes cannot escape a term', () {
      expect(
        FtsQuerySanitizer.sanitize('symptoms:brake* OR "x" ^start'),
        '"symptoms" OR "brake" OR "OR" OR "x" OR "start"',
      );
    });

    test('input with no searchable term sanitizes to empty', () {
      expect(FtsQuerySanitizer.sanitize(''), isEmpty);
      expect(FtsQuerySanitizer.sanitize('  \n\t '), isEmpty);
      expect(FtsQuerySanitizer.sanitize('()*:^-- ""'), isEmpty);
    });

    test('keeps intra-word hyphens and apostrophes, drops edge ones', () {
      expect(FtsQuerySanitizer.terms("-lockout-tagout- 'won't'"), [
        'lockout-tagout',
        "won't",
      ]);
    });

    test('unicode letters and digits survive', () {
      expect(FtsQuerySanitizer.terms('winda głośno piszczy 305'), [
        'winda',
        'głośno',
        'piszczy',
        '305',
      ]);
    });

    test('term count is capped', () {
      final many = List.generate(
        FtsQuerySanitizer.maxTerms + 20,
        (i) => 'term$i',
      ).join(' ');

      expect(
        FtsQuerySanitizer.terms(many),
        hasLength(FtsQuerySanitizer.maxTerms),
      );
    });

    test('a hand-built term with syntax in it cannot inject', () async {
      // terms() can never emit a double quote, but sanitizeTerms is public for
      // the retrieval router (Task 1.4), so it normalises what it is given: the
      // quote is stripped rather than merely escaped, and the operator word ends
      // up quoted like any other term.
      expect(
        FtsQuerySanitizer.sanitizeTerms(['a" OR b']),
        '"a" OR "OR" OR "b"',
      );

      // A caller-supplied phrase is split into terms rather than trusted.
      expect(
        FtsQuerySanitizer.sanitizeTerms(['door belt', 'brake*']),
        '"door" OR "belt" OR "brake"',
      );

      // And the cap applies to caller-supplied lists too.
      expect(
        FtsQuerySanitizer.sanitizeTerms(
          List.generate(FtsQuerySanitizer.maxTerms + 5, (i) => 'term$i'),
        ).split(' OR '),
        hasLength(FtsQuerySanitizer.maxTerms),
      );

      await expectLater(
        db.searchManualEntriesByTerms(['a" OR b', 'NEAR(x y, 2)']),
        completes,
      );
    });

    test('combining marks stay attached to their term', () {
      // Decomposed "café" — `e` plus U+0301 COMBINING ACUTE ACCENT. Without
      // \p{M} in the allowlist the mark is stripped and the term silently
      // becomes "cafe", tokenizing differently from the composed form.
      // Escapes, not literal marks, so the decomposition survives editing.
      expect(FtsQuerySanitizer.terms('cafe\u0301 brake'), [
        'cafe\u0301',
        'brake',
      ]);

      // A chunk of marks with no letter or digit is still dropped.
      expect(FtsQuerySanitizer.terms('\u0301\u0308'), isEmpty);
    });

    test('every sanitized query is accepted by FTS5', () async {
      const hostileInputs = [
        'door won\'t close - "stuck" (E-305)',
        'belt AND door OR NEAR',
        'NOT belt',
        'brake*',
        'symptoms:brake',
        '"unterminated phrase',
        'a OR (b AND c',
        'NEAR(belt door, 3)',
        r'^title door',
        'E-305 -- comment',
        "100%'; DROP TABLE manual_entries;--",
      ];

      for (final input in hostileInputs) {
        await expectLater(
          db.searchManualEntries(input),
          completes,
          reason: 'sanitized query for "$input" must be valid FTS5',
        );
      }

      // The injection attempt above must not have destroyed anything.
      expect(await db.manualFtsIndexedDocumentCount(), 3);
      expect(await db.select(db.manualEntries).get(), hasLength(3));
    });
  });

  group('list columns', () {
    setUp(seed);

    test('required tools and parts round-trip as decoded lists', () async {
      final row = await db.manualEntryByCode('E-102');

      expect(row!.requiredPartsList, ['BRK-990-XP']);
      expect(row.requiredToolsList, [
        'Torx T20',
        'Digital Caliper',
        'Lockout Tagout Kit',
      ]);
    });

    test('malformed list JSON degrades to an empty list', () async {
      await db.upsertManualEntries([
        _seedEntries.first.copyWith(
          id: 'apex_9_err_888',
          code: 'E-888',
          requiredParts: 'not json',
        ),
      ]);

      final row = await db.manualEntryByCode('E-888');
      expect(row!.requiredPartsList, isEmpty);
    });
  });
}

/// The three Apex-9 manual entries from `assets/elevator_manual_seed.json`.
/// Inlined rather than loaded from the asset bundle: asset loading is Task 1.3's
/// concern, and these tests must pin the index behaviour, not the loader.
final List<ManualEntryRow> _seedEntries = [
  ManualEntryRow(
    id: 'apex_9_err_102',
    section: 'Brake Systems',
    code: 'E-102',
    title: 'Traction Brake Pad Wear & Vibration',
    symptoms:
        'High-pitched squealing during deceleration, cabin vibration at '
        'terminal landings, fault code E-102 displayed on machine room '
        'controller.',
    procedure:
        '1. Isolate the main elevator power bus. 2. Lockout/tagout machine room '
        'breaker 4A. 3. Remove the magnetic brake cowl using a Torx T20 driver. '
        '4. Inspect brake pad wear indicators. If thickness is less than 2.0mm, '
        'replace the assemblies. 5. Adjust caliper clearance to exactly 0.5mm.',
    requiredTools: encodeStringList([
      'Torx T20',
      'Digital Caliper',
      'Lockout Tagout Kit',
    ]),
    requiredParts: encodeStringList(['BRK-990-XP']),
  ),
  ManualEntryRow(
    id: 'apex_9_err_204',
    section: 'Hydraulics & Valving',
    code: 'E-204',
    title: 'Proportional Valve Flow Discrepancy',
    symptoms:
        'Levelling inaccuracies exceeding 5mm, rough ride transitions, '
        'temperature warning E-204 on hydraulic manifold ledger.',
    procedure:
        '1. Read hydraulic oil temperature from manifold gauge. 2. If '
        'temperature is above 60C, activate the cooling bypass valve. '
        '3. Inspect proportional valve solenoid connections for resistance '
        'drift. 4. Clean pilot valve filter mesh with isopropyl spray. '
        '5. Recalibrate flow curves using the console controller.',
    requiredTools: encodeStringList([
      'Multimeter',
      'Hex Key 5mm',
      'Isopropyl Cleaner',
    ]),
    requiredParts: encodeStringList(['FLT-440-HYD']),
  ),
  ManualEntryRow(
    id: 'apex_9_err_305',
    section: 'Door Operators',
    code: 'E-305',
    title: 'Door Clutches & Belt Slippage',
    symptoms:
        'Elevator doors cycle three times and throw obstruction warning, belt '
        'squealing during door open sequences, fault code E-305.',
    procedure:
        '1. Switch door operator controller to Manual. 2. Check door clutch '
        'alignment relative to hoistway rollers; gap must be 6mm. 3. Inspect '
        'operator belt tension; tighten tension bolt by 2 full rotations if '
        'slack exceeds 10mm. 4. Clean optical door curtain lenses with a '
        'microfiber cloth.',
    requiredTools: encodeStringList([
      'Microfiber Cloth',
      'Wrench 10mm',
      'Steel Ruler',
    ]),
    requiredParts: encodeStringList(['BELT-330-DRV']),
  ),
];
