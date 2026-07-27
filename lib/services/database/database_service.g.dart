// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'database_service.dart';

// ignore_for_file: type=lint
class $TechniciansTable extends Technicians
    with TableInfo<$TechniciansTable, TechnicianRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TechniciansTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _fullNameMeta = const VerificationMeta(
    'fullName',
  );
  @override
  late final GeneratedColumn<String> fullName = GeneratedColumn<String>(
    'full_name',
    aliasedName,
    false,
    additionalChecks: GeneratedColumn.checkTextLength(
      minTextLength: 1,
      maxTextLength: 120,
    ),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _employeeIdMeta = const VerificationMeta(
    'employeeId',
  );
  @override
  late final GeneratedColumn<String> employeeId = GeneratedColumn<String>(
    'employee_id',
    aliasedName,
    false,
    additionalChecks: GeneratedColumn.checkTextLength(
      minTextLength: 1,
      maxTextLength: 40,
    ),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _regionMeta = const VerificationMeta('region');
  @override
  late final GeneratedColumn<String> region = GeneratedColumn<String>(
    'region',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _certificationLevelMeta =
      const VerificationMeta('certificationLevel');
  @override
  late final GeneratedColumn<int> certificationLevel = GeneratedColumn<int>(
    'certification_level',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(1),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    fullName,
    employeeId,
    region,
    certificationLevel,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'technicians';
  @override
  VerificationContext validateIntegrity(
    Insertable<TechnicianRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('full_name')) {
      context.handle(
        _fullNameMeta,
        fullName.isAcceptableOrUnknown(data['full_name']!, _fullNameMeta),
      );
    } else if (isInserting) {
      context.missing(_fullNameMeta);
    }
    if (data.containsKey('employee_id')) {
      context.handle(
        _employeeIdMeta,
        employeeId.isAcceptableOrUnknown(data['employee_id']!, _employeeIdMeta),
      );
    } else if (isInserting) {
      context.missing(_employeeIdMeta);
    }
    if (data.containsKey('region')) {
      context.handle(
        _regionMeta,
        region.isAcceptableOrUnknown(data['region']!, _regionMeta),
      );
    }
    if (data.containsKey('certification_level')) {
      context.handle(
        _certificationLevelMeta,
        certificationLevel.isAcceptableOrUnknown(
          data['certification_level']!,
          _certificationLevelMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  TechnicianRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return TechnicianRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      fullName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}full_name'],
      )!,
      employeeId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}employee_id'],
      )!,
      region: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}region'],
      ),
      certificationLevel: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}certification_level'],
      )!,
    );
  }

  @override
  $TechniciansTable createAlias(String alias) {
    return $TechniciansTable(attachedDatabase, alias);
  }
}

class TechnicianRow extends DataClass implements Insertable<TechnicianRow> {
  /// Stable technician identifier (e.g. an employee UUID).
  final String id;
  final String fullName;

  /// Human-facing employee number printed on the badge.
  final String employeeId;

  /// Service region the technician is assigned to (nullable — not always set).
  final String? region;

