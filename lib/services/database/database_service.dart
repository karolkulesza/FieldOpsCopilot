import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import 'fts_query_sanitizer.dart';
import 'tables.dart';
import 'tables/manual_fts_table.dart';

part 'database_service.g.dart';

/// How the encryption key text should be interpreted by `PRAGMA key`.
enum DatabaseKeyKind {
  /// A human-readable passphrase; SQLite derives the raw key via the cipher KDF.
  passphrase,

  /// A key supplied as hex, bound with the `x'...'` syntax. SQLite3MultipleCiphers
  /// only bypasses key derivation when the hex decodes to the cipher's exact raw
  /// key length (32 bytes / 64 hex chars for chacha20); any other length is still
  /// run through the KDF. [_assertHex] validates hex shape only — enforce the raw
  /// key length here when a raw-key path is actually wired up.
  hex,
}

/// Encrypted local database for FieldOps Copilot.
///
/// Encryption is provided by **SQLite3MultipleCiphers**, bundled through the
/// `sqlite3` package's `source: sqlite3mc` build hook (see `pubspec.yaml`) — the
/// modern replacement for `sqlcipher_flutter_libs`. The active cipher is the
/// SQLite3MultipleCiphers default, **ChaCha20-Poly1305** (an AEAD scheme), with
/// KDF iterations pinned explicitly rather than left to the library default.
///
/// The key is applied in the [NativeDatabase] `setup` callback via `PRAGMA key`,
/// before drift issues any statement. A `SELECT` against `sqlite_master` inside
/// the same callback forces the cipher to attempt decryption at open time, so an
/// incorrect key fails fast with a [SqliteException] instead of surfacing later.
@DriftDatabase(
  tables: [Technicians, InventoryParts, WorkOrders, ManualEntries, SeedMarkers],
  include: {'database_service.drift'},
)
class DatabaseService extends _$DatabaseService {
  DatabaseService(super.e);

  /// Opens (or creates) an encrypted database at [file].
  factory DatabaseService.encrypted({
    required File file,
    required String encryptionKey,
    DatabaseKeyKind keyKind = DatabaseKeyKind.passphrase,
  }) {
    return DatabaseService(
      _openEncrypted(file: file, key: encryptionKey, keyKind: keyKind),
    );
  }

  /// Opens the app's default encrypted database in the application-support
  /// directory. Used by the runtime provider; tests use [DatabaseService.encrypted].
  static Future<DatabaseService> openDefault({
    required String encryptionKey,
    DatabaseKeyKind keyKind = DatabaseKeyKind.passphrase,
  }) async {
    final dir = await getApplicationSupportDirectory();
    final file = File(p.join(dir.path, 'field_ops.db'));
    return DatabaseService.encrypted(
      file: file,
      encryptionKey: encryptionKey,
      keyKind: keyKind,
    );
  }

  @override
  int get schemaVersion => 3;

