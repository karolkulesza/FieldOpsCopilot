import 'dart:io';

import 'package:field_ops_copilot/services/database/database_initializer.dart';
import 'package:field_ops_copilot/services/database/database_service.dart';
import 'package:field_ops_copilot/services/database/providers.dart';
import 'package:field_ops_copilot/services/database/seed_data.dart';
import 'package:field_ops_copilot/services/models/model_descriptor.dart';
import 'package:field_ops_copilot/services/models/providers.dart';
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Unit-tier coverage for Task 1.11's first deferred wiring: the database, the
/// key it needs, and the first-launch seed.
///
/// **What can and cannot be tested on the host, stated up front because the
/// boundary is the interesting part.** [appDatabaseProvider] calls
/// `getApplicationSupportDirectory()`, a platform channel with no host
/// implementation, so it is *overridden* here with a temp-file database. That
/// means these tests bind the two properties this task actually owns — the key
/// the graph resolves, and that nothing reaches the retrieval path before the
/// seed has run — and say nothing about the application-support path itself.
/// `integration_test/demo_flow_test.dart` is what exercises that, on device,
/// with the real directory and the real key.
void main() {
  late Directory tempDir;
  late String shippedJson;

  /// How many times the seed provider's body has run in the current container.
  /// Only interesting for the retry test; see that test for why.
  var seedBuilds = 0;

  setUpAll(() async {
    shippedJson = await File('assets/elevator_manual_seed.json').readAsString();
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('fieldops_db_providers');
    seedBuilds = 0;
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  /// A container whose database lives in [tempDir] and whose seed comes from
  /// [seedJson] (the shipped asset unless a test wants a broken one).
  ///
  /// Only [appDatabaseProvider] and the seed *source* are overridden. The seed
  /// **trigger**, the ordering dependency and the key provider are the real ones,
  /// because they are what is under test.
  ProviderContainer containerOver({
    String? seedJson,
    String fileName = 'providers.db',
  }) {
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) async {
          final database = DatabaseService.encrypted(
            file: File('${tempDir.path}/$fileName'),
            encryptionKey: ref.watch(databaseEncryptionKeyProvider),
          );
          ref.onDispose(database.close);
          return database;
        }),
        // `overrideWith` keeps the origin provider's `retry` — Riverpod copies
        // `retry: _inner.retry` into the view (`functional_provider.dart`) — so
        // these overrides run under the production retry policy rather than the
        // framework default. That is what makes the retry test below a statement
        // about `providers.dart` and not about this file.
        seedOutcomeProvider.overrideWith((ref) async {
          seedBuilds++;
          final database = await ref.watch(appDatabaseProvider.future);
          return DatabaseInitializer(
            database: database,
            source: _TextSeedSource(seedJson ?? shippedJson),
          ).ensureSeeded();
        }),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('the encryption-key decision', () {
    // The task's brief permits a hardcoded key and requires that it be a
    // deliberate recorded decision. This binds the decision: with no define
    // supplied — which is how every host test and every un-configured build runs
    // — the key is the named demo constant and nothing else.
    test('falls back to the named demo key when no define is supplied', () {
      final container = containerOver();

      expect(container.read(databaseEncryptionKeyProvider), demoDatabaseKey);
    });

    // The constant is exported and says what it is. A regression that renamed it
    // to something innocuous would satisfy every other test in this file, so the
    // property is asserted directly rather than left to the name in one file.
    test('the demo key is self-describing rather than plausible-looking', () {
      expect(demoDatabaseKey, contains('not-a-secret'));
      expect(demoDatabaseKey, isNotEmpty);
    });

    // The key is not merely resolved, it reaches `PRAGMA key`: a database opened
    // through the graph is readable with the graph's key and refuses any other.
    // Without this, `databaseEncryptionKeyProvider` could be a decorative
    // provider nothing consulted.
    test('the resolved key is the one the database is opened with', () async {
      final container = containerOver(fileName: 'keyed.db');
      await container.read(seededDatabaseProvider.future);
      container.dispose();

      final wrongKey = DatabaseService.encrypted(
        file: File('${tempDir.path}/keyed.db'),
        encryptionKey: 'some-other-passphrase',
      );
      addTearDown(wrongKey.close);
      await expectLater(
        wrongKey.manualEntryByCode('E-102'),
        throwsA(isNotNull),
      );

      final rightKey = DatabaseService.encrypted(
        file: File('${tempDir.path}/keyed.db'),
        encryptionKey: demoDatabaseKey,
      );
      addTearDown(rightKey.close);
      expect(await rightKey.manualEntryByCode('E-102'), isNotNull);
    });
  });

  group('the first-launch seed', () {
    test(
      'a fresh database is seeded, and reports it as a first launch',
      () async {
        final container = containerOver();

        final outcome = await container.read(seedOutcomeProvider.future);

        expect(outcome, isA<SeedApplied>());
        expect((outcome as SeedApplied).wasFirstLaunch, isTrue);
        expect(outcome.manualEntries, greaterThan(0));
        expect(outcome.inventoryParts, greaterThan(0));
      },
    );

    test(
      'a second launch over the same file skips rather than re-seeds',
      () async {
        final first = containerOver(fileName: 'twice.db');
        expect(
          await first.read(seedOutcomeProvider.future),
          isA<SeedApplied>(),
        );
        first.dispose();

        final second = containerOver(fileName: 'twice.db');
        final outcome = await second.read(seedOutcomeProvider.future);

        expect(outcome, isA<SeedSkipped>());
      },
    );

    // Task 1.3's contract: a malformed asset is a build defect and must fail
    // loudly rather than start the app with an empty manual. "Loudly" here means
    // the provider carries the error, which is what lets the screen render it
    // instead of the framework swallowing it.
    test(
      'a malformed asset surfaces as an error, not an empty manual',
      () async {
        final container = containerOver(
          seedJson: '{"revision": "not a number"}',
        );

        await expectLater(
          container.read(seedOutcomeProvider.future),
          throwsA(isA<SeedFormatException>()),
        );
      },
    );

    // Riverpod 3 retries a provider whose body threw an `Exception` ten times
    // with exponential backoff — ~40 seconds in `AsyncLoading` before the error
    // is reported at all (`ProviderContainer.defaultRetry` skips only `Error` and
    // `ProviderException`). Both of this provider's failures are ordinary
    // `Exception`s and both are perfectly deterministic, so the default turns
    // Task 1.3's "fail loudly at startup" into a forty-second hang that then
    // says something.
    //
    // This binds the fix rather than describing it, and the numbers below are
    // sampled rather than derived from the backoff parameters. With
    // `retry: noRetry` deleted from `seedOutcomeProvider`, this body ran **11**
    // times (one attempt plus ten retries) and the element was still
    // `AsyncLoading` at 30s and `AsyncError` by 45s — so this test would also
    // time out, but the count is the assertion because a timeout alone does not
    // distinguish "retried" from "hung".
    test(
      'a deterministic startup failure is built once rather than retried',
      () async {
        final container = containerOver(seedJson: 'not json at all');

        await expectLater(
          container.read(seedOutcomeProvider.future),
          throwsA(isA<SeedFormatException>()),
        );
        expect(seedBuilds, 1);
      },
    );

    // **The model-status chain needs its own guard, and review finding R0-F4 is
    // that it did not have one.** `retry: noRetry` was applied to eleven providers
    // and only two were bound; the reviewer measured that deleting it from
    // `modelInstallStatusProvider`, `modelStorageProvider`, `retrievalRouterProvider`
    // and `toolRegistryProvider` all survived the whole suite. The unbound one that
    // matters most is the model-status site, because
    // `lib/services/models/providers.dart` makes the strongest behavioural claim in
    // the set — that without it the banner sits on "Checking model…" for half a
    // minute before showing a status its own doc says must be distinguishable from
    // ready and absent.
    //
    // Bound the same way the seed is, by counting builds. `modelStorageProvider` is
    // the throwing surface because it is what actually fails when the platform
    // channel is absent — the real-world case, and the one every host widget test
    // hits — while `modelInstallStatusProvider` is the provider under test and
    // inherits the policy through the dependency.
    test(
      'a failing model-status chain is built once rather than retried',
      () async {
        var storageBuilds = 0;
        final container = ProviderContainer(
          overrides: [
            modelStorageProvider.overrideWith((ref) async {
              storageBuilds++;
              throw MissingPluginException('no application support directory');
            }),
          ],
        );
        addTearDown(container.dispose);

        await expectLater(
          container.read(
            modelInstallStatusProvider(ModelCatalog.active.id).future,
          ),
          throwsA(isA<MissingPluginException>()),
        );
        expect(storageBuilds, 1);
      },
    );
  });

  group('seeding precedes the retrieval path', () {
    // The load-bearing property of this file. `seededDatabaseProvider` is the
    // only handle the retrieval path gets, and it cannot resolve before the seed
    // has. Asserted by *reading it first* and finding the manual already there:
    // if the dependency were dropped, this returns the same instance with no rows
    // and the query answers null.
    test(
      'reading the seeded database first still finds seeded content',
      () async {
        final container = containerOver();

        final database = await container.read(seededDatabaseProvider.future);

        expect(await database.manualEntryByCode('E-102'), isNotNull);
        expect(await database.inventoryPartBySku('BRK-990-XP'), isNotNull);
      },
    );

    // The same property stated as the mutation that would break it: with the
    // ordering dependency removed, the read below is exactly what returns an
    // empty database. This test is what fails when someone "simplifies"
    // `seededDatabaseProvider` into an alias for `appDatabaseProvider`.
    test(
      'the seed outcome has already resolved once the seeded database has',
      () async {
        final container = containerOver();

        await container.read(seededDatabaseProvider.future);

        // `read` on a resolved FutureProvider is synchronous data; if the seed had
        // not run it would still be loading (or absent) here.
        expect(
          container.read(seedOutcomeProvider),
          isA<AsyncData<SeedOutcome>>(),
        );
      },
    );

    // Same instance, not a copy. `seededDatabaseProvider` adds an edge to the
    // dependency graph and nothing else — a wrapper would mean two connections to
    // one file, which SQLite tolerates and a reader should not have to reason
    // about.
    test(
      'it is the same DatabaseService instance, not a second connection',
      () async {
        final container = containerOver();

        final seeded = await container.read(seededDatabaseProvider.future);
        final raw = await container.read(appDatabaseProvider.future);

        expect(seeded, same(raw));
      },
    );

    // A failed seed must not hand out a database. Nothing downstream is written
    // to cope with a half-initialised manual, so the failure has to propagate
    // rather than degrade.
    test('a failed seed denies the database rather than degrading', () async {
      final container = containerOver(seedJson: 'not json at all');

      await expectLater(
        container.read(seededDatabaseProvider.future),
        throwsA(isA<SeedFormatException>()),
      );
    });
  });
}

/// Seed source over an in-memory string — the same shape
/// `test/services/ai/agent_loop_test.dart` uses, so the asset is the shipped one
/// without a `rootBundle` and its binding.
class _TextSeedSource implements SeedSource {
  const _TextSeedSource(this._json);

  final String _json;

  @override
  String get seedId => AssetBundleSeedSource.defaultSeedId;

  @override
  Future<String> loadSeedJson() async => _json;
}
