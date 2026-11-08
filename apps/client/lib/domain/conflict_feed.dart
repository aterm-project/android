import '../crypto/jcs.dart';

/// One opaque server conflict-feed event. `envelope` is ciphertext and is only
/// present for creation events; consuming this value never mutates record heads.
class ConflictChangeEvent {
  const ConflictChangeEvent({
    required this.seq,
    required this.type,
    required this.conflictId,
    required this.recordId,
    required this.baseRevisionId,
    required this.resolvedRevisionId,
    required this.createdAt,
    required this.envelope,
    this.redaction,
  });

  final String seq;
  final String type;
  final String conflictId;
  final String recordId;
  final String? baseRevisionId;
  final String? resolvedRevisionId;
  final String createdAt;
  final Map<String, dynamic>? envelope;
  final Map<String, dynamic>? redaction;

  factory ConflictChangeEvent.fromJson(Map<String, dynamic> json) {
    final type = json['type'];
    final expectedKeys = type == 'created'
        ? const {
            'seq',
            'type',
            'conflict_id',
            'record_id',
            'base_revision_id',
            'resolved_revision_id',
            'created_at',
            'envelope',
          }
        : type == 'resolved'
        ? const {
            'seq',
            'type',
            'conflict_id',
            'record_id',
            'base_revision_id',
            'resolved_revision_id',
            'created_at',
          }
        : type == 'redacted'
        ? const {'seq', 'type', 'conflict_id', 'record_id', 'redaction'}
        : null;
    if (expectedKeys == null || !_hasExactKeys(json, expectedKeys)) {
      throw const FormatException('Invalid conflict feed event shape.');
    }

    final seq = json['seq'];
    final conflictId = json['conflict_id'];
    final recordId = json['record_id'];
    final baseRevisionId = json['base_revision_id'];
    final resolvedRevisionId = json['resolved_revision_id'];
    final createdAt = json['created_at'];
    if (seq is! String ||
        !_isCanonicalDecimal(seq) ||
        conflictId is! String ||
        !_isCanonicalUuid(conflictId) ||
        recordId is! String ||
        !_isCanonicalUuid(recordId) ||
        (baseRevisionId != null &&
            (baseRevisionId is! String || !_isCanonicalUuid(baseRevisionId))) ||
        (type != 'redacted' &&
            (createdAt is! String || !_isIsoDateTime(createdAt)))) {
      throw const FormatException('Invalid conflict feed event fields.');
    }

    if (type == 'created') {
      if (resolvedRevisionId != null) {
        throw const FormatException(
          'A created conflict event cannot have a resolved revision.',
        );
      }
      final rawEnvelope = json['envelope'];
      if (rawEnvelope is! Map) {
        throw const FormatException(
          'A created conflict event must have an envelope object.',
        );
      }
      final envelope = _stringKeyedObject(rawEnvelope);
      try {
        canonicalJson(envelope);
      } on Object {
        throw const FormatException('Invalid conflict envelope object.');
      }
      return ConflictChangeEvent(
        seq: seq,
        type: type as String,
        conflictId: conflictId,
        recordId: recordId,
        baseRevisionId: baseRevisionId as String?,
        resolvedRevisionId: null,
        createdAt: createdAt,
        envelope: envelope,
      );
    }

    if (type == 'redacted') {
      final rawRedaction = json['redaction'];
      if (rawRedaction is! Map) {
        throw const FormatException('A redacted conflict event has no proof.');
      }
      return ConflictChangeEvent(
        seq: seq,
        type: type as String,
        conflictId: conflictId,
        recordId: recordId,
        baseRevisionId: null,
        resolvedRevisionId: null,
        createdAt: '',
        envelope: null,
        redaction: _stringKeyedObject(rawRedaction),
      );
    }

    if (resolvedRevisionId is! String ||
        !_isCanonicalUuid(resolvedRevisionId)) {
      throw const FormatException(
        'A resolved conflict event must have a resolved revision.',
      );
    }
    return ConflictChangeEvent(
      seq: seq,
      type: type as String,
      conflictId: conflictId,
      recordId: recordId,
      baseRevisionId: baseRevisionId as String?,
      resolvedRevisionId: resolvedRevisionId,
      createdAt: createdAt,
      envelope: null,
    );
  }

