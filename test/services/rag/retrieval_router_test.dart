import 'dart:io';

import 'package:field_ops_copilot/services/database/database_initializer.dart';
import 'package:field_ops_copilot/services/database/database_service.dart';
import 'package:field_ops_copilot/services/rag/retrieval_router.dart';
import 'package:flutter_test/flutter_test.dart';

/// Unit-tier coverage for the retrieval router.
///
/// Every test runs against a real encrypted database seeded from the **shipped**
/// `assets/elevator_manual_seed.json`, not from fixtures. The router depends on
/// that even harder than the seeder does: TC-RAG-ROUTE-03's two expected
/// ids are a property of that exact seed text and its porter stems, so a fixture
/// would let the suite stay green while the bundled manual stopped producing
/// them.
void main() {
  late Directory tempDir;
  late DatabaseService db;
  late RetrievalRouter router;
  late String shippedJson;

  setUpAll(() async {
    shippedJson = await File('assets/elevator_manual_seed.json').readAsString();
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('fieldops_router_test');
    db = DatabaseService.encrypted(
      file: File('${tempDir.path}/router.db'),
      encryptionKey: 'router-test-key',
    );
    await DatabaseInitializer(
      database: db,
      source: _TextSeedSource(shippedJson),
    ).ensureSeeded();
    router = RetrievalRouter(db);
  });

  tearDown(() async {
    await db.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<List<String>> ftsOnly(String raw) async =>
      (await db.searchManualEntries(raw)).map((e) => e.id).toList();

  group('TC-RAG-ROUTE-01 code extraction wins', () {
    const query = 'cabin shaking, E-102 on controller';

    test('the code leg retrieves apex_9_err_102 and ranks it first', () async {
      final result = await router.retrieve(query);

      expect(result.resolvedCodes, ['E-102']);
      expect(result.codeHitIds, {'apex_9_err_102'});
      expect(result.entries.first.id, 'apex_9_err_102');
      expect(result.entries.first.code, 'E-102');
      expect(result.route, RetrievalRoute.hybrid);
    });

    test('"shaking" really does match nothing, so the AC has a premise', () async {
      // The acceptance criterion says the entry is found "even though 'shaking'
      // matches nothing in FTS". That clause is an assumption about the porter
      // stemmer and the seed text, and an assumption is exactly the kind of thing
      // this project keeps finding to be false. Check it rather than repeat it:
      // the manual says "vibration"/"vibrating", never anything that stems to
      // `shake`.
      expect(await ftsOnly('shaking'), isEmpty);

      // And the term was genuinely offered to FTS — it is in the residual, not
      // quietly dropped along with the code.
      final result = await router.retrieve(query);
      expect(result.searchedTerms, contains('shaking'));
    });

    test('a code-only query retrieves without ever touching MATCH', () async {
      // The residual is empty here, and an empty MATCH expression is an FTS5
      // *syntax error* rather than an empty result — so this is the case that
      // would throw if the router forwarded the residual unconditionally.
      await expectLater(
        db.searchManualEntriesRanked('', 10).get(),
        throwsA(isA<Exception>()),
        reason: 'an empty MATCH must really be an error for this to be a guard',
      );

      final result = await router.retrieve('E-102');

      expect(result.searchedTerms, isEmpty);
      expect(result.ftsHitIds, isEmpty);
      expect(result.entryIds, ['apex_9_err_102']);
      expect(result.route, RetrievalRoute.code);
    });
  });

  group('TC-RAG-ROUTE-02 code + symptoms merge', () {
    const query = 'door belt squealing E-305';

    test('the code hit ranks first and appears exactly once', () async {
      final result = await router.retrieve(query);

      expect(result.entryIds, ['apex_9_err_305', 'apex_9_err_102']);
      expect(
        result.entryIds.toSet(),
        hasLength(result.entryIds.length),
        reason: 'no id may appear twice in the merged list',
      );
      expect(result.route, RetrievalRoute.hybrid);
    });

    test('the de-duplication is doing work — both legs returned _305', () async {
      // Without this the previous test passes for a second reason: if the FTS
      // leg had missed _305 entirely there would be nothing to de-duplicate, and
      // deleting the `seen` set would leave the assertion green.
      final result = await router.retrieve(query);

      expect(result.codeHitIds, contains('apex_9_err_305'));
      expect(result.ftsHitIds, contains('apex_9_err_305'));
      expect(await ftsOnly('door belt squealing'), contains('apex_9_err_305'));
    });

    test(
      'the code hit leads because it is a code hit, not because bm25 agrees',
      () async {
        // The input above is a weak test of ordering, and a mutation proved it:
        // bm25 already ranks _305 top for "door belt squealing", so swapping the
        // merge to put the full-text leg first leaves the assertion above green.
        // This input separates the two properties. Full text ranks _305 then _102;
        // the code hit is a third entry that bm25 would never lead with, so only a
        // code-first merge produces this order.
        final result = await router.retrieve('squealing noise E-204');

        expect(result.codeHitIds, {'apex_9_err_204'});
        expect(result.ftsHitIds, {'apex_9_err_305', 'apex_9_err_102'});
        expect(result.entryIds, [
          'apex_9_err_204',
          'apex_9_err_305',
          'apex_9_err_102',
        ]);
      },
    );

    test('the code is cut from the residual, its digits with it', () async {
      final result = await router.retrieve(query);

      expect(result.searchedTerms, ['door', 'belt', 'squealing']);
      expect(result.searchedTerms, isNot(contains('E-305')));
      expect(result.searchedTerms, isNot(contains('305')));
    });
  });

  group('TC-RAG-ROUTE-03 no code, full text only', () {
    const query = 'squealing noise';

    test('takes the full-text leg and returns _102 and _305', () async {
      final result = await router.retrieve(query);

      expect(result.route, RetrievalRoute.fullText);
      expect(result.resolvedCodes, isEmpty);
      expect(result.unresolvedCodes, isEmpty);
      expect(result.codeHitIds, isEmpty);
      expect(result.entryIds, hasLength(2));
      expect(result.entryIds.toSet(), {'apex_9_err_102', 'apex_9_err_305'});
    });

    test(
      '"noise" matches nothing, so the OR join is what earns the recall',
      () async {
        // The sanitizer chose `OR` over `AND` specifically for this input:
        // `"squealing" AND "noise"` returns zero rows. That claim is only
        // interesting if "noise" is genuinely absent from the manual — pin it
        // here, because if a future seed adds the word, the test above starts
        // passing for a different reason than the one it was written for.
        expect(await ftsOnly('noise'), isEmpty);
        expect(await ftsOnly('squealing'), hasLength(2));
      },
    );
  });

  group('fault-code extraction', () {
    test(
      'the separator variants a technician actually types all resolve',
      () async {
        for (final query in const [
          'E-102',
          'e-102',
          '  E-102  ',
          'E102',
          'e102 on the controller',
          'E 102 showing',
          'fault E–102 again', // en dash
          'fault E—102 again', // em dash
        ]) {
          final result = await router.retrieve(query);
          expect(result.resolvedCodes, ['E-102'], reason: 'query: $query');
          expect(result.codeHitIds, {
            'apex_9_err_102',
          }, reason: 'query: $query');
        }
      },
    );

    test('a candidate that misses keeps its words searchable', () async {
      // `Torx T20` reads as a code candidate under the loose pattern. The router's
      // contract is that this costs one indexed lookup and nothing else: the words
      // stay in the residual, and here they are what finds the entry (the E-102
      // procedure names the Torx T20 driver).
      final result = await router.retrieve('Torx T20 needed');

      expect(result.unresolvedCodes, ['T-20']);
      expect(result.resolvedCodes, isEmpty);
      expect(result.searchedTerms, contains('T20'));
      expect(result.entryIds, contains('apex_9_err_102'));
      expect(result.route, RetrievalRoute.fullText);
    });

    test('a plausible but unknown code leaves the text intact', () async {
      final result = await router.retrieve('controller shows E-999');

      expect(result.unresolvedCodes, ['E-999']);
      expect(result.searchedTerms, contains('E-999'));
    });

    test('measurements and locations are not codes', () async {
      // The exclusions the pattern's doc claims. Each of these is a digit run the
      // manual's own procedure text contains, and treating one as a fault code
      // would spend a lookup and — worse, if it ever hit — cut a real search term.
      final result = await router.retrieve(
        'tighten the 10mm bolt in Aisle 4, breaker 4A, gap 2.0mm',
      );

      expect(result.resolvedCodes, isEmpty);
      expect(result.unresolvedCodes, isEmpty);
    });

    test(
      'a repeated code is cut from every position, not just the first',
      () async {
        final result = await router.retrieve('E-102 earlier, still E-102 now');

        expect(result.resolvedCodes, ['E-102']);
        expect(result.searchedTerms, ['earlier', 'still', 'now']);
      },
    );

    test(
      'two distinct codes both retrieve, in the order they were written',
      () async {
        final result = await router.retrieve('E-305 first then E-102');

        expect(result.resolvedCodes, ['E-305', 'E-102']);
        expect(result.entryIds.take(2), ['apex_9_err_305', 'apex_9_err_102']);
        expect(result.searchedTerms, ['first', 'then']);
      },
    );

    test('cutting a code cannot fuse the terms on either side of it', () async {
      // The span is replaced by a space rather than deleted. The case that makes
      // that load-bearing is narrow but real: `\b` already guarantees the code is
      // not adjacent to a letter or digit, so letters cannot fuse — but the FTS
      // sanitizer keeps hyphens *inside* a term while the regex treats one as a
      // boundary. Delete the span instead of blanking it and `door-E-305-belt`
      // collapses to the single unmatchable term `door--belt`.
      final result = await router.retrieve(
        'squealing door-E-305-belt slipping',
      );

      expect(result.resolvedCodes, ['E-305']);
      expect(result.searchedTerms, ['squealing', 'door', 'belt', 'slipping']);
      expect(result.entries.first.id, 'apex_9_err_305');
    });

    test(
      'a code fused to a following word is not a code, and its words survive',
      () async {
        // `E-102on` has no word boundary after the digits, so the pattern does not
        // fire — deliberately, since the same boundary is what stops `E-10` being
        // read out of `E-1024`. The cost is that the whole blob goes to FTS as one
        // term; the point of this test is that the *rest* of the sentence still
        // does its job rather than the query failing.
        final result = await router.retrieve(
          'cabin vibration, E-102on controller',
        );

        expect(result.resolvedCodes, isEmpty);
        expect(result.searchedTerms, contains('E-102on'));
        expect(result.entryIds, contains('apex_9_err_102'));
      },
    );

    test('a code repeated around another code is still cut everywhere', () async {
      // The spans reach `_withoutSpans` grouped by canonical code, not in
      // text order, so a code that repeats *around* another one produces
      // out-of-order starts — here `[0, 16, 8]`. Without the sort, the cursor has
      // already passed position 8 when that span arrives and the overlap branch
      // silently drops it, leaving a resolved `E-305` in the residual for FTS to
      // tokenize into `e` plus `305`. The two existing repetition tests use one
      // code repeated or two codes appearing once, so neither interleaves and
      // neither could see this: deleting the sort left all 318 tests green.
      final result = await router.retrieve('E-102 x E-305 y E-102 z');

      expect(result.resolvedCodes, ['E-102', 'E-305']);
      expect(result.searchedTerms, ['x', 'y', 'z']);
    });

    test('a one- or two-letter word before a single digit is not a code', () async {
      // This is what the two-digit floor actually excludes. `breaker 4A`
      // — which the pattern's doc used to credit to the floor — is out because of
      // the letter prefix instead, so it could never bind this. `to 8` can:
      // relax `\d{2,4}` to `\d{1,4}` and `torque to 8 Nm` yields the candidate
      // `TO-8`, spending a lookup on ordinary English rather than an identifier.
      for (final query in const [
        'torque to 8 Nm',
        'use a T 5 driver',
        'shelf B 3',
        'A4 paper',
      ]) {
        final result = await router.retrieve(query);
        expect(result.resolvedCodes, isEmpty, reason: 'query: $query');
        expect(result.unresolvedCodes, isEmpty, reason: 'query: $query');
      }
    });

    test(
      'maxCodes bounds the lookups, and the surplus stays searchable',
      () async {
        final limited = RetrievalRouter(db, maxCodes: 1);
        final result = await limited.retrieve('E-102 and E-305 and E-204');

        expect(result.resolvedCodes, ['E-102']);
        // The codes past the cap were never extracted, so their text is still in
        // the residual — dropped candidates are not dropped words.
        expect(result.searchedTerms, containsAll(['E-305', 'E-204']));
      },
    );
  });

  group('merging', () {
    test('ftsLimit bounds the full-text leg only', () async {
      final narrow = RetrievalRouter(db, ftsLimit: 1);
      final result = await narrow.retrieve(
        'cabin shaking, E-102 on controller',
      );

      expect(result.ftsHitIds, hasLength(1));
      // The code hit is not subject to ftsLimit, and here the single full-text
      // hit is the same row, so the merged list holds exactly one entry.
      expect(result.entryIds, ['apex_9_err_102']);

      final wide = await router.retrieve('cabin shaking, E-102 on controller');
      expect(wide.entryIds, hasLength(3));
    });

    test('route reports the full-text leg even when it adds no new row', () async {
      // Regression. `route` used to derive the full-text leg from `entries.length >
      // codeHitIds.length`, which is silent exactly when every full-text hit is
      // also a code hit — the merged list grows by nothing. That bug shipped for
      // one commit and was fixed by recording `ftsHitIds`; nothing bound the fix,
      // so restoring the old expression left all 318 tests green.
      //
      // This is the discriminating state, reached two ways. Both must say
      // `hybrid`; the old derivation says `code`.
      final onlyOverlap = await router.retrieve(
        'door clutch belt slipping, E-305',
      );
      expect(onlyOverlap.entries, hasLength(1));
      expect(onlyOverlap.codeHitIds, {'apex_9_err_305'});
      expect(onlyOverlap.ftsHitIds, {'apex_9_err_305'});
      expect(onlyOverlap.route, RetrievalRoute.hybrid);

      final narrowed = await RetrievalRouter(
        db,
        ftsLimit: 1,
      ).retrieve('cabin shaking, E-102 on controller');
      expect(narrowed.entries, hasLength(1));
      expect(narrowed.ftsHitIds, hasLength(1));
      expect(narrowed.route, RetrievalRoute.hybrid);
    });

    test('nothing matches anywhere, and the result says so', () async {
      final result = await router.retrieve('unknown machinery broken');

      expect(result.route, RetrievalRoute.none);
      expect(result.isEmpty, isTrue);
      expect(result.entries, isEmpty);
      expect(result.searchedTerms, ['unknown', 'machinery', 'broken']);
    });

    test('hostile punctuation reaches FTS as terms, not as syntax', () async {
      // TC-FTS-SAN-01's input, routed. The router adds a way to get this
      // wrong that the sanitizer cannot catch: it edits the raw string before
      // sanitizing, so a bad span cut could produce text the sanitizer then turns
      // into a valid-but-wrong query, or the code could be forwarded unsanitized.
      final result = await router.retrieve(
        'door won\'t close - "stuck" (E-305)',
      );

      expect(result.resolvedCodes, ['E-305']);
      expect(result.entries.first.id, 'apex_9_err_305');
      expect(result.searchedTerms, ['door', "won't", 'close', 'stuck']);
    });

    test(
      'empty and whitespace-only input query nothing and throw nothing',
      () async {
        for (final query in const ['', '   ', '???']) {
          final result = await router.retrieve(query);
          expect(result.entries, isEmpty, reason: 'query: "$query"');
          expect(result.route, RetrievalRoute.none, reason: 'query: "$query"');
        }
      },
    );

    test(
      'rawQuery is carried through untouched for the prompt compiler',
      () async {
        const query = '  Cabin shaking, E-102 on controller  ';
        final result = await router.retrieve(query);

        expect(result.rawQuery, query);
      },
    );
  });

  group('the shipped asset backs every code these ACs use', () {
    test('E-102, E-204 and E-305 all resolve through the router', () async {
      for (final code in const ['E-102', 'E-204', 'E-305']) {
        final result = await router.retrieve(code);
        expect(result.resolvedCodes, [code], reason: code);
        expect(result.entries, hasLength(1), reason: code);
      }
    });
  });
}

/// Feeds seed JSON straight to the initializer, bypassing the asset bundle.
class _TextSeedSource implements SeedSource {
  const _TextSeedSource(this.json);

  final String json;

  @override
  String get seedId => 'elevator_manual_seed';

  @override
  Future<String> loadSeedJson() async => json;
}