  /// v1 shipped the technician/inventory/work-order tables; v2 adds the manual
  /// table, its FTS5 index and the triggers that keep them in sync;
  /// v3 adds the seed-marker table and gives `inventory_parts.sku` the
  /// `COLLATE NOCASE` collation.
  ///
  /// `createTable` emits only `CREATE TABLE`, so every non-table entity has to be
  /// created explicitly — including [idxManualEntriesCode]. Miss one and upgraded
  /// installs diverge permanently from fresh ones (which get everything via
  /// `createAll`).
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await m.createTable(manualEntries);
        await m.create(idxManualEntriesCode);
        await m.create(manualFts);
        await m.create(manualEntriesAfterInsert);
        await m.create(manualEntriesAfterDelete);
        await m.create(manualEntriesAfterUpdate);
      }
      if (from < 3) {
        await m.createTable(seedMarkers);
        // A column *collation* is part of the table definition, and SQLite has no
        // `ALTER COLUMN`, so NOCASE on `sku` can only arrive by rewriting the
        // table — which is exactly what an empty [TableMigration] does (create
        // under a temp name with the current schema, copy the rows, swap). No
        // `columnTransformer` is needed because no column's *type or value*
        // changes.
        //
        // Two consequences worth stating. The rewrite renumbers rowids, which is
        // harmless here (nothing indexes `inventory_parts` by rowid — unlike
        // `manual_entries`, whose FTS index does). And if a pre-v3 install held
        // two SKUs differing only in case, rebuilding the primary key under
        // NOCASE would fail as a uniqueness violation; no writer for this table
        // existed before this task, so that state is unreachable in practice
        // rather than handled.
        await m.alterTable(TableMigration(inventoryParts));
      }
    },
  );

  /// Inserts a technician, or replaces the existing row with the same id.
  Future<void> upsertTechnician(TechnicianRow row) =>
      into(technicians).insertOnConflictUpdate(row);

  /// Returns the technician with [id], or `null` if none exists.
  Future<TechnicianRow?> technicianById(String id) =>
      (select(technicians)..where((t) => t.id.equals(id))).getSingleOrNull();

  /// Inserts or replaces inventory rows, canonicalising each SKU on the way in so
  /// [inventoryPartBySku] can match exactly.
  ///
  /// Mirrors [upsertManualEntries] deliberately: the write path is what makes the
  /// stored form canonical, and the `COLLATE NOCASE` collation on the column is
  /// the backstop for rows written by some other path, not the primary mechanism.
  Future<void> upsertInventoryParts(Iterable<InventoryPartRow> parts) {
    final normalized = parts
        .map((p) => p.copyWith(sku: normalizeSku(p.sku)))
        .toList(growable: false);
    return batch(
      (b) => b.insertAllOnConflictUpdate(inventoryParts, normalized),
    );
  }

  /// Exact SKU lookup — the query the agent's `get_local_parts_inventory` tool is
  /// built on.
  ///
  /// [sku] is canonicalised before comparison, and `inventory_parts.sku` is
  /// declared `COLLATE NOCASE`, so `" brk-990-xp "` finds `BRK-990-XP` through the
  /// primary-key index. Returns `null` for an unknown SKU — a tool argument the
  /// model invented is a normal outcome, not an error.
  Future<InventoryPartRow?> inventoryPartBySku(String sku) {
    if (normalizeSku(sku).isEmpty) return Future.value();
    return inventoryPartBySkuQuery(sku).getSingleOrNull();
  }

  /// The statement [inventoryPartBySku] runs.
  ///
  /// Exposed for the same reason as [manualEntryByCodeQuery]: a test can assert
  /// the query plan of the SQL drift *actually emits*, which a hand-written
  /// equivalent would not catch if this method regressed to wrapping the column in
  /// `upper(...)`.
  SimpleSelectStatement<$InventoryPartsTable, InventoryPartRow>
  inventoryPartBySkuQuery(String sku) =>
      select(inventoryParts)..where((t) => t.sku.equals(normalizeSku(sku)));

  /// Every inventory row, ordered by SKU so callers and tests see a stable order.
  Future<List<InventoryPartRow>> allInventoryParts() =>
      (select(inventoryParts)..orderBy([(t) => OrderingTerm.asc(t.sku)])).get();

  /// The seed marker for [id], or `null` if that dataset was never applied.
  Future<SeedMarkerRow?> seedMarker(String id) =>
      (select(seedMarkers)..where((t) => t.id.equals(id))).getSingleOrNull();

  /// Records that seed dataset [id] has been applied at [revision].
  ///
  /// Called inside the seeding transaction, so the marker and the rows it vouches
  /// for commit together or not at all.
  Future<void> recordSeedMarker({
    required String id,
    required int revision,
    DateTime? appliedAt,
  }) => into(seedMarkers).insertOnConflictUpdate(
    SeedMarkerRow(
      id: id,
      revision: revision,
      appliedAt: appliedAt ?? DateTime.now(),
    ),
  );

  /// Inserts or replaces manual entries in a single transaction, canonicalising
  /// each fault code on the way in so [manualEntryByCode] can match exactly.
  ///
  /// Replacing a row fires the update trigger, so the FTS5 index follows.
  Future<void> upsertManualEntries(Iterable<ManualEntryRow> entries) {
    final normalized = entries
        .map((e) => e.copyWith(code: normalizeFaultCode(e.code)))
        .toList(growable: false);
    return batch((b) => b.insertAllOnConflictUpdate(manualEntries, normalized));
  }

  /// Exact fault-code lookup — the structured path, **not** full-text search.
  ///
  /// [code] is canonicalised before comparison, and `manual_entries.code` is
  /// declared `COLLATE NOCASE`, so `" e-204 "` finds `E-204` *through*
  /// `idx_manual_entries_code`. Comparing `upper(code)` instead would wrap the
  /// column in a function and force a full table scan.
  ///
  /// Returns `null` when the code is unknown, and the first match (by id) in the
  /// pathological case of a code shared by several entries.
  Future<ManualEntryRow?> manualEntryByCode(String code) {
    if (normalizeFaultCode(code).isEmpty) return Future.value();
    return manualEntryByCodeQuery(code).getSingleOrNull();
  }

  /// The statement [manualEntryByCode] runs.
  ///
  /// Canonicalises [code] itself rather than trusting the caller, so it is
  /// correct for any caller — the `NOCASE` collation covers case but not the
  /// surrounding whitespace a dictated code can carry.
  ///
  /// Exposed so a test can inspect the SQL drift actually emits: asserting the
  /// query plan of a hand-written equivalent would keep passing if this method
  /// regressed to wrapping the column in `upper(...)`, which is exactly the
  /// regression worth guarding.
  SimpleSelectStatement<$ManualEntriesTable, ManualEntryRow>
  manualEntryByCodeQuery(String code) => select(manualEntries)
    ..where((t) => t.code.equals(normalizeFaultCode(code)))
    ..orderBy([(t) => OrderingTerm.asc(t.id)])
    ..limit(1);

  /// Ranked full-text search over the manual's prose columns.
  ///
  /// [rawQuery] is free technician text: it is sanitized by
  /// [FtsQuerySanitizer] before it reaches `MATCH`, because raw input can be an
  /// FTS5 *syntax error*, not merely a bad query. Text with no searchable term
  /// (whitespace, `"???"`) yields an empty list rather than an empty `MATCH`,
  /// which FTS5 rejects.
  Future<List<ManualEntryRow>> searchManualEntries(
    String rawQuery, {
    int limit = 10,
  }) => searchManualEntriesByTerms(
    FtsQuerySanitizer.terms(rawQuery),
    limit: limit,
  );

  /// Ranked full-text search over an already-extracted term list.
  ///
  /// This is the entry point for the retrieval router, which pulls a
  /// fault code out of the raw text, handles it through [manualEntryByCode], and
  /// searches on what remains. Routing through here rather than the generated
  /// `searchManualEntriesRanked` keeps the empty-expression guard attached to the
  /// expression builder: a query consisting *only* of a fault code leaves no
  /// residual terms, and an empty `MATCH` is an FTS5 syntax error, not an empty
  /// result.
  Future<List<ManualEntryRow>> searchManualEntriesByTerms(
    Iterable<String> terms, {
    int limit = 10,
  }) async {
    final match = FtsQuerySanitizer.sanitizeTerms(terms);
    if (match.isEmpty) return const [];
    return searchManualEntriesRanked(match, limit).get();
  }

  /// Number of documents present in the FTS5 **index**, which is not the same as
  /// the `manual_entries` row count.
  ///
  /// On an external-content table an unconstrained `SELECT COUNT(*) FROM
  /// manual_fts` is answered by scanning the *content* table, so it returns 3 even
  /// with every sync trigger dropped. `manual_fts_docsize` is the shadow table
  /// holding one row per indexed document, so reading it is what actually proves
  /// the triggers ran.
  ///
  /// `manual_fts_docsize` exists because fts5 defaults to `columnsize=1`; adding
  /// `columnsize=0` to the virtual-table options would drop the shadow table and
  /// break this query. `readsFrom` names `manual_entries` as well as the index,
  /// because writes to the content table are what change the answer.
  Future<int> manualFtsIndexedDocumentCount() async {
    final row = await customSelect(
      'SELECT COUNT(*) AS c FROM manual_fts_docsize',
      readsFrom: {manualFts, manualEntries},
    ).getSingle();
    return row.read<int>('c');
  }

  /// Rebuilds the FTS5 index from `manual_entries`.
  ///
  /// The index is keyed by `manual_entries.rowid`. Nothing in the app renumbers
  /// rowids today, but an operation that does (`VACUUM INTO`, a table rewrite in
  /// a future migration) would silently desync the index; this is the recovery.
  Future<void> rebuildManualFtsIndex() =>
      customStatement("INSERT INTO manual_fts(manual_fts) VALUES('rebuild')");
}

