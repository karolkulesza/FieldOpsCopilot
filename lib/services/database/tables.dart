import 'package:drift/drift.dart';

/// Drift table definitions for the local, encrypted field-service database.
///
/// Three domains cover the Tier 1 vertical slice: the technician using the
/// device, the spare-parts inventory the agent looks up, and the work orders a
/// diagnosis produces. Fault codes elsewhere in the app live in the manual/FTS
/// tables (Task 1.2) — these tables hold operational, per-technician data.

/// Profile of the technician signed in on this device.
@DataClassName('TechnicianRow')
class Technicians extends Table {
  /// Stable technician identifier (e.g. an employee UUID).
  TextColumn get id => text()();

  TextColumn get fullName => text().withLength(min: 1, max: 120)();

  /// Human-facing employee number printed on the badge.
  TextColumn get employeeId => text().withLength(min: 1, max: 40)();

  /// Service region the technician is assigned to (nullable — not always set).
  TextColumn get region => text().nullable()();

  /// Certification tier gating which procedures the technician may perform.
  IntColumn get certificationLevel =>
      integer().withDefault(const Constant(1))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Maximum stored length of a part SKU, for callers that must check the bound
/// *before* the column does — `SeedBundle.parse` in particular, whose contract is
/// that a bad asset fails before any write is attempted.
///
/// **This must stay equal to the literal in [InventoryParts.sku]'s `withLength`,
/// and it cannot be shared with it.** Passing `max: kSkuMaxLength` instead of a
/// literal *compiles and analyzes cleanly* but silently drops the bound from the
/// generated code: `drift_dev` resolves `withLength`'s arguments at build time from
/// the source expression and does not fold a named constant, so the emitted
/// `checkTextLength(minTextLength: 1, maxTextLength: 60)` becomes
/// `checkTextLength(minTextLength: 1)` — the Dart-side length check disappears with
/// no error anywhere. (Found exactly that way: the CI codegen gate flagged the
/// regenerated file.) `kSkuMaxLengthAgreesWithColumn` in the test suite pins the two
/// together behaviourally, since the compiler cannot.
const int kSkuMaxLength = 60;

/// Maximum stored length of a part name. Same duplication rule as [kSkuMaxLength].
const int kPartNameMaxLength = 160;

/// Spare parts held in the local warehouse, keyed by SKU.
@DataClassName('InventoryPartRow')
class InventoryParts extends Table {
  /// Stock-keeping unit, e.g. `BRK-990-XP`. Stored canonically (trimmed,
  /// upper-cased) via [normalizeSku] and matched by exact equality.
  ///
  /// `COLLATE NOCASE` for the same reason `manual_entries.code` carries it, and
  /// it matters more here: from Task 1.5 onward the SKU in a lookup arrives from
  /// the *model*, inside a native function call, so its casing is whatever the
  /// weights felt like emitting. The collation applies to the implicit primary-key
  /// index too, so case-insensitive equality goes *through* the index instead of
  /// forcing `upper(sku)` and a table scan.
  ///
  /// As on `code`, `customConstraint` **replaces** drift's generated constraint
  /// string, so `NOT NULL` is restated by hand; `withLength` survives because it
  /// only ever produced a Dart-side check, never SQL.
  // The `60`/`160` literals below must stay equal to [kSkuMaxLength] and
  // [kPartNameMaxLength]; see those constants for why they cannot be referenced
  // here, and which test holds the pair together.
  TextColumn get sku => text()
      .withLength(min: 1, max: 60)
      .customConstraint('NOT NULL COLLATE NOCASE')();

  TextColumn get name => text().withLength(min: 1, max: 160)();

  /// Units currently on hand.
  IntColumn get stock => integer().withDefault(const Constant(0))();

  /// Warehouse location, e.g. `Aisle 4, Shelf B`.
  TextColumn get location => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {sku};
}

/// Canonical form of a part SKU: trimmed and upper-cased, mirroring
/// [normalizeFaultCode]. Applied on write and on lookup.
///
/// Whitespace is the half the `COLLATE NOCASE` collation cannot cover, and a SKU
/// dictated by voice (Tier 2) or emitted by the model arrives with both problems.
String normalizeSku(String sku) => sku.trim().toUpperCase();

/// Record of a seed dataset that has already been applied to this database.
///
/// This is what makes seeding a **first-launch** operation rather than a
/// launch-time overwrite. `inventory_parts.stock` is operational data — the agent
/// reads it and a technician consuming a part decrements it — so re-applying the
/// asset on every start would silently roll those changes back. One row per seed
/// dataset, keyed by name, holding the [revision] that was applied.
///
/// Re-seeding therefore happens only when the asset's revision moves, which *is*
/// a deliberate overwrite of both the manual text and the seeded stock levels.
/// A real fleet would sync inventory from a server rather than seed it; that
/// distinction is Appendix A's offline-sync story, not this table's job.
@DataClassName('SeedMarkerRow')
class SeedMarkers extends Table {
  /// Dataset name, e.g. `elevator_manual_seed`.
  TextColumn get id => text()();

  /// The `revision` field of the asset that was applied.
  IntColumn get revision => integer()();

  /// When the seed ran, for support/debugging only — nothing branches on it.
  DateTimeColumn get appliedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// A repair job raised for an Apex-9 unit.
@DataClassName('WorkOrderRow')
class WorkOrders extends Table {
  /// Work-order identifier.
  TextColumn get id => text()();

  /// Fault code that triggered the order (e.g. `E-102`), when known.
  TextColumn get faultCode => text().nullable()();

  /// Short description of the reported problem.
  TextColumn get summary => text()();

  /// Technician the order is assigned to.
  TextColumn get technicianId =>
      text().references(Technicians, #id, onDelete: KeyAction.cascade)();

  /// Lifecycle state: `open`, `in_progress`, `closed`.
  TextColumn get status => text().withDefault(const Constant('open'))();

  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
