// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'database_service.dart';

// ignore_for_file: type=lint
class $ManualEntriesTable extends ManualEntries
    with TableInfo<$ManualEntriesTable, ManualEntryRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ManualEntriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sectionMeta = const VerificationMeta(
    'section',
  );
  @override
  late final GeneratedColumn<String> section = GeneratedColumn<String>(
    'section',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _codeMeta = const VerificationMeta('code');
  @override
  late final GeneratedColumn<String> code = GeneratedColumn<String>(
    'code',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: 'NOT NULL COLLATE NOCASE',
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _symptomsMeta = const VerificationMeta(
    'symptoms',
  );
  @override
  late final GeneratedColumn<String> symptoms = GeneratedColumn<String>(
    'symptoms',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _procedureMeta = const VerificationMeta(
    'procedure',
  );
  @override
  late final GeneratedColumn<String> procedure = GeneratedColumn<String>(
    'procedure',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _requiredToolsMeta = const VerificationMeta(
    'requiredTools',
  );
  @override
  late final GeneratedColumn<String> requiredTools = GeneratedColumn<String>(
    'required_tools',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('[]'),
  );
  static const VerificationMeta _requiredPartsMeta = const VerificationMeta(
    'requiredParts',
  );
  @override
  late final GeneratedColumn<String> requiredParts = GeneratedColumn<String>(
    'required_parts',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('[]'),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    section,
    code,
    title,
    symptoms,
    procedure,
    requiredTools,
    requiredParts,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'manual_entries';
  @override
  VerificationContext validateIntegrity(
    Insertable<ManualEntryRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('section')) {
      context.handle(
        _sectionMeta,
        section.isAcceptableOrUnknown(data['section']!, _sectionMeta),
      );
    } else if (isInserting) {
      context.missing(_sectionMeta);
    }
    if (data.containsKey('code')) {
      context.handle(
        _codeMeta,
        code.isAcceptableOrUnknown(data['code']!, _codeMeta),
      );
    } else if (isInserting) {
      context.missing(_codeMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('symptoms')) {
      context.handle(
        _symptomsMeta,
        symptoms.isAcceptableOrUnknown(data['symptoms']!, _symptomsMeta),
      );
    } else if (isInserting) {
      context.missing(_symptomsMeta);
    }
    if (data.containsKey('procedure')) {
      context.handle(
        _procedureMeta,
        procedure.isAcceptableOrUnknown(data['procedure']!, _procedureMeta),
      );
    } else if (isInserting) {
      context.missing(_procedureMeta);
    }
    if (data.containsKey('required_tools')) {
      context.handle(
        _requiredToolsMeta,
        requiredTools.isAcceptableOrUnknown(
          data['required_tools']!,
          _requiredToolsMeta,
        ),
      );
    }
    if (data.containsKey('required_parts')) {
      context.handle(
        _requiredPartsMeta,
        requiredParts.isAcceptableOrUnknown(
          data['required_parts']!,
          _requiredPartsMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ManualEntryRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ManualEntryRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      section: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}section'],
      )!,
      code: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}code'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      symptoms: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}symptoms'],
      )!,
      procedure: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}procedure'],
      )!,
      requiredTools: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}required_tools'],
      )!,
      requiredParts: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}required_parts'],
      )!,
    );
  }

  @override
  $ManualEntriesTable createAlias(String alias) {
    return $ManualEntriesTable(attachedDatabase, alias);
  }
}

class ManualEntryRow extends DataClass implements Insertable<ManualEntryRow> {
  /// Stable document identifier, e.g. `apex_9_err_102`.
  final String id;

  /// Manual chapter the entry belongs to, e.g. `Brake Systems`.
  final String section;

