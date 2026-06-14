/// Parsing for the first-launch seed asset (`assets/elevator_manual_seed.json`).
///
/// The asset is a **build input**, like Task 1.7's model URL and digest: it ships
/// inside the bundle and nothing at runtime can repair it. So it is validated
/// completely *before* a single row is written — a malformed asset must be a typed
/// [SeedFormatException] at parse time, not a half-applied seed discovered later
/// by a retrieval test returning two manuals instead of three.
///
/// Schema:
/// ```json
/// {
///   "revision": 1,
///   "manual_entries": [ { "id": …, "section": …, "code": …, "title": …,
///                         "symptoms": …, "procedure": …,
///                         "required_tools": [...], "required_parts": [...] } ],
///   "inventory_parts": [ { "sku": …, "name": …, "stock": …, "location": … } ]
/// }
/// ```
library;

import 'dart:convert';

import 'database_service.dart';
import 'tables.dart';
import 'tables/manual_fts_table.dart';

/// The seed asset failed to parse or violated a documented invariant.
///
/// A distinct type rather than [FormatException] so a caller can tell "the bundled
/// asset is wrong" (a build defect) apart from any other decode failure.
class SeedFormatException implements Exception {
  SeedFormatException(this.message);

  final String message;

  @override
  String toString() => 'SeedFormatException: $message';
}

/// A parsed, validated seed dataset.
class SeedBundle {
  const SeedBundle({
    required this.revision,
    required this.manualEntries,
    required this.inventoryParts,
  });

  /// Monotonically increasing dataset version. Compared against the stored
  /// [SeedMarkerRow.revision] to decide whether seeding runs at all.
  final int revision;

  /// Manual entries with fault codes already canonicalised.
  final List<ManualEntryRow> manualEntries;

  /// Inventory rows with SKUs already canonicalised.
  final List<InventoryPartRow> inventoryParts;

  /// Parses [json] (the raw asset text) into a validated bundle.
  ///
  /// Throws [SeedFormatException] on anything the loader cannot honestly apply:
  /// a non-object root, a missing or non-integer `revision`, a missing dataset, a
  /// row missing a required field, a blank id/code/sku, or a **duplicate** id or
  /// sku within the asset.
  ///
  /// Duplicates are rejected rather than deduplicated because the upsert that
  /// applies this bundle is last-write-wins: a duplicated id would seed silently
  /// and leave a row count one short of what the asset appears to declare, which is
  /// precisely the kind of near-miss no assertion in this task's ACs would catch.
  static SeedBundle parse(String json) {
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException catch (e) {
      throw SeedFormatException('seed asset is not valid JSON: ${e.message}');
    }
    if (decoded is! Map<String, Object?>) {
      throw SeedFormatException(
        'seed asset root must be a JSON object with "revision", '
        '"manual_entries" and "inventory_parts" keys',
      );
    }

    final revision = decoded['revision'];
    if (revision is! int) {
      throw SeedFormatException(
        'seed asset "revision" must be an integer, got '
        '${revision == null ? 'nothing' : revision.runtimeType}',
      );
    }

    final manuals = _requireList(
      decoded,
      'manual_entries',
    ).map(_manualEntry).toList(growable: false);
    final parts = _requireList(
      decoded,
      'inventory_parts',
    ).map(_inventoryPart).toList(growable: false);

    _rejectDuplicates(manuals.map((m) => m.id), 'manual_entries', 'id');
    _rejectDuplicates(parts.map((p) => p.sku), 'inventory_parts', 'sku');

    return SeedBundle(
      revision: revision,
      manualEntries: manuals,
      inventoryParts: parts,
    );
  }
}

List<Map<String, Object?>> _requireList(Map<String, Object?> root, String key) {
  final value = root[key];
  if (value is! List) {
    throw SeedFormatException(
      'seed asset "$key" must be a JSON array, got '
      '${value == null ? 'nothing' : value.runtimeType}',
    );
  }
  return value
      .map((e) {
        if (e is! Map<String, Object?>) {
          throw SeedFormatException(
            'every "$key" element must be a JSON object',
          );
        }
        return e;
      })
      .toList(growable: false);
}