  Map<String, Object?> toJson() => type == 'redacted'
      ? {
          'seq': seq,
          'type': type,
          'conflict_id': conflictId,
          'record_id': recordId,
          'redaction': redaction,
        }
      : {
          'seq': seq,
          'type': type,
          'conflict_id': conflictId,
          'record_id': recordId,
          'base_revision_id': baseRevisionId,
          'resolved_revision_id': resolvedRevisionId,
          'created_at': createdAt,
          if (type == 'created') 'envelope': envelope,
        };

  String get canonicalEventJson => canonicalJson(toJson());
}

/// A fully validated, generation-bound page from the independent conflict log.
class ConflictChangesPage {
  const ConflictChangesPage({
    required this.vaultId,
    required this.afterSeq,
    required this.highWatermark,
    required this.events,
    required this.nextAfterSeq,
    required this.hasMore,
    required this.serverGeneration,
  });

  final String vaultId;
  final String afterSeq;
  final String highWatermark;
  final List<ConflictChangeEvent> events;
  final String nextAfterSeq;
  final bool hasMore;
  final String serverGeneration;

  Map<String, Object?> toJson() => {
    'vault_id': vaultId,
    'after_seq': afterSeq,
    'high_watermark': highWatermark,
    'events': events.map((event) => event.toJson()).toList(growable: false),
    'next_after_seq': nextAfterSeq,
    'has_more': hasMore,
    'server_generation': serverGeneration,
  };

  /// Revalidates even pages constructed outside the API parser before durable
  /// storage accepts them.
  void validate() {
    ConflictChangesPage.fromJson(
      toJson(),
      expectedVaultId: vaultId,
      expectedAfterSeq: afterSeq,
      limit: 100,
    );
  }

  factory ConflictChangesPage.fromJson(
    Map<String, dynamic> json, {
    required String expectedVaultId,
    required String expectedAfterSeq,
    required int limit,
  }) {
    const keys = {
      'vault_id',
      'after_seq',
      'high_watermark',
      'events',
      'next_after_seq',
      'has_more',
      'server_generation',
    };
    if (!_hasExactKeys(json, keys)) {
      throw const FormatException('Invalid conflict feed page shape.');
    }
    final vaultId = json['vault_id'];
    final afterSeq = json['after_seq'];
    final highWatermark = json['high_watermark'];
    final rawEvents = json['events'];
    final nextAfterSeq = json['next_after_seq'];
    final hasMore = json['has_more'];
    final serverGeneration = json['server_generation'];
    if (vaultId != expectedVaultId ||
        afterSeq != expectedAfterSeq ||
        afterSeq is! String ||
        !_isCanonicalDecimal(afterSeq) ||
        highWatermark is! String ||
        !_isCanonicalDecimal(highWatermark) ||
        rawEvents is! List ||
        rawEvents.length > limit ||
        nextAfterSeq is! String ||
        !_isCanonicalDecimal(nextAfterSeq) ||
        hasMore is! bool ||
        serverGeneration is! String ||
        !_isCanonicalUuid(serverGeneration)) {
      throw const FormatException('Invalid conflict feed page fields.');
    }
    if (_compareDecimal(highWatermark, afterSeq) < 0) {
      throw const FormatException('Conflict feed watermark moved backwards.');
    }

    final events = <ConflictChangeEvent>[];
    var previous = afterSeq;
    final conflictKinds = <String>{};
    for (final rawEvent in rawEvents) {
      if (rawEvent is! Map) {
        throw const FormatException('Conflict feed event must be an object.');
      }
      final event = ConflictChangeEvent.fromJson(_stringKeyedObject(rawEvent));
      if (_compareDecimal(event.seq, previous) <= 0 ||
          _compareDecimal(event.seq, highWatermark) > 0) {
        throw const FormatException(
          'Conflict feed event sequence is outside page order or watermark.',
        );
      }
      final conflictKind = event.type == 'redacted'
          ? '${event.conflictId}\u0000${event.type}\u0000${event.seq}'
          : '${event.conflictId}\u0000${event.type}';
      if (!conflictKinds.add(conflictKind)) {
        throw const FormatException(
          'Conflict feed page repeats a conflict event type.',
        );
      }
      events.add(event);
      previous = event.seq;
    }
    final expectedNext = events.isEmpty ? afterSeq : events.last.seq;
    if (nextAfterSeq != expectedNext ||
        (hasMore && (events.isEmpty || nextAfterSeq == afterSeq))) {
      throw const FormatException('Conflict feed page cursor is inconsistent.');
    }
    return ConflictChangesPage(
      vaultId: vaultId,
      afterSeq: afterSeq,
      highWatermark: highWatermark,
      events: List.unmodifiable(events),
      nextAfterSeq: nextAfterSeq,
      hasMore: hasMore,
      serverGeneration: serverGeneration,
    );
  }
}

