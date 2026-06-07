import 'dart:convert';

import 'package:drift/drift.dart';

/// Storage for the Apex-9 technical manual, split deliberately in two:
///
/// * [ManualEntries] — the **structured** row. Every field a caller needs to
///   render or ground a prompt lives here, including the fault `code`, which is
///   matched **exactly** on this column and is *not* fed to full-text search:
///   `E-102` tokenizes into the junk token `e` plus the number `102`, so FTS
///   would both dilute the index and lose the identifier's precision.
/// * `manual_fts` — an FTS5 **index** over the four prose columns (`title`,
///   `symptoms`, `procedure`, `section`), declared in `database_service.drift`
///   with the `porter` tokenizer so morphological variants match
///   (`squealing` ↔ `squeal`, `vibrating` ↔ `vibration`). It is an
///   *external-content* table: the text is stored once, here, and triggers keep
///   the index in sync.
///
/// Column names on this table are therefore load-bearing — `title`, `symptoms`,
/// `procedure` and `section` must keep matching the FTS5 column list.

/// A single troubleshooting entry from the Apex-9 service manual.
@DataClassName('ManualEntryRow')
@TableIndex(name: 'idx_manual_entries_code', columns: {#code})
class ManualEntries extends Table {
  /// Stable document identifier, e.g. `apex_9_err_102`.
  TextColumn get id => text()();

  /// Manual chapter the entry belongs to, e.g. `Brake Systems`.
  TextColumn get section => text()();

  /// Controller fault code, e.g. `E-102`. Stored canonically (trimmed,
  /// upper-cased) and queried by exact match — never through FTS.
  TextColumn get code => text()();

  /// Entry heading, e.g. `Traction Brake Pad Wear & Vibration`.
  TextColumn get title => text()();

  /// Free-text symptom description a technician would recognise.
  TextColumn get symptoms => text()();

  /// Ordered repair steps.
  TextColumn get procedure => text()();

  /// JSON array of tool names, e.g. `["Torx T20","Digital Caliper"]`.
  ///
  /// Kept as raw JSON text rather than a drift type converter so that the
  /// generated row class keeps value equality (a converted `List<String>` field
  /// compares by identity, which silently breaks row-equality assertions).
  /// Decode through the `ManualEntryLists` extension in `database_service.dart`.
  TextColumn get requiredTools => text().withDefault(const Constant('[]'))();

  /// JSON array of part SKUs, e.g. `["BRK-990-XP"]`.
  TextColumn get requiredParts => text().withDefault(const Constant('[]'))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Canonical form of a fault code: trimmed and upper-cased, so `" e-102 "` and
/// `"E-102"` are the same key. Applied on write and on lookup.
String normalizeFaultCode(String code) => code.trim().toUpperCase();

/// Decodes a JSON string array, tolerating malformed/legacy values by returning
/// an empty list rather than throwing inside a UI or prompt build.
///
/// Used by the `ManualEntryLists` extension in `database_service.dart`, which is
/// where the generated `ManualEntryRow` class is visible.
List<String> decodeStringList(String raw) {
  if (raw.trim().isEmpty) return const [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    return decoded.whereType<String>().toList(growable: false);
  } on FormatException {
    return const [];
  }
}

/// Encodes a list of strings for the JSON text columns on [ManualEntries].
String encodeStringList(Iterable<String> values) =>
    jsonEncode(values.toList(growable: false));