ManualEntryRow _manualEntry(Map<String, Object?> json) {
  final id = _requireText(json, 'id', context: 'manual_entries');
  return ManualEntryRow(
    id: id,
    section: _requireText(json, 'section', context: 'manual_entries[$id]'),
    // Canonicalised here as well as in `upsertManualEntries`, so the parsed
    // bundle a test inspects already holds the form that will be stored.
    code: normalizeFaultCode(
      _requireText(json, 'code', context: 'manual_entries[$id]'),
    ),
    title: _requireText(json, 'title', context: 'manual_entries[$id]'),
    symptoms: _requireText(json, 'symptoms', context: 'manual_entries[$id]'),
    procedure: _requireText(json, 'procedure', context: 'manual_entries[$id]'),
    requiredTools: encodeStringList(
      _optionalStringList(
        json,
        'required_tools',
        context: 'manual_entries[$id]',
      ),
    ),
    requiredParts: encodeStringList(
      _optionalStringList(
        json,
        'required_parts',
        context: 'manual_entries[$id]',
      ),
    ),
  );
}

InventoryPartRow _inventoryPart(Map<String, Object?> json) {
  final sku = normalizeSku(
    _requireText(json, 'sku', context: 'inventory_parts'),
  );
  final stock = json['stock'];
  if (stock is! int) {
    throw SeedFormatException(
      'inventory_parts[$sku] "stock" must be an integer, got '
      '${stock == null ? 'nothing' : stock.runtimeType}',
    );
  }
  if (stock < 0) {
    throw SeedFormatException(
      'inventory_parts[$sku] "stock" must not be negative, got $stock',
    );
  }
  final location = json['location'];
  if (location != null && location is! String) {
    throw SeedFormatException(
      'inventory_parts[$sku] "location" must be a string when present',
    );
  }
  return InventoryPartRow(
    sku: sku,
    name: _requireText(json, 'name', context: 'inventory_parts[$sku]'),
    stock: stock,
    location: location as String?,
  );
}

/// Reads a required, non-blank string field.
///
/// Blank is rejected, not just absent: an empty `code` or `sku` is a key that no
/// lookup can ever match, and `normalizeFaultCode('  ')` yields `''`, which
/// [DatabaseService.manualEntryByCode] short-circuits to `null` — a row that exists
/// and is permanently unreachable.
String _requireText(
  Map<String, Object?> json,
  String field, {
  required String context,
}) {
  final value = json[field];
  if (value is! String) {
    throw SeedFormatException(
      '$context "$field" must be a string, got '
      '${value == null ? 'nothing' : value.runtimeType}',
    );
  }
  if (value.trim().isEmpty) {
    throw SeedFormatException('$context "$field" must not be blank');
  }
  return value;
}

/// Reads an optional array-of-strings field, defaulting to empty.
///
/// A present-but-wrong value is an error rather than a silent empty list: the
/// `ManualEntryLists` decoder already degrades malformed *stored* JSON to `[]`, and
/// letting the parser do the same would make a typo in the asset indistinguishable
/// from a procedure that genuinely needs no tools — while 1.4's TC-RAG-COMP-02
/// asserts a tool name reaches the prompt.
List<String> _optionalStringList(
  Map<String, Object?> json,
  String field, {
  required String context,
}) {
  final value = json[field];
  if (value == null) return const [];
  if (value is! List) {
    throw SeedFormatException(
      '$context "$field" must be a JSON array when present',
    );
  }
  return value
      .map((e) {
        if (e is! String) {
          throw SeedFormatException(
            '$context "$field" must contain only strings',
          );
        }
        return e;
      })
      .toList(growable: false);
}

void _rejectDuplicates(Iterable<String> keys, String dataset, String field) {
  final seen = <String>{};
  for (final key in keys) {
    if (!seen.add(key)) {
      throw SeedFormatException(
        '$dataset contains duplicate $field "$key"; the seed upsert is '
        'last-write-wins, so a duplicate would silently seed one row short',
      );
    }
  }
}
