import 'dart:io';
import 'dart:typed_data';

import 'package:field_ops_copilot/services/database/database_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

/// Unit-tier coverage for the encrypted Drift database.
///
/// These run on the host against the SQLite3MultipleCiphers build bundled by the
/// `sqlite3` build hook (`source: sqlite3mc`), so the encryption PRAGMAs behave
/// exactly as they do on device.
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('fieldops_db_test');
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  File dbFile(String name) => File('${tempDir.path}/$name');

  const technician = TechnicianRow(
    id: 'tech-001',
    fullName: 'Zenon Plaintextowski',
    employeeId: 'EMP-4471',
    region: 'PL-South',
    certificationLevel: 3,
  );

  group('encryption', () {
    // TC-DB-ENC-01: opening with a key succeeds and the file is not plaintext.
    test('opens with a key and writes a non-plaintext file', () async {
      final file = dbFile('enc01.db');
      final db = DatabaseService.encrypted(
        file: file,
        encryptionKey: 'correct-horse-battery-staple',
      );

      // No exception on open/write.
      await db.upsertTechnician(technician);
      await db.close();

      expect(file.existsSync(), isTrue);
      final bytes = await file.readAsBytes();

      // An unencrypted SQLite file starts with the "SQLite format 3\x00"
      // magic; the encrypted file must not.
      expect(
        _startsWithSqliteMagic(bytes),
        isFalse,
        reason: 'file header should be encrypted, not the SQLite magic',
      );

      // The distinctive technician name must not be readable in the raw bytes.
      expect(
        _containsUtf8(bytes, 'Zenon Plaintextowski'),
        isFalse,
        reason: 'row data should be encrypted at rest',
      );
    });

    // TC-DB-ENC-02: reopening with the wrong key is rejected.
    test('rejects the wrong key on reopen', () async {
      final file = dbFile('enc02.db');

      final db = DatabaseService.encrypted(
        file: file,
        encryptionKey: 'the-real-key',
      );
      await db.upsertTechnician(technician);
      await db.close();

      final reopened = DatabaseService.encrypted(
        file: file,
        encryptionKey: 'a-different-wrong-key',
      );
      addTearDown(() async {
        try {
          await reopened.close();
        } catch (_) {
          /* connection never opened cleanly */
        }
      });

      // The wrong key fails when the cipher first touches the file.
      await expectLater(
        reopened.technicianById('tech-001'),
        throwsA(isA<SqliteException>()),
      );
    });

    test('reopening with the correct key reads the data back', () async {
      final file = dbFile('enc03.db');

      final first = DatabaseService.encrypted(
        file: file,
        encryptionKey: 'stable-key',
      );
      await first.upsertTechnician(technician);
      await first.close();

      final second = DatabaseService.encrypted(
        file: file,
        encryptionKey: 'stable-key',
      );
      addTearDown(second.close);

      final row = await second.technicianById('tech-001');
      expect(row, isNotNull);
      expect(row!.fullName, 'Zenon Plaintextowski');
    });
  });

  group('CRUD', () {
    // TC-DB-CRUD-01: technician round-trips with exact field equality.
    test('technician round-trip returns the exact record', () async {
      final db = DatabaseService.encrypted(
        file: dbFile('crud01.db'),
        encryptionKey: 'crud-key',
      );
      addTearDown(db.close);

      await db.upsertTechnician(technician);
      final fetched = await db.technicianById('tech-001');

      expect(fetched, technician);
    });
  });
}

/// The 16-byte magic prefix of an unencrypted SQLite 3 database file.
bool _startsWithSqliteMagic(Uint8List bytes) {
  const magic = 'SQLite format 3\x00';
  if (bytes.length < magic.length) return false;
  for (var i = 0; i < magic.length; i++) {
    if (bytes[i] != magic.codeUnitAt(i)) return false;
  }
  return true;
}

/// Whether the UTF-8 encoding of [needle] appears anywhere in [haystack].
bool _containsUtf8(Uint8List haystack, String needle) {
  final n = needle.codeUnits;
  if (n.isEmpty || haystack.length < n.length) return false;
  for (var i = 0; i <= haystack.length - n.length; i++) {
    var match = true;
    for (var j = 0; j < n.length; j++) {
      if (haystack[i + j] != n[j]) {
        match = false;
        break;
      }
    }
    if (match) return true;
  }
  return false;
}