  /// Certification tier gating which procedures the technician may perform.
  final int certificationLevel;
  const TechnicianRow({
    required this.id,
    required this.fullName,
    required this.employeeId,
    this.region,
    required this.certificationLevel,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['full_name'] = Variable<String>(fullName);
    map['employee_id'] = Variable<String>(employeeId);
    if (!nullToAbsent || region != null) {
      map['region'] = Variable<String>(region);
    }
    map['certification_level'] = Variable<int>(certificationLevel);
    return map;
  }

  TechniciansCompanion toCompanion(bool nullToAbsent) {
    return TechniciansCompanion(
      id: Value(id),
      fullName: Value(fullName),
      employeeId: Value(employeeId),
      region: region == null && nullToAbsent
          ? const Value.absent()
          : Value(region),
      certificationLevel: Value(certificationLevel),
    );
  }

  factory TechnicianRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return TechnicianRow(
      id: serializer.fromJson<String>(json['id']),
      fullName: serializer.fromJson<String>(json['fullName']),
      employeeId: serializer.fromJson<String>(json['employeeId']),
      region: serializer.fromJson<String?>(json['region']),
      certificationLevel: serializer.fromJson<int>(json['certificationLevel']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'fullName': serializer.toJson<String>(fullName),
      'employeeId': serializer.toJson<String>(employeeId),
      'region': serializer.toJson<String?>(region),
      'certificationLevel': serializer.toJson<int>(certificationLevel),
    };
  }

  TechnicianRow copyWith({
    String? id,
    String? fullName,
    String? employeeId,
    Value<String?> region = const Value.absent(),
    int? certificationLevel,
  }) => TechnicianRow(
    id: id ?? this.id,
    fullName: fullName ?? this.fullName,
    employeeId: employeeId ?? this.employeeId,
    region: region.present ? region.value : this.region,
    certificationLevel: certificationLevel ?? this.certificationLevel,
  );
  TechnicianRow copyWithCompanion(TechniciansCompanion data) {
    return TechnicianRow(
      id: data.id.present ? data.id.value : this.id,
      fullName: data.fullName.present ? data.fullName.value : this.fullName,
      employeeId: data.employeeId.present
          ? data.employeeId.value
          : this.employeeId,
      region: data.region.present ? data.region.value : this.region,
      certificationLevel: data.certificationLevel.present
          ? data.certificationLevel.value
          : this.certificationLevel,
    );
  }

  @override
  String toString() {
    return (StringBuffer('TechnicianRow(')
          ..write('id: $id, ')
          ..write('fullName: $fullName, ')
          ..write('employeeId: $employeeId, ')
          ..write('region: $region, ')
          ..write('certificationLevel: $certificationLevel')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, fullName, employeeId, region, certificationLevel);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TechnicianRow &&
          other.id == this.id &&
          other.fullName == this.fullName &&
          other.employeeId == this.employeeId &&
          other.region == this.region &&
          other.certificationLevel == this.certificationLevel);
}

class TechniciansCompanion extends UpdateCompanion<TechnicianRow> {
  final Value<String> id;
  final Value<String> fullName;
  final Value<String> employeeId;
  final Value<String?> region;
  final Value<int> certificationLevel;
  final Value<int> rowid;
  const TechniciansCompanion({
    this.id = const Value.absent(),
    this.fullName = const Value.absent(),
    this.employeeId = const Value.absent(),
    this.region = const Value.absent(),
    this.certificationLevel = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  TechniciansCompanion.insert({
    required String id,
    required String fullName,
    required String employeeId,
    this.region = const Value.absent(),
    this.certificationLevel = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       fullName = Value(fullName),
       employeeId = Value(employeeId);
  static Insertable<TechnicianRow> custom({
    Expression<String>? id,
    Expression<String>? fullName,
    Expression<String>? employeeId,
    Expression<String>? region,
    Expression<int>? certificationLevel,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (fullName != null) 'full_name': fullName,
      if (employeeId != null) 'employee_id': employeeId,
      if (region != null) 'region': region,
      if (certificationLevel != null) 'certification_level': certificationLevel,
      if (rowid != null) 'rowid': rowid,
    });
  }

  TechniciansCompanion copyWith({
    Value<String>? id,
    Value<String>? fullName,
    Value<String>? employeeId,
    Value<String?>? region,
    Value<int>? certificationLevel,
    Value<int>? rowid,
  }) {
    return TechniciansCompanion(
      id: id ?? this.id,
      fullName: fullName ?? this.fullName,
      employeeId: employeeId ?? this.employeeId,
      region: region ?? this.region,
      certificationLevel: certificationLevel ?? this.certificationLevel,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (fullName.present) {
      map['full_name'] = Variable<String>(fullName.value);
    }
    if (employeeId.present) {
      map['employee_id'] = Variable<String>(employeeId.value);
    }
    if (region.present) {
      map['region'] = Variable<String>(region.value);
    }
    if (certificationLevel.present) {
      map['certification_level'] = Variable<int>(certificationLevel.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TechniciansCompanion(')
          ..write('id: $id, ')
          ..write('fullName: $fullName, ')
          ..write('employeeId: $employeeId, ')
          ..write('region: $region, ')
          ..write('certificationLevel: $certificationLevel, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $InventoryPartsTable extends InventoryParts
    with TableInfo<$InventoryPartsTable, InventoryPartRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $InventoryPartsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _skuMeta = const VerificationMeta('sku');
  @override
  late final GeneratedColumn<String> sku = GeneratedColumn<String>(
    'sku',
    aliasedName,
    false,
    additionalChecks: GeneratedColumn.checkTextLength(
      minTextLength: 1,
      maxTextLength: 60,
    ),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    additionalChecks: GeneratedColumn.checkTextLength(
      minTextLength: 1,
      maxTextLength: 160,
    ),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _stockMeta = const VerificationMeta('stock');
  @override
  late final GeneratedColumn<int> stock = GeneratedColumn<int>(
    'stock',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _locationMeta = const VerificationMeta(
    'location',
  );
  @override
  late final GeneratedColumn<String> location = GeneratedColumn<String>(
    'location',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [sku, name, stock, location];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'inventory_parts';
  @override
  VerificationContext validateIntegrity(
    Insertable<InventoryPartRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('sku')) {
      context.handle(
        _skuMeta,
        sku.isAcceptableOrUnknown(data['sku']!, _skuMeta),
      );
    } else if (isInserting) {
      context.missing(_skuMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('stock')) {
      context.handle(
        _stockMeta,
        stock.isAcceptableOrUnknown(data['stock']!, _stockMeta),
      );
    }
    if (data.containsKey('location')) {
      context.handle(
        _locationMeta,
        location.isAcceptableOrUnknown(data['location']!, _locationMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {sku};
  @override
  InventoryPartRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return InventoryPartRow(
      sku: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sku'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      stock: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}stock'],
      )!,
      location: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}location'],
      ),
    );
  }

  @override
  $InventoryPartsTable createAlias(String alias) {
    return $InventoryPartsTable(attachedDatabase, alias);
  }
}

class InventoryPartRow extends DataClass
    implements Insertable<InventoryPartRow> {
  /// Stock-keeping unit, e.g. `BRK-990-XP`.
  final String sku;
  final String name;

  /// Units currently on hand.
  final int stock;

  /// Warehouse location, e.g. `Aisle 4, Shelf B`.
  final String? location;
  const InventoryPartRow({
    required this.sku,
    required this.name,
    required this.stock,
    this.location,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['sku'] = Variable<String>(sku);
    map['name'] = Variable<String>(name);
    map['stock'] = Variable<int>(stock);
    if (!nullToAbsent || location != null) {
      map['location'] = Variable<String>(location);
    }
    return map;
  }

  InventoryPartsCompanion toCompanion(bool nullToAbsent) {
    return InventoryPartsCompanion(
      sku: Value(sku),
      name: Value(name),
      stock: Value(stock),
      location: location == null && nullToAbsent
          ? const Value.absent()
          : Value(location),
    );
  }

  factory InventoryPartRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return InventoryPartRow(
      sku: serializer.fromJson<String>(json['sku']),
      name: serializer.fromJson<String>(json['name']),
      stock: serializer.fromJson<int>(json['stock']),
      location: serializer.fromJson<String?>(json['location']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'sku': serializer.toJson<String>(sku),
      'name': serializer.toJson<String>(name),
      'stock': serializer.toJson<int>(stock),
      'location': serializer.toJson<String?>(location),
    };
  }

  InventoryPartRow copyWith({
    String? sku,
    String? name,
    int? stock,
    Value<String?> location = const Value.absent(),
  }) => InventoryPartRow(
    sku: sku ?? this.sku,
    name: name ?? this.name,
    stock: stock ?? this.stock,
    location: location.present ? location.value : this.location,
  );
  InventoryPartRow copyWithCompanion(InventoryPartsCompanion data) {
    return InventoryPartRow(
      sku: data.sku.present ? data.sku.value : this.sku,
      name: data.name.present ? data.name.value : this.name,
      stock: data.stock.present ? data.stock.value : this.stock,
      location: data.location.present ? data.location.value : this.location,
    );
  }

  @override
  String toString() {
    return (StringBuffer('InventoryPartRow(')
          ..write('sku: $sku, ')
          ..write('name: $name, ')
          ..write('stock: $stock, ')
          ..write('location: $location')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(sku, name, stock, location);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is InventoryPartRow &&
          other.sku == this.sku &&
          other.name == this.name &&
          other.stock == this.stock &&
          other.location == this.location);
}

class InventoryPartsCompanion extends UpdateCompanion<InventoryPartRow> {
  final Value<String> sku;
  final Value<String> name;
  final Value<int> stock;
  final Value<String?> location;
  final Value<int> rowid;
  const InventoryPartsCompanion({
    this.sku = const Value.absent(),
    this.name = const Value.absent(),
    this.stock = const Value.absent(),
    this.location = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  InventoryPartsCompanion.insert({
    required String sku,
    required String name,
    this.stock = const Value.absent(),
    this.location = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : sku = Value(sku),
       name = Value(name);
  static Insertable<InventoryPartRow> custom({
    Expression<String>? sku,
    Expression<String>? name,
    Expression<int>? stock,
    Expression<String>? location,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (sku != null) 'sku': sku,
      if (name != null) 'name': name,
      if (stock != null) 'stock': stock,
      if (location != null) 'location': location,
      if (rowid != null) 'rowid': rowid,
    });
  }

  InventoryPartsCompanion copyWith({
    Value<String>? sku,
    Value<String>? name,
    Value<int>? stock,
    Value<String?>? location,
    Value<int>? rowid,
  }) {
    return InventoryPartsCompanion(
      sku: sku ?? this.sku,
      name: name ?? this.name,
      stock: stock ?? this.stock,
      location: location ?? this.location,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (sku.present) {
      map['sku'] = Variable<String>(sku.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (stock.present) {
      map['stock'] = Variable<int>(stock.value);
    }
    if (location.present) {
      map['location'] = Variable<String>(location.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('InventoryPartsCompanion(')
          ..write('sku: $sku, ')
          ..write('name: $name, ')
          ..write('stock: $stock, ')
          ..write('location: $location, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $WorkOrdersTable extends WorkOrders
    with TableInfo<$WorkOrdersTable, WorkOrderRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $WorkOrdersTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _faultCodeMeta = const VerificationMeta(
    'faultCode',
  );
  @override
  late final GeneratedColumn<String> faultCode = GeneratedColumn<String>(
    'fault_code',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _summaryMeta = const VerificationMeta(
    'summary',
  );
  @override
  late final GeneratedColumn<String> summary = GeneratedColumn<String>(
    'summary',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _technicianIdMeta = const VerificationMeta(
    'technicianId',
  );
  @override
  late final GeneratedColumn<String> technicianId = GeneratedColumn<String>(
    'technician_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES technicians (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('open'),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    faultCode,
    summary,
    technicianId,
    status,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'work_orders';
  @override
  VerificationContext validateIntegrity(
    Insertable<WorkOrderRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('fault_code')) {
      context.handle(
        _faultCodeMeta,
        faultCode.isAcceptableOrUnknown(data['fault_code']!, _faultCodeMeta),
      );
    }
    if (data.containsKey('summary')) {
      context.handle(
        _summaryMeta,
        summary.isAcceptableOrUnknown(data['summary']!, _summaryMeta),
      );
    } else if (isInserting) {
      context.missing(_summaryMeta);
    }
    if (data.containsKey('technician_id')) {
      context.handle(
        _technicianIdMeta,
        technicianId.isAcceptableOrUnknown(
          data['technician_id']!,
          _technicianIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_technicianIdMeta);
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  WorkOrderRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return WorkOrderRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      faultCode: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}fault_code'],
      ),
      summary: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}summary'],
      )!,
      technicianId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}technician_id'],
      )!,
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $WorkOrdersTable createAlias(String alias) {
    return $WorkOrdersTable(attachedDatabase, alias);
  }
}

class WorkOrderRow extends DataClass implements Insertable<WorkOrderRow> {
  /// Work-order identifier.
  final String id;

  /// Fault code that triggered the order (e.g. `E-102`), when known.
  final String? faultCode;

  /// Short description of the reported problem.
  final String summary;

  /// Technician the order is assigned to.
  final String technicianId;

  /// Lifecycle state: `open`, `in_progress`, `closed`.
  final String status;
  final DateTime createdAt;
  const WorkOrderRow({
    required this.id,
    this.faultCode,
    required this.summary,
    required this.technicianId,
    required this.status,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    if (!nullToAbsent || faultCode != null) {
      map['fault_code'] = Variable<String>(faultCode);
    }
    map['summary'] = Variable<String>(summary);
    map['technician_id'] = Variable<String>(technicianId);
    map['status'] = Variable<String>(status);
    map['created_at'] = Variable<DateTime>(createdAt);
    return map;
  }

  WorkOrdersCompanion toCompanion(bool nullToAbsent) {
    return WorkOrdersCompanion(
      id: Value(id),
      faultCode: faultCode == null && nullToAbsent
          ? const Value.absent()
          : Value(faultCode),
      summary: Value(summary),
      technicianId: Value(technicianId),
      status: Value(status),
      createdAt: Value(createdAt),
    );
  }

  factory WorkOrderRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return WorkOrderRow(
      id: serializer.fromJson<String>(json['id']),
      faultCode: serializer.fromJson<String?>(json['faultCode']),
      summary: serializer.fromJson<String>(json['summary']),
      technicianId: serializer.fromJson<String>(json['technicianId']),
      status: serializer.fromJson<String>(json['status']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'faultCode': serializer.toJson<String?>(faultCode),
      'summary': serializer.toJson<String>(summary),
      'technicianId': serializer.toJson<String>(technicianId),
      'status': serializer.toJson<String>(status),
      'createdAt': serializer.toJson<DateTime>(createdAt),
    };
  }

  WorkOrderRow copyWith({
    String? id,
    Value<String?> faultCode = const Value.absent(),
    String? summary,
    String? technicianId,
    String? status,
    DateTime? createdAt,
  }) => WorkOrderRow(
    id: id ?? this.id,
    faultCode: faultCode.present ? faultCode.value : this.faultCode,
    summary: summary ?? this.summary,
    technicianId: technicianId ?? this.technicianId,
    status: status ?? this.status,
    createdAt: createdAt ?? this.createdAt,
  );
  WorkOrderRow copyWithCompanion(WorkOrdersCompanion data) {
    return WorkOrderRow(
      id: data.id.present ? data.id.value : this.id,
      faultCode: data.faultCode.present ? data.faultCode.value : this.faultCode,
      summary: data.summary.present ? data.summary.value : this.summary,
      technicianId: data.technicianId.present
          ? data.technicianId.value
          : this.technicianId,
      status: data.status.present ? data.status.value : this.status,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('WorkOrderRow(')
          ..write('id: $id, ')
          ..write('faultCode: $faultCode, ')
          ..write('summary: $summary, ')
          ..write('technicianId: $technicianId, ')
          ..write('status: $status, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, faultCode, summary, technicianId, status, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is WorkOrderRow &&
          other.id == this.id &&
          other.faultCode == this.faultCode &&
          other.summary == this.summary &&
          other.technicianId == this.technicianId &&
          other.status == this.status &&
          other.createdAt == this.createdAt);
}

class WorkOrdersCompanion extends UpdateCompanion<WorkOrderRow> {
  final Value<String> id;
  final Value<String?> faultCode;
  final Value<String> summary;
  final Value<String> technicianId;
  final Value<String> status;
  final Value<DateTime> createdAt;
  final Value<int> rowid;
  const WorkOrdersCompanion({
    this.id = const Value.absent(),
    this.faultCode = const Value.absent(),
    this.summary = const Value.absent(),
    this.technicianId = const Value.absent(),
    this.status = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  WorkOrdersCompanion.insert({
    required String id,
    this.faultCode = const Value.absent(),
    required String summary,
    required String technicianId,
    this.status = const Value.absent(),
    required DateTime createdAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       summary = Value(summary),
       technicianId = Value(technicianId),
       createdAt = Value(createdAt);
  static Insertable<WorkOrderRow> custom({
    Expression<String>? id,
    Expression<String>? faultCode,
    Expression<String>? summary,
    Expression<String>? technicianId,
    Expression<String>? status,
    Expression<DateTime>? createdAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (faultCode != null) 'fault_code': faultCode,
      if (summary != null) 'summary': summary,
      if (technicianId != null) 'technician_id': technicianId,
      if (status != null) 'status': status,
      if (createdAt != null) 'created_at': createdAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  WorkOrdersCompanion copyWith({
    Value<String>? id,
    Value<String?>? faultCode,
    Value<String>? summary,
    Value<String>? technicianId,
    Value<String>? status,
    Value<DateTime>? createdAt,
    Value<int>? rowid,
  }) {
    return WorkOrdersCompanion(
      id: id ?? this.id,
      faultCode: faultCode ?? this.faultCode,
      summary: summary ?? this.summary,
      technicianId: technicianId ?? this.technicianId,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (faultCode.present) {
      map['fault_code'] = Variable<String>(faultCode.value);
    }
    if (summary.present) {
      map['summary'] = Variable<String>(summary.value);
    }
    if (technicianId.present) {
      map['technician_id'] = Variable<String>(technicianId.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('WorkOrdersCompanion(')
          ..write('id: $id, ')
          ..write('faultCode: $faultCode, ')
          ..write('summary: $summary, ')
          ..write('technicianId: $technicianId, ')
          ..write('status: $status, ')
          ..write('createdAt: $createdAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$DatabaseService extends GeneratedDatabase {
  _$DatabaseService(QueryExecutor e) : super(e);
  $DatabaseServiceManager get managers => $DatabaseServiceManager(this);
  late final $TechniciansTable technicians = $TechniciansTable(this);
  late final $InventoryPartsTable inventoryParts = $InventoryPartsTable(this);
  late final $WorkOrdersTable workOrders = $WorkOrdersTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    technicians,
    inventoryParts,
    workOrders,
  ];
  @override
  StreamQueryUpdateRules get streamUpdateRules => const StreamQueryUpdateRules([
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'technicians',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('work_orders', kind: UpdateKind.delete)],
    ),
  ]);
}

typedef $$TechniciansTableCreateCompanionBuilder =
    TechniciansCompanion Function({
      required String id,
      required String fullName,
      required String employeeId,
      Value<String?> region,
      Value<int> certificationLevel,
      Value<int> rowid,
    });
typedef $$TechniciansTableUpdateCompanionBuilder =
    TechniciansCompanion Function({
      Value<String> id,
      Value<String> fullName,
      Value<String> employeeId,
      Value<String?> region,
      Value<int> certificationLevel,
      Value<int> rowid,
    });

final class $$TechniciansTableReferences
    extends
        BaseReferences<_$DatabaseService, $TechniciansTable, TechnicianRow> {
  $$TechniciansTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$WorkOrdersTable, List<WorkOrderRow>>
  _workOrdersRefsTable(_$DatabaseService db) => MultiTypedResultKey.fromTable(
    db.workOrders,
    aliasName: 'technicians__id__work_orders__technician_id',
  );

  $$WorkOrdersTableProcessedTableManager get workOrdersRefs {
    final manager = $$WorkOrdersTableTableManager(
      $_db,
      $_db.workOrders,
    ).filter((f) => f.technicianId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_workOrdersRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$TechniciansTableFilterComposer
    extends Composer<_$DatabaseService, $TechniciansTable> {
  $$TechniciansTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get fullName => $composableBuilder(
    column: $table.fullName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get employeeId => $composableBuilder(
    column: $table.employeeId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get region => $composableBuilder(
    column: $table.region,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get certificationLevel => $composableBuilder(
    column: $table.certificationLevel,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> workOrdersRefs(
    Expression<bool> Function($$WorkOrdersTableFilterComposer f) f,
  ) {
    final $$WorkOrdersTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.workOrders,
      getReferencedColumn: (t) => t.technicianId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$WorkOrdersTableFilterComposer(
            $db: $db,
            $table: $db.workOrders,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$TechniciansTableOrderingComposer
    extends Composer<_$DatabaseService, $TechniciansTable> {
  $$TechniciansTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get fullName => $composableBuilder(
    column: $table.fullName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get employeeId => $composableBuilder(
    column: $table.employeeId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get region => $composableBuilder(
    column: $table.region,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get certificationLevel => $composableBuilder(
    column: $table.certificationLevel,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$TechniciansTableAnnotationComposer
    extends Composer<_$DatabaseService, $TechniciansTable> {
  $$TechniciansTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get fullName =>
      $composableBuilder(column: $table.fullName, builder: (column) => column);

  GeneratedColumn<String> get employeeId => $composableBuilder(
    column: $table.employeeId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get region =>
      $composableBuilder(column: $table.region, builder: (column) => column);

  GeneratedColumn<int> get certificationLevel => $composableBuilder(
    column: $table.certificationLevel,
    builder: (column) => column,
  );

  Expression<T> workOrdersRefs<T extends Object>(
    Expression<T> Function($$WorkOrdersTableAnnotationComposer a) f,
  ) {
    final $$WorkOrdersTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.workOrders,
      getReferencedColumn: (t) => t.technicianId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$WorkOrdersTableAnnotationComposer(
            $db: $db,
            $table: $db.workOrders,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$TechniciansTableTableManager
    extends
        RootTableManager<
          _$DatabaseService,
          $TechniciansTable,
          TechnicianRow,
          $$TechniciansTableFilterComposer,
          $$TechniciansTableOrderingComposer,
          $$TechniciansTableAnnotationComposer,
          $$TechniciansTableCreateCompanionBuilder,
          $$TechniciansTableUpdateCompanionBuilder,
          (TechnicianRow, $$TechniciansTableReferences),
          TechnicianRow,
          PrefetchHooks Function({bool workOrdersRefs})
        > {
  $$TechniciansTableTableManager(_$DatabaseService db, $TechniciansTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TechniciansTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$TechniciansTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$TechniciansTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> fullName = const Value.absent(),
                Value<String> employeeId = const Value.absent(),
                Value<String?> region = const Value.absent(),
                Value<int> certificationLevel = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TechniciansCompanion(
                id: id,
                fullName: fullName,
                employeeId: employeeId,
                region: region,
                certificationLevel: certificationLevel,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String fullName,
                required String employeeId,
                Value<String?> region = const Value.absent(),
                Value<int> certificationLevel = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TechniciansCompanion.insert(
                id: id,
                fullName: fullName,
                employeeId: employeeId,
                region: region,
                certificationLevel: certificationLevel,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$TechniciansTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({workOrdersRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [if (workOrdersRefs) db.workOrders],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (workOrdersRefs)
                    await $_getPrefetchedData<
                      TechnicianRow,
                      $TechniciansTable,
                      WorkOrderRow
                    >(
                      currentTable: table,
                      referencedTable: $$TechniciansTableReferences
                          ._workOrdersRefsTable(db),
                      managerFromTypedResult: (p0) =>
                          $$TechniciansTableReferences(
                            db,
                            table,
                            p0,
                          ).workOrdersRefs,
                      referencedItemsForCurrentItem: (item, referencedItems) =>
                          referencedItems.where(
                            (e) => e.technicianId == item.id,
                          ),
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$TechniciansTableProcessedTableManager =
    ProcessedTableManager<
      _$DatabaseService,
      $TechniciansTable,
      TechnicianRow,
      $$TechniciansTableFilterComposer,
      $$TechniciansTableOrderingComposer,
      $$TechniciansTableAnnotationComposer,
      $$TechniciansTableCreateCompanionBuilder,
      $$TechniciansTableUpdateCompanionBuilder,
      (TechnicianRow, $$TechniciansTableReferences),
      TechnicianRow,
      PrefetchHooks Function({bool workOrdersRefs})
    >;
typedef $$InventoryPartsTableCreateCompanionBuilder =
    InventoryPartsCompanion Function({
      required String sku,
      required String name,
      Value<int> stock,
      Value<String?> location,
      Value<int> rowid,
    });
typedef $$InventoryPartsTableUpdateCompanionBuilder =
    InventoryPartsCompanion Function({
      Value<String> sku,
      Value<String> name,
      Value<int> stock,
      Value<String?> location,
      Value<int> rowid,
    });

class $$InventoryPartsTableFilterComposer
    extends Composer<_$DatabaseService, $InventoryPartsTable> {
  $$InventoryPartsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get sku => $composableBuilder(
    column: $table.sku,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get stock => $composableBuilder(
    column: $table.stock,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get location => $composableBuilder(
    column: $table.location,
    builder: (column) => ColumnFilters(column),
  );
}

class $$InventoryPartsTableOrderingComposer
    extends Composer<_$DatabaseService, $InventoryPartsTable> {
  $$InventoryPartsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get sku => $composableBuilder(
    column: $table.sku,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get stock => $composableBuilder(
    column: $table.stock,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get location => $composableBuilder(
    column: $table.location,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$InventoryPartsTableAnnotationComposer
    extends Composer<_$DatabaseService, $InventoryPartsTable> {
  $$InventoryPartsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get sku =>
      $composableBuilder(column: $table.sku, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<int> get stock =>
      $composableBuilder(column: $table.stock, builder: (column) => column);

  GeneratedColumn<String> get location =>
      $composableBuilder(column: $table.location, builder: (column) => column);
}

class $$InventoryPartsTableTableManager
    extends
        RootTableManager<
          _$DatabaseService,
          $InventoryPartsTable,
          InventoryPartRow,
          $$InventoryPartsTableFilterComposer,
          $$InventoryPartsTableOrderingComposer,
          $$InventoryPartsTableAnnotationComposer,
          $$InventoryPartsTableCreateCompanionBuilder,
          $$InventoryPartsTableUpdateCompanionBuilder,
          (
            InventoryPartRow,
            BaseReferences<
              _$DatabaseService,
              $InventoryPartsTable,
              InventoryPartRow
            >,
          ),
          InventoryPartRow,
          PrefetchHooks Function()
        > {
  $$InventoryPartsTableTableManager(
    _$DatabaseService db,
    $InventoryPartsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$InventoryPartsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$InventoryPartsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$InventoryPartsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> sku = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<int> stock = const Value.absent(),
                Value<String?> location = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => InventoryPartsCompanion(
                sku: sku,
                name: name,
                stock: stock,
                location: location,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String sku,
                required String name,
                Value<int> stock = const Value.absent(),
                Value<String?> location = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => InventoryPartsCompanion.insert(
                sku: sku,
                name: name,
                stock: stock,
                location: location,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$InventoryPartsTableProcessedTableManager =
    ProcessedTableManager<
      _$DatabaseService,
      $InventoryPartsTable,
      InventoryPartRow,
      $$InventoryPartsTableFilterComposer,
      $$InventoryPartsTableOrderingComposer,
      $$InventoryPartsTableAnnotationComposer,
      $$InventoryPartsTableCreateCompanionBuilder,
      $$InventoryPartsTableUpdateCompanionBuilder,
      (
        InventoryPartRow,
        BaseReferences<
          _$DatabaseService,
          $InventoryPartsTable,
          InventoryPartRow
        >,
      ),
      InventoryPartRow,
      PrefetchHooks Function()
    >;
typedef $$WorkOrdersTableCreateCompanionBuilder =
    WorkOrdersCompanion Function({
      required String id,
      Value<String?> faultCode,
      required String summary,
      required String technicianId,
      Value<String> status,
      required DateTime createdAt,
      Value<int> rowid,
    });
typedef $$WorkOrdersTableUpdateCompanionBuilder =
    WorkOrdersCompanion Function({
      Value<String> id,
      Value<String?> faultCode,
      Value<String> summary,
      Value<String> technicianId,
      Value<String> status,
      Value<DateTime> createdAt,
      Value<int> rowid,
    });

final class $$WorkOrdersTableReferences
    extends BaseReferences<_$DatabaseService, $WorkOrdersTable, WorkOrderRow> {
  $$WorkOrdersTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $TechniciansTable _technicianIdTable(_$DatabaseService db) =>
      db.technicians.createAlias('work_orders__technician_id__technicians__id');

  $$TechniciansTableProcessedTableManager get technicianId {
    final $_column = $_itemColumn<String>('technician_id')!;

    final manager = $$TechniciansTableTableManager(
      $_db,
      $_db.technicians,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_technicianIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$WorkOrdersTableFilterComposer
    extends Composer<_$DatabaseService, $WorkOrdersTable> {
  $$WorkOrdersTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get faultCode => $composableBuilder(
    column: $table.faultCode,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get summary => $composableBuilder(
    column: $table.summary,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  $$TechniciansTableFilterComposer get technicianId {
    final $$TechniciansTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.technicianId,
      referencedTable: $db.technicians,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TechniciansTableFilterComposer(
            $db: $db,
            $table: $db.technicians,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$WorkOrdersTableOrderingComposer
    extends Composer<_$DatabaseService, $WorkOrdersTable> {
  $$WorkOrdersTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get faultCode => $composableBuilder(
    column: $table.faultCode,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get summary => $composableBuilder(
    column: $table.summary,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  $$TechniciansTableOrderingComposer get technicianId {
    final $$TechniciansTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.technicianId,
      referencedTable: $db.technicians,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TechniciansTableOrderingComposer(
            $db: $db,
            $table: $db.technicians,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$WorkOrdersTableAnnotationComposer
    extends Composer<_$DatabaseService, $WorkOrdersTable> {
  $$WorkOrdersTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get faultCode =>
      $composableBuilder(column: $table.faultCode, builder: (column) => column);

  GeneratedColumn<String> get summary =>
      $composableBuilder(column: $table.summary, builder: (column) => column);

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  $$TechniciansTableAnnotationComposer get technicianId {
    final $$TechniciansTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.technicianId,
      referencedTable: $db.technicians,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$TechniciansTableAnnotationComposer(
            $db: $db,
            $table: $db.technicians,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$WorkOrdersTableTableManager
    extends
        RootTableManager<
          _$DatabaseService,
          $WorkOrdersTable,
          WorkOrderRow,
          $$WorkOrdersTableFilterComposer,
          $$WorkOrdersTableOrderingComposer,
          $$WorkOrdersTableAnnotationComposer,
          $$WorkOrdersTableCreateCompanionBuilder,
          $$WorkOrdersTableUpdateCompanionBuilder,
          (WorkOrderRow, $$WorkOrdersTableReferences),
          WorkOrderRow,
          PrefetchHooks Function({bool technicianId})
        > {
  $$WorkOrdersTableTableManager(_$DatabaseService db, $WorkOrdersTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$WorkOrdersTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$WorkOrdersTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$WorkOrdersTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String?> faultCode = const Value.absent(),
                Value<String> summary = const Value.absent(),
                Value<String> technicianId = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => WorkOrdersCompanion(
                id: id,
                faultCode: faultCode,
                summary: summary,
                technicianId: technicianId,
                status: status,
                createdAt: createdAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                Value<String?> faultCode = const Value.absent(),
                required String summary,
                required String technicianId,
                Value<String> status = const Value.absent(),
                required DateTime createdAt,
                Value<int> rowid = const Value.absent(),
              }) => WorkOrdersCompanion.insert(
                id: id,
                faultCode: faultCode,
                summary: summary,
                technicianId: technicianId,
                status: status,
                createdAt: createdAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$WorkOrdersTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({technicianId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (technicianId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.technicianId,
                                referencedTable: $$WorkOrdersTableReferences
                                    ._technicianIdTable(db),
                                referencedColumn: $$WorkOrdersTableReferences
                                    ._technicianIdTable(db)
                                    .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$WorkOrdersTableProcessedTableManager =
    ProcessedTableManager<
      _$DatabaseService,
      $WorkOrdersTable,
      WorkOrderRow,
      $$WorkOrdersTableFilterComposer,
      $$WorkOrdersTableOrderingComposer,
      $$WorkOrdersTableAnnotationComposer,
      $$WorkOrdersTableCreateCompanionBuilder,
      $$WorkOrdersTableUpdateCompanionBuilder,
      (WorkOrderRow, $$WorkOrdersTableReferences),
      WorkOrderRow,
      PrefetchHooks Function({bool technicianId})
    >;

class $DatabaseServiceManager {
  final _$DatabaseService _db;
  $DatabaseServiceManager(this._db);
  $$TechniciansTableTableManager get technicians =>
      $$TechniciansTableTableManager(_db, _db.technicians);
  $$InventoryPartsTableTableManager get inventoryParts =>
      $$InventoryPartsTableTableManager(_db, _db.inventoryParts);
  $$WorkOrdersTableTableManager get workOrders =>
      $$WorkOrdersTableTableManager(_db, _db.workOrders);
}
