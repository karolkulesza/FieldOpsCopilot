/// Dependency-injection seam for the encrypted local database, and the place the
/// first-launch seed is triggered.
///
/// Mirrors `lib/engines/providers.dart`, `lib/services/models/providers.dart` and
/// `lib/services/inference/providers.dart`: the runtime binds real
/// implementations and tests override these rather than reaching for concrete
/// types.
///
/// **Why this file arrived late.** `DatabaseService.openDefault` shipped
/// with nothing binding it, and
/// `DatabaseInitializer` with no call site, both for the same reason: opening the
/// database needs an encryption key and nothing had decided where the key comes
/// from. Every layer built in between inherited that gap and recorded
/// it. The demo screen is the first thing that needs a database *at runtime*, so
/// this is where the decision lands — see [databaseEncryptionKeyProvider], which
/// is that
/// decision written down rather than a literal for someone to find later.
///
/// **Seeding is a dependency here, not a call order.** Everything on the
/// retrieval path takes its database from [seededDatabaseProvider], which cannot
/// resolve until [seedOutcomeProvider] has. A `main()` that called
/// `ensureSeeded()` and then passed the database around would behave identically
/// today and would be one new entry point away from a screen querying an empty
/// manual; this shape has no call order to get wrong, because the only way to
/// reach the database on the retrieval path runs through the seed.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../retry_policy.dart';
import 'database_initializer.dart';
import 'database_service.dart';

/// The passphrase used when no `--dart-define=FIELDOPS_DB_KEY` was supplied.
///
/// **Named, exported and spelled "not-a-secret" on purpose.** A hardcoded key
/// is acceptable for the demo only as a deliberate,
/// recorded decision. Hiding it behind an innocuous-looking constant would
/// satisfy the letter and invert the intent, so the constant says what it is.
const String demoDatabaseKey = 'fieldops-demo-key-not-a-secret';

/// Passphrase for the local database: `--dart-define=FIELDOPS_DB_KEY` when one
/// was supplied at build time, [demoDatabaseKey] otherwise.
///
/// **What this buys and what it does not.** The cipher is real —
/// ChaCha20-Poly1305 with KDF iterations pinned explicitly, see [DatabaseService]
/// — so a database file lifted off the device is ciphertext. The *key management*
/// is not real: a passphrase compiled into the binary is obfuscation, because
/// anyone who can read the app bundle can read the key. So this protects a stolen
/// **file** and not a stolen **device**, and the design goal that "sensitive data
/// remains sandboxed on the physical device" is true of the storage and only
/// partly true
/// of the threat model. Stated here rather than implied, because the gap between
/// "encrypted at rest" and "encrypted against the person holding the phone" is
/// exactly the gap a demo makes invisible.
///
/// The fleet-deployment answer slots in behind this provider without
/// touching anything downstream: a random key generated on first launch, held in
/// the iOS Keychain or the Android Keystore behind device-passcode protection,
/// and never present in the binary at all. Nothing above this line would change.
///
/// **One operational hazard, because it is silent.** The key is part of the
/// database's identity: change it between launches — add the define to a build
/// that previously used [demoDatabaseKey] — and the existing file cannot be
/// decrypted. It surfaces as a `SqliteException` out of [seedOutcomeProvider] —
/// on the first statement rather than at open time, because `openDefault` is
/// lazy — which the demo screen renders as a readable startup failure. It does
/// *not* silently start over with an empty database, which is the failure that
/// would be worth fearing.
final databaseEncryptionKeyProvider = Provider<String>(
  (ref) => _configuredKey.isEmpty ? demoDatabaseKey : _configuredKey,
);

/// The app's durable encrypted database, in the application-support directory.
///
/// Async because resolving that directory is a platform call. Closed on dispose:
/// a `DatabaseService` outliving its provider holds an open sqlite connection and
/// a native isolate's worth of buffers.
///
/// Opening is **lazy** all the way down — `DatabaseService.openDefault` builds a
/// `LazyDatabase`, so this future completing means "a path was resolved", not
/// "the file opened and the key was accepted". The first statement is what proves
/// the key, and on this path that statement is [seedOutcomeProvider]'s.
///
/// [noRetry], like every provider in this file: the ways it fails — no platform
/// channel, an unwritable directory — do not resolve themselves, and Riverpod 3's
/// default would spend forty seconds in `AsyncLoading` finding that out. See
/// `retry_policy.dart`.
final appDatabaseProvider = FutureProvider<DatabaseService>(retry: noRetry, (
  ref,
) async {
  final database = await DatabaseService.openDefault(
    encryptionKey: ref.watch(databaseEncryptionKeyProvider),
  );
  ref.onDispose(database.close);
  return database;
});

/// The first-launch seed — where `ensureSeeded()` is finally called.
///
/// Exposed as the outcome rather than as a `void` future because the outcome is
/// informative by design: [SeedApplied] versus [SeedSkipped]
/// distinguishes a first launch from every later one, and
/// [SeedApplied.wasFirstLaunch] distinguishes a genuine first launch from a
/// re-seed onto a bumped asset revision.
///
/// Failures are deliberately *not* caught. A `SeedFormatException` means the
/// bundled asset is malformed, which is a build defect and not a runtime
/// condition — `DatabaseInitializer`'s own docs say it should fail loudly rather than start
/// with an empty manual. It arrives here as an errored `AsyncValue`, which the
/// demo screen renders as a startup failure with the message attached, so
/// "loudly" means legible rather than a crash into a grey screen.
///
/// [noRetry] is load-bearing *here specifically*, because both of this
/// provider's failures are the shape Riverpod 3's default retries: a
/// `SeedFormatException` and a `SqliteException` are ordinary `Exception`s, and
/// each is perfectly deterministic. Removing it was measured, not reasoned about:
/// this body then runs **11 times** and the element is still `AsyncLoading` at
/// 30s, so a build shipped with a broken asset shows "Preparing the local
/// manual…" for half a minute before saying anything. Bound by
/// `providers_test.dart`'s 'a deterministic startup failure is built once rather
/// than retried'.
final seedOutcomeProvider = FutureProvider<SeedOutcome>(retry: noRetry, (
  ref,
) async {
  final database = await ref.watch(appDatabaseProvider.future);
  return DatabaseInitializer(database: database).ensureSeeded();
});

/// The database, guaranteed seeded.
///
/// **This is the whole mechanism behind "seed before the retrieval path can be
/// reached".** It is the same `DatabaseService` instance [appDatabaseProvider]
/// holds — nothing is wrapped or copied — and the only thing it adds is an
/// unmet-until-seeded dependency. Everything on the retrieval path
/// (`retrievalRouterProvider`, `toolRegistryProvider`) resolves its database from
/// here, so an unseeded query is not something a caller has to remember not to
/// make: there is no handle to make it with.
///
/// A caller that genuinely wants the database *without* waiting for the seed
/// (there is none today) would use [appDatabaseProvider] and would have to say so
/// at the call site, which is the point.
final seededDatabaseProvider = FutureProvider<DatabaseService>(retry: noRetry, (
  ref,
) async {
  await ref.watch(seedOutcomeProvider.future);
  return ref.watch(appDatabaseProvider.future);
});

const String _configuredKey = String.fromEnvironment('FIELDOPS_DB_KEY');
