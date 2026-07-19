import 'dart:io';

import 'package:field_ops_copilot/services/database/database_initializer.dart';
import 'package:field_ops_copilot/services/database/database_service.dart';
import 'package:field_ops_copilot/services/rag/retrieval_router.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../integration_test/e2e_fixtures.dart';

/// Host-tier guards for the **premises** of the device suite.
///
/// TC-AGENT-E2E-01b begins `expect(retrieved.isEmpty, isTrue)` — an assumption
/// about the shipped seed, not an assertion about the loop. On the first device
/// run that assumption was false and the test failed there, after a build, a
/// 2.6GB transfer and four minutes, without the model ever being asked
/// anything.
///
/// Nothing about that needed a device. These tests run in CI on every commit
/// and fail in seconds instead, which is the whole reason
/// `integration_test/e2e_fixtures.dart` exists as a shared file rather than two
/// string literals that drift apart.
void main() {
  late Directory tempDir;
  late DatabaseService db;
  late RetrievalRouter router;
  late String shippedJson;

  setUpAll(() async {
    shippedJson = await File('assets/elevator_manual_seed.json').readAsString();
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('fieldops_e2e_premises');
    db = DatabaseService.encrypted(
      file: File('${tempDir.path}/premises.db'),
      encryptionKey: 'e2e-premises-test-key',
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

  test('TC-AGENT-E2E-01 retrieves the E-102 entry', () async {
    final result = await router.retrieve(e2eGroundedInquiry);

    expect(result.entryIds, contains('apex_9_err_102'));
    expect(result.resolvedCodes, contains('E-102'));
  });

  test('TC-AGENT-E2E-01b really does retrieve nothing', () async {
    // The guard that would have turned a four-minute device failure into a
    // two-second host failure.
    final result = await router.retrieve(e2eNoMatchInquiry);

    expect(
      result.isEmpty,
      isTrue,
      reason:
          'TC-AGENT-E2E-01b asserts this on device before the model is asked '
          'anything; if it is false the device run fails on its premise',
    );
    expect(result.entryIds, isEmpty);
    expect(result.codeHitIds, isEmpty);
    expect(result.ftsHitIds, isEmpty);
  });

  test('the fixture it replaced matched, and both reasons still hold', () async {
    // Recorded as a test rather than a comment, because the *reason* the first
    // fixture failed is a live property of the corpus, not a one-off mistake —
    // and the second reason means any replacement chosen by intuition is
    // likely to be wrong too.
    const replaced = 'the hydraulic ram on the loading crane is leaking';
    expect((await router.retrieve(replaced)).isEmpty, isFalse);

    // Reason 1: `hydraulic` is genuinely in the manual — E-204 is
    // "Proportional Valve Flow Discrepancy", whose symptoms name the hydraulic
    // manifold. An elevator manual is a bad place to look for a non-hydraulic
    // word.
    expect(
      (await db.searchManualEntries('hydraulic')).map((e) => e.id),
      contains('apex_9_err_204'),
    );

    // Reason 2, and the one that generalises: **stop words match.** The
    // sanitizer joins terms with `OR` and the porter tokenizer removes no stop
    // words, so a query is non-empty as soon as it contains one common English
    // word that appears anywhere in the manual prose.
    for (final stopWord in const ['the', 'on', 'is']) {
      expect(
        await db.searchManualEntries(stopWord),
        isNotEmpty,
        reason: '"$stopWord" alone retrieves manual entries',
      );
    }

    // Which is why a plausible-sounding out-of-domain sentence is *still* a
    // match with every domain word removed. This is the finding; the fixture
    // swap is only the workaround.
    expect(
      (await router.retrieve(
        'the coffee machine in the lobby is broken',
      )).isEmpty,
      isFalse,
      reason:
          'no word here is about elevators; it matches on "the", "in" and "is"',
    );
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