  /// Controller fault code, e.g. `E-102`. Stored canonically (trimmed,
  /// upper-cased) and queried by exact match — never through FTS.
  ///
  /// `COLLATE NOCASE` rather than an `upper(code)` comparison at query time:
  /// wrapping the column in a function makes `idx_manual_entries_code`
  /// unusable and forces a table scan, whereas the collation gives
  /// case-insensitive equality *through* the index — and still matches rows
  /// written by a path that skipped [normalizeFaultCode].
  ///
  /// Note that `customConstraint` **replaces** drift's whole generated constraint
  /// string rather than adding to it, which is why `NOT NULL` is restated by
  /// hand. Anything added here later (a default, a check) has to go in this one
  /// string or it silently vanishes from the DDL.
  final String code;

  /// Entry heading, e.g. `Traction Brake Pad Wear & Vibration`.
  final String title;

  /// Free-text symptom description a technician would recognise.
  final String symptoms;

  /// Ordered repair steps.
  final String procedure;

  /// JSON array of tool names, e.g. `["Torx T20","Digital Caliper"]`.
  ///
  /// Kept as raw JSON text rather than a drift type converter so that the
  /// generated row class keeps value equality (a converted `List<String>` field
  /// compares by identity, which silently breaks row-equality assertions).
  /// Decode through the `ManualEntryLists` extension in `database_service.dart`.
  final String requiredTools;

