// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'client_database.dart';

// ignore_for_file: type=lint
class $EncryptedRecordsTable extends EncryptedRecords
    with TableInfo<$EncryptedRecordsTable, EncryptedRecord> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $EncryptedRecordsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _vaultIdMeta = const VerificationMeta(
    'vaultId',
  );
  @override
  late final GeneratedColumn<String> vaultId = GeneratedColumn<String>(
    'vault_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _recordIdMeta = const VerificationMeta(
    'recordId',
  );
  @override
  late final GeneratedColumn<String> recordId = GeneratedColumn<String>(
    'record_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _instanceIdMeta = const VerificationMeta(
    'instanceId',
  );
  @override
  late final GeneratedColumn<String> instanceId = GeneratedColumn<String>(
    'instance_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _serverSpaceIdMeta = const VerificationMeta(
    'serverSpaceId',
  );
  @override
  late final GeneratedColumn<String> serverSpaceId = GeneratedColumn<String>(
    'server_space_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _revisionIdMeta = const VerificationMeta(
    'revisionId',
  );
  @override
  late final GeneratedColumn<String> revisionId = GeneratedColumn<String>(
    'revision_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _envelopeJsonMeta = const VerificationMeta(
    'envelopeJson',
  );
  @override
  late final GeneratedColumn<String> envelopeJson = GeneratedColumn<String>(
    'envelope_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _isDeletedMeta = const VerificationMeta(
    'isDeleted',
  );
  @override
  late final GeneratedColumn<bool> isDeleted = GeneratedColumn<bool>(
    'is_deleted',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_deleted" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _commitSeqMeta = const VerificationMeta(
    'commitSeq',
  );
  @override
  late final GeneratedColumn<String> commitSeq = GeneratedColumn<String>(
    'commit_seq',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    vaultId,
    recordId,
    instanceId,
    serverSpaceId,
    revisionId,
    envelopeJson,
    isDeleted,
    commitSeq,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'encrypted_records';
  @override
  VerificationContext validateIntegrity(
    Insertable<EncryptedRecord> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('vault_id')) {
      context.handle(
        _vaultIdMeta,
        vaultId.isAcceptableOrUnknown(data['vault_id']!, _vaultIdMeta),
      );
    } else if (isInserting) {
      context.missing(_vaultIdMeta);
    }
    if (data.containsKey('record_id')) {
      context.handle(
        _recordIdMeta,
        recordId.isAcceptableOrUnknown(data['record_id']!, _recordIdMeta),
      );
    } else if (isInserting) {
      context.missing(_recordIdMeta);
    }
    if (data.containsKey('instance_id')) {
      context.handle(
        _instanceIdMeta,
        instanceId.isAcceptableOrUnknown(data['instance_id']!, _instanceIdMeta),
      );
    }
    if (data.containsKey('server_space_id')) {
      context.handle(
        _serverSpaceIdMeta,
        serverSpaceId.isAcceptableOrUnknown(
          data['server_space_id']!,
          _serverSpaceIdMeta,
        ),
      );
    }
    if (data.containsKey('revision_id')) {
      context.handle(
        _revisionIdMeta,
        revisionId.isAcceptableOrUnknown(data['revision_id']!, _revisionIdMeta),
      );
    } else if (isInserting) {
      context.missing(_revisionIdMeta);
    }
    if (data.containsKey('envelope_json')) {
      context.handle(
        _envelopeJsonMeta,
        envelopeJson.isAcceptableOrUnknown(
          data['envelope_json']!,
          _envelopeJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_envelopeJsonMeta);
    }
    if (data.containsKey('is_deleted')) {
      context.handle(
        _isDeletedMeta,
        isDeleted.isAcceptableOrUnknown(data['is_deleted']!, _isDeletedMeta),
      );
    }
    if (data.containsKey('commit_seq')) {
      context.handle(
        _commitSeqMeta,
        commitSeq.isAcceptableOrUnknown(data['commit_seq']!, _commitSeqMeta),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {
    vaultId,
    recordId,
    instanceId,
    serverSpaceId,
  };
  @override
  EncryptedRecord map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return EncryptedRecord(
      vaultId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}vault_id'],
      )!,
      recordId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}record_id'],
      )!,
      instanceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}instance_id'],
      ),
      serverSpaceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_space_id'],
      ),
      revisionId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}revision_id'],
      )!,
      envelopeJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}envelope_json'],
      )!,
      isDeleted: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_deleted'],
      )!,
      commitSeq: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}commit_seq'],
      ),
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $EncryptedRecordsTable createAlias(String alias) {
    return $EncryptedRecordsTable(attachedDatabase, alias);
  }
}

class EncryptedRecord extends DataClass implements Insertable<EncryptedRecord> {
  final String vaultId;
  final String recordId;
  final String? instanceId;
  final String? serverSpaceId;
  final String revisionId;
  final String envelopeJson;
  final bool isDeleted;
  final String? commitSeq;
  final int updatedAt;
  const EncryptedRecord({
    required this.vaultId,
    required this.recordId,
    this.instanceId,
    this.serverSpaceId,
    required this.revisionId,
    required this.envelopeJson,
    required this.isDeleted,
    this.commitSeq,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['vault_id'] = Variable<String>(vaultId);
    map['record_id'] = Variable<String>(recordId);
    if (!nullToAbsent || instanceId != null) {
      map['instance_id'] = Variable<String>(instanceId);
    }
    if (!nullToAbsent || serverSpaceId != null) {
      map['server_space_id'] = Variable<String>(serverSpaceId);
    }
    map['revision_id'] = Variable<String>(revisionId);
    map['envelope_json'] = Variable<String>(envelopeJson);
    map['is_deleted'] = Variable<bool>(isDeleted);
    if (!nullToAbsent || commitSeq != null) {
      map['commit_seq'] = Variable<String>(commitSeq);
    }
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  EncryptedRecordsCompanion toCompanion(bool nullToAbsent) {
    return EncryptedRecordsCompanion(
      vaultId: Value(vaultId),
      recordId: Value(recordId),
      instanceId: instanceId == null && nullToAbsent
          ? const Value.absent()
          : Value(instanceId),
      serverSpaceId: serverSpaceId == null && nullToAbsent
          ? const Value.absent()
          : Value(serverSpaceId),
      revisionId: Value(revisionId),
      envelopeJson: Value(envelopeJson),
      isDeleted: Value(isDeleted),
      commitSeq: commitSeq == null && nullToAbsent
          ? const Value.absent()
          : Value(commitSeq),
      updatedAt: Value(updatedAt),
    );
  }

  factory EncryptedRecord.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return EncryptedRecord(
      vaultId: serializer.fromJson<String>(json['vaultId']),
      recordId: serializer.fromJson<String>(json['recordId']),
      instanceId: serializer.fromJson<String?>(json['instanceId']),
      serverSpaceId: serializer.fromJson<String?>(json['serverSpaceId']),
      revisionId: serializer.fromJson<String>(json['revisionId']),
      envelopeJson: serializer.fromJson<String>(json['envelopeJson']),
      isDeleted: serializer.fromJson<bool>(json['isDeleted']),
      commitSeq: serializer.fromJson<String?>(json['commitSeq']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'vaultId': serializer.toJson<String>(vaultId),
      'recordId': serializer.toJson<String>(recordId),
      'instanceId': serializer.toJson<String?>(instanceId),
      'serverSpaceId': serializer.toJson<String?>(serverSpaceId),
      'revisionId': serializer.toJson<String>(revisionId),
      'envelopeJson': serializer.toJson<String>(envelopeJson),
      'isDeleted': serializer.toJson<bool>(isDeleted),
      'commitSeq': serializer.toJson<String?>(commitSeq),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  EncryptedRecord copyWith({
    String? vaultId,
    String? recordId,
    Value<String?> instanceId = const Value.absent(),
    Value<String?> serverSpaceId = const Value.absent(),
    String? revisionId,
    String? envelopeJson,
    bool? isDeleted,
    Value<String?> commitSeq = const Value.absent(),
    int? updatedAt,
  }) => EncryptedRecord(
    vaultId: vaultId ?? this.vaultId,
    recordId: recordId ?? this.recordId,
    instanceId: instanceId.present ? instanceId.value : this.instanceId,
    serverSpaceId: serverSpaceId.present
        ? serverSpaceId.value
        : this.serverSpaceId,
    revisionId: revisionId ?? this.revisionId,
    envelopeJson: envelopeJson ?? this.envelopeJson,
    isDeleted: isDeleted ?? this.isDeleted,
    commitSeq: commitSeq.present ? commitSeq.value : this.commitSeq,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  EncryptedRecord copyWithCompanion(EncryptedRecordsCompanion data) {
    return EncryptedRecord(
      vaultId: data.vaultId.present ? data.vaultId.value : this.vaultId,
      recordId: data.recordId.present ? data.recordId.value : this.recordId,
      instanceId: data.instanceId.present
          ? data.instanceId.value
          : this.instanceId,
      serverSpaceId: data.serverSpaceId.present
          ? data.serverSpaceId.value
          : this.serverSpaceId,
      revisionId: data.revisionId.present
          ? data.revisionId.value
          : this.revisionId,
      envelopeJson: data.envelopeJson.present
          ? data.envelopeJson.value
          : this.envelopeJson,
      isDeleted: data.isDeleted.present ? data.isDeleted.value : this.isDeleted,
      commitSeq: data.commitSeq.present ? data.commitSeq.value : this.commitSeq,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('EncryptedRecord(')
          ..write('vaultId: $vaultId, ')
          ..write('recordId: $recordId, ')
          ..write('instanceId: $instanceId, ')
          ..write('serverSpaceId: $serverSpaceId, ')
          ..write('revisionId: $revisionId, ')
          ..write('envelopeJson: $envelopeJson, ')
          ..write('isDeleted: $isDeleted, ')
          ..write('commitSeq: $commitSeq, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    vaultId,
    recordId,
    instanceId,
    serverSpaceId,
    revisionId,
    envelopeJson,
    isDeleted,
    commitSeq,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is EncryptedRecord &&
          other.vaultId == this.vaultId &&
          other.recordId == this.recordId &&
          other.instanceId == this.instanceId &&
          other.serverSpaceId == this.serverSpaceId &&
          other.revisionId == this.revisionId &&
          other.envelopeJson == this.envelopeJson &&
          other.isDeleted == this.isDeleted &&
          other.commitSeq == this.commitSeq &&
          other.updatedAt == this.updatedAt);
}

class EncryptedRecordsCompanion extends UpdateCompanion<EncryptedRecord> {
  final Value<String> vaultId;
  final Value<String> recordId;
  final Value<String?> instanceId;
  final Value<String?> serverSpaceId;
  final Value<String> revisionId;
  final Value<String> envelopeJson;
  final Value<bool> isDeleted;
  final Value<String?> commitSeq;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const EncryptedRecordsCompanion({
    this.vaultId = const Value.absent(),
    this.recordId = const Value.absent(),
    this.instanceId = const Value.absent(),
    this.serverSpaceId = const Value.absent(),
    this.revisionId = const Value.absent(),
    this.envelopeJson = const Value.absent(),
    this.isDeleted = const Value.absent(),
    this.commitSeq = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  EncryptedRecordsCompanion.insert({
    required String vaultId,
    required String recordId,
    this.instanceId = const Value.absent(),
    this.serverSpaceId = const Value.absent(),
    required String revisionId,
    required String envelopeJson,
    this.isDeleted = const Value.absent(),
    this.commitSeq = const Value.absent(),
    required int updatedAt,
    this.rowid = const Value.absent(),
  }) : vaultId = Value(vaultId),
       recordId = Value(recordId),
       revisionId = Value(revisionId),
       envelopeJson = Value(envelopeJson),
       updatedAt = Value(updatedAt);
  static Insertable<EncryptedRecord> custom({
    Expression<String>? vaultId,
    Expression<String>? recordId,
    Expression<String>? instanceId,
    Expression<String>? serverSpaceId,
    Expression<String>? revisionId,
    Expression<String>? envelopeJson,
    Expression<bool>? isDeleted,
    Expression<String>? commitSeq,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (vaultId != null) 'vault_id': vaultId,
      if (recordId != null) 'record_id': recordId,
      if (instanceId != null) 'instance_id': instanceId,
      if (serverSpaceId != null) 'server_space_id': serverSpaceId,
      if (revisionId != null) 'revision_id': revisionId,
      if (envelopeJson != null) 'envelope_json': envelopeJson,
      if (isDeleted != null) 'is_deleted': isDeleted,
      if (commitSeq != null) 'commit_seq': commitSeq,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  EncryptedRecordsCompanion copyWith({
    Value<String>? vaultId,
    Value<String>? recordId,
    Value<String?>? instanceId,
    Value<String?>? serverSpaceId,
    Value<String>? revisionId,
    Value<String>? envelopeJson,
    Value<bool>? isDeleted,
    Value<String?>? commitSeq,
    Value<int>? updatedAt,
    Value<int>? rowid,
  }) {
    return EncryptedRecordsCompanion(
      vaultId: vaultId ?? this.vaultId,
      recordId: recordId ?? this.recordId,
      instanceId: instanceId ?? this.instanceId,
      serverSpaceId: serverSpaceId ?? this.serverSpaceId,
      revisionId: revisionId ?? this.revisionId,
      envelopeJson: envelopeJson ?? this.envelopeJson,
      isDeleted: isDeleted ?? this.isDeleted,
      commitSeq: commitSeq ?? this.commitSeq,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (vaultId.present) {
      map['vault_id'] = Variable<String>(vaultId.value);
    }
    if (recordId.present) {
      map['record_id'] = Variable<String>(recordId.value);
    }
    if (instanceId.present) {
      map['instance_id'] = Variable<String>(instanceId.value);
    }
    if (serverSpaceId.present) {
      map['server_space_id'] = Variable<String>(serverSpaceId.value);
    }
    if (revisionId.present) {
      map['revision_id'] = Variable<String>(revisionId.value);
    }
    if (envelopeJson.present) {
      map['envelope_json'] = Variable<String>(envelopeJson.value);
    }
    if (isDeleted.present) {
      map['is_deleted'] = Variable<bool>(isDeleted.value);
    }
    if (commitSeq.present) {
      map['commit_seq'] = Variable<String>(commitSeq.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('EncryptedRecordsCompanion(')
          ..write('vaultId: $vaultId, ')
          ..write('recordId: $recordId, ')
          ..write('instanceId: $instanceId, ')
          ..write('serverSpaceId: $serverSpaceId, ')
          ..write('revisionId: $revisionId, ')
          ..write('envelopeJson: $envelopeJson, ')
          ..write('isDeleted: $isDeleted, ')
          ..write('commitSeq: $commitSeq, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $PendingOperationsTable extends PendingOperations
    with TableInfo<$PendingOperationsTable, PendingOperation> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PendingOperationsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _opIdMeta = const VerificationMeta('opId');
  @override
  late final GeneratedColumn<String> opId = GeneratedColumn<String>(
    'op_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _vaultIdMeta = const VerificationMeta(
    'vaultId',
  );
  @override
  late final GeneratedColumn<String> vaultId = GeneratedColumn<String>(
    'vault_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _recordIdMeta = const VerificationMeta(
    'recordId',
  );
  @override
  late final GeneratedColumn<String> recordId = GeneratedColumn<String>(
    'record_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _instanceIdMeta = const VerificationMeta(
    'instanceId',
  );
  @override
  late final GeneratedColumn<String> instanceId = GeneratedColumn<String>(
    'instance_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _serverSpaceIdMeta = const VerificationMeta(
    'serverSpaceId',
  );
  @override
  late final GeneratedColumn<String> serverSpaceId = GeneratedColumn<String>(
    'server_space_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _baseRevisionIdMeta = const VerificationMeta(
    'baseRevisionId',
  );
  @override
  late final GeneratedColumn<String> baseRevisionId = GeneratedColumn<String>(
    'base_revision_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _baseEnvelopeJsonMeta = const VerificationMeta(
    'baseEnvelopeJson',
  );
  @override
  late final GeneratedColumn<String> baseEnvelopeJson = GeneratedColumn<String>(
    'base_envelope_json',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _envelopeJsonMeta = const VerificationMeta(
    'envelopeJson',
  );
  @override
  late final GeneratedColumn<String> envelopeJson = GeneratedColumn<String>(
    'envelope_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('queued'),
  );
  static const VerificationMeta _attemptCountMeta = const VerificationMeta(
    'attemptCount',
  );
  @override
  late final GeneratedColumn<int> attemptCount = GeneratedColumn<int>(
    'attempt_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _lastAttemptAtMeta = const VerificationMeta(
    'lastAttemptAt',
  );
  @override
  late final GeneratedColumn<int> lastAttemptAt = GeneratedColumn<int>(
    'last_attempt_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    opId,
    vaultId,
    recordId,
    instanceId,
    serverSpaceId,
    baseRevisionId,
    baseEnvelopeJson,
    envelopeJson,
    status,
    attemptCount,
    createdAt,
    lastAttemptAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'pending_operations';
  @override
  VerificationContext validateIntegrity(
    Insertable<PendingOperation> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('op_id')) {
      context.handle(
        _opIdMeta,
        opId.isAcceptableOrUnknown(data['op_id']!, _opIdMeta),
      );
    } else if (isInserting) {
      context.missing(_opIdMeta);
    }
    if (data.containsKey('vault_id')) {
      context.handle(
        _vaultIdMeta,
        vaultId.isAcceptableOrUnknown(data['vault_id']!, _vaultIdMeta),
      );
    } else if (isInserting) {
      context.missing(_vaultIdMeta);
    }
    if (data.containsKey('record_id')) {
      context.handle(
        _recordIdMeta,
        recordId.isAcceptableOrUnknown(data['record_id']!, _recordIdMeta),
      );
    } else if (isInserting) {
      context.missing(_recordIdMeta);
    }
    if (data.containsKey('instance_id')) {
      context.handle(
        _instanceIdMeta,
        instanceId.isAcceptableOrUnknown(data['instance_id']!, _instanceIdMeta),
      );
    }
    if (data.containsKey('server_space_id')) {
      context.handle(
        _serverSpaceIdMeta,
        serverSpaceId.isAcceptableOrUnknown(
          data['server_space_id']!,
          _serverSpaceIdMeta,
        ),
      );
    }
    if (data.containsKey('base_revision_id')) {
      context.handle(
        _baseRevisionIdMeta,
        baseRevisionId.isAcceptableOrUnknown(
          data['base_revision_id']!,
          _baseRevisionIdMeta,
        ),
      );
    }
    if (data.containsKey('base_envelope_json')) {
      context.handle(
        _baseEnvelopeJsonMeta,
        baseEnvelopeJson.isAcceptableOrUnknown(
          data['base_envelope_json']!,
          _baseEnvelopeJsonMeta,
        ),
      );
    }
    if (data.containsKey('envelope_json')) {
      context.handle(
        _envelopeJsonMeta,
        envelopeJson.isAcceptableOrUnknown(
          data['envelope_json']!,
          _envelopeJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_envelopeJsonMeta);
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    }
    if (data.containsKey('attempt_count')) {
      context.handle(
        _attemptCountMeta,
        attemptCount.isAcceptableOrUnknown(
          data['attempt_count']!,
          _attemptCountMeta,
        ),
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
    if (data.containsKey('last_attempt_at')) {
      context.handle(
        _lastAttemptAtMeta,
        lastAttemptAt.isAcceptableOrUnknown(
          data['last_attempt_at']!,
          _lastAttemptAtMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {opId};
  @override
  PendingOperation map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PendingOperation(
      opId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}op_id'],
      )!,
      vaultId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}vault_id'],
      )!,
      recordId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}record_id'],
      )!,
      instanceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}instance_id'],
      ),
      serverSpaceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_space_id'],
      ),
      baseRevisionId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}base_revision_id'],
      ),
      baseEnvelopeJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}base_envelope_json'],
      ),
      envelopeJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}envelope_json'],
      )!,
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      attemptCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}attempt_count'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      lastAttemptAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_attempt_at'],
      ),
    );
  }

  @override
  $PendingOperationsTable createAlias(String alias) {
    return $PendingOperationsTable(attachedDatabase, alias);
  }
}

class PendingOperation extends DataClass
    implements Insertable<PendingOperation> {
  final String opId;
  final String vaultId;
  final String recordId;
  final String? instanceId;
  final String? serverSpaceId;
  final String? baseRevisionId;
  final String? baseEnvelopeJson;
  final String envelopeJson;
  final String status;
  final int attemptCount;
  final int createdAt;
  final int? lastAttemptAt;
  const PendingOperation({
    required this.opId,
    required this.vaultId,
    required this.recordId,
    this.instanceId,
    this.serverSpaceId,
    this.baseRevisionId,
    this.baseEnvelopeJson,
    required this.envelopeJson,
    required this.status,
    required this.attemptCount,
    required this.createdAt,
    this.lastAttemptAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['op_id'] = Variable<String>(opId);
    map['vault_id'] = Variable<String>(vaultId);
    map['record_id'] = Variable<String>(recordId);
    if (!nullToAbsent || instanceId != null) {
      map['instance_id'] = Variable<String>(instanceId);
    }
    if (!nullToAbsent || serverSpaceId != null) {
      map['server_space_id'] = Variable<String>(serverSpaceId);
    }
    if (!nullToAbsent || baseRevisionId != null) {
      map['base_revision_id'] = Variable<String>(baseRevisionId);
    }
    if (!nullToAbsent || baseEnvelopeJson != null) {
      map['base_envelope_json'] = Variable<String>(baseEnvelopeJson);
    }
    map['envelope_json'] = Variable<String>(envelopeJson);
    map['status'] = Variable<String>(status);
    map['attempt_count'] = Variable<int>(attemptCount);
    map['created_at'] = Variable<int>(createdAt);
    if (!nullToAbsent || lastAttemptAt != null) {
      map['last_attempt_at'] = Variable<int>(lastAttemptAt);
    }
    return map;
  }

  PendingOperationsCompanion toCompanion(bool nullToAbsent) {
    return PendingOperationsCompanion(
      opId: Value(opId),
      vaultId: Value(vaultId),
      recordId: Value(recordId),
      instanceId: instanceId == null && nullToAbsent
          ? const Value.absent()
          : Value(instanceId),
      serverSpaceId: serverSpaceId == null && nullToAbsent
          ? const Value.absent()
          : Value(serverSpaceId),
      baseRevisionId: baseRevisionId == null && nullToAbsent
          ? const Value.absent()
          : Value(baseRevisionId),
      baseEnvelopeJson: baseEnvelopeJson == null && nullToAbsent
          ? const Value.absent()
          : Value(baseEnvelopeJson),
      envelopeJson: Value(envelopeJson),
      status: Value(status),
      attemptCount: Value(attemptCount),
      createdAt: Value(createdAt),
      lastAttemptAt: lastAttemptAt == null && nullToAbsent
          ? const Value.absent()
          : Value(lastAttemptAt),
    );
  }

  factory PendingOperation.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PendingOperation(
      opId: serializer.fromJson<String>(json['opId']),
      vaultId: serializer.fromJson<String>(json['vaultId']),
      recordId: serializer.fromJson<String>(json['recordId']),
      instanceId: serializer.fromJson<String?>(json['instanceId']),
      serverSpaceId: serializer.fromJson<String?>(json['serverSpaceId']),
      baseRevisionId: serializer.fromJson<String?>(json['baseRevisionId']),
      baseEnvelopeJson: serializer.fromJson<String?>(json['baseEnvelopeJson']),
      envelopeJson: serializer.fromJson<String>(json['envelopeJson']),
      status: serializer.fromJson<String>(json['status']),
      attemptCount: serializer.fromJson<int>(json['attemptCount']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      lastAttemptAt: serializer.fromJson<int?>(json['lastAttemptAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'opId': serializer.toJson<String>(opId),
      'vaultId': serializer.toJson<String>(vaultId),
      'recordId': serializer.toJson<String>(recordId),
      'instanceId': serializer.toJson<String?>(instanceId),
      'serverSpaceId': serializer.toJson<String?>(serverSpaceId),
      'baseRevisionId': serializer.toJson<String?>(baseRevisionId),
      'baseEnvelopeJson': serializer.toJson<String?>(baseEnvelopeJson),
      'envelopeJson': serializer.toJson<String>(envelopeJson),
      'status': serializer.toJson<String>(status),
      'attemptCount': serializer.toJson<int>(attemptCount),
      'createdAt': serializer.toJson<int>(createdAt),
      'lastAttemptAt': serializer.toJson<int?>(lastAttemptAt),
    };
  }

  PendingOperation copyWith({
    String? opId,
    String? vaultId,
    String? recordId,
    Value<String?> instanceId = const Value.absent(),
    Value<String?> serverSpaceId = const Value.absent(),
    Value<String?> baseRevisionId = const Value.absent(),
    Value<String?> baseEnvelopeJson = const Value.absent(),
    String? envelopeJson,
    String? status,
    int? attemptCount,
    int? createdAt,
    Value<int?> lastAttemptAt = const Value.absent(),
  }) => PendingOperation(
    opId: opId ?? this.opId,
    vaultId: vaultId ?? this.vaultId,
    recordId: recordId ?? this.recordId,
    instanceId: instanceId.present ? instanceId.value : this.instanceId,
    serverSpaceId: serverSpaceId.present
        ? serverSpaceId.value
        : this.serverSpaceId,
    baseRevisionId: baseRevisionId.present
        ? baseRevisionId.value
        : this.baseRevisionId,
    baseEnvelopeJson: baseEnvelopeJson.present
        ? baseEnvelopeJson.value
        : this.baseEnvelopeJson,
    envelopeJson: envelopeJson ?? this.envelopeJson,
    status: status ?? this.status,
    attemptCount: attemptCount ?? this.attemptCount,
    createdAt: createdAt ?? this.createdAt,
    lastAttemptAt: lastAttemptAt.present
        ? lastAttemptAt.value
        : this.lastAttemptAt,
  );
  PendingOperation copyWithCompanion(PendingOperationsCompanion data) {
    return PendingOperation(
      opId: data.opId.present ? data.opId.value : this.opId,
      vaultId: data.vaultId.present ? data.vaultId.value : this.vaultId,
      recordId: data.recordId.present ? data.recordId.value : this.recordId,
      instanceId: data.instanceId.present
          ? data.instanceId.value
          : this.instanceId,
      serverSpaceId: data.serverSpaceId.present
          ? data.serverSpaceId.value
          : this.serverSpaceId,
      baseRevisionId: data.baseRevisionId.present
          ? data.baseRevisionId.value
          : this.baseRevisionId,
      baseEnvelopeJson: data.baseEnvelopeJson.present
          ? data.baseEnvelopeJson.value
          : this.baseEnvelopeJson,
      envelopeJson: data.envelopeJson.present
          ? data.envelopeJson.value
          : this.envelopeJson,
      status: data.status.present ? data.status.value : this.status,
      attemptCount: data.attemptCount.present
          ? data.attemptCount.value
          : this.attemptCount,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      lastAttemptAt: data.lastAttemptAt.present
          ? data.lastAttemptAt.value
          : this.lastAttemptAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PendingOperation(')
          ..write('opId: $opId, ')
          ..write('vaultId: $vaultId, ')
          ..write('recordId: $recordId, ')
          ..write('instanceId: $instanceId, ')
          ..write('serverSpaceId: $serverSpaceId, ')
          ..write('baseRevisionId: $baseRevisionId, ')
          ..write('baseEnvelopeJson: $baseEnvelopeJson, ')
          ..write('envelopeJson: $envelopeJson, ')
          ..write('status: $status, ')
          ..write('attemptCount: $attemptCount, ')
          ..write('createdAt: $createdAt, ')
          ..write('lastAttemptAt: $lastAttemptAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    opId,
    vaultId,
    recordId,
    instanceId,
    serverSpaceId,
    baseRevisionId,
    baseEnvelopeJson,
    envelopeJson,
    status,
    attemptCount,
    createdAt,
    lastAttemptAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PendingOperation &&
          other.opId == this.opId &&
          other.vaultId == this.vaultId &&
          other.recordId == this.recordId &&
          other.instanceId == this.instanceId &&
          other.serverSpaceId == this.serverSpaceId &&
          other.baseRevisionId == this.baseRevisionId &&
          other.baseEnvelopeJson == this.baseEnvelopeJson &&
          other.envelopeJson == this.envelopeJson &&
          other.status == this.status &&
          other.attemptCount == this.attemptCount &&
          other.createdAt == this.createdAt &&
          other.lastAttemptAt == this.lastAttemptAt);
}

class PendingOperationsCompanion extends UpdateCompanion<PendingOperation> {
  final Value<String> opId;
  final Value<String> vaultId;
  final Value<String> recordId;
  final Value<String?> instanceId;
  final Value<String?> serverSpaceId;
  final Value<String?> baseRevisionId;
  final Value<String?> baseEnvelopeJson;
  final Value<String> envelopeJson;
  final Value<String> status;
  final Value<int> attemptCount;
  final Value<int> createdAt;
  final Value<int?> lastAttemptAt;
  final Value<int> rowid;
  const PendingOperationsCompanion({
    this.opId = const Value.absent(),
    this.vaultId = const Value.absent(),
    this.recordId = const Value.absent(),
    this.instanceId = const Value.absent(),
    this.serverSpaceId = const Value.absent(),
    this.baseRevisionId = const Value.absent(),
    this.baseEnvelopeJson = const Value.absent(),
    this.envelopeJson = const Value.absent(),
    this.status = const Value.absent(),
    this.attemptCount = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.lastAttemptAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  PendingOperationsCompanion.insert({
    required String opId,
    required String vaultId,
    required String recordId,
    this.instanceId = const Value.absent(),
    this.serverSpaceId = const Value.absent(),
    this.baseRevisionId = const Value.absent(),
    this.baseEnvelopeJson = const Value.absent(),
    required String envelopeJson,
    this.status = const Value.absent(),
    this.attemptCount = const Value.absent(),
    required int createdAt,
    this.lastAttemptAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : opId = Value(opId),
       vaultId = Value(vaultId),
       recordId = Value(recordId),
       envelopeJson = Value(envelopeJson),
       createdAt = Value(createdAt);
  static Insertable<PendingOperation> custom({
    Expression<String>? opId,
    Expression<String>? vaultId,
    Expression<String>? recordId,
    Expression<String>? instanceId,
    Expression<String>? serverSpaceId,
    Expression<String>? baseRevisionId,
    Expression<String>? baseEnvelopeJson,
    Expression<String>? envelopeJson,
    Expression<String>? status,
    Expression<int>? attemptCount,
    Expression<int>? createdAt,
    Expression<int>? lastAttemptAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (opId != null) 'op_id': opId,
      if (vaultId != null) 'vault_id': vaultId,
      if (recordId != null) 'record_id': recordId,
      if (instanceId != null) 'instance_id': instanceId,
      if (serverSpaceId != null) 'server_space_id': serverSpaceId,
      if (baseRevisionId != null) 'base_revision_id': baseRevisionId,
      if (baseEnvelopeJson != null) 'base_envelope_json': baseEnvelopeJson,
      if (envelopeJson != null) 'envelope_json': envelopeJson,
      if (status != null) 'status': status,
      if (attemptCount != null) 'attempt_count': attemptCount,
      if (createdAt != null) 'created_at': createdAt,
      if (lastAttemptAt != null) 'last_attempt_at': lastAttemptAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  PendingOperationsCompanion copyWith({
    Value<String>? opId,
    Value<String>? vaultId,
    Value<String>? recordId,
    Value<String?>? instanceId,
    Value<String?>? serverSpaceId,
    Value<String?>? baseRevisionId,
    Value<String?>? baseEnvelopeJson,
    Value<String>? envelopeJson,
    Value<String>? status,
    Value<int>? attemptCount,
    Value<int>? createdAt,
    Value<int?>? lastAttemptAt,
    Value<int>? rowid,
  }) {
    return PendingOperationsCompanion(
      opId: opId ?? this.opId,
      vaultId: vaultId ?? this.vaultId,
      recordId: recordId ?? this.recordId,
      instanceId: instanceId ?? this.instanceId,
      serverSpaceId: serverSpaceId ?? this.serverSpaceId,
      baseRevisionId: baseRevisionId ?? this.baseRevisionId,
      baseEnvelopeJson: baseEnvelopeJson ?? this.baseEnvelopeJson,
      envelopeJson: envelopeJson ?? this.envelopeJson,
      status: status ?? this.status,
      attemptCount: attemptCount ?? this.attemptCount,
      createdAt: createdAt ?? this.createdAt,
      lastAttemptAt: lastAttemptAt ?? this.lastAttemptAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (opId.present) {
      map['op_id'] = Variable<String>(opId.value);
    }
    if (vaultId.present) {
      map['vault_id'] = Variable<String>(vaultId.value);
    }
    if (recordId.present) {
      map['record_id'] = Variable<String>(recordId.value);
    }
    if (instanceId.present) {
      map['instance_id'] = Variable<String>(instanceId.value);
    }
    if (serverSpaceId.present) {
      map['server_space_id'] = Variable<String>(serverSpaceId.value);
    }
    if (baseRevisionId.present) {
      map['base_revision_id'] = Variable<String>(baseRevisionId.value);
    }
    if (baseEnvelopeJson.present) {
      map['base_envelope_json'] = Variable<String>(baseEnvelopeJson.value);
    }
    if (envelopeJson.present) {
      map['envelope_json'] = Variable<String>(envelopeJson.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (attemptCount.present) {
      map['attempt_count'] = Variable<int>(attemptCount.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (lastAttemptAt.present) {
      map['last_attempt_at'] = Variable<int>(lastAttemptAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PendingOperationsCompanion(')
          ..write('opId: $opId, ')
          ..write('vaultId: $vaultId, ')
          ..write('recordId: $recordId, ')
          ..write('instanceId: $instanceId, ')
          ..write('serverSpaceId: $serverSpaceId, ')
          ..write('baseRevisionId: $baseRevisionId, ')
          ..write('baseEnvelopeJson: $baseEnvelopeJson, ')
          ..write('envelopeJson: $envelopeJson, ')
          ..write('status: $status, ')
          ..write('attemptCount: $attemptCount, ')
          ..write('createdAt: $createdAt, ')
          ..write('lastAttemptAt: $lastAttemptAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $AuthenticatedPushReceiptsTable extends AuthenticatedPushReceipts
    with TableInfo<$AuthenticatedPushReceiptsTable, AuthenticatedPushReceipt> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AuthenticatedPushReceiptsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _opIdMeta = const VerificationMeta('opId');
  @override
  late final GeneratedColumn<String> opId = GeneratedColumn<String>(
    'op_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _vaultIdMeta = const VerificationMeta(
    'vaultId',
  );
  @override
  late final GeneratedColumn<String> vaultId = GeneratedColumn<String>(
    'vault_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _recordIdMeta = const VerificationMeta(
    'recordId',
  );
  @override
  late final GeneratedColumn<String> recordId = GeneratedColumn<String>(
    'record_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _instanceIdMeta = const VerificationMeta(
    'instanceId',
  );
  @override
  late final GeneratedColumn<String> instanceId = GeneratedColumn<String>(
    'instance_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _serverSpaceIdMeta = const VerificationMeta(
    'serverSpaceId',
  );
  @override
  late final GeneratedColumn<String> serverSpaceId = GeneratedColumn<String>(
    'server_space_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _revisionIdMeta = const VerificationMeta(
    'revisionId',
  );
  @override
  late final GeneratedColumn<String> revisionId = GeneratedColumn<String>(
    'revision_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _envelopeJsonMeta = const VerificationMeta(
    'envelopeJson',
  );
  @override
  late final GeneratedColumn<String> envelopeJson = GeneratedColumn<String>(
    'envelope_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _commitSeqMeta = const VerificationMeta(
    'commitSeq',
  );
  @override
  late final GeneratedColumn<String> commitSeq = GeneratedColumn<String>(
    'commit_seq',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [
    opId,
    vaultId,
    recordId,
    instanceId,
    serverSpaceId,
    revisionId,
    envelopeJson,
    commitSeq,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'authenticated_push_receipts';
  @override
  VerificationContext validateIntegrity(
    Insertable<AuthenticatedPushReceipt> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('op_id')) {
      context.handle(
        _opIdMeta,
        opId.isAcceptableOrUnknown(data['op_id']!, _opIdMeta),
      );
    } else if (isInserting) {
      context.missing(_opIdMeta);
    }
    if (data.containsKey('vault_id')) {
      context.handle(
        _vaultIdMeta,
        vaultId.isAcceptableOrUnknown(data['vault_id']!, _vaultIdMeta),
      );
    } else if (isInserting) {
      context.missing(_vaultIdMeta);
    }
    if (data.containsKey('record_id')) {
      context.handle(
        _recordIdMeta,
        recordId.isAcceptableOrUnknown(data['record_id']!, _recordIdMeta),
      );
    } else if (isInserting) {
      context.missing(_recordIdMeta);
    }
    if (data.containsKey('instance_id')) {
      context.handle(
        _instanceIdMeta,
        instanceId.isAcceptableOrUnknown(data['instance_id']!, _instanceIdMeta),
      );
    }
    if (data.containsKey('server_space_id')) {
      context.handle(
        _serverSpaceIdMeta,
        serverSpaceId.isAcceptableOrUnknown(
          data['server_space_id']!,
          _serverSpaceIdMeta,
        ),
      );
    }
    if (data.containsKey('revision_id')) {
      context.handle(
        _revisionIdMeta,
        revisionId.isAcceptableOrUnknown(data['revision_id']!, _revisionIdMeta),
      );
    } else if (isInserting) {
      context.missing(_revisionIdMeta);
    }
    if (data.containsKey('envelope_json')) {
      context.handle(
        _envelopeJsonMeta,
        envelopeJson.isAcceptableOrUnknown(
          data['envelope_json']!,
          _envelopeJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_envelopeJsonMeta);
    }
    if (data.containsKey('commit_seq')) {
      context.handle(
        _commitSeqMeta,
        commitSeq.isAcceptableOrUnknown(data['commit_seq']!, _commitSeqMeta),
      );
    } else if (isInserting) {
      context.missing(_commitSeqMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {opId};
  @override
  AuthenticatedPushReceipt map(
    Map<String, dynamic> data, {
    String? tablePrefix,
  }) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AuthenticatedPushReceipt(
      opId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}op_id'],
      )!,
      vaultId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}vault_id'],
      )!,
      recordId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}record_id'],
      )!,
      instanceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}instance_id'],
      ),
      serverSpaceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_space_id'],
      ),
      revisionId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}revision_id'],
      )!,
      envelopeJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}envelope_json'],
      )!,
      commitSeq: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}commit_seq'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $AuthenticatedPushReceiptsTable createAlias(String alias) {
    return $AuthenticatedPushReceiptsTable(attachedDatabase, alias);
  }
}

class AuthenticatedPushReceipt extends DataClass
    implements Insertable<AuthenticatedPushReceipt> {
  final String opId;
  final String vaultId;
  final String recordId;
  final String? instanceId;
  final String? serverSpaceId;
  final String revisionId;
  final String envelopeJson;
  final String commitSeq;
  final int createdAt;
  const AuthenticatedPushReceipt({
    required this.opId,
    required this.vaultId,
    required this.recordId,
    this.instanceId,
    this.serverSpaceId,
    required this.revisionId,
    required this.envelopeJson,
    required this.commitSeq,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['op_id'] = Variable<String>(opId);
    map['vault_id'] = Variable<String>(vaultId);
    map['record_id'] = Variable<String>(recordId);
    if (!nullToAbsent || instanceId != null) {
      map['instance_id'] = Variable<String>(instanceId);
    }
    if (!nullToAbsent || serverSpaceId != null) {
      map['server_space_id'] = Variable<String>(serverSpaceId);
    }
    map['revision_id'] = Variable<String>(revisionId);
    map['envelope_json'] = Variable<String>(envelopeJson);
    map['commit_seq'] = Variable<String>(commitSeq);
    map['created_at'] = Variable<int>(createdAt);
    return map;
  }

  AuthenticatedPushReceiptsCompanion toCompanion(bool nullToAbsent) {
    return AuthenticatedPushReceiptsCompanion(
      opId: Value(opId),
      vaultId: Value(vaultId),
      recordId: Value(recordId),
      instanceId: instanceId == null && nullToAbsent
          ? const Value.absent()
          : Value(instanceId),
      serverSpaceId: serverSpaceId == null && nullToAbsent
          ? const Value.absent()
          : Value(serverSpaceId),
      revisionId: Value(revisionId),
      envelopeJson: Value(envelopeJson),
      commitSeq: Value(commitSeq),
      createdAt: Value(createdAt),
    );
  }

  factory AuthenticatedPushReceipt.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AuthenticatedPushReceipt(
      opId: serializer.fromJson<String>(json['opId']),
      vaultId: serializer.fromJson<String>(json['vaultId']),
      recordId: serializer.fromJson<String>(json['recordId']),
      instanceId: serializer.fromJson<String?>(json['instanceId']),
      serverSpaceId: serializer.fromJson<String?>(json['serverSpaceId']),
      revisionId: serializer.fromJson<String>(json['revisionId']),
      envelopeJson: serializer.fromJson<String>(json['envelopeJson']),
      commitSeq: serializer.fromJson<String>(json['commitSeq']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'opId': serializer.toJson<String>(opId),
      'vaultId': serializer.toJson<String>(vaultId),
      'recordId': serializer.toJson<String>(recordId),
      'instanceId': serializer.toJson<String?>(instanceId),
      'serverSpaceId': serializer.toJson<String?>(serverSpaceId),
      'revisionId': serializer.toJson<String>(revisionId),
      'envelopeJson': serializer.toJson<String>(envelopeJson),
      'commitSeq': serializer.toJson<String>(commitSeq),
      'createdAt': serializer.toJson<int>(createdAt),
    };
  }

  AuthenticatedPushReceipt copyWith({
    String? opId,
    String? vaultId,
    String? recordId,
    Value<String?> instanceId = const Value.absent(),
    Value<String?> serverSpaceId = const Value.absent(),
    String? revisionId,
    String? envelopeJson,
    String? commitSeq,
    int? createdAt,
  }) => AuthenticatedPushReceipt(
    opId: opId ?? this.opId,
    vaultId: vaultId ?? this.vaultId,
    recordId: recordId ?? this.recordId,
    instanceId: instanceId.present ? instanceId.value : this.instanceId,
    serverSpaceId: serverSpaceId.present
        ? serverSpaceId.value
        : this.serverSpaceId,
    revisionId: revisionId ?? this.revisionId,
    envelopeJson: envelopeJson ?? this.envelopeJson,
    commitSeq: commitSeq ?? this.commitSeq,
    createdAt: createdAt ?? this.createdAt,
  );
  AuthenticatedPushReceipt copyWithCompanion(
    AuthenticatedPushReceiptsCompanion data,
  ) {
    return AuthenticatedPushReceipt(
      opId: data.opId.present ? data.opId.value : this.opId,
      vaultId: data.vaultId.present ? data.vaultId.value : this.vaultId,
      recordId: data.recordId.present ? data.recordId.value : this.recordId,
      instanceId: data.instanceId.present
          ? data.instanceId.value
          : this.instanceId,
      serverSpaceId: data.serverSpaceId.present
          ? data.serverSpaceId.value
          : this.serverSpaceId,
      revisionId: data.revisionId.present
          ? data.revisionId.value
          : this.revisionId,
      envelopeJson: data.envelopeJson.present
          ? data.envelopeJson.value
          : this.envelopeJson,
      commitSeq: data.commitSeq.present ? data.commitSeq.value : this.commitSeq,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AuthenticatedPushReceipt(')
          ..write('opId: $opId, ')
          ..write('vaultId: $vaultId, ')
          ..write('recordId: $recordId, ')
          ..write('instanceId: $instanceId, ')
          ..write('serverSpaceId: $serverSpaceId, ')
          ..write('revisionId: $revisionId, ')
          ..write('envelopeJson: $envelopeJson, ')
          ..write('commitSeq: $commitSeq, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    opId,
    vaultId,
    recordId,
    instanceId,
    serverSpaceId,
    revisionId,
    envelopeJson,
    commitSeq,
    createdAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AuthenticatedPushReceipt &&
          other.opId == this.opId &&
          other.vaultId == this.vaultId &&
          other.recordId == this.recordId &&
          other.instanceId == this.instanceId &&
          other.serverSpaceId == this.serverSpaceId &&
          other.revisionId == this.revisionId &&
          other.envelopeJson == this.envelopeJson &&
          other.commitSeq == this.commitSeq &&
          other.createdAt == this.createdAt);
}

class AuthenticatedPushReceiptsCompanion
    extends UpdateCompanion<AuthenticatedPushReceipt> {
  final Value<String> opId;
  final Value<String> vaultId;
  final Value<String> recordId;
  final Value<String?> instanceId;
  final Value<String?> serverSpaceId;
  final Value<String> revisionId;
  final Value<String> envelopeJson;
  final Value<String> commitSeq;
  final Value<int> createdAt;
  final Value<int> rowid;
  const AuthenticatedPushReceiptsCompanion({
    this.opId = const Value.absent(),
    this.vaultId = const Value.absent(),
    this.recordId = const Value.absent(),
    this.instanceId = const Value.absent(),
    this.serverSpaceId = const Value.absent(),
    this.revisionId = const Value.absent(),
    this.envelopeJson = const Value.absent(),
    this.commitSeq = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AuthenticatedPushReceiptsCompanion.insert({
    required String opId,
    required String vaultId,
    required String recordId,
    this.instanceId = const Value.absent(),
    this.serverSpaceId = const Value.absent(),
    required String revisionId,
    required String envelopeJson,
    required String commitSeq,
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : opId = Value(opId),
       vaultId = Value(vaultId),
       recordId = Value(recordId),
       revisionId = Value(revisionId),
       envelopeJson = Value(envelopeJson),
       commitSeq = Value(commitSeq);
  static Insertable<AuthenticatedPushReceipt> custom({
    Expression<String>? opId,
    Expression<String>? vaultId,
    Expression<String>? recordId,
    Expression<String>? instanceId,
    Expression<String>? serverSpaceId,
    Expression<String>? revisionId,
    Expression<String>? envelopeJson,
    Expression<String>? commitSeq,
    Expression<int>? createdAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (opId != null) 'op_id': opId,
      if (vaultId != null) 'vault_id': vaultId,
      if (recordId != null) 'record_id': recordId,
      if (instanceId != null) 'instance_id': instanceId,
      if (serverSpaceId != null) 'server_space_id': serverSpaceId,
      if (revisionId != null) 'revision_id': revisionId,
      if (envelopeJson != null) 'envelope_json': envelopeJson,
      if (commitSeq != null) 'commit_seq': commitSeq,
      if (createdAt != null) 'created_at': createdAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AuthenticatedPushReceiptsCompanion copyWith({
    Value<String>? opId,
    Value<String>? vaultId,
    Value<String>? recordId,
    Value<String?>? instanceId,
    Value<String?>? serverSpaceId,
    Value<String>? revisionId,
    Value<String>? envelopeJson,
    Value<String>? commitSeq,
    Value<int>? createdAt,
    Value<int>? rowid,
  }) {
    return AuthenticatedPushReceiptsCompanion(
      opId: opId ?? this.opId,
      vaultId: vaultId ?? this.vaultId,
      recordId: recordId ?? this.recordId,
      instanceId: instanceId ?? this.instanceId,
      serverSpaceId: serverSpaceId ?? this.serverSpaceId,
      revisionId: revisionId ?? this.revisionId,
      envelopeJson: envelopeJson ?? this.envelopeJson,
      commitSeq: commitSeq ?? this.commitSeq,
      createdAt: createdAt ?? this.createdAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (opId.present) {
      map['op_id'] = Variable<String>(opId.value);
    }
    if (vaultId.present) {
      map['vault_id'] = Variable<String>(vaultId.value);
    }
    if (recordId.present) {
      map['record_id'] = Variable<String>(recordId.value);
    }
    if (instanceId.present) {
      map['instance_id'] = Variable<String>(instanceId.value);
    }
    if (serverSpaceId.present) {
      map['server_space_id'] = Variable<String>(serverSpaceId.value);
    }
    if (revisionId.present) {
      map['revision_id'] = Variable<String>(revisionId.value);
    }
    if (envelopeJson.present) {
      map['envelope_json'] = Variable<String>(envelopeJson.value);
    }
    if (commitSeq.present) {
      map['commit_seq'] = Variable<String>(commitSeq.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AuthenticatedPushReceiptsCompanion(')
          ..write('opId: $opId, ')
          ..write('vaultId: $vaultId, ')
          ..write('recordId: $recordId, ')
          ..write('instanceId: $instanceId, ')
          ..write('serverSpaceId: $serverSpaceId, ')
          ..write('revisionId: $revisionId, ')
          ..write('envelopeJson: $envelopeJson, ')
          ..write('commitSeq: $commitSeq, ')
          ..write('createdAt: $createdAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SyncCheckpointsTable extends SyncCheckpoints
    with TableInfo<$SyncCheckpointsTable, SyncCheckpoint> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncCheckpointsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _vaultIdMeta = const VerificationMeta(
    'vaultId',
  );
  @override
  late final GeneratedColumn<String> vaultId = GeneratedColumn<String>(
    'vault_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _instanceIdMeta = const VerificationMeta(
    'instanceId',
  );
  @override
  late final GeneratedColumn<String> instanceId = GeneratedColumn<String>(
    'instance_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _serverSpaceIdMeta = const VerificationMeta(
    'serverSpaceId',
  );
  @override
  late final GeneratedColumn<String> serverSpaceId = GeneratedColumn<String>(
    'server_space_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _cursorMeta = const VerificationMeta('cursor');
  @override
  late final GeneratedColumn<String> cursor = GeneratedColumn<String>(
    'cursor',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _serverGenerationMeta = const VerificationMeta(
    'serverGeneration',
  );
  @override
  late final GeneratedColumn<String> serverGeneration = GeneratedColumn<String>(
    'server_generation',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _syncStatusMeta = const VerificationMeta(
    'syncStatus',
  );
  @override
  late final GeneratedColumn<String> syncStatus = GeneratedColumn<String>(
    'sync_status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('idle'),
  );
  static const VerificationMeta _lastSuccessAtMeta = const VerificationMeta(
    'lastSuccessAt',
  );
  @override
  late final GeneratedColumn<int> lastSuccessAt = GeneratedColumn<int>(
    'last_success_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    vaultId,
    instanceId,
    serverSpaceId,
    cursor,
    serverGeneration,
    syncStatus,
    lastSuccessAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_checkpoints';
  @override
  VerificationContext validateIntegrity(
    Insertable<SyncCheckpoint> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('vault_id')) {
      context.handle(
        _vaultIdMeta,
        vaultId.isAcceptableOrUnknown(data['vault_id']!, _vaultIdMeta),
      );
    } else if (isInserting) {
      context.missing(_vaultIdMeta);
    }
    if (data.containsKey('instance_id')) {
      context.handle(
        _instanceIdMeta,
        instanceId.isAcceptableOrUnknown(data['instance_id']!, _instanceIdMeta),
      );
    }
    if (data.containsKey('server_space_id')) {
      context.handle(
        _serverSpaceIdMeta,
        serverSpaceId.isAcceptableOrUnknown(
          data['server_space_id']!,
          _serverSpaceIdMeta,
        ),
      );
    }
    if (data.containsKey('cursor')) {
      context.handle(
        _cursorMeta,
        cursor.isAcceptableOrUnknown(data['cursor']!, _cursorMeta),
      );
    }
    if (data.containsKey('server_generation')) {
      context.handle(
        _serverGenerationMeta,
        serverGeneration.isAcceptableOrUnknown(
          data['server_generation']!,
          _serverGenerationMeta,
        ),
      );
    }
    if (data.containsKey('sync_status')) {
      context.handle(
        _syncStatusMeta,
        syncStatus.isAcceptableOrUnknown(data['sync_status']!, _syncStatusMeta),
      );
    }
    if (data.containsKey('last_success_at')) {
      context.handle(
        _lastSuccessAtMeta,
        lastSuccessAt.isAcceptableOrUnknown(
          data['last_success_at']!,
          _lastSuccessAtMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {vaultId, instanceId, serverSpaceId};
  @override
  SyncCheckpoint map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncCheckpoint(
      vaultId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}vault_id'],
      )!,
      instanceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}instance_id'],
      )!,
      serverSpaceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_space_id'],
      )!,
      cursor: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}cursor'],
      ),
      serverGeneration: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_generation'],
      ),
      syncStatus: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sync_status'],
      )!,
      lastSuccessAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_success_at'],
      ),
    );
  }

  @override
  $SyncCheckpointsTable createAlias(String alias) {
    return $SyncCheckpointsTable(attachedDatabase, alias);
  }
}

class SyncCheckpoint extends DataClass implements Insertable<SyncCheckpoint> {
  final String vaultId;
  final String instanceId;
  final String serverSpaceId;
  final String? cursor;
  final String? serverGeneration;
  final String syncStatus;
  final int? lastSuccessAt;
  const SyncCheckpoint({
    required this.vaultId,
    required this.instanceId,
    required this.serverSpaceId,
    this.cursor,
    this.serverGeneration,
    required this.syncStatus,
    this.lastSuccessAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['vault_id'] = Variable<String>(vaultId);
    map['instance_id'] = Variable<String>(instanceId);
    map['server_space_id'] = Variable<String>(serverSpaceId);
    if (!nullToAbsent || cursor != null) {
      map['cursor'] = Variable<String>(cursor);
    }
    if (!nullToAbsent || serverGeneration != null) {
      map['server_generation'] = Variable<String>(serverGeneration);
    }
    map['sync_status'] = Variable<String>(syncStatus);
    if (!nullToAbsent || lastSuccessAt != null) {
      map['last_success_at'] = Variable<int>(lastSuccessAt);
    }
    return map;
  }

  SyncCheckpointsCompanion toCompanion(bool nullToAbsent) {
    return SyncCheckpointsCompanion(
      vaultId: Value(vaultId),
      instanceId: Value(instanceId),
      serverSpaceId: Value(serverSpaceId),
      cursor: cursor == null && nullToAbsent
          ? const Value.absent()
          : Value(cursor),
      serverGeneration: serverGeneration == null && nullToAbsent
          ? const Value.absent()
          : Value(serverGeneration),
      syncStatus: Value(syncStatus),
      lastSuccessAt: lastSuccessAt == null && nullToAbsent
          ? const Value.absent()
          : Value(lastSuccessAt),
    );
  }

  factory SyncCheckpoint.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncCheckpoint(
      vaultId: serializer.fromJson<String>(json['vaultId']),
      instanceId: serializer.fromJson<String>(json['instanceId']),
      serverSpaceId: serializer.fromJson<String>(json['serverSpaceId']),
      cursor: serializer.fromJson<String?>(json['cursor']),
      serverGeneration: serializer.fromJson<String?>(json['serverGeneration']),
      syncStatus: serializer.fromJson<String>(json['syncStatus']),
      lastSuccessAt: serializer.fromJson<int?>(json['lastSuccessAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'vaultId': serializer.toJson<String>(vaultId),
      'instanceId': serializer.toJson<String>(instanceId),
      'serverSpaceId': serializer.toJson<String>(serverSpaceId),
      'cursor': serializer.toJson<String?>(cursor),
      'serverGeneration': serializer.toJson<String?>(serverGeneration),
      'syncStatus': serializer.toJson<String>(syncStatus),
      'lastSuccessAt': serializer.toJson<int?>(lastSuccessAt),
    };
  }

  SyncCheckpoint copyWith({
    String? vaultId,
    String? instanceId,
    String? serverSpaceId,
    Value<String?> cursor = const Value.absent(),
    Value<String?> serverGeneration = const Value.absent(),
    String? syncStatus,
    Value<int?> lastSuccessAt = const Value.absent(),
  }) => SyncCheckpoint(
    vaultId: vaultId ?? this.vaultId,
    instanceId: instanceId ?? this.instanceId,
    serverSpaceId: serverSpaceId ?? this.serverSpaceId,
    cursor: cursor.present ? cursor.value : this.cursor,
    serverGeneration: serverGeneration.present
        ? serverGeneration.value
        : this.serverGeneration,
    syncStatus: syncStatus ?? this.syncStatus,
    lastSuccessAt: lastSuccessAt.present
        ? lastSuccessAt.value
        : this.lastSuccessAt,
  );
  SyncCheckpoint copyWithCompanion(SyncCheckpointsCompanion data) {
    return SyncCheckpoint(
      vaultId: data.vaultId.present ? data.vaultId.value : this.vaultId,
      instanceId: data.instanceId.present
          ? data.instanceId.value
          : this.instanceId,
      serverSpaceId: data.serverSpaceId.present
          ? data.serverSpaceId.value
          : this.serverSpaceId,
      cursor: data.cursor.present ? data.cursor.value : this.cursor,
      serverGeneration: data.serverGeneration.present
          ? data.serverGeneration.value
          : this.serverGeneration,
      syncStatus: data.syncStatus.present
          ? data.syncStatus.value
          : this.syncStatus,
      lastSuccessAt: data.lastSuccessAt.present
          ? data.lastSuccessAt.value
          : this.lastSuccessAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncCheckpoint(')
          ..write('vaultId: $vaultId, ')
          ..write('instanceId: $instanceId, ')
          ..write('serverSpaceId: $serverSpaceId, ')
          ..write('cursor: $cursor, ')
          ..write('serverGeneration: $serverGeneration, ')
          ..write('syncStatus: $syncStatus, ')
          ..write('lastSuccessAt: $lastSuccessAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    vaultId,
    instanceId,
    serverSpaceId,
    cursor,
    serverGeneration,
    syncStatus,
    lastSuccessAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncCheckpoint &&
          other.vaultId == this.vaultId &&
          other.instanceId == this.instanceId &&
          other.serverSpaceId == this.serverSpaceId &&
          other.cursor == this.cursor &&
          other.serverGeneration == this.serverGeneration &&
          other.syncStatus == this.syncStatus &&
          other.lastSuccessAt == this.lastSuccessAt);
}

class SyncCheckpointsCompanion extends UpdateCompanion<SyncCheckpoint> {
  final Value<String> vaultId;
  final Value<String> instanceId;
  final Value<String> serverSpaceId;
  final Value<String?> cursor;
  final Value<String?> serverGeneration;
  final Value<String> syncStatus;
  final Value<int?> lastSuccessAt;
  final Value<int> rowid;
  const SyncCheckpointsCompanion({
    this.vaultId = const Value.absent(),
    this.instanceId = const Value.absent(),
    this.serverSpaceId = const Value.absent(),
    this.cursor = const Value.absent(),
    this.serverGeneration = const Value.absent(),
    this.syncStatus = const Value.absent(),
    this.lastSuccessAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SyncCheckpointsCompanion.insert({
    required String vaultId,
    this.instanceId = const Value.absent(),
    this.serverSpaceId = const Value.absent(),
    this.cursor = const Value.absent(),
    this.serverGeneration = const Value.absent(),
    this.syncStatus = const Value.absent(),
    this.lastSuccessAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : vaultId = Value(vaultId);
  static Insertable<SyncCheckpoint> custom({
    Expression<String>? vaultId,
    Expression<String>? instanceId,
    Expression<String>? serverSpaceId,
    Expression<String>? cursor,
    Expression<String>? serverGeneration,
    Expression<String>? syncStatus,
    Expression<int>? lastSuccessAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (vaultId != null) 'vault_id': vaultId,
      if (instanceId != null) 'instance_id': instanceId,
      if (serverSpaceId != null) 'server_space_id': serverSpaceId,
      if (cursor != null) 'cursor': cursor,
      if (serverGeneration != null) 'server_generation': serverGeneration,
      if (syncStatus != null) 'sync_status': syncStatus,
      if (lastSuccessAt != null) 'last_success_at': lastSuccessAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SyncCheckpointsCompanion copyWith({
    Value<String>? vaultId,
    Value<String>? instanceId,
    Value<String>? serverSpaceId,
    Value<String?>? cursor,
    Value<String?>? serverGeneration,
    Value<String>? syncStatus,
    Value<int?>? lastSuccessAt,
    Value<int>? rowid,
  }) {
    return SyncCheckpointsCompanion(
      vaultId: vaultId ?? this.vaultId,
      instanceId: instanceId ?? this.instanceId,
      serverSpaceId: serverSpaceId ?? this.serverSpaceId,
      cursor: cursor ?? this.cursor,
      serverGeneration: serverGeneration ?? this.serverGeneration,
      syncStatus: syncStatus ?? this.syncStatus,
      lastSuccessAt: lastSuccessAt ?? this.lastSuccessAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (vaultId.present) {
      map['vault_id'] = Variable<String>(vaultId.value);
    }
    if (instanceId.present) {
      map['instance_id'] = Variable<String>(instanceId.value);
    }
    if (serverSpaceId.present) {
      map['server_space_id'] = Variable<String>(serverSpaceId.value);
    }
    if (cursor.present) {
      map['cursor'] = Variable<String>(cursor.value);
    }
    if (serverGeneration.present) {
      map['server_generation'] = Variable<String>(serverGeneration.value);
    }
    if (syncStatus.present) {
      map['sync_status'] = Variable<String>(syncStatus.value);
    }
    if (lastSuccessAt.present) {
      map['last_success_at'] = Variable<int>(lastSuccessAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncCheckpointsCompanion(')
          ..write('vaultId: $vaultId, ')
          ..write('instanceId: $instanceId, ')
          ..write('serverSpaceId: $serverSpaceId, ')
          ..write('cursor: $cursor, ')
          ..write('serverGeneration: $serverGeneration, ')
          ..write('syncStatus: $syncStatus, ')
          ..write('lastSuccessAt: $lastSuccessAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LockedSyncCheckpointsTable extends LockedSyncCheckpoints
    with TableInfo<$LockedSyncCheckpointsTable, LockedSyncCheckpoint> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LockedSyncCheckpointsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _vaultIdMeta = const VerificationMeta(
    'vaultId',
  );
  @override
  late final GeneratedColumn<String> vaultId = GeneratedColumn<String>(
    'vault_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _instanceIdMeta = const VerificationMeta(
    'instanceId',
  );
  @override
  late final GeneratedColumn<String> instanceId = GeneratedColumn<String>(
    'instance_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _serverSpaceIdMeta = const VerificationMeta(
    'serverSpaceId',
  );
  @override
  late final GeneratedColumn<String> serverSpaceId = GeneratedColumn<String>(
    'server_space_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _serverGenerationMeta = const VerificationMeta(
    'serverGeneration',
  );
  @override
  late final GeneratedColumn<String> serverGeneration = GeneratedColumn<String>(
    'server_generation',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _cursorMeta = const VerificationMeta('cursor');
  @override
  late final GeneratedColumn<String> cursor = GeneratedColumn<String>(
    'cursor',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _nextPageIndexMeta = const VerificationMeta(
    'nextPageIndex',
  );
  @override
  late final GeneratedColumn<int> nextPageIndex = GeneratedColumn<int>(
    'next_page_index',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [
    vaultId,
    instanceId,
    serverSpaceId,
    serverGeneration,
    cursor,
    nextPageIndex,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'locked_sync_checkpoints';
  @override
  VerificationContext validateIntegrity(
    Insertable<LockedSyncCheckpoint> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('vault_id')) {
      context.handle(
        _vaultIdMeta,
        vaultId.isAcceptableOrUnknown(data['vault_id']!, _vaultIdMeta),
      );
    } else if (isInserting) {
      context.missing(_vaultIdMeta);
    }
    if (data.containsKey('instance_id')) {
      context.handle(
        _instanceIdMeta,
        instanceId.isAcceptableOrUnknown(data['instance_id']!, _instanceIdMeta),
      );
    }
    if (data.containsKey('server_space_id')) {
      context.handle(
        _serverSpaceIdMeta,
        serverSpaceId.isAcceptableOrUnknown(
          data['server_space_id']!,
          _serverSpaceIdMeta,
        ),
      );
    }
    if (data.containsKey('server_generation')) {
      context.handle(
        _serverGenerationMeta,
        serverGeneration.isAcceptableOrUnknown(
          data['server_generation']!,
          _serverGenerationMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_serverGenerationMeta);
    }
    if (data.containsKey('cursor')) {
      context.handle(
        _cursorMeta,
        cursor.isAcceptableOrUnknown(data['cursor']!, _cursorMeta),
      );
    }
    if (data.containsKey('next_page_index')) {
      context.handle(
        _nextPageIndexMeta,
        nextPageIndex.isAcceptableOrUnknown(
          data['next_page_index']!,
          _nextPageIndexMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {vaultId, instanceId, serverSpaceId};
  @override
  LockedSyncCheckpoint map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LockedSyncCheckpoint(
      vaultId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}vault_id'],
      )!,
      instanceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}instance_id'],
      )!,
      serverSpaceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_space_id'],
      )!,
      serverGeneration: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_generation'],
      )!,
      cursor: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}cursor'],
      ),
      nextPageIndex: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}next_page_index'],
      )!,
    );
  }

  @override
  $LockedSyncCheckpointsTable createAlias(String alias) {
    return $LockedSyncCheckpointsTable(attachedDatabase, alias);
  }
}

class LockedSyncCheckpoint extends DataClass
    implements Insertable<LockedSyncCheckpoint> {
  final String vaultId;
  final String instanceId;
  final String serverSpaceId;
  final String serverGeneration;
  final String? cursor;
  final int nextPageIndex;
  const LockedSyncCheckpoint({
    required this.vaultId,
    required this.instanceId,
    required this.serverSpaceId,
    required this.serverGeneration,
    this.cursor,
    required this.nextPageIndex,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['vault_id'] = Variable<String>(vaultId);
    map['instance_id'] = Variable<String>(instanceId);
    map['server_space_id'] = Variable<String>(serverSpaceId);
    map['server_generation'] = Variable<String>(serverGeneration);
    if (!nullToAbsent || cursor != null) {
      map['cursor'] = Variable<String>(cursor);
    }
    map['next_page_index'] = Variable<int>(nextPageIndex);
    return map;
  }

  LockedSyncCheckpointsCompanion toCompanion(bool nullToAbsent) {
    return LockedSyncCheckpointsCompanion(
      vaultId: Value(vaultId),
      instanceId: Value(instanceId),
      serverSpaceId: Value(serverSpaceId),
      serverGeneration: Value(serverGeneration),
      cursor: cursor == null && nullToAbsent
          ? const Value.absent()
          : Value(cursor),
      nextPageIndex: Value(nextPageIndex),
    );
  }

  factory LockedSyncCheckpoint.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LockedSyncCheckpoint(
      vaultId: serializer.fromJson<String>(json['vaultId']),
      instanceId: serializer.fromJson<String>(json['instanceId']),
      serverSpaceId: serializer.fromJson<String>(json['serverSpaceId']),
      serverGeneration: serializer.fromJson<String>(json['serverGeneration']),
      cursor: serializer.fromJson<String?>(json['cursor']),
      nextPageIndex: serializer.fromJson<int>(json['nextPageIndex']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'vaultId': serializer.toJson<String>(vaultId),
      'instanceId': serializer.toJson<String>(instanceId),
      'serverSpaceId': serializer.toJson<String>(serverSpaceId),
      'serverGeneration': serializer.toJson<String>(serverGeneration),
      'cursor': serializer.toJson<String?>(cursor),
      'nextPageIndex': serializer.toJson<int>(nextPageIndex),
    };
  }

  LockedSyncCheckpoint copyWith({
    String? vaultId,
    String? instanceId,
    String? serverSpaceId,
    String? serverGeneration,
    Value<String?> cursor = const Value.absent(),
    int? nextPageIndex,
  }) => LockedSyncCheckpoint(
    vaultId: vaultId ?? this.vaultId,
    instanceId: instanceId ?? this.instanceId,
    serverSpaceId: serverSpaceId ?? this.serverSpaceId,
    serverGeneration: serverGeneration ?? this.serverGeneration,
    cursor: cursor.present ? cursor.value : this.cursor,
    nextPageIndex: nextPageIndex ?? this.nextPageIndex,
  );
  LockedSyncCheckpoint copyWithCompanion(LockedSyncCheckpointsCompanion data) {
    return LockedSyncCheckpoint(
      vaultId: data.vaultId.present ? data.vaultId.value : this.vaultId,
      instanceId: data.instanceId.present
          ? data.instanceId.value
          : this.instanceId,
      serverSpaceId: data.serverSpaceId.present
          ? data.serverSpaceId.value
          : this.serverSpaceId,
      serverGeneration: data.serverGeneration.present
          ? data.serverGeneration.value
          : this.serverGeneration,
      cursor: data.cursor.present ? data.cursor.value : this.cursor,
      nextPageIndex: data.nextPageIndex.present
          ? data.nextPageIndex.value
          : this.nextPageIndex,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LockedSyncCheckpoint(')
          ..write('vaultId: $vaultId, ')
          ..write('instanceId: $instanceId, ')
          ..write('serverSpaceId: $serverSpaceId, ')
          ..write('serverGeneration: $serverGeneration, ')
          ..write('cursor: $cursor, ')
          ..write('nextPageIndex: $nextPageIndex')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    vaultId,
    instanceId,
    serverSpaceId,
    serverGeneration,
    cursor,
    nextPageIndex,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LockedSyncCheckpoint &&
          other.vaultId == this.vaultId &&
          other.instanceId == this.instanceId &&
          other.serverSpaceId == this.serverSpaceId &&
          other.serverGeneration == this.serverGeneration &&
          other.cursor == this.cursor &&
          other.nextPageIndex == this.nextPageIndex);
}

class LockedSyncCheckpointsCompanion
    extends UpdateCompanion<LockedSyncCheckpoint> {
  final Value<String> vaultId;
  final Value<String> instanceId;
  final Value<String> serverSpaceId;
  final Value<String> serverGeneration;
  final Value<String?> cursor;
  final Value<int> nextPageIndex;
  final Value<int> rowid;
  const LockedSyncCheckpointsCompanion({
    this.vaultId = const Value.absent(),
    this.instanceId = const Value.absent(),
    this.serverSpaceId = const Value.absent(),
    this.serverGeneration = const Value.absent(),
    this.cursor = const Value.absent(),
    this.nextPageIndex = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LockedSyncCheckpointsCompanion.insert({
    required String vaultId,
    this.instanceId = const Value.absent(),
    this.serverSpaceId = const Value.absent(),
    required String serverGeneration,
    this.cursor = const Value.absent(),
    this.nextPageIndex = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : vaultId = Value(vaultId),
       serverGeneration = Value(serverGeneration);
  static Insertable<LockedSyncCheckpoint> custom({
    Expression<String>? vaultId,
    Expression<String>? instanceId,
    Expression<String>? serverSpaceId,
    Expression<String>? serverGeneration,
    Expression<String>? cursor,
    Expression<int>? nextPageIndex,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (vaultId != null) 'vault_id': vaultId,
      if (instanceId != null) 'instance_id': instanceId,
      if (serverSpaceId != null) 'server_space_id': serverSpaceId,
      if (serverGeneration != null) 'server_generation': serverGeneration,
      if (cursor != null) 'cursor': cursor,
      if (nextPageIndex != null) 'next_page_index': nextPageIndex,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LockedSyncCheckpointsCompanion copyWith({
    Value<String>? vaultId,
    Value<String>? instanceId,
    Value<String>? serverSpaceId,
    Value<String>? serverGeneration,
    Value<String?>? cursor,
    Value<int>? nextPageIndex,
    Value<int>? rowid,
  }) {
    return LockedSyncCheckpointsCompanion(
      vaultId: vaultId ?? this.vaultId,
      instanceId: instanceId ?? this.instanceId,
      serverSpaceId: serverSpaceId ?? this.serverSpaceId,
      serverGeneration: serverGeneration ?? this.serverGeneration,
      cursor: cursor ?? this.cursor,
      nextPageIndex: nextPageIndex ?? this.nextPageIndex,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (vaultId.present) {
      map['vault_id'] = Variable<String>(vaultId.value);
    }
    if (instanceId.present) {
      map['instance_id'] = Variable<String>(instanceId.value);
    }
    if (serverSpaceId.present) {
      map['server_space_id'] = Variable<String>(serverSpaceId.value);
    }
    if (serverGeneration.present) {
      map['server_generation'] = Variable<String>(serverGeneration.value);
    }
    if (cursor.present) {
      map['cursor'] = Variable<String>(cursor.value);
    }
    if (nextPageIndex.present) {
      map['next_page_index'] = Variable<int>(nextPageIndex.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LockedSyncCheckpointsCompanion(')
          ..write('vaultId: $vaultId, ')
          ..write('instanceId: $instanceId, ')
          ..write('serverSpaceId: $serverSpaceId, ')
          ..write('serverGeneration: $serverGeneration, ')
          ..write('cursor: $cursor, ')
          ..write('nextPageIndex: $nextPageIndex, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LockedSyncInboxPagesTable extends LockedSyncInboxPages
    with TableInfo<$LockedSyncInboxPagesTable, LockedSyncInboxPage> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LockedSyncInboxPagesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _vaultIdMeta = const VerificationMeta(
    'vaultId',
  );
  @override
  late final GeneratedColumn<String> vaultId = GeneratedColumn<String>(
    'vault_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _instanceIdMeta = const VerificationMeta(
    'instanceId',
  );
  @override
  late final GeneratedColumn<String> instanceId = GeneratedColumn<String>(
    'instance_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _serverSpaceIdMeta = const VerificationMeta(
    'serverSpaceId',
  );
  @override
  late final GeneratedColumn<String> serverSpaceId = GeneratedColumn<String>(
    'server_space_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _serverGenerationMeta = const VerificationMeta(
    'serverGeneration',
  );
  @override
  late final GeneratedColumn<String> serverGeneration = GeneratedColumn<String>(
    'server_generation',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _pageIndexMeta = const VerificationMeta(
    'pageIndex',
  );
  @override
  late final GeneratedColumn<int> pageIndex = GeneratedColumn<int>(
    'page_index',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _startCursorMeta = const VerificationMeta(
    'startCursor',
  );
  @override
  late final GeneratedColumn<String> startCursor = GeneratedColumn<String>(
    'start_cursor',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _nextCursorMeta = const VerificationMeta(
    'nextCursor',
  );
  @override
  late final GeneratedColumn<String> nextCursor = GeneratedColumn<String>(
    'next_cursor',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _hasMoreMeta = const VerificationMeta(
    'hasMore',
  );
  @override
  late final GeneratedColumn<bool> hasMore = GeneratedColumn<bool>(
    'has_more',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("has_more" IN (0, 1))',
    ),
  );
  static const VerificationMeta _eventsJsonMeta = const VerificationMeta(
    'eventsJson',
  );
  @override
  late final GeneratedColumn<String> eventsJson = GeneratedColumn<String>(
    'events_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    vaultId,
    instanceId,
    serverSpaceId,
    serverGeneration,
    pageIndex,
    startCursor,
    nextCursor,
    hasMore,
    eventsJson,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'locked_sync_inbox_pages';
  @override
  VerificationContext validateIntegrity(
    Insertable<LockedSyncInboxPage> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('vault_id')) {
      context.handle(
        _vaultIdMeta,
        vaultId.isAcceptableOrUnknown(data['vault_id']!, _vaultIdMeta),
      );
    } else if (isInserting) {
      context.missing(_vaultIdMeta);
    }
    if (data.containsKey('instance_id')) {
      context.handle(
        _instanceIdMeta,
        instanceId.isAcceptableOrUnknown(data['instance_id']!, _instanceIdMeta),
      );
    }
    if (data.containsKey('server_space_id')) {
      context.handle(
        _serverSpaceIdMeta,
        serverSpaceId.isAcceptableOrUnknown(
          data['server_space_id']!,
          _serverSpaceIdMeta,
        ),
      );
    }
    if (data.containsKey('server_generation')) {
      context.handle(
        _serverGenerationMeta,
        serverGeneration.isAcceptableOrUnknown(
          data['server_generation']!,
          _serverGenerationMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_serverGenerationMeta);
    }
    if (data.containsKey('page_index')) {
      context.handle(
        _pageIndexMeta,
        pageIndex.isAcceptableOrUnknown(data['page_index']!, _pageIndexMeta),
      );
    } else if (isInserting) {
      context.missing(_pageIndexMeta);
    }
    if (data.containsKey('start_cursor')) {
      context.handle(
        _startCursorMeta,
        startCursor.isAcceptableOrUnknown(
          data['start_cursor']!,
          _startCursorMeta,
        ),
      );
    }
    if (data.containsKey('next_cursor')) {
      context.handle(
        _nextCursorMeta,
        nextCursor.isAcceptableOrUnknown(data['next_cursor']!, _nextCursorMeta),
      );
    }
    if (data.containsKey('has_more')) {
      context.handle(
        _hasMoreMeta,
        hasMore.isAcceptableOrUnknown(data['has_more']!, _hasMoreMeta),
      );
    } else if (isInserting) {
      context.missing(_hasMoreMeta);
    }
    if (data.containsKey('events_json')) {
      context.handle(
        _eventsJsonMeta,
        eventsJson.isAcceptableOrUnknown(data['events_json']!, _eventsJsonMeta),
      );
    } else if (isInserting) {
      context.missing(_eventsJsonMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {
    vaultId,
    instanceId,
    serverSpaceId,
    serverGeneration,
    pageIndex,
  };
  @override
  LockedSyncInboxPage map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LockedSyncInboxPage(
      vaultId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}vault_id'],
      )!,
      instanceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}instance_id'],
      )!,
      serverSpaceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_space_id'],
      )!,
      serverGeneration: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_generation'],
      )!,
      pageIndex: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}page_index'],
      )!,
      startCursor: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}start_cursor'],
      ),
      nextCursor: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}next_cursor'],
      ),
      hasMore: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}has_more'],
      )!,
      eventsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}events_json'],
      )!,
    );
  }

  @override
  $LockedSyncInboxPagesTable createAlias(String alias) {
    return $LockedSyncInboxPagesTable(attachedDatabase, alias);
  }
}

class LockedSyncInboxPage extends DataClass
    implements Insertable<LockedSyncInboxPage> {
  final String vaultId;
  final String instanceId;
  final String serverSpaceId;
  final String serverGeneration;
  final int pageIndex;
  final String? startCursor;
  final String? nextCursor;
  final bool hasMore;
  final String eventsJson;
  const LockedSyncInboxPage({
    required this.vaultId,
    required this.instanceId,
    required this.serverSpaceId,
    required this.serverGeneration,
    required this.pageIndex,
    this.startCursor,
    this.nextCursor,
    required this.hasMore,
    required this.eventsJson,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['vault_id'] = Variable<String>(vaultId);
    map['instance_id'] = Variable<String>(instanceId);
    map['server_space_id'] = Variable<String>(serverSpaceId);
    map['server_generation'] = Variable<String>(serverGeneration);
    map['page_index'] = Variable<int>(pageIndex);
    if (!nullToAbsent || startCursor != null) {
      map['start_cursor'] = Variable<String>(startCursor);
    }
    if (!nullToAbsent || nextCursor != null) {
      map['next_cursor'] = Variable<String>(nextCursor);
    }
    map['has_more'] = Variable<bool>(hasMore);
    map['events_json'] = Variable<String>(eventsJson);
    return map;
  }

  LockedSyncInboxPagesCompanion toCompanion(bool nullToAbsent) {
    return LockedSyncInboxPagesCompanion(
      vaultId: Value(vaultId),
      instanceId: Value(instanceId),
      serverSpaceId: Value(serverSpaceId),
      serverGeneration: Value(serverGeneration),
      pageIndex: Value(pageIndex),
      startCursor: startCursor == null && nullToAbsent
          ? const Value.absent()
          : Value(startCursor),
      nextCursor: nextCursor == null && nullToAbsent
          ? const Value.absent()
          : Value(nextCursor),
      hasMore: Value(hasMore),
      eventsJson: Value(eventsJson),
    );
  }

  factory LockedSyncInboxPage.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LockedSyncInboxPage(
      vaultId: serializer.fromJson<String>(json['vaultId']),
      instanceId: serializer.fromJson<String>(json['instanceId']),
      serverSpaceId: serializer.fromJson<String>(json['serverSpaceId']),
      serverGeneration: serializer.fromJson<String>(json['serverGeneration']),
      pageIndex: serializer.fromJson<int>(json['pageIndex']),
      startCursor: serializer.fromJson<String?>(json['startCursor']),
      nextCursor: serializer.fromJson<String?>(json['nextCursor']),
      hasMore: serializer.fromJson<bool>(json['hasMore']),
      eventsJson: serializer.fromJson<String>(json['eventsJson']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'vaultId': serializer.toJson<String>(vaultId),
      'instanceId': serializer.toJson<String>(instanceId),
      'serverSpaceId': serializer.toJson<String>(serverSpaceId),
      'serverGeneration': serializer.toJson<String>(serverGeneration),
      'pageIndex': serializer.toJson<int>(pageIndex),
      'startCursor': serializer.toJson<String?>(startCursor),
      'nextCursor': serializer.toJson<String?>(nextCursor),
      'hasMore': serializer.toJson<bool>(hasMore),
      'eventsJson': serializer.toJson<String>(eventsJson),
    };
  }

  LockedSyncInboxPage copyWith({
    String? vaultId,
    String? instanceId,
    String? serverSpaceId,
    String? serverGeneration,
    int? pageIndex,
    Value<String?> startCursor = const Value.absent(),
    Value<String?> nextCursor = const Value.absent(),
    bool? hasMore,
    String? eventsJson,
  }) => LockedSyncInboxPage(
    vaultId: vaultId ?? this.vaultId,
    instanceId: instanceId ?? this.instanceId,
    serverSpaceId: serverSpaceId ?? this.serverSpaceId,
    serverGeneration: serverGeneration ?? this.serverGeneration,
    pageIndex: pageIndex ?? this.pageIndex,
    startCursor: startCursor.present ? startCursor.value : this.startCursor,
    nextCursor: nextCursor.present ? nextCursor.value : this.nextCursor,
    hasMore: hasMore ?? this.hasMore,
    eventsJson: eventsJson ?? this.eventsJson,
  );
  LockedSyncInboxPage copyWithCompanion(LockedSyncInboxPagesCompanion data) {
    return LockedSyncInboxPage(
      vaultId: data.vaultId.present ? data.vaultId.value : this.vaultId,
      instanceId: data.instanceId.present
          ? data.instanceId.value
          : this.instanceId,
      serverSpaceId: data.serverSpaceId.present
          ? data.serverSpaceId.value
          : this.serverSpaceId,
      serverGeneration: data.serverGeneration.present
          ? data.serverGeneration.value
          : this.serverGeneration,
      pageIndex: data.pageIndex.present ? data.pageIndex.value : this.pageIndex,
      startCursor: data.startCursor.present
          ? data.startCursor.value
          : this.startCursor,
      nextCursor: data.nextCursor.present
          ? data.nextCursor.value
          : this.nextCursor,
      hasMore: data.hasMore.present ? data.hasMore.value : this.hasMore,
      eventsJson: data.eventsJson.present
          ? data.eventsJson.value
          : this.eventsJson,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LockedSyncInboxPage(')
          ..write('vaultId: $vaultId, ')
          ..write('instanceId: $instanceId, ')
          ..write('serverSpaceId: $serverSpaceId, ')
          ..write('serverGeneration: $serverGeneration, ')
          ..write('pageIndex: $pageIndex, ')
          ..write('startCursor: $startCursor, ')
          ..write('nextCursor: $nextCursor, ')
          ..write('hasMore: $hasMore, ')
          ..write('eventsJson: $eventsJson')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    vaultId,
    instanceId,
    serverSpaceId,
    serverGeneration,
    pageIndex,
    startCursor,
    nextCursor,
    hasMore,
    eventsJson,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LockedSyncInboxPage &&
          other.vaultId == this.vaultId &&
          other.instanceId == this.instanceId &&
          other.serverSpaceId == this.serverSpaceId &&
          other.serverGeneration == this.serverGeneration &&
          other.pageIndex == this.pageIndex &&
          other.startCursor == this.startCursor &&
          other.nextCursor == this.nextCursor &&
          other.hasMore == this.hasMore &&
          other.eventsJson == this.eventsJson);
}

class LockedSyncInboxPagesCompanion
    extends UpdateCompanion<LockedSyncInboxPage> {
  final Value<String> vaultId;
  final Value<String> instanceId;
  final Value<String> serverSpaceId;
  final Value<String> serverGeneration;
  final Value<int> pageIndex;
  final Value<String?> startCursor;
  final Value<String?> nextCursor;
  final Value<bool> hasMore;
  final Value<String> eventsJson;
  final Value<int> rowid;
  const LockedSyncInboxPagesCompanion({
    this.vaultId = const Value.absent(),
    this.instanceId = const Value.absent(),
    this.serverSpaceId = const Value.absent(),
    this.serverGeneration = const Value.absent(),
    this.pageIndex = const Value.absent(),
    this.startCursor = const Value.absent(),
    this.nextCursor = const Value.absent(),
    this.hasMore = const Value.absent(),
    this.eventsJson = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LockedSyncInboxPagesCompanion.insert({
    required String vaultId,
    this.instanceId = const Value.absent(),
    this.serverSpaceId = const Value.absent(),
    required String serverGeneration,
    required int pageIndex,
    this.startCursor = const Value.absent(),
    this.nextCursor = const Value.absent(),
    required bool hasMore,
    required String eventsJson,
    this.rowid = const Value.absent(),
  }) : vaultId = Value(vaultId),
       serverGeneration = Value(serverGeneration),
       pageIndex = Value(pageIndex),
       hasMore = Value(hasMore),
       eventsJson = Value(eventsJson);
  static Insertable<LockedSyncInboxPage> custom({
    Expression<String>? vaultId,
    Expression<String>? instanceId,
    Expression<String>? serverSpaceId,
    Expression<String>? serverGeneration,
    Expression<int>? pageIndex,
    Expression<String>? startCursor,
    Expression<String>? nextCursor,
    Expression<bool>? hasMore,
    Expression<String>? eventsJson,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (vaultId != null) 'vault_id': vaultId,
      if (instanceId != null) 'instance_id': instanceId,
      if (serverSpaceId != null) 'server_space_id': serverSpaceId,
      if (serverGeneration != null) 'server_generation': serverGeneration,
      if (pageIndex != null) 'page_index': pageIndex,
      if (startCursor != null) 'start_cursor': startCursor,
      if (nextCursor != null) 'next_cursor': nextCursor,
      if (hasMore != null) 'has_more': hasMore,
      if (eventsJson != null) 'events_json': eventsJson,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LockedSyncInboxPagesCompanion copyWith({
    Value<String>? vaultId,
    Value<String>? instanceId,
    Value<String>? serverSpaceId,
    Value<String>? serverGeneration,
    Value<int>? pageIndex,
    Value<String?>? startCursor,
    Value<String?>? nextCursor,
    Value<bool>? hasMore,
    Value<String>? eventsJson,
    Value<int>? rowid,
  }) {
    return LockedSyncInboxPagesCompanion(
      vaultId: vaultId ?? this.vaultId,
      instanceId: instanceId ?? this.instanceId,
      serverSpaceId: serverSpaceId ?? this.serverSpaceId,
      serverGeneration: serverGeneration ?? this.serverGeneration,
      pageIndex: pageIndex ?? this.pageIndex,
      startCursor: startCursor ?? this.startCursor,
      nextCursor: nextCursor ?? this.nextCursor,
      hasMore: hasMore ?? this.hasMore,
      eventsJson: eventsJson ?? this.eventsJson,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (vaultId.present) {
      map['vault_id'] = Variable<String>(vaultId.value);
    }
    if (instanceId.present) {
      map['instance_id'] = Variable<String>(instanceId.value);
    }
    if (serverSpaceId.present) {
      map['server_space_id'] = Variable<String>(serverSpaceId.value);
    }
    if (serverGeneration.present) {
      map['server_generation'] = Variable<String>(serverGeneration.value);
    }
    if (pageIndex.present) {
      map['page_index'] = Variable<int>(pageIndex.value);
    }
    if (startCursor.present) {
      map['start_cursor'] = Variable<String>(startCursor.value);
    }
    if (nextCursor.present) {
      map['next_cursor'] = Variable<String>(nextCursor.value);
    }
    if (hasMore.present) {
      map['has_more'] = Variable<bool>(hasMore.value);
    }
    if (eventsJson.present) {
      map['events_json'] = Variable<String>(eventsJson.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LockedSyncInboxPagesCompanion(')
          ..write('vaultId: $vaultId, ')
          ..write('instanceId: $instanceId, ')
          ..write('serverSpaceId: $serverSpaceId, ')
          ..write('serverGeneration: $serverGeneration, ')
          ..write('pageIndex: $pageIndex, ')
          ..write('startCursor: $startCursor, ')
          ..write('nextCursor: $nextCursor, ')
          ..write('hasMore: $hasMore, ')
          ..write('eventsJson: $eventsJson, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SyncSnapshotRecoveryStagesTable extends SyncSnapshotRecoveryStages
    with
        TableInfo<$SyncSnapshotRecoveryStagesTable, SyncSnapshotRecoveryStage> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncSnapshotRecoveryStagesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _serverNamespaceMeta = const VerificationMeta(
    'serverNamespace',
  );
  @override
  late final GeneratedColumn<String> serverNamespace = GeneratedColumn<String>(
    'server_namespace',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<String> accountId = GeneratedColumn<String>(
    'account_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _instanceIdMeta = const VerificationMeta(
    'instanceId',
  );
  @override
  late final GeneratedColumn<String> instanceId = GeneratedColumn<String>(
    'instance_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _serverSpaceIdMeta = const VerificationMeta(
    'serverSpaceId',
  );
  @override
  late final GeneratedColumn<String> serverSpaceId = GeneratedColumn<String>(
    'server_space_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _vaultIdMeta = const VerificationMeta(
    'vaultId',
  );
  @override
  late final GeneratedColumn<String> vaultId = GeneratedColumn<String>(
    'vault_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _serverGenerationMeta = const VerificationMeta(
    'serverGeneration',
  );
  @override
  late final GeneratedColumn<String> serverGeneration = GeneratedColumn<String>(
    'server_generation',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _snapshotIdMeta = const VerificationMeta(
    'snapshotId',
  );
  @override
  late final GeneratedColumn<String> snapshotId = GeneratedColumn<String>(
    'snapshot_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _highWatermarkMeta = const VerificationMeta(
    'highWatermark',
  );
  @override
  late final GeneratedColumn<String> highWatermark = GeneratedColumn<String>(
    'high_watermark',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _conflictHighWatermarkMeta =
      const VerificationMeta('conflictHighWatermark');
  @override
  late final GeneratedColumn<String> conflictHighWatermark =
      GeneratedColumn<String>(
        'conflict_high_watermark',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: true,
      );
  static const VerificationMeta _checkpointCursorMeta = const VerificationMeta(
    'checkpointCursor',
  );
  @override
  late final GeneratedColumn<String> checkpointCursor = GeneratedColumn<String>(
    'checkpoint_cursor',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _expiresAtMeta = const VerificationMeta(
    'expiresAt',
  );
  @override
  late final GeneratedColumn<String> expiresAt = GeneratedColumn<String>(
    'expires_at',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nextPageCursorMeta = const VerificationMeta(
    'nextPageCursor',
  );
  @override
  late final GeneratedColumn<String> nextPageCursor = GeneratedColumn<String>(
    'next_page_cursor',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _lastRecordIdMeta = const VerificationMeta(
    'lastRecordId',
  );
  @override
  late final GeneratedColumn<String> lastRecordId = GeneratedColumn<String>(
    'last_record_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _expectedItemCountMeta = const VerificationMeta(
    'expectedItemCount',
  );
  @override
  late final GeneratedColumn<int> expectedItemCount = GeneratedColumn<int>(
    'expected_item_count',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _itemCountObservedMeta = const VerificationMeta(
    'itemCountObserved',
  );
  @override
  late final GeneratedColumn<bool> itemCountObserved = GeneratedColumn<bool>(
    'item_count_observed',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("item_count_observed" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _itemCountPresentMeta = const VerificationMeta(
    'itemCountPresent',
  );
  @override
  late final GeneratedColumn<bool> itemCountPresent = GeneratedColumn<bool>(
    'item_count_present',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("item_count_present" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _verifiedItemCountMeta = const VerificationMeta(
    'verifiedItemCount',
  );
  @override
  late final GeneratedColumn<int> verifiedItemCount = GeneratedColumn<int>(
    'verified_item_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _serializedManifestBytesMeta =
      const VerificationMeta('serializedManifestBytes');
  @override
  late final GeneratedColumn<int> serializedManifestBytes =
      GeneratedColumn<int>(
        'serialized_manifest_bytes',
        aliasedName,
        false,
        type: DriftSqlType.int,
        requiredDuringInsert: false,
        defaultValue: const Constant(2),
      );
  static const VerificationMeta _pageCountMeta = const VerificationMeta(
    'pageCount',
  );
  @override
  late final GeneratedColumn<int> pageCount = GeneratedColumn<int>(
    'page_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _legacyFullManifestMeta =
      const VerificationMeta('legacyFullManifest');
  @override
  late final GeneratedColumn<bool> legacyFullManifest = GeneratedColumn<bool>(
    'legacy_full_manifest',
    aliasedName,
    true,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("legacy_full_manifest" IN (0, 1))',
    ),
  );
  static const VerificationMeta _completeMeta = const VerificationMeta(
    'complete',
  );
  @override
  late final GeneratedColumn<bool> complete = GeneratedColumn<bool>(
    'complete',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("complete" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    serverNamespace,
    accountId,
    instanceId,
    serverSpaceId,
    vaultId,
    serverGeneration,
    snapshotId,
    highWatermark,
    conflictHighWatermark,
    checkpointCursor,
    expiresAt,
    nextPageCursor,
    lastRecordId,
    expectedItemCount,
    itemCountObserved,
    itemCountPresent,
    verifiedItemCount,
    serializedManifestBytes,
    pageCount,
    legacyFullManifest,
    complete,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_snapshot_recovery_stages';
  @override
  VerificationContext validateIntegrity(
    Insertable<SyncSnapshotRecoveryStage> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('server_namespace')) {
      context.handle(
        _serverNamespaceMeta,
        serverNamespace.isAcceptableOrUnknown(
          data['server_namespace']!,
          _serverNamespaceMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_serverNamespaceMeta);
    }
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    } else if (isInserting) {
      context.missing(_accountIdMeta);
    }
    if (data.containsKey('instance_id')) {
      context.handle(
        _instanceIdMeta,
        instanceId.isAcceptableOrUnknown(data['instance_id']!, _instanceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_instanceIdMeta);
    }
    if (data.containsKey('server_space_id')) {
      context.handle(
        _serverSpaceIdMeta,
        serverSpaceId.isAcceptableOrUnknown(
          data['server_space_id']!,
          _serverSpaceIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_serverSpaceIdMeta);
    }
    if (data.containsKey('vault_id')) {
      context.handle(
        _vaultIdMeta,
        vaultId.isAcceptableOrUnknown(data['vault_id']!, _vaultIdMeta),
      );
    } else if (isInserting) {
      context.missing(_vaultIdMeta);
    }
    if (data.containsKey('server_generation')) {
      context.handle(
        _serverGenerationMeta,
        serverGeneration.isAcceptableOrUnknown(
          data['server_generation']!,
          _serverGenerationMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_serverGenerationMeta);
    }
    if (data.containsKey('snapshot_id')) {
      context.handle(
        _snapshotIdMeta,
        snapshotId.isAcceptableOrUnknown(data['snapshot_id']!, _snapshotIdMeta),
      );
    } else if (isInserting) {
      context.missing(_snapshotIdMeta);
    }
    if (data.containsKey('high_watermark')) {
      context.handle(
        _highWatermarkMeta,
        highWatermark.isAcceptableOrUnknown(
          data['high_watermark']!,
          _highWatermarkMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_highWatermarkMeta);
    }
    if (data.containsKey('conflict_high_watermark')) {
      context.handle(
        _conflictHighWatermarkMeta,
        conflictHighWatermark.isAcceptableOrUnknown(
          data['conflict_high_watermark']!,
          _conflictHighWatermarkMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_conflictHighWatermarkMeta);
    }
    if (data.containsKey('checkpoint_cursor')) {
      context.handle(
        _checkpointCursorMeta,
        checkpointCursor.isAcceptableOrUnknown(
          data['checkpoint_cursor']!,
          _checkpointCursorMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_checkpointCursorMeta);
    }
    if (data.containsKey('expires_at')) {
      context.handle(
        _expiresAtMeta,
        expiresAt.isAcceptableOrUnknown(data['expires_at']!, _expiresAtMeta),
      );
    } else if (isInserting) {
      context.missing(_expiresAtMeta);
    }
    if (data.containsKey('next_page_cursor')) {
      context.handle(
        _nextPageCursorMeta,
        nextPageCursor.isAcceptableOrUnknown(
          data['next_page_cursor']!,
          _nextPageCursorMeta,
        ),
      );
    }
    if (data.containsKey('last_record_id')) {
      context.handle(
        _lastRecordIdMeta,
        lastRecordId.isAcceptableOrUnknown(
          data['last_record_id']!,
          _lastRecordIdMeta,
        ),
      );
    }
    if (data.containsKey('expected_item_count')) {
      context.handle(
        _expectedItemCountMeta,
        expectedItemCount.isAcceptableOrUnknown(
          data['expected_item_count']!,
          _expectedItemCountMeta,
        ),
      );
    }
    if (data.containsKey('item_count_observed')) {
      context.handle(
        _itemCountObservedMeta,
        itemCountObserved.isAcceptableOrUnknown(
          data['item_count_observed']!,
          _itemCountObservedMeta,
        ),
      );
    }
    if (data.containsKey('item_count_present')) {
      context.handle(
        _itemCountPresentMeta,
        itemCountPresent.isAcceptableOrUnknown(
          data['item_count_present']!,
          _itemCountPresentMeta,
        ),
      );
    }
    if (data.containsKey('verified_item_count')) {
      context.handle(
        _verifiedItemCountMeta,
        verifiedItemCount.isAcceptableOrUnknown(
          data['verified_item_count']!,
          _verifiedItemCountMeta,
        ),
      );
    }
    if (data.containsKey('serialized_manifest_bytes')) {
      context.handle(
        _serializedManifestBytesMeta,
        serializedManifestBytes.isAcceptableOrUnknown(
          data['serialized_manifest_bytes']!,
          _serializedManifestBytesMeta,
        ),
      );
    }
    if (data.containsKey('page_count')) {
      context.handle(
        _pageCountMeta,
        pageCount.isAcceptableOrUnknown(data['page_count']!, _pageCountMeta),
      );
    }
    if (data.containsKey('legacy_full_manifest')) {
      context.handle(
        _legacyFullManifestMeta,
        legacyFullManifest.isAcceptableOrUnknown(
          data['legacy_full_manifest']!,
          _legacyFullManifestMeta,
        ),
      );
    }
    if (data.containsKey('complete')) {
      context.handle(
        _completeMeta,
        complete.isAcceptableOrUnknown(data['complete']!, _completeMeta),
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
  Set<GeneratedColumn> get $primaryKey => {
    serverNamespace,
    accountId,
    instanceId,
    serverSpaceId,
    vaultId,
    serverGeneration,
    snapshotId,
  };
  @override
  SyncSnapshotRecoveryStage map(
    Map<String, dynamic> data, {
    String? tablePrefix,
  }) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncSnapshotRecoveryStage(
      serverNamespace: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_namespace'],
      )!,
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}account_id'],
      )!,
      instanceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}instance_id'],
      )!,
      serverSpaceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_space_id'],
      )!,
      vaultId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}vault_id'],
      )!,
      serverGeneration: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_generation'],
      )!,
      snapshotId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}snapshot_id'],
      )!,
      highWatermark: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}high_watermark'],
      )!,
      conflictHighWatermark: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conflict_high_watermark'],
      )!,
      checkpointCursor: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}checkpoint_cursor'],
      )!,
      expiresAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}expires_at'],
      )!,
      nextPageCursor: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}next_page_cursor'],
      ),
      lastRecordId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}last_record_id'],
      ),
      expectedItemCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}expected_item_count'],
      ),
      itemCountObserved: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}item_count_observed'],
      )!,
      itemCountPresent: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}item_count_present'],
      )!,
      verifiedItemCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}verified_item_count'],
      )!,
      serializedManifestBytes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}serialized_manifest_bytes'],
      )!,
      pageCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}page_count'],
      )!,
      legacyFullManifest: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}legacy_full_manifest'],
      ),
      complete: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}complete'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $SyncSnapshotRecoveryStagesTable createAlias(String alias) {
    return $SyncSnapshotRecoveryStagesTable(attachedDatabase, alias);
  }
}

class SyncSnapshotRecoveryStage extends DataClass
    implements Insertable<SyncSnapshotRecoveryStage> {
  final String serverNamespace;
  final String accountId;
  final String instanceId;
  final String serverSpaceId;
  final String vaultId;
  final String serverGeneration;
  final String snapshotId;
  final String highWatermark;
  final String conflictHighWatermark;
  final String checkpointCursor;
  final String expiresAt;
  final String? nextPageCursor;
  final String? lastRecordId;
  final int? expectedItemCount;
  final bool itemCountObserved;
  final bool itemCountPresent;
  final int verifiedItemCount;
  final int serializedManifestBytes;
  final int pageCount;
  final bool? legacyFullManifest;
  final bool complete;
  final int createdAt;
  const SyncSnapshotRecoveryStage({
    required this.serverNamespace,
    required this.accountId,
    required this.instanceId,
    required this.serverSpaceId,
    required this.vaultId,
    required this.serverGeneration,
    required this.snapshotId,
    required this.highWatermark,
    required this.conflictHighWatermark,
    required this.checkpointCursor,
    required this.expiresAt,
    this.nextPageCursor,
    this.lastRecordId,
    this.expectedItemCount,
    required this.itemCountObserved,
    required this.itemCountPresent,
    required this.verifiedItemCount,
    required this.serializedManifestBytes,
    required this.pageCount,
    this.legacyFullManifest,
    required this.complete,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['server_namespace'] = Variable<String>(serverNamespace);
    map['account_id'] = Variable<String>(accountId);
    map['instance_id'] = Variable<String>(instanceId);
    map['server_space_id'] = Variable<String>(serverSpaceId);
    map['vault_id'] = Variable<String>(vaultId);
    map['server_generation'] = Variable<String>(serverGeneration);
    map['snapshot_id'] = Variable<String>(snapshotId);
    map['high_watermark'] = Variable<String>(highWatermark);
    map['conflict_high_watermark'] = Variable<String>(conflictHighWatermark);
    map['checkpoint_cursor'] = Variable<String>(checkpointCursor);
    map['expires_at'] = Variable<String>(expiresAt);
    if (!nullToAbsent || nextPageCursor != null) {
      map['next_page_cursor'] = Variable<String>(nextPageCursor);
    }
    if (!nullToAbsent || lastRecordId != null) {
      map['last_record_id'] = Variable<String>(lastRecordId);
    }
    if (!nullToAbsent || expectedItemCount != null) {
      map['expected_item_count'] = Variable<int>(expectedItemCount);
    }
    map['item_count_observed'] = Variable<bool>(itemCountObserved);
    map['item_count_present'] = Variable<bool>(itemCountPresent);
    map['verified_item_count'] = Variable<int>(verifiedItemCount);
    map['serialized_manifest_bytes'] = Variable<int>(serializedManifestBytes);
    map['page_count'] = Variable<int>(pageCount);
    if (!nullToAbsent || legacyFullManifest != null) {
      map['legacy_full_manifest'] = Variable<bool>(legacyFullManifest);
    }
    map['complete'] = Variable<bool>(complete);
    map['created_at'] = Variable<int>(createdAt);
    return map;
  }

  SyncSnapshotRecoveryStagesCompanion toCompanion(bool nullToAbsent) {
    return SyncSnapshotRecoveryStagesCompanion(
      serverNamespace: Value(serverNamespace),
      accountId: Value(accountId),
      instanceId: Value(instanceId),
      serverSpaceId: Value(serverSpaceId),
      vaultId: Value(vaultId),
      serverGeneration: Value(serverGeneration),
      snapshotId: Value(snapshotId),
      highWatermark: Value(highWatermark),
      conflictHighWatermark: Value(conflictHighWatermark),
      checkpointCursor: Value(checkpointCursor),
      expiresAt: Value(expiresAt),
      nextPageCursor: nextPageCursor == null && nullToAbsent
          ? const Value.absent()
          : Value(nextPageCursor),
      lastRecordId: lastRecordId == null && nullToAbsent
          ? const Value.absent()
          : Value(lastRecordId),
      expectedItemCount: expectedItemCount == null && nullToAbsent
          ? const Value.absent()
          : Value(expectedItemCount),
      itemCountObserved: Value(itemCountObserved),
      itemCountPresent: Value(itemCountPresent),
      verifiedItemCount: Value(verifiedItemCount),
      serializedManifestBytes: Value(serializedManifestBytes),
      pageCount: Value(pageCount),
      legacyFullManifest: legacyFullManifest == null && nullToAbsent
          ? const Value.absent()
          : Value(legacyFullManifest),
      complete: Value(complete),
      createdAt: Value(createdAt),
    );
  }

  factory SyncSnapshotRecoveryStage.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncSnapshotRecoveryStage(
      serverNamespace: serializer.fromJson<String>(json['serverNamespace']),
      accountId: serializer.fromJson<String>(json['accountId']),
      instanceId: serializer.fromJson<String>(json['instanceId']),
      serverSpaceId: serializer.fromJson<String>(json['serverSpaceId']),
      vaultId: serializer.fromJson<String>(json['vaultId']),
      serverGeneration: serializer.fromJson<String>(json['serverGeneration']),
      snapshotId: serializer.fromJson<String>(json['snapshotId']),
      highWatermark: serializer.fromJson<String>(json['highWatermark']),
      conflictHighWatermark: serializer.fromJson<String>(
        json['conflictHighWatermark'],
      ),
      checkpointCursor: serializer.fromJson<String>(json['checkpointCursor']),
      expiresAt: serializer.fromJson<String>(json['expiresAt']),
      nextPageCursor: serializer.fromJson<String?>(json['nextPageCursor']),
      lastRecordId: serializer.fromJson<String?>(json['lastRecordId']),
      expectedItemCount: serializer.fromJson<int?>(json['expectedItemCount']),
      itemCountObserved: serializer.fromJson<bool>(json['itemCountObserved']),
      itemCountPresent: serializer.fromJson<bool>(json['itemCountPresent']),
      verifiedItemCount: serializer.fromJson<int>(json['verifiedItemCount']),
      serializedManifestBytes: serializer.fromJson<int>(
        json['serializedManifestBytes'],
      ),
      pageCount: serializer.fromJson<int>(json['pageCount']),
      legacyFullManifest: serializer.fromJson<bool?>(
        json['legacyFullManifest'],
      ),
      complete: serializer.fromJson<bool>(json['complete']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'serverNamespace': serializer.toJson<String>(serverNamespace),
      'accountId': serializer.toJson<String>(accountId),
      'instanceId': serializer.toJson<String>(instanceId),
      'serverSpaceId': serializer.toJson<String>(serverSpaceId),
      'vaultId': serializer.toJson<String>(vaultId),
      'serverGeneration': serializer.toJson<String>(serverGeneration),
      'snapshotId': serializer.toJson<String>(snapshotId),
      'highWatermark': serializer.toJson<String>(highWatermark),
      'conflictHighWatermark': serializer.toJson<String>(conflictHighWatermark),
      'checkpointCursor': serializer.toJson<String>(checkpointCursor),
      'expiresAt': serializer.toJson<String>(expiresAt),
      'nextPageCursor': serializer.toJson<String?>(nextPageCursor),
      'lastRecordId': serializer.toJson<String?>(lastRecordId),
      'expectedItemCount': serializer.toJson<int?>(expectedItemCount),
      'itemCountObserved': serializer.toJson<bool>(itemCountObserved),
      'itemCountPresent': serializer.toJson<bool>(itemCountPresent),
      'verifiedItemCount': serializer.toJson<int>(verifiedItemCount),
      'serializedManifestBytes': serializer.toJson<int>(
        serializedManifestBytes,
      ),
      'pageCount': serializer.toJson<int>(pageCount),
      'legacyFullManifest': serializer.toJson<bool?>(legacyFullManifest),
      'complete': serializer.toJson<bool>(complete),
      'createdAt': serializer.toJson<int>(createdAt),
    };
  }

  SyncSnapshotRecoveryStage copyWith({
    String? serverNamespace,
    String? accountId,
    String? instanceId,
    String? serverSpaceId,
    String? vaultId,
    String? serverGeneration,
    String? snapshotId,
    String? highWatermark,
    String? conflictHighWatermark,
    String? checkpointCursor,
    String? expiresAt,
    Value<String?> nextPageCursor = const Value.absent(),
    Value<String?> lastRecordId = const Value.absent(),
    Value<int?> expectedItemCount = const Value.absent(),
    bool? itemCountObserved,
    bool? itemCountPresent,
    int? verifiedItemCount,
    int? serializedManifestBytes,
    int? pageCount,
    Value<bool?> legacyFullManifest = const Value.absent(),
    bool? complete,
    int? createdAt,
  }) => SyncSnapshotRecoveryStage(
    serverNamespace: serverNamespace ?? this.serverNamespace,
    accountId: accountId ?? this.accountId,
    instanceId: instanceId ?? this.instanceId,
    serverSpaceId: serverSpaceId ?? this.serverSpaceId,
    vaultId: vaultId ?? this.vaultId,
    serverGeneration: serverGeneration ?? this.serverGeneration,
    snapshotId: snapshotId ?? this.snapshotId,
    highWatermark: highWatermark ?? this.highWatermark,
    conflictHighWatermark: conflictHighWatermark ?? this.conflictHighWatermark,
    checkpointCursor: checkpointCursor ?? this.checkpointCursor,
    expiresAt: expiresAt ?? this.expiresAt,
    nextPageCursor: nextPageCursor.present
        ? nextPageCursor.value
        : this.nextPageCursor,
    lastRecordId: lastRecordId.present ? lastRecordId.value : this.lastRecordId,
    expectedItemCount: expectedItemCount.present
        ? expectedItemCount.value
        : this.expectedItemCount,
    itemCountObserved: itemCountObserved ?? this.itemCountObserved,
    itemCountPresent: itemCountPresent ?? this.itemCountPresent,
    verifiedItemCount: verifiedItemCount ?? this.verifiedItemCount,
    serializedManifestBytes:
        serializedManifestBytes ?? this.serializedManifestBytes,
    pageCount: pageCount ?? this.pageCount,
    legacyFullManifest: legacyFullManifest.present
        ? legacyFullManifest.value
        : this.legacyFullManifest,
    complete: complete ?? this.complete,
    createdAt: createdAt ?? this.createdAt,
  );
  SyncSnapshotRecoveryStage copyWithCompanion(
    SyncSnapshotRecoveryStagesCompanion data,
  ) {
    return SyncSnapshotRecoveryStage(
      serverNamespace: data.serverNamespace.present
          ? data.serverNamespace.value
          : this.serverNamespace,
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      instanceId: data.instanceId.present
          ? data.instanceId.value
          : this.instanceId,
      serverSpaceId: data.serverSpaceId.present
          ? data.serverSpaceId.value
          : this.serverSpaceId,
      vaultId: data.vaultId.present ? data.vaultId.value : this.vaultId,
      serverGeneration: data.serverGeneration.present
          ? data.serverGeneration.value
          : this.serverGeneration,
      snapshotId: data.snapshotId.present
          ? data.snapshotId.value
          : this.snapshotId,
      highWatermark: data.highWatermark.present
          ? data.highWatermark.value
          : this.highWatermark,
      conflictHighWatermark: data.conflictHighWatermark.present
          ? data.conflictHighWatermark.value
          : this.conflictHighWatermark,
      checkpointCursor: data.checkpointCursor.present
          ? data.checkpointCursor.value
          : this.checkpointCursor,
      expiresAt: data.expiresAt.present ? data.expiresAt.value : this.expiresAt,
      nextPageCursor: data.nextPageCursor.present
          ? data.nextPageCursor.value
          : this.nextPageCursor,
      lastRecordId: data.lastRecordId.present
          ? data.lastRecordId.value
          : this.lastRecordId,
      expectedItemCount: data.expectedItemCount.present
          ? data.expectedItemCount.value
          : this.expectedItemCount,
      itemCountObserved: data.itemCountObserved.present
          ? data.itemCountObserved.value
          : this.itemCountObserved,
      itemCountPresent: data.itemCountPresent.present
          ? data.itemCountPresent.value
          : this.itemCountPresent,
      verifiedItemCount: data.verifiedItemCount.present
          ? data.verifiedItemCount.value
          : this.verifiedItemCount,
      serializedManifestBytes: data.serializedManifestBytes.present
          ? data.serializedManifestBytes.value
          : this.serializedManifestBytes,
      pageCount: data.pageCount.present ? data.pageCount.value : this.pageCount,
      legacyFullManifest: data.legacyFullManifest.present
          ? data.legacyFullManifest.value
          : this.legacyFullManifest,
      complete: data.complete.present ? data.complete.value : this.complete,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncSnapshotRecoveryStage(')
          ..write('serverNamespace: $serverNamespace, ')
          ..write('accountId: $accountId, ')
          ..write('instanceId: $instanceId, ')
          ..write('serverSpaceId: $serverSpaceId, ')
          ..write('vaultId: $vaultId, ')
          ..write('serverGeneration: $serverGeneration, ')
          ..write('snapshotId: $snapshotId, ')
          ..write('highWatermark: $highWatermark, ')
          ..write('conflictHighWatermark: $conflictHighWatermark, ')
          ..write('checkpointCursor: $checkpointCursor, ')
          ..write('expiresAt: $expiresAt, ')
          ..write('nextPageCursor: $nextPageCursor, ')
          ..write('lastRecordId: $lastRecordId, ')
          ..write('expectedItemCount: $expectedItemCount, ')
          ..write('itemCountObserved: $itemCountObserved, ')
          ..write('itemCountPresent: $itemCountPresent, ')
          ..write('verifiedItemCount: $verifiedItemCount, ')
          ..write('serializedManifestBytes: $serializedManifestBytes, ')
          ..write('pageCount: $pageCount, ')
          ..write('legacyFullManifest: $legacyFullManifest, ')
          ..write('complete: $complete, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
    serverNamespace,
    accountId,
    instanceId,
    serverSpaceId,
    vaultId,
    serverGeneration,
    snapshotId,
    highWatermark,
    conflictHighWatermark,
    checkpointCursor,
    expiresAt,
    nextPageCursor,
    lastRecordId,
    expectedItemCount,
    itemCountObserved,
    itemCountPresent,
    verifiedItemCount,
    serializedManifestBytes,
    pageCount,
    legacyFullManifest,
    complete,
    createdAt,
  ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncSnapshotRecoveryStage &&
          other.serverNamespace == this.serverNamespace &&
          other.accountId == this.accountId &&
          other.instanceId == this.instanceId &&
          other.serverSpaceId == this.serverSpaceId &&
          other.vaultId == this.vaultId &&
          other.serverGeneration == this.serverGeneration &&
          other.snapshotId == this.snapshotId &&
          other.highWatermark == this.highWatermark &&
          other.conflictHighWatermark == this.conflictHighWatermark &&
          other.checkpointCursor == this.checkpointCursor &&
          other.expiresAt == this.expiresAt &&
          other.nextPageCursor == this.nextPageCursor &&
          other.lastRecordId == this.lastRecordId &&
          other.expectedItemCount == this.expectedItemCount &&
          other.itemCountObserved == this.itemCountObserved &&
          other.itemCountPresent == this.itemCountPresent &&
          other.verifiedItemCount == this.verifiedItemCount &&
          other.serializedManifestBytes == this.serializedManifestBytes &&
          other.pageCount == this.pageCount &&
          other.legacyFullManifest == this.legacyFullManifest &&
          other.complete == this.complete &&
          other.createdAt == this.createdAt);
}

class SyncSnapshotRecoveryStagesCompanion
    extends UpdateCompanion<SyncSnapshotRecoveryStage> {
  final Value<String> serverNamespace;
  final Value<String> accountId;
  final Value<String> instanceId;
  final Value<String> serverSpaceId;
  final Value<String> vaultId;
  final Value<String> serverGeneration;
  final Value<String> snapshotId;
  final Value<String> highWatermark;
  final Value<String> conflictHighWatermark;
  final Value<String> checkpointCursor;
  final Value<String> expiresAt;
  final Value<String?> nextPageCursor;
  final Value<String?> lastRecordId;
  final Value<int?> expectedItemCount;
  final Value<bool> itemCountObserved;
  final Value<bool> itemCountPresent;
  final Value<int> verifiedItemCount;
  final Value<int> serializedManifestBytes;
  final Value<int> pageCount;
  final Value<bool?> legacyFullManifest;
  final Value<bool> complete;
  final Value<int> createdAt;
  final Value<int> rowid;
  const SyncSnapshotRecoveryStagesCompanion({
    this.serverNamespace = const Value.absent(),
    this.accountId = const Value.absent(),
    this.instanceId = const Value.absent(),
    this.serverSpaceId = const Value.absent(),
    this.vaultId = const Value.absent(),
    this.serverGeneration = const Value.absent(),
    this.snapshotId = const Value.absent(),
    this.highWatermark = const Value.absent(),
    this.conflictHighWatermark = const Value.absent(),
    this.checkpointCursor = const Value.absent(),
    this.expiresAt = const Value.absent(),
    this.nextPageCursor = const Value.absent(),
    this.lastRecordId = const Value.absent(),
    this.expectedItemCount = const Value.absent(),
    this.itemCountObserved = const Value.absent(),
    this.itemCountPresent = const Value.absent(),
    this.verifiedItemCount = const Value.absent(),
    this.serializedManifestBytes = const Value.absent(),
    this.pageCount = const Value.absent(),
    this.legacyFullManifest = const Value.absent(),
    this.complete = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SyncSnapshotRecoveryStagesCompanion.insert({
    required String serverNamespace,
    required String accountId,
    required String instanceId,
    required String serverSpaceId,
    required String vaultId,
    required String serverGeneration,
    required String snapshotId,
    required String highWatermark,
    required String conflictHighWatermark,
    required String checkpointCursor,
    required String expiresAt,
    this.nextPageCursor = const Value.absent(),
    this.lastRecordId = const Value.absent(),
    this.expectedItemCount = const Value.absent(),
    this.itemCountObserved = const Value.absent(),
    this.itemCountPresent = const Value.absent(),
    this.verifiedItemCount = const Value.absent(),
    this.serializedManifestBytes = const Value.absent(),
    this.pageCount = const Value.absent(),
    this.legacyFullManifest = const Value.absent(),
    this.complete = const Value.absent(),
    required int createdAt,
    this.rowid = const Value.absent(),
  }) : serverNamespace = Value(serverNamespace),
       accountId = Value(accountId),
       instanceId = Value(instanceId),
       serverSpaceId = Value(serverSpaceId),
       vaultId = Value(vaultId),
       serverGeneration = Value(serverGeneration),
       snapshotId = Value(snapshotId),
       highWatermark = Value(highWatermark),
       conflictHighWatermark = Value(conflictHighWatermark),
       checkpointCursor = Value(checkpointCursor),
       expiresAt = Value(expiresAt),
       createdAt = Value(createdAt);
  static Insertable<SyncSnapshotRecoveryStage> custom({
    Expression<String>? serverNamespace,
    Expression<String>? accountId,
    Expression<String>? instanceId,
    Expression<String>? serverSpaceId,
    Expression<String>? vaultId,
    Expression<String>? serverGeneration,
    Expression<String>? snapshotId,
    Expression<String>? highWatermark,
    Expression<String>? conflictHighWatermark,
    Expression<String>? checkpointCursor,
    Expression<String>? expiresAt,
    Expression<String>? nextPageCursor,
    Expression<String>? lastRecordId,
    Expression<int>? expectedItemCount,
    Expression<bool>? itemCountObserved,
    Expression<bool>? itemCountPresent,
    Expression<int>? verifiedItemCount,
    Expression<int>? serializedManifestBytes,
    Expression<int>? pageCount,
    Expression<bool>? legacyFullManifest,
    Expression<bool>? complete,
    Expression<int>? createdAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (serverNamespace != null) 'server_namespace': serverNamespace,
      if (accountId != null) 'account_id': accountId,
      if (instanceId != null) 'instance_id': instanceId,
      if (serverSpaceId != null) 'server_space_id': serverSpaceId,
      if (vaultId != null) 'vault_id': vaultId,
      if (serverGeneration != null) 'server_generation': serverGeneration,
      if (snapshotId != null) 'snapshot_id': snapshotId,
      if (highWatermark != null) 'high_watermark': highWatermark,
      if (conflictHighWatermark != null)
        'conflict_high_watermark': conflictHighWatermark,
      if (checkpointCursor != null) 'checkpoint_cursor': checkpointCursor,
      if (expiresAt != null) 'expires_at': expiresAt,
      if (nextPageCursor != null) 'next_page_cursor': nextPageCursor,
      if (lastRecordId != null) 'last_record_id': lastRecordId,
      if (expectedItemCount != null) 'expected_item_count': expectedItemCount,
      if (itemCountObserved != null) 'item_count_observed': itemCountObserved,
      if (itemCountPresent != null) 'item_count_present': itemCountPresent,
      if (verifiedItemCount != null) 'verified_item_count': verifiedItemCount,
      if (serializedManifestBytes != null)
        'serialized_manifest_bytes': serializedManifestBytes,
      if (pageCount != null) 'page_count': pageCount,
      if (legacyFullManifest != null)
        'legacy_full_manifest': legacyFullManifest,
      if (complete != null) 'complete': complete,
      if (createdAt != null) 'created_at': createdAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SyncSnapshotRecoveryStagesCompanion copyWith({
    Value<String>? serverNamespace,
    Value<String>? accountId,
    Value<String>? instanceId,
    Value<String>? serverSpaceId,
    Value<String>? vaultId,
    Value<String>? serverGeneration,
    Value<String>? snapshotId,
    Value<String>? highWatermark,
    Value<String>? conflictHighWatermark,
    Value<String>? checkpointCursor,
    Value<String>? expiresAt,
    Value<String?>? nextPageCursor,
    Value<String?>? lastRecordId,
    Value<int?>? expectedItemCount,
    Value<bool>? itemCountObserved,
    Value<bool>? itemCountPresent,
    Value<int>? verifiedItemCount,
    Value<int>? serializedManifestBytes,
    Value<int>? pageCount,
    Value<bool?>? legacyFullManifest,
    Value<bool>? complete,
    Value<int>? createdAt,
    Value<int>? rowid,
  }) {
    return SyncSnapshotRecoveryStagesCompanion(
      serverNamespace: serverNamespace ?? this.serverNamespace,
      accountId: accountId ?? this.accountId,
      instanceId: instanceId ?? this.instanceId,
      serverSpaceId: serverSpaceId ?? this.serverSpaceId,
      vaultId: vaultId ?? this.vaultId,
      serverGeneration: serverGeneration ?? this.serverGeneration,
      snapshotId: snapshotId ?? this.snapshotId,
      highWatermark: highWatermark ?? this.highWatermark,
      conflictHighWatermark:
          conflictHighWatermark ?? this.conflictHighWatermark,
      checkpointCursor: checkpointCursor ?? this.checkpointCursor,
      expiresAt: expiresAt ?? this.expiresAt,
      nextPageCursor: nextPageCursor ?? this.nextPageCursor,
      lastRecordId: lastRecordId ?? this.lastRecordId,
      expectedItemCount: expectedItemCount ?? this.expectedItemCount,
      itemCountObserved: itemCountObserved ?? this.itemCountObserved,
      itemCountPresent: itemCountPresent ?? this.itemCountPresent,
      verifiedItemCount: verifiedItemCount ?? this.verifiedItemCount,
      serializedManifestBytes:
          serializedManifestBytes ?? this.serializedManifestBytes,
      pageCount: pageCount ?? this.pageCount,
      legacyFullManifest: legacyFullManifest ?? this.legacyFullManifest,
      complete: complete ?? this.complete,
      createdAt: createdAt ?? this.createdAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (serverNamespace.present) {
      map['server_namespace'] = Variable<String>(serverNamespace.value);
    }
    if (accountId.present) {
      map['account_id'] = Variable<String>(accountId.value);
    }
    if (instanceId.present) {
      map['instance_id'] = Variable<String>(instanceId.value);
    }
    if (serverSpaceId.present) {
      map['server_space_id'] = Variable<String>(serverSpaceId.value);
    }
    if (vaultId.present) {
      map['vault_id'] = Variable<String>(vaultId.value);
    }
    if (serverGeneration.present) {
      map['server_generation'] = Variable<String>(serverGeneration.value);
    }
    if (snapshotId.present) {
      map['snapshot_id'] = Variable<String>(snapshotId.value);
    }
    if (highWatermark.present) {
      map['high_watermark'] = Variable<String>(highWatermark.value);
    }
    if (conflictHighWatermark.present) {
      map['conflict_high_watermark'] = Variable<String>(
        conflictHighWatermark.value,
      );
    }
    if (checkpointCursor.present) {
      map['checkpoint_cursor'] = Variable<String>(checkpointCursor.value);
    }
    if (expiresAt.present) {
      map['expires_at'] = Variable<String>(expiresAt.value);
    }
    if (nextPageCursor.present) {
      map['next_page_cursor'] = Variable<String>(nextPageCursor.value);
    }
    if (lastRecordId.present) {
      map['last_record_id'] = Variable<String>(lastRecordId.value);
    }
    if (expectedItemCount.present) {
      map['expected_item_count'] = Variable<int>(expectedItemCount.value);
    }
    if (itemCountObserved.present) {
      map['item_count_observed'] = Variable<bool>(itemCountObserved.value);
    }
    if (itemCountPresent.present) {
      map['item_count_present'] = Variable<bool>(itemCountPresent.value);
    }
    if (verifiedItemCount.present) {
      map['verified_item_count'] = Variable<int>(verifiedItemCount.value);
    }
    if (serializedManifestBytes.present) {
      map['serialized_manifest_bytes'] = Variable<int>(
        serializedManifestBytes.value,
      );
    }
    if (pageCount.present) {
      map['page_count'] = Variable<int>(pageCount.value);
    }
    if (legacyFullManifest.present) {
      map['legacy_full_manifest'] = Variable<bool>(legacyFullManifest.value);
    }
    if (complete.present) {
      map['complete'] = Variable<bool>(complete.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncSnapshotRecoveryStagesCompanion(')
          ..write('serverNamespace: $serverNamespace, ')
          ..write('accountId: $accountId, ')
          ..write('instanceId: $instanceId, ')
          ..write('serverSpaceId: $serverSpaceId, ')
          ..write('vaultId: $vaultId, ')
          ..write('serverGeneration: $serverGeneration, ')
          ..write('snapshotId: $snapshotId, ')
          ..write('highWatermark: $highWatermark, ')
          ..write('conflictHighWatermark: $conflictHighWatermark, ')
          ..write('checkpointCursor: $checkpointCursor, ')
          ..write('expiresAt: $expiresAt, ')
          ..write('nextPageCursor: $nextPageCursor, ')
          ..write('lastRecordId: $lastRecordId, ')
          ..write('expectedItemCount: $expectedItemCount, ')
          ..write('itemCountObserved: $itemCountObserved, ')
          ..write('itemCountPresent: $itemCountPresent, ')
          ..write('verifiedItemCount: $verifiedItemCount, ')
          ..write('serializedManifestBytes: $serializedManifestBytes, ')
          ..write('pageCount: $pageCount, ')
          ..write('legacyFullManifest: $legacyFullManifest, ')
          ..write('complete: $complete, ')
          ..write('createdAt: $createdAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SyncSnapshotRecoveryItemsTable extends SyncSnapshotRecoveryItems
    with TableInfo<$SyncSnapshotRecoveryItemsTable, SyncSnapshotRecoveryItem> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncSnapshotRecoveryItemsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _serverNamespaceMeta = const VerificationMeta(
    'serverNamespace',
  );
  @override
  late final GeneratedColumn<String> serverNamespace = GeneratedColumn<String>(
    'server_namespace',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<String> accountId = GeneratedColumn<String>(
    'account_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _instanceIdMeta = const VerificationMeta(
    'instanceId',
  );
  @override
  late final GeneratedColumn<String> instanceId = GeneratedColumn<String>(
    'instance_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _serverSpaceIdMeta = const VerificationMeta(
    'serverSpaceId',
  );
  @override
  late final GeneratedColumn<String> serverSpaceId = GeneratedColumn<String>(
    'server_space_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _vaultIdMeta = const VerificationMeta(
    'vaultId',
  );
  @override
  late final GeneratedColumn<String> vaultId = GeneratedColumn<String>(
    'vault_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _serverGenerationMeta = const VerificationMeta(
    'serverGeneration',
  );
  @override
  late final GeneratedColumn<String> serverGeneration = GeneratedColumn<String>(
    'server_generation',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _snapshotIdMeta = const VerificationMeta(
    'snapshotId',
  );
  @override
  late final GeneratedColumn<String> snapshotId = GeneratedColumn<String>(
    'snapshot_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _recordIdMeta = const VerificationMeta(
    'recordId',
  );
  @override
  late final GeneratedColumn<String> recordId = GeneratedColumn<String>(
    'record_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _ordinalMeta = const VerificationMeta(
    'ordinal',
  );
  @override
  late final GeneratedColumn<int> ordinal = GeneratedColumn<int>(
    'ordinal',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _revisionIdMeta = const VerificationMeta(
    'revisionId',
  );
  @override
  late final GeneratedColumn<String> revisionId = GeneratedColumn<String>(
    'revision_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deletedMeta = const VerificationMeta(
    'deleted',
  );
  @override
  late final GeneratedColumn<bool> deleted = GeneratedColumn<bool>(
    'deleted',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("deleted" IN (0, 1))',
    ),
  );
  static const VerificationMeta _envelopeJsonMeta = const VerificationMeta(
    'envelopeJson',
  );
  @override
  late final GeneratedColumn<String> envelopeJson = GeneratedColumn<String>(
    'envelope_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _commitSeqMeta = const VerificationMeta(
    'commitSeq',
  );
  @override
  late final GeneratedColumn<String> commitSeq = GeneratedColumn<String>(
    'commit_seq',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _redactionJsonMeta = const VerificationMeta(
    'redactionJson',
  );
  @override
  late final GeneratedColumn<String> redactionJson = GeneratedColumn<String>(
    'redaction_json',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    serverNamespace,
    accountId,
    instanceId,
    serverSpaceId,
    vaultId,
    serverGeneration,
    snapshotId,
    recordId,
    ordinal,
    revisionId,
    deleted,
    envelopeJson,
    commitSeq,
    redactionJson,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_snapshot_recovery_items';
  @override
  VerificationContext validateIntegrity(
    Insertable<SyncSnapshotRecoveryItem> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('server_namespace')) {
      context.handle(
        _serverNamespaceMeta,
        serverNamespace.isAcceptableOrUnknown(
          data['server_namespace']!,
          _serverNamespaceMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_serverNamespaceMeta);
    }
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    } else if (isInserting) {
      context.missing(_accountIdMeta);
    }
    if (data.containsKey('instance_id')) {
      context.handle(
        _instanceIdMeta,
        instanceId.isAcceptableOrUnknown(data['instance_id']!, _instanceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_instanceIdMeta);
    }
    if (data.containsKey('server_space_id')) {
      context.handle(
        _serverSpaceIdMeta,
        serverSpaceId.isAcceptableOrUnknown(
          data['server_space_id']!,
          _serverSpaceIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_serverSpaceIdMeta);
    }
    if (data.containsKey('vault_id')) {
      context.handle(
        _vaultIdMeta,
        vaultId.isAcceptableOrUnknown(data['vault_id']!, _vaultIdMeta),
      );
    } else if (isInserting) {
      context.missing(_vaultIdMeta);
    }
    if (data.containsKey('server_generation')) {
      context.handle(
        _serverGenerationMeta,
        serverGeneration.isAcceptableOrUnknown(
          data['server_generation']!,
          _serverGenerationMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_serverGenerationMeta);
    }
    if (data.containsKey('snapshot_id')) {
      context.handle(
        _snapshotIdMeta,
        snapshotId.isAcceptableOrUnknown(data['snapshot_id']!, _snapshotIdMeta),
      );
    } else if (isInserting) {
      context.missing(_snapshotIdMeta);
    }
    if (data.containsKey('record_id')) {
      context.handle(
        _recordIdMeta,
        recordId.isAcceptableOrUnknown(data['record_id']!, _recordIdMeta),
      );
    } else if (isInserting) {
      context.missing(_recordIdMeta);
    }
    if (data.containsKey('ordinal')) {
      context.handle(
        _ordinalMeta,
        ordinal.isAcceptableOrUnknown(data['ordinal']!, _ordinalMeta),
      );
    } else if (isInserting) {
      context.missing(_ordinalMeta);
    }
    if (data.containsKey('revision_id')) {
      context.handle(
        _revisionIdMeta,
        revisionId.isAcceptableOrUnknown(data['revision_id']!, _revisionIdMeta),
      );
    } else if (isInserting) {
      context.missing(_revisionIdMeta);
    }
    if (data.containsKey('deleted')) {
      context.handle(
        _deletedMeta,
        deleted.isAcceptableOrUnknown(data['deleted']!, _deletedMeta),
      );
    } else if (isInserting) {
      context.missing(_deletedMeta);
    }
    if (data.containsKey('envelope_json')) {
      context.handle(
        _envelopeJsonMeta,
        envelopeJson.isAcceptableOrUnknown(
          data['envelope_json']!,
          _envelopeJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_envelopeJsonMeta);
    }
    if (data.containsKey('commit_seq')) {
      context.handle(
        _commitSeqMeta,
        commitSeq.isAcceptableOrUnknown(data['commit_seq']!, _commitSeqMeta),
      );
    }
    if (data.containsKey('redaction_json')) {
      context.handle(
        _redactionJsonMeta,
        redactionJson.isAcceptableOrUnknown(
          data['redaction_json']!,
          _redactionJsonMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {
    serverNamespace,
    accountId,
    instanceId,
    serverSpaceId,
    vaultId,
    serverGeneration,
    snapshotId,
    recordId,
  };
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
    {
      serverNamespace,
      accountId,
      instanceId,
      serverSpaceId,
      vaultId,
      serverGeneration,
      snapshotId,
      ordinal,
    },
  ];
  @override
  SyncSnapshotRecoveryItem map(
    Map<String, dynamic> data, {
    String? tablePrefix,
  }) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncSnapshotRecoveryItem(
      serverNamespace: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_namespace'],
      )!,
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}account_id'],
      )!,
      instanceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}instance_id'],
      )!,
      serverSpaceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_space_id'],
      )!,
      vaultId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}vault_id'],
      )!,
      serverGeneration: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_generation'],
      )!,
      snapshotId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}snapshot_id'],
      )!,
      recordId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}record_id'],
      )!,
      ordinal: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}ordinal'],
      )!,
      revisionId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}revision_id'],
      )!,
      deleted: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}deleted'],
      )!,
      envelopeJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}envelope_json'],
      )!,
      commitSeq: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}commit_seq'],
      ),
      redactionJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}redaction_json'],
      ),
    );
  }

  @override
  $SyncSnapshotRecoveryItemsTable createAlias(String alias) {
    return $SyncSnapshotRecoveryItemsTable(attachedDatabase, alias);
  }
}

class SyncSnapshotRecoveryItem extends DataClass
    implements Insertable<SyncSnapshotRecoveryItem> {
  final String serverNamespace;
  final String accountId;
  final String instanceId;
  final String serverSpaceId;
  final String vaultId;
  final String serverGeneration;
  final String snapshotId;
  final String recordId;
  final int ordinal;
  final String revisionId;
  final bool deleted;
  final String envelopeJson;
  final String? commitSeq;
  final String? redactionJson;
  const SyncSnapshotRecoveryItem({
    required this.serverNamespace,
    required this.accountId,
    required this.instanceId,
    required this.serverSpaceId,
    required this.vaultId,
    required this.serverGeneration,
    required this.snapshotId,
    required this.recordId,
    required this.ordinal,
    required this.revisionId,
    required this.deleted,
    required this.envelopeJson,
    this.commitSeq,
    this.redactionJson,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['server_namespace'] = Variable<String>(serverNamespace);
    map['account_id'] = Variable<String>(accountId);
    map['instance_id'] = Variable<String>(instanceId);
    map['server_space_id'] = Variable<String>(serverSpaceId);
    map['vault_id'] = Variable<String>(vaultId);
    map['server_generation'] = Variable<String>(serverGeneration);
    map['snapshot_id'] = Variable<String>(snapshotId);
    map['record_id'] = Variable<String>(recordId);
    map['ordinal'] = Variable<int>(ordinal);
    map['revision_id'] = Variable<String>(revisionId);
    map['deleted'] = Variable<bool>(deleted);
    map['envelope_json'] = Variable<String>(envelopeJson);
    if (!nullToAbsent || commitSeq != null) {
      map['commit_seq'] = Variable<String>(commitSeq);
    }
    if (!nullToAbsent || redactionJson != null) {
      map['redaction_json'] = Variable<String>(redactionJson);
    }
    return map;
  }

  SyncSnapshotRecoveryItemsCompanion toCompanion(bool nullToAbsent) {
    return SyncSnapshotRecoveryItemsCompanion(
      serverNamespace: Value(serverNamespace),
      accountId: Value(accountId),
      instanceId: Value(instanceId),
      serverSpaceId: Value(serverSpaceId),
      vaultId: Value(vaultId),
      serverGeneration: Value(serverGeneration),
      snapshotId: Value(snapshotId),
      recordId: Value(recordId),
      ordinal: Value(ordinal),
      revisionId: Value(revisionId),
      deleted: Value(deleted),
      envelopeJson: Value(envelopeJson),
      commitSeq: commitSeq == null && nullToAbsent
          ? const Value.absent()
          : Value(commitSeq),
      redactionJson: redactionJson == null && nullToAbsent
          ? const Value.absent()
          : Value(redactionJson),
    );
  }

  factory SyncSnapshotRecoveryItem.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncSnapshotRecoveryItem(
      serverNamespace: serializer.fromJson<String>(json['serverNamespace']),
      accountId: serializer.fromJson<String>(json['accountId']),
      instanceId: serializer.fromJson<String>(json['instanceId']),
      serverSpaceId: serializer.fromJson<String>(json['serverSpaceId']),
      vaultId: serializer.fromJson<String>(json['vaultId']),
      serverGeneration: serializer.fromJson<String>(json['serverGeneration']),
      snapshotId: serializer.fromJson<String>(json['snapshotId']),
      recordId: serializer.fromJson<String>(json['recordId']),
      ordinal: serializer.fromJson<int>(json['ordinal']),
      revisionId: serializer.fromJson<String>(json['revisionId']),
      deleted: serializer.fromJson<bool>(json['deleted']),
      envelopeJson: serializer.fromJson<String>(json['envelopeJson']),
      commitSeq: serializer.fromJson<String?>(json['commitSeq']),
      redactionJson: serializer.fromJson<String?>(json['redactionJson']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'serverNamespace': serializer.toJson<String>(serverNamespace),
      'accountId': serializer.toJson<String>(accountId),
      'instanceId': serializer.toJson<String>(instanceId),
      'serverSpaceId': serializer.toJson<String>(serverSpaceId),
      'vaultId': serializer.toJson<String>(vaultId),
      'serverGeneration': serializer.toJson<String>(serverGeneration),
      'snapshotId': serializer.toJson<String>(snapshotId),
      'recordId': serializer.toJson<String>(recordId),
      'ordinal': serializer.toJson<int>(ordinal),
      'revisionId': serializer.toJson<String>(revisionId),
      'deleted': serializer.toJson<bool>(deleted),
      'envelopeJson': serializer.toJson<String>(envelopeJson),
      'commitSeq': serializer.toJson<String?>(commitSeq),
      'redactionJson': serializer.toJson<String?>(redactionJson),
    };
  }

  SyncSnapshotRecoveryItem copyWith({
    String? serverNamespace,
    String? accountId,
    String? instanceId,
    String? serverSpaceId,
    String? vaultId,
    String? serverGeneration,
    String? snapshotId,
    String? recordId,
    int? ordinal,
    String? revisionId,
    bool? deleted,
    String? envelopeJson,
    Value<String?> commitSeq = const Value.absent(),
    Value<String?> redactionJson = const Value.absent(),
  }) => SyncSnapshotRecoveryItem(
    serverNamespace: serverNamespace ?? this.serverNamespace,
    accountId: accountId ?? this.accountId,
    instanceId: instanceId ?? this.instanceId,
    serverSpaceId: serverSpaceId ?? this.serverSpaceId,
    vaultId: vaultId ?? this.vaultId,
    serverGeneration: serverGeneration ?? this.serverGeneration,
    snapshotId: snapshotId ?? this.snapshotId,
    recordId: recordId ?? this.recordId,
    ordinal: ordinal ?? this.ordinal,
    revisionId: revisionId ?? this.revisionId,
    deleted: deleted ?? this.deleted,
    envelopeJson: envelopeJson ?? this.envelopeJson,
    commitSeq: commitSeq.present ? commitSeq.value : this.commitSeq,
    redactionJson: redactionJson.present
        ? redactionJson.value
        : this.redactionJson,
  );
  SyncSnapshotRecoveryItem copyWithCompanion(
    SyncSnapshotRecoveryItemsCompanion data,
  ) {
    return SyncSnapshotRecoveryItem(
      serverNamespace: data.serverNamespace.present
          ? data.serverNamespace.value
          : this.serverNamespace,
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      instanceId: data.instanceId.present
          ? data.instanceId.value
          : this.instanceId,
      serverSpaceId: data.serverSpaceId.present
          ? data.serverSpaceId.value
          : this.serverSpaceId,
      vaultId: data.vaultId.present ? data.vaultId.value : this.vaultId,
      serverGeneration: data.serverGeneration.present
          ? data.serverGeneration.value
          : this.serverGeneration,
      snapshotId: data.snapshotId.present
          ? data.snapshotId.value
          : this.snapshotId,
      recordId: data.recordId.present ? data.recordId.value : this.recordId,
      ordinal: data.ordinal.present ? data.ordinal.value : this.ordinal,
      revisionId: data.revisionId.present
          ? data.revisionId.value
          : this.revisionId,
      deleted: data.deleted.present ? data.deleted.value : this.deleted,
      envelopeJson: data.envelopeJson.present
          ? data.envelopeJson.value
          : this.envelopeJson,
      commitSeq: data.commitSeq.present ? data.commitSeq.value : this.commitSeq,
      redactionJson: data.redactionJson.present
          ? data.redactionJson.value
          : this.redactionJson,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncSnapshotRecoveryItem(')
          ..write('serverNamespace: $serverNamespace, ')
          ..write('accountId: $accountId, ')
          ..write('instanceId: $instanceId, ')
          ..write('serverSpaceId: $serverSpaceId, ')
          ..write('vaultId: $vaultId, ')
          ..write('serverGeneration: $serverGeneration, ')
          ..write('snapshotId: $snapshotId, ')
          ..write('recordId: $recordId, ')
          ..write('ordinal: $ordinal, ')
          ..write('revisionId: $revisionId, ')
          ..write('deleted: $deleted, ')
          ..write('envelopeJson: $envelopeJson, ')
          ..write('commitSeq: $commitSeq, ')
          ..write('redactionJson: $redactionJson')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    serverNamespace,
    accountId,
    instanceId,
    serverSpaceId,
    vaultId,
    serverGeneration,
    snapshotId,
    recordId,
    ordinal,
    revisionId,
    deleted,
    envelopeJson,
    commitSeq,
    redactionJson,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncSnapshotRecoveryItem &&
          other.serverNamespace == this.serverNamespace &&
          other.accountId == this.accountId &&
          other.instanceId == this.instanceId &&
          other.serverSpaceId == this.serverSpaceId &&
          other.vaultId == this.vaultId &&
          other.serverGeneration == this.serverGeneration &&
          other.snapshotId == this.snapshotId &&
          other.recordId == this.recordId &&
          other.ordinal == this.ordinal &&
          other.revisionId == this.revisionId &&
          other.deleted == this.deleted &&
          other.envelopeJson == this.envelopeJson &&
          other.commitSeq == this.commitSeq &&
          other.redactionJson == this.redactionJson);
}

class SyncSnapshotRecoveryItemsCompanion
    extends UpdateCompanion<SyncSnapshotRecoveryItem> {
  final Value<String> serverNamespace;
  final Value<String> accountId;
  final Value<String> instanceId;
  final Value<String> serverSpaceId;
  final Value<String> vaultId;
  final Value<String> serverGeneration;
  final Value<String> snapshotId;
  final Value<String> recordId;
  final Value<int> ordinal;
  final Value<String> revisionId;
  final Value<bool> deleted;
  final Value<String> envelopeJson;
  final Value<String?> commitSeq;
  final Value<String?> redactionJson;
  final Value<int> rowid;
  const SyncSnapshotRecoveryItemsCompanion({
    this.serverNamespace = const Value.absent(),
    this.accountId = const Value.absent(),
    this.instanceId = const Value.absent(),
    this.serverSpaceId = const Value.absent(),
    this.vaultId = const Value.absent(),
    this.serverGeneration = const Value.absent(),
    this.snapshotId = const Value.absent(),
    this.recordId = const Value.absent(),
    this.ordinal = const Value.absent(),
    this.revisionId = const Value.absent(),
    this.deleted = const Value.absent(),
    this.envelopeJson = const Value.absent(),
    this.commitSeq = const Value.absent(),
    this.redactionJson = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SyncSnapshotRecoveryItemsCompanion.insert({
    required String serverNamespace,
    required String accountId,
    required String instanceId,
    required String serverSpaceId,
    required String vaultId,
    required String serverGeneration,
    required String snapshotId,
    required String recordId,
    required int ordinal,
    required String revisionId,
    required bool deleted,
    required String envelopeJson,
    this.commitSeq = const Value.absent(),
    this.redactionJson = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : serverNamespace = Value(serverNamespace),
       accountId = Value(accountId),
       instanceId = Value(instanceId),
       serverSpaceId = Value(serverSpaceId),
       vaultId = Value(vaultId),
       serverGeneration = Value(serverGeneration),
       snapshotId = Value(snapshotId),
       recordId = Value(recordId),
       ordinal = Value(ordinal),
       revisionId = Value(revisionId),
       deleted = Value(deleted),
       envelopeJson = Value(envelopeJson);
  static Insertable<SyncSnapshotRecoveryItem> custom({
    Expression<String>? serverNamespace,
    Expression<String>? accountId,
    Expression<String>? instanceId,
    Expression<String>? serverSpaceId,
    Expression<String>? vaultId,
    Expression<String>? serverGeneration,
    Expression<String>? snapshotId,
    Expression<String>? recordId,
    Expression<int>? ordinal,
    Expression<String>? revisionId,
    Expression<bool>? deleted,
    Expression<String>? envelopeJson,
    Expression<String>? commitSeq,
    Expression<String>? redactionJson,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (serverNamespace != null) 'server_namespace': serverNamespace,
      if (accountId != null) 'account_id': accountId,
      if (instanceId != null) 'instance_id': instanceId,
      if (serverSpaceId != null) 'server_space_id': serverSpaceId,
      if (vaultId != null) 'vault_id': vaultId,
      if (serverGeneration != null) 'server_generation': serverGeneration,
      if (snapshotId != null) 'snapshot_id': snapshotId,
      if (recordId != null) 'record_id': recordId,
      if (ordinal != null) 'ordinal': ordinal,
      if (revisionId != null) 'revision_id': revisionId,
      if (deleted != null) 'deleted': deleted,
      if (envelopeJson != null) 'envelope_json': envelopeJson,
      if (commitSeq != null) 'commit_seq': commitSeq,
      if (redactionJson != null) 'redaction_json': redactionJson,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SyncSnapshotRecoveryItemsCompanion copyWith({
    Value<String>? serverNamespace,
    Value<String>? accountId,
    Value<String>? instanceId,
    Value<String>? serverSpaceId,
    Value<String>? vaultId,
    Value<String>? serverGeneration,
    Value<String>? snapshotId,
    Value<String>? recordId,
    Value<int>? ordinal,
    Value<String>? revisionId,
    Value<bool>? deleted,
    Value<String>? envelopeJson,
    Value<String?>? commitSeq,
    Value<String?>? redactionJson,
    Value<int>? rowid,
  }) {
    return SyncSnapshotRecoveryItemsCompanion(
      serverNamespace: serverNamespace ?? this.serverNamespace,
      accountId: accountId ?? this.accountId,
      instanceId: instanceId ?? this.instanceId,
      serverSpaceId: serverSpaceId ?? this.serverSpaceId,
      vaultId: vaultId ?? this.vaultId,
      serverGeneration: serverGeneration ?? this.serverGeneration,
      snapshotId: snapshotId ?? this.snapshotId,
      recordId: recordId ?? this.recordId,
      ordinal: ordinal ?? this.ordinal,
      revisionId: revisionId ?? this.revisionId,
      deleted: deleted ?? this.deleted,
      envelopeJson: envelopeJson ?? this.envelopeJson,
      commitSeq: commitSeq ?? this.commitSeq,
      redactionJson: redactionJson ?? this.redactionJson,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (serverNamespace.present) {
      map['server_namespace'] = Variable<String>(serverNamespace.value);
    }
    if (accountId.present) {
      map['account_id'] = Variable<String>(accountId.value);
    }
    if (instanceId.present) {
      map['instance_id'] = Variable<String>(instanceId.value);
    }
    if (serverSpaceId.present) {
      map['server_space_id'] = Variable<String>(serverSpaceId.value);
    }
    if (vaultId.present) {
      map['vault_id'] = Variable<String>(vaultId.value);
    }
    if (serverGeneration.present) {
      map['server_generation'] = Variable<String>(serverGeneration.value);
    }
    if (snapshotId.present) {
      map['snapshot_id'] = Variable<String>(snapshotId.value);
    }
    if (recordId.present) {
      map['record_id'] = Variable<String>(recordId.value);
    }
    if (ordinal.present) {
      map['ordinal'] = Variable<int>(ordinal.value);
    }
    if (revisionId.present) {
      map['revision_id'] = Variable<String>(revisionId.value);
    }
    if (deleted.present) {
      map['deleted'] = Variable<bool>(deleted.value);
    }
    if (envelopeJson.present) {
      map['envelope_json'] = Variable<String>(envelopeJson.value);
    }
    if (commitSeq.present) {
      map['commit_seq'] = Variable<String>(commitSeq.value);
    }
    if (redactionJson.present) {
      map['redaction_json'] = Variable<String>(redactionJson.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncSnapshotRecoveryItemsCompanion(')
          ..write('serverNamespace: $serverNamespace, ')
          ..write('accountId: $accountId, ')
          ..write('instanceId: $instanceId, ')
          ..write('serverSpaceId: $serverSpaceId, ')
          ..write('vaultId: $vaultId, ')
          ..write('serverGeneration: $serverGeneration, ')
          ..write('snapshotId: $snapshotId, ')
          ..write('recordId: $recordId, ')
          ..write('ordinal: $ordinal, ')
          ..write('revisionId: $revisionId, ')
          ..write('deleted: $deleted, ')
          ..write('envelopeJson: $envelopeJson, ')
          ..write('commitSeq: $commitSeq, ')
          ..write('redactionJson: $redactionJson, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SyncRedactionsTable extends SyncRedactions
    with TableInfo<$SyncRedactionsTable, SyncRedaction> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncRedactionsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _instanceIdMeta = const VerificationMeta(
    'instanceId',
  );
  @override
  late final GeneratedColumn<String> instanceId = GeneratedColumn<String>(
    'instance_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _serverSpaceIdMeta = const VerificationMeta(
    'serverSpaceId',
  );
  @override
  late final GeneratedColumn<String> serverSpaceId = GeneratedColumn<String>(
    'server_space_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _vaultIdMeta = const VerificationMeta(
    'vaultId',
  );
  @override
  late final GeneratedColumn<String> vaultId = GeneratedColumn<String>(
    'vault_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _recordIdMeta = const VerificationMeta(
    'recordId',
  );
  @override
  late final GeneratedColumn<String> recordId = GeneratedColumn<String>(
    'record_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _redactionIdMeta = const VerificationMeta(
    'redactionId',
  );
  @override
  late final GeneratedColumn<String> redactionId = GeneratedColumn<String>(
    'redaction_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deletedRevisionIdMeta = const VerificationMeta(
    'deletedRevisionId',
  );
  @override
  late final GeneratedColumn<String> deletedRevisionId =
      GeneratedColumn<String>(
        'deleted_revision_id',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: true,
      );
  static const VerificationMeta _deletedSeqMeta = const VerificationMeta(
    'deletedSeq',
  );
  @override
  late final GeneratedColumn<String> deletedSeq = GeneratedColumn<String>(
    'deleted_seq',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _redactionSeqMeta = const VerificationMeta(
    'redactionSeq',
  );
  @override
  late final GeneratedColumn<String> redactionSeq = GeneratedColumn<String>(
    'redaction_seq',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _proofJsonMeta = const VerificationMeta(
    'proofJson',
  );
  @override
  late final GeneratedColumn<String> proofJson = GeneratedColumn<String>(
    'proof_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _serverGenerationMeta = const VerificationMeta(
    'serverGeneration',
  );
  @override
  late final GeneratedColumn<String> serverGeneration = GeneratedColumn<String>(
    'server_generation',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _appliedAtMeta = const VerificationMeta(
    'appliedAt',
  );
  @override
  late final GeneratedColumn<int> appliedAt = GeneratedColumn<int>(
    'applied_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    instanceId,
    serverSpaceId,
    vaultId,
    recordId,
    redactionId,
    deletedRevisionId,
    deletedSeq,
    redactionSeq,
    proofJson,
    serverGeneration,
    appliedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_redactions';
  @override
  VerificationContext validateIntegrity(
    Insertable<SyncRedaction> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('instance_id')) {
      context.handle(
        _instanceIdMeta,
        instanceId.isAcceptableOrUnknown(data['instance_id']!, _instanceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_instanceIdMeta);
    }
    if (data.containsKey('server_space_id')) {
      context.handle(
        _serverSpaceIdMeta,
        serverSpaceId.isAcceptableOrUnknown(
          data['server_space_id']!,
          _serverSpaceIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_serverSpaceIdMeta);
    }
    if (data.containsKey('vault_id')) {
      context.handle(
        _vaultIdMeta,
        vaultId.isAcceptableOrUnknown(data['vault_id']!, _vaultIdMeta),
      );
    } else if (isInserting) {
      context.missing(_vaultIdMeta);
    }
    if (data.containsKey('record_id')) {
      context.handle(
        _recordIdMeta,
        recordId.isAcceptableOrUnknown(data['record_id']!, _recordIdMeta),
      );
    } else if (isInserting) {
      context.missing(_recordIdMeta);
    }
    if (data.containsKey('redaction_id')) {
      context.handle(
        _redactionIdMeta,
        redactionId.isAcceptableOrUnknown(
          data['redaction_id']!,
          _redactionIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_redactionIdMeta);
    }
    if (data.containsKey('deleted_revision_id')) {
      context.handle(
        _deletedRevisionIdMeta,
        deletedRevisionId.isAcceptableOrUnknown(
          data['deleted_revision_id']!,
          _deletedRevisionIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_deletedRevisionIdMeta);
    }
    if (data.containsKey('deleted_seq')) {
      context.handle(
        _deletedSeqMeta,
        deletedSeq.isAcceptableOrUnknown(data['deleted_seq']!, _deletedSeqMeta),
      );
    } else if (isInserting) {
      context.missing(_deletedSeqMeta);
    }
    if (data.containsKey('redaction_seq')) {
      context.handle(
        _redactionSeqMeta,
        redactionSeq.isAcceptableOrUnknown(
          data['redaction_seq']!,
          _redactionSeqMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_redactionSeqMeta);
    }
    if (data.containsKey('proof_json')) {
      context.handle(
        _proofJsonMeta,
        proofJson.isAcceptableOrUnknown(data['proof_json']!, _proofJsonMeta),
      );
    } else if (isInserting) {
      context.missing(_proofJsonMeta);
    }
    if (data.containsKey('server_generation')) {
      context.handle(
        _serverGenerationMeta,
        serverGeneration.isAcceptableOrUnknown(
          data['server_generation']!,
          _serverGenerationMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_serverGenerationMeta);
    }
    if (data.containsKey('applied_at')) {
      context.handle(
        _appliedAtMeta,
        appliedAt.isAcceptableOrUnknown(data['applied_at']!, _appliedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_appliedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {
    instanceId,
    serverSpaceId,
    vaultId,
    recordId,
  };
  @override
  SyncRedaction map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncRedaction(
      instanceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}instance_id'],
      )!,
      serverSpaceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_space_id'],
      )!,
      vaultId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}vault_id'],
      )!,
      recordId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}record_id'],
      )!,
      redactionId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}redaction_id'],
      )!,
      deletedRevisionId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}deleted_revision_id'],
      )!,
      deletedSeq: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}deleted_seq'],
      )!,
      redactionSeq: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}redaction_seq'],
      )!,
      proofJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}proof_json'],
      )!,
      serverGeneration: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_generation'],
      )!,
      appliedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}applied_at'],
      )!,
    );
  }

  @override
  $SyncRedactionsTable createAlias(String alias) {
    return $SyncRedactionsTable(attachedDatabase, alias);
  }
}

class SyncRedaction extends DataClass implements Insertable<SyncRedaction> {
  final String instanceId;
  final String serverSpaceId;
  final String vaultId;
  final String recordId;
  final String redactionId;
  final String deletedRevisionId;
  final String deletedSeq;
  final String redactionSeq;
  final String proofJson;
  final String serverGeneration;
  final int appliedAt;
  const SyncRedaction({
    required this.instanceId,
    required this.serverSpaceId,
    required this.vaultId,
    required this.recordId,
    required this.redactionId,
    required this.deletedRevisionId,
    required this.deletedSeq,
    required this.redactionSeq,
    required this.proofJson,
    required this.serverGeneration,
    required this.appliedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['instance_id'] = Variable<String>(instanceId);
    map['server_space_id'] = Variable<String>(serverSpaceId);
    map['vault_id'] = Variable<String>(vaultId);
    map['record_id'] = Variable<String>(recordId);
    map['redaction_id'] = Variable<String>(redactionId);
    map['deleted_revision_id'] = Variable<String>(deletedRevisionId);
    map['deleted_seq'] = Variable<String>(deletedSeq);
    map['redaction_seq'] = Variable<String>(redactionSeq);
    map['proof_json'] = Variable<String>(proofJson);
    map['server_generation'] = Variable<String>(serverGeneration);
    map['applied_at'] = Variable<int>(appliedAt);
    return map;
  }

  SyncRedactionsCompanion toCompanion(bool nullToAbsent) {
    return SyncRedactionsCompanion(
      instanceId: Value(instanceId),
      serverSpaceId: Value(serverSpaceId),
      vaultId: Value(vaultId),
      recordId: Value(recordId),
      redactionId: Value(redactionId),
      deletedRevisionId: Value(deletedRevisionId),
      deletedSeq: Value(deletedSeq),
      redactionSeq: Value(redactionSeq),
      proofJson: Value(proofJson),
      serverGeneration: Value(serverGeneration),
      appliedAt: Value(appliedAt),
    );
  }

  factory SyncRedaction.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncRedaction(
      instanceId: serializer.fromJson<String>(json['instanceId']),
      serverSpaceId: serializer.fromJson<String>(json['serverSpaceId']),
      vaultId: serializer.fromJson<String>(json['vaultId']),
      recordId: serializer.fromJson<String>(json['recordId']),
      redactionId: serializer.fromJson<String>(json['redactionId']),
      deletedRevisionId: serializer.fromJson<String>(json['deletedRevisionId']),
      deletedSeq: serializer.fromJson<String>(json['deletedSeq']),
      redactionSeq: serializer.fromJson<String>(json['redactionSeq']),
      proofJson: serializer.fromJson<String>(json['proofJson']),
      serverGeneration: serializer.fromJson<String>(json['serverGeneration']),
      appliedAt: serializer.fromJson<int>(json['appliedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'instanceId': serializer.toJson<String>(instanceId),
      'serverSpaceId': serializer.toJson<String>(serverSpaceId),
      'vaultId': serializer.toJson<String>(vaultId),
      'recordId': serializer.toJson<String>(recordId),
      'redactionId': serializer.toJson<String>(redactionId),
      'deletedRevisionId': serializer.toJson<String>(deletedRevisionId),
      'deletedSeq': serializer.toJson<String>(deletedSeq),
      'redactionSeq': serializer.toJson<String>(redactionSeq),
      'proofJson': serializer.toJson<String>(proofJson),
      'serverGeneration': serializer.toJson<String>(serverGeneration),
      'appliedAt': serializer.toJson<int>(appliedAt),
    };
  }

  SyncRedaction copyWith({
    String? instanceId,
    String? serverSpaceId,
    String? vaultId,
    String? recordId,
    String? redactionId,
    String? deletedRevisionId,
    String? deletedSeq,
    String? redactionSeq,
    String? proofJson,
    String? serverGeneration,
    int? appliedAt,
  }) => SyncRedaction(
    instanceId: instanceId ?? this.instanceId,
    serverSpaceId: serverSpaceId ?? this.serverSpaceId,
    vaultId: vaultId ?? this.vaultId,
    recordId: recordId ?? this.recordId,
    redactionId: redactionId ?? this.redactionId,
    deletedRevisionId: deletedRevisionId ?? this.deletedRevisionId,
    deletedSeq: deletedSeq ?? this.deletedSeq,
    redactionSeq: redactionSeq ?? this.redactionSeq,
    proofJson: proofJson ?? this.proofJson,
    serverGeneration: serverGeneration ?? this.serverGeneration,
    appliedAt: appliedAt ?? this.appliedAt,
  );
  SyncRedaction copyWithCompanion(SyncRedactionsCompanion data) {
    return SyncRedaction(
      instanceId: data.instanceId.present
          ? data.instanceId.value
          : this.instanceId,
      serverSpaceId: data.serverSpaceId.present
          ? data.serverSpaceId.value
          : this.serverSpaceId,
      vaultId: data.vaultId.present ? data.vaultId.value : this.vaultId,
      recordId: data.recordId.present ? data.recordId.value : this.recordId,
      redactionId: data.redactionId.present
          ? data.redactionId.value
          : this.redactionId,
      deletedRevisionId: data.deletedRevisionId.present
          ? data.deletedRevisionId.value
          : this.deletedRevisionId,
      deletedSeq: data.deletedSeq.present
          ? data.deletedSeq.value
          : this.deletedSeq,
      redactionSeq: data.redactionSeq.present
          ? data.redactionSeq.value
          : this.redactionSeq,
      proofJson: data.proofJson.present ? data.proofJson.value : this.proofJson,
      serverGeneration: data.serverGeneration.present
          ? data.serverGeneration.value
          : this.serverGeneration,
      appliedAt: data.appliedAt.present ? data.appliedAt.value : this.appliedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncRedaction(')
          ..write('instanceId: $instanceId, ')
          ..write('serverSpaceId: $serverSpaceId, ')
          ..write('vaultId: $vaultId, ')
          ..write('recordId: $recordId, ')
          ..write('redactionId: $redactionId, ')
          ..write('deletedRevisionId: $deletedRevisionId, ')
          ..write('deletedSeq: $deletedSeq, ')
          ..write('redactionSeq: $redactionSeq, ')
          ..write('proofJson: $proofJson, ')
          ..write('serverGeneration: $serverGeneration, ')
          ..write('appliedAt: $appliedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    instanceId,
    serverSpaceId,
    vaultId,
    recordId,
    redactionId,
    deletedRevisionId,
    deletedSeq,
    redactionSeq,
    proofJson,
    serverGeneration,
    appliedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncRedaction &&
          other.instanceId == this.instanceId &&
          other.serverSpaceId == this.serverSpaceId &&
          other.vaultId == this.vaultId &&
          other.recordId == this.recordId &&
          other.redactionId == this.redactionId &&
          other.deletedRevisionId == this.deletedRevisionId &&
          other.deletedSeq == this.deletedSeq &&
          other.redactionSeq == this.redactionSeq &&
          other.proofJson == this.proofJson &&
          other.serverGeneration == this.serverGeneration &&
          other.appliedAt == this.appliedAt);
}

class SyncRedactionsCompanion extends UpdateCompanion<SyncRedaction> {
  final Value<String> instanceId;
  final Value<String> serverSpaceId;
  final Value<String> vaultId;
  final Value<String> recordId;
  final Value<String> redactionId;
  final Value<String> deletedRevisionId;
  final Value<String> deletedSeq;
  final Value<String> redactionSeq;
  final Value<String> proofJson;
  final Value<String> serverGeneration;
  final Value<int> appliedAt;
  final Value<int> rowid;
  const SyncRedactionsCompanion({
    this.instanceId = const Value.absent(),
    this.serverSpaceId = const Value.absent(),
    this.vaultId = const Value.absent(),
    this.recordId = const Value.absent(),
    this.redactionId = const Value.absent(),
    this.deletedRevisionId = const Value.absent(),
    this.deletedSeq = const Value.absent(),
    this.redactionSeq = const Value.absent(),
    this.proofJson = const Value.absent(),
    this.serverGeneration = const Value.absent(),
    this.appliedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SyncRedactionsCompanion.insert({
    required String instanceId,
    required String serverSpaceId,
    required String vaultId,
    required String recordId,
    required String redactionId,
    required String deletedRevisionId,
    required String deletedSeq,
    required String redactionSeq,
    required String proofJson,
    required String serverGeneration,
    required int appliedAt,
    this.rowid = const Value.absent(),
  }) : instanceId = Value(instanceId),
       serverSpaceId = Value(serverSpaceId),
       vaultId = Value(vaultId),
       recordId = Value(recordId),
       redactionId = Value(redactionId),
       deletedRevisionId = Value(deletedRevisionId),
       deletedSeq = Value(deletedSeq),
       redactionSeq = Value(redactionSeq),
       proofJson = Value(proofJson),
       serverGeneration = Value(serverGeneration),
       appliedAt = Value(appliedAt);
  static Insertable<SyncRedaction> custom({
    Expression<String>? instanceId,
    Expression<String>? serverSpaceId,
    Expression<String>? vaultId,
    Expression<String>? recordId,
    Expression<String>? redactionId,
    Expression<String>? deletedRevisionId,
    Expression<String>? deletedSeq,
    Expression<String>? redactionSeq,
    Expression<String>? proofJson,
    Expression<String>? serverGeneration,
    Expression<int>? appliedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (instanceId != null) 'instance_id': instanceId,
      if (serverSpaceId != null) 'server_space_id': serverSpaceId,
      if (vaultId != null) 'vault_id': vaultId,
      if (recordId != null) 'record_id': recordId,
      if (redactionId != null) 'redaction_id': redactionId,
      if (deletedRevisionId != null) 'deleted_revision_id': deletedRevisionId,
      if (deletedSeq != null) 'deleted_seq': deletedSeq,
      if (redactionSeq != null) 'redaction_seq': redactionSeq,
      if (proofJson != null) 'proof_json': proofJson,
      if (serverGeneration != null) 'server_generation': serverGeneration,
      if (appliedAt != null) 'applied_at': appliedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SyncRedactionsCompanion copyWith({
    Value<String>? instanceId,
    Value<String>? serverSpaceId,
    Value<String>? vaultId,
    Value<String>? recordId,
    Value<String>? redactionId,
    Value<String>? deletedRevisionId,
    Value<String>? deletedSeq,
    Value<String>? redactionSeq,
    Value<String>? proofJson,
    Value<String>? serverGeneration,
    Value<int>? appliedAt,
    Value<int>? rowid,
  }) {
    return SyncRedactionsCompanion(
      instanceId: instanceId ?? this.instanceId,
      serverSpaceId: serverSpaceId ?? this.serverSpaceId,
      vaultId: vaultId ?? this.vaultId,
      recordId: recordId ?? this.recordId,
      redactionId: redactionId ?? this.redactionId,
      deletedRevisionId: deletedRevisionId ?? this.deletedRevisionId,
      deletedSeq: deletedSeq ?? this.deletedSeq,
      redactionSeq: redactionSeq ?? this.redactionSeq,
      proofJson: proofJson ?? this.proofJson,
      serverGeneration: serverGeneration ?? this.serverGeneration,
      appliedAt: appliedAt ?? this.appliedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (instanceId.present) {
      map['instance_id'] = Variable<String>(instanceId.value);
    }
    if (serverSpaceId.present) {
      map['server_space_id'] = Variable<String>(serverSpaceId.value);
    }
    if (vaultId.present) {
      map['vault_id'] = Variable<String>(vaultId.value);
    }
    if (recordId.present) {
      map['record_id'] = Variable<String>(recordId.value);
    }
    if (redactionId.present) {
      map['redaction_id'] = Variable<String>(redactionId.value);
    }
    if (deletedRevisionId.present) {
      map['deleted_revision_id'] = Variable<String>(deletedRevisionId.value);
    }
    if (deletedSeq.present) {
      map['deleted_seq'] = Variable<String>(deletedSeq.value);
    }
    if (redactionSeq.present) {
      map['redaction_seq'] = Variable<String>(redactionSeq.value);
    }
    if (proofJson.present) {
      map['proof_json'] = Variable<String>(proofJson.value);
    }
    if (serverGeneration.present) {
      map['server_generation'] = Variable<String>(serverGeneration.value);
    }
    if (appliedAt.present) {
      map['applied_at'] = Variable<int>(appliedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncRedactionsCompanion(')
          ..write('instanceId: $instanceId, ')
          ..write('serverSpaceId: $serverSpaceId, ')
          ..write('vaultId: $vaultId, ')
          ..write('recordId: $recordId, ')
          ..write('redactionId: $redactionId, ')
          ..write('deletedRevisionId: $deletedRevisionId, ')
          ..write('deletedSeq: $deletedSeq, ')
          ..write('redactionSeq: $redactionSeq, ')
          ..write('proofJson: $proofJson, ')
          ..write('serverGeneration: $serverGeneration, ')
          ..write('appliedAt: $appliedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SyncSnapshotRecoveryCursorsTable extends SyncSnapshotRecoveryCursors
    with
        TableInfo<
          $SyncSnapshotRecoveryCursorsTable,
          SyncSnapshotRecoveryCursor
        > {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncSnapshotRecoveryCursorsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _serverNamespaceMeta = const VerificationMeta(
    'serverNamespace',
  );
  @override
  late final GeneratedColumn<String> serverNamespace = GeneratedColumn<String>(
    'server_namespace',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<String> accountId = GeneratedColumn<String>(
    'account_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _instanceIdMeta = const VerificationMeta(
    'instanceId',
  );
  @override
  late final GeneratedColumn<String> instanceId = GeneratedColumn<String>(
    'instance_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _serverSpaceIdMeta = const VerificationMeta(
    'serverSpaceId',
  );
  @override
  late final GeneratedColumn<String> serverSpaceId = GeneratedColumn<String>(
    'server_space_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _vaultIdMeta = const VerificationMeta(
    'vaultId',
  );
  @override
  late final GeneratedColumn<String> vaultId = GeneratedColumn<String>(
    'vault_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _serverGenerationMeta = const VerificationMeta(
    'serverGeneration',
  );
  @override
  late final GeneratedColumn<String> serverGeneration = GeneratedColumn<String>(
    'server_generation',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _snapshotIdMeta = const VerificationMeta(
    'snapshotId',
  );
  @override
  late final GeneratedColumn<String> snapshotId = GeneratedColumn<String>(
    'snapshot_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _cursorMeta = const VerificationMeta('cursor');
  @override
  late final GeneratedColumn<String> cursor = GeneratedColumn<String>(
    'cursor',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    serverNamespace,
    accountId,
    instanceId,
    serverSpaceId,
    vaultId,
    serverGeneration,
    snapshotId,
    cursor,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_snapshot_recovery_cursors';
  @override
  VerificationContext validateIntegrity(
    Insertable<SyncSnapshotRecoveryCursor> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('server_namespace')) {
      context.handle(
        _serverNamespaceMeta,
        serverNamespace.isAcceptableOrUnknown(
          data['server_namespace']!,
          _serverNamespaceMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_serverNamespaceMeta);
    }
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    } else if (isInserting) {
      context.missing(_accountIdMeta);
    }
    if (data.containsKey('instance_id')) {
      context.handle(
        _instanceIdMeta,
        instanceId.isAcceptableOrUnknown(data['instance_id']!, _instanceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_instanceIdMeta);
    }
    if (data.containsKey('server_space_id')) {
      context.handle(
        _serverSpaceIdMeta,
        serverSpaceId.isAcceptableOrUnknown(
          data['server_space_id']!,
          _serverSpaceIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_serverSpaceIdMeta);
    }
    if (data.containsKey('vault_id')) {
      context.handle(
        _vaultIdMeta,
        vaultId.isAcceptableOrUnknown(data['vault_id']!, _vaultIdMeta),
      );
    } else if (isInserting) {
      context.missing(_vaultIdMeta);
    }
    if (data.containsKey('server_generation')) {
      context.handle(
        _serverGenerationMeta,
        serverGeneration.isAcceptableOrUnknown(
          data['server_generation']!,
          _serverGenerationMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_serverGenerationMeta);
    }
    if (data.containsKey('snapshot_id')) {
      context.handle(
        _snapshotIdMeta,
        snapshotId.isAcceptableOrUnknown(data['snapshot_id']!, _snapshotIdMeta),
      );
    } else if (isInserting) {
      context.missing(_snapshotIdMeta);
    }
    if (data.containsKey('cursor')) {
      context.handle(
        _cursorMeta,
        cursor.isAcceptableOrUnknown(data['cursor']!, _cursorMeta),
      );
    } else if (isInserting) {
      context.missing(_cursorMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {
    serverNamespace,
    accountId,
    instanceId,
    serverSpaceId,
    vaultId,
    serverGeneration,
    snapshotId,
    cursor,
  };
  @override
  SyncSnapshotRecoveryCursor map(
    Map<String, dynamic> data, {
    String? tablePrefix,
  }) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncSnapshotRecoveryCursor(
      serverNamespace: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_namespace'],
      )!,
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}account_id'],
      )!,
      instanceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}instance_id'],
      )!,
      serverSpaceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_space_id'],
      )!,
      vaultId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}vault_id'],
      )!,
      serverGeneration: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_generation'],
      )!,
      snapshotId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}snapshot_id'],
      )!,
      cursor: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}cursor'],
      )!,
    );
  }

  @override
  $SyncSnapshotRecoveryCursorsTable createAlias(String alias) {
    return $SyncSnapshotRecoveryCursorsTable(attachedDatabase, alias);
  }
}

class SyncSnapshotRecoveryCursor extends DataClass
    implements Insertable<SyncSnapshotRecoveryCursor> {
  final String serverNamespace;
  final String accountId;
  final String instanceId;
  final String serverSpaceId;
  final String vaultId;
  final String serverGeneration;
  final String snapshotId;
  final String cursor;
  const SyncSnapshotRecoveryCursor({
    required this.serverNamespace,
    required this.accountId,
    required this.instanceId,
    required this.serverSpaceId,
    required this.vaultId,
    required this.serverGeneration,
    required this.snapshotId,
    required this.cursor,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['server_namespace'] = Variable<String>(serverNamespace);
    map['account_id'] = Variable<String>(accountId);
    map['instance_id'] = Variable<String>(instanceId);
    map['server_space_id'] = Variable<String>(serverSpaceId);
    map['vault_id'] = Variable<String>(vaultId);
    map['server_generation'] = Variable<String>(serverGeneration);
    map['snapshot_id'] = Variable<String>(snapshotId);
    map['cursor'] = Variable<String>(cursor);
    return map;
  }

  SyncSnapshotRecoveryCursorsCompanion toCompanion(bool nullToAbsent) {
    return SyncSnapshotRecoveryCursorsCompanion(
      serverNamespace: Value(serverNamespace),
      accountId: Value(accountId),
      instanceId: Value(instanceId),
      serverSpaceId: Value(serverSpaceId),
      vaultId: Value(vaultId),
      serverGeneration: Value(serverGeneration),
      snapshotId: Value(snapshotId),
      cursor: Value(cursor),
    );
  }

  factory SyncSnapshotRecoveryCursor.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncSnapshotRecoveryCursor(
      serverNamespace: serializer.fromJson<String>(json['serverNamespace']),
      accountId: serializer.fromJson<String>(json['accountId']),
      instanceId: serializer.fromJson<String>(json['instanceId']),
      serverSpaceId: serializer.fromJson<String>(json['serverSpaceId']),
      vaultId: serializer.fromJson<String>(json['vaultId']),
      serverGeneration: serializer.fromJson<String>(json['serverGeneration']),
      snapshotId: serializer.fromJson<String>(json['snapshotId']),
      cursor: serializer.fromJson<String>(json['cursor']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'serverNamespace': serializer.toJson<String>(serverNamespace),
      'accountId': serializer.toJson<String>(accountId),
      'instanceId': serializer.toJson<String>(instanceId),
      'serverSpaceId': serializer.toJson<String>(serverSpaceId),
      'vaultId': serializer.toJson<String>(vaultId),
      'serverGeneration': serializer.toJson<String>(serverGeneration),
      'snapshotId': serializer.toJson<String>(snapshotId),
      'cursor': serializer.toJson<String>(cursor),
    };
  }

  SyncSnapshotRecoveryCursor copyWith({
    String? serverNamespace,
    String? accountId,
    String? instanceId,
    String? serverSpaceId,
    String? vaultId,
    String? serverGeneration,
    String? snapshotId,
    String? cursor,
  }) => SyncSnapshotRecoveryCursor(
    serverNamespace: serverNamespace ?? this.serverNamespace,
    accountId: accountId ?? this.accountId,
    instanceId: instanceId ?? this.instanceId,
    serverSpaceId: serverSpaceId ?? this.serverSpaceId,
    vaultId: vaultId ?? this.vaultId,
    serverGeneration: serverGeneration ?? this.serverGeneration,
    snapshotId: snapshotId ?? this.snapshotId,
    cursor: cursor ?? this.cursor,
  );
  SyncSnapshotRecoveryCursor copyWithCompanion(
    SyncSnapshotRecoveryCursorsCompanion data,
  ) {
    return SyncSnapshotRecoveryCursor(
      serverNamespace: data.serverNamespace.present
          ? data.serverNamespace.value
          : this.serverNamespace,
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      instanceId: data.instanceId.present
          ? data.instanceId.value
          : this.instanceId,
      serverSpaceId: data.serverSpaceId.present
          ? data.serverSpaceId.value
          : this.serverSpaceId,
      vaultId: data.vaultId.present ? data.vaultId.value : this.vaultId,
      serverGeneration: data.serverGeneration.present
          ? data.serverGeneration.value
          : this.serverGeneration,
      snapshotId: data.snapshotId.present
          ? data.snapshotId.value
          : this.snapshotId,
      cursor: data.cursor.present ? data.cursor.value : this.cursor,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncSnapshotRecoveryCursor(')
          ..write('serverNamespace: $serverNamespace, ')
          ..write('accountId: $accountId, ')
          ..write('instanceId: $instanceId, ')
          ..write('serverSpaceId: $serverSpaceId, ')
          ..write('vaultId: $vaultId, ')
          ..write('serverGeneration: $serverGeneration, ')
          ..write('snapshotId: $snapshotId, ')
          ..write('cursor: $cursor')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    serverNamespace,
    accountId,
    instanceId,
    serverSpaceId,
    vaultId,
    serverGeneration,
    snapshotId,
    cursor,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncSnapshotRecoveryCursor &&
          other.serverNamespace == this.serverNamespace &&
          other.accountId == this.accountId &&
          other.instanceId == this.instanceId &&
          other.serverSpaceId == this.serverSpaceId &&
          other.vaultId == this.vaultId &&
          other.serverGeneration == this.serverGeneration &&
          other.snapshotId == this.snapshotId &&
          other.cursor == this.cursor);
}

class SyncSnapshotRecoveryCursorsCompanion
    extends UpdateCompanion<SyncSnapshotRecoveryCursor> {
  final Value<String> serverNamespace;
  final Value<String> accountId;
  final Value<String> instanceId;
  final Value<String> serverSpaceId;
  final Value<String> vaultId;
  final Value<String> serverGeneration;
  final Value<String> snapshotId;
  final Value<String> cursor;
  final Value<int> rowid;
  const SyncSnapshotRecoveryCursorsCompanion({
    this.serverNamespace = const Value.absent(),
    this.accountId = const Value.absent(),
    this.instanceId = const Value.absent(),
    this.serverSpaceId = const Value.absent(),
    this.vaultId = const Value.absent(),
    this.serverGeneration = const Value.absent(),
    this.snapshotId = const Value.absent(),
    this.cursor = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SyncSnapshotRecoveryCursorsCompanion.insert({
    required String serverNamespace,
    required String accountId,
    required String instanceId,
    required String serverSpaceId,
    required String vaultId,
    required String serverGeneration,
    required String snapshotId,
    required String cursor,
    this.rowid = const Value.absent(),
  }) : serverNamespace = Value(serverNamespace),
       accountId = Value(accountId),
       instanceId = Value(instanceId),
       serverSpaceId = Value(serverSpaceId),
       vaultId = Value(vaultId),
       serverGeneration = Value(serverGeneration),
       snapshotId = Value(snapshotId),
       cursor = Value(cursor);
  static Insertable<SyncSnapshotRecoveryCursor> custom({
    Expression<String>? serverNamespace,
    Expression<String>? accountId,
    Expression<String>? instanceId,
    Expression<String>? serverSpaceId,
    Expression<String>? vaultId,
    Expression<String>? serverGeneration,
    Expression<String>? snapshotId,
    Expression<String>? cursor,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (serverNamespace != null) 'server_namespace': serverNamespace,
      if (accountId != null) 'account_id': accountId,
      if (instanceId != null) 'instance_id': instanceId,
      if (serverSpaceId != null) 'server_space_id': serverSpaceId,
      if (vaultId != null) 'vault_id': vaultId,
      if (serverGeneration != null) 'server_generation': serverGeneration,
      if (snapshotId != null) 'snapshot_id': snapshotId,
      if (cursor != null) 'cursor': cursor,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SyncSnapshotRecoveryCursorsCompanion copyWith({
    Value<String>? serverNamespace,
    Value<String>? accountId,
    Value<String>? instanceId,
    Value<String>? serverSpaceId,
    Value<String>? vaultId,
    Value<String>? serverGeneration,
    Value<String>? snapshotId,
    Value<String>? cursor,
    Value<int>? rowid,
  }) {
    return SyncSnapshotRecoveryCursorsCompanion(
      serverNamespace: serverNamespace ?? this.serverNamespace,
      accountId: accountId ?? this.accountId,
      instanceId: instanceId ?? this.instanceId,
      serverSpaceId: serverSpaceId ?? this.serverSpaceId,
      vaultId: vaultId ?? this.vaultId,
      serverGeneration: serverGeneration ?? this.serverGeneration,
      snapshotId: snapshotId ?? this.snapshotId,
      cursor: cursor ?? this.cursor,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (serverNamespace.present) {
      map['server_namespace'] = Variable<String>(serverNamespace.value);
    }
    if (accountId.present) {
      map['account_id'] = Variable<String>(accountId.value);
    }
    if (instanceId.present) {
      map['instance_id'] = Variable<String>(instanceId.value);
    }
    if (serverSpaceId.present) {
      map['server_space_id'] = Variable<String>(serverSpaceId.value);
    }
    if (vaultId.present) {
      map['vault_id'] = Variable<String>(vaultId.value);
    }
    if (serverGeneration.present) {
      map['server_generation'] = Variable<String>(serverGeneration.value);
    }
    if (snapshotId.present) {
      map['snapshot_id'] = Variable<String>(snapshotId.value);
    }
    if (cursor.present) {
      map['cursor'] = Variable<String>(cursor.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncSnapshotRecoveryCursorsCompanion(')
          ..write('serverNamespace: $serverNamespace, ')
          ..write('accountId: $accountId, ')
          ..write('instanceId: $instanceId, ')
          ..write('serverSpaceId: $serverSpaceId, ')
          ..write('vaultId: $vaultId, ')
          ..write('serverGeneration: $serverGeneration, ')
          ..write('snapshotId: $snapshotId, ')
          ..write('cursor: $cursor, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ConflictBranchesTable extends ConflictBranches
    with TableInfo<$ConflictBranchesTable, ConflictBranche> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ConflictBranchesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _conflictIdMeta = const VerificationMeta(
    'conflictId',
  );
  @override
  late final GeneratedColumn<String> conflictId = GeneratedColumn<String>(
    'conflict_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _vaultIdMeta = const VerificationMeta(
    'vaultId',
  );
  @override
  late final GeneratedColumn<String> vaultId = GeneratedColumn<String>(
    'vault_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _recordIdMeta = const VerificationMeta(
    'recordId',
  );
  @override
  late final GeneratedColumn<String> recordId = GeneratedColumn<String>(
    'record_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _instanceIdMeta = const VerificationMeta(
    'instanceId',
  );
  @override
  late final GeneratedColumn<String> instanceId = GeneratedColumn<String>(
    'instance_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _serverSpaceIdMeta = const VerificationMeta(
    'serverSpaceId',
  );
  @override
  late final GeneratedColumn<String> serverSpaceId = GeneratedColumn<String>(
    'server_space_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
    'kind',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _branchEnvelopeJsonMeta =
      const VerificationMeta('branchEnvelopeJson');
  @override
  late final GeneratedColumn<String> branchEnvelopeJson =
      GeneratedColumn<String>(
        'branch_envelope_json',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: true,
      );
  static const VerificationMeta _remoteEnvelopeJsonMeta =
      const VerificationMeta('remoteEnvelopeJson');
  @override
  late final GeneratedColumn<String> remoteEnvelopeJson =
      GeneratedColumn<String>(
        'remote_envelope_json',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: true,
      );
  static const VerificationMeta _stateMeta = const VerificationMeta('state');
  @override
  late final GeneratedColumn<String> state = GeneratedColumn<String>(
    'state',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('open'),
  );
  static const VerificationMeta _resolutionOpIdMeta = const VerificationMeta(
    'resolutionOpId',
  );
  @override
  late final GeneratedColumn<String> resolutionOpId = GeneratedColumn<String>(
    'resolution_op_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _resolutionRevisionIdMeta =
      const VerificationMeta('resolutionRevisionId');
  @override
  late final GeneratedColumn<String> resolutionRevisionId =
      GeneratedColumn<String>(
        'resolution_revision_id',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _redactionProofJsonMeta =
      const VerificationMeta('redactionProofJson');
  @override
  late final GeneratedColumn<String> redactionProofJson =
      GeneratedColumn<String>(
        'redaction_proof_json',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    conflictId,
    vaultId,
    recordId,
    instanceId,
    serverSpaceId,
    kind,
    branchEnvelopeJson,
    remoteEnvelopeJson,
    state,
    resolutionOpId,
    resolutionRevisionId,
    redactionProofJson,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'conflict_branches';
  @override
  VerificationContext validateIntegrity(
    Insertable<ConflictBranche> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('conflict_id')) {
      context.handle(
        _conflictIdMeta,
        conflictId.isAcceptableOrUnknown(data['conflict_id']!, _conflictIdMeta),
      );
    } else if (isInserting) {
      context.missing(_conflictIdMeta);
    }
    if (data.containsKey('vault_id')) {
      context.handle(
        _vaultIdMeta,
        vaultId.isAcceptableOrUnknown(data['vault_id']!, _vaultIdMeta),
      );
    } else if (isInserting) {
      context.missing(_vaultIdMeta);
    }
    if (data.containsKey('record_id')) {
      context.handle(
        _recordIdMeta,
        recordId.isAcceptableOrUnknown(data['record_id']!, _recordIdMeta),
      );
    } else if (isInserting) {
      context.missing(_recordIdMeta);
    }
    if (data.containsKey('instance_id')) {
      context.handle(
        _instanceIdMeta,
        instanceId.isAcceptableOrUnknown(data['instance_id']!, _instanceIdMeta),
      );
    }
    if (data.containsKey('server_space_id')) {
      context.handle(
        _serverSpaceIdMeta,
        serverSpaceId.isAcceptableOrUnknown(
          data['server_space_id']!,
          _serverSpaceIdMeta,
        ),
      );
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('branch_envelope_json')) {
      context.handle(
        _branchEnvelopeJsonMeta,
        branchEnvelopeJson.isAcceptableOrUnknown(
          data['branch_envelope_json']!,
          _branchEnvelopeJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_branchEnvelopeJsonMeta);
    }
    if (data.containsKey('remote_envelope_json')) {
      context.handle(
        _remoteEnvelopeJsonMeta,
        remoteEnvelopeJson.isAcceptableOrUnknown(
          data['remote_envelope_json']!,
          _remoteEnvelopeJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_remoteEnvelopeJsonMeta);
    }
    if (data.containsKey('state')) {
      context.handle(
        _stateMeta,
        state.isAcceptableOrUnknown(data['state']!, _stateMeta),
      );
    }
    if (data.containsKey('resolution_op_id')) {
      context.handle(
        _resolutionOpIdMeta,
        resolutionOpId.isAcceptableOrUnknown(
          data['resolution_op_id']!,
          _resolutionOpIdMeta,
        ),
      );
    }
    if (data.containsKey('resolution_revision_id')) {
      context.handle(
        _resolutionRevisionIdMeta,
        resolutionRevisionId.isAcceptableOrUnknown(
          data['resolution_revision_id']!,
          _resolutionRevisionIdMeta,
        ),
      );
    }
    if (data.containsKey('redaction_proof_json')) {
      context.handle(
        _redactionProofJsonMeta,
        redactionProofJson.isAcceptableOrUnknown(
          data['redaction_proof_json']!,
          _redactionProofJsonMeta,
        ),
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
  Set<GeneratedColumn> get $primaryKey => {conflictId};
  @override
  ConflictBranche map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ConflictBranche(
      conflictId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conflict_id'],
      )!,
      vaultId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}vault_id'],
      )!,
      recordId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}record_id'],
      )!,
      instanceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}instance_id'],
      ),
      serverSpaceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_space_id'],
      ),
      kind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}kind'],
      )!,
      branchEnvelopeJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}branch_envelope_json'],
      )!,
      remoteEnvelopeJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}remote_envelope_json'],
      )!,
      state: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}state'],
      )!,
      resolutionOpId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}resolution_op_id'],
      ),
      resolutionRevisionId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}resolution_revision_id'],
      ),
      redactionProofJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}redaction_proof_json'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $ConflictBranchesTable createAlias(String alias) {
    return $ConflictBranchesTable(attachedDatabase, alias);
  }
}

class ConflictBranche extends DataClass implements Insertable<ConflictBranche> {
  final String conflictId;
  final String vaultId;
  final String recordId;
  final String? instanceId;
  final String? serverSpaceId;
  final String kind;
  final String branchEnvelopeJson;
  final String remoteEnvelopeJson;
  final String state;
  final String? resolutionOpId;
  final String? resolutionRevisionId;
  final String? redactionProofJson;
  final int createdAt;
  const ConflictBranche({
    required this.conflictId,
    required this.vaultId,
    required this.recordId,
    this.instanceId,
    this.serverSpaceId,
    required this.kind,
    required this.branchEnvelopeJson,
    required this.remoteEnvelopeJson,
    required this.state,
    this.resolutionOpId,
    this.resolutionRevisionId,
    this.redactionProofJson,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['conflict_id'] = Variable<String>(conflictId);
    map['vault_id'] = Variable<String>(vaultId);
    map['record_id'] = Variable<String>(recordId);
    if (!nullToAbsent || instanceId != null) {
      map['instance_id'] = Variable<String>(instanceId);
    }
    if (!nullToAbsent || serverSpaceId != null) {
      map['server_space_id'] = Variable<String>(serverSpaceId);
    }
    map['kind'] = Variable<String>(kind);
    map['branch_envelope_json'] = Variable<String>(branchEnvelopeJson);
    map['remote_envelope_json'] = Variable<String>(remoteEnvelopeJson);
    map['state'] = Variable<String>(state);
    if (!nullToAbsent || resolutionOpId != null) {
      map['resolution_op_id'] = Variable<String>(resolutionOpId);
    }
    if (!nullToAbsent || resolutionRevisionId != null) {
      map['resolution_revision_id'] = Variable<String>(resolutionRevisionId);
    }
    if (!nullToAbsent || redactionProofJson != null) {
      map['redaction_proof_json'] = Variable<String>(redactionProofJson);
    }
    map['created_at'] = Variable<int>(createdAt);
    return map;
  }

  ConflictBranchesCompanion toCompanion(bool nullToAbsent) {
    return ConflictBranchesCompanion(
      conflictId: Value(conflictId),
      vaultId: Value(vaultId),
      recordId: Value(recordId),
      instanceId: instanceId == null && nullToAbsent
          ? const Value.absent()
          : Value(instanceId),
      serverSpaceId: serverSpaceId == null && nullToAbsent
          ? const Value.absent()
          : Value(serverSpaceId),
      kind: Value(kind),
      branchEnvelopeJson: Value(branchEnvelopeJson),
      remoteEnvelopeJson: Value(remoteEnvelopeJson),
      state: Value(state),
      resolutionOpId: resolutionOpId == null && nullToAbsent
          ? const Value.absent()
          : Value(resolutionOpId),
      resolutionRevisionId: resolutionRevisionId == null && nullToAbsent
          ? const Value.absent()
          : Value(resolutionRevisionId),
      redactionProofJson: redactionProofJson == null && nullToAbsent
          ? const Value.absent()
          : Value(redactionProofJson),
      createdAt: Value(createdAt),
    );
  }

  factory ConflictBranche.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ConflictBranche(
      conflictId: serializer.fromJson<String>(json['conflictId']),
      vaultId: serializer.fromJson<String>(json['vaultId']),
      recordId: serializer.fromJson<String>(json['recordId']),
      instanceId: serializer.fromJson<String?>(json['instanceId']),
      serverSpaceId: serializer.fromJson<String?>(json['serverSpaceId']),
      kind: serializer.fromJson<String>(json['kind']),
      branchEnvelopeJson: serializer.fromJson<String>(
        json['branchEnvelopeJson'],
      ),
      remoteEnvelopeJson: serializer.fromJson<String>(
        json['remoteEnvelopeJson'],
      ),
      state: serializer.fromJson<String>(json['state']),
      resolutionOpId: serializer.fromJson<String?>(json['resolutionOpId']),
      resolutionRevisionId: serializer.fromJson<String?>(
        json['resolutionRevisionId'],
      ),
      redactionProofJson: serializer.fromJson<String?>(
        json['redactionProofJson'],
      ),
      createdAt: serializer.fromJson<int>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'conflictId': serializer.toJson<String>(conflictId),
      'vaultId': serializer.toJson<String>(vaultId),
      'recordId': serializer.toJson<String>(recordId),
      'instanceId': serializer.toJson<String?>(instanceId),
      'serverSpaceId': serializer.toJson<String?>(serverSpaceId),
      'kind': serializer.toJson<String>(kind),
      'branchEnvelopeJson': serializer.toJson<String>(branchEnvelopeJson),
      'remoteEnvelopeJson': serializer.toJson<String>(remoteEnvelopeJson),
      'state': serializer.toJson<String>(state),
      'resolutionOpId': serializer.toJson<String?>(resolutionOpId),
      'resolutionRevisionId': serializer.toJson<String?>(resolutionRevisionId),
      'redactionProofJson': serializer.toJson<String?>(redactionProofJson),
      'createdAt': serializer.toJson<int>(createdAt),
    };
  }

  ConflictBranche copyWith({
    String? conflictId,
    String? vaultId,
    String? recordId,
    Value<String?> instanceId = const Value.absent(),
    Value<String?> serverSpaceId = const Value.absent(),
    String? kind,
    String? branchEnvelopeJson,
    String? remoteEnvelopeJson,
    String? state,
    Value<String?> resolutionOpId = const Value.absent(),
    Value<String?> resolutionRevisionId = const Value.absent(),
    Value<String?> redactionProofJson = const Value.absent(),
    int? createdAt,
  }) => ConflictBranche(
    conflictId: conflictId ?? this.conflictId,
    vaultId: vaultId ?? this.vaultId,
    recordId: recordId ?? this.recordId,
    instanceId: instanceId.present ? instanceId.value : this.instanceId,
    serverSpaceId: serverSpaceId.present
        ? serverSpaceId.value
        : this.serverSpaceId,
    kind: kind ?? this.kind,
    branchEnvelopeJson: branchEnvelopeJson ?? this.branchEnvelopeJson,
    remoteEnvelopeJson: remoteEnvelopeJson ?? this.remoteEnvelopeJson,
    state: state ?? this.state,
    resolutionOpId: resolutionOpId.present
        ? resolutionOpId.value
        : this.resolutionOpId,
    resolutionRevisionId: resolutionRevisionId.present
        ? resolutionRevisionId.value
        : this.resolutionRevisionId,
    redactionProofJson: redactionProofJson.present
        ? redactionProofJson.value
        : this.redactionProofJson,
    createdAt: createdAt ?? this.createdAt,
  );
  ConflictBranche copyWithCompanion(ConflictBranchesCompanion data) {
    return ConflictBranche(
      conflictId: data.conflictId.present
          ? data.conflictId.value
          : this.conflictId,
      vaultId: data.vaultId.present ? data.vaultId.value : this.vaultId,
      recordId: data.recordId.present ? data.recordId.value : this.recordId,
      instanceId: data.instanceId.present
          ? data.instanceId.value
          : this.instanceId,
      serverSpaceId: data.serverSpaceId.present
          ? data.serverSpaceId.value
          : this.serverSpaceId,
      kind: data.kind.present ? data.kind.value : this.kind,
      branchEnvelopeJson: data.branchEnvelopeJson.present
          ? data.branchEnvelopeJson.value
          : this.branchEnvelopeJson,
      remoteEnvelopeJson: data.remoteEnvelopeJson.present
          ? data.remoteEnvelopeJson.value
          : this.remoteEnvelopeJson,
      state: data.state.present ? data.state.value : this.state,
      resolutionOpId: data.resolutionOpId.present
          ? data.resolutionOpId.value
          : this.resolutionOpId,
      resolutionRevisionId: data.resolutionRevisionId.present
          ? data.resolutionRevisionId.value
          : this.resolutionRevisionId,
      redactionProofJson: data.redactionProofJson.present
          ? data.redactionProofJson.value
          : this.redactionProofJson,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ConflictBranche(')
          ..write('conflictId: $conflictId, ')
          ..write('vaultId: $vaultId, ')
          ..write('recordId: $recordId, ')
          ..write('instanceId: $instanceId, ')
          ..write('serverSpaceId: $serverSpaceId, ')
          ..write('kind: $kind, ')
          ..write('branchEnvelopeJson: $branchEnvelopeJson, ')
          ..write('remoteEnvelopeJson: $remoteEnvelopeJson, ')
          ..write('state: $state, ')
          ..write('resolutionOpId: $resolutionOpId, ')
          ..write('resolutionRevisionId: $resolutionRevisionId, ')
          ..write('redactionProofJson: $redactionProofJson, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    conflictId,
    vaultId,
    recordId,
    instanceId,
    serverSpaceId,
    kind,
    branchEnvelopeJson,
    remoteEnvelopeJson,
    state,
    resolutionOpId,
    resolutionRevisionId,
    redactionProofJson,
    createdAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ConflictBranche &&
          other.conflictId == this.conflictId &&
          other.vaultId == this.vaultId &&
          other.recordId == this.recordId &&
          other.instanceId == this.instanceId &&
          other.serverSpaceId == this.serverSpaceId &&
          other.kind == this.kind &&
          other.branchEnvelopeJson == this.branchEnvelopeJson &&
          other.remoteEnvelopeJson == this.remoteEnvelopeJson &&
          other.state == this.state &&
          other.resolutionOpId == this.resolutionOpId &&
          other.resolutionRevisionId == this.resolutionRevisionId &&
          other.redactionProofJson == this.redactionProofJson &&
          other.createdAt == this.createdAt);
}

class ConflictBranchesCompanion extends UpdateCompanion<ConflictBranche> {
  final Value<String> conflictId;
  final Value<String> vaultId;
  final Value<String> recordId;
  final Value<String?> instanceId;
  final Value<String?> serverSpaceId;
  final Value<String> kind;
  final Value<String> branchEnvelopeJson;
  final Value<String> remoteEnvelopeJson;
  final Value<String> state;
  final Value<String?> resolutionOpId;
  final Value<String?> resolutionRevisionId;
  final Value<String?> redactionProofJson;
  final Value<int> createdAt;
  final Value<int> rowid;
  const ConflictBranchesCompanion({
    this.conflictId = const Value.absent(),
    this.vaultId = const Value.absent(),
    this.recordId = const Value.absent(),
    this.instanceId = const Value.absent(),
    this.serverSpaceId = const Value.absent(),
    this.kind = const Value.absent(),
    this.branchEnvelopeJson = const Value.absent(),
    this.remoteEnvelopeJson = const Value.absent(),
    this.state = const Value.absent(),
    this.resolutionOpId = const Value.absent(),
    this.resolutionRevisionId = const Value.absent(),
    this.redactionProofJson = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ConflictBranchesCompanion.insert({
    required String conflictId,
    required String vaultId,
    required String recordId,
    this.instanceId = const Value.absent(),
    this.serverSpaceId = const Value.absent(),
    required String kind,
    required String branchEnvelopeJson,
    required String remoteEnvelopeJson,
    this.state = const Value.absent(),
    this.resolutionOpId = const Value.absent(),
    this.resolutionRevisionId = const Value.absent(),
    this.redactionProofJson = const Value.absent(),
    required int createdAt,
    this.rowid = const Value.absent(),
  }) : conflictId = Value(conflictId),
       vaultId = Value(vaultId),
       recordId = Value(recordId),
       kind = Value(kind),
       branchEnvelopeJson = Value(branchEnvelopeJson),
       remoteEnvelopeJson = Value(remoteEnvelopeJson),
       createdAt = Value(createdAt);
  static Insertable<ConflictBranche> custom({
    Expression<String>? conflictId,
    Expression<String>? vaultId,
    Expression<String>? recordId,
    Expression<String>? instanceId,
    Expression<String>? serverSpaceId,
    Expression<String>? kind,
    Expression<String>? branchEnvelopeJson,
    Expression<String>? remoteEnvelopeJson,
    Expression<String>? state,
    Expression<String>? resolutionOpId,
    Expression<String>? resolutionRevisionId,
    Expression<String>? redactionProofJson,
    Expression<int>? createdAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (conflictId != null) 'conflict_id': conflictId,
      if (vaultId != null) 'vault_id': vaultId,
      if (recordId != null) 'record_id': recordId,
      if (instanceId != null) 'instance_id': instanceId,
      if (serverSpaceId != null) 'server_space_id': serverSpaceId,
      if (kind != null) 'kind': kind,
      if (branchEnvelopeJson != null)
        'branch_envelope_json': branchEnvelopeJson,
      if (remoteEnvelopeJson != null)
        'remote_envelope_json': remoteEnvelopeJson,
      if (state != null) 'state': state,
      if (resolutionOpId != null) 'resolution_op_id': resolutionOpId,
      if (resolutionRevisionId != null)
        'resolution_revision_id': resolutionRevisionId,
      if (redactionProofJson != null)
        'redaction_proof_json': redactionProofJson,
      if (createdAt != null) 'created_at': createdAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ConflictBranchesCompanion copyWith({
    Value<String>? conflictId,
    Value<String>? vaultId,
    Value<String>? recordId,
    Value<String?>? instanceId,
    Value<String?>? serverSpaceId,
    Value<String>? kind,
    Value<String>? branchEnvelopeJson,
    Value<String>? remoteEnvelopeJson,
    Value<String>? state,
    Value<String?>? resolutionOpId,
    Value<String?>? resolutionRevisionId,
    Value<String?>? redactionProofJson,
    Value<int>? createdAt,
    Value<int>? rowid,
  }) {
    return ConflictBranchesCompanion(
      conflictId: conflictId ?? this.conflictId,
      vaultId: vaultId ?? this.vaultId,
      recordId: recordId ?? this.recordId,
      instanceId: instanceId ?? this.instanceId,
      serverSpaceId: serverSpaceId ?? this.serverSpaceId,
      kind: kind ?? this.kind,
      branchEnvelopeJson: branchEnvelopeJson ?? this.branchEnvelopeJson,
      remoteEnvelopeJson: remoteEnvelopeJson ?? this.remoteEnvelopeJson,
      state: state ?? this.state,
      resolutionOpId: resolutionOpId ?? this.resolutionOpId,
      resolutionRevisionId: resolutionRevisionId ?? this.resolutionRevisionId,
      redactionProofJson: redactionProofJson ?? this.redactionProofJson,
      createdAt: createdAt ?? this.createdAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (conflictId.present) {
      map['conflict_id'] = Variable<String>(conflictId.value);
    }
    if (vaultId.present) {
      map['vault_id'] = Variable<String>(vaultId.value);
    }
    if (recordId.present) {
      map['record_id'] = Variable<String>(recordId.value);
    }
    if (instanceId.present) {
      map['instance_id'] = Variable<String>(instanceId.value);
    }
    if (serverSpaceId.present) {
      map['server_space_id'] = Variable<String>(serverSpaceId.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (branchEnvelopeJson.present) {
      map['branch_envelope_json'] = Variable<String>(branchEnvelopeJson.value);
    }
    if (remoteEnvelopeJson.present) {
      map['remote_envelope_json'] = Variable<String>(remoteEnvelopeJson.value);
    }
    if (state.present) {
      map['state'] = Variable<String>(state.value);
    }
    if (resolutionOpId.present) {
      map['resolution_op_id'] = Variable<String>(resolutionOpId.value);
    }
    if (resolutionRevisionId.present) {
      map['resolution_revision_id'] = Variable<String>(
        resolutionRevisionId.value,
      );
    }
    if (redactionProofJson.present) {
      map['redaction_proof_json'] = Variable<String>(redactionProofJson.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ConflictBranchesCompanion(')
          ..write('conflictId: $conflictId, ')
          ..write('vaultId: $vaultId, ')
          ..write('recordId: $recordId, ')
          ..write('instanceId: $instanceId, ')
          ..write('serverSpaceId: $serverSpaceId, ')
          ..write('kind: $kind, ')
          ..write('branchEnvelopeJson: $branchEnvelopeJson, ')
          ..write('remoteEnvelopeJson: $remoteEnvelopeJson, ')
          ..write('state: $state, ')
          ..write('resolutionOpId: $resolutionOpId, ')
          ..write('resolutionRevisionId: $resolutionRevisionId, ')
          ..write('redactionProofJson: $redactionProofJson, ')
          ..write('createdAt: $createdAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $TrustedDevicesTable extends TrustedDevices
    with TableInfo<$TrustedDevicesTable, TrustedDevice> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TrustedDevicesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _deviceIdMeta = const VerificationMeta(
    'deviceId',
  );
  @override
  late final GeneratedColumn<String> deviceId = GeneratedColumn<String>(
    'device_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _signingPublicKeyMeta = const VerificationMeta(
    'signingPublicKey',
  );
  @override
  late final GeneratedColumn<String> signingPublicKey = GeneratedColumn<String>(
    'signing_public_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _displayNameEnvelopeMeta =
      const VerificationMeta('displayNameEnvelope');
  @override
  late final GeneratedColumn<String> displayNameEnvelope =
      GeneratedColumn<String>(
        'display_name_envelope',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  @override
  List<GeneratedColumn> get $columns => [
    deviceId,
    signingPublicKey,
    displayNameEnvelope,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'trusted_devices';
  @override
  VerificationContext validateIntegrity(
    Insertable<TrustedDevice> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('device_id')) {
      context.handle(
        _deviceIdMeta,
        deviceId.isAcceptableOrUnknown(data['device_id']!, _deviceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_deviceIdMeta);
    }
    if (data.containsKey('signing_public_key')) {
      context.handle(
        _signingPublicKeyMeta,
        signingPublicKey.isAcceptableOrUnknown(
          data['signing_public_key']!,
          _signingPublicKeyMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_signingPublicKeyMeta);
    }
    if (data.containsKey('display_name_envelope')) {
      context.handle(
        _displayNameEnvelopeMeta,
        displayNameEnvelope.isAcceptableOrUnknown(
          data['display_name_envelope']!,
          _displayNameEnvelopeMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {deviceId};
  @override
  TrustedDevice map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return TrustedDevice(
      deviceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}device_id'],
      )!,
      signingPublicKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}signing_public_key'],
      )!,
      displayNameEnvelope: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}display_name_envelope'],
      ),
    );
  }

  @override
  $TrustedDevicesTable createAlias(String alias) {
    return $TrustedDevicesTable(attachedDatabase, alias);
  }
}

class TrustedDevice extends DataClass implements Insertable<TrustedDevice> {
  final String deviceId;
  final String signingPublicKey;
  final String? displayNameEnvelope;
  const TrustedDevice({
    required this.deviceId,
    required this.signingPublicKey,
    this.displayNameEnvelope,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['device_id'] = Variable<String>(deviceId);
    map['signing_public_key'] = Variable<String>(signingPublicKey);
    if (!nullToAbsent || displayNameEnvelope != null) {
      map['display_name_envelope'] = Variable<String>(displayNameEnvelope);
    }
    return map;
  }

  TrustedDevicesCompanion toCompanion(bool nullToAbsent) {
    return TrustedDevicesCompanion(
      deviceId: Value(deviceId),
      signingPublicKey: Value(signingPublicKey),
      displayNameEnvelope: displayNameEnvelope == null && nullToAbsent
          ? const Value.absent()
          : Value(displayNameEnvelope),
    );
  }

  factory TrustedDevice.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return TrustedDevice(
      deviceId: serializer.fromJson<String>(json['deviceId']),
      signingPublicKey: serializer.fromJson<String>(json['signingPublicKey']),
      displayNameEnvelope: serializer.fromJson<String?>(
        json['displayNameEnvelope'],
      ),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'deviceId': serializer.toJson<String>(deviceId),
      'signingPublicKey': serializer.toJson<String>(signingPublicKey),
      'displayNameEnvelope': serializer.toJson<String?>(displayNameEnvelope),
    };
  }

  TrustedDevice copyWith({
    String? deviceId,
    String? signingPublicKey,
    Value<String?> displayNameEnvelope = const Value.absent(),
  }) => TrustedDevice(
    deviceId: deviceId ?? this.deviceId,
    signingPublicKey: signingPublicKey ?? this.signingPublicKey,
    displayNameEnvelope: displayNameEnvelope.present
        ? displayNameEnvelope.value
        : this.displayNameEnvelope,
  );
  TrustedDevice copyWithCompanion(TrustedDevicesCompanion data) {
    return TrustedDevice(
      deviceId: data.deviceId.present ? data.deviceId.value : this.deviceId,
      signingPublicKey: data.signingPublicKey.present
          ? data.signingPublicKey.value
          : this.signingPublicKey,
      displayNameEnvelope: data.displayNameEnvelope.present
          ? data.displayNameEnvelope.value
          : this.displayNameEnvelope,
    );
  }

  @override
  String toString() {
    return (StringBuffer('TrustedDevice(')
          ..write('deviceId: $deviceId, ')
          ..write('signingPublicKey: $signingPublicKey, ')
          ..write('displayNameEnvelope: $displayNameEnvelope')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(deviceId, signingPublicKey, displayNameEnvelope);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TrustedDevice &&
          other.deviceId == this.deviceId &&
          other.signingPublicKey == this.signingPublicKey &&
          other.displayNameEnvelope == this.displayNameEnvelope);
}

class TrustedDevicesCompanion extends UpdateCompanion<TrustedDevice> {
  final Value<String> deviceId;
  final Value<String> signingPublicKey;
  final Value<String?> displayNameEnvelope;
  final Value<int> rowid;
  const TrustedDevicesCompanion({
    this.deviceId = const Value.absent(),
    this.signingPublicKey = const Value.absent(),
    this.displayNameEnvelope = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  TrustedDevicesCompanion.insert({
    required String deviceId,
    required String signingPublicKey,
    this.displayNameEnvelope = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : deviceId = Value(deviceId),
       signingPublicKey = Value(signingPublicKey);
  static Insertable<TrustedDevice> custom({
    Expression<String>? deviceId,
    Expression<String>? signingPublicKey,
    Expression<String>? displayNameEnvelope,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (deviceId != null) 'device_id': deviceId,
      if (signingPublicKey != null) 'signing_public_key': signingPublicKey,
      if (displayNameEnvelope != null)
        'display_name_envelope': displayNameEnvelope,
      if (rowid != null) 'rowid': rowid,
    });
  }

  TrustedDevicesCompanion copyWith({
    Value<String>? deviceId,
    Value<String>? signingPublicKey,
    Value<String?>? displayNameEnvelope,
    Value<int>? rowid,
  }) {
    return TrustedDevicesCompanion(
      deviceId: deviceId ?? this.deviceId,
      signingPublicKey: signingPublicKey ?? this.signingPublicKey,
      displayNameEnvelope: displayNameEnvelope ?? this.displayNameEnvelope,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (deviceId.present) {
      map['device_id'] = Variable<String>(deviceId.value);
    }
    if (signingPublicKey.present) {
      map['signing_public_key'] = Variable<String>(signingPublicKey.value);
    }
    if (displayNameEnvelope.present) {
      map['display_name_envelope'] = Variable<String>(
        displayNameEnvelope.value,
      );
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TrustedDevicesCompanion(')
          ..write('deviceId: $deviceId, ')
          ..write('signingPublicKey: $signingPublicKey, ')
          ..write('displayNameEnvelope: $displayNameEnvelope, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $DeviceSequencesTable extends DeviceSequences
    with TableInfo<$DeviceSequencesTable, DeviceSequence> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $DeviceSequencesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _deviceIdMeta = const VerificationMeta(
    'deviceId',
  );
  @override
  late final GeneratedColumn<String> deviceId = GeneratedColumn<String>(
    'device_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nextSequenceMeta = const VerificationMeta(
    'nextSequence',
  );
  @override
  late final GeneratedColumn<int> nextSequence = GeneratedColumn<int>(
    'next_sequence',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(1),
  );
  @override
  List<GeneratedColumn> get $columns => [deviceId, nextSequence];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'device_sequences';
  @override
  VerificationContext validateIntegrity(
    Insertable<DeviceSequence> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('device_id')) {
      context.handle(
        _deviceIdMeta,
        deviceId.isAcceptableOrUnknown(data['device_id']!, _deviceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_deviceIdMeta);
    }
    if (data.containsKey('next_sequence')) {
      context.handle(
        _nextSequenceMeta,
        nextSequence.isAcceptableOrUnknown(
          data['next_sequence']!,
          _nextSequenceMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {deviceId};
  @override
  DeviceSequence map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DeviceSequence(
      deviceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}device_id'],
      )!,
      nextSequence: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}next_sequence'],
      )!,
    );
  }

  @override
  $DeviceSequencesTable createAlias(String alias) {
    return $DeviceSequencesTable(attachedDatabase, alias);
  }
}

class DeviceSequence extends DataClass implements Insertable<DeviceSequence> {
  final String deviceId;
  final int nextSequence;
  const DeviceSequence({required this.deviceId, required this.nextSequence});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['device_id'] = Variable<String>(deviceId);
    map['next_sequence'] = Variable<int>(nextSequence);
    return map;
  }

  DeviceSequencesCompanion toCompanion(bool nullToAbsent) {
    return DeviceSequencesCompanion(
      deviceId: Value(deviceId),
      nextSequence: Value(nextSequence),
    );
  }

  factory DeviceSequence.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DeviceSequence(
      deviceId: serializer.fromJson<String>(json['deviceId']),
      nextSequence: serializer.fromJson<int>(json['nextSequence']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'deviceId': serializer.toJson<String>(deviceId),
      'nextSequence': serializer.toJson<int>(nextSequence),
    };
  }

  DeviceSequence copyWith({String? deviceId, int? nextSequence}) =>
      DeviceSequence(
        deviceId: deviceId ?? this.deviceId,
        nextSequence: nextSequence ?? this.nextSequence,
      );
  DeviceSequence copyWithCompanion(DeviceSequencesCompanion data) {
    return DeviceSequence(
      deviceId: data.deviceId.present ? data.deviceId.value : this.deviceId,
      nextSequence: data.nextSequence.present
          ? data.nextSequence.value
          : this.nextSequence,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DeviceSequence(')
          ..write('deviceId: $deviceId, ')
          ..write('nextSequence: $nextSequence')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(deviceId, nextSequence);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DeviceSequence &&
          other.deviceId == this.deviceId &&
          other.nextSequence == this.nextSequence);
}

class DeviceSequencesCompanion extends UpdateCompanion<DeviceSequence> {
  final Value<String> deviceId;
  final Value<int> nextSequence;
  final Value<int> rowid;
  const DeviceSequencesCompanion({
    this.deviceId = const Value.absent(),
    this.nextSequence = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  DeviceSequencesCompanion.insert({
    required String deviceId,
    this.nextSequence = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : deviceId = Value(deviceId);
  static Insertable<DeviceSequence> custom({
    Expression<String>? deviceId,
    Expression<int>? nextSequence,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (deviceId != null) 'device_id': deviceId,
      if (nextSequence != null) 'next_sequence': nextSequence,
      if (rowid != null) 'rowid': rowid,
    });
  }

  DeviceSequencesCompanion copyWith({
    Value<String>? deviceId,
    Value<int>? nextSequence,
    Value<int>? rowid,
  }) {
    return DeviceSequencesCompanion(
      deviceId: deviceId ?? this.deviceId,
      nextSequence: nextSequence ?? this.nextSequence,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (deviceId.present) {
      map['device_id'] = Variable<String>(deviceId.value);
    }
    if (nextSequence.present) {
      map['next_sequence'] = Variable<int>(nextSequence.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('DeviceSequencesCompanion(')
          ..write('deviceId: $deviceId, ')
          ..write('nextSequence: $nextSequence, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $VaultArchiveObjectsTable extends VaultArchiveObjects
    with TableInfo<$VaultArchiveObjectsTable, VaultArchiveObject> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $VaultArchiveObjectsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _vaultIdMeta = const VerificationMeta(
    'vaultId',
  );
  @override
  late final GeneratedColumn<String> vaultId = GeneratedColumn<String>(
    'vault_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _objectIdMeta = const VerificationMeta(
    'objectId',
  );
  @override
  late final GeneratedColumn<String> objectId = GeneratedColumn<String>(
    'object_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _bytesMeta = const VerificationMeta('bytes');
  @override
  late final GeneratedColumn<Uint8List> bytes = GeneratedColumn<Uint8List>(
    'bytes',
    aliasedName,
    false,
    type: DriftSqlType.blob,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sha256Meta = const VerificationMeta('sha256');
  @override
  late final GeneratedColumn<String> sha256 = GeneratedColumn<String>(
    'sha256',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _importedAtMeta = const VerificationMeta(
    'importedAt',
  );
  @override
  late final GeneratedColumn<int> importedAt = GeneratedColumn<int>(
    'imported_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    vaultId,
    objectId,
    bytes,
    sha256,
    importedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'vault_archive_objects';
  @override
  VerificationContext validateIntegrity(
    Insertable<VaultArchiveObject> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('vault_id')) {
      context.handle(
        _vaultIdMeta,
        vaultId.isAcceptableOrUnknown(data['vault_id']!, _vaultIdMeta),
      );
    } else if (isInserting) {
      context.missing(_vaultIdMeta);
    }
    if (data.containsKey('object_id')) {
      context.handle(
        _objectIdMeta,
        objectId.isAcceptableOrUnknown(data['object_id']!, _objectIdMeta),
      );
    } else if (isInserting) {
      context.missing(_objectIdMeta);
    }
    if (data.containsKey('bytes')) {
      context.handle(
        _bytesMeta,
        bytes.isAcceptableOrUnknown(data['bytes']!, _bytesMeta),
      );
    } else if (isInserting) {
      context.missing(_bytesMeta);
    }
    if (data.containsKey('sha256')) {
      context.handle(
        _sha256Meta,
        sha256.isAcceptableOrUnknown(data['sha256']!, _sha256Meta),
      );
    } else if (isInserting) {
      context.missing(_sha256Meta);
    }
    if (data.containsKey('imported_at')) {
      context.handle(
        _importedAtMeta,
        importedAt.isAcceptableOrUnknown(data['imported_at']!, _importedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_importedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {vaultId, objectId};
  @override
  VaultArchiveObject map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return VaultArchiveObject(
      vaultId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}vault_id'],
      )!,
      objectId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}object_id'],
      )!,
      bytes: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}bytes'],
      )!,
      sha256: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sha256'],
      )!,
      importedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}imported_at'],
      )!,
    );
  }

  @override
  $VaultArchiveObjectsTable createAlias(String alias) {
    return $VaultArchiveObjectsTable(attachedDatabase, alias);
  }
}

class VaultArchiveObject extends DataClass
    implements Insertable<VaultArchiveObject> {
  final String vaultId;
  final String objectId;
  final Uint8List bytes;
  final String sha256;
  final int importedAt;
  const VaultArchiveObject({
    required this.vaultId,
    required this.objectId,
    required this.bytes,
    required this.sha256,
    required this.importedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['vault_id'] = Variable<String>(vaultId);
    map['object_id'] = Variable<String>(objectId);
    map['bytes'] = Variable<Uint8List>(bytes);
    map['sha256'] = Variable<String>(sha256);
    map['imported_at'] = Variable<int>(importedAt);
    return map;
  }

  VaultArchiveObjectsCompanion toCompanion(bool nullToAbsent) {
    return VaultArchiveObjectsCompanion(
      vaultId: Value(vaultId),
      objectId: Value(objectId),
      bytes: Value(bytes),
      sha256: Value(sha256),
      importedAt: Value(importedAt),
    );
  }

  factory VaultArchiveObject.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return VaultArchiveObject(
      vaultId: serializer.fromJson<String>(json['vaultId']),
      objectId: serializer.fromJson<String>(json['objectId']),
      bytes: serializer.fromJson<Uint8List>(json['bytes']),
      sha256: serializer.fromJson<String>(json['sha256']),
      importedAt: serializer.fromJson<int>(json['importedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'vaultId': serializer.toJson<String>(vaultId),
      'objectId': serializer.toJson<String>(objectId),
      'bytes': serializer.toJson<Uint8List>(bytes),
      'sha256': serializer.toJson<String>(sha256),
      'importedAt': serializer.toJson<int>(importedAt),
    };
  }

  VaultArchiveObject copyWith({
    String? vaultId,
    String? objectId,
    Uint8List? bytes,
    String? sha256,
    int? importedAt,
  }) => VaultArchiveObject(
    vaultId: vaultId ?? this.vaultId,
    objectId: objectId ?? this.objectId,
    bytes: bytes ?? this.bytes,
    sha256: sha256 ?? this.sha256,
    importedAt: importedAt ?? this.importedAt,
  );
  VaultArchiveObject copyWithCompanion(VaultArchiveObjectsCompanion data) {
    return VaultArchiveObject(
      vaultId: data.vaultId.present ? data.vaultId.value : this.vaultId,
      objectId: data.objectId.present ? data.objectId.value : this.objectId,
      bytes: data.bytes.present ? data.bytes.value : this.bytes,
      sha256: data.sha256.present ? data.sha256.value : this.sha256,
      importedAt: data.importedAt.present
          ? data.importedAt.value
          : this.importedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('VaultArchiveObject(')
          ..write('vaultId: $vaultId, ')
          ..write('objectId: $objectId, ')
          ..write('bytes: $bytes, ')
          ..write('sha256: $sha256, ')
          ..write('importedAt: $importedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    vaultId,
    objectId,
    $driftBlobEquality.hash(bytes),
    sha256,
    importedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is VaultArchiveObject &&
          other.vaultId == this.vaultId &&
          other.objectId == this.objectId &&
          $driftBlobEquality.equals(other.bytes, this.bytes) &&
          other.sha256 == this.sha256 &&
          other.importedAt == this.importedAt);
}

class VaultArchiveObjectsCompanion extends UpdateCompanion<VaultArchiveObject> {
  final Value<String> vaultId;
  final Value<String> objectId;
  final Value<Uint8List> bytes;
  final Value<String> sha256;
  final Value<int> importedAt;
  final Value<int> rowid;
  const VaultArchiveObjectsCompanion({
    this.vaultId = const Value.absent(),
    this.objectId = const Value.absent(),
    this.bytes = const Value.absent(),
    this.sha256 = const Value.absent(),
    this.importedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  VaultArchiveObjectsCompanion.insert({
    required String vaultId,
    required String objectId,
    required Uint8List bytes,
    required String sha256,
    required int importedAt,
    this.rowid = const Value.absent(),
  }) : vaultId = Value(vaultId),
       objectId = Value(objectId),
       bytes = Value(bytes),
       sha256 = Value(sha256),
       importedAt = Value(importedAt);
  static Insertable<VaultArchiveObject> custom({
    Expression<String>? vaultId,
    Expression<String>? objectId,
    Expression<Uint8List>? bytes,
    Expression<String>? sha256,
    Expression<int>? importedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (vaultId != null) 'vault_id': vaultId,
      if (objectId != null) 'object_id': objectId,
      if (bytes != null) 'bytes': bytes,
      if (sha256 != null) 'sha256': sha256,
      if (importedAt != null) 'imported_at': importedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  VaultArchiveObjectsCompanion copyWith({
    Value<String>? vaultId,
    Value<String>? objectId,
    Value<Uint8List>? bytes,
    Value<String>? sha256,
    Value<int>? importedAt,
    Value<int>? rowid,
  }) {
    return VaultArchiveObjectsCompanion(
      vaultId: vaultId ?? this.vaultId,
      objectId: objectId ?? this.objectId,
      bytes: bytes ?? this.bytes,
      sha256: sha256 ?? this.sha256,
      importedAt: importedAt ?? this.importedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (vaultId.present) {
      map['vault_id'] = Variable<String>(vaultId.value);
    }
    if (objectId.present) {
      map['object_id'] = Variable<String>(objectId.value);
    }
    if (bytes.present) {
      map['bytes'] = Variable<Uint8List>(bytes.value);
    }
    if (sha256.present) {
      map['sha256'] = Variable<String>(sha256.value);
    }
    if (importedAt.present) {
      map['imported_at'] = Variable<int>(importedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('VaultArchiveObjectsCompanion(')
          ..write('vaultId: $vaultId, ')
          ..write('objectId: $objectId, ')
          ..write('bytes: $bytes, ')
          ..write('sha256: $sha256, ')
          ..write('importedAt: $importedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $BlobJobsTable extends BlobJobs with TableInfo<$BlobJobsTable, BlobJob> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $BlobJobsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _jobIdMeta = const VerificationMeta('jobId');
  @override
  late final GeneratedColumn<String> jobId = GeneratedColumn<String>(
    'job_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _vaultIdMeta = const VerificationMeta(
    'vaultId',
  );
  @override
  late final GeneratedColumn<String> vaultId = GeneratedColumn<String>(
    'vault_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _recordIdMeta = const VerificationMeta(
    'recordId',
  );
  @override
  late final GeneratedColumn<String> recordId = GeneratedColumn<String>(
    'record_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _instanceIdMeta = const VerificationMeta(
    'instanceId',
  );
  @override
  late final GeneratedColumn<String> instanceId = GeneratedColumn<String>(
    'instance_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _serverSpaceIdMeta = const VerificationMeta(
    'serverSpaceId',
  );
  @override
  late final GeneratedColumn<String> serverSpaceId = GeneratedColumn<String>(
    'server_space_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _blobIdMeta = const VerificationMeta('blobId');
  @override
  late final GeneratedColumn<String> blobId = GeneratedColumn<String>(
    'blob_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _directionMeta = const VerificationMeta(
    'direction',
  );
  @override
  late final GeneratedColumn<String> direction = GeneratedColumn<String>(
    'direction',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _stateMeta = const VerificationMeta('state');
  @override
  late final GeneratedColumn<String> state = GeneratedColumn<String>(
    'state',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _totalObjectsMeta = const VerificationMeta(
    'totalObjects',
  );
  @override
  late final GeneratedColumn<int> totalObjects = GeneratedColumn<int>(
    'total_objects',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _attemptCountMeta = const VerificationMeta(
    'attemptCount',
  );
  @override
  late final GeneratedColumn<int> attemptCount = GeneratedColumn<int>(
    'attempt_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _lastErrorCodeMeta = const VerificationMeta(
    'lastErrorCode',
  );
  @override
  late final GeneratedColumn<String> lastErrorCode = GeneratedColumn<String>(
    'last_error_code',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    jobId,
    vaultId,
    recordId,
    instanceId,
    serverSpaceId,
    blobId,
    direction,
    state,
    totalObjects,
    attemptCount,
    lastErrorCode,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'blob_jobs';
  @override
  VerificationContext validateIntegrity(
    Insertable<BlobJob> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('job_id')) {
      context.handle(
        _jobIdMeta,
        jobId.isAcceptableOrUnknown(data['job_id']!, _jobIdMeta),
      );
    } else if (isInserting) {
      context.missing(_jobIdMeta);
    }
    if (data.containsKey('vault_id')) {
      context.handle(
        _vaultIdMeta,
        vaultId.isAcceptableOrUnknown(data['vault_id']!, _vaultIdMeta),
      );
    } else if (isInserting) {
      context.missing(_vaultIdMeta);
    }
    if (data.containsKey('record_id')) {
      context.handle(
        _recordIdMeta,
        recordId.isAcceptableOrUnknown(data['record_id']!, _recordIdMeta),
      );
    } else if (isInserting) {
      context.missing(_recordIdMeta);
    }
    if (data.containsKey('instance_id')) {
      context.handle(
        _instanceIdMeta,
        instanceId.isAcceptableOrUnknown(data['instance_id']!, _instanceIdMeta),
      );
    }
    if (data.containsKey('server_space_id')) {
      context.handle(
        _serverSpaceIdMeta,
        serverSpaceId.isAcceptableOrUnknown(
          data['server_space_id']!,
          _serverSpaceIdMeta,
        ),
      );
    }
    if (data.containsKey('blob_id')) {
      context.handle(
        _blobIdMeta,
        blobId.isAcceptableOrUnknown(data['blob_id']!, _blobIdMeta),
      );
    } else if (isInserting) {
      context.missing(_blobIdMeta);
    }
    if (data.containsKey('direction')) {
      context.handle(
        _directionMeta,
        direction.isAcceptableOrUnknown(data['direction']!, _directionMeta),
      );
    } else if (isInserting) {
      context.missing(_directionMeta);
    }
    if (data.containsKey('state')) {
      context.handle(
        _stateMeta,
        state.isAcceptableOrUnknown(data['state']!, _stateMeta),
      );
    } else if (isInserting) {
      context.missing(_stateMeta);
    }
    if (data.containsKey('total_objects')) {
      context.handle(
        _totalObjectsMeta,
        totalObjects.isAcceptableOrUnknown(
          data['total_objects']!,
          _totalObjectsMeta,
        ),
      );
    }
    if (data.containsKey('attempt_count')) {
      context.handle(
        _attemptCountMeta,
        attemptCount.isAcceptableOrUnknown(
          data['attempt_count']!,
          _attemptCountMeta,
        ),
      );
    }
    if (data.containsKey('last_error_code')) {
      context.handle(
        _lastErrorCodeMeta,
        lastErrorCode.isAcceptableOrUnknown(
          data['last_error_code']!,
          _lastErrorCodeMeta,
        ),
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
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {jobId};
  @override
  BlobJob map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return BlobJob(
      jobId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}job_id'],
      )!,
      vaultId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}vault_id'],
      )!,
      recordId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}record_id'],
      )!,
      instanceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}instance_id'],
      ),
      serverSpaceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_space_id'],
      ),
      blobId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}blob_id'],
      )!,
      direction: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}direction'],
      )!,
      state: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}state'],
      )!,
      totalObjects: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}total_objects'],
      )!,
      attemptCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}attempt_count'],
      )!,
      lastErrorCode: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}last_error_code'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $BlobJobsTable createAlias(String alias) {
    return $BlobJobsTable(attachedDatabase, alias);
  }
}

class BlobJob extends DataClass implements Insertable<BlobJob> {
  final String jobId;
  final String vaultId;
  final String recordId;
  final String? instanceId;
  final String? serverSpaceId;
  final String blobId;
  final String direction;
  final String state;
  final int totalObjects;
  final int attemptCount;
  final String? lastErrorCode;
  final int createdAt;
  final int updatedAt;
  const BlobJob({
    required this.jobId,
    required this.vaultId,
    required this.recordId,
    this.instanceId,
    this.serverSpaceId,
    required this.blobId,
    required this.direction,
    required this.state,
    required this.totalObjects,
    required this.attemptCount,
    this.lastErrorCode,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['job_id'] = Variable<String>(jobId);
    map['vault_id'] = Variable<String>(vaultId);
    map['record_id'] = Variable<String>(recordId);
    if (!nullToAbsent || instanceId != null) {
      map['instance_id'] = Variable<String>(instanceId);
    }
    if (!nullToAbsent || serverSpaceId != null) {
      map['server_space_id'] = Variable<String>(serverSpaceId);
    }
    map['blob_id'] = Variable<String>(blobId);
    map['direction'] = Variable<String>(direction);
    map['state'] = Variable<String>(state);
    map['total_objects'] = Variable<int>(totalObjects);
    map['attempt_count'] = Variable<int>(attemptCount);
    if (!nullToAbsent || lastErrorCode != null) {
      map['last_error_code'] = Variable<String>(lastErrorCode);
    }
    map['created_at'] = Variable<int>(createdAt);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  BlobJobsCompanion toCompanion(bool nullToAbsent) {
    return BlobJobsCompanion(
      jobId: Value(jobId),
      vaultId: Value(vaultId),
      recordId: Value(recordId),
      instanceId: instanceId == null && nullToAbsent
          ? const Value.absent()
          : Value(instanceId),
      serverSpaceId: serverSpaceId == null && nullToAbsent
          ? const Value.absent()
          : Value(serverSpaceId),
      blobId: Value(blobId),
      direction: Value(direction),
      state: Value(state),
      totalObjects: Value(totalObjects),
      attemptCount: Value(attemptCount),
      lastErrorCode: lastErrorCode == null && nullToAbsent
          ? const Value.absent()
          : Value(lastErrorCode),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory BlobJob.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return BlobJob(
      jobId: serializer.fromJson<String>(json['jobId']),
      vaultId: serializer.fromJson<String>(json['vaultId']),
      recordId: serializer.fromJson<String>(json['recordId']),
      instanceId: serializer.fromJson<String?>(json['instanceId']),
      serverSpaceId: serializer.fromJson<String?>(json['serverSpaceId']),
      blobId: serializer.fromJson<String>(json['blobId']),
      direction: serializer.fromJson<String>(json['direction']),
      state: serializer.fromJson<String>(json['state']),
      totalObjects: serializer.fromJson<int>(json['totalObjects']),
      attemptCount: serializer.fromJson<int>(json['attemptCount']),
      lastErrorCode: serializer.fromJson<String?>(json['lastErrorCode']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'jobId': serializer.toJson<String>(jobId),
      'vaultId': serializer.toJson<String>(vaultId),
      'recordId': serializer.toJson<String>(recordId),
      'instanceId': serializer.toJson<String?>(instanceId),
      'serverSpaceId': serializer.toJson<String?>(serverSpaceId),
      'blobId': serializer.toJson<String>(blobId),
      'direction': serializer.toJson<String>(direction),
      'state': serializer.toJson<String>(state),
      'totalObjects': serializer.toJson<int>(totalObjects),
      'attemptCount': serializer.toJson<int>(attemptCount),
      'lastErrorCode': serializer.toJson<String?>(lastErrorCode),
      'createdAt': serializer.toJson<int>(createdAt),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  BlobJob copyWith({
    String? jobId,
    String? vaultId,
    String? recordId,
    Value<String?> instanceId = const Value.absent(),
    Value<String?> serverSpaceId = const Value.absent(),
    String? blobId,
    String? direction,
    String? state,
    int? totalObjects,
    int? attemptCount,
    Value<String?> lastErrorCode = const Value.absent(),
    int? createdAt,
    int? updatedAt,
  }) => BlobJob(
    jobId: jobId ?? this.jobId,
    vaultId: vaultId ?? this.vaultId,
    recordId: recordId ?? this.recordId,
    instanceId: instanceId.present ? instanceId.value : this.instanceId,
    serverSpaceId: serverSpaceId.present
        ? serverSpaceId.value
        : this.serverSpaceId,
    blobId: blobId ?? this.blobId,
    direction: direction ?? this.direction,
    state: state ?? this.state,
    totalObjects: totalObjects ?? this.totalObjects,
    attemptCount: attemptCount ?? this.attemptCount,
    lastErrorCode: lastErrorCode.present
        ? lastErrorCode.value
        : this.lastErrorCode,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  BlobJob copyWithCompanion(BlobJobsCompanion data) {
    return BlobJob(
      jobId: data.jobId.present ? data.jobId.value : this.jobId,
      vaultId: data.vaultId.present ? data.vaultId.value : this.vaultId,
      recordId: data.recordId.present ? data.recordId.value : this.recordId,
      instanceId: data.instanceId.present
          ? data.instanceId.value
          : this.instanceId,
      serverSpaceId: data.serverSpaceId.present
          ? data.serverSpaceId.value
          : this.serverSpaceId,
      blobId: data.blobId.present ? data.blobId.value : this.blobId,
      direction: data.direction.present ? data.direction.value : this.direction,
      state: data.state.present ? data.state.value : this.state,
      totalObjects: data.totalObjects.present
          ? data.totalObjects.value
          : this.totalObjects,
      attemptCount: data.attemptCount.present
          ? data.attemptCount.value
          : this.attemptCount,
      lastErrorCode: data.lastErrorCode.present
          ? data.lastErrorCode.value
          : this.lastErrorCode,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('BlobJob(')
          ..write('jobId: $jobId, ')
          ..write('vaultId: $vaultId, ')
          ..write('recordId: $recordId, ')
          ..write('instanceId: $instanceId, ')
          ..write('serverSpaceId: $serverSpaceId, ')
          ..write('blobId: $blobId, ')
          ..write('direction: $direction, ')
          ..write('state: $state, ')
          ..write('totalObjects: $totalObjects, ')
          ..write('attemptCount: $attemptCount, ')
          ..write('lastErrorCode: $lastErrorCode, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    jobId,
    vaultId,
    recordId,
    instanceId,
    serverSpaceId,
    blobId,
    direction,
    state,
    totalObjects,
    attemptCount,
    lastErrorCode,
    createdAt,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is BlobJob &&
          other.jobId == this.jobId &&
          other.vaultId == this.vaultId &&
          other.recordId == this.recordId &&
          other.instanceId == this.instanceId &&
          other.serverSpaceId == this.serverSpaceId &&
          other.blobId == this.blobId &&
          other.direction == this.direction &&
          other.state == this.state &&
          other.totalObjects == this.totalObjects &&
          other.attemptCount == this.attemptCount &&
          other.lastErrorCode == this.lastErrorCode &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class BlobJobsCompanion extends UpdateCompanion<BlobJob> {
  final Value<String> jobId;
  final Value<String> vaultId;
  final Value<String> recordId;
  final Value<String?> instanceId;
  final Value<String?> serverSpaceId;
  final Value<String> blobId;
  final Value<String> direction;
  final Value<String> state;
  final Value<int> totalObjects;
  final Value<int> attemptCount;
  final Value<String?> lastErrorCode;
  final Value<int> createdAt;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const BlobJobsCompanion({
    this.jobId = const Value.absent(),
    this.vaultId = const Value.absent(),
    this.recordId = const Value.absent(),
    this.instanceId = const Value.absent(),
    this.serverSpaceId = const Value.absent(),
    this.blobId = const Value.absent(),
    this.direction = const Value.absent(),
    this.state = const Value.absent(),
    this.totalObjects = const Value.absent(),
    this.attemptCount = const Value.absent(),
    this.lastErrorCode = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  BlobJobsCompanion.insert({
    required String jobId,
    required String vaultId,
    required String recordId,
    this.instanceId = const Value.absent(),
    this.serverSpaceId = const Value.absent(),
    required String blobId,
    required String direction,
    required String state,
    this.totalObjects = const Value.absent(),
    this.attemptCount = const Value.absent(),
    this.lastErrorCode = const Value.absent(),
    required int createdAt,
    required int updatedAt,
    this.rowid = const Value.absent(),
  }) : jobId = Value(jobId),
       vaultId = Value(vaultId),
       recordId = Value(recordId),
       blobId = Value(blobId),
       direction = Value(direction),
       state = Value(state),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<BlobJob> custom({
    Expression<String>? jobId,
    Expression<String>? vaultId,
    Expression<String>? recordId,
    Expression<String>? instanceId,
    Expression<String>? serverSpaceId,
    Expression<String>? blobId,
    Expression<String>? direction,
    Expression<String>? state,
    Expression<int>? totalObjects,
    Expression<int>? attemptCount,
    Expression<String>? lastErrorCode,
    Expression<int>? createdAt,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (jobId != null) 'job_id': jobId,
      if (vaultId != null) 'vault_id': vaultId,
      if (recordId != null) 'record_id': recordId,
      if (instanceId != null) 'instance_id': instanceId,
      if (serverSpaceId != null) 'server_space_id': serverSpaceId,
      if (blobId != null) 'blob_id': blobId,
      if (direction != null) 'direction': direction,
      if (state != null) 'state': state,
      if (totalObjects != null) 'total_objects': totalObjects,
      if (attemptCount != null) 'attempt_count': attemptCount,
      if (lastErrorCode != null) 'last_error_code': lastErrorCode,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  BlobJobsCompanion copyWith({
    Value<String>? jobId,
    Value<String>? vaultId,
    Value<String>? recordId,
    Value<String?>? instanceId,
    Value<String?>? serverSpaceId,
    Value<String>? blobId,
    Value<String>? direction,
    Value<String>? state,
    Value<int>? totalObjects,
    Value<int>? attemptCount,
    Value<String?>? lastErrorCode,
    Value<int>? createdAt,
    Value<int>? updatedAt,
    Value<int>? rowid,
  }) {
    return BlobJobsCompanion(
      jobId: jobId ?? this.jobId,
      vaultId: vaultId ?? this.vaultId,
      recordId: recordId ?? this.recordId,
      instanceId: instanceId ?? this.instanceId,
      serverSpaceId: serverSpaceId ?? this.serverSpaceId,
      blobId: blobId ?? this.blobId,
      direction: direction ?? this.direction,
      state: state ?? this.state,
      totalObjects: totalObjects ?? this.totalObjects,
      attemptCount: attemptCount ?? this.attemptCount,
      lastErrorCode: lastErrorCode ?? this.lastErrorCode,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (jobId.present) {
      map['job_id'] = Variable<String>(jobId.value);
    }
    if (vaultId.present) {
      map['vault_id'] = Variable<String>(vaultId.value);
    }
    if (recordId.present) {
      map['record_id'] = Variable<String>(recordId.value);
    }
    if (instanceId.present) {
      map['instance_id'] = Variable<String>(instanceId.value);
    }
    if (serverSpaceId.present) {
      map['server_space_id'] = Variable<String>(serverSpaceId.value);
    }
    if (blobId.present) {
      map['blob_id'] = Variable<String>(blobId.value);
    }
    if (direction.present) {
      map['direction'] = Variable<String>(direction.value);
    }
    if (state.present) {
      map['state'] = Variable<String>(state.value);
    }
    if (totalObjects.present) {
      map['total_objects'] = Variable<int>(totalObjects.value);
    }
    if (attemptCount.present) {
      map['attempt_count'] = Variable<int>(attemptCount.value);
    }
    if (lastErrorCode.present) {
      map['last_error_code'] = Variable<String>(lastErrorCode.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('BlobJobsCompanion(')
          ..write('jobId: $jobId, ')
          ..write('vaultId: $vaultId, ')
          ..write('recordId: $recordId, ')
          ..write('instanceId: $instanceId, ')
          ..write('serverSpaceId: $serverSpaceId, ')
          ..write('blobId: $blobId, ')
          ..write('direction: $direction, ')
          ..write('state: $state, ')
          ..write('totalObjects: $totalObjects, ')
          ..write('attemptCount: $attemptCount, ')
          ..write('lastErrorCode: $lastErrorCode, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $BlobJobObjectsTable extends BlobJobObjects
    with TableInfo<$BlobJobObjectsTable, BlobJobObject> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $BlobJobObjectsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _jobIdMeta = const VerificationMeta('jobId');
  @override
  late final GeneratedColumn<String> jobId = GeneratedColumn<String>(
    'job_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _objectIdMeta = const VerificationMeta(
    'objectId',
  );
  @override
  late final GeneratedColumn<String> objectId = GeneratedColumn<String>(
    'object_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sha256Meta = const VerificationMeta('sha256');
  @override
  late final GeneratedColumn<String> sha256 = GeneratedColumn<String>(
    'sha256',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sizeMeta = const VerificationMeta('size');
  @override
  late final GeneratedColumn<int> size = GeneratedColumn<int>(
    'size',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _bytesMeta = const VerificationMeta('bytes');
  @override
  late final GeneratedColumn<Uint8List> bytes = GeneratedColumn<Uint8List>(
    'bytes',
    aliasedName,
    true,
    type: DriftSqlType.blob,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _uploadIdMeta = const VerificationMeta(
    'uploadId',
  );
  @override
  late final GeneratedColumn<String> uploadId = GeneratedColumn<String>(
    'upload_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _uploadChunkSizeMeta = const VerificationMeta(
    'uploadChunkSize',
  );
  @override
  late final GeneratedColumn<int> uploadChunkSize = GeneratedColumn<int>(
    'upload_chunk_size',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _nextChunkIndexMeta = const VerificationMeta(
    'nextChunkIndex',
  );
  @override
  late final GeneratedColumn<int> nextChunkIndex = GeneratedColumn<int>(
    'next_chunk_index',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _transferredMeta = const VerificationMeta(
    'transferred',
  );
  @override
  late final GeneratedColumn<bool> transferred = GeneratedColumn<bool>(
    'transferred',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("transferred" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  @override
  List<GeneratedColumn> get $columns => [
    jobId,
    objectId,
    sha256,
    size,
    bytes,
    uploadId,
    uploadChunkSize,
    nextChunkIndex,
    transferred,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'blob_job_objects';
  @override
  VerificationContext validateIntegrity(
    Insertable<BlobJobObject> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('job_id')) {
      context.handle(
        _jobIdMeta,
        jobId.isAcceptableOrUnknown(data['job_id']!, _jobIdMeta),
      );
    } else if (isInserting) {
      context.missing(_jobIdMeta);
    }
    if (data.containsKey('object_id')) {
      context.handle(
        _objectIdMeta,
        objectId.isAcceptableOrUnknown(data['object_id']!, _objectIdMeta),
      );
    } else if (isInserting) {
      context.missing(_objectIdMeta);
    }
    if (data.containsKey('sha256')) {
      context.handle(
        _sha256Meta,
        sha256.isAcceptableOrUnknown(data['sha256']!, _sha256Meta),
      );
    } else if (isInserting) {
      context.missing(_sha256Meta);
    }
    if (data.containsKey('size')) {
      context.handle(
        _sizeMeta,
        size.isAcceptableOrUnknown(data['size']!, _sizeMeta),
      );
    } else if (isInserting) {
      context.missing(_sizeMeta);
    }
    if (data.containsKey('bytes')) {
      context.handle(
        _bytesMeta,
        bytes.isAcceptableOrUnknown(data['bytes']!, _bytesMeta),
      );
    }
    if (data.containsKey('upload_id')) {
      context.handle(
        _uploadIdMeta,
        uploadId.isAcceptableOrUnknown(data['upload_id']!, _uploadIdMeta),
      );
    }
    if (data.containsKey('upload_chunk_size')) {
      context.handle(
        _uploadChunkSizeMeta,
        uploadChunkSize.isAcceptableOrUnknown(
          data['upload_chunk_size']!,
          _uploadChunkSizeMeta,
        ),
      );
    }
    if (data.containsKey('next_chunk_index')) {
      context.handle(
        _nextChunkIndexMeta,
        nextChunkIndex.isAcceptableOrUnknown(
          data['next_chunk_index']!,
          _nextChunkIndexMeta,
        ),
      );
    }
    if (data.containsKey('transferred')) {
      context.handle(
        _transferredMeta,
        transferred.isAcceptableOrUnknown(
          data['transferred']!,
          _transferredMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {jobId, objectId};
  @override
  BlobJobObject map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return BlobJobObject(
      jobId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}job_id'],
      )!,
      objectId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}object_id'],
      )!,
      sha256: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sha256'],
      )!,
      size: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}size'],
      )!,
      bytes: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}bytes'],
      ),
      uploadId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}upload_id'],
      ),
      uploadChunkSize: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}upload_chunk_size'],
      ),
      nextChunkIndex: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}next_chunk_index'],
      )!,
      transferred: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}transferred'],
      )!,
    );
  }

  @override
  $BlobJobObjectsTable createAlias(String alias) {
    return $BlobJobObjectsTable(attachedDatabase, alias);
  }
}

class BlobJobObject extends DataClass implements Insertable<BlobJobObject> {
  final String jobId;
  final String objectId;
  final String sha256;
  final int size;
  final Uint8List? bytes;
  final String? uploadId;
  final int? uploadChunkSize;
  final int nextChunkIndex;
  final bool transferred;
  const BlobJobObject({
    required this.jobId,
    required this.objectId,
    required this.sha256,
    required this.size,
    this.bytes,
    this.uploadId,
    this.uploadChunkSize,
    required this.nextChunkIndex,
    required this.transferred,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['job_id'] = Variable<String>(jobId);
    map['object_id'] = Variable<String>(objectId);
    map['sha256'] = Variable<String>(sha256);
    map['size'] = Variable<int>(size);
    if (!nullToAbsent || bytes != null) {
      map['bytes'] = Variable<Uint8List>(bytes);
    }
    if (!nullToAbsent || uploadId != null) {
      map['upload_id'] = Variable<String>(uploadId);
    }
    if (!nullToAbsent || uploadChunkSize != null) {
      map['upload_chunk_size'] = Variable<int>(uploadChunkSize);
    }
    map['next_chunk_index'] = Variable<int>(nextChunkIndex);
    map['transferred'] = Variable<bool>(transferred);
    return map;
  }

  BlobJobObjectsCompanion toCompanion(bool nullToAbsent) {
    return BlobJobObjectsCompanion(
      jobId: Value(jobId),
      objectId: Value(objectId),
      sha256: Value(sha256),
      size: Value(size),
      bytes: bytes == null && nullToAbsent
          ? const Value.absent()
          : Value(bytes),
      uploadId: uploadId == null && nullToAbsent
          ? const Value.absent()
          : Value(uploadId),
      uploadChunkSize: uploadChunkSize == null && nullToAbsent
          ? const Value.absent()
          : Value(uploadChunkSize),
      nextChunkIndex: Value(nextChunkIndex),
      transferred: Value(transferred),
    );
  }

  factory BlobJobObject.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return BlobJobObject(
      jobId: serializer.fromJson<String>(json['jobId']),
      objectId: serializer.fromJson<String>(json['objectId']),
      sha256: serializer.fromJson<String>(json['sha256']),
      size: serializer.fromJson<int>(json['size']),
      bytes: serializer.fromJson<Uint8List?>(json['bytes']),
      uploadId: serializer.fromJson<String?>(json['uploadId']),
      uploadChunkSize: serializer.fromJson<int?>(json['uploadChunkSize']),
      nextChunkIndex: serializer.fromJson<int>(json['nextChunkIndex']),
      transferred: serializer.fromJson<bool>(json['transferred']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'jobId': serializer.toJson<String>(jobId),
      'objectId': serializer.toJson<String>(objectId),
      'sha256': serializer.toJson<String>(sha256),
      'size': serializer.toJson<int>(size),
      'bytes': serializer.toJson<Uint8List?>(bytes),
      'uploadId': serializer.toJson<String?>(uploadId),
      'uploadChunkSize': serializer.toJson<int?>(uploadChunkSize),
      'nextChunkIndex': serializer.toJson<int>(nextChunkIndex),
      'transferred': serializer.toJson<bool>(transferred),
    };
  }

  BlobJobObject copyWith({
    String? jobId,
    String? objectId,
    String? sha256,
    int? size,
    Value<Uint8List?> bytes = const Value.absent(),
    Value<String?> uploadId = const Value.absent(),
    Value<int?> uploadChunkSize = const Value.absent(),
    int? nextChunkIndex,
    bool? transferred,
  }) => BlobJobObject(
    jobId: jobId ?? this.jobId,
    objectId: objectId ?? this.objectId,
    sha256: sha256 ?? this.sha256,
    size: size ?? this.size,
    bytes: bytes.present ? bytes.value : this.bytes,
    uploadId: uploadId.present ? uploadId.value : this.uploadId,
    uploadChunkSize: uploadChunkSize.present
        ? uploadChunkSize.value
        : this.uploadChunkSize,
    nextChunkIndex: nextChunkIndex ?? this.nextChunkIndex,
    transferred: transferred ?? this.transferred,
  );
  BlobJobObject copyWithCompanion(BlobJobObjectsCompanion data) {
    return BlobJobObject(
      jobId: data.jobId.present ? data.jobId.value : this.jobId,
      objectId: data.objectId.present ? data.objectId.value : this.objectId,
      sha256: data.sha256.present ? data.sha256.value : this.sha256,
      size: data.size.present ? data.size.value : this.size,
      bytes: data.bytes.present ? data.bytes.value : this.bytes,
      uploadId: data.uploadId.present ? data.uploadId.value : this.uploadId,
      uploadChunkSize: data.uploadChunkSize.present
          ? data.uploadChunkSize.value
          : this.uploadChunkSize,
      nextChunkIndex: data.nextChunkIndex.present
          ? data.nextChunkIndex.value
          : this.nextChunkIndex,
      transferred: data.transferred.present
          ? data.transferred.value
          : this.transferred,
    );
  }

  @override
  String toString() {
    return (StringBuffer('BlobJobObject(')
          ..write('jobId: $jobId, ')
          ..write('objectId: $objectId, ')
          ..write('sha256: $sha256, ')
          ..write('size: $size, ')
          ..write('bytes: $bytes, ')
          ..write('uploadId: $uploadId, ')
          ..write('uploadChunkSize: $uploadChunkSize, ')
          ..write('nextChunkIndex: $nextChunkIndex, ')
          ..write('transferred: $transferred')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    jobId,
    objectId,
    sha256,
    size,
    $driftBlobEquality.hash(bytes),
    uploadId,
    uploadChunkSize,
    nextChunkIndex,
    transferred,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is BlobJobObject &&
          other.jobId == this.jobId &&
          other.objectId == this.objectId &&
          other.sha256 == this.sha256 &&
          other.size == this.size &&
          $driftBlobEquality.equals(other.bytes, this.bytes) &&
          other.uploadId == this.uploadId &&
          other.uploadChunkSize == this.uploadChunkSize &&
          other.nextChunkIndex == this.nextChunkIndex &&
          other.transferred == this.transferred);
}

class BlobJobObjectsCompanion extends UpdateCompanion<BlobJobObject> {
  final Value<String> jobId;
  final Value<String> objectId;
  final Value<String> sha256;
  final Value<int> size;
  final Value<Uint8List?> bytes;
  final Value<String?> uploadId;
  final Value<int?> uploadChunkSize;
  final Value<int> nextChunkIndex;
  final Value<bool> transferred;
  final Value<int> rowid;
  const BlobJobObjectsCompanion({
    this.jobId = const Value.absent(),
    this.objectId = const Value.absent(),
    this.sha256 = const Value.absent(),
    this.size = const Value.absent(),
    this.bytes = const Value.absent(),
    this.uploadId = const Value.absent(),
    this.uploadChunkSize = const Value.absent(),
    this.nextChunkIndex = const Value.absent(),
    this.transferred = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  BlobJobObjectsCompanion.insert({
    required String jobId,
    required String objectId,
    required String sha256,
    required int size,
    this.bytes = const Value.absent(),
    this.uploadId = const Value.absent(),
    this.uploadChunkSize = const Value.absent(),
    this.nextChunkIndex = const Value.absent(),
    this.transferred = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : jobId = Value(jobId),
       objectId = Value(objectId),
       sha256 = Value(sha256),
       size = Value(size);
  static Insertable<BlobJobObject> custom({
    Expression<String>? jobId,
    Expression<String>? objectId,
    Expression<String>? sha256,
    Expression<int>? size,
    Expression<Uint8List>? bytes,
    Expression<String>? uploadId,
    Expression<int>? uploadChunkSize,
    Expression<int>? nextChunkIndex,
    Expression<bool>? transferred,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (jobId != null) 'job_id': jobId,
      if (objectId != null) 'object_id': objectId,
      if (sha256 != null) 'sha256': sha256,
      if (size != null) 'size': size,
      if (bytes != null) 'bytes': bytes,
      if (uploadId != null) 'upload_id': uploadId,
      if (uploadChunkSize != null) 'upload_chunk_size': uploadChunkSize,
      if (nextChunkIndex != null) 'next_chunk_index': nextChunkIndex,
      if (transferred != null) 'transferred': transferred,
      if (rowid != null) 'rowid': rowid,
    });
  }

  BlobJobObjectsCompanion copyWith({
    Value<String>? jobId,
    Value<String>? objectId,
    Value<String>? sha256,
    Value<int>? size,
    Value<Uint8List?>? bytes,
    Value<String?>? uploadId,
    Value<int?>? uploadChunkSize,
    Value<int>? nextChunkIndex,
    Value<bool>? transferred,
    Value<int>? rowid,
  }) {
    return BlobJobObjectsCompanion(
      jobId: jobId ?? this.jobId,
      objectId: objectId ?? this.objectId,
      sha256: sha256 ?? this.sha256,
      size: size ?? this.size,
      bytes: bytes ?? this.bytes,
      uploadId: uploadId ?? this.uploadId,
      uploadChunkSize: uploadChunkSize ?? this.uploadChunkSize,
      nextChunkIndex: nextChunkIndex ?? this.nextChunkIndex,
      transferred: transferred ?? this.transferred,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (jobId.present) {
      map['job_id'] = Variable<String>(jobId.value);
    }
    if (objectId.present) {
      map['object_id'] = Variable<String>(objectId.value);
    }
    if (sha256.present) {
      map['sha256'] = Variable<String>(sha256.value);
    }
    if (size.present) {
      map['size'] = Variable<int>(size.value);
    }
    if (bytes.present) {
      map['bytes'] = Variable<Uint8List>(bytes.value);
    }
    if (uploadId.present) {
      map['upload_id'] = Variable<String>(uploadId.value);
    }
    if (uploadChunkSize.present) {
      map['upload_chunk_size'] = Variable<int>(uploadChunkSize.value);
    }
    if (nextChunkIndex.present) {
      map['next_chunk_index'] = Variable<int>(nextChunkIndex.value);
    }
    if (transferred.present) {
      map['transferred'] = Variable<bool>(transferred.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('BlobJobObjectsCompanion(')
          ..write('jobId: $jobId, ')
          ..write('objectId: $objectId, ')
          ..write('sha256: $sha256, ')
          ..write('size: $size, ')
          ..write('bytes: $bytes, ')
          ..write('uploadId: $uploadId, ')
          ..write('uploadChunkSize: $uploadChunkSize, ')
          ..write('nextChunkIndex: $nextChunkIndex, ')
          ..write('transferred: $transferred, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ConflictFeedCheckpointsTable extends ConflictFeedCheckpoints
    with TableInfo<$ConflictFeedCheckpointsTable, ConflictFeedCheckpoint> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ConflictFeedCheckpointsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _vaultIdMeta = const VerificationMeta(
    'vaultId',
  );
  @override
  late final GeneratedColumn<String> vaultId = GeneratedColumn<String>(
    'vault_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _instanceIdMeta = const VerificationMeta(
    'instanceId',
  );
  @override
  late final GeneratedColumn<String> instanceId = GeneratedColumn<String>(
    'instance_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _serverSpaceIdMeta = const VerificationMeta(
    'serverSpaceId',
  );
  @override
  late final GeneratedColumn<String> serverSpaceId = GeneratedColumn<String>(
    'server_space_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _serverGenerationMeta = const VerificationMeta(
    'serverGeneration',
  );
  @override
  late final GeneratedColumn<String> serverGeneration = GeneratedColumn<String>(
    'server_generation',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _partitionIdMeta = const VerificationMeta(
    'partitionId',
  );
  @override
  late final GeneratedColumn<String> partitionId = GeneratedColumn<String>(
    'partition_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _afterSeqMeta = const VerificationMeta(
    'afterSeq',
  );
  @override
  late final GeneratedColumn<String> afterSeq = GeneratedColumn<String>(
    'after_seq',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    vaultId,
    instanceId,
    serverSpaceId,
    serverGeneration,
    partitionId,
    afterSeq,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'conflict_feed_checkpoints';
  @override
  VerificationContext validateIntegrity(
    Insertable<ConflictFeedCheckpoint> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('vault_id')) {
      context.handle(
        _vaultIdMeta,
        vaultId.isAcceptableOrUnknown(data['vault_id']!, _vaultIdMeta),
      );
    } else if (isInserting) {
      context.missing(_vaultIdMeta);
    }
    if (data.containsKey('instance_id')) {
      context.handle(
        _instanceIdMeta,
        instanceId.isAcceptableOrUnknown(data['instance_id']!, _instanceIdMeta),
      );
    }
    if (data.containsKey('server_space_id')) {
      context.handle(
        _serverSpaceIdMeta,
        serverSpaceId.isAcceptableOrUnknown(
          data['server_space_id']!,
          _serverSpaceIdMeta,
        ),
      );
    }
    if (data.containsKey('server_generation')) {
      context.handle(
        _serverGenerationMeta,
        serverGeneration.isAcceptableOrUnknown(
          data['server_generation']!,
          _serverGenerationMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_serverGenerationMeta);
    }
    if (data.containsKey('partition_id')) {
      context.handle(
        _partitionIdMeta,
        partitionId.isAcceptableOrUnknown(
          data['partition_id']!,
          _partitionIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_partitionIdMeta);
    }
    if (data.containsKey('after_seq')) {
      context.handle(
        _afterSeqMeta,
        afterSeq.isAcceptableOrUnknown(data['after_seq']!, _afterSeqMeta),
      );
    } else if (isInserting) {
      context.missing(_afterSeqMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {
    vaultId,
    instanceId,
    serverSpaceId,
    serverGeneration,
    partitionId,
  };
  @override
  ConflictFeedCheckpoint map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ConflictFeedCheckpoint(
      vaultId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}vault_id'],
      )!,
      instanceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}instance_id'],
      )!,
      serverSpaceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_space_id'],
      )!,
      serverGeneration: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_generation'],
      )!,
      partitionId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}partition_id'],
      )!,
      afterSeq: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}after_seq'],
      )!,
    );
  }

  @override
  $ConflictFeedCheckpointsTable createAlias(String alias) {
    return $ConflictFeedCheckpointsTable(attachedDatabase, alias);
  }
}

class ConflictFeedCheckpoint extends DataClass
    implements Insertable<ConflictFeedCheckpoint> {
  final String vaultId;
  final String instanceId;
  final String serverSpaceId;
  final String serverGeneration;
  final String partitionId;
  final String afterSeq;
  const ConflictFeedCheckpoint({
    required this.vaultId,
    required this.instanceId,
    required this.serverSpaceId,
    required this.serverGeneration,
    required this.partitionId,
    required this.afterSeq,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['vault_id'] = Variable<String>(vaultId);
    map['instance_id'] = Variable<String>(instanceId);
    map['server_space_id'] = Variable<String>(serverSpaceId);
    map['server_generation'] = Variable<String>(serverGeneration);
    map['partition_id'] = Variable<String>(partitionId);
    map['after_seq'] = Variable<String>(afterSeq);
    return map;
  }

  ConflictFeedCheckpointsCompanion toCompanion(bool nullToAbsent) {
    return ConflictFeedCheckpointsCompanion(
      vaultId: Value(vaultId),
      instanceId: Value(instanceId),
      serverSpaceId: Value(serverSpaceId),
      serverGeneration: Value(serverGeneration),
      partitionId: Value(partitionId),
      afterSeq: Value(afterSeq),
    );
  }

  factory ConflictFeedCheckpoint.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ConflictFeedCheckpoint(
      vaultId: serializer.fromJson<String>(json['vaultId']),
      instanceId: serializer.fromJson<String>(json['instanceId']),
      serverSpaceId: serializer.fromJson<String>(json['serverSpaceId']),
      serverGeneration: serializer.fromJson<String>(json['serverGeneration']),
      partitionId: serializer.fromJson<String>(json['partitionId']),
      afterSeq: serializer.fromJson<String>(json['afterSeq']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'vaultId': serializer.toJson<String>(vaultId),
      'instanceId': serializer.toJson<String>(instanceId),
      'serverSpaceId': serializer.toJson<String>(serverSpaceId),
      'serverGeneration': serializer.toJson<String>(serverGeneration),
      'partitionId': serializer.toJson<String>(partitionId),
      'afterSeq': serializer.toJson<String>(afterSeq),
    };
  }

  ConflictFeedCheckpoint copyWith({
    String? vaultId,
    String? instanceId,
    String? serverSpaceId,
    String? serverGeneration,
    String? partitionId,
    String? afterSeq,
  }) => ConflictFeedCheckpoint(
    vaultId: vaultId ?? this.vaultId,
    instanceId: instanceId ?? this.instanceId,
    serverSpaceId: serverSpaceId ?? this.serverSpaceId,
    serverGeneration: serverGeneration ?? this.serverGeneration,
    partitionId: partitionId ?? this.partitionId,
    afterSeq: afterSeq ?? this.afterSeq,
  );
  ConflictFeedCheckpoint copyWithCompanion(
    ConflictFeedCheckpointsCompanion data,
  ) {
    return ConflictFeedCheckpoint(
      vaultId: data.vaultId.present ? data.vaultId.value : this.vaultId,
      instanceId: data.instanceId.present
          ? data.instanceId.value
          : this.instanceId,
      serverSpaceId: data.serverSpaceId.present
          ? data.serverSpaceId.value
          : this.serverSpaceId,
      serverGeneration: data.serverGeneration.present
          ? data.serverGeneration.value
          : this.serverGeneration,
      partitionId: data.partitionId.present
          ? data.partitionId.value
          : this.partitionId,
      afterSeq: data.afterSeq.present ? data.afterSeq.value : this.afterSeq,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ConflictFeedCheckpoint(')
          ..write('vaultId: $vaultId, ')
          ..write('instanceId: $instanceId, ')
          ..write('serverSpaceId: $serverSpaceId, ')
          ..write('serverGeneration: $serverGeneration, ')
          ..write('partitionId: $partitionId, ')
          ..write('afterSeq: $afterSeq')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    vaultId,
    instanceId,
    serverSpaceId,
    serverGeneration,
    partitionId,
    afterSeq,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ConflictFeedCheckpoint &&
          other.vaultId == this.vaultId &&
          other.instanceId == this.instanceId &&
          other.serverSpaceId == this.serverSpaceId &&
          other.serverGeneration == this.serverGeneration &&
          other.partitionId == this.partitionId &&
          other.afterSeq == this.afterSeq);
}

class ConflictFeedCheckpointsCompanion
    extends UpdateCompanion<ConflictFeedCheckpoint> {
  final Value<String> vaultId;
  final Value<String> instanceId;
  final Value<String> serverSpaceId;
  final Value<String> serverGeneration;
  final Value<String> partitionId;
  final Value<String> afterSeq;
  final Value<int> rowid;
  const ConflictFeedCheckpointsCompanion({
    this.vaultId = const Value.absent(),
    this.instanceId = const Value.absent(),
    this.serverSpaceId = const Value.absent(),
    this.serverGeneration = const Value.absent(),
    this.partitionId = const Value.absent(),
    this.afterSeq = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ConflictFeedCheckpointsCompanion.insert({
    required String vaultId,
    this.instanceId = const Value.absent(),
    this.serverSpaceId = const Value.absent(),
    required String serverGeneration,
    required String partitionId,
    required String afterSeq,
    this.rowid = const Value.absent(),
  }) : vaultId = Value(vaultId),
       serverGeneration = Value(serverGeneration),
       partitionId = Value(partitionId),
       afterSeq = Value(afterSeq);
  static Insertable<ConflictFeedCheckpoint> custom({
    Expression<String>? vaultId,
    Expression<String>? instanceId,
    Expression<String>? serverSpaceId,
    Expression<String>? serverGeneration,
    Expression<String>? partitionId,
    Expression<String>? afterSeq,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (vaultId != null) 'vault_id': vaultId,
      if (instanceId != null) 'instance_id': instanceId,
      if (serverSpaceId != null) 'server_space_id': serverSpaceId,
      if (serverGeneration != null) 'server_generation': serverGeneration,
      if (partitionId != null) 'partition_id': partitionId,
      if (afterSeq != null) 'after_seq': afterSeq,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ConflictFeedCheckpointsCompanion copyWith({
    Value<String>? vaultId,
    Value<String>? instanceId,
    Value<String>? serverSpaceId,
    Value<String>? serverGeneration,
    Value<String>? partitionId,
    Value<String>? afterSeq,
    Value<int>? rowid,
  }) {
    return ConflictFeedCheckpointsCompanion(
      vaultId: vaultId ?? this.vaultId,
      instanceId: instanceId ?? this.instanceId,
      serverSpaceId: serverSpaceId ?? this.serverSpaceId,
      serverGeneration: serverGeneration ?? this.serverGeneration,
      partitionId: partitionId ?? this.partitionId,
      afterSeq: afterSeq ?? this.afterSeq,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (vaultId.present) {
      map['vault_id'] = Variable<String>(vaultId.value);
    }
    if (instanceId.present) {
      map['instance_id'] = Variable<String>(instanceId.value);
    }
    if (serverSpaceId.present) {
      map['server_space_id'] = Variable<String>(serverSpaceId.value);
    }
    if (serverGeneration.present) {
      map['server_generation'] = Variable<String>(serverGeneration.value);
    }
    if (partitionId.present) {
      map['partition_id'] = Variable<String>(partitionId.value);
    }
    if (afterSeq.present) {
      map['after_seq'] = Variable<String>(afterSeq.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ConflictFeedCheckpointsCompanion(')
          ..write('vaultId: $vaultId, ')
          ..write('instanceId: $instanceId, ')
          ..write('serverSpaceId: $serverSpaceId, ')
          ..write('serverGeneration: $serverGeneration, ')
          ..write('partitionId: $partitionId, ')
          ..write('afterSeq: $afterSeq, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ConflictFeedInboxTable extends ConflictFeedInbox
    with TableInfo<$ConflictFeedInboxTable, ConflictFeedInboxData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ConflictFeedInboxTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _vaultIdMeta = const VerificationMeta(
    'vaultId',
  );
  @override
  late final GeneratedColumn<String> vaultId = GeneratedColumn<String>(
    'vault_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _serverGenerationMeta = const VerificationMeta(
    'serverGeneration',
  );
  @override
  late final GeneratedColumn<String> serverGeneration = GeneratedColumn<String>(
    'server_generation',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _instanceIdMeta = const VerificationMeta(
    'instanceId',
  );
  @override
  late final GeneratedColumn<String> instanceId = GeneratedColumn<String>(
    'instance_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _serverSpaceIdMeta = const VerificationMeta(
    'serverSpaceId',
  );
  @override
  late final GeneratedColumn<String> serverSpaceId = GeneratedColumn<String>(
    'server_space_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _partitionIdMeta = const VerificationMeta(
    'partitionId',
  );
  @override
  late final GeneratedColumn<String> partitionId = GeneratedColumn<String>(
    'partition_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _seqMeta = const VerificationMeta('seq');
  @override
  late final GeneratedColumn<String> seq = GeneratedColumn<String>(
    'seq',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _conflictIdMeta = const VerificationMeta(
    'conflictId',
  );
  @override
  late final GeneratedColumn<String> conflictId = GeneratedColumn<String>(
    'conflict_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _eventTypeMeta = const VerificationMeta(
    'eventType',
  );
  @override
  late final GeneratedColumn<String> eventType = GeneratedColumn<String>(
    'event_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _eventJsonMeta = const VerificationMeta(
    'eventJson',
  );
  @override
  late final GeneratedColumn<String> eventJson = GeneratedColumn<String>(
    'event_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    vaultId,
    serverGeneration,
    instanceId,
    serverSpaceId,
    partitionId,
    seq,
    conflictId,
    eventType,
    eventJson,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'conflict_feed_inbox';
  @override
  VerificationContext validateIntegrity(
    Insertable<ConflictFeedInboxData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('vault_id')) {
      context.handle(
        _vaultIdMeta,
        vaultId.isAcceptableOrUnknown(data['vault_id']!, _vaultIdMeta),
      );
    } else if (isInserting) {
      context.missing(_vaultIdMeta);
    }
    if (data.containsKey('server_generation')) {
      context.handle(
        _serverGenerationMeta,
        serverGeneration.isAcceptableOrUnknown(
          data['server_generation']!,
          _serverGenerationMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_serverGenerationMeta);
    }
    if (data.containsKey('instance_id')) {
      context.handle(
        _instanceIdMeta,
        instanceId.isAcceptableOrUnknown(data['instance_id']!, _instanceIdMeta),
      );
    }
    if (data.containsKey('server_space_id')) {
      context.handle(
        _serverSpaceIdMeta,
        serverSpaceId.isAcceptableOrUnknown(
          data['server_space_id']!,
          _serverSpaceIdMeta,
        ),
      );
    }
    if (data.containsKey('partition_id')) {
      context.handle(
        _partitionIdMeta,
        partitionId.isAcceptableOrUnknown(
          data['partition_id']!,
          _partitionIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_partitionIdMeta);
    }
    if (data.containsKey('seq')) {
      context.handle(
        _seqMeta,
        seq.isAcceptableOrUnknown(data['seq']!, _seqMeta),
      );
    } else if (isInserting) {
      context.missing(_seqMeta);
    }
    if (data.containsKey('conflict_id')) {
      context.handle(
        _conflictIdMeta,
        conflictId.isAcceptableOrUnknown(data['conflict_id']!, _conflictIdMeta),
      );
    } else if (isInserting) {
      context.missing(_conflictIdMeta);
    }
    if (data.containsKey('event_type')) {
      context.handle(
        _eventTypeMeta,
        eventType.isAcceptableOrUnknown(data['event_type']!, _eventTypeMeta),
      );
    } else if (isInserting) {
      context.missing(_eventTypeMeta);
    }
    if (data.containsKey('event_json')) {
      context.handle(
        _eventJsonMeta,
        eventJson.isAcceptableOrUnknown(data['event_json']!, _eventJsonMeta),
      );
    } else if (isInserting) {
      context.missing(_eventJsonMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {
    vaultId,
    instanceId,
    serverSpaceId,
    serverGeneration,
    partitionId,
    seq,
  };
  @override
  ConflictFeedInboxData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ConflictFeedInboxData(
      vaultId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}vault_id'],
      )!,
      serverGeneration: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_generation'],
      )!,
      instanceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}instance_id'],
      )!,
      serverSpaceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_space_id'],
      )!,
      partitionId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}partition_id'],
      )!,
      seq: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}seq'],
      )!,
      conflictId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conflict_id'],
      )!,
      eventType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}event_type'],
      )!,
      eventJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}event_json'],
      )!,
    );
  }

  @override
  $ConflictFeedInboxTable createAlias(String alias) {
    return $ConflictFeedInboxTable(attachedDatabase, alias);
  }
}

class ConflictFeedInboxData extends DataClass
    implements Insertable<ConflictFeedInboxData> {
  final String vaultId;
  final String serverGeneration;
  final String instanceId;
  final String serverSpaceId;
  final String partitionId;
  final String seq;
  final String conflictId;
  final String eventType;
  final String eventJson;
  const ConflictFeedInboxData({
    required this.vaultId,
    required this.serverGeneration,
    required this.instanceId,
    required this.serverSpaceId,
    required this.partitionId,
    required this.seq,
    required this.conflictId,
    required this.eventType,
    required this.eventJson,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['vault_id'] = Variable<String>(vaultId);
    map['server_generation'] = Variable<String>(serverGeneration);
    map['instance_id'] = Variable<String>(instanceId);
    map['server_space_id'] = Variable<String>(serverSpaceId);
    map['partition_id'] = Variable<String>(partitionId);
    map['seq'] = Variable<String>(seq);
    map['conflict_id'] = Variable<String>(conflictId);
    map['event_type'] = Variable<String>(eventType);
    map['event_json'] = Variable<String>(eventJson);
    return map;
  }

  ConflictFeedInboxCompanion toCompanion(bool nullToAbsent) {
    return ConflictFeedInboxCompanion(
      vaultId: Value(vaultId),
      serverGeneration: Value(serverGeneration),
      instanceId: Value(instanceId),
      serverSpaceId: Value(serverSpaceId),
      partitionId: Value(partitionId),
      seq: Value(seq),
      conflictId: Value(conflictId),
      eventType: Value(eventType),
      eventJson: Value(eventJson),
    );
  }

  factory ConflictFeedInboxData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ConflictFeedInboxData(
      vaultId: serializer.fromJson<String>(json['vaultId']),
      serverGeneration: serializer.fromJson<String>(json['serverGeneration']),
      instanceId: serializer.fromJson<String>(json['instanceId']),
      serverSpaceId: serializer.fromJson<String>(json['serverSpaceId']),
      partitionId: serializer.fromJson<String>(json['partitionId']),
      seq: serializer.fromJson<String>(json['seq']),
      conflictId: serializer.fromJson<String>(json['conflictId']),
      eventType: serializer.fromJson<String>(json['eventType']),
      eventJson: serializer.fromJson<String>(json['eventJson']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'vaultId': serializer.toJson<String>(vaultId),
      'serverGeneration': serializer.toJson<String>(serverGeneration),
      'instanceId': serializer.toJson<String>(instanceId),
      'serverSpaceId': serializer.toJson<String>(serverSpaceId),
      'partitionId': serializer.toJson<String>(partitionId),
      'seq': serializer.toJson<String>(seq),
      'conflictId': serializer.toJson<String>(conflictId),
      'eventType': serializer.toJson<String>(eventType),
      'eventJson': serializer.toJson<String>(eventJson),
    };
  }

  ConflictFeedInboxData copyWith({
    String? vaultId,
    String? serverGeneration,
    String? instanceId,
    String? serverSpaceId,
    String? partitionId,
    String? seq,
    String? conflictId,
    String? eventType,
    String? eventJson,
  }) => ConflictFeedInboxData(
    vaultId: vaultId ?? this.vaultId,
    serverGeneration: serverGeneration ?? this.serverGeneration,
    instanceId: instanceId ?? this.instanceId,
    serverSpaceId: serverSpaceId ?? this.serverSpaceId,
    partitionId: partitionId ?? this.partitionId,
    seq: seq ?? this.seq,
    conflictId: conflictId ?? this.conflictId,
    eventType: eventType ?? this.eventType,
    eventJson: eventJson ?? this.eventJson,
  );
  ConflictFeedInboxData copyWithCompanion(ConflictFeedInboxCompanion data) {
    return ConflictFeedInboxData(
      vaultId: data.vaultId.present ? data.vaultId.value : this.vaultId,
      serverGeneration: data.serverGeneration.present
          ? data.serverGeneration.value
          : this.serverGeneration,
      instanceId: data.instanceId.present
          ? data.instanceId.value
          : this.instanceId,
      serverSpaceId: data.serverSpaceId.present
          ? data.serverSpaceId.value
          : this.serverSpaceId,
      partitionId: data.partitionId.present
          ? data.partitionId.value
          : this.partitionId,
      seq: data.seq.present ? data.seq.value : this.seq,
      conflictId: data.conflictId.present
          ? data.conflictId.value
          : this.conflictId,
      eventType: data.eventType.present ? data.eventType.value : this.eventType,
      eventJson: data.eventJson.present ? data.eventJson.value : this.eventJson,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ConflictFeedInboxData(')
          ..write('vaultId: $vaultId, ')
          ..write('serverGeneration: $serverGeneration, ')
          ..write('instanceId: $instanceId, ')
          ..write('serverSpaceId: $serverSpaceId, ')
          ..write('partitionId: $partitionId, ')
          ..write('seq: $seq, ')
          ..write('conflictId: $conflictId, ')
          ..write('eventType: $eventType, ')
          ..write('eventJson: $eventJson')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    vaultId,
    serverGeneration,
    instanceId,
    serverSpaceId,
    partitionId,
    seq,
    conflictId,
    eventType,
    eventJson,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ConflictFeedInboxData &&
          other.vaultId == this.vaultId &&
          other.serverGeneration == this.serverGeneration &&
          other.instanceId == this.instanceId &&
          other.serverSpaceId == this.serverSpaceId &&
          other.partitionId == this.partitionId &&
          other.seq == this.seq &&
          other.conflictId == this.conflictId &&
          other.eventType == this.eventType &&
          other.eventJson == this.eventJson);
}

class ConflictFeedInboxCompanion
    extends UpdateCompanion<ConflictFeedInboxData> {
  final Value<String> vaultId;
  final Value<String> serverGeneration;
  final Value<String> instanceId;
  final Value<String> serverSpaceId;
  final Value<String> partitionId;
  final Value<String> seq;
  final Value<String> conflictId;
  final Value<String> eventType;
  final Value<String> eventJson;
  final Value<int> rowid;
  const ConflictFeedInboxCompanion({
    this.vaultId = const Value.absent(),
    this.serverGeneration = const Value.absent(),
    this.instanceId = const Value.absent(),
    this.serverSpaceId = const Value.absent(),
    this.partitionId = const Value.absent(),
    this.seq = const Value.absent(),
    this.conflictId = const Value.absent(),
    this.eventType = const Value.absent(),
    this.eventJson = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ConflictFeedInboxCompanion.insert({
    required String vaultId,
    required String serverGeneration,
    this.instanceId = const Value.absent(),
    this.serverSpaceId = const Value.absent(),
    required String partitionId,
    required String seq,
    required String conflictId,
    required String eventType,
    required String eventJson,
    this.rowid = const Value.absent(),
  }) : vaultId = Value(vaultId),
       serverGeneration = Value(serverGeneration),
       partitionId = Value(partitionId),
       seq = Value(seq),
       conflictId = Value(conflictId),
       eventType = Value(eventType),
       eventJson = Value(eventJson);
  static Insertable<ConflictFeedInboxData> custom({
    Expression<String>? vaultId,
    Expression<String>? serverGeneration,
    Expression<String>? instanceId,
    Expression<String>? serverSpaceId,
    Expression<String>? partitionId,
    Expression<String>? seq,
    Expression<String>? conflictId,
    Expression<String>? eventType,
    Expression<String>? eventJson,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (vaultId != null) 'vault_id': vaultId,
      if (serverGeneration != null) 'server_generation': serverGeneration,
      if (instanceId != null) 'instance_id': instanceId,
      if (serverSpaceId != null) 'server_space_id': serverSpaceId,
      if (partitionId != null) 'partition_id': partitionId,
      if (seq != null) 'seq': seq,
      if (conflictId != null) 'conflict_id': conflictId,
      if (eventType != null) 'event_type': eventType,
      if (eventJson != null) 'event_json': eventJson,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ConflictFeedInboxCompanion copyWith({
    Value<String>? vaultId,
    Value<String>? serverGeneration,
    Value<String>? instanceId,
    Value<String>? serverSpaceId,
    Value<String>? partitionId,
    Value<String>? seq,
    Value<String>? conflictId,
    Value<String>? eventType,
    Value<String>? eventJson,
    Value<int>? rowid,
  }) {
    return ConflictFeedInboxCompanion(
      vaultId: vaultId ?? this.vaultId,
      serverGeneration: serverGeneration ?? this.serverGeneration,
      instanceId: instanceId ?? this.instanceId,
      serverSpaceId: serverSpaceId ?? this.serverSpaceId,
      partitionId: partitionId ?? this.partitionId,
      seq: seq ?? this.seq,
      conflictId: conflictId ?? this.conflictId,
      eventType: eventType ?? this.eventType,
      eventJson: eventJson ?? this.eventJson,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (vaultId.present) {
      map['vault_id'] = Variable<String>(vaultId.value);
    }
    if (serverGeneration.present) {
      map['server_generation'] = Variable<String>(serverGeneration.value);
    }
    if (instanceId.present) {
      map['instance_id'] = Variable<String>(instanceId.value);
    }
    if (serverSpaceId.present) {
      map['server_space_id'] = Variable<String>(serverSpaceId.value);
    }
    if (partitionId.present) {
      map['partition_id'] = Variable<String>(partitionId.value);
    }
    if (seq.present) {
      map['seq'] = Variable<String>(seq.value);
    }
    if (conflictId.present) {
      map['conflict_id'] = Variable<String>(conflictId.value);
    }
    if (eventType.present) {
      map['event_type'] = Variable<String>(eventType.value);
    }
    if (eventJson.present) {
      map['event_json'] = Variable<String>(eventJson.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ConflictFeedInboxCompanion(')
          ..write('vaultId: $vaultId, ')
          ..write('serverGeneration: $serverGeneration, ')
          ..write('instanceId: $instanceId, ')
          ..write('serverSpaceId: $serverSpaceId, ')
          ..write('partitionId: $partitionId, ')
          ..write('seq: $seq, ')
          ..write('conflictId: $conflictId, ')
          ..write('eventType: $eventType, ')
          ..write('eventJson: $eventJson, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ConflictFeedStatesTable extends ConflictFeedStates
    with TableInfo<$ConflictFeedStatesTable, ConflictFeedState> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ConflictFeedStatesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _vaultIdMeta = const VerificationMeta(
    'vaultId',
  );
  @override
  late final GeneratedColumn<String> vaultId = GeneratedColumn<String>(
    'vault_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _instanceIdMeta = const VerificationMeta(
    'instanceId',
  );
  @override
  late final GeneratedColumn<String> instanceId = GeneratedColumn<String>(
    'instance_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _serverSpaceIdMeta = const VerificationMeta(
    'serverSpaceId',
  );
  @override
  late final GeneratedColumn<String> serverSpaceId = GeneratedColumn<String>(
    'server_space_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _serverGenerationMeta = const VerificationMeta(
    'serverGeneration',
  );
  @override
  late final GeneratedColumn<String> serverGeneration = GeneratedColumn<String>(
    'server_generation',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _partitionIdMeta = const VerificationMeta(
    'partitionId',
  );
  @override
  late final GeneratedColumn<String> partitionId = GeneratedColumn<String>(
    'partition_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    vaultId,
    instanceId,
    serverSpaceId,
    serverGeneration,
    partitionId,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'conflict_feed_states';
  @override
  VerificationContext validateIntegrity(
    Insertable<ConflictFeedState> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('vault_id')) {
      context.handle(
        _vaultIdMeta,
        vaultId.isAcceptableOrUnknown(data['vault_id']!, _vaultIdMeta),
      );
    } else if (isInserting) {
      context.missing(_vaultIdMeta);
    }
    if (data.containsKey('instance_id')) {
      context.handle(
        _instanceIdMeta,
        instanceId.isAcceptableOrUnknown(data['instance_id']!, _instanceIdMeta),
      );
    }
    if (data.containsKey('server_space_id')) {
      context.handle(
        _serverSpaceIdMeta,
        serverSpaceId.isAcceptableOrUnknown(
          data['server_space_id']!,
          _serverSpaceIdMeta,
        ),
      );
    }
    if (data.containsKey('server_generation')) {
      context.handle(
        _serverGenerationMeta,
        serverGeneration.isAcceptableOrUnknown(
          data['server_generation']!,
          _serverGenerationMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_serverGenerationMeta);
    }
    if (data.containsKey('partition_id')) {
      context.handle(
        _partitionIdMeta,
        partitionId.isAcceptableOrUnknown(
          data['partition_id']!,
          _partitionIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_partitionIdMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {vaultId, instanceId, serverSpaceId};
  @override
  ConflictFeedState map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ConflictFeedState(
      vaultId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}vault_id'],
      )!,
      instanceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}instance_id'],
      )!,
      serverSpaceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_space_id'],
      )!,
      serverGeneration: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_generation'],
      )!,
      partitionId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}partition_id'],
      )!,
    );
  }

  @override
  $ConflictFeedStatesTable createAlias(String alias) {
    return $ConflictFeedStatesTable(attachedDatabase, alias);
  }
}

class ConflictFeedState extends DataClass
    implements Insertable<ConflictFeedState> {
  final String vaultId;
  final String instanceId;
  final String serverSpaceId;
  final String serverGeneration;
  final String partitionId;
  const ConflictFeedState({
    required this.vaultId,
    required this.instanceId,
    required this.serverSpaceId,
    required this.serverGeneration,
    required this.partitionId,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['vault_id'] = Variable<String>(vaultId);
    map['instance_id'] = Variable<String>(instanceId);
    map['server_space_id'] = Variable<String>(serverSpaceId);
    map['server_generation'] = Variable<String>(serverGeneration);
    map['partition_id'] = Variable<String>(partitionId);
    return map;
  }

  ConflictFeedStatesCompanion toCompanion(bool nullToAbsent) {
    return ConflictFeedStatesCompanion(
      vaultId: Value(vaultId),
      instanceId: Value(instanceId),
      serverSpaceId: Value(serverSpaceId),
      serverGeneration: Value(serverGeneration),
      partitionId: Value(partitionId),
    );
  }

  factory ConflictFeedState.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ConflictFeedState(
      vaultId: serializer.fromJson<String>(json['vaultId']),
      instanceId: serializer.fromJson<String>(json['instanceId']),
      serverSpaceId: serializer.fromJson<String>(json['serverSpaceId']),
      serverGeneration: serializer.fromJson<String>(json['serverGeneration']),
      partitionId: serializer.fromJson<String>(json['partitionId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'vaultId': serializer.toJson<String>(vaultId),
      'instanceId': serializer.toJson<String>(instanceId),
      'serverSpaceId': serializer.toJson<String>(serverSpaceId),
      'serverGeneration': serializer.toJson<String>(serverGeneration),
      'partitionId': serializer.toJson<String>(partitionId),
    };
  }

  ConflictFeedState copyWith({
    String? vaultId,
    String? instanceId,
    String? serverSpaceId,
    String? serverGeneration,
    String? partitionId,
  }) => ConflictFeedState(
    vaultId: vaultId ?? this.vaultId,
    instanceId: instanceId ?? this.instanceId,
    serverSpaceId: serverSpaceId ?? this.serverSpaceId,
    serverGeneration: serverGeneration ?? this.serverGeneration,
    partitionId: partitionId ?? this.partitionId,
  );
  ConflictFeedState copyWithCompanion(ConflictFeedStatesCompanion data) {
    return ConflictFeedState(
      vaultId: data.vaultId.present ? data.vaultId.value : this.vaultId,
      instanceId: data.instanceId.present
          ? data.instanceId.value
          : this.instanceId,
      serverSpaceId: data.serverSpaceId.present
          ? data.serverSpaceId.value
          : this.serverSpaceId,
      serverGeneration: data.serverGeneration.present
          ? data.serverGeneration.value
          : this.serverGeneration,
      partitionId: data.partitionId.present
          ? data.partitionId.value
          : this.partitionId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ConflictFeedState(')
          ..write('vaultId: $vaultId, ')
          ..write('instanceId: $instanceId, ')
          ..write('serverSpaceId: $serverSpaceId, ')
          ..write('serverGeneration: $serverGeneration, ')
          ..write('partitionId: $partitionId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    vaultId,
    instanceId,
    serverSpaceId,
    serverGeneration,
    partitionId,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ConflictFeedState &&
          other.vaultId == this.vaultId &&
          other.instanceId == this.instanceId &&
          other.serverSpaceId == this.serverSpaceId &&
          other.serverGeneration == this.serverGeneration &&
          other.partitionId == this.partitionId);
}

class ConflictFeedStatesCompanion extends UpdateCompanion<ConflictFeedState> {
  final Value<String> vaultId;
  final Value<String> instanceId;
  final Value<String> serverSpaceId;
  final Value<String> serverGeneration;
  final Value<String> partitionId;
  final Value<int> rowid;
  const ConflictFeedStatesCompanion({
    this.vaultId = const Value.absent(),
    this.instanceId = const Value.absent(),
    this.serverSpaceId = const Value.absent(),
    this.serverGeneration = const Value.absent(),
    this.partitionId = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ConflictFeedStatesCompanion.insert({
    required String vaultId,
    this.instanceId = const Value.absent(),
    this.serverSpaceId = const Value.absent(),
    required String serverGeneration,
    required String partitionId,
    this.rowid = const Value.absent(),
  }) : vaultId = Value(vaultId),
       serverGeneration = Value(serverGeneration),
       partitionId = Value(partitionId);
  static Insertable<ConflictFeedState> custom({
    Expression<String>? vaultId,
    Expression<String>? instanceId,
    Expression<String>? serverSpaceId,
    Expression<String>? serverGeneration,
    Expression<String>? partitionId,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (vaultId != null) 'vault_id': vaultId,
      if (instanceId != null) 'instance_id': instanceId,
      if (serverSpaceId != null) 'server_space_id': serverSpaceId,
      if (serverGeneration != null) 'server_generation': serverGeneration,
      if (partitionId != null) 'partition_id': partitionId,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ConflictFeedStatesCompanion copyWith({
    Value<String>? vaultId,
    Value<String>? instanceId,
    Value<String>? serverSpaceId,
    Value<String>? serverGeneration,
    Value<String>? partitionId,
    Value<int>? rowid,
  }) {
    return ConflictFeedStatesCompanion(
      vaultId: vaultId ?? this.vaultId,
      instanceId: instanceId ?? this.instanceId,
      serverSpaceId: serverSpaceId ?? this.serverSpaceId,
      serverGeneration: serverGeneration ?? this.serverGeneration,
      partitionId: partitionId ?? this.partitionId,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (vaultId.present) {
      map['vault_id'] = Variable<String>(vaultId.value);
    }
    if (instanceId.present) {
      map['instance_id'] = Variable<String>(instanceId.value);
    }
    if (serverSpaceId.present) {
      map['server_space_id'] = Variable<String>(serverSpaceId.value);
    }
    if (serverGeneration.present) {
      map['server_generation'] = Variable<String>(serverGeneration.value);
    }
    if (partitionId.present) {
      map['partition_id'] = Variable<String>(partitionId.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ConflictFeedStatesCompanion(')
          ..write('vaultId: $vaultId, ')
          ..write('instanceId: $instanceId, ')
          ..write('serverSpaceId: $serverSpaceId, ')
          ..write('serverGeneration: $serverGeneration, ')
          ..write('partitionId: $partitionId, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $FeedConflictResolutionsTable extends FeedConflictResolutions
    with TableInfo<$FeedConflictResolutionsTable, FeedConflictResolution> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $FeedConflictResolutionsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _conflictIdMeta = const VerificationMeta(
    'conflictId',
  );
  @override
  late final GeneratedColumn<String> conflictId = GeneratedColumn<String>(
    'conflict_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _vaultIdMeta = const VerificationMeta(
    'vaultId',
  );
  @override
  late final GeneratedColumn<String> vaultId = GeneratedColumn<String>(
    'vault_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _recordIdMeta = const VerificationMeta(
    'recordId',
  );
  @override
  late final GeneratedColumn<String> recordId = GeneratedColumn<String>(
    'record_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _instanceIdMeta = const VerificationMeta(
    'instanceId',
  );
  @override
  late final GeneratedColumn<String> instanceId = GeneratedColumn<String>(
    'instance_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _serverSpaceIdMeta = const VerificationMeta(
    'serverSpaceId',
  );
  @override
  late final GeneratedColumn<String> serverSpaceId = GeneratedColumn<String>(
    'server_space_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _opIdMeta = const VerificationMeta('opId');
  @override
  late final GeneratedColumn<String> opId = GeneratedColumn<String>(
    'op_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _resolutionRevisionIdMeta =
      const VerificationMeta('resolutionRevisionId');
  @override
  late final GeneratedColumn<String> resolutionRevisionId =
      GeneratedColumn<String>(
        'resolution_revision_id',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: true,
      );
  static const VerificationMeta _stateMeta = const VerificationMeta('state');
  @override
  late final GeneratedColumn<String> state = GeneratedColumn<String>(
    'state',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    conflictId,
    vaultId,
    recordId,
    instanceId,
    serverSpaceId,
    opId,
    resolutionRevisionId,
    state,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'feed_conflict_resolutions';
  @override
  VerificationContext validateIntegrity(
    Insertable<FeedConflictResolution> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('conflict_id')) {
      context.handle(
        _conflictIdMeta,
        conflictId.isAcceptableOrUnknown(data['conflict_id']!, _conflictIdMeta),
      );
    } else if (isInserting) {
      context.missing(_conflictIdMeta);
    }
    if (data.containsKey('vault_id')) {
      context.handle(
        _vaultIdMeta,
        vaultId.isAcceptableOrUnknown(data['vault_id']!, _vaultIdMeta),
      );
    } else if (isInserting) {
      context.missing(_vaultIdMeta);
    }
    if (data.containsKey('record_id')) {
      context.handle(
        _recordIdMeta,
        recordId.isAcceptableOrUnknown(data['record_id']!, _recordIdMeta),
      );
    } else if (isInserting) {
      context.missing(_recordIdMeta);
    }
    if (data.containsKey('instance_id')) {
      context.handle(
        _instanceIdMeta,
        instanceId.isAcceptableOrUnknown(data['instance_id']!, _instanceIdMeta),
      );
    }
    if (data.containsKey('server_space_id')) {
      context.handle(
        _serverSpaceIdMeta,
        serverSpaceId.isAcceptableOrUnknown(
          data['server_space_id']!,
          _serverSpaceIdMeta,
        ),
      );
    }
    if (data.containsKey('op_id')) {
      context.handle(
        _opIdMeta,
        opId.isAcceptableOrUnknown(data['op_id']!, _opIdMeta),
      );
    }
    if (data.containsKey('resolution_revision_id')) {
      context.handle(
        _resolutionRevisionIdMeta,
        resolutionRevisionId.isAcceptableOrUnknown(
          data['resolution_revision_id']!,
          _resolutionRevisionIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_resolutionRevisionIdMeta);
    }
    if (data.containsKey('state')) {
      context.handle(
        _stateMeta,
        state.isAcceptableOrUnknown(data['state']!, _stateMeta),
      );
    } else if (isInserting) {
      context.missing(_stateMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {conflictId};
  @override
  FeedConflictResolution map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return FeedConflictResolution(
      conflictId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conflict_id'],
      )!,
      vaultId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}vault_id'],
      )!,
      recordId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}record_id'],
      )!,
      instanceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}instance_id'],
      ),
      serverSpaceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_space_id'],
      ),
      opId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}op_id'],
      ),
      resolutionRevisionId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}resolution_revision_id'],
      )!,
      state: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}state'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $FeedConflictResolutionsTable createAlias(String alias) {
    return $FeedConflictResolutionsTable(attachedDatabase, alias);
  }
}

class FeedConflictResolution extends DataClass
    implements Insertable<FeedConflictResolution> {
  final String conflictId;
  final String vaultId;
  final String recordId;
  final String? instanceId;
  final String? serverSpaceId;
  final String? opId;
  final String resolutionRevisionId;
  final String state;
  final int createdAt;
  final int updatedAt;
  const FeedConflictResolution({
    required this.conflictId,
    required this.vaultId,
    required this.recordId,
    this.instanceId,
    this.serverSpaceId,
    this.opId,
    required this.resolutionRevisionId,
    required this.state,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['conflict_id'] = Variable<String>(conflictId);
    map['vault_id'] = Variable<String>(vaultId);
    map['record_id'] = Variable<String>(recordId);
    if (!nullToAbsent || instanceId != null) {
      map['instance_id'] = Variable<String>(instanceId);
    }
    if (!nullToAbsent || serverSpaceId != null) {
      map['server_space_id'] = Variable<String>(serverSpaceId);
    }
    if (!nullToAbsent || opId != null) {
      map['op_id'] = Variable<String>(opId);
    }
    map['resolution_revision_id'] = Variable<String>(resolutionRevisionId);
    map['state'] = Variable<String>(state);
    map['created_at'] = Variable<int>(createdAt);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  FeedConflictResolutionsCompanion toCompanion(bool nullToAbsent) {
    return FeedConflictResolutionsCompanion(
      conflictId: Value(conflictId),
      vaultId: Value(vaultId),
      recordId: Value(recordId),
      instanceId: instanceId == null && nullToAbsent
          ? const Value.absent()
          : Value(instanceId),
      serverSpaceId: serverSpaceId == null && nullToAbsent
          ? const Value.absent()
          : Value(serverSpaceId),
      opId: opId == null && nullToAbsent ? const Value.absent() : Value(opId),
      resolutionRevisionId: Value(resolutionRevisionId),
      state: Value(state),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory FeedConflictResolution.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return FeedConflictResolution(
      conflictId: serializer.fromJson<String>(json['conflictId']),
      vaultId: serializer.fromJson<String>(json['vaultId']),
      recordId: serializer.fromJson<String>(json['recordId']),
      instanceId: serializer.fromJson<String?>(json['instanceId']),
      serverSpaceId: serializer.fromJson<String?>(json['serverSpaceId']),
      opId: serializer.fromJson<String?>(json['opId']),
      resolutionRevisionId: serializer.fromJson<String>(
        json['resolutionRevisionId'],
      ),
      state: serializer.fromJson<String>(json['state']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'conflictId': serializer.toJson<String>(conflictId),
      'vaultId': serializer.toJson<String>(vaultId),
      'recordId': serializer.toJson<String>(recordId),
      'instanceId': serializer.toJson<String?>(instanceId),
      'serverSpaceId': serializer.toJson<String?>(serverSpaceId),
      'opId': serializer.toJson<String?>(opId),
      'resolutionRevisionId': serializer.toJson<String>(resolutionRevisionId),
      'state': serializer.toJson<String>(state),
      'createdAt': serializer.toJson<int>(createdAt),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  FeedConflictResolution copyWith({
    String? conflictId,
    String? vaultId,
    String? recordId,
    Value<String?> instanceId = const Value.absent(),
    Value<String?> serverSpaceId = const Value.absent(),
    Value<String?> opId = const Value.absent(),
    String? resolutionRevisionId,
    String? state,
    int? createdAt,
    int? updatedAt,
  }) => FeedConflictResolution(
    conflictId: conflictId ?? this.conflictId,
    vaultId: vaultId ?? this.vaultId,
    recordId: recordId ?? this.recordId,
    instanceId: instanceId.present ? instanceId.value : this.instanceId,
    serverSpaceId: serverSpaceId.present
        ? serverSpaceId.value
        : this.serverSpaceId,
    opId: opId.present ? opId.value : this.opId,
    resolutionRevisionId: resolutionRevisionId ?? this.resolutionRevisionId,
    state: state ?? this.state,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  FeedConflictResolution copyWithCompanion(
    FeedConflictResolutionsCompanion data,
  ) {
    return FeedConflictResolution(
      conflictId: data.conflictId.present
          ? data.conflictId.value
          : this.conflictId,
      vaultId: data.vaultId.present ? data.vaultId.value : this.vaultId,
      recordId: data.recordId.present ? data.recordId.value : this.recordId,
      instanceId: data.instanceId.present
          ? data.instanceId.value
          : this.instanceId,
      serverSpaceId: data.serverSpaceId.present
          ? data.serverSpaceId.value
          : this.serverSpaceId,
      opId: data.opId.present ? data.opId.value : this.opId,
      resolutionRevisionId: data.resolutionRevisionId.present
          ? data.resolutionRevisionId.value
          : this.resolutionRevisionId,
      state: data.state.present ? data.state.value : this.state,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('FeedConflictResolution(')
          ..write('conflictId: $conflictId, ')
          ..write('vaultId: $vaultId, ')
          ..write('recordId: $recordId, ')
          ..write('instanceId: $instanceId, ')
          ..write('serverSpaceId: $serverSpaceId, ')
          ..write('opId: $opId, ')
          ..write('resolutionRevisionId: $resolutionRevisionId, ')
          ..write('state: $state, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    conflictId,
    vaultId,
    recordId,
    instanceId,
    serverSpaceId,
    opId,
    resolutionRevisionId,
    state,
    createdAt,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is FeedConflictResolution &&
          other.conflictId == this.conflictId &&
          other.vaultId == this.vaultId &&
          other.recordId == this.recordId &&
          other.instanceId == this.instanceId &&
          other.serverSpaceId == this.serverSpaceId &&
          other.opId == this.opId &&
          other.resolutionRevisionId == this.resolutionRevisionId &&
          other.state == this.state &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class FeedConflictResolutionsCompanion
    extends UpdateCompanion<FeedConflictResolution> {
  final Value<String> conflictId;
  final Value<String> vaultId;
  final Value<String> recordId;
  final Value<String?> instanceId;
  final Value<String?> serverSpaceId;
  final Value<String?> opId;
  final Value<String> resolutionRevisionId;
  final Value<String> state;
  final Value<int> createdAt;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const FeedConflictResolutionsCompanion({
    this.conflictId = const Value.absent(),
    this.vaultId = const Value.absent(),
    this.recordId = const Value.absent(),
    this.instanceId = const Value.absent(),
    this.serverSpaceId = const Value.absent(),
    this.opId = const Value.absent(),
    this.resolutionRevisionId = const Value.absent(),
    this.state = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  FeedConflictResolutionsCompanion.insert({
    required String conflictId,
    required String vaultId,
    required String recordId,
    this.instanceId = const Value.absent(),
    this.serverSpaceId = const Value.absent(),
    this.opId = const Value.absent(),
    required String resolutionRevisionId,
    required String state,
    required int createdAt,
    required int updatedAt,
    this.rowid = const Value.absent(),
  }) : conflictId = Value(conflictId),
       vaultId = Value(vaultId),
       recordId = Value(recordId),
       resolutionRevisionId = Value(resolutionRevisionId),
       state = Value(state),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<FeedConflictResolution> custom({
    Expression<String>? conflictId,
    Expression<String>? vaultId,
    Expression<String>? recordId,
    Expression<String>? instanceId,
    Expression<String>? serverSpaceId,
    Expression<String>? opId,
    Expression<String>? resolutionRevisionId,
    Expression<String>? state,
    Expression<int>? createdAt,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (conflictId != null) 'conflict_id': conflictId,
      if (vaultId != null) 'vault_id': vaultId,
      if (recordId != null) 'record_id': recordId,
      if (instanceId != null) 'instance_id': instanceId,
      if (serverSpaceId != null) 'server_space_id': serverSpaceId,
      if (opId != null) 'op_id': opId,
      if (resolutionRevisionId != null)
        'resolution_revision_id': resolutionRevisionId,
      if (state != null) 'state': state,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  FeedConflictResolutionsCompanion copyWith({
    Value<String>? conflictId,
    Value<String>? vaultId,
    Value<String>? recordId,
    Value<String?>? instanceId,
    Value<String?>? serverSpaceId,
    Value<String?>? opId,
    Value<String>? resolutionRevisionId,
    Value<String>? state,
    Value<int>? createdAt,
    Value<int>? updatedAt,
    Value<int>? rowid,
  }) {
    return FeedConflictResolutionsCompanion(
      conflictId: conflictId ?? this.conflictId,
      vaultId: vaultId ?? this.vaultId,
      recordId: recordId ?? this.recordId,
      instanceId: instanceId ?? this.instanceId,
      serverSpaceId: serverSpaceId ?? this.serverSpaceId,
      opId: opId ?? this.opId,
      resolutionRevisionId: resolutionRevisionId ?? this.resolutionRevisionId,
      state: state ?? this.state,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (conflictId.present) {
      map['conflict_id'] = Variable<String>(conflictId.value);
    }
    if (vaultId.present) {
      map['vault_id'] = Variable<String>(vaultId.value);
    }
    if (recordId.present) {
      map['record_id'] = Variable<String>(recordId.value);
    }
    if (instanceId.present) {
      map['instance_id'] = Variable<String>(instanceId.value);
    }
    if (serverSpaceId.present) {
      map['server_space_id'] = Variable<String>(serverSpaceId.value);
    }
    if (opId.present) {
      map['op_id'] = Variable<String>(opId.value);
    }
    if (resolutionRevisionId.present) {
      map['resolution_revision_id'] = Variable<String>(
        resolutionRevisionId.value,
      );
    }
    if (state.present) {
      map['state'] = Variable<String>(state.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('FeedConflictResolutionsCompanion(')
          ..write('conflictId: $conflictId, ')
          ..write('vaultId: $vaultId, ')
          ..write('recordId: $recordId, ')
          ..write('instanceId: $instanceId, ')
          ..write('serverSpaceId: $serverSpaceId, ')
          ..write('opId: $opId, ')
          ..write('resolutionRevisionId: $resolutionRevisionId, ')
          ..write('state: $state, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $TerminalHistoryEntriesTable extends TerminalHistoryEntries
    with TableInfo<$TerminalHistoryEntriesTable, TerminalHistoryEntry> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TerminalHistoryEntriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _serverNamespaceMeta = const VerificationMeta(
    'serverNamespace',
  );
  @override
  late final GeneratedColumn<String> serverNamespace = GeneratedColumn<String>(
    'server_namespace',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _accountIdMeta = const VerificationMeta(
    'accountId',
  );
  @override
  late final GeneratedColumn<String> accountId = GeneratedColumn<String>(
    'account_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deviceIdMeta = const VerificationMeta(
    'deviceId',
  );
  @override
  late final GeneratedColumn<String> deviceId = GeneratedColumn<String>(
    'device_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _entryIdMeta = const VerificationMeta(
    'entryId',
  );
  @override
  late final GeneratedColumn<String> entryId = GeneratedColumn<String>(
    'entry_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _ciphertextMeta = const VerificationMeta(
    'ciphertext',
  );
  @override
  late final GeneratedColumn<Uint8List> ciphertext = GeneratedColumn<Uint8List>(
    'ciphertext',
    aliasedName,
    false,
    type: DriftSqlType.blob,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    serverNamespace,
    accountId,
    deviceId,
    entryId,
    ciphertext,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'terminal_history_entries';
  @override
  VerificationContext validateIntegrity(
    Insertable<TerminalHistoryEntry> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('server_namespace')) {
      context.handle(
        _serverNamespaceMeta,
        serverNamespace.isAcceptableOrUnknown(
          data['server_namespace']!,
          _serverNamespaceMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_serverNamespaceMeta);
    }
    if (data.containsKey('account_id')) {
      context.handle(
        _accountIdMeta,
        accountId.isAcceptableOrUnknown(data['account_id']!, _accountIdMeta),
      );
    } else if (isInserting) {
      context.missing(_accountIdMeta);
    }
    if (data.containsKey('device_id')) {
      context.handle(
        _deviceIdMeta,
        deviceId.isAcceptableOrUnknown(data['device_id']!, _deviceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_deviceIdMeta);
    }
    if (data.containsKey('entry_id')) {
      context.handle(
        _entryIdMeta,
        entryId.isAcceptableOrUnknown(data['entry_id']!, _entryIdMeta),
      );
    } else if (isInserting) {
      context.missing(_entryIdMeta);
    }
    if (data.containsKey('ciphertext')) {
      context.handle(
        _ciphertextMeta,
        ciphertext.isAcceptableOrUnknown(data['ciphertext']!, _ciphertextMeta),
      );
    } else if (isInserting) {
      context.missing(_ciphertextMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {
    serverNamespace,
    accountId,
    deviceId,
    entryId,
  };
  @override
  TerminalHistoryEntry map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return TerminalHistoryEntry(
      serverNamespace: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_namespace'],
      )!,
      accountId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}account_id'],
      )!,
      deviceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}device_id'],
      )!,
      entryId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}entry_id'],
      )!,
      ciphertext: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}ciphertext'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $TerminalHistoryEntriesTable createAlias(String alias) {
    return $TerminalHistoryEntriesTable(attachedDatabase, alias);
  }
}

class TerminalHistoryEntry extends DataClass
    implements Insertable<TerminalHistoryEntry> {
  final String serverNamespace;
  final String accountId;
  final String deviceId;
  final String entryId;
  final Uint8List ciphertext;
  final int createdAt;
  final int updatedAt;
  const TerminalHistoryEntry({
    required this.serverNamespace,
    required this.accountId,
    required this.deviceId,
    required this.entryId,
    required this.ciphertext,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['server_namespace'] = Variable<String>(serverNamespace);
    map['account_id'] = Variable<String>(accountId);
    map['device_id'] = Variable<String>(deviceId);
    map['entry_id'] = Variable<String>(entryId);
    map['ciphertext'] = Variable<Uint8List>(ciphertext);
    map['created_at'] = Variable<int>(createdAt);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  TerminalHistoryEntriesCompanion toCompanion(bool nullToAbsent) {
    return TerminalHistoryEntriesCompanion(
      serverNamespace: Value(serverNamespace),
      accountId: Value(accountId),
      deviceId: Value(deviceId),
      entryId: Value(entryId),
      ciphertext: Value(ciphertext),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory TerminalHistoryEntry.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return TerminalHistoryEntry(
      serverNamespace: serializer.fromJson<String>(json['serverNamespace']),
      accountId: serializer.fromJson<String>(json['accountId']),
      deviceId: serializer.fromJson<String>(json['deviceId']),
      entryId: serializer.fromJson<String>(json['entryId']),
      ciphertext: serializer.fromJson<Uint8List>(json['ciphertext']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'serverNamespace': serializer.toJson<String>(serverNamespace),
      'accountId': serializer.toJson<String>(accountId),
      'deviceId': serializer.toJson<String>(deviceId),
      'entryId': serializer.toJson<String>(entryId),
      'ciphertext': serializer.toJson<Uint8List>(ciphertext),
      'createdAt': serializer.toJson<int>(createdAt),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  TerminalHistoryEntry copyWith({
    String? serverNamespace,
    String? accountId,
    String? deviceId,
    String? entryId,
    Uint8List? ciphertext,
    int? createdAt,
    int? updatedAt,
  }) => TerminalHistoryEntry(
    serverNamespace: serverNamespace ?? this.serverNamespace,
    accountId: accountId ?? this.accountId,
    deviceId: deviceId ?? this.deviceId,
    entryId: entryId ?? this.entryId,
    ciphertext: ciphertext ?? this.ciphertext,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  TerminalHistoryEntry copyWithCompanion(TerminalHistoryEntriesCompanion data) {
    return TerminalHistoryEntry(
      serverNamespace: data.serverNamespace.present
          ? data.serverNamespace.value
          : this.serverNamespace,
      accountId: data.accountId.present ? data.accountId.value : this.accountId,
      deviceId: data.deviceId.present ? data.deviceId.value : this.deviceId,
      entryId: data.entryId.present ? data.entryId.value : this.entryId,
      ciphertext: data.ciphertext.present
          ? data.ciphertext.value
          : this.ciphertext,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('TerminalHistoryEntry(')
          ..write('serverNamespace: $serverNamespace, ')
          ..write('accountId: $accountId, ')
          ..write('deviceId: $deviceId, ')
          ..write('entryId: $entryId, ')
          ..write('ciphertext: $ciphertext, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    serverNamespace,
    accountId,
    deviceId,
    entryId,
    $driftBlobEquality.hash(ciphertext),
    createdAt,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TerminalHistoryEntry &&
          other.serverNamespace == this.serverNamespace &&
          other.accountId == this.accountId &&
          other.deviceId == this.deviceId &&
          other.entryId == this.entryId &&
          $driftBlobEquality.equals(other.ciphertext, this.ciphertext) &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class TerminalHistoryEntriesCompanion
    extends UpdateCompanion<TerminalHistoryEntry> {
  final Value<String> serverNamespace;
  final Value<String> accountId;
  final Value<String> deviceId;
  final Value<String> entryId;
  final Value<Uint8List> ciphertext;
  final Value<int> createdAt;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const TerminalHistoryEntriesCompanion({
    this.serverNamespace = const Value.absent(),
    this.accountId = const Value.absent(),
    this.deviceId = const Value.absent(),
    this.entryId = const Value.absent(),
    this.ciphertext = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  TerminalHistoryEntriesCompanion.insert({
    required String serverNamespace,
    required String accountId,
    required String deviceId,
    required String entryId,
    required Uint8List ciphertext,
    required int createdAt,
    required int updatedAt,
    this.rowid = const Value.absent(),
  }) : serverNamespace = Value(serverNamespace),
       accountId = Value(accountId),
       deviceId = Value(deviceId),
       entryId = Value(entryId),
       ciphertext = Value(ciphertext),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<TerminalHistoryEntry> custom({
    Expression<String>? serverNamespace,
    Expression<String>? accountId,
    Expression<String>? deviceId,
    Expression<String>? entryId,
    Expression<Uint8List>? ciphertext,
    Expression<int>? createdAt,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (serverNamespace != null) 'server_namespace': serverNamespace,
      if (accountId != null) 'account_id': accountId,
      if (deviceId != null) 'device_id': deviceId,
      if (entryId != null) 'entry_id': entryId,
      if (ciphertext != null) 'ciphertext': ciphertext,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  TerminalHistoryEntriesCompanion copyWith({
    Value<String>? serverNamespace,
    Value<String>? accountId,
    Value<String>? deviceId,
    Value<String>? entryId,
    Value<Uint8List>? ciphertext,
    Value<int>? createdAt,
    Value<int>? updatedAt,
    Value<int>? rowid,
  }) {
    return TerminalHistoryEntriesCompanion(
      serverNamespace: serverNamespace ?? this.serverNamespace,
      accountId: accountId ?? this.accountId,
      deviceId: deviceId ?? this.deviceId,
      entryId: entryId ?? this.entryId,
      ciphertext: ciphertext ?? this.ciphertext,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (serverNamespace.present) {
      map['server_namespace'] = Variable<String>(serverNamespace.value);
    }
    if (accountId.present) {
      map['account_id'] = Variable<String>(accountId.value);
    }
    if (deviceId.present) {
      map['device_id'] = Variable<String>(deviceId.value);
    }
    if (entryId.present) {
      map['entry_id'] = Variable<String>(entryId.value);
    }
    if (ciphertext.present) {
      map['ciphertext'] = Variable<Uint8List>(ciphertext.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TerminalHistoryEntriesCompanion(')
          ..write('serverNamespace: $serverNamespace, ')
          ..write('accountId: $accountId, ')
          ..write('deviceId: $deviceId, ')
          ..write('entryId: $entryId, ')
          ..write('ciphertext: $ciphertext, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$ClientDatabase extends GeneratedDatabase {
  _$ClientDatabase(QueryExecutor e) : super(e);
  $ClientDatabaseManager get managers => $ClientDatabaseManager(this);
  late final $EncryptedRecordsTable encryptedRecords = $EncryptedRecordsTable(
    this,
  );
  late final $PendingOperationsTable pendingOperations =
      $PendingOperationsTable(this);
  late final $AuthenticatedPushReceiptsTable authenticatedPushReceipts =
      $AuthenticatedPushReceiptsTable(this);
  late final $SyncCheckpointsTable syncCheckpoints = $SyncCheckpointsTable(
    this,
  );
  late final $LockedSyncCheckpointsTable lockedSyncCheckpoints =
      $LockedSyncCheckpointsTable(this);
  late final $LockedSyncInboxPagesTable lockedSyncInboxPages =
      $LockedSyncInboxPagesTable(this);
  late final $SyncSnapshotRecoveryStagesTable syncSnapshotRecoveryStages =
      $SyncSnapshotRecoveryStagesTable(this);
  late final $SyncSnapshotRecoveryItemsTable syncSnapshotRecoveryItems =
      $SyncSnapshotRecoveryItemsTable(this);
  late final $SyncRedactionsTable syncRedactions = $SyncRedactionsTable(this);
  late final $SyncSnapshotRecoveryCursorsTable syncSnapshotRecoveryCursors =
      $SyncSnapshotRecoveryCursorsTable(this);
  late final $ConflictBranchesTable conflictBranches = $ConflictBranchesTable(
    this,
  );
  late final $TrustedDevicesTable trustedDevices = $TrustedDevicesTable(this);
  late final $DeviceSequencesTable deviceSequences = $DeviceSequencesTable(
    this,
  );
  late final $VaultArchiveObjectsTable vaultArchiveObjects =
      $VaultArchiveObjectsTable(this);
  late final $BlobJobsTable blobJobs = $BlobJobsTable(this);
  late final $BlobJobObjectsTable blobJobObjects = $BlobJobObjectsTable(this);
  late final $ConflictFeedCheckpointsTable conflictFeedCheckpoints =
      $ConflictFeedCheckpointsTable(this);
  late final $ConflictFeedInboxTable conflictFeedInbox =
      $ConflictFeedInboxTable(this);
  late final $ConflictFeedStatesTable conflictFeedStates =
      $ConflictFeedStatesTable(this);
  late final $FeedConflictResolutionsTable feedConflictResolutions =
      $FeedConflictResolutionsTable(this);
  late final $TerminalHistoryEntriesTable terminalHistoryEntries =
      $TerminalHistoryEntriesTable(this);
  late final Index syncSnapshotRecoveryItemOrder = Index(
    'sync_snapshot_recovery_item_order',
    'CREATE INDEX sync_snapshot_recovery_item_order ON sync_snapshot_recovery_items (server_namespace, account_id, instance_id, server_space_id, vault_id, server_generation, snapshot_id, ordinal)',
  );
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    encryptedRecords,
    pendingOperations,
    authenticatedPushReceipts,
    syncCheckpoints,
    lockedSyncCheckpoints,
    lockedSyncInboxPages,
    syncSnapshotRecoveryStages,
    syncSnapshotRecoveryItems,
    syncRedactions,
    syncSnapshotRecoveryCursors,
    conflictBranches,
    trustedDevices,
    deviceSequences,
    vaultArchiveObjects,
    blobJobs,
    blobJobObjects,
    conflictFeedCheckpoints,
    conflictFeedInbox,
    conflictFeedStates,
    feedConflictResolutions,
    terminalHistoryEntries,
    syncSnapshotRecoveryItemOrder,
  ];
}

typedef $$EncryptedRecordsTableCreateCompanionBuilder =
    EncryptedRecordsCompanion Function({
      required String vaultId,
      required String recordId,
      Value<String?> instanceId,
      Value<String?> serverSpaceId,
      required String revisionId,
      required String envelopeJson,
      Value<bool> isDeleted,
      Value<String?> commitSeq,
      required int updatedAt,
      Value<int> rowid,
    });
typedef $$EncryptedRecordsTableUpdateCompanionBuilder =
    EncryptedRecordsCompanion Function({
      Value<String> vaultId,
      Value<String> recordId,
      Value<String?> instanceId,
      Value<String?> serverSpaceId,
      Value<String> revisionId,
      Value<String> envelopeJson,
      Value<bool> isDeleted,
      Value<String?> commitSeq,
      Value<int> updatedAt,
      Value<int> rowid,
    });

class $$EncryptedRecordsTableFilterComposer
    extends Composer<_$ClientDatabase, $EncryptedRecordsTable> {
  $$EncryptedRecordsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get vaultId => $composableBuilder(
    column: $table.vaultId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get recordId => $composableBuilder(
    column: $table.recordId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get instanceId => $composableBuilder(
    column: $table.instanceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverSpaceId => $composableBuilder(
    column: $table.serverSpaceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get revisionId => $composableBuilder(
    column: $table.revisionId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get envelopeJson => $composableBuilder(
    column: $table.envelopeJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isDeleted => $composableBuilder(
    column: $table.isDeleted,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get commitSeq => $composableBuilder(
    column: $table.commitSeq,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$EncryptedRecordsTableOrderingComposer
    extends Composer<_$ClientDatabase, $EncryptedRecordsTable> {
  $$EncryptedRecordsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get vaultId => $composableBuilder(
    column: $table.vaultId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get recordId => $composableBuilder(
    column: $table.recordId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get instanceId => $composableBuilder(
    column: $table.instanceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverSpaceId => $composableBuilder(
    column: $table.serverSpaceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get revisionId => $composableBuilder(
    column: $table.revisionId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get envelopeJson => $composableBuilder(
    column: $table.envelopeJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isDeleted => $composableBuilder(
    column: $table.isDeleted,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get commitSeq => $composableBuilder(
    column: $table.commitSeq,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$EncryptedRecordsTableAnnotationComposer
    extends Composer<_$ClientDatabase, $EncryptedRecordsTable> {
  $$EncryptedRecordsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get vaultId =>
      $composableBuilder(column: $table.vaultId, builder: (column) => column);

  GeneratedColumn<String> get recordId =>
      $composableBuilder(column: $table.recordId, builder: (column) => column);

  GeneratedColumn<String> get instanceId => $composableBuilder(
    column: $table.instanceId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get serverSpaceId => $composableBuilder(
    column: $table.serverSpaceId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get revisionId => $composableBuilder(
    column: $table.revisionId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get envelopeJson => $composableBuilder(
    column: $table.envelopeJson,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get isDeleted =>
      $composableBuilder(column: $table.isDeleted, builder: (column) => column);

  GeneratedColumn<String> get commitSeq =>
      $composableBuilder(column: $table.commitSeq, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$EncryptedRecordsTableTableManager
    extends
        RootTableManager<
          _$ClientDatabase,
          $EncryptedRecordsTable,
          EncryptedRecord,
          $$EncryptedRecordsTableFilterComposer,
          $$EncryptedRecordsTableOrderingComposer,
          $$EncryptedRecordsTableAnnotationComposer,
          $$EncryptedRecordsTableCreateCompanionBuilder,
          $$EncryptedRecordsTableUpdateCompanionBuilder,
          (
            EncryptedRecord,
            BaseReferences<
              _$ClientDatabase,
              $EncryptedRecordsTable,
              EncryptedRecord
            >,
          ),
          EncryptedRecord,
          PrefetchHooks Function()
        > {
  $$EncryptedRecordsTableTableManager(
    _$ClientDatabase db,
    $EncryptedRecordsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$EncryptedRecordsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$EncryptedRecordsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$EncryptedRecordsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> vaultId = const Value.absent(),
                Value<String> recordId = const Value.absent(),
                Value<String?> instanceId = const Value.absent(),
                Value<String?> serverSpaceId = const Value.absent(),
                Value<String> revisionId = const Value.absent(),
                Value<String> envelopeJson = const Value.absent(),
                Value<bool> isDeleted = const Value.absent(),
                Value<String?> commitSeq = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => EncryptedRecordsCompanion(
                vaultId: vaultId,
                recordId: recordId,
                instanceId: instanceId,
                serverSpaceId: serverSpaceId,
                revisionId: revisionId,
                envelopeJson: envelopeJson,
                isDeleted: isDeleted,
                commitSeq: commitSeq,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String vaultId,
                required String recordId,
                Value<String?> instanceId = const Value.absent(),
                Value<String?> serverSpaceId = const Value.absent(),
                required String revisionId,
                required String envelopeJson,
                Value<bool> isDeleted = const Value.absent(),
                Value<String?> commitSeq = const Value.absent(),
                required int updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => EncryptedRecordsCompanion.insert(
                vaultId: vaultId,
                recordId: recordId,
                instanceId: instanceId,
                serverSpaceId: serverSpaceId,
                revisionId: revisionId,
                envelopeJson: envelopeJson,
                isDeleted: isDeleted,
                commitSeq: commitSeq,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$EncryptedRecordsTable, EncryptedRecord>(table),
                  BaseReferences<
                    _$ClientDatabase,
                    $EncryptedRecordsTable,
                    EncryptedRecord
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$EncryptedRecordsTableProcessedTableManager =
    ProcessedTableManager<
      _$ClientDatabase,
      $EncryptedRecordsTable,
      EncryptedRecord,
      $$EncryptedRecordsTableFilterComposer,
      $$EncryptedRecordsTableOrderingComposer,
      $$EncryptedRecordsTableAnnotationComposer,
      $$EncryptedRecordsTableCreateCompanionBuilder,
      $$EncryptedRecordsTableUpdateCompanionBuilder,
      (
        EncryptedRecord,
        BaseReferences<
          _$ClientDatabase,
          $EncryptedRecordsTable,
          EncryptedRecord
        >,
      ),
      EncryptedRecord,
      PrefetchHooks Function()
    >;
typedef $$PendingOperationsTableCreateCompanionBuilder =
    PendingOperationsCompanion Function({
      required String opId,
      required String vaultId,
      required String recordId,
      Value<String?> instanceId,
      Value<String?> serverSpaceId,
      Value<String?> baseRevisionId,
      Value<String?> baseEnvelopeJson,
      required String envelopeJson,
      Value<String> status,
      Value<int> attemptCount,
      required int createdAt,
      Value<int?> lastAttemptAt,
      Value<int> rowid,
    });
typedef $$PendingOperationsTableUpdateCompanionBuilder =
    PendingOperationsCompanion Function({
      Value<String> opId,
      Value<String> vaultId,
      Value<String> recordId,
      Value<String?> instanceId,
      Value<String?> serverSpaceId,
      Value<String?> baseRevisionId,
      Value<String?> baseEnvelopeJson,
      Value<String> envelopeJson,
      Value<String> status,
      Value<int> attemptCount,
      Value<int> createdAt,
      Value<int?> lastAttemptAt,
      Value<int> rowid,
    });

class $$PendingOperationsTableFilterComposer
    extends Composer<_$ClientDatabase, $PendingOperationsTable> {
  $$PendingOperationsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get opId => $composableBuilder(
    column: $table.opId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get vaultId => $composableBuilder(
    column: $table.vaultId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get recordId => $composableBuilder(
    column: $table.recordId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get instanceId => $composableBuilder(
    column: $table.instanceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverSpaceId => $composableBuilder(
    column: $table.serverSpaceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get baseRevisionId => $composableBuilder(
    column: $table.baseRevisionId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get baseEnvelopeJson => $composableBuilder(
    column: $table.baseEnvelopeJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get envelopeJson => $composableBuilder(
    column: $table.envelopeJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get attemptCount => $composableBuilder(
    column: $table.attemptCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastAttemptAt => $composableBuilder(
    column: $table.lastAttemptAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$PendingOperationsTableOrderingComposer
    extends Composer<_$ClientDatabase, $PendingOperationsTable> {
  $$PendingOperationsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get opId => $composableBuilder(
    column: $table.opId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get vaultId => $composableBuilder(
    column: $table.vaultId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get recordId => $composableBuilder(
    column: $table.recordId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get instanceId => $composableBuilder(
    column: $table.instanceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverSpaceId => $composableBuilder(
    column: $table.serverSpaceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get baseRevisionId => $composableBuilder(
    column: $table.baseRevisionId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get baseEnvelopeJson => $composableBuilder(
    column: $table.baseEnvelopeJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get envelopeJson => $composableBuilder(
    column: $table.envelopeJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get attemptCount => $composableBuilder(
    column: $table.attemptCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastAttemptAt => $composableBuilder(
    column: $table.lastAttemptAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$PendingOperationsTableAnnotationComposer
    extends Composer<_$ClientDatabase, $PendingOperationsTable> {
  $$PendingOperationsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get opId =>
      $composableBuilder(column: $table.opId, builder: (column) => column);

  GeneratedColumn<String> get vaultId =>
      $composableBuilder(column: $table.vaultId, builder: (column) => column);

  GeneratedColumn<String> get recordId =>
      $composableBuilder(column: $table.recordId, builder: (column) => column);

  GeneratedColumn<String> get instanceId => $composableBuilder(
    column: $table.instanceId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get serverSpaceId => $composableBuilder(
    column: $table.serverSpaceId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get baseRevisionId => $composableBuilder(
    column: $table.baseRevisionId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get baseEnvelopeJson => $composableBuilder(
    column: $table.baseEnvelopeJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get envelopeJson => $composableBuilder(
    column: $table.envelopeJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<int> get attemptCount => $composableBuilder(
    column: $table.attemptCount,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get lastAttemptAt => $composableBuilder(
    column: $table.lastAttemptAt,
    builder: (column) => column,
  );
}

class $$PendingOperationsTableTableManager
    extends
        RootTableManager<
          _$ClientDatabase,
          $PendingOperationsTable,
          PendingOperation,
          $$PendingOperationsTableFilterComposer,
          $$PendingOperationsTableOrderingComposer,
          $$PendingOperationsTableAnnotationComposer,
          $$PendingOperationsTableCreateCompanionBuilder,
          $$PendingOperationsTableUpdateCompanionBuilder,
          (
            PendingOperation,
            BaseReferences<
              _$ClientDatabase,
              $PendingOperationsTable,
              PendingOperation
            >,
          ),
          PendingOperation,
          PrefetchHooks Function()
        > {
  $$PendingOperationsTableTableManager(
    _$ClientDatabase db,
    $PendingOperationsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PendingOperationsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PendingOperationsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PendingOperationsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> opId = const Value.absent(),
                Value<String> vaultId = const Value.absent(),
                Value<String> recordId = const Value.absent(),
                Value<String?> instanceId = const Value.absent(),
                Value<String?> serverSpaceId = const Value.absent(),
                Value<String?> baseRevisionId = const Value.absent(),
                Value<String?> baseEnvelopeJson = const Value.absent(),
                Value<String> envelopeJson = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<int> attemptCount = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int?> lastAttemptAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => PendingOperationsCompanion(
                opId: opId,
                vaultId: vaultId,
                recordId: recordId,
                instanceId: instanceId,
                serverSpaceId: serverSpaceId,
                baseRevisionId: baseRevisionId,
                baseEnvelopeJson: baseEnvelopeJson,
                envelopeJson: envelopeJson,
                status: status,
                attemptCount: attemptCount,
                createdAt: createdAt,
                lastAttemptAt: lastAttemptAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String opId,
                required String vaultId,
                required String recordId,
                Value<String?> instanceId = const Value.absent(),
                Value<String?> serverSpaceId = const Value.absent(),
                Value<String?> baseRevisionId = const Value.absent(),
                Value<String?> baseEnvelopeJson = const Value.absent(),
                required String envelopeJson,
                Value<String> status = const Value.absent(),
                Value<int> attemptCount = const Value.absent(),
                required int createdAt,
                Value<int?> lastAttemptAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => PendingOperationsCompanion.insert(
                opId: opId,
                vaultId: vaultId,
                recordId: recordId,
                instanceId: instanceId,
                serverSpaceId: serverSpaceId,
                baseRevisionId: baseRevisionId,
                baseEnvelopeJson: baseEnvelopeJson,
                envelopeJson: envelopeJson,
                status: status,
                attemptCount: attemptCount,
                createdAt: createdAt,
                lastAttemptAt: lastAttemptAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$PendingOperationsTable, PendingOperation>(table),
                  BaseReferences<
                    _$ClientDatabase,
                    $PendingOperationsTable,
                    PendingOperation
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$PendingOperationsTableProcessedTableManager =
    ProcessedTableManager<
      _$ClientDatabase,
      $PendingOperationsTable,
      PendingOperation,
      $$PendingOperationsTableFilterComposer,
      $$PendingOperationsTableOrderingComposer,
      $$PendingOperationsTableAnnotationComposer,
      $$PendingOperationsTableCreateCompanionBuilder,
      $$PendingOperationsTableUpdateCompanionBuilder,
      (
        PendingOperation,
        BaseReferences<
          _$ClientDatabase,
          $PendingOperationsTable,
          PendingOperation
        >,
      ),
      PendingOperation,
      PrefetchHooks Function()
    >;
typedef $$AuthenticatedPushReceiptsTableCreateCompanionBuilder =
    AuthenticatedPushReceiptsCompanion Function({
      required String opId,
      required String vaultId,
      required String recordId,
      Value<String?> instanceId,
      Value<String?> serverSpaceId,
      required String revisionId,
      required String envelopeJson,
      required String commitSeq,
      Value<int> createdAt,
      Value<int> rowid,
    });
typedef $$AuthenticatedPushReceiptsTableUpdateCompanionBuilder =
    AuthenticatedPushReceiptsCompanion Function({
      Value<String> opId,
      Value<String> vaultId,
      Value<String> recordId,
      Value<String?> instanceId,
      Value<String?> serverSpaceId,
      Value<String> revisionId,
      Value<String> envelopeJson,
      Value<String> commitSeq,
      Value<int> createdAt,
      Value<int> rowid,
    });

class $$AuthenticatedPushReceiptsTableFilterComposer
    extends Composer<_$ClientDatabase, $AuthenticatedPushReceiptsTable> {
  $$AuthenticatedPushReceiptsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get opId => $composableBuilder(
    column: $table.opId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get vaultId => $composableBuilder(
    column: $table.vaultId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get recordId => $composableBuilder(
    column: $table.recordId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get instanceId => $composableBuilder(
    column: $table.instanceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverSpaceId => $composableBuilder(
    column: $table.serverSpaceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get revisionId => $composableBuilder(
    column: $table.revisionId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get envelopeJson => $composableBuilder(
    column: $table.envelopeJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get commitSeq => $composableBuilder(
    column: $table.commitSeq,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$AuthenticatedPushReceiptsTableOrderingComposer
    extends Composer<_$ClientDatabase, $AuthenticatedPushReceiptsTable> {
  $$AuthenticatedPushReceiptsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get opId => $composableBuilder(
    column: $table.opId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get vaultId => $composableBuilder(
    column: $table.vaultId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get recordId => $composableBuilder(
    column: $table.recordId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get instanceId => $composableBuilder(
    column: $table.instanceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverSpaceId => $composableBuilder(
    column: $table.serverSpaceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get revisionId => $composableBuilder(
    column: $table.revisionId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get envelopeJson => $composableBuilder(
    column: $table.envelopeJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get commitSeq => $composableBuilder(
    column: $table.commitSeq,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$AuthenticatedPushReceiptsTableAnnotationComposer
    extends Composer<_$ClientDatabase, $AuthenticatedPushReceiptsTable> {
  $$AuthenticatedPushReceiptsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get opId =>
      $composableBuilder(column: $table.opId, builder: (column) => column);

  GeneratedColumn<String> get vaultId =>
      $composableBuilder(column: $table.vaultId, builder: (column) => column);

  GeneratedColumn<String> get recordId =>
      $composableBuilder(column: $table.recordId, builder: (column) => column);

  GeneratedColumn<String> get instanceId => $composableBuilder(
    column: $table.instanceId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get serverSpaceId => $composableBuilder(
    column: $table.serverSpaceId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get revisionId => $composableBuilder(
    column: $table.revisionId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get envelopeJson => $composableBuilder(
    column: $table.envelopeJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get commitSeq =>
      $composableBuilder(column: $table.commitSeq, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);
}

class $$AuthenticatedPushReceiptsTableTableManager
    extends
        RootTableManager<
          _$ClientDatabase,
          $AuthenticatedPushReceiptsTable,
          AuthenticatedPushReceipt,
          $$AuthenticatedPushReceiptsTableFilterComposer,
          $$AuthenticatedPushReceiptsTableOrderingComposer,
          $$AuthenticatedPushReceiptsTableAnnotationComposer,
          $$AuthenticatedPushReceiptsTableCreateCompanionBuilder,
          $$AuthenticatedPushReceiptsTableUpdateCompanionBuilder,
          (
            AuthenticatedPushReceipt,
            BaseReferences<
              _$ClientDatabase,
              $AuthenticatedPushReceiptsTable,
              AuthenticatedPushReceipt
            >,
          ),
          AuthenticatedPushReceipt,
          PrefetchHooks Function()
        > {
  $$AuthenticatedPushReceiptsTableTableManager(
    _$ClientDatabase db,
    $AuthenticatedPushReceiptsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AuthenticatedPushReceiptsTableFilterComposer(
                $db: db,
                $table: table,
              ),
          createOrderingComposer: () =>
              $$AuthenticatedPushReceiptsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$AuthenticatedPushReceiptsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> opId = const Value.absent(),
                Value<String> vaultId = const Value.absent(),
                Value<String> recordId = const Value.absent(),
                Value<String?> instanceId = const Value.absent(),
                Value<String?> serverSpaceId = const Value.absent(),
                Value<String> revisionId = const Value.absent(),
                Value<String> envelopeJson = const Value.absent(),
                Value<String> commitSeq = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AuthenticatedPushReceiptsCompanion(
                opId: opId,
                vaultId: vaultId,
                recordId: recordId,
                instanceId: instanceId,
                serverSpaceId: serverSpaceId,
                revisionId: revisionId,
                envelopeJson: envelopeJson,
                commitSeq: commitSeq,
                createdAt: createdAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String opId,
                required String vaultId,
                required String recordId,
                Value<String?> instanceId = const Value.absent(),
                Value<String?> serverSpaceId = const Value.absent(),
                required String revisionId,
                required String envelopeJson,
                required String commitSeq,
                Value<int> createdAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AuthenticatedPushReceiptsCompanion.insert(
                opId: opId,
                vaultId: vaultId,
                recordId: recordId,
                instanceId: instanceId,
                serverSpaceId: serverSpaceId,
                revisionId: revisionId,
                envelopeJson: envelopeJson,
                commitSeq: commitSeq,
                createdAt: createdAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<
                    $AuthenticatedPushReceiptsTable,
                    AuthenticatedPushReceipt
                  >(table),
                  BaseReferences<
                    _$ClientDatabase,
                    $AuthenticatedPushReceiptsTable,
                    AuthenticatedPushReceipt
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$AuthenticatedPushReceiptsTableProcessedTableManager =
    ProcessedTableManager<
      _$ClientDatabase,
      $AuthenticatedPushReceiptsTable,
      AuthenticatedPushReceipt,
      $$AuthenticatedPushReceiptsTableFilterComposer,
      $$AuthenticatedPushReceiptsTableOrderingComposer,
      $$AuthenticatedPushReceiptsTableAnnotationComposer,
      $$AuthenticatedPushReceiptsTableCreateCompanionBuilder,
      $$AuthenticatedPushReceiptsTableUpdateCompanionBuilder,
      (
        AuthenticatedPushReceipt,
        BaseReferences<
          _$ClientDatabase,
          $AuthenticatedPushReceiptsTable,
          AuthenticatedPushReceipt
        >,
      ),
      AuthenticatedPushReceipt,
      PrefetchHooks Function()
    >;
typedef $$SyncCheckpointsTableCreateCompanionBuilder =
    SyncCheckpointsCompanion Function({
      required String vaultId,
      Value<String> instanceId,
      Value<String> serverSpaceId,
      Value<String?> cursor,
      Value<String?> serverGeneration,
      Value<String> syncStatus,
      Value<int?> lastSuccessAt,
      Value<int> rowid,
    });
typedef $$SyncCheckpointsTableUpdateCompanionBuilder =
    SyncCheckpointsCompanion Function({
      Value<String> vaultId,
      Value<String> instanceId,
      Value<String> serverSpaceId,
      Value<String?> cursor,
      Value<String?> serverGeneration,
      Value<String> syncStatus,
      Value<int?> lastSuccessAt,
      Value<int> rowid,
    });

class $$SyncCheckpointsTableFilterComposer
    extends Composer<_$ClientDatabase, $SyncCheckpointsTable> {
  $$SyncCheckpointsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get vaultId => $composableBuilder(
    column: $table.vaultId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get instanceId => $composableBuilder(
    column: $table.instanceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverSpaceId => $composableBuilder(
    column: $table.serverSpaceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get cursor => $composableBuilder(
    column: $table.cursor,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverGeneration => $composableBuilder(
    column: $table.serverGeneration,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get syncStatus => $composableBuilder(
    column: $table.syncStatus,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastSuccessAt => $composableBuilder(
    column: $table.lastSuccessAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SyncCheckpointsTableOrderingComposer
    extends Composer<_$ClientDatabase, $SyncCheckpointsTable> {
  $$SyncCheckpointsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get vaultId => $composableBuilder(
    column: $table.vaultId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get instanceId => $composableBuilder(
    column: $table.instanceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverSpaceId => $composableBuilder(
    column: $table.serverSpaceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get cursor => $composableBuilder(
    column: $table.cursor,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverGeneration => $composableBuilder(
    column: $table.serverGeneration,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get syncStatus => $composableBuilder(
    column: $table.syncStatus,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastSuccessAt => $composableBuilder(
    column: $table.lastSuccessAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SyncCheckpointsTableAnnotationComposer
    extends Composer<_$ClientDatabase, $SyncCheckpointsTable> {
  $$SyncCheckpointsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get vaultId =>
      $composableBuilder(column: $table.vaultId, builder: (column) => column);

  GeneratedColumn<String> get instanceId => $composableBuilder(
    column: $table.instanceId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get serverSpaceId => $composableBuilder(
    column: $table.serverSpaceId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get cursor =>
      $composableBuilder(column: $table.cursor, builder: (column) => column);

  GeneratedColumn<String> get serverGeneration => $composableBuilder(
    column: $table.serverGeneration,
    builder: (column) => column,
  );

  GeneratedColumn<String> get syncStatus => $composableBuilder(
    column: $table.syncStatus,
    builder: (column) => column,
  );

  GeneratedColumn<int> get lastSuccessAt => $composableBuilder(
    column: $table.lastSuccessAt,
    builder: (column) => column,
  );
}

class $$SyncCheckpointsTableTableManager
    extends
        RootTableManager<
          _$ClientDatabase,
          $SyncCheckpointsTable,
          SyncCheckpoint,
          $$SyncCheckpointsTableFilterComposer,
          $$SyncCheckpointsTableOrderingComposer,
          $$SyncCheckpointsTableAnnotationComposer,
          $$SyncCheckpointsTableCreateCompanionBuilder,
          $$SyncCheckpointsTableUpdateCompanionBuilder,
          (
            SyncCheckpoint,
            BaseReferences<
              _$ClientDatabase,
              $SyncCheckpointsTable,
              SyncCheckpoint
            >,
          ),
          SyncCheckpoint,
          PrefetchHooks Function()
        > {
  $$SyncCheckpointsTableTableManager(
    _$ClientDatabase db,
    $SyncCheckpointsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncCheckpointsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncCheckpointsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SyncCheckpointsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> vaultId = const Value.absent(),
                Value<String> instanceId = const Value.absent(),
                Value<String> serverSpaceId = const Value.absent(),
                Value<String?> cursor = const Value.absent(),
                Value<String?> serverGeneration = const Value.absent(),
                Value<String> syncStatus = const Value.absent(),
                Value<int?> lastSuccessAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SyncCheckpointsCompanion(
                vaultId: vaultId,
                instanceId: instanceId,
                serverSpaceId: serverSpaceId,
                cursor: cursor,
                serverGeneration: serverGeneration,
                syncStatus: syncStatus,
                lastSuccessAt: lastSuccessAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String vaultId,
                Value<String> instanceId = const Value.absent(),
                Value<String> serverSpaceId = const Value.absent(),
                Value<String?> cursor = const Value.absent(),
                Value<String?> serverGeneration = const Value.absent(),
                Value<String> syncStatus = const Value.absent(),
                Value<int?> lastSuccessAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SyncCheckpointsCompanion.insert(
                vaultId: vaultId,
                instanceId: instanceId,
                serverSpaceId: serverSpaceId,
                cursor: cursor,
                serverGeneration: serverGeneration,
                syncStatus: syncStatus,
                lastSuccessAt: lastSuccessAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$SyncCheckpointsTable, SyncCheckpoint>(table),
                  BaseReferences<
                    _$ClientDatabase,
                    $SyncCheckpointsTable,
                    SyncCheckpoint
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SyncCheckpointsTableProcessedTableManager =
    ProcessedTableManager<
      _$ClientDatabase,
      $SyncCheckpointsTable,
      SyncCheckpoint,
      $$SyncCheckpointsTableFilterComposer,
      $$SyncCheckpointsTableOrderingComposer,
      $$SyncCheckpointsTableAnnotationComposer,
      $$SyncCheckpointsTableCreateCompanionBuilder,
      $$SyncCheckpointsTableUpdateCompanionBuilder,
      (
        SyncCheckpoint,
        BaseReferences<_$ClientDatabase, $SyncCheckpointsTable, SyncCheckpoint>,
      ),
      SyncCheckpoint,
      PrefetchHooks Function()
    >;
typedef $$LockedSyncCheckpointsTableCreateCompanionBuilder =
    LockedSyncCheckpointsCompanion Function({
      required String vaultId,
      Value<String> instanceId,
      Value<String> serverSpaceId,
      required String serverGeneration,
      Value<String?> cursor,
      Value<int> nextPageIndex,
      Value<int> rowid,
    });
typedef $$LockedSyncCheckpointsTableUpdateCompanionBuilder =
    LockedSyncCheckpointsCompanion Function({
      Value<String> vaultId,
      Value<String> instanceId,
      Value<String> serverSpaceId,
      Value<String> serverGeneration,
      Value<String?> cursor,
      Value<int> nextPageIndex,
      Value<int> rowid,
    });

class $$LockedSyncCheckpointsTableFilterComposer
    extends Composer<_$ClientDatabase, $LockedSyncCheckpointsTable> {
  $$LockedSyncCheckpointsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get vaultId => $composableBuilder(
    column: $table.vaultId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get instanceId => $composableBuilder(
    column: $table.instanceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverSpaceId => $composableBuilder(
    column: $table.serverSpaceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverGeneration => $composableBuilder(
    column: $table.serverGeneration,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get cursor => $composableBuilder(
    column: $table.cursor,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get nextPageIndex => $composableBuilder(
    column: $table.nextPageIndex,
    builder: (column) => ColumnFilters(column),
  );
}

class $$LockedSyncCheckpointsTableOrderingComposer
    extends Composer<_$ClientDatabase, $LockedSyncCheckpointsTable> {
  $$LockedSyncCheckpointsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get vaultId => $composableBuilder(
    column: $table.vaultId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get instanceId => $composableBuilder(
    column: $table.instanceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverSpaceId => $composableBuilder(
    column: $table.serverSpaceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverGeneration => $composableBuilder(
    column: $table.serverGeneration,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get cursor => $composableBuilder(
    column: $table.cursor,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get nextPageIndex => $composableBuilder(
    column: $table.nextPageIndex,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LockedSyncCheckpointsTableAnnotationComposer
    extends Composer<_$ClientDatabase, $LockedSyncCheckpointsTable> {
  $$LockedSyncCheckpointsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get vaultId =>
      $composableBuilder(column: $table.vaultId, builder: (column) => column);

  GeneratedColumn<String> get instanceId => $composableBuilder(
    column: $table.instanceId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get serverSpaceId => $composableBuilder(
    column: $table.serverSpaceId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get serverGeneration => $composableBuilder(
    column: $table.serverGeneration,
    builder: (column) => column,
  );

  GeneratedColumn<String> get cursor =>
      $composableBuilder(column: $table.cursor, builder: (column) => column);

  GeneratedColumn<int> get nextPageIndex => $composableBuilder(
    column: $table.nextPageIndex,
    builder: (column) => column,
  );
}

class $$LockedSyncCheckpointsTableTableManager
    extends
        RootTableManager<
          _$ClientDatabase,
          $LockedSyncCheckpointsTable,
          LockedSyncCheckpoint,
          $$LockedSyncCheckpointsTableFilterComposer,
          $$LockedSyncCheckpointsTableOrderingComposer,
          $$LockedSyncCheckpointsTableAnnotationComposer,
          $$LockedSyncCheckpointsTableCreateCompanionBuilder,
          $$LockedSyncCheckpointsTableUpdateCompanionBuilder,
          (
            LockedSyncCheckpoint,
            BaseReferences<
              _$ClientDatabase,
              $LockedSyncCheckpointsTable,
              LockedSyncCheckpoint
            >,
          ),
          LockedSyncCheckpoint,
          PrefetchHooks Function()
        > {
  $$LockedSyncCheckpointsTableTableManager(
    _$ClientDatabase db,
    $LockedSyncCheckpointsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LockedSyncCheckpointsTableFilterComposer(
                $db: db,
                $table: table,
              ),
          createOrderingComposer: () =>
              $$LockedSyncCheckpointsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$LockedSyncCheckpointsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> vaultId = const Value.absent(),
                Value<String> instanceId = const Value.absent(),
                Value<String> serverSpaceId = const Value.absent(),
                Value<String> serverGeneration = const Value.absent(),
                Value<String?> cursor = const Value.absent(),
                Value<int> nextPageIndex = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LockedSyncCheckpointsCompanion(
                vaultId: vaultId,
                instanceId: instanceId,
                serverSpaceId: serverSpaceId,
                serverGeneration: serverGeneration,
                cursor: cursor,
                nextPageIndex: nextPageIndex,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String vaultId,
                Value<String> instanceId = const Value.absent(),
                Value<String> serverSpaceId = const Value.absent(),
                required String serverGeneration,
                Value<String?> cursor = const Value.absent(),
                Value<int> nextPageIndex = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LockedSyncCheckpointsCompanion.insert(
                vaultId: vaultId,
                instanceId: instanceId,
                serverSpaceId: serverSpaceId,
                serverGeneration: serverGeneration,
                cursor: cursor,
                nextPageIndex: nextPageIndex,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<
                    $LockedSyncCheckpointsTable,
                    LockedSyncCheckpoint
                  >(table),
                  BaseReferences<
                    _$ClientDatabase,
                    $LockedSyncCheckpointsTable,
                    LockedSyncCheckpoint
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$LockedSyncCheckpointsTableProcessedTableManager =
    ProcessedTableManager<
      _$ClientDatabase,
      $LockedSyncCheckpointsTable,
      LockedSyncCheckpoint,
      $$LockedSyncCheckpointsTableFilterComposer,
      $$LockedSyncCheckpointsTableOrderingComposer,
      $$LockedSyncCheckpointsTableAnnotationComposer,
      $$LockedSyncCheckpointsTableCreateCompanionBuilder,
      $$LockedSyncCheckpointsTableUpdateCompanionBuilder,
      (
        LockedSyncCheckpoint,
        BaseReferences<
          _$ClientDatabase,
          $LockedSyncCheckpointsTable,
          LockedSyncCheckpoint
        >,
      ),
      LockedSyncCheckpoint,
      PrefetchHooks Function()
    >;
typedef $$LockedSyncInboxPagesTableCreateCompanionBuilder =
    LockedSyncInboxPagesCompanion Function({
      required String vaultId,
      Value<String> instanceId,
      Value<String> serverSpaceId,
      required String serverGeneration,
      required int pageIndex,
      Value<String?> startCursor,
      Value<String?> nextCursor,
      required bool hasMore,
      required String eventsJson,
      Value<int> rowid,
    });
typedef $$LockedSyncInboxPagesTableUpdateCompanionBuilder =
    LockedSyncInboxPagesCompanion Function({
      Value<String> vaultId,
      Value<String> instanceId,
      Value<String> serverSpaceId,
      Value<String> serverGeneration,
      Value<int> pageIndex,
      Value<String?> startCursor,
      Value<String?> nextCursor,
      Value<bool> hasMore,
      Value<String> eventsJson,
      Value<int> rowid,
    });

class $$LockedSyncInboxPagesTableFilterComposer
    extends Composer<_$ClientDatabase, $LockedSyncInboxPagesTable> {
  $$LockedSyncInboxPagesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get vaultId => $composableBuilder(
    column: $table.vaultId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get instanceId => $composableBuilder(
    column: $table.instanceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverSpaceId => $composableBuilder(
    column: $table.serverSpaceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverGeneration => $composableBuilder(
    column: $table.serverGeneration,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get pageIndex => $composableBuilder(
    column: $table.pageIndex,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get startCursor => $composableBuilder(
    column: $table.startCursor,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get nextCursor => $composableBuilder(
    column: $table.nextCursor,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get hasMore => $composableBuilder(
    column: $table.hasMore,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get eventsJson => $composableBuilder(
    column: $table.eventsJson,
    builder: (column) => ColumnFilters(column),
  );
}

class $$LockedSyncInboxPagesTableOrderingComposer
    extends Composer<_$ClientDatabase, $LockedSyncInboxPagesTable> {
  $$LockedSyncInboxPagesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get vaultId => $composableBuilder(
    column: $table.vaultId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get instanceId => $composableBuilder(
    column: $table.instanceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverSpaceId => $composableBuilder(
    column: $table.serverSpaceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverGeneration => $composableBuilder(
    column: $table.serverGeneration,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get pageIndex => $composableBuilder(
    column: $table.pageIndex,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get startCursor => $composableBuilder(
    column: $table.startCursor,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get nextCursor => $composableBuilder(
    column: $table.nextCursor,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get hasMore => $composableBuilder(
    column: $table.hasMore,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get eventsJson => $composableBuilder(
    column: $table.eventsJson,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LockedSyncInboxPagesTableAnnotationComposer
    extends Composer<_$ClientDatabase, $LockedSyncInboxPagesTable> {
  $$LockedSyncInboxPagesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get vaultId =>
      $composableBuilder(column: $table.vaultId, builder: (column) => column);

  GeneratedColumn<String> get instanceId => $composableBuilder(
    column: $table.instanceId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get serverSpaceId => $composableBuilder(
    column: $table.serverSpaceId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get serverGeneration => $composableBuilder(
    column: $table.serverGeneration,
    builder: (column) => column,
  );

  GeneratedColumn<int> get pageIndex =>
      $composableBuilder(column: $table.pageIndex, builder: (column) => column);

  GeneratedColumn<String> get startCursor => $composableBuilder(
    column: $table.startCursor,
    builder: (column) => column,
  );

  GeneratedColumn<String> get nextCursor => $composableBuilder(
    column: $table.nextCursor,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get hasMore =>
      $composableBuilder(column: $table.hasMore, builder: (column) => column);

  GeneratedColumn<String> get eventsJson => $composableBuilder(
    column: $table.eventsJson,
    builder: (column) => column,
  );
}

class $$LockedSyncInboxPagesTableTableManager
    extends
        RootTableManager<
          _$ClientDatabase,
          $LockedSyncInboxPagesTable,
          LockedSyncInboxPage,
          $$LockedSyncInboxPagesTableFilterComposer,
          $$LockedSyncInboxPagesTableOrderingComposer,
          $$LockedSyncInboxPagesTableAnnotationComposer,
          $$LockedSyncInboxPagesTableCreateCompanionBuilder,
          $$LockedSyncInboxPagesTableUpdateCompanionBuilder,
          (
            LockedSyncInboxPage,
            BaseReferences<
              _$ClientDatabase,
              $LockedSyncInboxPagesTable,
              LockedSyncInboxPage
            >,
          ),
          LockedSyncInboxPage,
          PrefetchHooks Function()
        > {
  $$LockedSyncInboxPagesTableTableManager(
    _$ClientDatabase db,
    $LockedSyncInboxPagesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LockedSyncInboxPagesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LockedSyncInboxPagesTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$LockedSyncInboxPagesTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> vaultId = const Value.absent(),
                Value<String> instanceId = const Value.absent(),
                Value<String> serverSpaceId = const Value.absent(),
                Value<String> serverGeneration = const Value.absent(),
                Value<int> pageIndex = const Value.absent(),
                Value<String?> startCursor = const Value.absent(),
                Value<String?> nextCursor = const Value.absent(),
                Value<bool> hasMore = const Value.absent(),
                Value<String> eventsJson = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LockedSyncInboxPagesCompanion(
                vaultId: vaultId,
                instanceId: instanceId,
                serverSpaceId: serverSpaceId,
                serverGeneration: serverGeneration,
                pageIndex: pageIndex,
                startCursor: startCursor,
                nextCursor: nextCursor,
                hasMore: hasMore,
                eventsJson: eventsJson,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String vaultId,
                Value<String> instanceId = const Value.absent(),
                Value<String> serverSpaceId = const Value.absent(),
                required String serverGeneration,
                required int pageIndex,
                Value<String?> startCursor = const Value.absent(),
                Value<String?> nextCursor = const Value.absent(),
                required bool hasMore,
                required String eventsJson,
                Value<int> rowid = const Value.absent(),
              }) => LockedSyncInboxPagesCompanion.insert(
                vaultId: vaultId,
                instanceId: instanceId,
                serverSpaceId: serverSpaceId,
                serverGeneration: serverGeneration,
                pageIndex: pageIndex,
                startCursor: startCursor,
                nextCursor: nextCursor,
                hasMore: hasMore,
                eventsJson: eventsJson,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$LockedSyncInboxPagesTable, LockedSyncInboxPage>(
                    table,
                  ),
                  BaseReferences<
                    _$ClientDatabase,
                    $LockedSyncInboxPagesTable,
                    LockedSyncInboxPage
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$LockedSyncInboxPagesTableProcessedTableManager =
    ProcessedTableManager<
      _$ClientDatabase,
      $LockedSyncInboxPagesTable,
      LockedSyncInboxPage,
      $$LockedSyncInboxPagesTableFilterComposer,
      $$LockedSyncInboxPagesTableOrderingComposer,
      $$LockedSyncInboxPagesTableAnnotationComposer,
      $$LockedSyncInboxPagesTableCreateCompanionBuilder,
      $$LockedSyncInboxPagesTableUpdateCompanionBuilder,
      (
        LockedSyncInboxPage,
        BaseReferences<
          _$ClientDatabase,
          $LockedSyncInboxPagesTable,
          LockedSyncInboxPage
        >,
      ),
      LockedSyncInboxPage,
      PrefetchHooks Function()
    >;
typedef $$SyncSnapshotRecoveryStagesTableCreateCompanionBuilder =
    SyncSnapshotRecoveryStagesCompanion Function({
      required String serverNamespace,
      required String accountId,
      required String instanceId,
      required String serverSpaceId,
      required String vaultId,
      required String serverGeneration,
      required String snapshotId,
      required String highWatermark,
      required String conflictHighWatermark,
      required String checkpointCursor,
      required String expiresAt,
      Value<String?> nextPageCursor,
      Value<String?> lastRecordId,
      Value<int?> expectedItemCount,
      Value<bool> itemCountObserved,
      Value<bool> itemCountPresent,
      Value<int> verifiedItemCount,
      Value<int> serializedManifestBytes,
      Value<int> pageCount,
      Value<bool?> legacyFullManifest,
      Value<bool> complete,
      required int createdAt,
      Value<int> rowid,
    });
typedef $$SyncSnapshotRecoveryStagesTableUpdateCompanionBuilder =
    SyncSnapshotRecoveryStagesCompanion Function({
      Value<String> serverNamespace,
      Value<String> accountId,
      Value<String> instanceId,
      Value<String> serverSpaceId,
      Value<String> vaultId,
      Value<String> serverGeneration,
      Value<String> snapshotId,
      Value<String> highWatermark,
      Value<String> conflictHighWatermark,
      Value<String> checkpointCursor,
      Value<String> expiresAt,
      Value<String?> nextPageCursor,
      Value<String?> lastRecordId,
      Value<int?> expectedItemCount,
      Value<bool> itemCountObserved,
      Value<bool> itemCountPresent,
      Value<int> verifiedItemCount,
      Value<int> serializedManifestBytes,
      Value<int> pageCount,
      Value<bool?> legacyFullManifest,
      Value<bool> complete,
      Value<int> createdAt,
      Value<int> rowid,
    });

class $$SyncSnapshotRecoveryStagesTableFilterComposer
    extends Composer<_$ClientDatabase, $SyncSnapshotRecoveryStagesTable> {
  $$SyncSnapshotRecoveryStagesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get serverNamespace => $composableBuilder(
    column: $table.serverNamespace,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get instanceId => $composableBuilder(
    column: $table.instanceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverSpaceId => $composableBuilder(
    column: $table.serverSpaceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get vaultId => $composableBuilder(
    column: $table.vaultId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverGeneration => $composableBuilder(
    column: $table.serverGeneration,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get snapshotId => $composableBuilder(
    column: $table.snapshotId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get highWatermark => $composableBuilder(
    column: $table.highWatermark,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get conflictHighWatermark => $composableBuilder(
    column: $table.conflictHighWatermark,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get checkpointCursor => $composableBuilder(
    column: $table.checkpointCursor,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get expiresAt => $composableBuilder(
    column: $table.expiresAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get nextPageCursor => $composableBuilder(
    column: $table.nextPageCursor,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lastRecordId => $composableBuilder(
    column: $table.lastRecordId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get expectedItemCount => $composableBuilder(
    column: $table.expectedItemCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get itemCountObserved => $composableBuilder(
    column: $table.itemCountObserved,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get itemCountPresent => $composableBuilder(
    column: $table.itemCountPresent,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get verifiedItemCount => $composableBuilder(
    column: $table.verifiedItemCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get serializedManifestBytes => $composableBuilder(
    column: $table.serializedManifestBytes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get pageCount => $composableBuilder(
    column: $table.pageCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get legacyFullManifest => $composableBuilder(
    column: $table.legacyFullManifest,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get complete => $composableBuilder(
    column: $table.complete,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SyncSnapshotRecoveryStagesTableOrderingComposer
    extends Composer<_$ClientDatabase, $SyncSnapshotRecoveryStagesTable> {
  $$SyncSnapshotRecoveryStagesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get serverNamespace => $composableBuilder(
    column: $table.serverNamespace,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get instanceId => $composableBuilder(
    column: $table.instanceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverSpaceId => $composableBuilder(
    column: $table.serverSpaceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get vaultId => $composableBuilder(
    column: $table.vaultId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverGeneration => $composableBuilder(
    column: $table.serverGeneration,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get snapshotId => $composableBuilder(
    column: $table.snapshotId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get highWatermark => $composableBuilder(
    column: $table.highWatermark,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get conflictHighWatermark => $composableBuilder(
    column: $table.conflictHighWatermark,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get checkpointCursor => $composableBuilder(
    column: $table.checkpointCursor,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get expiresAt => $composableBuilder(
    column: $table.expiresAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get nextPageCursor => $composableBuilder(
    column: $table.nextPageCursor,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lastRecordId => $composableBuilder(
    column: $table.lastRecordId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get expectedItemCount => $composableBuilder(
    column: $table.expectedItemCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get itemCountObserved => $composableBuilder(
    column: $table.itemCountObserved,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get itemCountPresent => $composableBuilder(
    column: $table.itemCountPresent,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get verifiedItemCount => $composableBuilder(
    column: $table.verifiedItemCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get serializedManifestBytes => $composableBuilder(
    column: $table.serializedManifestBytes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get pageCount => $composableBuilder(
    column: $table.pageCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get legacyFullManifest => $composableBuilder(
    column: $table.legacyFullManifest,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get complete => $composableBuilder(
    column: $table.complete,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SyncSnapshotRecoveryStagesTableAnnotationComposer
    extends Composer<_$ClientDatabase, $SyncSnapshotRecoveryStagesTable> {
  $$SyncSnapshotRecoveryStagesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get serverNamespace => $composableBuilder(
    column: $table.serverNamespace,
    builder: (column) => column,
  );

  GeneratedColumn<String> get accountId =>
      $composableBuilder(column: $table.accountId, builder: (column) => column);

  GeneratedColumn<String> get instanceId => $composableBuilder(
    column: $table.instanceId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get serverSpaceId => $composableBuilder(
    column: $table.serverSpaceId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get vaultId =>
      $composableBuilder(column: $table.vaultId, builder: (column) => column);

  GeneratedColumn<String> get serverGeneration => $composableBuilder(
    column: $table.serverGeneration,
    builder: (column) => column,
  );

  GeneratedColumn<String> get snapshotId => $composableBuilder(
    column: $table.snapshotId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get highWatermark => $composableBuilder(
    column: $table.highWatermark,
    builder: (column) => column,
  );

  GeneratedColumn<String> get conflictHighWatermark => $composableBuilder(
    column: $table.conflictHighWatermark,
    builder: (column) => column,
  );

  GeneratedColumn<String> get checkpointCursor => $composableBuilder(
    column: $table.checkpointCursor,
    builder: (column) => column,
  );

  GeneratedColumn<String> get expiresAt =>
      $composableBuilder(column: $table.expiresAt, builder: (column) => column);

  GeneratedColumn<String> get nextPageCursor => $composableBuilder(
    column: $table.nextPageCursor,
    builder: (column) => column,
  );

  GeneratedColumn<String> get lastRecordId => $composableBuilder(
    column: $table.lastRecordId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get expectedItemCount => $composableBuilder(
    column: $table.expectedItemCount,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get itemCountObserved => $composableBuilder(
    column: $table.itemCountObserved,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get itemCountPresent => $composableBuilder(
    column: $table.itemCountPresent,
    builder: (column) => column,
  );

  GeneratedColumn<int> get verifiedItemCount => $composableBuilder(
    column: $table.verifiedItemCount,
    builder: (column) => column,
  );

  GeneratedColumn<int> get serializedManifestBytes => $composableBuilder(
    column: $table.serializedManifestBytes,
    builder: (column) => column,
  );

  GeneratedColumn<int> get pageCount =>
      $composableBuilder(column: $table.pageCount, builder: (column) => column);

  GeneratedColumn<bool> get legacyFullManifest => $composableBuilder(
    column: $table.legacyFullManifest,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get complete =>
      $composableBuilder(column: $table.complete, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);
}

class $$SyncSnapshotRecoveryStagesTableTableManager
    extends
        RootTableManager<
          _$ClientDatabase,
          $SyncSnapshotRecoveryStagesTable,
          SyncSnapshotRecoveryStage,
          $$SyncSnapshotRecoveryStagesTableFilterComposer,
          $$SyncSnapshotRecoveryStagesTableOrderingComposer,
          $$SyncSnapshotRecoveryStagesTableAnnotationComposer,
          $$SyncSnapshotRecoveryStagesTableCreateCompanionBuilder,
          $$SyncSnapshotRecoveryStagesTableUpdateCompanionBuilder,
          (
            SyncSnapshotRecoveryStage,
            BaseReferences<
              _$ClientDatabase,
              $SyncSnapshotRecoveryStagesTable,
              SyncSnapshotRecoveryStage
            >,
          ),
          SyncSnapshotRecoveryStage,
          PrefetchHooks Function()
        > {
  $$SyncSnapshotRecoveryStagesTableTableManager(
    _$ClientDatabase db,
    $SyncSnapshotRecoveryStagesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncSnapshotRecoveryStagesTableFilterComposer(
                $db: db,
                $table: table,
              ),
          createOrderingComposer: () =>
              $$SyncSnapshotRecoveryStagesTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$SyncSnapshotRecoveryStagesTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> serverNamespace = const Value.absent(),
                Value<String> accountId = const Value.absent(),
                Value<String> instanceId = const Value.absent(),
                Value<String> serverSpaceId = const Value.absent(),
                Value<String> vaultId = const Value.absent(),
                Value<String> serverGeneration = const Value.absent(),
                Value<String> snapshotId = const Value.absent(),
                Value<String> highWatermark = const Value.absent(),
                Value<String> conflictHighWatermark = const Value.absent(),
                Value<String> checkpointCursor = const Value.absent(),
                Value<String> expiresAt = const Value.absent(),
                Value<String?> nextPageCursor = const Value.absent(),
                Value<String?> lastRecordId = const Value.absent(),
                Value<int?> expectedItemCount = const Value.absent(),
                Value<bool> itemCountObserved = const Value.absent(),
                Value<bool> itemCountPresent = const Value.absent(),
                Value<int> verifiedItemCount = const Value.absent(),
                Value<int> serializedManifestBytes = const Value.absent(),
                Value<int> pageCount = const Value.absent(),
                Value<bool?> legacyFullManifest = const Value.absent(),
                Value<bool> complete = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SyncSnapshotRecoveryStagesCompanion(
                serverNamespace: serverNamespace,
                accountId: accountId,
                instanceId: instanceId,
                serverSpaceId: serverSpaceId,
                vaultId: vaultId,
                serverGeneration: serverGeneration,
                snapshotId: snapshotId,
                highWatermark: highWatermark,
                conflictHighWatermark: conflictHighWatermark,
                checkpointCursor: checkpointCursor,
                expiresAt: expiresAt,
                nextPageCursor: nextPageCursor,
                lastRecordId: lastRecordId,
                expectedItemCount: expectedItemCount,
                itemCountObserved: itemCountObserved,
                itemCountPresent: itemCountPresent,
                verifiedItemCount: verifiedItemCount,
                serializedManifestBytes: serializedManifestBytes,
                pageCount: pageCount,
                legacyFullManifest: legacyFullManifest,
                complete: complete,
                createdAt: createdAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String serverNamespace,
                required String accountId,
                required String instanceId,
                required String serverSpaceId,
                required String vaultId,
                required String serverGeneration,
                required String snapshotId,
                required String highWatermark,
                required String conflictHighWatermark,
                required String checkpointCursor,
                required String expiresAt,
                Value<String?> nextPageCursor = const Value.absent(),
                Value<String?> lastRecordId = const Value.absent(),
                Value<int?> expectedItemCount = const Value.absent(),
                Value<bool> itemCountObserved = const Value.absent(),
                Value<bool> itemCountPresent = const Value.absent(),
                Value<int> verifiedItemCount = const Value.absent(),
                Value<int> serializedManifestBytes = const Value.absent(),
                Value<int> pageCount = const Value.absent(),
                Value<bool?> legacyFullManifest = const Value.absent(),
                Value<bool> complete = const Value.absent(),
                required int createdAt,
                Value<int> rowid = const Value.absent(),
              }) => SyncSnapshotRecoveryStagesCompanion.insert(
                serverNamespace: serverNamespace,
                accountId: accountId,
                instanceId: instanceId,
                serverSpaceId: serverSpaceId,
                vaultId: vaultId,
                serverGeneration: serverGeneration,
                snapshotId: snapshotId,
                highWatermark: highWatermark,
                conflictHighWatermark: conflictHighWatermark,
                checkpointCursor: checkpointCursor,
                expiresAt: expiresAt,
                nextPageCursor: nextPageCursor,
                lastRecordId: lastRecordId,
                expectedItemCount: expectedItemCount,
                itemCountObserved: itemCountObserved,
                itemCountPresent: itemCountPresent,
                verifiedItemCount: verifiedItemCount,
                serializedManifestBytes: serializedManifestBytes,
                pageCount: pageCount,
                legacyFullManifest: legacyFullManifest,
                complete: complete,
                createdAt: createdAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<
                    $SyncSnapshotRecoveryStagesTable,
                    SyncSnapshotRecoveryStage
                  >(table),
                  BaseReferences<
                    _$ClientDatabase,
                    $SyncSnapshotRecoveryStagesTable,
                    SyncSnapshotRecoveryStage
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SyncSnapshotRecoveryStagesTableProcessedTableManager =
    ProcessedTableManager<
      _$ClientDatabase,
      $SyncSnapshotRecoveryStagesTable,
      SyncSnapshotRecoveryStage,
      $$SyncSnapshotRecoveryStagesTableFilterComposer,
      $$SyncSnapshotRecoveryStagesTableOrderingComposer,
      $$SyncSnapshotRecoveryStagesTableAnnotationComposer,
      $$SyncSnapshotRecoveryStagesTableCreateCompanionBuilder,
      $$SyncSnapshotRecoveryStagesTableUpdateCompanionBuilder,
      (
        SyncSnapshotRecoveryStage,
        BaseReferences<
          _$ClientDatabase,
          $SyncSnapshotRecoveryStagesTable,
          SyncSnapshotRecoveryStage
        >,
      ),
      SyncSnapshotRecoveryStage,
      PrefetchHooks Function()
    >;
typedef $$SyncSnapshotRecoveryItemsTableCreateCompanionBuilder =
    SyncSnapshotRecoveryItemsCompanion Function({
      required String serverNamespace,
      required String accountId,
      required String instanceId,
      required String serverSpaceId,
      required String vaultId,
      required String serverGeneration,
      required String snapshotId,
      required String recordId,
      required int ordinal,
      required String revisionId,
      required bool deleted,
      required String envelopeJson,
      Value<String?> commitSeq,
      Value<String?> redactionJson,
      Value<int> rowid,
    });
typedef $$SyncSnapshotRecoveryItemsTableUpdateCompanionBuilder =
    SyncSnapshotRecoveryItemsCompanion Function({
      Value<String> serverNamespace,
      Value<String> accountId,
      Value<String> instanceId,
      Value<String> serverSpaceId,
      Value<String> vaultId,
      Value<String> serverGeneration,
      Value<String> snapshotId,
      Value<String> recordId,
      Value<int> ordinal,
      Value<String> revisionId,
      Value<bool> deleted,
      Value<String> envelopeJson,
      Value<String?> commitSeq,
      Value<String?> redactionJson,
      Value<int> rowid,
    });

class $$SyncSnapshotRecoveryItemsTableFilterComposer
    extends Composer<_$ClientDatabase, $SyncSnapshotRecoveryItemsTable> {
  $$SyncSnapshotRecoveryItemsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get serverNamespace => $composableBuilder(
    column: $table.serverNamespace,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get instanceId => $composableBuilder(
    column: $table.instanceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverSpaceId => $composableBuilder(
    column: $table.serverSpaceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get vaultId => $composableBuilder(
    column: $table.vaultId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverGeneration => $composableBuilder(
    column: $table.serverGeneration,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get snapshotId => $composableBuilder(
    column: $table.snapshotId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get recordId => $composableBuilder(
    column: $table.recordId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get ordinal => $composableBuilder(
    column: $table.ordinal,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get revisionId => $composableBuilder(
    column: $table.revisionId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get deleted => $composableBuilder(
    column: $table.deleted,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get envelopeJson => $composableBuilder(
    column: $table.envelopeJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get commitSeq => $composableBuilder(
    column: $table.commitSeq,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get redactionJson => $composableBuilder(
    column: $table.redactionJson,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SyncSnapshotRecoveryItemsTableOrderingComposer
    extends Composer<_$ClientDatabase, $SyncSnapshotRecoveryItemsTable> {
  $$SyncSnapshotRecoveryItemsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get serverNamespace => $composableBuilder(
    column: $table.serverNamespace,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get instanceId => $composableBuilder(
    column: $table.instanceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverSpaceId => $composableBuilder(
    column: $table.serverSpaceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get vaultId => $composableBuilder(
    column: $table.vaultId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverGeneration => $composableBuilder(
    column: $table.serverGeneration,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get snapshotId => $composableBuilder(
    column: $table.snapshotId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get recordId => $composableBuilder(
    column: $table.recordId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get ordinal => $composableBuilder(
    column: $table.ordinal,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get revisionId => $composableBuilder(
    column: $table.revisionId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get deleted => $composableBuilder(
    column: $table.deleted,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get envelopeJson => $composableBuilder(
    column: $table.envelopeJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get commitSeq => $composableBuilder(
    column: $table.commitSeq,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get redactionJson => $composableBuilder(
    column: $table.redactionJson,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SyncSnapshotRecoveryItemsTableAnnotationComposer
    extends Composer<_$ClientDatabase, $SyncSnapshotRecoveryItemsTable> {
  $$SyncSnapshotRecoveryItemsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get serverNamespace => $composableBuilder(
    column: $table.serverNamespace,
    builder: (column) => column,
  );

  GeneratedColumn<String> get accountId =>
      $composableBuilder(column: $table.accountId, builder: (column) => column);

  GeneratedColumn<String> get instanceId => $composableBuilder(
    column: $table.instanceId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get serverSpaceId => $composableBuilder(
    column: $table.serverSpaceId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get vaultId =>
      $composableBuilder(column: $table.vaultId, builder: (column) => column);

  GeneratedColumn<String> get serverGeneration => $composableBuilder(
    column: $table.serverGeneration,
    builder: (column) => column,
  );

  GeneratedColumn<String> get snapshotId => $composableBuilder(
    column: $table.snapshotId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get recordId =>
      $composableBuilder(column: $table.recordId, builder: (column) => column);

  GeneratedColumn<int> get ordinal =>
      $composableBuilder(column: $table.ordinal, builder: (column) => column);

  GeneratedColumn<String> get revisionId => $composableBuilder(
    column: $table.revisionId,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get deleted =>
      $composableBuilder(column: $table.deleted, builder: (column) => column);

  GeneratedColumn<String> get envelopeJson => $composableBuilder(
    column: $table.envelopeJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get commitSeq =>
      $composableBuilder(column: $table.commitSeq, builder: (column) => column);

  GeneratedColumn<String> get redactionJson => $composableBuilder(
    column: $table.redactionJson,
    builder: (column) => column,
  );
}

class $$SyncSnapshotRecoveryItemsTableTableManager
    extends
        RootTableManager<
          _$ClientDatabase,
          $SyncSnapshotRecoveryItemsTable,
          SyncSnapshotRecoveryItem,
          $$SyncSnapshotRecoveryItemsTableFilterComposer,
          $$SyncSnapshotRecoveryItemsTableOrderingComposer,
          $$SyncSnapshotRecoveryItemsTableAnnotationComposer,
          $$SyncSnapshotRecoveryItemsTableCreateCompanionBuilder,
          $$SyncSnapshotRecoveryItemsTableUpdateCompanionBuilder,
          (
            SyncSnapshotRecoveryItem,
            BaseReferences<
              _$ClientDatabase,
              $SyncSnapshotRecoveryItemsTable,
              SyncSnapshotRecoveryItem
            >,
          ),
          SyncSnapshotRecoveryItem,
          PrefetchHooks Function()
        > {
  $$SyncSnapshotRecoveryItemsTableTableManager(
    _$ClientDatabase db,
    $SyncSnapshotRecoveryItemsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncSnapshotRecoveryItemsTableFilterComposer(
                $db: db,
                $table: table,
              ),
          createOrderingComposer: () =>
              $$SyncSnapshotRecoveryItemsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$SyncSnapshotRecoveryItemsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> serverNamespace = const Value.absent(),
                Value<String> accountId = const Value.absent(),
                Value<String> instanceId = const Value.absent(),
                Value<String> serverSpaceId = const Value.absent(),
                Value<String> vaultId = const Value.absent(),
                Value<String> serverGeneration = const Value.absent(),
                Value<String> snapshotId = const Value.absent(),
                Value<String> recordId = const Value.absent(),
                Value<int> ordinal = const Value.absent(),
                Value<String> revisionId = const Value.absent(),
                Value<bool> deleted = const Value.absent(),
                Value<String> envelopeJson = const Value.absent(),
                Value<String?> commitSeq = const Value.absent(),
                Value<String?> redactionJson = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SyncSnapshotRecoveryItemsCompanion(
                serverNamespace: serverNamespace,
                accountId: accountId,
                instanceId: instanceId,
                serverSpaceId: serverSpaceId,
                vaultId: vaultId,
                serverGeneration: serverGeneration,
                snapshotId: snapshotId,
                recordId: recordId,
                ordinal: ordinal,
                revisionId: revisionId,
                deleted: deleted,
                envelopeJson: envelopeJson,
                commitSeq: commitSeq,
                redactionJson: redactionJson,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String serverNamespace,
                required String accountId,
                required String instanceId,
                required String serverSpaceId,
                required String vaultId,
                required String serverGeneration,
                required String snapshotId,
                required String recordId,
                required int ordinal,
                required String revisionId,
                required bool deleted,
                required String envelopeJson,
                Value<String?> commitSeq = const Value.absent(),
                Value<String?> redactionJson = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SyncSnapshotRecoveryItemsCompanion.insert(
                serverNamespace: serverNamespace,
                accountId: accountId,
                instanceId: instanceId,
                serverSpaceId: serverSpaceId,
                vaultId: vaultId,
                serverGeneration: serverGeneration,
                snapshotId: snapshotId,
                recordId: recordId,
                ordinal: ordinal,
                revisionId: revisionId,
                deleted: deleted,
                envelopeJson: envelopeJson,
                commitSeq: commitSeq,
                redactionJson: redactionJson,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<
                    $SyncSnapshotRecoveryItemsTable,
                    SyncSnapshotRecoveryItem
                  >(table),
                  BaseReferences<
                    _$ClientDatabase,
                    $SyncSnapshotRecoveryItemsTable,
                    SyncSnapshotRecoveryItem
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SyncSnapshotRecoveryItemsTableProcessedTableManager =
    ProcessedTableManager<
      _$ClientDatabase,
      $SyncSnapshotRecoveryItemsTable,
      SyncSnapshotRecoveryItem,
      $$SyncSnapshotRecoveryItemsTableFilterComposer,
      $$SyncSnapshotRecoveryItemsTableOrderingComposer,
      $$SyncSnapshotRecoveryItemsTableAnnotationComposer,
      $$SyncSnapshotRecoveryItemsTableCreateCompanionBuilder,
      $$SyncSnapshotRecoveryItemsTableUpdateCompanionBuilder,
      (
        SyncSnapshotRecoveryItem,
        BaseReferences<
          _$ClientDatabase,
          $SyncSnapshotRecoveryItemsTable,
          SyncSnapshotRecoveryItem
        >,
      ),
      SyncSnapshotRecoveryItem,
      PrefetchHooks Function()
    >;
typedef $$SyncRedactionsTableCreateCompanionBuilder =
    SyncRedactionsCompanion Function({
      required String instanceId,
      required String serverSpaceId,
      required String vaultId,
      required String recordId,
      required String redactionId,
      required String deletedRevisionId,
      required String deletedSeq,
      required String redactionSeq,
      required String proofJson,
      required String serverGeneration,
      required int appliedAt,
      Value<int> rowid,
    });
typedef $$SyncRedactionsTableUpdateCompanionBuilder =
    SyncRedactionsCompanion Function({
      Value<String> instanceId,
      Value<String> serverSpaceId,
      Value<String> vaultId,
      Value<String> recordId,
      Value<String> redactionId,
      Value<String> deletedRevisionId,
      Value<String> deletedSeq,
      Value<String> redactionSeq,
      Value<String> proofJson,
      Value<String> serverGeneration,
      Value<int> appliedAt,
      Value<int> rowid,
    });

class $$SyncRedactionsTableFilterComposer
    extends Composer<_$ClientDatabase, $SyncRedactionsTable> {
  $$SyncRedactionsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get instanceId => $composableBuilder(
    column: $table.instanceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverSpaceId => $composableBuilder(
    column: $table.serverSpaceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get vaultId => $composableBuilder(
    column: $table.vaultId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get recordId => $composableBuilder(
    column: $table.recordId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get redactionId => $composableBuilder(
    column: $table.redactionId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get deletedRevisionId => $composableBuilder(
    column: $table.deletedRevisionId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get deletedSeq => $composableBuilder(
    column: $table.deletedSeq,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get redactionSeq => $composableBuilder(
    column: $table.redactionSeq,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get proofJson => $composableBuilder(
    column: $table.proofJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverGeneration => $composableBuilder(
    column: $table.serverGeneration,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get appliedAt => $composableBuilder(
    column: $table.appliedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SyncRedactionsTableOrderingComposer
    extends Composer<_$ClientDatabase, $SyncRedactionsTable> {
  $$SyncRedactionsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get instanceId => $composableBuilder(
    column: $table.instanceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverSpaceId => $composableBuilder(
    column: $table.serverSpaceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get vaultId => $composableBuilder(
    column: $table.vaultId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get recordId => $composableBuilder(
    column: $table.recordId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get redactionId => $composableBuilder(
    column: $table.redactionId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get deletedRevisionId => $composableBuilder(
    column: $table.deletedRevisionId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get deletedSeq => $composableBuilder(
    column: $table.deletedSeq,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get redactionSeq => $composableBuilder(
    column: $table.redactionSeq,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get proofJson => $composableBuilder(
    column: $table.proofJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverGeneration => $composableBuilder(
    column: $table.serverGeneration,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get appliedAt => $composableBuilder(
    column: $table.appliedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SyncRedactionsTableAnnotationComposer
    extends Composer<_$ClientDatabase, $SyncRedactionsTable> {
  $$SyncRedactionsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get instanceId => $composableBuilder(
    column: $table.instanceId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get serverSpaceId => $composableBuilder(
    column: $table.serverSpaceId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get vaultId =>
      $composableBuilder(column: $table.vaultId, builder: (column) => column);

  GeneratedColumn<String> get recordId =>
      $composableBuilder(column: $table.recordId, builder: (column) => column);

  GeneratedColumn<String> get redactionId => $composableBuilder(
    column: $table.redactionId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get deletedRevisionId => $composableBuilder(
    column: $table.deletedRevisionId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get deletedSeq => $composableBuilder(
    column: $table.deletedSeq,
    builder: (column) => column,
  );

  GeneratedColumn<String> get redactionSeq => $composableBuilder(
    column: $table.redactionSeq,
    builder: (column) => column,
  );

  GeneratedColumn<String> get proofJson =>
      $composableBuilder(column: $table.proofJson, builder: (column) => column);

  GeneratedColumn<String> get serverGeneration => $composableBuilder(
    column: $table.serverGeneration,
    builder: (column) => column,
  );

  GeneratedColumn<int> get appliedAt =>
      $composableBuilder(column: $table.appliedAt, builder: (column) => column);
}

class $$SyncRedactionsTableTableManager
    extends
        RootTableManager<
          _$ClientDatabase,
          $SyncRedactionsTable,
          SyncRedaction,
          $$SyncRedactionsTableFilterComposer,
          $$SyncRedactionsTableOrderingComposer,
          $$SyncRedactionsTableAnnotationComposer,
          $$SyncRedactionsTableCreateCompanionBuilder,
          $$SyncRedactionsTableUpdateCompanionBuilder,
          (
            SyncRedaction,
            BaseReferences<
              _$ClientDatabase,
              $SyncRedactionsTable,
              SyncRedaction
            >,
          ),
          SyncRedaction,
          PrefetchHooks Function()
        > {
  $$SyncRedactionsTableTableManager(
    _$ClientDatabase db,
    $SyncRedactionsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncRedactionsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncRedactionsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SyncRedactionsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> instanceId = const Value.absent(),
                Value<String> serverSpaceId = const Value.absent(),
                Value<String> vaultId = const Value.absent(),
                Value<String> recordId = const Value.absent(),
                Value<String> redactionId = const Value.absent(),
                Value<String> deletedRevisionId = const Value.absent(),
                Value<String> deletedSeq = const Value.absent(),
                Value<String> redactionSeq = const Value.absent(),
                Value<String> proofJson = const Value.absent(),
                Value<String> serverGeneration = const Value.absent(),
                Value<int> appliedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SyncRedactionsCompanion(
                instanceId: instanceId,
                serverSpaceId: serverSpaceId,
                vaultId: vaultId,
                recordId: recordId,
                redactionId: redactionId,
                deletedRevisionId: deletedRevisionId,
                deletedSeq: deletedSeq,
                redactionSeq: redactionSeq,
                proofJson: proofJson,
                serverGeneration: serverGeneration,
                appliedAt: appliedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String instanceId,
                required String serverSpaceId,
                required String vaultId,
                required String recordId,
                required String redactionId,
                required String deletedRevisionId,
                required String deletedSeq,
                required String redactionSeq,
                required String proofJson,
                required String serverGeneration,
                required int appliedAt,
                Value<int> rowid = const Value.absent(),
              }) => SyncRedactionsCompanion.insert(
                instanceId: instanceId,
                serverSpaceId: serverSpaceId,
                vaultId: vaultId,
                recordId: recordId,
                redactionId: redactionId,
                deletedRevisionId: deletedRevisionId,
                deletedSeq: deletedSeq,
                redactionSeq: redactionSeq,
                proofJson: proofJson,
                serverGeneration: serverGeneration,
                appliedAt: appliedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$SyncRedactionsTable, SyncRedaction>(table),
                  BaseReferences<
                    _$ClientDatabase,
                    $SyncRedactionsTable,
                    SyncRedaction
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SyncRedactionsTableProcessedTableManager =
    ProcessedTableManager<
      _$ClientDatabase,
      $SyncRedactionsTable,
      SyncRedaction,
      $$SyncRedactionsTableFilterComposer,
      $$SyncRedactionsTableOrderingComposer,
      $$SyncRedactionsTableAnnotationComposer,
      $$SyncRedactionsTableCreateCompanionBuilder,
      $$SyncRedactionsTableUpdateCompanionBuilder,
      (
        SyncRedaction,
        BaseReferences<_$ClientDatabase, $SyncRedactionsTable, SyncRedaction>,
      ),
      SyncRedaction,
      PrefetchHooks Function()
    >;
typedef $$SyncSnapshotRecoveryCursorsTableCreateCompanionBuilder =
    SyncSnapshotRecoveryCursorsCompanion Function({
      required String serverNamespace,
      required String accountId,
      required String instanceId,
      required String serverSpaceId,
      required String vaultId,
      required String serverGeneration,
      required String snapshotId,
      required String cursor,
      Value<int> rowid,
    });
typedef $$SyncSnapshotRecoveryCursorsTableUpdateCompanionBuilder =
    SyncSnapshotRecoveryCursorsCompanion Function({
      Value<String> serverNamespace,
      Value<String> accountId,
      Value<String> instanceId,
      Value<String> serverSpaceId,
      Value<String> vaultId,
      Value<String> serverGeneration,
      Value<String> snapshotId,
      Value<String> cursor,
      Value<int> rowid,
    });

class $$SyncSnapshotRecoveryCursorsTableFilterComposer
    extends Composer<_$ClientDatabase, $SyncSnapshotRecoveryCursorsTable> {
  $$SyncSnapshotRecoveryCursorsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get serverNamespace => $composableBuilder(
    column: $table.serverNamespace,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get instanceId => $composableBuilder(
    column: $table.instanceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverSpaceId => $composableBuilder(
    column: $table.serverSpaceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get vaultId => $composableBuilder(
    column: $table.vaultId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverGeneration => $composableBuilder(
    column: $table.serverGeneration,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get snapshotId => $composableBuilder(
    column: $table.snapshotId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get cursor => $composableBuilder(
    column: $table.cursor,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SyncSnapshotRecoveryCursorsTableOrderingComposer
    extends Composer<_$ClientDatabase, $SyncSnapshotRecoveryCursorsTable> {
  $$SyncSnapshotRecoveryCursorsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get serverNamespace => $composableBuilder(
    column: $table.serverNamespace,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get instanceId => $composableBuilder(
    column: $table.instanceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverSpaceId => $composableBuilder(
    column: $table.serverSpaceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get vaultId => $composableBuilder(
    column: $table.vaultId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverGeneration => $composableBuilder(
    column: $table.serverGeneration,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get snapshotId => $composableBuilder(
    column: $table.snapshotId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get cursor => $composableBuilder(
    column: $table.cursor,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SyncSnapshotRecoveryCursorsTableAnnotationComposer
    extends Composer<_$ClientDatabase, $SyncSnapshotRecoveryCursorsTable> {
  $$SyncSnapshotRecoveryCursorsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get serverNamespace => $composableBuilder(
    column: $table.serverNamespace,
    builder: (column) => column,
  );

  GeneratedColumn<String> get accountId =>
      $composableBuilder(column: $table.accountId, builder: (column) => column);

  GeneratedColumn<String> get instanceId => $composableBuilder(
    column: $table.instanceId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get serverSpaceId => $composableBuilder(
    column: $table.serverSpaceId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get vaultId =>
      $composableBuilder(column: $table.vaultId, builder: (column) => column);

  GeneratedColumn<String> get serverGeneration => $composableBuilder(
    column: $table.serverGeneration,
    builder: (column) => column,
  );

  GeneratedColumn<String> get snapshotId => $composableBuilder(
    column: $table.snapshotId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get cursor =>
      $composableBuilder(column: $table.cursor, builder: (column) => column);
}

class $$SyncSnapshotRecoveryCursorsTableTableManager
    extends
        RootTableManager<
          _$ClientDatabase,
          $SyncSnapshotRecoveryCursorsTable,
          SyncSnapshotRecoveryCursor,
          $$SyncSnapshotRecoveryCursorsTableFilterComposer,
          $$SyncSnapshotRecoveryCursorsTableOrderingComposer,
          $$SyncSnapshotRecoveryCursorsTableAnnotationComposer,
          $$SyncSnapshotRecoveryCursorsTableCreateCompanionBuilder,
          $$SyncSnapshotRecoveryCursorsTableUpdateCompanionBuilder,
          (
            SyncSnapshotRecoveryCursor,
            BaseReferences<
              _$ClientDatabase,
              $SyncSnapshotRecoveryCursorsTable,
              SyncSnapshotRecoveryCursor
            >,
          ),
          SyncSnapshotRecoveryCursor,
          PrefetchHooks Function()
        > {
  $$SyncSnapshotRecoveryCursorsTableTableManager(
    _$ClientDatabase db,
    $SyncSnapshotRecoveryCursorsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncSnapshotRecoveryCursorsTableFilterComposer(
                $db: db,
                $table: table,
              ),
          createOrderingComposer: () =>
              $$SyncSnapshotRecoveryCursorsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$SyncSnapshotRecoveryCursorsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> serverNamespace = const Value.absent(),
                Value<String> accountId = const Value.absent(),
                Value<String> instanceId = const Value.absent(),
                Value<String> serverSpaceId = const Value.absent(),
                Value<String> vaultId = const Value.absent(),
                Value<String> serverGeneration = const Value.absent(),
                Value<String> snapshotId = const Value.absent(),
                Value<String> cursor = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SyncSnapshotRecoveryCursorsCompanion(
                serverNamespace: serverNamespace,
                accountId: accountId,
                instanceId: instanceId,
                serverSpaceId: serverSpaceId,
                vaultId: vaultId,
                serverGeneration: serverGeneration,
                snapshotId: snapshotId,
                cursor: cursor,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String serverNamespace,
                required String accountId,
                required String instanceId,
                required String serverSpaceId,
                required String vaultId,
                required String serverGeneration,
                required String snapshotId,
                required String cursor,
                Value<int> rowid = const Value.absent(),
              }) => SyncSnapshotRecoveryCursorsCompanion.insert(
                serverNamespace: serverNamespace,
                accountId: accountId,
                instanceId: instanceId,
                serverSpaceId: serverSpaceId,
                vaultId: vaultId,
                serverGeneration: serverGeneration,
                snapshotId: snapshotId,
                cursor: cursor,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<
                    $SyncSnapshotRecoveryCursorsTable,
                    SyncSnapshotRecoveryCursor
                  >(table),
                  BaseReferences<
                    _$ClientDatabase,
                    $SyncSnapshotRecoveryCursorsTable,
                    SyncSnapshotRecoveryCursor
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SyncSnapshotRecoveryCursorsTableProcessedTableManager =
    ProcessedTableManager<
      _$ClientDatabase,
      $SyncSnapshotRecoveryCursorsTable,
      SyncSnapshotRecoveryCursor,
      $$SyncSnapshotRecoveryCursorsTableFilterComposer,
      $$SyncSnapshotRecoveryCursorsTableOrderingComposer,
      $$SyncSnapshotRecoveryCursorsTableAnnotationComposer,
      $$SyncSnapshotRecoveryCursorsTableCreateCompanionBuilder,
      $$SyncSnapshotRecoveryCursorsTableUpdateCompanionBuilder,
      (
        SyncSnapshotRecoveryCursor,
        BaseReferences<
          _$ClientDatabase,
          $SyncSnapshotRecoveryCursorsTable,
          SyncSnapshotRecoveryCursor
        >,
      ),
      SyncSnapshotRecoveryCursor,
      PrefetchHooks Function()
    >;
typedef $$ConflictBranchesTableCreateCompanionBuilder =
    ConflictBranchesCompanion Function({
      required String conflictId,
      required String vaultId,
      required String recordId,
      Value<String?> instanceId,
      Value<String?> serverSpaceId,
      required String kind,
      required String branchEnvelopeJson,
      required String remoteEnvelopeJson,
      Value<String> state,
      Value<String?> resolutionOpId,
      Value<String?> resolutionRevisionId,
      Value<String?> redactionProofJson,
      required int createdAt,
      Value<int> rowid,
    });
typedef $$ConflictBranchesTableUpdateCompanionBuilder =
    ConflictBranchesCompanion Function({
      Value<String> conflictId,
      Value<String> vaultId,
      Value<String> recordId,
      Value<String?> instanceId,
      Value<String?> serverSpaceId,
      Value<String> kind,
      Value<String> branchEnvelopeJson,
      Value<String> remoteEnvelopeJson,
      Value<String> state,
      Value<String?> resolutionOpId,
      Value<String?> resolutionRevisionId,
      Value<String?> redactionProofJson,
      Value<int> createdAt,
      Value<int> rowid,
    });

class $$ConflictBranchesTableFilterComposer
    extends Composer<_$ClientDatabase, $ConflictBranchesTable> {
  $$ConflictBranchesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get conflictId => $composableBuilder(
    column: $table.conflictId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get vaultId => $composableBuilder(
    column: $table.vaultId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get recordId => $composableBuilder(
    column: $table.recordId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get instanceId => $composableBuilder(
    column: $table.instanceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverSpaceId => $composableBuilder(
    column: $table.serverSpaceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get branchEnvelopeJson => $composableBuilder(
    column: $table.branchEnvelopeJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get remoteEnvelopeJson => $composableBuilder(
    column: $table.remoteEnvelopeJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get resolutionOpId => $composableBuilder(
    column: $table.resolutionOpId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get resolutionRevisionId => $composableBuilder(
    column: $table.resolutionRevisionId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get redactionProofJson => $composableBuilder(
    column: $table.redactionProofJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ConflictBranchesTableOrderingComposer
    extends Composer<_$ClientDatabase, $ConflictBranchesTable> {
  $$ConflictBranchesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get conflictId => $composableBuilder(
    column: $table.conflictId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get vaultId => $composableBuilder(
    column: $table.vaultId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get recordId => $composableBuilder(
    column: $table.recordId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get instanceId => $composableBuilder(
    column: $table.instanceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverSpaceId => $composableBuilder(
    column: $table.serverSpaceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get branchEnvelopeJson => $composableBuilder(
    column: $table.branchEnvelopeJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get remoteEnvelopeJson => $composableBuilder(
    column: $table.remoteEnvelopeJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get resolutionOpId => $composableBuilder(
    column: $table.resolutionOpId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get resolutionRevisionId => $composableBuilder(
    column: $table.resolutionRevisionId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get redactionProofJson => $composableBuilder(
    column: $table.redactionProofJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ConflictBranchesTableAnnotationComposer
    extends Composer<_$ClientDatabase, $ConflictBranchesTable> {
  $$ConflictBranchesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get conflictId => $composableBuilder(
    column: $table.conflictId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get vaultId =>
      $composableBuilder(column: $table.vaultId, builder: (column) => column);

  GeneratedColumn<String> get recordId =>
      $composableBuilder(column: $table.recordId, builder: (column) => column);

  GeneratedColumn<String> get instanceId => $composableBuilder(
    column: $table.instanceId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get serverSpaceId => $composableBuilder(
    column: $table.serverSpaceId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<String> get branchEnvelopeJson => $composableBuilder(
    column: $table.branchEnvelopeJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get remoteEnvelopeJson => $composableBuilder(
    column: $table.remoteEnvelopeJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get state =>
      $composableBuilder(column: $table.state, builder: (column) => column);

  GeneratedColumn<String> get resolutionOpId => $composableBuilder(
    column: $table.resolutionOpId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get resolutionRevisionId => $composableBuilder(
    column: $table.resolutionRevisionId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get redactionProofJson => $composableBuilder(
    column: $table.redactionProofJson,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);
}

class $$ConflictBranchesTableTableManager
    extends
        RootTableManager<
          _$ClientDatabase,
          $ConflictBranchesTable,
          ConflictBranche,
          $$ConflictBranchesTableFilterComposer,
          $$ConflictBranchesTableOrderingComposer,
          $$ConflictBranchesTableAnnotationComposer,
          $$ConflictBranchesTableCreateCompanionBuilder,
          $$ConflictBranchesTableUpdateCompanionBuilder,
          (
            ConflictBranche,
            BaseReferences<
              _$ClientDatabase,
              $ConflictBranchesTable,
              ConflictBranche
            >,
          ),
          ConflictBranche,
          PrefetchHooks Function()
        > {
  $$ConflictBranchesTableTableManager(
    _$ClientDatabase db,
    $ConflictBranchesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ConflictBranchesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ConflictBranchesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ConflictBranchesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> conflictId = const Value.absent(),
                Value<String> vaultId = const Value.absent(),
                Value<String> recordId = const Value.absent(),
                Value<String?> instanceId = const Value.absent(),
                Value<String?> serverSpaceId = const Value.absent(),
                Value<String> kind = const Value.absent(),
                Value<String> branchEnvelopeJson = const Value.absent(),
                Value<String> remoteEnvelopeJson = const Value.absent(),
                Value<String> state = const Value.absent(),
                Value<String?> resolutionOpId = const Value.absent(),
                Value<String?> resolutionRevisionId = const Value.absent(),
                Value<String?> redactionProofJson = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ConflictBranchesCompanion(
                conflictId: conflictId,
                vaultId: vaultId,
                recordId: recordId,
                instanceId: instanceId,
                serverSpaceId: serverSpaceId,
                kind: kind,
                branchEnvelopeJson: branchEnvelopeJson,
                remoteEnvelopeJson: remoteEnvelopeJson,
                state: state,
                resolutionOpId: resolutionOpId,
                resolutionRevisionId: resolutionRevisionId,
                redactionProofJson: redactionProofJson,
                createdAt: createdAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String conflictId,
                required String vaultId,
                required String recordId,
                Value<String?> instanceId = const Value.absent(),
                Value<String?> serverSpaceId = const Value.absent(),
                required String kind,
                required String branchEnvelopeJson,
                required String remoteEnvelopeJson,
                Value<String> state = const Value.absent(),
                Value<String?> resolutionOpId = const Value.absent(),
                Value<String?> resolutionRevisionId = const Value.absent(),
                Value<String?> redactionProofJson = const Value.absent(),
                required int createdAt,
                Value<int> rowid = const Value.absent(),
              }) => ConflictBranchesCompanion.insert(
                conflictId: conflictId,
                vaultId: vaultId,
                recordId: recordId,
                instanceId: instanceId,
                serverSpaceId: serverSpaceId,
                kind: kind,
                branchEnvelopeJson: branchEnvelopeJson,
                remoteEnvelopeJson: remoteEnvelopeJson,
                state: state,
                resolutionOpId: resolutionOpId,
                resolutionRevisionId: resolutionRevisionId,
                redactionProofJson: redactionProofJson,
                createdAt: createdAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ConflictBranchesTable, ConflictBranche>(table),
                  BaseReferences<
                    _$ClientDatabase,
                    $ConflictBranchesTable,
                    ConflictBranche
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ConflictBranchesTableProcessedTableManager =
    ProcessedTableManager<
      _$ClientDatabase,
      $ConflictBranchesTable,
      ConflictBranche,
      $$ConflictBranchesTableFilterComposer,
      $$ConflictBranchesTableOrderingComposer,
      $$ConflictBranchesTableAnnotationComposer,
      $$ConflictBranchesTableCreateCompanionBuilder,
      $$ConflictBranchesTableUpdateCompanionBuilder,
      (
        ConflictBranche,
        BaseReferences<
          _$ClientDatabase,
          $ConflictBranchesTable,
          ConflictBranche
        >,
      ),
      ConflictBranche,
      PrefetchHooks Function()
    >;
typedef $$TrustedDevicesTableCreateCompanionBuilder =
    TrustedDevicesCompanion Function({
      required String deviceId,
      required String signingPublicKey,
      Value<String?> displayNameEnvelope,
      Value<int> rowid,
    });
typedef $$TrustedDevicesTableUpdateCompanionBuilder =
    TrustedDevicesCompanion Function({
      Value<String> deviceId,
      Value<String> signingPublicKey,
      Value<String?> displayNameEnvelope,
      Value<int> rowid,
    });

class $$TrustedDevicesTableFilterComposer
    extends Composer<_$ClientDatabase, $TrustedDevicesTable> {
  $$TrustedDevicesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get signingPublicKey => $composableBuilder(
    column: $table.signingPublicKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get displayNameEnvelope => $composableBuilder(
    column: $table.displayNameEnvelope,
    builder: (column) => ColumnFilters(column),
  );
}

class $$TrustedDevicesTableOrderingComposer
    extends Composer<_$ClientDatabase, $TrustedDevicesTable> {
  $$TrustedDevicesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get signingPublicKey => $composableBuilder(
    column: $table.signingPublicKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get displayNameEnvelope => $composableBuilder(
    column: $table.displayNameEnvelope,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$TrustedDevicesTableAnnotationComposer
    extends Composer<_$ClientDatabase, $TrustedDevicesTable> {
  $$TrustedDevicesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get deviceId =>
      $composableBuilder(column: $table.deviceId, builder: (column) => column);

  GeneratedColumn<String> get signingPublicKey => $composableBuilder(
    column: $table.signingPublicKey,
    builder: (column) => column,
  );

  GeneratedColumn<String> get displayNameEnvelope => $composableBuilder(
    column: $table.displayNameEnvelope,
    builder: (column) => column,
  );
}

class $$TrustedDevicesTableTableManager
    extends
        RootTableManager<
          _$ClientDatabase,
          $TrustedDevicesTable,
          TrustedDevice,
          $$TrustedDevicesTableFilterComposer,
          $$TrustedDevicesTableOrderingComposer,
          $$TrustedDevicesTableAnnotationComposer,
          $$TrustedDevicesTableCreateCompanionBuilder,
          $$TrustedDevicesTableUpdateCompanionBuilder,
          (
            TrustedDevice,
            BaseReferences<
              _$ClientDatabase,
              $TrustedDevicesTable,
              TrustedDevice
            >,
          ),
          TrustedDevice,
          PrefetchHooks Function()
        > {
  $$TrustedDevicesTableTableManager(
    _$ClientDatabase db,
    $TrustedDevicesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TrustedDevicesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$TrustedDevicesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$TrustedDevicesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> deviceId = const Value.absent(),
                Value<String> signingPublicKey = const Value.absent(),
                Value<String?> displayNameEnvelope = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TrustedDevicesCompanion(
                deviceId: deviceId,
                signingPublicKey: signingPublicKey,
                displayNameEnvelope: displayNameEnvelope,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String deviceId,
                required String signingPublicKey,
                Value<String?> displayNameEnvelope = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TrustedDevicesCompanion.insert(
                deviceId: deviceId,
                signingPublicKey: signingPublicKey,
                displayNameEnvelope: displayNameEnvelope,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$TrustedDevicesTable, TrustedDevice>(table),
                  BaseReferences<
                    _$ClientDatabase,
                    $TrustedDevicesTable,
                    TrustedDevice
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$TrustedDevicesTableProcessedTableManager =
    ProcessedTableManager<
      _$ClientDatabase,
      $TrustedDevicesTable,
      TrustedDevice,
      $$TrustedDevicesTableFilterComposer,
      $$TrustedDevicesTableOrderingComposer,
      $$TrustedDevicesTableAnnotationComposer,
      $$TrustedDevicesTableCreateCompanionBuilder,
      $$TrustedDevicesTableUpdateCompanionBuilder,
      (
        TrustedDevice,
        BaseReferences<_$ClientDatabase, $TrustedDevicesTable, TrustedDevice>,
      ),
      TrustedDevice,
      PrefetchHooks Function()
    >;
typedef $$DeviceSequencesTableCreateCompanionBuilder =
    DeviceSequencesCompanion Function({
      required String deviceId,
      Value<int> nextSequence,
      Value<int> rowid,
    });
typedef $$DeviceSequencesTableUpdateCompanionBuilder =
    DeviceSequencesCompanion Function({
      Value<String> deviceId,
      Value<int> nextSequence,
      Value<int> rowid,
    });

class $$DeviceSequencesTableFilterComposer
    extends Composer<_$ClientDatabase, $DeviceSequencesTable> {
  $$DeviceSequencesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get nextSequence => $composableBuilder(
    column: $table.nextSequence,
    builder: (column) => ColumnFilters(column),
  );
}

class $$DeviceSequencesTableOrderingComposer
    extends Composer<_$ClientDatabase, $DeviceSequencesTable> {
  $$DeviceSequencesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get nextSequence => $composableBuilder(
    column: $table.nextSequence,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$DeviceSequencesTableAnnotationComposer
    extends Composer<_$ClientDatabase, $DeviceSequencesTable> {
  $$DeviceSequencesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get deviceId =>
      $composableBuilder(column: $table.deviceId, builder: (column) => column);

  GeneratedColumn<int> get nextSequence => $composableBuilder(
    column: $table.nextSequence,
    builder: (column) => column,
  );
}

class $$DeviceSequencesTableTableManager
    extends
        RootTableManager<
          _$ClientDatabase,
          $DeviceSequencesTable,
          DeviceSequence,
          $$DeviceSequencesTableFilterComposer,
          $$DeviceSequencesTableOrderingComposer,
          $$DeviceSequencesTableAnnotationComposer,
          $$DeviceSequencesTableCreateCompanionBuilder,
          $$DeviceSequencesTableUpdateCompanionBuilder,
          (
            DeviceSequence,
            BaseReferences<
              _$ClientDatabase,
              $DeviceSequencesTable,
              DeviceSequence
            >,
          ),
          DeviceSequence,
          PrefetchHooks Function()
        > {
  $$DeviceSequencesTableTableManager(
    _$ClientDatabase db,
    $DeviceSequencesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$DeviceSequencesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$DeviceSequencesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$DeviceSequencesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> deviceId = const Value.absent(),
                Value<int> nextSequence = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => DeviceSequencesCompanion(
                deviceId: deviceId,
                nextSequence: nextSequence,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String deviceId,
                Value<int> nextSequence = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => DeviceSequencesCompanion.insert(
                deviceId: deviceId,
                nextSequence: nextSequence,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$DeviceSequencesTable, DeviceSequence>(table),
                  BaseReferences<
                    _$ClientDatabase,
                    $DeviceSequencesTable,
                    DeviceSequence
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$DeviceSequencesTableProcessedTableManager =
    ProcessedTableManager<
      _$ClientDatabase,
      $DeviceSequencesTable,
      DeviceSequence,
      $$DeviceSequencesTableFilterComposer,
      $$DeviceSequencesTableOrderingComposer,
      $$DeviceSequencesTableAnnotationComposer,
      $$DeviceSequencesTableCreateCompanionBuilder,
      $$DeviceSequencesTableUpdateCompanionBuilder,
      (
        DeviceSequence,
        BaseReferences<_$ClientDatabase, $DeviceSequencesTable, DeviceSequence>,
      ),
      DeviceSequence,
      PrefetchHooks Function()
    >;
typedef $$VaultArchiveObjectsTableCreateCompanionBuilder =
    VaultArchiveObjectsCompanion Function({
      required String vaultId,
      required String objectId,
      required Uint8List bytes,
      required String sha256,
      required int importedAt,
      Value<int> rowid,
    });
typedef $$VaultArchiveObjectsTableUpdateCompanionBuilder =
    VaultArchiveObjectsCompanion Function({
      Value<String> vaultId,
      Value<String> objectId,
      Value<Uint8List> bytes,
      Value<String> sha256,
      Value<int> importedAt,
      Value<int> rowid,
    });

class $$VaultArchiveObjectsTableFilterComposer
    extends Composer<_$ClientDatabase, $VaultArchiveObjectsTable> {
  $$VaultArchiveObjectsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get vaultId => $composableBuilder(
    column: $table.vaultId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get objectId => $composableBuilder(
    column: $table.objectId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get bytes => $composableBuilder(
    column: $table.bytes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sha256 => $composableBuilder(
    column: $table.sha256,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get importedAt => $composableBuilder(
    column: $table.importedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$VaultArchiveObjectsTableOrderingComposer
    extends Composer<_$ClientDatabase, $VaultArchiveObjectsTable> {
  $$VaultArchiveObjectsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get vaultId => $composableBuilder(
    column: $table.vaultId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get objectId => $composableBuilder(
    column: $table.objectId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get bytes => $composableBuilder(
    column: $table.bytes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sha256 => $composableBuilder(
    column: $table.sha256,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get importedAt => $composableBuilder(
    column: $table.importedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$VaultArchiveObjectsTableAnnotationComposer
    extends Composer<_$ClientDatabase, $VaultArchiveObjectsTable> {
  $$VaultArchiveObjectsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get vaultId =>
      $composableBuilder(column: $table.vaultId, builder: (column) => column);

  GeneratedColumn<String> get objectId =>
      $composableBuilder(column: $table.objectId, builder: (column) => column);

  GeneratedColumn<Uint8List> get bytes =>
      $composableBuilder(column: $table.bytes, builder: (column) => column);

  GeneratedColumn<String> get sha256 =>
      $composableBuilder(column: $table.sha256, builder: (column) => column);

  GeneratedColumn<int> get importedAt => $composableBuilder(
    column: $table.importedAt,
    builder: (column) => column,
  );
}

class $$VaultArchiveObjectsTableTableManager
    extends
        RootTableManager<
          _$ClientDatabase,
          $VaultArchiveObjectsTable,
          VaultArchiveObject,
          $$VaultArchiveObjectsTableFilterComposer,
          $$VaultArchiveObjectsTableOrderingComposer,
          $$VaultArchiveObjectsTableAnnotationComposer,
          $$VaultArchiveObjectsTableCreateCompanionBuilder,
          $$VaultArchiveObjectsTableUpdateCompanionBuilder,
          (
            VaultArchiveObject,
            BaseReferences<
              _$ClientDatabase,
              $VaultArchiveObjectsTable,
              VaultArchiveObject
            >,
          ),
          VaultArchiveObject,
          PrefetchHooks Function()
        > {
  $$VaultArchiveObjectsTableTableManager(
    _$ClientDatabase db,
    $VaultArchiveObjectsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$VaultArchiveObjectsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$VaultArchiveObjectsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$VaultArchiveObjectsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> vaultId = const Value.absent(),
                Value<String> objectId = const Value.absent(),
                Value<Uint8List> bytes = const Value.absent(),
                Value<String> sha256 = const Value.absent(),
                Value<int> importedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => VaultArchiveObjectsCompanion(
                vaultId: vaultId,
                objectId: objectId,
                bytes: bytes,
                sha256: sha256,
                importedAt: importedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String vaultId,
                required String objectId,
                required Uint8List bytes,
                required String sha256,
                required int importedAt,
                Value<int> rowid = const Value.absent(),
              }) => VaultArchiveObjectsCompanion.insert(
                vaultId: vaultId,
                objectId: objectId,
                bytes: bytes,
                sha256: sha256,
                importedAt: importedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$VaultArchiveObjectsTable, VaultArchiveObject>(
                    table,
                  ),
                  BaseReferences<
                    _$ClientDatabase,
                    $VaultArchiveObjectsTable,
                    VaultArchiveObject
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$VaultArchiveObjectsTableProcessedTableManager =
    ProcessedTableManager<
      _$ClientDatabase,
      $VaultArchiveObjectsTable,
      VaultArchiveObject,
      $$VaultArchiveObjectsTableFilterComposer,
      $$VaultArchiveObjectsTableOrderingComposer,
      $$VaultArchiveObjectsTableAnnotationComposer,
      $$VaultArchiveObjectsTableCreateCompanionBuilder,
      $$VaultArchiveObjectsTableUpdateCompanionBuilder,
      (
        VaultArchiveObject,
        BaseReferences<
          _$ClientDatabase,
          $VaultArchiveObjectsTable,
          VaultArchiveObject
        >,
      ),
      VaultArchiveObject,
      PrefetchHooks Function()
    >;
typedef $$BlobJobsTableCreateCompanionBuilder =
    BlobJobsCompanion Function({
      required String jobId,
      required String vaultId,
      required String recordId,
      Value<String?> instanceId,
      Value<String?> serverSpaceId,
      required String blobId,
      required String direction,
      required String state,
      Value<int> totalObjects,
      Value<int> attemptCount,
      Value<String?> lastErrorCode,
      required int createdAt,
      required int updatedAt,
      Value<int> rowid,
    });
typedef $$BlobJobsTableUpdateCompanionBuilder =
    BlobJobsCompanion Function({
      Value<String> jobId,
      Value<String> vaultId,
      Value<String> recordId,
      Value<String?> instanceId,
      Value<String?> serverSpaceId,
      Value<String> blobId,
      Value<String> direction,
      Value<String> state,
      Value<int> totalObjects,
      Value<int> attemptCount,
      Value<String?> lastErrorCode,
      Value<int> createdAt,
      Value<int> updatedAt,
      Value<int> rowid,
    });

class $$BlobJobsTableFilterComposer
    extends Composer<_$ClientDatabase, $BlobJobsTable> {
  $$BlobJobsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get jobId => $composableBuilder(
    column: $table.jobId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get vaultId => $composableBuilder(
    column: $table.vaultId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get recordId => $composableBuilder(
    column: $table.recordId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get instanceId => $composableBuilder(
    column: $table.instanceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverSpaceId => $composableBuilder(
    column: $table.serverSpaceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get blobId => $composableBuilder(
    column: $table.blobId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get direction => $composableBuilder(
    column: $table.direction,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get totalObjects => $composableBuilder(
    column: $table.totalObjects,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get attemptCount => $composableBuilder(
    column: $table.attemptCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lastErrorCode => $composableBuilder(
    column: $table.lastErrorCode,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$BlobJobsTableOrderingComposer
    extends Composer<_$ClientDatabase, $BlobJobsTable> {
  $$BlobJobsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get jobId => $composableBuilder(
    column: $table.jobId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get vaultId => $composableBuilder(
    column: $table.vaultId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get recordId => $composableBuilder(
    column: $table.recordId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get instanceId => $composableBuilder(
    column: $table.instanceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverSpaceId => $composableBuilder(
    column: $table.serverSpaceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get blobId => $composableBuilder(
    column: $table.blobId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get direction => $composableBuilder(
    column: $table.direction,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get totalObjects => $composableBuilder(
    column: $table.totalObjects,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get attemptCount => $composableBuilder(
    column: $table.attemptCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lastErrorCode => $composableBuilder(
    column: $table.lastErrorCode,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$BlobJobsTableAnnotationComposer
    extends Composer<_$ClientDatabase, $BlobJobsTable> {
  $$BlobJobsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get jobId =>
      $composableBuilder(column: $table.jobId, builder: (column) => column);

  GeneratedColumn<String> get vaultId =>
      $composableBuilder(column: $table.vaultId, builder: (column) => column);

  GeneratedColumn<String> get recordId =>
      $composableBuilder(column: $table.recordId, builder: (column) => column);

  GeneratedColumn<String> get instanceId => $composableBuilder(
    column: $table.instanceId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get serverSpaceId => $composableBuilder(
    column: $table.serverSpaceId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get blobId =>
      $composableBuilder(column: $table.blobId, builder: (column) => column);

  GeneratedColumn<String> get direction =>
      $composableBuilder(column: $table.direction, builder: (column) => column);

  GeneratedColumn<String> get state =>
      $composableBuilder(column: $table.state, builder: (column) => column);

  GeneratedColumn<int> get totalObjects => $composableBuilder(
    column: $table.totalObjects,
    builder: (column) => column,
  );

  GeneratedColumn<int> get attemptCount => $composableBuilder(
    column: $table.attemptCount,
    builder: (column) => column,
  );

  GeneratedColumn<String> get lastErrorCode => $composableBuilder(
    column: $table.lastErrorCode,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$BlobJobsTableTableManager
    extends
        RootTableManager<
          _$ClientDatabase,
          $BlobJobsTable,
          BlobJob,
          $$BlobJobsTableFilterComposer,
          $$BlobJobsTableOrderingComposer,
          $$BlobJobsTableAnnotationComposer,
          $$BlobJobsTableCreateCompanionBuilder,
          $$BlobJobsTableUpdateCompanionBuilder,
          (BlobJob, BaseReferences<_$ClientDatabase, $BlobJobsTable, BlobJob>),
          BlobJob,
          PrefetchHooks Function()
        > {
  $$BlobJobsTableTableManager(_$ClientDatabase db, $BlobJobsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$BlobJobsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$BlobJobsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$BlobJobsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> jobId = const Value.absent(),
                Value<String> vaultId = const Value.absent(),
                Value<String> recordId = const Value.absent(),
                Value<String?> instanceId = const Value.absent(),
                Value<String?> serverSpaceId = const Value.absent(),
                Value<String> blobId = const Value.absent(),
                Value<String> direction = const Value.absent(),
                Value<String> state = const Value.absent(),
                Value<int> totalObjects = const Value.absent(),
                Value<int> attemptCount = const Value.absent(),
                Value<String?> lastErrorCode = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => BlobJobsCompanion(
                jobId: jobId,
                vaultId: vaultId,
                recordId: recordId,
                instanceId: instanceId,
                serverSpaceId: serverSpaceId,
                blobId: blobId,
                direction: direction,
                state: state,
                totalObjects: totalObjects,
                attemptCount: attemptCount,
                lastErrorCode: lastErrorCode,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String jobId,
                required String vaultId,
                required String recordId,
                Value<String?> instanceId = const Value.absent(),
                Value<String?> serverSpaceId = const Value.absent(),
                required String blobId,
                required String direction,
                required String state,
                Value<int> totalObjects = const Value.absent(),
                Value<int> attemptCount = const Value.absent(),
                Value<String?> lastErrorCode = const Value.absent(),
                required int createdAt,
                required int updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => BlobJobsCompanion.insert(
                jobId: jobId,
                vaultId: vaultId,
                recordId: recordId,
                instanceId: instanceId,
                serverSpaceId: serverSpaceId,
                blobId: blobId,
                direction: direction,
                state: state,
                totalObjects: totalObjects,
                attemptCount: attemptCount,
                lastErrorCode: lastErrorCode,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$BlobJobsTable, BlobJob>(table),
                  BaseReferences<_$ClientDatabase, $BlobJobsTable, BlobJob>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$BlobJobsTableProcessedTableManager =
    ProcessedTableManager<
      _$ClientDatabase,
      $BlobJobsTable,
      BlobJob,
      $$BlobJobsTableFilterComposer,
      $$BlobJobsTableOrderingComposer,
      $$BlobJobsTableAnnotationComposer,
      $$BlobJobsTableCreateCompanionBuilder,
      $$BlobJobsTableUpdateCompanionBuilder,
      (BlobJob, BaseReferences<_$ClientDatabase, $BlobJobsTable, BlobJob>),
      BlobJob,
      PrefetchHooks Function()
    >;
typedef $$BlobJobObjectsTableCreateCompanionBuilder =
    BlobJobObjectsCompanion Function({
      required String jobId,
      required String objectId,
      required String sha256,
      required int size,
      Value<Uint8List?> bytes,
      Value<String?> uploadId,
      Value<int?> uploadChunkSize,
      Value<int> nextChunkIndex,
      Value<bool> transferred,
      Value<int> rowid,
    });
typedef $$BlobJobObjectsTableUpdateCompanionBuilder =
    BlobJobObjectsCompanion Function({
      Value<String> jobId,
      Value<String> objectId,
      Value<String> sha256,
      Value<int> size,
      Value<Uint8List?> bytes,
      Value<String?> uploadId,
      Value<int?> uploadChunkSize,
      Value<int> nextChunkIndex,
      Value<bool> transferred,
      Value<int> rowid,
    });

class $$BlobJobObjectsTableFilterComposer
    extends Composer<_$ClientDatabase, $BlobJobObjectsTable> {
  $$BlobJobObjectsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get jobId => $composableBuilder(
    column: $table.jobId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get objectId => $composableBuilder(
    column: $table.objectId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sha256 => $composableBuilder(
    column: $table.sha256,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get size => $composableBuilder(
    column: $table.size,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get bytes => $composableBuilder(
    column: $table.bytes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get uploadId => $composableBuilder(
    column: $table.uploadId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get uploadChunkSize => $composableBuilder(
    column: $table.uploadChunkSize,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get nextChunkIndex => $composableBuilder(
    column: $table.nextChunkIndex,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get transferred => $composableBuilder(
    column: $table.transferred,
    builder: (column) => ColumnFilters(column),
  );
}

class $$BlobJobObjectsTableOrderingComposer
    extends Composer<_$ClientDatabase, $BlobJobObjectsTable> {
  $$BlobJobObjectsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get jobId => $composableBuilder(
    column: $table.jobId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get objectId => $composableBuilder(
    column: $table.objectId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sha256 => $composableBuilder(
    column: $table.sha256,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get size => $composableBuilder(
    column: $table.size,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get bytes => $composableBuilder(
    column: $table.bytes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get uploadId => $composableBuilder(
    column: $table.uploadId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get uploadChunkSize => $composableBuilder(
    column: $table.uploadChunkSize,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get nextChunkIndex => $composableBuilder(
    column: $table.nextChunkIndex,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get transferred => $composableBuilder(
    column: $table.transferred,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$BlobJobObjectsTableAnnotationComposer
    extends Composer<_$ClientDatabase, $BlobJobObjectsTable> {
  $$BlobJobObjectsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get jobId =>
      $composableBuilder(column: $table.jobId, builder: (column) => column);

  GeneratedColumn<String> get objectId =>
      $composableBuilder(column: $table.objectId, builder: (column) => column);

  GeneratedColumn<String> get sha256 =>
      $composableBuilder(column: $table.sha256, builder: (column) => column);

  GeneratedColumn<int> get size =>
      $composableBuilder(column: $table.size, builder: (column) => column);

  GeneratedColumn<Uint8List> get bytes =>
      $composableBuilder(column: $table.bytes, builder: (column) => column);

  GeneratedColumn<String> get uploadId =>
      $composableBuilder(column: $table.uploadId, builder: (column) => column);

  GeneratedColumn<int> get uploadChunkSize => $composableBuilder(
    column: $table.uploadChunkSize,
    builder: (column) => column,
  );

  GeneratedColumn<int> get nextChunkIndex => $composableBuilder(
    column: $table.nextChunkIndex,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get transferred => $composableBuilder(
    column: $table.transferred,
    builder: (column) => column,
  );
}

class $$BlobJobObjectsTableTableManager
    extends
        RootTableManager<
          _$ClientDatabase,
          $BlobJobObjectsTable,
          BlobJobObject,
          $$BlobJobObjectsTableFilterComposer,
          $$BlobJobObjectsTableOrderingComposer,
          $$BlobJobObjectsTableAnnotationComposer,
          $$BlobJobObjectsTableCreateCompanionBuilder,
          $$BlobJobObjectsTableUpdateCompanionBuilder,
          (
            BlobJobObject,
            BaseReferences<
              _$ClientDatabase,
              $BlobJobObjectsTable,
              BlobJobObject
            >,
          ),
          BlobJobObject,
          PrefetchHooks Function()
        > {
  $$BlobJobObjectsTableTableManager(
    _$ClientDatabase db,
    $BlobJobObjectsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$BlobJobObjectsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$BlobJobObjectsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$BlobJobObjectsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> jobId = const Value.absent(),
                Value<String> objectId = const Value.absent(),
                Value<String> sha256 = const Value.absent(),
                Value<int> size = const Value.absent(),
                Value<Uint8List?> bytes = const Value.absent(),
                Value<String?> uploadId = const Value.absent(),
                Value<int?> uploadChunkSize = const Value.absent(),
                Value<int> nextChunkIndex = const Value.absent(),
                Value<bool> transferred = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => BlobJobObjectsCompanion(
                jobId: jobId,
                objectId: objectId,
                sha256: sha256,
                size: size,
                bytes: bytes,
                uploadId: uploadId,
                uploadChunkSize: uploadChunkSize,
                nextChunkIndex: nextChunkIndex,
                transferred: transferred,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String jobId,
                required String objectId,
                required String sha256,
                required int size,
                Value<Uint8List?> bytes = const Value.absent(),
                Value<String?> uploadId = const Value.absent(),
                Value<int?> uploadChunkSize = const Value.absent(),
                Value<int> nextChunkIndex = const Value.absent(),
                Value<bool> transferred = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => BlobJobObjectsCompanion.insert(
                jobId: jobId,
                objectId: objectId,
                sha256: sha256,
                size: size,
                bytes: bytes,
                uploadId: uploadId,
                uploadChunkSize: uploadChunkSize,
                nextChunkIndex: nextChunkIndex,
                transferred: transferred,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$BlobJobObjectsTable, BlobJobObject>(table),
                  BaseReferences<
                    _$ClientDatabase,
                    $BlobJobObjectsTable,
                    BlobJobObject
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$BlobJobObjectsTableProcessedTableManager =
    ProcessedTableManager<
      _$ClientDatabase,
      $BlobJobObjectsTable,
      BlobJobObject,
      $$BlobJobObjectsTableFilterComposer,
      $$BlobJobObjectsTableOrderingComposer,
      $$BlobJobObjectsTableAnnotationComposer,
      $$BlobJobObjectsTableCreateCompanionBuilder,
      $$BlobJobObjectsTableUpdateCompanionBuilder,
      (
        BlobJobObject,
        BaseReferences<_$ClientDatabase, $BlobJobObjectsTable, BlobJobObject>,
      ),
      BlobJobObject,
      PrefetchHooks Function()
    >;
typedef $$ConflictFeedCheckpointsTableCreateCompanionBuilder =
    ConflictFeedCheckpointsCompanion Function({
      required String vaultId,
      Value<String> instanceId,
      Value<String> serverSpaceId,
      required String serverGeneration,
      required String partitionId,
      required String afterSeq,
      Value<int> rowid,
    });
typedef $$ConflictFeedCheckpointsTableUpdateCompanionBuilder =
    ConflictFeedCheckpointsCompanion Function({
      Value<String> vaultId,
      Value<String> instanceId,
      Value<String> serverSpaceId,
      Value<String> serverGeneration,
      Value<String> partitionId,
      Value<String> afterSeq,
      Value<int> rowid,
    });

class $$ConflictFeedCheckpointsTableFilterComposer
    extends Composer<_$ClientDatabase, $ConflictFeedCheckpointsTable> {
  $$ConflictFeedCheckpointsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get vaultId => $composableBuilder(
    column: $table.vaultId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get instanceId => $composableBuilder(
    column: $table.instanceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverSpaceId => $composableBuilder(
    column: $table.serverSpaceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverGeneration => $composableBuilder(
    column: $table.serverGeneration,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get partitionId => $composableBuilder(
    column: $table.partitionId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get afterSeq => $composableBuilder(
    column: $table.afterSeq,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ConflictFeedCheckpointsTableOrderingComposer
    extends Composer<_$ClientDatabase, $ConflictFeedCheckpointsTable> {
  $$ConflictFeedCheckpointsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get vaultId => $composableBuilder(
    column: $table.vaultId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get instanceId => $composableBuilder(
    column: $table.instanceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverSpaceId => $composableBuilder(
    column: $table.serverSpaceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverGeneration => $composableBuilder(
    column: $table.serverGeneration,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get partitionId => $composableBuilder(
    column: $table.partitionId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get afterSeq => $composableBuilder(
    column: $table.afterSeq,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ConflictFeedCheckpointsTableAnnotationComposer
    extends Composer<_$ClientDatabase, $ConflictFeedCheckpointsTable> {
  $$ConflictFeedCheckpointsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get vaultId =>
      $composableBuilder(column: $table.vaultId, builder: (column) => column);

  GeneratedColumn<String> get instanceId => $composableBuilder(
    column: $table.instanceId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get serverSpaceId => $composableBuilder(
    column: $table.serverSpaceId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get serverGeneration => $composableBuilder(
    column: $table.serverGeneration,
    builder: (column) => column,
  );

  GeneratedColumn<String> get partitionId => $composableBuilder(
    column: $table.partitionId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get afterSeq =>
      $composableBuilder(column: $table.afterSeq, builder: (column) => column);
}

class $$ConflictFeedCheckpointsTableTableManager
    extends
        RootTableManager<
          _$ClientDatabase,
          $ConflictFeedCheckpointsTable,
          ConflictFeedCheckpoint,
          $$ConflictFeedCheckpointsTableFilterComposer,
          $$ConflictFeedCheckpointsTableOrderingComposer,
          $$ConflictFeedCheckpointsTableAnnotationComposer,
          $$ConflictFeedCheckpointsTableCreateCompanionBuilder,
          $$ConflictFeedCheckpointsTableUpdateCompanionBuilder,
          (
            ConflictFeedCheckpoint,
            BaseReferences<
              _$ClientDatabase,
              $ConflictFeedCheckpointsTable,
              ConflictFeedCheckpoint
            >,
          ),
          ConflictFeedCheckpoint,
          PrefetchHooks Function()
        > {
  $$ConflictFeedCheckpointsTableTableManager(
    _$ClientDatabase db,
    $ConflictFeedCheckpointsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ConflictFeedCheckpointsTableFilterComposer(
                $db: db,
                $table: table,
              ),
          createOrderingComposer: () =>
              $$ConflictFeedCheckpointsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$ConflictFeedCheckpointsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> vaultId = const Value.absent(),
                Value<String> instanceId = const Value.absent(),
                Value<String> serverSpaceId = const Value.absent(),
                Value<String> serverGeneration = const Value.absent(),
                Value<String> partitionId = const Value.absent(),
                Value<String> afterSeq = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ConflictFeedCheckpointsCompanion(
                vaultId: vaultId,
                instanceId: instanceId,
                serverSpaceId: serverSpaceId,
                serverGeneration: serverGeneration,
                partitionId: partitionId,
                afterSeq: afterSeq,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String vaultId,
                Value<String> instanceId = const Value.absent(),
                Value<String> serverSpaceId = const Value.absent(),
                required String serverGeneration,
                required String partitionId,
                required String afterSeq,
                Value<int> rowid = const Value.absent(),
              }) => ConflictFeedCheckpointsCompanion.insert(
                vaultId: vaultId,
                instanceId: instanceId,
                serverSpaceId: serverSpaceId,
                serverGeneration: serverGeneration,
                partitionId: partitionId,
                afterSeq: afterSeq,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<
                    $ConflictFeedCheckpointsTable,
                    ConflictFeedCheckpoint
                  >(table),
                  BaseReferences<
                    _$ClientDatabase,
                    $ConflictFeedCheckpointsTable,
                    ConflictFeedCheckpoint
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ConflictFeedCheckpointsTableProcessedTableManager =
    ProcessedTableManager<
      _$ClientDatabase,
      $ConflictFeedCheckpointsTable,
      ConflictFeedCheckpoint,
      $$ConflictFeedCheckpointsTableFilterComposer,
      $$ConflictFeedCheckpointsTableOrderingComposer,
      $$ConflictFeedCheckpointsTableAnnotationComposer,
      $$ConflictFeedCheckpointsTableCreateCompanionBuilder,
      $$ConflictFeedCheckpointsTableUpdateCompanionBuilder,
      (
        ConflictFeedCheckpoint,
        BaseReferences<
          _$ClientDatabase,
          $ConflictFeedCheckpointsTable,
          ConflictFeedCheckpoint
        >,
      ),
      ConflictFeedCheckpoint,
      PrefetchHooks Function()
    >;
typedef $$ConflictFeedInboxTableCreateCompanionBuilder =
    ConflictFeedInboxCompanion Function({
      required String vaultId,
      required String serverGeneration,
      Value<String> instanceId,
      Value<String> serverSpaceId,
      required String partitionId,
      required String seq,
      required String conflictId,
      required String eventType,
      required String eventJson,
      Value<int> rowid,
    });
typedef $$ConflictFeedInboxTableUpdateCompanionBuilder =
    ConflictFeedInboxCompanion Function({
      Value<String> vaultId,
      Value<String> serverGeneration,
      Value<String> instanceId,
      Value<String> serverSpaceId,
      Value<String> partitionId,
      Value<String> seq,
      Value<String> conflictId,
      Value<String> eventType,
      Value<String> eventJson,
      Value<int> rowid,
    });

class $$ConflictFeedInboxTableFilterComposer
    extends Composer<_$ClientDatabase, $ConflictFeedInboxTable> {
  $$ConflictFeedInboxTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get vaultId => $composableBuilder(
    column: $table.vaultId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverGeneration => $composableBuilder(
    column: $table.serverGeneration,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get instanceId => $composableBuilder(
    column: $table.instanceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverSpaceId => $composableBuilder(
    column: $table.serverSpaceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get partitionId => $composableBuilder(
    column: $table.partitionId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get seq => $composableBuilder(
    column: $table.seq,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get conflictId => $composableBuilder(
    column: $table.conflictId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get eventType => $composableBuilder(
    column: $table.eventType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get eventJson => $composableBuilder(
    column: $table.eventJson,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ConflictFeedInboxTableOrderingComposer
    extends Composer<_$ClientDatabase, $ConflictFeedInboxTable> {
  $$ConflictFeedInboxTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get vaultId => $composableBuilder(
    column: $table.vaultId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverGeneration => $composableBuilder(
    column: $table.serverGeneration,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get instanceId => $composableBuilder(
    column: $table.instanceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverSpaceId => $composableBuilder(
    column: $table.serverSpaceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get partitionId => $composableBuilder(
    column: $table.partitionId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get seq => $composableBuilder(
    column: $table.seq,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get conflictId => $composableBuilder(
    column: $table.conflictId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get eventType => $composableBuilder(
    column: $table.eventType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get eventJson => $composableBuilder(
    column: $table.eventJson,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ConflictFeedInboxTableAnnotationComposer
    extends Composer<_$ClientDatabase, $ConflictFeedInboxTable> {
  $$ConflictFeedInboxTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get vaultId =>
      $composableBuilder(column: $table.vaultId, builder: (column) => column);

  GeneratedColumn<String> get serverGeneration => $composableBuilder(
    column: $table.serverGeneration,
    builder: (column) => column,
  );

  GeneratedColumn<String> get instanceId => $composableBuilder(
    column: $table.instanceId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get serverSpaceId => $composableBuilder(
    column: $table.serverSpaceId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get partitionId => $composableBuilder(
    column: $table.partitionId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get seq =>
      $composableBuilder(column: $table.seq, builder: (column) => column);

  GeneratedColumn<String> get conflictId => $composableBuilder(
    column: $table.conflictId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get eventType =>
      $composableBuilder(column: $table.eventType, builder: (column) => column);

  GeneratedColumn<String> get eventJson =>
      $composableBuilder(column: $table.eventJson, builder: (column) => column);
}

class $$ConflictFeedInboxTableTableManager
    extends
        RootTableManager<
          _$ClientDatabase,
          $ConflictFeedInboxTable,
          ConflictFeedInboxData,
          $$ConflictFeedInboxTableFilterComposer,
          $$ConflictFeedInboxTableOrderingComposer,
          $$ConflictFeedInboxTableAnnotationComposer,
          $$ConflictFeedInboxTableCreateCompanionBuilder,
          $$ConflictFeedInboxTableUpdateCompanionBuilder,
          (
            ConflictFeedInboxData,
            BaseReferences<
              _$ClientDatabase,
              $ConflictFeedInboxTable,
              ConflictFeedInboxData
            >,
          ),
          ConflictFeedInboxData,
          PrefetchHooks Function()
        > {
  $$ConflictFeedInboxTableTableManager(
    _$ClientDatabase db,
    $ConflictFeedInboxTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ConflictFeedInboxTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ConflictFeedInboxTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ConflictFeedInboxTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> vaultId = const Value.absent(),
                Value<String> serverGeneration = const Value.absent(),
                Value<String> instanceId = const Value.absent(),
                Value<String> serverSpaceId = const Value.absent(),
                Value<String> partitionId = const Value.absent(),
                Value<String> seq = const Value.absent(),
                Value<String> conflictId = const Value.absent(),
                Value<String> eventType = const Value.absent(),
                Value<String> eventJson = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ConflictFeedInboxCompanion(
                vaultId: vaultId,
                serverGeneration: serverGeneration,
                instanceId: instanceId,
                serverSpaceId: serverSpaceId,
                partitionId: partitionId,
                seq: seq,
                conflictId: conflictId,
                eventType: eventType,
                eventJson: eventJson,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String vaultId,
                required String serverGeneration,
                Value<String> instanceId = const Value.absent(),
                Value<String> serverSpaceId = const Value.absent(),
                required String partitionId,
                required String seq,
                required String conflictId,
                required String eventType,
                required String eventJson,
                Value<int> rowid = const Value.absent(),
              }) => ConflictFeedInboxCompanion.insert(
                vaultId: vaultId,
                serverGeneration: serverGeneration,
                instanceId: instanceId,
                serverSpaceId: serverSpaceId,
                partitionId: partitionId,
                seq: seq,
                conflictId: conflictId,
                eventType: eventType,
                eventJson: eventJson,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ConflictFeedInboxTable, ConflictFeedInboxData>(
                    table,
                  ),
                  BaseReferences<
                    _$ClientDatabase,
                    $ConflictFeedInboxTable,
                    ConflictFeedInboxData
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ConflictFeedInboxTableProcessedTableManager =
    ProcessedTableManager<
      _$ClientDatabase,
      $ConflictFeedInboxTable,
      ConflictFeedInboxData,
      $$ConflictFeedInboxTableFilterComposer,
      $$ConflictFeedInboxTableOrderingComposer,
      $$ConflictFeedInboxTableAnnotationComposer,
      $$ConflictFeedInboxTableCreateCompanionBuilder,
      $$ConflictFeedInboxTableUpdateCompanionBuilder,
      (
        ConflictFeedInboxData,
        BaseReferences<
          _$ClientDatabase,
          $ConflictFeedInboxTable,
          ConflictFeedInboxData
        >,
      ),
      ConflictFeedInboxData,
      PrefetchHooks Function()
    >;
typedef $$ConflictFeedStatesTableCreateCompanionBuilder =
    ConflictFeedStatesCompanion Function({
      required String vaultId,
      Value<String> instanceId,
      Value<String> serverSpaceId,
      required String serverGeneration,
      required String partitionId,
      Value<int> rowid,
    });
typedef $$ConflictFeedStatesTableUpdateCompanionBuilder =
    ConflictFeedStatesCompanion Function({
      Value<String> vaultId,
      Value<String> instanceId,
      Value<String> serverSpaceId,
      Value<String> serverGeneration,
      Value<String> partitionId,
      Value<int> rowid,
    });

class $$ConflictFeedStatesTableFilterComposer
    extends Composer<_$ClientDatabase, $ConflictFeedStatesTable> {
  $$ConflictFeedStatesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get vaultId => $composableBuilder(
    column: $table.vaultId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get instanceId => $composableBuilder(
    column: $table.instanceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverSpaceId => $composableBuilder(
    column: $table.serverSpaceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverGeneration => $composableBuilder(
    column: $table.serverGeneration,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get partitionId => $composableBuilder(
    column: $table.partitionId,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ConflictFeedStatesTableOrderingComposer
    extends Composer<_$ClientDatabase, $ConflictFeedStatesTable> {
  $$ConflictFeedStatesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get vaultId => $composableBuilder(
    column: $table.vaultId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get instanceId => $composableBuilder(
    column: $table.instanceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverSpaceId => $composableBuilder(
    column: $table.serverSpaceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverGeneration => $composableBuilder(
    column: $table.serverGeneration,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get partitionId => $composableBuilder(
    column: $table.partitionId,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ConflictFeedStatesTableAnnotationComposer
    extends Composer<_$ClientDatabase, $ConflictFeedStatesTable> {
  $$ConflictFeedStatesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get vaultId =>
      $composableBuilder(column: $table.vaultId, builder: (column) => column);

  GeneratedColumn<String> get instanceId => $composableBuilder(
    column: $table.instanceId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get serverSpaceId => $composableBuilder(
    column: $table.serverSpaceId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get serverGeneration => $composableBuilder(
    column: $table.serverGeneration,
    builder: (column) => column,
  );

  GeneratedColumn<String> get partitionId => $composableBuilder(
    column: $table.partitionId,
    builder: (column) => column,
  );
}

class $$ConflictFeedStatesTableTableManager
    extends
        RootTableManager<
          _$ClientDatabase,
          $ConflictFeedStatesTable,
          ConflictFeedState,
          $$ConflictFeedStatesTableFilterComposer,
          $$ConflictFeedStatesTableOrderingComposer,
          $$ConflictFeedStatesTableAnnotationComposer,
          $$ConflictFeedStatesTableCreateCompanionBuilder,
          $$ConflictFeedStatesTableUpdateCompanionBuilder,
          (
            ConflictFeedState,
            BaseReferences<
              _$ClientDatabase,
              $ConflictFeedStatesTable,
              ConflictFeedState
            >,
          ),
          ConflictFeedState,
          PrefetchHooks Function()
        > {
  $$ConflictFeedStatesTableTableManager(
    _$ClientDatabase db,
    $ConflictFeedStatesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ConflictFeedStatesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ConflictFeedStatesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ConflictFeedStatesTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> vaultId = const Value.absent(),
                Value<String> instanceId = const Value.absent(),
                Value<String> serverSpaceId = const Value.absent(),
                Value<String> serverGeneration = const Value.absent(),
                Value<String> partitionId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ConflictFeedStatesCompanion(
                vaultId: vaultId,
                instanceId: instanceId,
                serverSpaceId: serverSpaceId,
                serverGeneration: serverGeneration,
                partitionId: partitionId,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String vaultId,
                Value<String> instanceId = const Value.absent(),
                Value<String> serverSpaceId = const Value.absent(),
                required String serverGeneration,
                required String partitionId,
                Value<int> rowid = const Value.absent(),
              }) => ConflictFeedStatesCompanion.insert(
                vaultId: vaultId,
                instanceId: instanceId,
                serverSpaceId: serverSpaceId,
                serverGeneration: serverGeneration,
                partitionId: partitionId,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ConflictFeedStatesTable, ConflictFeedState>(
                    table,
                  ),
                  BaseReferences<
                    _$ClientDatabase,
                    $ConflictFeedStatesTable,
                    ConflictFeedState
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ConflictFeedStatesTableProcessedTableManager =
    ProcessedTableManager<
      _$ClientDatabase,
      $ConflictFeedStatesTable,
      ConflictFeedState,
      $$ConflictFeedStatesTableFilterComposer,
      $$ConflictFeedStatesTableOrderingComposer,
      $$ConflictFeedStatesTableAnnotationComposer,
      $$ConflictFeedStatesTableCreateCompanionBuilder,
      $$ConflictFeedStatesTableUpdateCompanionBuilder,
      (
        ConflictFeedState,
        BaseReferences<
          _$ClientDatabase,
          $ConflictFeedStatesTable,
          ConflictFeedState
        >,
      ),
      ConflictFeedState,
      PrefetchHooks Function()
    >;
typedef $$FeedConflictResolutionsTableCreateCompanionBuilder =
    FeedConflictResolutionsCompanion Function({
      required String conflictId,
      required String vaultId,
      required String recordId,
      Value<String?> instanceId,
      Value<String?> serverSpaceId,
      Value<String?> opId,
      required String resolutionRevisionId,
      required String state,
      required int createdAt,
      required int updatedAt,
      Value<int> rowid,
    });
typedef $$FeedConflictResolutionsTableUpdateCompanionBuilder =
    FeedConflictResolutionsCompanion Function({
      Value<String> conflictId,
      Value<String> vaultId,
      Value<String> recordId,
      Value<String?> instanceId,
      Value<String?> serverSpaceId,
      Value<String?> opId,
      Value<String> resolutionRevisionId,
      Value<String> state,
      Value<int> createdAt,
      Value<int> updatedAt,
      Value<int> rowid,
    });

class $$FeedConflictResolutionsTableFilterComposer
    extends Composer<_$ClientDatabase, $FeedConflictResolutionsTable> {
  $$FeedConflictResolutionsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get conflictId => $composableBuilder(
    column: $table.conflictId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get vaultId => $composableBuilder(
    column: $table.vaultId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get recordId => $composableBuilder(
    column: $table.recordId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get instanceId => $composableBuilder(
    column: $table.instanceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverSpaceId => $composableBuilder(
    column: $table.serverSpaceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get opId => $composableBuilder(
    column: $table.opId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get resolutionRevisionId => $composableBuilder(
    column: $table.resolutionRevisionId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$FeedConflictResolutionsTableOrderingComposer
    extends Composer<_$ClientDatabase, $FeedConflictResolutionsTable> {
  $$FeedConflictResolutionsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get conflictId => $composableBuilder(
    column: $table.conflictId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get vaultId => $composableBuilder(
    column: $table.vaultId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get recordId => $composableBuilder(
    column: $table.recordId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get instanceId => $composableBuilder(
    column: $table.instanceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverSpaceId => $composableBuilder(
    column: $table.serverSpaceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get opId => $composableBuilder(
    column: $table.opId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get resolutionRevisionId => $composableBuilder(
    column: $table.resolutionRevisionId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$FeedConflictResolutionsTableAnnotationComposer
    extends Composer<_$ClientDatabase, $FeedConflictResolutionsTable> {
  $$FeedConflictResolutionsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get conflictId => $composableBuilder(
    column: $table.conflictId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get vaultId =>
      $composableBuilder(column: $table.vaultId, builder: (column) => column);

  GeneratedColumn<String> get recordId =>
      $composableBuilder(column: $table.recordId, builder: (column) => column);

  GeneratedColumn<String> get instanceId => $composableBuilder(
    column: $table.instanceId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get serverSpaceId => $composableBuilder(
    column: $table.serverSpaceId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get opId =>
      $composableBuilder(column: $table.opId, builder: (column) => column);

  GeneratedColumn<String> get resolutionRevisionId => $composableBuilder(
    column: $table.resolutionRevisionId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get state =>
      $composableBuilder(column: $table.state, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$FeedConflictResolutionsTableTableManager
    extends
        RootTableManager<
          _$ClientDatabase,
          $FeedConflictResolutionsTable,
          FeedConflictResolution,
          $$FeedConflictResolutionsTableFilterComposer,
          $$FeedConflictResolutionsTableOrderingComposer,
          $$FeedConflictResolutionsTableAnnotationComposer,
          $$FeedConflictResolutionsTableCreateCompanionBuilder,
          $$FeedConflictResolutionsTableUpdateCompanionBuilder,
          (
            FeedConflictResolution,
            BaseReferences<
              _$ClientDatabase,
              $FeedConflictResolutionsTable,
              FeedConflictResolution
            >,
          ),
          FeedConflictResolution,
          PrefetchHooks Function()
        > {
  $$FeedConflictResolutionsTableTableManager(
    _$ClientDatabase db,
    $FeedConflictResolutionsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$FeedConflictResolutionsTableFilterComposer(
                $db: db,
                $table: table,
              ),
          createOrderingComposer: () =>
              $$FeedConflictResolutionsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$FeedConflictResolutionsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> conflictId = const Value.absent(),
                Value<String> vaultId = const Value.absent(),
                Value<String> recordId = const Value.absent(),
                Value<String?> instanceId = const Value.absent(),
                Value<String?> serverSpaceId = const Value.absent(),
                Value<String?> opId = const Value.absent(),
                Value<String> resolutionRevisionId = const Value.absent(),
                Value<String> state = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => FeedConflictResolutionsCompanion(
                conflictId: conflictId,
                vaultId: vaultId,
                recordId: recordId,
                instanceId: instanceId,
                serverSpaceId: serverSpaceId,
                opId: opId,
                resolutionRevisionId: resolutionRevisionId,
                state: state,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String conflictId,
                required String vaultId,
                required String recordId,
                Value<String?> instanceId = const Value.absent(),
                Value<String?> serverSpaceId = const Value.absent(),
                Value<String?> opId = const Value.absent(),
                required String resolutionRevisionId,
                required String state,
                required int createdAt,
                required int updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => FeedConflictResolutionsCompanion.insert(
                conflictId: conflictId,
                vaultId: vaultId,
                recordId: recordId,
                instanceId: instanceId,
                serverSpaceId: serverSpaceId,
                opId: opId,
                resolutionRevisionId: resolutionRevisionId,
                state: state,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<
                    $FeedConflictResolutionsTable,
                    FeedConflictResolution
                  >(table),
                  BaseReferences<
                    _$ClientDatabase,
                    $FeedConflictResolutionsTable,
                    FeedConflictResolution
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$FeedConflictResolutionsTableProcessedTableManager =
    ProcessedTableManager<
      _$ClientDatabase,
      $FeedConflictResolutionsTable,
      FeedConflictResolution,
      $$FeedConflictResolutionsTableFilterComposer,
      $$FeedConflictResolutionsTableOrderingComposer,
      $$FeedConflictResolutionsTableAnnotationComposer,
      $$FeedConflictResolutionsTableCreateCompanionBuilder,
      $$FeedConflictResolutionsTableUpdateCompanionBuilder,
      (
        FeedConflictResolution,
        BaseReferences<
          _$ClientDatabase,
          $FeedConflictResolutionsTable,
          FeedConflictResolution
        >,
      ),
      FeedConflictResolution,
      PrefetchHooks Function()
    >;
typedef $$TerminalHistoryEntriesTableCreateCompanionBuilder =
    TerminalHistoryEntriesCompanion Function({
      required String serverNamespace,
      required String accountId,
      required String deviceId,
      required String entryId,
      required Uint8List ciphertext,
      required int createdAt,
      required int updatedAt,
      Value<int> rowid,
    });
typedef $$TerminalHistoryEntriesTableUpdateCompanionBuilder =
    TerminalHistoryEntriesCompanion Function({
      Value<String> serverNamespace,
      Value<String> accountId,
      Value<String> deviceId,
      Value<String> entryId,
      Value<Uint8List> ciphertext,
      Value<int> createdAt,
      Value<int> updatedAt,
      Value<int> rowid,
    });

class $$TerminalHistoryEntriesTableFilterComposer
    extends Composer<_$ClientDatabase, $TerminalHistoryEntriesTable> {
  $$TerminalHistoryEntriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get serverNamespace => $composableBuilder(
    column: $table.serverNamespace,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get entryId => $composableBuilder(
    column: $table.entryId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get ciphertext => $composableBuilder(
    column: $table.ciphertext,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$TerminalHistoryEntriesTableOrderingComposer
    extends Composer<_$ClientDatabase, $TerminalHistoryEntriesTable> {
  $$TerminalHistoryEntriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get serverNamespace => $composableBuilder(
    column: $table.serverNamespace,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get accountId => $composableBuilder(
    column: $table.accountId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get entryId => $composableBuilder(
    column: $table.entryId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get ciphertext => $composableBuilder(
    column: $table.ciphertext,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$TerminalHistoryEntriesTableAnnotationComposer
    extends Composer<_$ClientDatabase, $TerminalHistoryEntriesTable> {
  $$TerminalHistoryEntriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get serverNamespace => $composableBuilder(
    column: $table.serverNamespace,
    builder: (column) => column,
  );

  GeneratedColumn<String> get accountId =>
      $composableBuilder(column: $table.accountId, builder: (column) => column);

  GeneratedColumn<String> get deviceId =>
      $composableBuilder(column: $table.deviceId, builder: (column) => column);

  GeneratedColumn<String> get entryId =>
      $composableBuilder(column: $table.entryId, builder: (column) => column);

  GeneratedColumn<Uint8List> get ciphertext => $composableBuilder(
    column: $table.ciphertext,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$TerminalHistoryEntriesTableTableManager
    extends
        RootTableManager<
          _$ClientDatabase,
          $TerminalHistoryEntriesTable,
          TerminalHistoryEntry,
          $$TerminalHistoryEntriesTableFilterComposer,
          $$TerminalHistoryEntriesTableOrderingComposer,
          $$TerminalHistoryEntriesTableAnnotationComposer,
          $$TerminalHistoryEntriesTableCreateCompanionBuilder,
          $$TerminalHistoryEntriesTableUpdateCompanionBuilder,
          (
            TerminalHistoryEntry,
            BaseReferences<
              _$ClientDatabase,
              $TerminalHistoryEntriesTable,
              TerminalHistoryEntry
            >,
          ),
          TerminalHistoryEntry,
          PrefetchHooks Function()
        > {
  $$TerminalHistoryEntriesTableTableManager(
    _$ClientDatabase db,
    $TerminalHistoryEntriesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TerminalHistoryEntriesTableFilterComposer(
                $db: db,
                $table: table,
              ),
          createOrderingComposer: () =>
              $$TerminalHistoryEntriesTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$TerminalHistoryEntriesTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> serverNamespace = const Value.absent(),
                Value<String> accountId = const Value.absent(),
                Value<String> deviceId = const Value.absent(),
                Value<String> entryId = const Value.absent(),
                Value<Uint8List> ciphertext = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TerminalHistoryEntriesCompanion(
                serverNamespace: serverNamespace,
                accountId: accountId,
                deviceId: deviceId,
                entryId: entryId,
                ciphertext: ciphertext,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String serverNamespace,
                required String accountId,
                required String deviceId,
                required String entryId,
                required Uint8List ciphertext,
                required int createdAt,
                required int updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => TerminalHistoryEntriesCompanion.insert(
                serverNamespace: serverNamespace,
                accountId: accountId,
                deviceId: deviceId,
                entryId: entryId,
                ciphertext: ciphertext,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<
                    $TerminalHistoryEntriesTable,
                    TerminalHistoryEntry
                  >(table),
                  BaseReferences<
                    _$ClientDatabase,
                    $TerminalHistoryEntriesTable,
                    TerminalHistoryEntry
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$TerminalHistoryEntriesTableProcessedTableManager =
    ProcessedTableManager<
      _$ClientDatabase,
      $TerminalHistoryEntriesTable,
      TerminalHistoryEntry,
      $$TerminalHistoryEntriesTableFilterComposer,
      $$TerminalHistoryEntriesTableOrderingComposer,
      $$TerminalHistoryEntriesTableAnnotationComposer,
      $$TerminalHistoryEntriesTableCreateCompanionBuilder,
      $$TerminalHistoryEntriesTableUpdateCompanionBuilder,
      (
        TerminalHistoryEntry,
        BaseReferences<
          _$ClientDatabase,
          $TerminalHistoryEntriesTable,
          TerminalHistoryEntry
        >,
      ),
      TerminalHistoryEntry,
      PrefetchHooks Function()
    >;

class $ClientDatabaseManager {
  final _$ClientDatabase _db;
  $ClientDatabaseManager(this._db);
  $$EncryptedRecordsTableTableManager get encryptedRecords =>
      $$EncryptedRecordsTableTableManager(_db, _db.encryptedRecords);
  $$PendingOperationsTableTableManager get pendingOperations =>
      $$PendingOperationsTableTableManager(_db, _db.pendingOperations);
  $$AuthenticatedPushReceiptsTableTableManager get authenticatedPushReceipts =>
      $$AuthenticatedPushReceiptsTableTableManager(
        _db,
        _db.authenticatedPushReceipts,
      );
  $$SyncCheckpointsTableTableManager get syncCheckpoints =>
      $$SyncCheckpointsTableTableManager(_db, _db.syncCheckpoints);
  $$LockedSyncCheckpointsTableTableManager get lockedSyncCheckpoints =>
      $$LockedSyncCheckpointsTableTableManager(_db, _db.lockedSyncCheckpoints);
  $$LockedSyncInboxPagesTableTableManager get lockedSyncInboxPages =>
      $$LockedSyncInboxPagesTableTableManager(_db, _db.lockedSyncInboxPages);
  $$SyncSnapshotRecoveryStagesTableTableManager
  get syncSnapshotRecoveryStages =>
      $$SyncSnapshotRecoveryStagesTableTableManager(
        _db,
        _db.syncSnapshotRecoveryStages,
      );
  $$SyncSnapshotRecoveryItemsTableTableManager get syncSnapshotRecoveryItems =>
      $$SyncSnapshotRecoveryItemsTableTableManager(
        _db,
        _db.syncSnapshotRecoveryItems,
      );
  $$SyncRedactionsTableTableManager get syncRedactions =>
      $$SyncRedactionsTableTableManager(_db, _db.syncRedactions);
  $$SyncSnapshotRecoveryCursorsTableTableManager
  get syncSnapshotRecoveryCursors =>
      $$SyncSnapshotRecoveryCursorsTableTableManager(
        _db,
        _db.syncSnapshotRecoveryCursors,
      );
  $$ConflictBranchesTableTableManager get conflictBranches =>
      $$ConflictBranchesTableTableManager(_db, _db.conflictBranches);
  $$TrustedDevicesTableTableManager get trustedDevices =>
      $$TrustedDevicesTableTableManager(_db, _db.trustedDevices);
  $$DeviceSequencesTableTableManager get deviceSequences =>
      $$DeviceSequencesTableTableManager(_db, _db.deviceSequences);
  $$VaultArchiveObjectsTableTableManager get vaultArchiveObjects =>
      $$VaultArchiveObjectsTableTableManager(_db, _db.vaultArchiveObjects);
  $$BlobJobsTableTableManager get blobJobs =>
      $$BlobJobsTableTableManager(_db, _db.blobJobs);
  $$BlobJobObjectsTableTableManager get blobJobObjects =>
      $$BlobJobObjectsTableTableManager(_db, _db.blobJobObjects);
  $$ConflictFeedCheckpointsTableTableManager get conflictFeedCheckpoints =>
      $$ConflictFeedCheckpointsTableTableManager(
        _db,
        _db.conflictFeedCheckpoints,
      );
  $$ConflictFeedInboxTableTableManager get conflictFeedInbox =>
      $$ConflictFeedInboxTableTableManager(_db, _db.conflictFeedInbox);
  $$ConflictFeedStatesTableTableManager get conflictFeedStates =>
      $$ConflictFeedStatesTableTableManager(_db, _db.conflictFeedStates);
  $$FeedConflictResolutionsTableTableManager get feedConflictResolutions =>
      $$FeedConflictResolutionsTableTableManager(
        _db,
        _db.feedConflictResolutions,
      );
  $$TerminalHistoryEntriesTableTableManager get terminalHistoryEntries =>
      $$TerminalHistoryEntriesTableTableManager(
        _db,
        _db.terminalHistoryEntries,
      );
}