/// Decoding helpers for the JSON-encoded list columns on `manual_entries`.
///
/// Declared here rather than beside the table because `ManualEntryRow` is
/// generated into this library's `part` file.
extension ManualEntryLists on ManualEntryRow {
  /// Tool names required by this procedure.
  List<String> get requiredToolsList => decodeStringList(requiredTools);

  /// Part SKUs required by this procedure.
  List<String> get requiredPartsList => decodeStringList(requiredParts);
}

/// Number of KDF iterations pinned for the ChaCha20 key-derivation. Pinned
/// explicitly (rather than relying on the library default) so the derivation
/// cost is stable and auditable across SQLite3MultipleCiphers versions.
const int _kdfIterations = 256000;

/// Builds an encrypted drift connection. Opening is deferred via [LazyDatabase]
/// so the file/directory work happens off the constructor path.
LazyDatabase _openEncrypted({
  required File file,
  required String key,
  required DatabaseKeyKind keyKind,
}) {
  return LazyDatabase(() async {
    await file.parent.create(recursive: true);
    return NativeDatabase(
      file,
      setup: (rawDb) => _applyKey(rawDb, key: key, keyKind: keyKind),
    );
  });
}

/// Applies the cipher configuration and key to a freshly opened raw connection.
void _applyKey(
  Database rawDb, {
  required String key,
  required DatabaseKeyKind keyKind,
}) {
  assert(
    _debugHasCipherSupport(rawDb),
    'sqlite3 was built without SQLite3MultipleCiphers — set '
    '`hooks: user_defines: sqlite3: source: sqlite3mc` in pubspec.yaml.',
  );

  // Configure the cipher *before* keying so the KDF params take effect.
  rawDb.execute("PRAGMA cipher = 'chacha20';");
  rawDb.execute('PRAGMA kdf_iter = $_kdfIterations;');

  final keyLiteral = switch (keyKind) {
    // Bind hex bytes via x'..'; the KDF is bypassed only for an exact-length
    // raw key (see [DatabaseKeyKind.hex]), otherwise it still applies.
    DatabaseKeyKind.hex => "x'${_assertHex(key)}'",
    // Passphrase: single-quote-escaped string literal; SQLite runs the KDF.
    DatabaseKeyKind.passphrase => "'${key.replaceAll("'", "''")}'",
  };
  rawDb.execute('PRAGMA key = $keyLiteral;');

  // Force the cipher to touch the file now so a wrong key fails at open time.
  rawDb.execute('SELECT count(*) FROM sqlite_master;');
}

/// True when the loaded sqlite3 is the encryption-capable build. When
/// SQLite3MultipleCiphers is present, `PRAGMA cipher;` reports the active codec.
bool _debugHasCipherSupport(Database rawDb) {
  try {
    return rawDb.select('PRAGMA cipher;').isNotEmpty;
  } on SqliteException {
    return false;
  }
}

/// Validates that [value] is a non-empty even-length hex string and returns it.
String _assertHex(String value) {
  final ok =
      value.isNotEmpty &&
      value.length.isEven &&
      RegExp(r'^[0-9a-fA-F]+$').hasMatch(value);
  if (!ok) {
    throw ArgumentError.value(
      value,
      'encryptionKey',
      'hex key must be a non-empty, even-length hex string',
    );
  }
  return value;
}