  /// JSON array of part SKUs, e.g. `["BRK-990-XP"]`.
  final String requiredParts;
  const ManualEntryRow({
    required this.id,
    required this.section,
    required this.code,
    required this.title,
    required this.symptoms,
    required this.procedure,
    required this.requiredTools,
    required this.requiredParts,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['section'] = Variable<String>(section);
    map['code'] = Variable<String>(code);
    map['title'] = Variable<String>(title);
    map['symptoms'] = Variable<String>(symptoms);
    map['procedure'] = Variable<String>(procedure);
    map['required_tools'] = Variable<String>(requiredTools);
    map['required_parts'] = Variable<String>(requiredParts);
    return map;
  }

  ManualEntriesCompanion toCompanion(bool nullToAbsent) {
    return ManualEntriesCompanion(
      id: Value(id),
      section: Value(section),
      code: Value(code),
      title: Value(title),
      symptoms: Value(symptoms),
      procedure: Value(procedure),
      requiredTools: Value(requiredTools),
      requiredParts: Value(requiredParts),
    );
  }

  factory ManualEntryRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ManualEntryRow(
      id: serializer.fromJson<String>(json['id']),
      section: serializer.fromJson<String>(json['section']),
      code: serializer.fromJson<String>(json['code']),
      title: serializer.fromJson<String>(json['title']),
      symptoms: serializer.fromJson<String>(json['symptoms']),
      procedure: serializer.fromJson<String>(json['procedure']),
      requiredTools: serializer.fromJson<String>(json['requiredTools']),
      requiredParts: serializer.fromJson<String>(json['requiredParts']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'section': serializer.toJson<String>(section),
      'code': serializer.toJson<String>(code),
      'title': serializer.toJson<String>(title),
      'symptoms': serializer.toJson<String>(symptoms),
      'procedure': serializer.toJson<String>(procedure),
      'requiredTools': serializer.toJson<String>(requiredTools),
      'requiredParts': serializer.toJson<String>(requiredParts),
    };
  }

  ManualEntryRow copyWith({
    String? id,
    String? section,
    String? code,
    String? title,
    String? symptoms,
    String? procedure,
    String? requiredTools,
    String? requiredParts,
  }) => ManualEntryRow(
    id: id ?? this.id,
    section: section ?? this.section,
    code: code ?? this.code,
    title: title ?? this.title,
    symptoms: symptoms ?? this.symptoms,
    procedure: procedure ?? this.procedure,
    requiredTools: requiredTools ?? this.requiredTools,
    requiredParts: requiredParts ?? this.requiredParts,
  );
  ManualEntryRow copyWithCompanion(ManualEntriesCompanion data) {
    return ManualEntryRow(
      id: data.id.present ? data.id.value : this.id,
      section: data.section.present ? data.section.value : this.section,
      code: data.code.present ? data.code.value : this.code,
      title: data.title.present ? data.title.value : this.title,
      symptoms: data.symptoms.present ? data.symptoms.value : this.symptoms,
      procedure: data.procedure.present ? data.procedure.value : this.procedure,
      requiredTools: data.requiredTools.present
          ? data.requiredTools.value
          : this.requiredTools,
      requiredParts: data.requiredParts.present
          ? data.requiredParts.value
          : this.requiredParts,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ManualEntryRow(')
          ..write('id: $id, ')
          ..write('section: $section, ')
          ..write('code: $code, ')
          ..write('title: $title, ')
          ..write('symptoms: $symptoms, ')
          ..write('procedure: $procedure, ')
          ..write('requiredTools: $requiredTools, ')
          ..write('requiredParts: $requiredParts')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    section,
    code,
    title,
    symptoms,
    procedure,
    requiredTools,
    requiredParts,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ManualEntryRow &&
          other.id == this.id &&
          other.section == this.section &&
          other.code == this.code &&
          other.title == this.title &&
          other.symptoms == this.symptoms &&
          other.procedure == this.procedure &&
          other.requiredTools == this.requiredTools &&
          other.requiredParts == this.requiredParts);
}

class ManualEntriesCompanion extends UpdateCompanion<ManualEntryRow> {
  final Value<String> id;
  final Value<String> section;
  final Value<String> code;
  final Value<String> title;
  final Value<String> symptoms;
  final Value<String> procedure;
  final Value<String> requiredTools;
  final Value<String> requiredParts;
  final Value<int> rowid;
  const ManualEntriesCompanion({
    this.id = const Value.absent(),
    this.section = const Value.absent(),
    this.code = const Value.absent(),
    this.title = const Value.absent(),
    this.symptoms = const Value.absent(),
    this.procedure = const Value.absent(),
    this.requiredTools = const Value.absent(),
    this.requiredParts = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ManualEntriesCompanion.insert({
    required String id,
    required String section,
    required String code,
    required String title,
    required String symptoms,
    required String procedure,
    this.requiredTools = const Value.absent(),
    this.requiredParts = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       section = Value(section),
       code = Value(code),
       title = Value(title),
       symptoms = Value(symptoms),
       procedure = Value(procedure);
  static Insertable<ManualEntryRow> custom({
    Expression<String>? id,
    Expression<String>? section,
    Expression<String>? code,
    Expression<String>? title,
    Expression<String>? symptoms,
    Expression<String>? procedure,
    Expression<String>? requiredTools,
    Expression<String>? requiredParts,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (section != null) 'section': section,
      if (code != null) 'code': code,
      if (title != null) 'title': title,
      if (symptoms != null) 'symptoms': symptoms,
      if (procedure != null) 'procedure': procedure,
      if (requiredTools != null) 'required_tools': requiredTools,
      if (requiredParts != null) 'required_parts': requiredParts,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ManualEntriesCompanion copyWith({
    Value<String>? id,
    Value<String>? section,
    Value<String>? code,
    Value<String>? title,
    Value<String>? symptoms,
    Value<String>? procedure,
    Value<String>? requiredTools,
    Value<String>? requiredParts,
    Value<int>? rowid,
  }) {
    return ManualEntriesCompanion(
      id: id ?? this.id,
      section: section ?? this.section,
      code: code ?? this.code,
      title: title ?? this.title,
      symptoms: symptoms ?? this.symptoms,
      procedure: procedure ?? this.procedure,
      requiredTools: requiredTools ?? this.requiredTools,
      requiredParts: requiredParts ?? this.requiredParts,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (section.present) {
      map['section'] = Variable<String>(section.value);
    }
    if (code.present) {
      map['code'] = Variable<String>(code.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (symptoms.present) {
      map['symptoms'] = Variable<String>(symptoms.value);
    }
    if (procedure.present) {
      map['procedure'] = Variable<String>(procedure.value);
    }
    if (requiredTools.present) {
      map['required_tools'] = Variable<String>(requiredTools.value);
    }
    if (requiredParts.present) {
      map['required_parts'] = Variable<String>(requiredParts.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ManualEntriesCompanion(')
          ..write('id: $id, ')
          ..write('section: $section, ')
          ..write('code: $code, ')
          ..write('title: $title, ')
          ..write('symptoms: $symptoms, ')
          ..write('procedure: $procedure, ')
          ..write('requiredTools: $requiredTools, ')
          ..write('requiredParts: $requiredParts, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class ManualFts extends Table
    with TableInfo<ManualFts, ManualFt>, VirtualTableInfo<ManualFts, ManualFt> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  ManualFts(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: '',
  );
  static const VerificationMeta _symptomsMeta = const VerificationMeta(
    'symptoms',
  );
  late final GeneratedColumn<String> symptoms = GeneratedColumn<String>(
    'symptoms',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: '',
  );
  static const VerificationMeta _procedureMeta = const VerificationMeta(
    'procedure',
  );
  late final GeneratedColumn<String> procedure = GeneratedColumn<String>(
    'procedure',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: '',
  );
  static const VerificationMeta _sectionMeta = const VerificationMeta(
    'section',
  );
  late final GeneratedColumn<String> section = GeneratedColumn<String>(
    'section',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    $customConstraints: '',
  );
  @override
  List<GeneratedColumn> get $columns => [title, symptoms, procedure, section];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'manual_fts';
  @override
  VerificationContext validateIntegrity(
    Insertable<ManualFt> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('symptoms')) {
      context.handle(
        _symptomsMeta,
        symptoms.isAcceptableOrUnknown(data['symptoms']!, _symptomsMeta),
      );
    } else if (isInserting) {
      context.missing(_symptomsMeta);
    }
    if (data.containsKey('procedure')) {
      context.handle(
        _procedureMeta,
        procedure.isAcceptableOrUnknown(data['procedure']!, _procedureMeta),
      );
    } else if (isInserting) {
      context.missing(_procedureMeta);
    }
    if (data.containsKey('section')) {
      context.handle(
        _sectionMeta,
        section.isAcceptableOrUnknown(data['section']!, _sectionMeta),
      );
    } else if (isInserting) {
      context.missing(_sectionMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => const {};
  @override
  ManualFt map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ManualFt(
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      symptoms: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}symptoms'],
      )!,
      procedure: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}procedure'],
      )!,
      section: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}section'],
      )!,
    );
  }

  @override
  ManualFts createAlias(String alias) {
    return ManualFts(attachedDatabase, alias);
  }

  @override
  bool get dontWriteConstraints => true;
  @override
  String get moduleAndArgs =>
      'fts5(title, symptoms, procedure, section, content=manual_entries, content_rowid=rowid, tokenize=\'porter unicode61\')';
}

class ManualFt extends DataClass implements Insertable<ManualFt> {
  final String title;
  final String symptoms;
  final String procedure;
  final String section;
  const ManualFt({
    required this.title,
    required this.symptoms,
    required this.procedure,
    required this.section,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['title'] = Variable<String>(title);
    map['symptoms'] = Variable<String>(symptoms);
    map['procedure'] = Variable<String>(procedure);
    map['section'] = Variable<String>(section);
    return map;
  }

  ManualFtsCompanion toCompanion(bool nullToAbsent) {
    return ManualFtsCompanion(
      title: Value(title),
      symptoms: Value(symptoms),
      procedure: Value(procedure),
      section: Value(section),
    );
  }

  factory ManualFt.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ManualFt(
      title: serializer.fromJson<String>(json['title']),
      symptoms: serializer.fromJson<String>(json['symptoms']),
      procedure: serializer.fromJson<String>(json['procedure']),
      section: serializer.fromJson<String>(json['section']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'title': serializer.toJson<String>(title),
      'symptoms': serializer.toJson<String>(symptoms),
      'procedure': serializer.toJson<String>(procedure),
      'section': serializer.toJson<String>(section),
    };
  }

  ManualFt copyWith({
    String? title,
    String? symptoms,
    String? procedure,
    String? section,
  }) => ManualFt(
    title: title ?? this.title,
    symptoms: symptoms ?? this.symptoms,
    procedure: procedure ?? this.procedure,
    section: section ?? this.section,
  );
  ManualFt copyWithCompanion(ManualFtsCompanion data) {
    return ManualFt(
      title: data.title.present ? data.title.value : this.title,
      symptoms: data.symptoms.present ? data.symptoms.value : this.symptoms,
      procedure: data.procedure.present ? data.procedure.value : this.procedure,
      section: data.section.present ? data.section.value : this.section,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ManualFt(')
          ..write('title: $title, ')
          ..write('symptoms: $symptoms, ')
          ..write('procedure: $procedure, ')
          ..write('section: $section')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(title, symptoms, procedure, section);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ManualFt &&
          other.title == this.title &&
          other.symptoms == this.symptoms &&
          other.procedure == this.procedure &&
          other.section == this.section);
}

class ManualFtsCompanion extends UpdateCompanion<ManualFt> {
  final Value<String> title;
  final Value<String> symptoms;
  final Value<String> procedure;
  final Value<String> section;
  final Value<int> rowid;
  const ManualFtsCompanion({
    this.title = const Value.absent(),
    this.symptoms = const Value.absent(),
    this.procedure = const Value.absent(),
    this.section = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ManualFtsCompanion.insert({
    required String title,
    required String symptoms,
    required String procedure,
    required String section,
    this.rowid = const Value.absent(),
  }) : title = Value(title),
       symptoms = Value(symptoms),
       procedure = Value(procedure),
       section = Value(section);
  static Insertable<ManualFt> custom({
    Expression<String>? title,
    Expression<String>? symptoms,
    Expression<String>? procedure,
    Expression<String>? section,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (title != null) 'title': title,
      if (symptoms != null) 'symptoms': symptoms,
      if (procedure != null) 'procedure': procedure,
      if (section != null) 'section': section,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ManualFtsCompanion copyWith({
    Value<String>? title,
    Value<String>? symptoms,
    Value<String>? procedure,
    Value<String>? section,
    Value<int>? rowid,
  }) {
    return ManualFtsCompanion(
      title: title ?? this.title,
      symptoms: symptoms ?? this.symptoms,
      procedure: procedure ?? this.procedure,
      section: section ?? this.section,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (symptoms.present) {
      map['symptoms'] = Variable<String>(symptoms.value);
    }
    if (procedure.present) {
      map['procedure'] = Variable<String>(procedure.value);
    }
    if (section.present) {
      map['section'] = Variable<String>(section.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ManualFtsCompanion(')
          ..write('title: $title, ')
          ..write('symptoms: $symptoms, ')
          ..write('procedure: $procedure, ')
          ..write('section: $section, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

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
  late final $ManualEntriesTable manualEntries = $ManualEntriesTable(this);
  late final ManualFts manualFts = ManualFts(this);
  late final Trigger manualEntriesAfterInsert = Trigger(
    'CREATE TRIGGER manual_entries_after_insert AFTER INSERT ON manual_entries BEGIN INSERT INTO manual_fts ("rowid", title, symptoms, procedure, section) VALUES (new."rowid", new.title, new.symptoms, new.procedure, new.section);END',
    'manual_entries_after_insert',
  );
  late final Trigger manualEntriesAfterDelete = Trigger(
    'CREATE TRIGGER manual_entries_after_delete AFTER DELETE ON manual_entries BEGIN INSERT INTO manual_fts (manual_fts, "rowid", title, symptoms, procedure, section) VALUES (\'delete\', old."rowid", old.title, old.symptoms, old.procedure, old.section);END',
    'manual_entries_after_delete',
  );
  late final Trigger manualEntriesAfterUpdate = Trigger(
    'CREATE TRIGGER manual_entries_after_update AFTER UPDATE ON manual_entries BEGIN INSERT INTO manual_fts (manual_fts, "rowid", title, symptoms, procedure, section) VALUES (\'delete\', old."rowid", old.title, old.symptoms, old.procedure, old.section);INSERT INTO manual_fts ("rowid", title, symptoms, procedure, section) VALUES (new."rowid", new.title, new.symptoms, new.procedure, new.section);END',
    'manual_entries_after_update',
  );
  late final Index idxManualEntriesCode = Index(
    'idx_manual_entries_code',
    'CREATE INDEX idx_manual_entries_code ON manual_entries (code)',
  );
  late final $TechniciansTable technicians = $TechniciansTable(this);
  late final $InventoryPartsTable inventoryParts = $InventoryPartsTable(this);
  late final $WorkOrdersTable workOrders = $WorkOrdersTable(this);
  Selectable<ManualEntryRow> searchManualEntriesRanked(
    String match,
    int limit,
  ) {
    return customSelect(
      'SELECT manual_entries.* FROM manual_fts INNER JOIN manual_entries ON manual_entries."rowid" = manual_fts."rowid" WHERE manual_fts MATCH ?1 ORDER BY bm25(manual_fts, 8.0, 4.0, 1.0, 1.0) ASC, manual_entries.id ASC LIMIT ?2',
      variables: [Variable<String>(match), Variable<int>(limit)],
      readsFrom: {manualFts, manualEntries},
    ).asyncMap(manualEntries.mapFromRow);
  }

  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    manualEntries,
    manualFts,
    manualEntriesAfterInsert,
    manualEntriesAfterDelete,
    manualEntriesAfterUpdate,
    idxManualEntriesCode,
    technicians,
    inventoryParts,
    workOrders,
  ];
  @override
  StreamQueryUpdateRules get streamUpdateRules => const StreamQueryUpdateRules([
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'manual_entries',
        limitUpdateKind: UpdateKind.insert,
      ),
      result: [TableUpdate('manual_fts', kind: UpdateKind.insert)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'manual_entries',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('manual_fts', kind: UpdateKind.insert)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'manual_entries',
        limitUpdateKind: UpdateKind.update,
      ),
      result: [TableUpdate('manual_fts', kind: UpdateKind.insert)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'technicians',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('work_orders', kind: UpdateKind.delete)],
    ),
  ]);
}

typedef $$ManualEntriesTableCreateCompanionBuilder =
    ManualEntriesCompanion Function({
      required String id,
      required String section,
      required String code,
      required String title,
      required String symptoms,
      required String procedure,
      Value<String> requiredTools,
      Value<String> requiredParts,
      Value<int> rowid,
    });
typedef $$ManualEntriesTableUpdateCompanionBuilder =
    ManualEntriesCompanion Function({
      Value<String> id,
      Value<String> section,
      Value<String> code,
      Value<String> title,
      Value<String> symptoms,
      Value<String> procedure,
      Value<String> requiredTools,
      Value<String> requiredParts,
      Value<int> rowid,
    });

class $$ManualEntriesTableFilterComposer
    extends Composer<_$DatabaseService, $ManualEntriesTable> {
  $$ManualEntriesTableFilterComposer({
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

  ColumnFilters<String> get section => $composableBuilder(
    column: $table.section,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get code => $composableBuilder(
    column: $table.code,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get symptoms => $composableBuilder(
    column: $table.symptoms,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get procedure => $composableBuilder(
    column: $table.procedure,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get requiredTools => $composableBuilder(
    column: $table.requiredTools,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get requiredParts => $composableBuilder(
    column: $table.requiredParts,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ManualEntriesTableOrderingComposer
    extends Composer<_$DatabaseService, $ManualEntriesTable> {
  $$ManualEntriesTableOrderingComposer({
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

  ColumnOrderings<String> get section => $composableBuilder(
    column: $table.section,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get code => $composableBuilder(
    column: $table.code,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get symptoms => $composableBuilder(
    column: $table.symptoms,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get procedure => $composableBuilder(
    column: $table.procedure,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get requiredTools => $composableBuilder(
    column: $table.requiredTools,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get requiredParts => $composableBuilder(
    column: $table.requiredParts,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ManualEntriesTableAnnotationComposer
    extends Composer<_$DatabaseService, $ManualEntriesTable> {
  $$ManualEntriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get section =>
      $composableBuilder(column: $table.section, builder: (column) => column);

  GeneratedColumn<String> get code =>
      $composableBuilder(column: $table.code, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get symptoms =>
      $composableBuilder(column: $table.symptoms, builder: (column) => column);

  GeneratedColumn<String> get procedure =>
      $composableBuilder(column: $table.procedure, builder: (column) => column);

  GeneratedColumn<String> get requiredTools => $composableBuilder(
    column: $table.requiredTools,
    builder: (column) => column,
  );

  GeneratedColumn<String> get requiredParts => $composableBuilder(
    column: $table.requiredParts,
    builder: (column) => column,
  );
}

class $$ManualEntriesTableTableManager
    extends
        RootTableManager<
          _$DatabaseService,
          $ManualEntriesTable,
          ManualEntryRow,
          $$ManualEntriesTableFilterComposer,
          $$ManualEntriesTableOrderingComposer,
          $$ManualEntriesTableAnnotationComposer,
          $$ManualEntriesTableCreateCompanionBuilder,
          $$ManualEntriesTableUpdateCompanionBuilder,
          (
            ManualEntryRow,
            BaseReferences<
              _$DatabaseService,
              $ManualEntriesTable,
              ManualEntryRow
            >,
          ),
          ManualEntryRow,
          PrefetchHooks Function()
        > {
  $$ManualEntriesTableTableManager(
    _$DatabaseService db,
    $ManualEntriesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ManualEntriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ManualEntriesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ManualEntriesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> section = const Value.absent(),
                Value<String> code = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String> symptoms = const Value.absent(),
                Value<String> procedure = const Value.absent(),
                Value<String> requiredTools = const Value.absent(),
                Value<String> requiredParts = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ManualEntriesCompanion(
                id: id,
                section: section,
                code: code,
                title: title,
                symptoms: symptoms,
                procedure: procedure,
                requiredTools: requiredTools,
                requiredParts: requiredParts,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String section,
                required String code,
                required String title,
                required String symptoms,
                required String procedure,
                Value<String> requiredTools = const Value.absent(),
                Value<String> requiredParts = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ManualEntriesCompanion.insert(
                id: id,
                section: section,
                code: code,
                title: title,
                symptoms: symptoms,
                procedure: procedure,
                requiredTools: requiredTools,
                requiredParts: requiredParts,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ManualEntriesTableProcessedTableManager =
    ProcessedTableManager<
      _$DatabaseService,
      $ManualEntriesTable,
      ManualEntryRow,
      $$ManualEntriesTableFilterComposer,
      $$ManualEntriesTableOrderingComposer,
      $$ManualEntriesTableAnnotationComposer,
      $$ManualEntriesTableCreateCompanionBuilder,
      $$ManualEntriesTableUpdateCompanionBuilder,
      (
        ManualEntryRow,
        BaseReferences<_$DatabaseService, $ManualEntriesTable, ManualEntryRow>,
      ),
      ManualEntryRow,
      PrefetchHooks Function()
    >;
typedef $ManualFtsCreateCompanionBuilder =
    ManualFtsCompanion Function({
      required String title,
      required String symptoms,
      required String procedure,
      required String section,
      Value<int> rowid,
    });
typedef $ManualFtsUpdateCompanionBuilder =
    ManualFtsCompanion Function({
      Value<String> title,
      Value<String> symptoms,
      Value<String> procedure,
      Value<String> section,
      Value<int> rowid,
    });

class $ManualFtsFilterComposer extends Composer<_$DatabaseService, ManualFts> {
  $ManualFtsFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get symptoms => $composableBuilder(
    column: $table.symptoms,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get procedure => $composableBuilder(
    column: $table.procedure,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get section => $composableBuilder(
    column: $table.section,
    builder: (column) => ColumnFilters(column),
  );
}

class $ManualFtsOrderingComposer
    extends Composer<_$DatabaseService, ManualFts> {
  $ManualFtsOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get symptoms => $composableBuilder(
    column: $table.symptoms,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get procedure => $composableBuilder(
    column: $table.procedure,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get section => $composableBuilder(
    column: $table.section,
    builder: (column) => ColumnOrderings(column),
  );
}

class $ManualFtsAnnotationComposer
    extends Composer<_$DatabaseService, ManualFts> {
  $ManualFtsAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get symptoms =>
      $composableBuilder(column: $table.symptoms, builder: (column) => column);

  GeneratedColumn<String> get procedure =>
      $composableBuilder(column: $table.procedure, builder: (column) => column);

  GeneratedColumn<String> get section =>
      $composableBuilder(column: $table.section, builder: (column) => column);
}

class $ManualFtsTableManager
    extends
        RootTableManager<
          _$DatabaseService,
          ManualFts,
          ManualFt,
          $ManualFtsFilterComposer,
          $ManualFtsOrderingComposer,
          $ManualFtsAnnotationComposer,
          $ManualFtsCreateCompanionBuilder,
          $ManualFtsUpdateCompanionBuilder,
          (ManualFt, BaseReferences<_$DatabaseService, ManualFts, ManualFt>),
          ManualFt,
          PrefetchHooks Function()
        > {
  $ManualFtsTableManager(_$DatabaseService db, ManualFts table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $ManualFtsFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $ManualFtsOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $ManualFtsAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> title = const Value.absent(),
                Value<String> symptoms = const Value.absent(),
                Value<String> procedure = const Value.absent(),
                Value<String> section = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ManualFtsCompanion(
                title: title,
                symptoms: symptoms,
                procedure: procedure,
                section: section,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String title,
                required String symptoms,
                required String procedure,
                required String section,
                Value<int> rowid = const Value.absent(),
              }) => ManualFtsCompanion.insert(
                title: title,
                symptoms: symptoms,
                procedure: procedure,
                section: section,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $ManualFtsProcessedTableManager =
    ProcessedTableManager<
      _$DatabaseService,
      ManualFts,
      ManualFt,
      $ManualFtsFilterComposer,
      $ManualFtsOrderingComposer,
      $ManualFtsAnnotationComposer,
      $ManualFtsCreateCompanionBuilder,
      $ManualFtsUpdateCompanionBuilder,
      (ManualFt, BaseReferences<_$DatabaseService, ManualFts, ManualFt>),
      ManualFt,
      PrefetchHooks Function()
    >;
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
  $$ManualEntriesTableTableManager get manualEntries =>
      $$ManualEntriesTableTableManager(_db, _db.manualEntries);
  $ManualFtsTableManager get manualFts =>
      $ManualFtsTableManager(_db, _db.manualFts);
  $$TechniciansTableTableManager get technicians =>
      $$TechniciansTableTableManager(_db, _db.technicians);
  $$InventoryPartsTableTableManager get inventoryParts =>
      $$InventoryPartsTableTableManager(_db, _db.inventoryParts);
  $$WorkOrdersTableTableManager get workOrders =>
      $$WorkOrdersTableTableManager(_db, _db.workOrders);
}
