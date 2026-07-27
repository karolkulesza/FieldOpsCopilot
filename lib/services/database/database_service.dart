import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import 'tables.dart';

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
@DriftDatabase(tables: [Technicians, InventoryParts, WorkOrders])
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
  int get schemaVersion => 1;

  /// Inserts a technician, or replaces the existing row with the same id.
  Future<void> upsertTechnician(TechnicianRow row) =>
      into(technicians).insertOnConflictUpdate(row);

  /// Returns the technician with [id], or `null` if none exists.
  Future<TechnicianRow?> technicianById(String id) =>
      (select(technicians)..where((t) => t.id.equals(id))).getSingleOrNull();
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
