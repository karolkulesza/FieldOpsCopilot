import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart' show NativeDatabase;
import 'package:field_ops_copilot/services/database/database_initializer.dart';
import 'package:field_ops_copilot/services/database/database_service.dart';
import 'package:field_ops_copilot/services/database/seed_data.dart';
import 'package:field_ops_copilot/services/database/tables.dart'
    show kPartNameMaxLength, kSkuMaxLength;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Unit-tier coverage for the seeding engine and the parts inventory.
///
/// Runs against a real encrypted database with the real FTS5 module, like
/// `manual_fts_test.dart`: the loader's contract is "the manual is searchable and the
/// inventory is queryable afterwards", and a faked database would assert only that
/// the loader called the methods this test file already knows it calls.
void main() {
  late Directory tempDir;
  late DatabaseService db;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('fieldops_seed_test');
    db = DatabaseService.encrypted(
      file: File('${tempDir.path}/seed.db'),
      encryptionKey: 'seed-test-key',
    );
  });

  tearDown(() async {
    await db.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  DatabaseInitializer initializerFor(String json, {String? seedId}) =>
      DatabaseInitializer(
        database: db,
        source: _TextSeedSource(json, seedId: seedId ?? 'test_seed'),
      );

  Future<List<String>> search(String raw) async {
    final rows = await db.searchManualEntries(raw);
    return rows.map((r) => r.id).toList();
  }

  group('TC-SEED-INIT-01 first-launch seed', () {
    test('a clean database gets 3 manuals and 5 inventory rows', () async {
      final outcome = await initializerFor(_fixtureJson()).ensureSeeded();

      expect(outcome, isA<SeedApplied>());
      final applied = outcome as SeedApplied;
      expect(applied.wasFirstLaunch, isTrue);
      expect(applied.previousRevision, isNull);
      expect(applied.manualEntries, 3);
      expect(applied.inventoryParts, 5);

      // The manual count is read from the FTS *index* (`manual_fts_docsize`), per
      // the rule carried forward from 1.2: `COUNT(*) FROM manual_fts` is answered
      // from the content table on an external-content index, so it stays at 3 with
      // the index empty or double-populated.
      //
      // Being honest about what this pair buys *here*: on a clean database the two
      // counts move together, because any insert statement fires the sync trigger.
      // So this is a regression guard, not a discriminating assertion — what
      // discriminates is the per-document search below (index populated) and the
      // re-seed test in the next group (index not double-populated).
      expect(await db.manualFtsIndexedDocumentCount(), 3);
      expect(await db.select(db.manualEntries).get(), hasLength(3));
      expect(await db.allInventoryParts(), hasLength(5));

      // ...and each seeded manual is individually reachable through the index,
      // which a count alone cannot show.
      expect(await search('traction'), ['apex_9_err_102']);
      expect(await search('proportional'), ['apex_9_err_204']);
      expect(await search('clutches'), ['apex_9_err_305']);
    });

    test('fault codes are stored canonically, so exact lookup matches', () async {
      // The fixture writes ` e-102 ` — lower-case and padded — which is what a
      // hand-authored or dictated asset looks like. Without canonicalisation the
      // seeded row is unreachable: the column's NOCASE collation covers the case
      // but not the surrounding whitespace.
      //
      // What this pins, measured rather than assumed: the **end-to-end outcome**,
      // and nothing narrower. Canonicalisation happens twice on purpose — in
      // `SeedBundle.parse` and again in `upsertManualEntries` — and removing
      // either one leaves this test green, because the survivor still does the
      // job. Verified both ways round by mutation.
      //
      // So the redundancy is real defence in depth rather than a claim, and each
      // layer is pinned by its own assertion elsewhere: the parser by "parsed rows
      // are already canonical" below, the database by the FTS suite's "stored
      // codes are canonicalised on write". Deleting *both* fails this test.
      await initializerFor(_fixtureJson()).ensureSeeded();

      expect((await db.manualEntryByCode('E-102'))?.id, 'apex_9_err_102');
      expect((await db.manualEntryByCode('e-102'))?.id, 'apex_9_err_102');

      final stored = await db.manualEntryByCode('E-102');
      expect(stored?.code, 'E-102');
    });

    test('required tools and parts survive as decodable lists', () async {
      // TC-RAG-COMP-02 asserts a tool name and a part SKU reach the prompt,
      // so the seed has to land them in a form `ManualEntryLists` can decode —
      // not, say, a JSON-encoded string of a JSON string.
      await initializerFor(_fixtureJson()).ensureSeeded();

      final entry = await db.manualEntryByCode('E-305');
      expect(entry?.requiredToolsList, contains('Wrench 10mm'));
      expect(entry?.requiredPartsList, ['BELT-330-DRV']);
    });

    test('nothing is written when the asset is malformed', () async {
      await expectLater(
        initializerFor('{"revision": 1}').ensureSeeded(),
        throwsA(isA<SeedFormatException>()),
      );

      expect(await db.select(db.manualEntries).get(), isEmpty);
      expect(await db.allInventoryParts(), isEmpty);
      expect(await db.seedMarker('test_seed'), isNull);
    });

    test('a failure mid-write rolls the whole seed back', () async {
      // Failure is injected at the *last* step — after both datasets are in and
      // after the marker has been written — which is the worst case the transaction
      // exists for. Both bad end states are then reachable and asserted against:
      // rows without a marker (re-seeds forever) and a marker vouching for rows that
      // were rolled back (never seeds again).
      //
      // The injection writes the marker before throwing precisely so the marker
      // assertion below discriminates. An override that merely *replaced*
      // `recordSeedMarker` would leave the row absent whether or not the transaction
      // rolled back, making that expectation unfailable — which is what a first
      // version of this test did.
      //
      // Deliberately not driven by drift's `withLength` check any more: length
      // validation moved into the parser, so an over-length name now fails
      // before the transaction opens and could not reach this code path. Injecting
      // the failure directly also stops this test from silently becoming a test of
      // whichever column constraint happens to fire first.
      final failing = _MarkerFailingDatabase();
      addTearDown(failing.close);

      await expectLater(
        DatabaseInitializer(
          database: failing,
          source: _TextSeedSource(_fixtureJson(), seedId: 'test_seed'),
        ).ensureSeeded(),
        throwsA(isA<StateError>()),
      );

      // Marker first, deliberately. It is the assertion whose liveness is easiest
      // to lose and hardest to see: with the rows asserted first, a mutation that
      // keeps everything would fail on the rows and never reach here, so ordering it
      // first is what makes `transaction` removal fail *on this line* — checked.
      expect(await failing.seedMarker('test_seed'), isNull);
      expect(await failing.select(failing.manualEntries).get(), isEmpty);
      expect(await failing.manualFtsIndexedDocumentCount(), 0);
      expect(await failing.allInventoryParts(), isEmpty);
    });
  });

  group('TC-SEED-IDEM-01 idempotent seed', () {
    test('seeding twice leaves the counts and the index unchanged', () async {
      final initializer = initializerFor(_fixtureJson());

      expect(await initializer.ensureSeeded(), isA<SeedApplied>());
      final second = await initializer.ensureSeeded();

      expect(second, isA<SeedSkipped>());
      expect((second as SeedSkipped).storedRevision, 1);

      expect(await db.manualFtsIndexedDocumentCount(), 3);
      expect(await db.select(db.manualEntries).get(), hasLength(3));
      expect(await db.allInventoryParts(), hasLength(5));

      // A duplicated document would return the same id twice.
      expect(await search('traction'), ['apex_9_err_102']);
      expect(await search('squeal'), hasLength(2));
    });

    test('the write path is idempotent on its own, not just the marker', () async {
      // The assertion above passes for two independent reasons — the marker
      // short-circuits the second run, *and* the writes are upserts. If only the
      // marker did the work, a re-seed at a bumped revision (the one path that
      // deliberately writes over existing rows) would double everything. So drive
      // the write path twice, with no marker to hide behind.
      await initializerFor(_fixtureJson()).ensureSeeded();
      final again = await initializerFor(
        _fixtureJson(revision: 2),
      ).ensureSeeded();

      expect(again, isA<SeedApplied>());
      expect((again as SeedApplied).previousRevision, 1);
      expect(again.wasFirstLaunch, isFalse);

      expect(await db.manualFtsIndexedDocumentCount(), 3);
      expect(await db.select(db.manualEntries).get(), hasLength(3));
      expect(await db.allInventoryParts(), hasLength(5));
      expect(await search('traction'), ['apex_9_err_102']);
    });

    test('a re-seed leaves no stale terms in the FTS index', () async {
      // The reason the loader must use `upsertManualEntries` rather than an
      // `INSERT OR REPLACE`: with `recursive_triggers` off (SQLite's default) the
      // implicit delete inside OR REPLACE fires no delete trigger, so the old
      // terms stay in the index and only a term-level assertion notices.
      // `insertAllOnConflictUpdate` emits `ON CONFLICT DO UPDATE`, which fires the
      // update trigger and unwinds them.
      await initializerFor(_fixtureJson()).ensureSeeded();
      // "ledger" occurs *only* in E-204's symptom prose — not in its title,
      // section or procedure — so it is the one term whose disappearance can only
      // mean the old row was unindexed. ("manifold" would not do: the procedure
      // says it too, so it survives a correct update and the assertion would fail
      // for a reason unrelated to the trigger.)
      expect(await search('ledger'), ['apex_9_err_204']);

      await initializerFor(
        _fixtureJson(
          revision: 2,
          manualsOverride: _rewriteSymptoms(
            'apex_9_err_204',
            'Cabin overshoots the sill by a hair; nothing else to report.',
          ),
        ),
      ).ensureSeeded();

      expect(await search('ledger'), isEmpty);
      // And the replacement's own terms were indexed — "overshoots" appears
      // nowhere in the fixture but the new prose, so the insert half of the
      // trigger is asserted as well as the delete half.
      expect(await search('overshoots'), ['apex_9_err_204']);
      expect(await db.manualFtsIndexedDocumentCount(), 3);
    });

    test('a re-seed is upsert-shaped, not replace-shaped', () async {
      // Pins the two limits of a revision bump that the README now states,
      // because both are easy to assume the other way round and downstream
      // layers may lean on them.
      await initializerFor(_fixtureJson()).ensureSeeded();

      await initializerFor(
        _fixtureJson(
          revision: 2,
          // E-204 dropped from the asset entirely...
          manualsOverride: _defaultManuals()
              .where((m) => m['id'] != 'apex_9_err_204')
              .toList(growable: false),
          // ...and BRK-990-XP re-sent with `location` omitted.
          partsOverride: [
            {
              'sku': 'BRK-990-XP',
              'name': 'Traction Brake Pad Assembly',
              'stock': 9,
            },
          ],
        ),
      ).ensureSeeded();

      // A dropped row is not deleted, and its FTS terms stay searchable.
      expect(await db.manualEntryByCode('E-204'), isNotNull);
      expect(await search('ledger'), ['apex_9_err_204']);
      expect(await db.manualFtsIndexedDocumentCount(), 3);

      // A re-sent row's present columns are overwritten...
      final part = await db.inventoryPartBySku('BRK-990-XP');
      expect(part?.stock, 9);
      // ...and an omitted nullable column keeps its old value rather than being
      // cleared, because drift leaves an absent column out of the DO UPDATE SET.
      expect(part?.location, 'Aisle 4, Shelf B');

      // Parts dropped from the asset survive too, so the count does not shrink.
      expect(await db.allInventoryParts(), hasLength(5));
    });

    test('a lower asset revision does not re-seed', () async {
      await initializerFor(_fixtureJson(revision: 7)).ensureSeeded();

      final outcome = await initializerFor(
        _fixtureJson(revision: 3),
      ).ensureSeeded();

      expect(outcome, isA<SeedSkipped>());
      expect((outcome as SeedSkipped).storedRevision, 7);
      expect(await db.select(db.manualEntries).get(), hasLength(3));
    });

    test('a skipped seed preserves stock a technician changed', () async {
      // The point of the marker, stated as the behaviour it protects. Re-running
      // the seed on every launch would silently roll consumption back.
      await initializerFor(_fixtureJson()).ensureSeeded();
      await db.upsertInventoryParts([
        (await db.inventoryPartBySku('BRK-990-XP'))!.copyWith(stock: 0),
      ]);

      await initializerFor(_fixtureJson()).ensureSeeded();

      expect((await db.inventoryPartBySku('BRK-990-XP'))?.stock, 0);
    });

    test('the marker records the revision that was applied', () async {
      await initializerFor(_fixtureJson(revision: 4)).ensureSeeded();

      final marker = await db.seedMarker('test_seed');
      expect(marker?.revision, 4);
      expect(marker?.id, 'test_seed');
    });

    test('markers are per dataset, so a second source seeds too', () async {
      await initializerFor(_fixtureJson(), seedId: 'first').ensureSeeded();

      final outcome = await initializerFor(
        _fixtureJson(),
        seedId: 'second',
      ).ensureSeeded();

      expect(outcome, isA<SeedApplied>());
      expect((outcome as SeedApplied).wasFirstLaunch, isTrue);
    });
  });

  group('TC-INV-QRY-01 inventory by SKU', () {
    setUp(() => initializerFor(_fixtureJson()).ensureSeeded());

    test('BRK-990-XP reports its stock and location', () async {
      final part = await db.inventoryPartBySku('BRK-990-XP');

      expect(part?.stock, 2);
      expect(part?.location, 'Aisle 4, Shelf B');
      expect(part?.name, 'Traction Brake Pad Assembly');
    });

    test('lookup tolerates the casing and padding a model emits', () async {
      // In production the SKU arrives inside a model-emitted function call, so
      // its shape is whatever the weights produced.
      //
      // All three of these are `normalizeSku` doing the work, on both the write
      // and the read side — **not** the column's collation. Verified by mutation:
      // dropping `COLLATE NOCASE` leaves this test green, because the seed stored
      // `BRK-990-XP` upper-cased and the lookup upper-cases its argument too, so
      // the comparison is already exact. The collation earns its place against
      // rows written by some other path, which is the next test.
      expect((await db.inventoryPartBySku('brk-990-xp'))?.stock, 2);
      expect((await db.inventoryPartBySku('  BRK-990-XP  '))?.stock, 2);
      expect((await db.inventoryPartBySku(' Brk-990-Xp '))?.stock, 2);
    });

    test('upsertInventoryParts canonicalises the SKU it stores', () async {
      // The write side of `normalizeSku` had no regression guard: deleting
      // it from `upsertInventoryParts` left all 269 tests green, because every SKU
      // reaching that method in this suite had already been canonicalised by
      // `SeedBundle.parse`, and the one test that writes a non-canonical SKU (the
      // next one) goes through `customStatement` and bypasses the method entirely.
      //
      // That gap mattered because this layer is documented as the *primary*
      // mechanism and the collation only a backstop — and the collation genuinely
      // cannot cover this case: whitespace survives NOCASE, so the row would be
      // permanently unreachable. `upsertInventoryParts` is public API and the
      // seed parser is not its only caller: the SKU also arrives from the
      // model's tool calls, and by voice from speech.
      await db.upsertInventoryParts([
        const InventoryPartRow(
          sku: '  lot-888-pad  ',
          name: 'Padded Write Part',
          stock: 7,
          location: 'Aisle 7',
        ),
      ]);

      // Both halves. The *stored* form is canonical...
      expect(
        (await db.allInventoryParts()).map((p) => p.sku),
        contains('LOT-888-PAD'),
        reason: 'the write path is what makes the stored form canonical',
      );
      // ...and the canonical lookup therefore reaches it. Without write-side
      // normalisation the row is stored as `"  lot-888-pad  "` and this is null.
      expect((await db.inventoryPartBySku('LOT-888-PAD'))?.stock, 7);
    });

    test(
      'a row written past normalizeSku is still found, via the collation',
      () async {
        // This is the assertion `COLLATE NOCASE` actually buys, and the only one in
        // the file that fails if the collation is removed. A raw insert — a future
        // migration, a sync path, a hand-fixed database — stores a SKU
        // un-normalised; the canonical lookup must still reach it.
        await db.customStatement(
          'INSERT INTO inventory_parts (sku, name, stock, location) '
          "VALUES ('lot-777-raw', 'Raw-written Part', 4, 'Aisle 9')",
        );

        final part = await db.inventoryPartBySku('LOT-777-RAW');

        expect(part?.stock, 4);
        expect(part?.sku, 'lot-777-raw', reason: 'stored form is left alone');
      },
    );

    test('an unknown SKU returns null rather than throwing', () async {
      // A model can invent a SKU; that is a normal tool result, not an error.
      expect(await db.inventoryPartBySku('NOPE-000'), isNull);
      expect(await db.inventoryPartBySku('   '), isNull);
    });

    test('a zero-stock part is found, and reads as zero', () async {
      // Distinct from "not found", and the distinction is the whole answer the
      // agent gives for an out-of-stock part.
      final part = await db.inventoryPartBySku('BELT-330-DRV');

      expect(part, isNotNull);
      expect(part?.stock, 0);
    });

    test('the lookup uses the primary-key index, not a table scan', () async {
      // Guards the reason `sku` carries `COLLATE NOCASE` instead of the query
      // wrapping the column in `upper(...)`: the collation keeps equality
      // index-searchable. Asserting the plan of the SQL drift *actually emits*,
      // because a hand-written equivalent would keep passing if
      // `inventoryPartBySkuQuery` regressed.
      final statement = db.inventoryPartBySkuQuery('BRK-990-XP');
      final ctx = statement.constructQuery();
      final plan = await db
          .customSelect(
            'EXPLAIN QUERY PLAN ${ctx.sql}',
            variables: ctx.boundVariables
                .map((v) => Variable<Object>(v))
                .toList(),
          )
          .get();
      final detail = plan.map((r) => r.read<String>('detail')).join('\n');

      expect(detail, contains('inventory_parts'));
      expect(detail, contains('USING'));
      expect(detail, isNot(contains('SCAN')));
    });
  });

  group('the shipped asset', () {
    // The fixtures above prove the loader works on *a* well-formed asset. This
    // group proves the file the app actually bundles is that asset — otherwise the
    // whole suite stays green while the shipped JSON is a broken array, and the
    // failure surfaces on the demo device.
    late String shippedJson;

    setUpAll(() async {
      shippedJson = await File(
        'assets/elevator_manual_seed.json',
      ).readAsString();
    });

    test('parses, and carries the counts the ACs name', () {
      final bundle = SeedBundle.parse(shippedJson);

      expect(bundle.manualEntries, hasLength(3));
      expect(bundle.inventoryParts, hasLength(5));
      expect(bundle.revision, greaterThanOrEqualTo(1));
    });

    test('seeds the database the ACs describe', () async {
      final outcome = await DatabaseInitializer(
        database: db,
        source: _TextSeedSource(shippedJson, seedId: 'elevator_manual_seed'),
      ).ensureSeeded();

      expect((outcome as SeedApplied).manualEntries, 3);
      expect(outcome.inventoryParts, 5);
      expect(await db.manualFtsIndexedDocumentCount(), 3);

      // TC-INV-QRY-01's exact expectation, against the real asset.
      final part = await db.inventoryPartBySku('BRK-990-XP');
      expect(part?.stock, 2);
      expect(part?.location, 'Aisle 4, Shelf B');

      // The fault codes the retrieval ACs (1.4) will look up.
      for (final code in const ['E-102', 'E-204', 'E-305']) {
        expect(await db.manualEntryByCode(code), isNotNull, reason: code);
      }
    });

    test('every part a manual requires is actually stocked', () async {
      // A manual referencing a SKU the inventory does not hold would make the
      // agent loop's tool call return null for a part the answer just recommended.
      final bundle = SeedBundle.parse(shippedJson);
      final stocked = bundle.inventoryParts.map((p) => p.sku).toSet();

      for (final entry in bundle.manualEntries) {
        for (final sku in entry.requiredPartsList) {
          expect(stocked, contains(sku), reason: '${entry.id} requires $sku');
        }
      }
    });

    test('the bundled asset is reachable under its declared key', () async {
      // `AssetBundleSeedSource`'s default key has to match `pubspec.yaml`. A typo
      // there is invisible to every other test in this file, which supplies text
      // directly, and fails only at runtime.
      final bundle = _FakeAssetBundle({
        AssetBundleSeedSource.defaultAssetKey: shippedJson,
      });

      final source = AssetBundleSeedSource(bundle: bundle);
      expect(await source.loadSeedJson(), shippedJson);
      expect(source.seedId, 'elevator_manual_seed');

      final missing = AssetBundleSeedSource(
        bundle: bundle,
        assetKey: 'assets/not_there.json',
      );
      await expectLater(missing.loadSeedJson(), throwsA(anything));
    });

    test('the declared key is the one pubspec.yaml bundles', () async {
      final pubspec = await File('pubspec.yaml').readAsString();

      expect(pubspec, contains(AssetBundleSeedSource.defaultAssetKey));
    });
  });

  group('seed asset validation', () {
    void rejects(String label, String json, {String? because}) {
      test(label, () {
        expect(
          () => SeedBundle.parse(json),
          throwsA(isA<SeedFormatException>()),
          reason: because,
        );
      });
    }

    rejects('a bare array root', '[]');
    rejects('invalid JSON', '{not json');
    rejects('a missing revision', '{"manual_entries":[],"inventory_parts":[]}');
    rejects(
      'a non-integer revision',
      '{"revision":"1","manual_entries":[],"inventory_parts":[]}',
    );
    rejects('a missing manual dataset', '{"revision":1,"inventory_parts":[]}');
    rejects(
      'a missing inventory dataset',
      '{"revision":1,"manual_entries":[]}',
    );
    rejects(
      'a manual entry that is not an object',
      '{"revision":1,"manual_entries":["nope"],"inventory_parts":[]}',
    );

    rejects(
      'a manual entry missing its procedure',
      _fixtureJson(
        manualsOverride: [
          {
            'id': 'x',
            'section': 's',
            'code': 'E-1',
            'title': 't',
            'symptoms': 'y',
          },
        ],
      ),
    );

    rejects(
      'a blank fault code',
      _fixtureJson(manualsOverride: [_manual('x', code: '   ')]),
      because:
          'normalizeFaultCode trims it to "", and manualEntryByCode '
          'short-circuits an empty code to null — the row would be unreachable',
    );

    rejects(
      'a blank SKU',
      _fixtureJson(
        partsOverride: [
          {'sku': ' ', 'name': 'n', 'stock': 1},
        ],
      ),
    );

    rejects(
      'a duplicate manual id',
      _fixtureJson(manualsOverride: [_manual('dup'), _manual('dup')]),
      because: 'the upsert is last-write-wins, so it would seed one row short',
    );

    rejects(
      'a duplicate SKU',
      _fixtureJson(
        partsOverride: [
          {'sku': 'A-1', 'name': 'n', 'stock': 1},
          {'sku': 'a-1', 'name': 'm', 'stock': 2},
        ],
      ),
      because:
          'SKUs are canonicalised before the duplicate check, so these '
          'two collide on the primary key',
    );

    rejects(
      'a non-integer stock',
      _fixtureJson(
        partsOverride: [
          {'sku': 'A-1', 'name': 'n', 'stock': '2'},
        ],
      ),
    );

    rejects(
      'a negative stock',
      _fixtureJson(
        partsOverride: [
          {'sku': 'A-1', 'name': 'n', 'stock': -1},
        ],
      ),
    );

    rejects(
      'a required_tools entry that is not a string',
      _fixtureJson(
        manualsOverride: [
          {
            ..._manual('x'),
            'required_tools': [42],
          },
        ],
      ),
      because:
          'silently dropping it would make an asset typo indistinguishable '
          'from a procedure that needs no tools',
    );

    // These two bounds are what make the parser's promise true.
    // Drift declares them with `withLength`, whose check runs in
    // `validateIntegrity` at *insert* time — inside the seeding transaction, i.e.
    // too late to be a parse error. Both are validated here against the same
    // constants the columns use, so the two cannot drift apart.
    rejects(
      'a part name longer than the column stores',
      _fixtureJson(
        partsOverride: [
          {'sku': 'A-1', 'name': 'x' * (kPartNameMaxLength + 1), 'stock': 1},
        ],
      ),
      because: 'drift would otherwise reject it mid-transaction instead',
    );

    rejects(
      'a SKU longer than the column stores',
      _fixtureJson(
        partsOverride: [
          {'sku': 'S' * (kSkuMaxLength + 1), 'name': 'n', 'stock': 1},
        ],
      ),
    );

    // Named so `tables.dart` can point at it: kSkuMaxLengthAgreesWithColumn.
    test('the parser bounds equal the column bounds', () async {
      // The constants and the `withLength` literals are duplicated by necessity —
      // `drift_dev` reads `withLength`'s arguments from the source expression and
      // silently drops a named constant, emitting `checkTextLength(minTextLength: 1)`
      // with no max and no diagnostic. So the agreement has to be asserted through
      // behaviour: one character past the constant must be rejected *by the column*.
      //
      // Deliberately routed through the database rather than the parser: the parser
      // is what uses the constants, the column is what uses the literals, and this
      // test exists to catch them diverging.
      final tooLongName = 'x' * (kPartNameMaxLength + 1);
      await expectLater(
        () => db.upsertInventoryParts([
          InventoryPartRow(sku: 'LEN-1', name: tooLongName, stock: 1),
        ]),
        throwsA(anything),
        reason:
            'kPartNameMaxLength ($kPartNameMaxLength) is larger than the '
            "column's own limit, or the column lost its max entirely",
      );

      final tooLongSku = 'S' * (kSkuMaxLength + 1);
      await expectLater(
        () => db.upsertInventoryParts([
          InventoryPartRow(sku: tooLongSku, name: 'ok', stock: 1),
        ]),
        throwsA(anything),
        reason:
            'kSkuMaxLength ($kSkuMaxLength) exceeds the column, or the '
            'column lost its max',
      );

      // And exactly at the bound the column accepts, so the constants are not
      // merely *below* the column's limit but equal to it.
      await db.upsertInventoryParts([
        InventoryPartRow(
          sku: 'S' * kSkuMaxLength,
          name: 'x' * kPartNameMaxLength,
          stock: 1,
        ),
      ]);
      expect(
        (await db.inventoryPartBySku('S' * kSkuMaxLength))?.name,
        hasLength(kPartNameMaxLength),
      );
    });

    test('a name at exactly the limit is accepted', () {
      // The bound is inclusive; an off-by-one here would reject a legal asset,
      // which is a worse failure than the one being guarded.
      final bundle = SeedBundle.parse(
        _fixtureJson(
          partsOverride: [
            {'sku': 'A-1', 'name': 'x' * kPartNameMaxLength, 'stock': 1},
          ],
        ),
      );

      expect(bundle.inventoryParts.single.name, hasLength(kPartNameMaxLength));
    });

    rejects(
      'a manual id padded with whitespace',
      _fixtureJson(manualsOverride: [_manual(' padded ')]),
      because:
          'id is the primary key and is deliberately not canonicalised, so '
          '"m1" and "m1 " would pass the duplicate check as distinct rows',
    );

    test('an absent required_tools defaults to an empty list', () {
      final bundle = SeedBundle.parse(
        _fixtureJson(manualsOverride: [_manual('x')]),
      );

      expect(bundle.manualEntries.single.requiredToolsList, isEmpty);
    });

    test('an absent location is allowed and stays null', () {
      final bundle = SeedBundle.parse(
        _fixtureJson(
          partsOverride: [
            {'sku': 'A-1', 'name': 'n', 'stock': 1},
          ],
        ),
      );

      expect(bundle.inventoryParts.single.location, isNull);
    });

    test('parsed rows are already canonical', () {
      final bundle = SeedBundle.parse(
        _fixtureJson(
          manualsOverride: [_manual('x', code: ' e-999 ')],
          partsOverride: [
            {'sku': ' abc-1 ', 'name': 'n', 'stock': 1},
          ],
        ),
      );

      expect(bundle.manualEntries.single.code, 'E-999');
      expect(bundle.inventoryParts.single.sku, 'ABC-1');
    });
  });

  group('migration to schema v3', () {
    // Same shape as 1.2's migration test, and for the same reason: an install
    // made before this task must end up with exactly what a fresh install gets.
    // `Migrator.createTable` creates the table only, and a *collation* change
    // needs a table rewrite, so both halves are asserted separately.
    test('a v2 database upgrades to seed markers and NOCASE SKUs', () async {
      final file = File('${tempDir.path}/migrate.db');
      final v2 = DatabaseService.encrypted(
        file: file,
        encryptionKey: 'migrate-key',
      );
      // Rewind to the v2 shape: no seed_markers, and inventory_parts without the
      // NOCASE collation on its primary key.
      for (final stmt in const [
        'DROP TABLE seed_markers',
        'DROP TABLE inventory_parts',
        'CREATE TABLE inventory_parts ('
            'sku TEXT NOT NULL, name TEXT NOT NULL, '
            'stock INTEGER NOT NULL DEFAULT 0, location TEXT NULL, '
            'PRIMARY KEY (sku))',
        'PRAGMA user_version = 2',
      ]) {
        await v2.customStatement(stmt);
      }
      // Stored in the *un-normalised* form deliberately. A row written as
      // `BRK-990-XP` would be found after the upgrade whether or not the collation
      // arrived, because `normalizeSku` upper-cases the lookup argument too — so
      // asserting on that row would test nothing about the migration.
      await v2.customStatement(
        'INSERT INTO inventory_parts (sku, name, stock, location) '
        "VALUES ('brk-990-xp', 'Traction Brake Pad Assembly', 2, "
        "'Aisle 4, Shelf B')",
      );
      await v2.close();

      final v3 = DatabaseService.encrypted(
        file: file,
        encryptionKey: 'migrate-key',
      );
      addTearDown(v3.close);

      // The new table exists and is writable — `createTable` in the migration is
      // what puts it there, and an upgraded install without it would crash on the
      // first `ensureSeeded`.
      await v3.recordSeedMarker(id: 'after_upgrade', revision: 9);
      expect((await v3.seedMarker('after_upgrade'))?.revision, 9);

      // The `alterTable` rewrite copied the row rather than dropping it...
      final rows = await v3.allInventoryParts();
      expect(rows, hasLength(1));
      expect(rows.single.sku, 'brk-990-xp');

      // ...and the collation arrived with it. The stored SKU is lower-case and the
      // canonical lookup asks for the upper-case form, so a BINARY primary key
      // finds nothing here. Confirmed by mutation: removing the `alterTable` call
      // from the v3 migration makes exactly this expectation fail.
      expect((await v3.inventoryPartBySku('BRK-990-XP'))?.stock, 2);

      // The whole database is at v3, not just the parts this test rewound.
      final version = await v3.customSelect('PRAGMA user_version').getSingle();
      expect(version.read<int>('user_version'), 3);
    });
  });
}

/// A database that writes the seed marker and *then* fails, so the seeding
/// transaction can be made to fail at its final step with every row — the marker
/// included — already written.
///
/// It writes before throwing on purpose. An override that simply *replaced*
/// `recordSeedMarker` would leave the marker row absent for a reason unrelated to the
/// rollback, so the test's marker assertion could not fail; that was true of a first
/// version of this class. Writing first makes all four assertions discriminate, and
/// makes the "marker vouching for rolled-back rows" state the test comment describes
/// actually reachable.
///
/// Plaintext and in-memory: encryption is irrelevant to whether a transaction rolls
/// back, and `DatabaseService`'s constructor takes any [QueryExecutor], so this needs
/// no production seam.
class _MarkerFailingDatabase extends DatabaseService {
  _MarkerFailingDatabase() : super(NativeDatabase.memory());

  @override
  Future<void> recordSeedMarker({
    required String id,
    required int revision,
    DateTime? appliedAt,
  }) async {
    await super.recordSeedMarker(
      id: id,
      revision: revision,
      appliedAt: appliedAt,
    );
    throw StateError('injected failure after every row was written');
  }
}

/// A [SeedSource] that returns text handed to it, standing in for the asset bundle.
class _TextSeedSource implements SeedSource {
  _TextSeedSource(this._json, {required this.seedId});

  final String _json;

  @override
  final String seedId;

  @override
  Future<String> loadSeedJson() async => _json;
}

/// A minimal real [AssetBundle], so the production `loadString` path is exercised
/// rather than replaced.
class _FakeAssetBundle extends CachingAssetBundle {
  _FakeAssetBundle(this._assets);

  final Map<String, String> _assets;

  @override
  Future<ByteData> load(String key) async {
    final value = _assets[key];
    if (value == null) {
      throw StateError('asset not in fake bundle: $key');
    }
    return ByteData.sublistView(Uint8List.fromList(utf8.encode(value)));
  }
}

/// One well-formed manual entry, overridable field by field.
Map<String, Object?> _manual(String id, {String? code}) => {
  'id': id,
  'section': 'Section $id',
  'code': code ?? 'E-$id',
  'title': 'Title $id',
  'symptoms': 'Symptoms for $id',
  'procedure': 'Procedure for $id',
};

/// The three real manual entries, with `apex_9_err_102`'s code deliberately written
/// in the messy form a hand-authored asset carries (`" e-102 "`).
List<Map<String, Object?>> _defaultManuals() => [
  {
    'id': 'apex_9_err_102',
    'section': 'Brake Systems',
    'code': ' e-102 ',
    'title': 'Traction Brake Pad Wear & Vibration',
    'symptoms':
        'High-pitched squealing during deceleration, cabin vibration at '
        'terminal landings, fault code E-102 displayed on machine room '
        'controller.',
    'procedure':
        '1. Isolate the main elevator power bus. 2. Remove the magnetic brake '
        'cowl using a Torx T20 driver.',
    'required_tools': ['Torx T20', 'Digital Caliper'],
    'required_parts': ['BRK-990-XP'],
  },
  {
    'id': 'apex_9_err_204',
    'section': 'Hydraulics & Valving',
    'code': 'E-204',
    'title': 'Proportional Valve Flow Discrepancy',
    'symptoms':
        'Levelling inaccuracies exceeding 5mm, temperature warning E-204 on '
        'hydraulic manifold ledger.',
    'procedure': '1. Read hydraulic oil temperature from manifold gauge.',
    'required_tools': ['Multimeter'],
    'required_parts': ['FLT-440-HYD'],
  },
  {
    'id': 'apex_9_err_305',
    'section': 'Door Operators',
    'code': 'E-305',
    'title': 'Door Clutches & Belt Slippage',
    'symptoms': 'Belt squealing during door open sequences, fault code E-305.',
    'procedure': '1. Switch door operator controller to Manual.',
    'required_tools': ['Microfiber Cloth', 'Wrench 10mm'],
    'required_parts': ['BELT-330-DRV'],
  },
];

List<Map<String, Object?>> _defaultParts() => [
  {
    'sku': 'BRK-990-XP',
    'name': 'Traction Brake Pad Assembly',
    'stock': 2,
    'location': 'Aisle 4, Shelf B',
  },
  {
    'sku': 'FLT-440-HYD',
    'name': 'Hydraulic Pilot Valve Filter Mesh',
    'stock': 5,
    'location': 'Aisle 2, Shelf A',
  },
  {
    'sku': 'BELT-330-DRV',
    'name': 'Door Operator Drive Belt',
    'stock': 0,
    'location': 'Aisle 1, Shelf C',
  },
  {
    'sku': 'CAL-050-KIT',
    'name': 'Caliper Clearance Shim Kit',
    'stock': 12,
    'location': 'Aisle 4, Shelf A',
  },
  {
    'sku': 'SNS-770-OPT',
    'name': 'Optical Door Curtain Sensor',
    'stock': 1,
    'location': 'Aisle 3, Shelf D',
  },
];

/// Builds seed JSON. Defaults mirror the shipped asset's shape (3 manuals, 5
/// parts) so the AC counts come from the fixture rather than from a magic number.
String _fixtureJson({
  int revision = 1,
  List<Map<String, Object?>>? manualsOverride,
  List<Map<String, Object?>>? partsOverride,
}) => jsonEncode({
  'revision': revision,
  'manual_entries': manualsOverride ?? _defaultManuals(),
  'inventory_parts': partsOverride ?? _defaultParts(),
});

/// The default manuals with one entry's symptom prose replaced.
List<Map<String, Object?>> _rewriteSymptoms(String id, String symptoms) =>
    _defaultManuals()
        .map((m) => m['id'] == id ? {...m, 'symptoms': symptoms} : m)
        .toList(growable: false);