/// Safe review metadata derived from one created conflict-feed event. It
/// deliberately contains no decrypted record fields or ciphertext.
class ConflictFeedReviewItem {
  const ConflictFeedReviewItem({
    required this.conflictId,
    required this.recordId,
    required this.seq,
    required this.createdAt,
    required this.serverGeneration,
    required this.partitionId,
    required this.baseRevisionId,
    required this.branchRevisionId,
    required this.branchDeviceId,
    required this.branchOperation,
    required this.keyEpoch,
    required this.membershipVersion,
    required this.currentHeadRevisionId,
    required this.currentHeadExists,
    required this.currentHeadDeleted,
    required this.currentHeadCommitted,
    required this.isVerified,
    required this.verificationError,
    required this.isResolved,
    required this.resolutionState,
  });

  final String conflictId;
  final String recordId;
  final String seq;
  final String createdAt;
  final String serverGeneration;
  final String partitionId;
  final String? baseRevisionId;
  final String? branchRevisionId;
  final String? branchDeviceId;
  final String? branchOperation;
  final String? keyEpoch;
  final String? membershipVersion;
  final String? currentHeadRevisionId;
  final bool currentHeadExists;
  final bool currentHeadDeleted;
  final bool currentHeadCommitted;
  final bool isVerified;
  final String? verificationError;
  final bool isResolved;
  final String? resolutionState;

  bool get isTerminal => isResolved || resolutionState == 'resolved';
}

/// Chooses one visible representation when a device's local CAS branch has
/// also appeared in the shared conflict feed. The local conflict card keeps
/// branch-specific actions such as saving a copy; a server-confirmed resolved
/// feed event takes precedence over any stale local row.
class ConflictReviewProjection {
  const ConflictReviewProjection({
    required this.localConflictIds,
    required this.feedItems,
  });

  final Set<String> localConflictIds;
  final List<ConflictFeedReviewItem> feedItems;
}

ConflictReviewProjection projectConflictReviewItems({
  required Map<String, String> localOpenConflictRecords,
  required Iterable<ConflictFeedReviewItem> feedItems,
}) {
  final feedList = feedItems.toList(growable: false);
  final visibleLocalIds = localOpenConflictRecords.keys.where((id) {
    final recordId = localOpenConflictRecords[id];
    return !feedList.any(
      (item) =>
          item.conflictId == id && item.recordId == recordId && item.isTerminal,
    );
  }).toSet();
  final visibleFeedItems = feedList
      .where(
        (item) =>
            item.isTerminal ||
            localOpenConflictRecords[item.conflictId] != item.recordId,
      )
      .toList(growable: false);
  return ConflictReviewProjection(
    localConflictIds: visibleLocalIds,
    feedItems: visibleFeedItems,
  );
}

bool _hasExactKeys(Map<String, dynamic> value, Set<String> expected) =>
    value.length == expected.length && value.keys.toSet().containsAll(expected);

Map<String, dynamic> _stringKeyedObject(Map value) {
  try {
    return Map<String, dynamic>.from(value);
  } on Object {
    throw const FormatException('JSON object keys must be strings.');
  }
}

bool _isCanonicalDecimal(String value) =>
    RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(value);

bool _isCanonicalUuid(String value) => RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
).hasMatch(value);

int _compareDecimal(String left, String right) {
  if (left.length != right.length) return left.length.compareTo(right.length);
  return left.compareTo(right);
}

bool _isIsoDateTime(String value) {
  if (!RegExp(
    r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$',
  ).hasMatch(value)) {
    return false;
  }
  return DateTime.tryParse(value) != null;
}
