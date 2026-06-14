import 'package:flutter/services.dart' show AssetBundle, rootBundle;

import 'database_service.dart';
import 'seed_data.dart';

/// Where the seed JSON comes from.
///
/// An interface rather than an `AssetBundle` parameter so the unit tier can supply
/// text directly, and so a future source (a downloaded manual pack, an OTA content
/// update) slots in without touching [DatabaseInitializer].
abstract interface class SeedSource {
  /// Loads the raw seed JSON, or throws if it cannot be read.
  Future<String> loadSeedJson();

  /// Identifies the dataset, and is the key of its row in `seed_markers`.
  String get seedId;
}

/// Reads the seed JSON out of the Flutter asset bundle — the production source.
class AssetBundleSeedSource implements SeedSource {
  const AssetBundleSeedSource({
    this.bundle,
    this.assetKey = defaultAssetKey,
    this.seedId = defaultSeedId,
  });

  /// The asset declared in `pubspec.yaml`.
  static const String defaultAssetKey = 'assets/elevator_manual_seed.json';

  /// Marker id for this dataset.
  static const String defaultSeedId = 'elevator_manual_seed';

  /// Bundle to read from; `null` means [rootBundle].
  ///
  /// Nullable rather than defaulted to `rootBundle` in the constructor so this
  /// class stays `const`-constructible: reading [rootBundle] touches
  /// `ServicesBinding`, and resolving it eagerly would bind the initializer to a
  /// live binding at construction time rather than at load time.
  final AssetBundle? bundle;

  final String assetKey;

  @override
  final String seedId;

  @override
  Future<String> loadSeedJson() => (bundle ?? rootBundle).loadString(assetKey);
}

/// What [DatabaseInitializer.ensureSeeded] did.
sealed class SeedOutcome {
  const SeedOutcome();
}

/// The seed was applied: [manualEntries] manuals and [inventoryParts] parts were
/// written at asset revision [revision].
class SeedApplied extends SeedOutcome {
  const SeedApplied({
    required this.revision,
    required this.manualEntries,
    required this.inventoryParts,
    required this.previousRevision,
  });

  final int revision;
  final int manualEntries;
  final int inventoryParts;

  /// The revision that was already stored, or `null` on a genuine first launch.
  /// Non-null means this run *re-seeded* over existing content.
  final int? previousRevision;

  /// True when nothing had ever been seeded into this database before.
  bool get wasFirstLaunch => previousRevision == null;

  @override
  String toString() =>
      'SeedApplied(revision: $revision, manuals: $manualEntries, '
      'parts: $inventoryParts, previousRevision: $previousRevision)';
}

/// The stored marker already covers the asset's revision, so nothing was written.
class SeedSkipped extends SeedOutcome {
  const SeedSkipped({
    required this.storedRevision,
    required this.assetRevision,
  });

  final int storedRevision;
  final int assetRevision;

  @override
  String toString() =>
      'SeedSkipped(stored: $storedRevision, asset: $assetRevision)';
}

/// Applies the bundled seed dataset to the database on first launch.
///
/// Two invariants shape the implementation, and both come out of the Task 1.2
/// review:
///
/// * **Manual rows go through [DatabaseService.upsertManualEntries]**, never a raw
///   insert, so fault codes are canonicalised and the FTS5 sync triggers fire.
///   Writing `manual_entries` by any other path leaves the index stale, and
///   `SELECT COUNT(*) FROM manual_fts` would not notice — it is answered from the
///   content table on an external-content index.
/// * **The write is one transaction.** A seed that inserted the manuals, then threw
///   on the inventory, would leave a database that is seeded enough to look healthy
///   and store a marker it has not earned. Nothing is written unless everything is.
///
/// The asset is parsed and fully validated *before* the transaction opens, so a
/// malformed asset cannot half-apply.
class DatabaseInitializer {
  DatabaseInitializer({required DatabaseService database, SeedSource? source})
    : _db = database,
      _source = source ?? const AssetBundleSeedSource();

  final DatabaseService _db;
  final SeedSource _source;

  /// Seeds the database if the bundled asset is newer than what was applied.
  ///
  /// Returns [SeedSkipped] when the stored marker's revision already covers the
  /// asset — the normal path on every launch after the first. This is what keeps
  /// seeding from clobbering `inventory_parts.stock`, which the agent reads and
  /// field use decrements; a bumped asset revision *is* a deliberate overwrite.
  ///
  /// Throws [SeedFormatException] if the asset is malformed, and rethrows whatever
  /// [SeedSource.loadSeedJson] throws if it cannot be read. Both are build defects:
  /// failing loudly at startup is more useful than an app that runs with no manual.
  Future<SeedOutcome> ensureSeeded() async {
    final bundle = SeedBundle.parse(await _source.loadSeedJson());

    // Read the marker *before* the transaction. A concurrent second call is not a
    // scenario this class defends against (there is one initializer, invoked once
    // at startup) — and if it happened, the writes are idempotent upserts, so the
    // cost is duplicated work rather than a corrupt result.
    final stored = await _db.seedMarker(_source.seedId);
    if (stored != null && stored.revision >= bundle.revision) {
      return SeedSkipped(
        storedRevision: stored.revision,
        assetRevision: bundle.revision,
      );
    }

    await _db.transaction(() async {
      await _db.upsertManualEntries(bundle.manualEntries);
      await _db.upsertInventoryParts(bundle.inventoryParts);
      await _db.recordSeedMarker(id: _source.seedId, revision: bundle.revision);
    });

    return SeedApplied(
      revision: bundle.revision,
      manualEntries: bundle.manualEntries.length,
      inventoryParts: bundle.inventoryParts.length,
      previousRevision: stored?.revision,
    );
  }
}
