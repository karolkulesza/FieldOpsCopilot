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

/// Spare parts held in the local warehouse, keyed by SKU.
@DataClassName('InventoryPartRow')
class InventoryParts extends Table {
  /// Stock-keeping unit, e.g. `BRK-990-XP`.
  TextColumn get sku => text().withLength(min: 1, max: 60)();

  TextColumn get name => text().withLength(min: 1, max: 160)();

  /// Units currently on hand.
  IntColumn get stock => integer().withDefault(const Constant(0))();

  /// Warehouse location, e.g. `Aisle 4, Shelf B`.
  TextColumn get location => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {sku};
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
