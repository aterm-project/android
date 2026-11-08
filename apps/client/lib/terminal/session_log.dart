import 'dart:async';
import 'dart:convert';
import 'dart:math' show max;

import 'package:dartssh2/dartssh2.dart'
    show SSHAuthError, SSHAuthFailError, SSHHandshakeError, SSHSocketError;
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../domain/models.dart';
import '../ssh/ssh_service.dart';
import '../storage/local_host_repository.dart';
import 'session_log_scope.dart';

/// Session logs are a device-local journal of terminal *connections* (who,
/// where, when, how it ended). They are deliberately separate from shell
/// command history (the terminal tools sidebar).
///
/// Privacy policy:
/// * Lifecycle rows never contain passwords, keys, passphrases, raw input or
///   exception text; failures are reduced to [SessionLogFailure] categories.
/// * An output transcript is recorded only when the user explicitly enabled
///   [SessionLogBook.recordTranscripts] *before* the session started. It holds
///   what the terminal displayed (remote output, which includes characters
///   the remote echoes) with control sequences stripped. Keystrokes are never
///   captured, so hidden password prompts are not recorded.
/// * Local Profiles persist logs in the encrypted Profile Preference store
///   (scope [localSessionLogPreferenceScope], never migrated to a sync Vault).
///   Cloud workspaces keep them in memory for the running app only.
/// * Retention is bounded: [SessionLogBook.maxEntries] rows,
///   [SessionLogBook.maxTranscripts] transcripts of at most
///   [SessionLogBook.maxTranscriptBytes] UTF-8 bytes (newest output kept).
enum SessionLogStatus { connecting, connected, failed, closed }

enum SessionLogFailure {
  hostKeyRejected,
  hostKeyChanged,
  authentication,
  credential,
  network,
  timeout,
  cancelled,
  unsupported,
  other,
}

enum SessionLogEndReason { user, remote, error }

@immutable
final class SessionLogEntry {
  const SessionLogEntry({
    required this.id,
    required this.hostId,
    required this.hostName,
    required this.endpoint,
    required this.protocol,
    required this.startedAt,
    required this.status,
    this.connectedAt,
    this.endedAt,
    this.failure,
    this.endReason,
    this.viaJump = false,
    this.transcriptSlot,
    this.transcriptBytes = 0,
    this.transcriptTruncated = false,
    this.transcriptGeneration = 0,
    this.owner,
    this.updatedAt,
  });

  final String id;
  final String hostId;
  final String hostName;

  /// `user@address:port` (never includes credentials).
  final String endpoint;
  final String protocol;
  final DateTime startedAt;
  final DateTime? connectedAt;
  final DateTime? endedAt;
  final SessionLogStatus status;
  final SessionLogFailure? failure;
  final SessionLogEndReason? endReason;
  final bool viaJump;
  final int? transcriptSlot;
  final int transcriptBytes;
  final bool transcriptTruncated;

  /// Reservation generation of [transcriptSlot]; the slot payload must carry
  /// the same id and generation to be shown.
  final int transcriptGeneration;

  /// Book (window) that created the row; used for live-owner heartbeats.
  final String? owner;
  final DateTime? updatedAt;

  bool get hasTranscript => transcriptSlot != null;

  Duration? get duration {
    final from = connectedAt;
    if (from == null) return null;
    return (endedAt ?? DateTime.now().toUtc()).difference(from);
  }

  SessionLogEntry copyWith({
    DateTime? connectedAt,
    DateTime? endedAt,
    SessionLogStatus? status,
    SessionLogFailure? failure,
    SessionLogEndReason? endReason,
    int? transcriptSlot,
    bool clearTranscript = false,
    int? transcriptBytes,
    bool? transcriptTruncated,
    int? transcriptGeneration,
    bool touch = true,
  }) => SessionLogEntry(
    id: id,
    hostId: hostId,
    hostName: hostName,
    endpoint: endpoint,
    protocol: protocol,
    startedAt: startedAt,
    connectedAt: connectedAt ?? this.connectedAt,
    endedAt: endedAt ?? this.endedAt,
    status: status ?? this.status,
    failure: failure ?? this.failure,
    endReason: endReason ?? this.endReason,
    viaJump: viaJump,
    transcriptSlot: clearTranscript ? null : transcriptSlot ?? this.transcriptSlot,
    transcriptBytes: clearTranscript ? 0 : transcriptBytes ?? this.transcriptBytes,
    transcriptTruncated: clearTranscript
        ? false
        : transcriptTruncated ?? this.transcriptTruncated,
    transcriptGeneration: clearTranscript
        ? 0
        : transcriptGeneration ?? this.transcriptGeneration,
    owner: owner,
    updatedAt: touch ? DateTime.now().toUtc() : updatedAt,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'h': hostId,
    'n': hostName,
    'e': endpoint,
    'p': protocol,
    's': status.name,
    't0': startedAt.millisecondsSinceEpoch,
    if (connectedAt != null) 't1': connectedAt!.millisecondsSinceEpoch,
    if (endedAt != null) 't2': endedAt!.millisecondsSinceEpoch,
    if (failure != null) 'f': failure!.name,
    if (endReason != null) 'r': endReason!.name,
    if (viaJump) 'j': true,
    if (transcriptSlot != null) 'ts': transcriptSlot,
    if (transcriptSlot != null) 'tb': transcriptBytes,
    if (transcriptTruncated) 'tt': true,
    if (transcriptSlot != null) 'tg': transcriptGeneration,
    if (owner != null) 'ow': owner,
    'u': (updatedAt ?? startedAt).millisecondsSinceEpoch,
  };

  static SessionLogEntry? tryParse(Object? raw) {
    if (raw is! Map) return null;
    try {
      DateTime? time(Object? value) => value is int
          ? DateTime.fromMillisecondsSinceEpoch(value, isUtc: true)
          : null;
      T? byName<T extends Enum>(List<T> values, Object? name) =>
          values.where((value) => value.name == name).firstOrNull;
      final id = raw['id'], started = time(raw['t0']);
      final status = byName(SessionLogStatus.values, raw['s']);
      if (id is! String || started == null || status == null) return null;
      String text(Object? value, int max) =>
          value is String ? (value.length > max ? value.substring(0, max) : value) : '';
      final slot = raw['ts'];
      return SessionLogEntry(
        id: id,
        hostId: text(raw['h'], 64),
        hostName: text(raw['n'], 128),
        endpoint: text(raw['e'], 300),
        protocol: text(raw['p'], 16),
        startedAt: started,
        connectedAt: time(raw['t1']),
        endedAt: time(raw['t2']),
        status: status,
        failure: byName(SessionLogFailure.values, raw['f']),
        endReason: byName(SessionLogEndReason.values, raw['r']),
        viaJump: raw['j'] == true,
        transcriptSlot: slot is int ? slot : null,
        transcriptBytes: raw['tb'] is int ? raw['tb'] as int : 0,
        transcriptTruncated: raw['tt'] == true,
        transcriptGeneration: raw['tg'] is int ? raw['tg'] as int : 0,
        owner: raw['ow'] is String ? text(raw['ow'], 64) : null,
        updatedAt: time(raw['u']),
      );
    } on Object {
      return null;
    }
  }
}

/// Reduces any connect/session error to a non-sensitive category.
SessionLogFailure classifySessionFailure(Object error) {
  if (error is SshHostKeyVerificationException) {
    return error.failure == SshHostKeyFailure.changed
        ? SessionLogFailure.hostKeyChanged
        : SessionLogFailure.hostKeyRejected;
  }
  if (error is SshCredentialException) return SessionLogFailure.credential;
  if (error is SSHAuthError || error is SSHAuthFailError) {
    return SessionLogFailure.authentication;
  }
  if (error is SshStageException) {
    return error.stage == SshFailureStage.authentication
        ? SessionLogFailure.authentication
        : SessionLogFailure.network;
  }
  if (error is SshConnectCancelledException) return SessionLogFailure.cancelled;
  if (error is TimeoutException) return SessionLogFailure.timeout;
  if (error is UnsupportedError) return SessionLogFailure.unsupported;
  if (error is SSHSocketError ||
      error is SSHHandshakeError ||
      error is SshRelayTransportException) {
    return SessionLogFailure.network;
  }
  // dart:io is unavailable on web; match the type name without importing it.
  final type = error.runtimeType.toString();
  if (type == 'SocketException' || type == 'HandshakeException') {
    return SessionLogFailure.network;
  }
  return SessionLogFailure.other;
}

/// Key/value persistence for a [SessionLogBook]. Values are JSON data.
///
/// Every write is a read-transform-compare-and-swap: [update] reads the
/// latest stored value, passes it to [transform] and stores the result only
/// if nobody changed the key meanwhile (retrying with the fresh value). This
/// is what lets several windows of one Profile share the journal without a
/// stale writer overwriting rows it never saw.
abstract interface class SessionLogStorage {
  bool get persistent;
  Future<Object?> read(String key);

  /// Returns the stored value after the update. When [transform] returns
  /// `identical(current)` nothing is written.
  Future<Object?> update(String key, Object? Function(Object? current) transform);
}

final class MemorySessionLogStorage implements SessionLogStorage {
  final _values = <String, Object?>{};

  @override
  bool get persistent => false;

  @override
  Future<Object?> read(String key) async => _values[key];

  @override
  Future<Object?> update(
    String key,
    Object? Function(Object? current) transform,
  ) async {
    final current = _values[key];
    final next = transform(current);
    if (!identical(next, current)) _values[key] = next;
    return _values[key];
  }
}

/// Encrypted Local Profile Preference storage. Values are updated in place
/// (fixed keys / transcript slots) so retention never grows tombstones.
final class LocalPreferenceSessionLogStorage implements SessionLogStorage {
  LocalPreferenceSessionLogStorage(this.repository);
  final LocalHostRepository repository;

  @override
  bool get persistent => true;

  @override
  Future<Object?> read(String key) async => (await repository.getPreference(
    scope: localSessionLogPreferenceScope,
    key: key,
    platformFamily: 'all',
  ))?.value;

  @override
  Future<Object?> update(
    String key,
    Object? Function(Object? current) transform,
  ) async {
    for (var attempt = 0; ; attempt++) {
      final old = await repository.getPreference(
        scope: localSessionLogPreferenceScope,
        key: key,
        platformFamily: 'all',
      );
      final next = transform(old?.value);
      if (identical(next, old?.value)) return old?.value;
      try {
        if (old == null) {
          await repository.createPreference(
            scope: localSessionLogPreferenceScope,
            key: key,
            value: next,
            platformFamily: 'all',
          );
        } else {
          await repository.updatePreference(
            preference: LocalPreferenceRecord(
              id: old.id,
              scope: old.scope,
              key: old.key,
              value: next,
              platformFamily: old.platformFamily,
              revisionId: old.revisionId,
            ),
            baseRevisionId: old.revisionId,
          );
        }
        return next;
      } on LocalPreferenceConflictException {
        if (attempt >= 4) rethrow;
      } on LocalPreferenceDuplicateException {
        if (attempt >= 4) rethrow;
      }
    }
  }
}

/// Decoded shared index (format v2).
final class _Index {
  _Index({
    Map<String, SessionLogEntry>? entries,
    Map<String, int>? deleted,
    this.clearedAt = 0,
    Map<String, int>? owners,
    this.slotGeneration = 0,
  }) : entries = entries ?? {},
       deleted = deleted ?? {},
       owners = owners ?? {};

  final Map<String, SessionLogEntry> entries;

  /// Tombstones: entry id → deletion time (ms). Bounded.
  final Map<String, int> deleted;

  /// "Clear finished logs" watermark: rows that ended at or before it are gone.
  int clearedAt;

  /// Book (window) id → last heartbeat (ms).
  final Map<String, int> owners;

  /// Monotonic transcript slot reservation counter.
  int slotGeneration;

  static _Index decode(Object? raw) {
    if (raw is! Map) return _Index();
    final index = _Index(
      clearedAt: raw['c'] is int ? raw['c'] as int : 0,
      slotGeneration: raw['g'] is int ? raw['g'] as int : 0,
    );
    final rows = raw['entries'];
    if (rows is List) {
      for (final row in rows.take(SessionLogBook.hardMaxEntries)) {
        final entry = SessionLogEntry.tryParse(row);
        if (entry != null) index.entries[entry.id] = entry;
      }
    }
    for (final (field, target) in [
      ('d', index.deleted),
      ('o', index.owners),
    ]) {
      final value = raw[field];
      if (value is Map) {
        for (final e in value.entries.take(512)) {
          if (e.key is String && e.value is int) {
            target[e.key as String] = e.value as int;
          }
        }
      }
    }
    return index;
  }
}

class SessionLogBook extends ChangeNotifier {
  SessionLogBook({
    required this._storage,
    this.maxEntries = 100,
    this.maxTranscripts = 20,
    this.maxTranscriptBytes = 24 * 1024,
    this.ownerStaleAfter = const Duration(minutes: 3),
    this.heartbeatInterval = const Duration(seconds: 60),
  }) : assert(maxEntries > 0 && maxEntries <= hardMaxEntries),
       assert(maxTranscripts > 0 && maxTranscripts <= 64),
       assert(maxTranscriptBytes > 0 && maxTranscriptBytes <= 30 * 1024);

  SessionLogBook.memory() : this(storage: MemorySessionLogStorage());

  static const hardMaxEntries = 200;
  static const _indexKey = 'index';
  static const _settingsKey = 'settings';
  static String _slotKey(int slot) => 'transcript-slot-$slot';
  // Keeps the encrypted index well under the 64 KiB Preference value limit.
  static const _maxIndexBytes = 48 * 1024;
  static const _maxTombstones = 200;

  final SessionLogStorage _storage;
  final int maxEntries;
  final int maxTranscripts;
  final int maxTranscriptBytes;

  /// A live row owned by another book (window) is treated as abandoned only
  /// when that owner has not refreshed its heartbeat for this long.
  final Duration ownerStaleAfter;
  final Duration heartbeatInterval;

  /// Identity of this book instance (one per window / unlocked Profile).
  final String ownerId = const Uuid().v4();

  /// Merged view of the shared index.
  _Index _view = _Index();

  /// Rows this book created or changed and has not confirmed in storage.
  final _dirty = <String, SessionLogEntry>{};
  final _pendingDeletes = <String, int>{};
  int _pendingClear = 0;

  final _live = <String, SessionLogRecorder>{};
  bool _recordTranscripts = false;
  bool _loaded = false;
  bool _disposed = false;
  bool storageFailed = false;
  Future<void> _queue = Future.value();
  Timer? _heartbeat;

  bool get persistent => _storage.persistent;
  bool get loaded => _loaded;
  bool get recordTranscripts => _recordTranscripts;

  /// Newest first.
  List<SessionLogEntry> get entries =>
      _view.entries.values.toList()
        ..sort((a, b) => b.startedAt.compareTo(a.startedAt));

  /// Live in this window.
  bool isLive(String id) => _live.containsKey(id);

  /// Live here or in another window of the same Profile (fresh heartbeat).
  bool isActive(String id) {
    if (_live.containsKey(id)) return true;
    final entry = _view.entries[id];
    return entry != null && _isLiveElsewhere(entry);
  }

  int get _now => DateTime.now().toUtc().millisecondsSinceEpoch;

  /// Reads the shared journal (also used to refresh rows written by other
  /// windows). Rows left connecting/connected by an owner whose heartbeat is
  /// stale (crashed/killed app) are closed; rows of a live owner are kept.
  Future<void> load() => _serial(() async {
    try {
      final settings = await _storage.read(_settingsKey);
      _recordTranscripts =
          settings is Map && settings['recordTranscripts'] == true;
      final stored = _Index.decode(await _storage.read(_indexKey));
      _view = _merge(stored, touchOwner: false);
      final now = _now;
      var abandoned = false;
      for (final entry in _view.entries.values.toList()) {
        if (entry.status != SessionLogStatus.connecting &&
            entry.status != SessionLogStatus.connected) {
          continue;
        }
        if (_live.containsKey(entry.id)) continue;
        final owner = entry.owner;
        final beat = owner == null ? null : _view.owners[owner];
        final fresh =
            owner == ownerId ||
            (beat != null && now - beat < ownerStaleAfter.inMilliseconds);
        if (fresh) continue;
        abandoned = true;
        _dirty[entry.id] = entry.copyWith(
          status: entry.status == SessionLogStatus.connecting
              ? SessionLogStatus.failed
              : SessionLogStatus.closed,
          failure: entry.status == SessionLogStatus.connecting
              ? SessionLogFailure.other
              : null,
          endReason: SessionLogEndReason.error,
          endedAt: entry.updatedAt ?? entry.startedAt,
        );
      }
      if (abandoned) await _writeIndex();
      _loaded = true;
      storageFailed = false;
    } on Object {
      storageFailed = true;
    }
    _notify();
  });

  Future<void> setRecordTranscripts(bool value) {
    _recordTranscripts = value;
    _notify();
    return _serial(() async {
      try {
        await _storage.update(
          _settingsKey,
          (_) => {'recordTranscripts': value},
        );
        storageFailed = false;
      } on Object {
        storageFailed = true;
      }
      _notify();
    });
  }

  /// Starts a lifecycle row. Transcript capture follows the setting at this
  /// moment; toggling later never starts recording an already open session.
  SessionLogRecorder begin({
    required HostRecord host,
    String? protocol,
    bool viaJump = false,
  }) {
    final now = DateTime.now().toUtc();
    final entry = SessionLogEntry(
      id: const Uuid().v4(),
      hostId: host.id,
      hostName: host.name,
      endpoint: '${host.username.isEmpty ? '' : '${host.username}@'}${host.address}:${host.port}',
      protocol: protocol ?? host.protocol.name,
      startedAt: now,
      status: SessionLogStatus.connecting,
      viaJump: viaJump,
      owner: ownerId,
      updatedAt: now,
    );
    final recorder = SessionLogRecorder._(this, entry, _recordTranscripts);
    _live[entry.id] = recorder;
    _put(entry);
    _ensureHeartbeat();
    return recorder;
  }

  Future<String?> transcript(String id) async {
    final live = _live[id];
    if (live != null && live.capturing) return live._buffer.text;
    final entry = _view.entries[id];
    final slot = entry?.transcriptSlot;
    if (entry == null || slot == null) return null;
    try {
      final value = await _storage.read(_slotKey(slot));
      if (value is Map &&
          value['id'] == id &&
          value['g'] == entry.transcriptGeneration &&
          value['text'] is String) {
        return value['text'] as String;
      }
    } on Object {
      storageFailed = true;
      _notify();
    }
    return null;
  }

  /// Deletes a finished row everywhere (tombstoned so a stale writer in
  /// another window cannot resurrect it) and wipes its transcript slot.
  Future<void> delete(String id) {
    final entry = _view.entries[id];
    if (entry == null || _live.containsKey(id) || _isLiveElsewhere(entry)) {
      return Future.value();
    }
    _view.entries.remove(id);
    _dirty.remove(id);
    _pendingDeletes[id] = _now;
    _notify();
    return _serial(() async {
      await _writeIndex();
      final slot = entry.transcriptSlot;
      if (slot != null) await _wipeSlot(slot, onlyId: id);
    });
  }

  /// Removes every row that has ended (in any window) and wipes transcripts
  /// no remaining row references. Live sessions stay listed.
  Future<void> clear() {
    final at = _now;
    _pendingClear = at;
    _view.entries.removeWhere(
      (_, e) => e.endedAt != null && e.endedAt!.millisecondsSinceEpoch <= at,
    );
    _dirty.removeWhere(
      (_, e) => e.endedAt != null && e.endedAt!.millisecondsSinceEpoch <= at,
    );
    _notify();
    return _serial(() async {
      await _writeIndex();
      await _collectOrphanSlots();
    });
  }

  Future<void> flush() => _queue;

  bool _isLiveElsewhere(SessionLogEntry entry) {
    if (entry.status != SessionLogStatus.connecting &&
        entry.status != SessionLogStatus.connected) {
      return false;
    }
    final beat = entry.owner == null ? null : _view.owners[entry.owner];
    return beat != null && _now - beat < ownerStaleAfter.inMilliseconds;
  }

  void _put(SessionLogEntry entry) {
    if (_disposed) return;
    _view.entries[entry.id] = entry;
    _dirty[entry.id] = entry;
    _persistIndex();
    _notify();
  }

  void _update(SessionLogEntry entry) => _put(entry);

  void _finish(SessionLogRecorder recorder, SessionLogEntry entry) {
    _live.remove(entry.id);
    if (_live.isEmpty) {
      _heartbeat?.cancel();
      _heartbeat = null;
    }
    if (_disposed) {
      recorder._buffer.clear();
      return;
    }
    final text = recorder.capturing ? recorder._buffer.text : null;
    final truncated = recorder._buffer.truncated;
    recorder._buffer.clear();
    _view.entries[entry.id] = entry;
    _dirty[entry.id] = entry;
    _notify();
    unawaited(
      _serial(() async {
        if (text == null || text.isEmpty) {
          await _writeIndex();
          return;
        }
        // Reserve a slot inside the CAS-merged index so two windows never
        // pick the same slot, then write the payload guarded by generation.
        final reserved = await _writeIndex(
          reserveFor: entry.id,
          transcriptBytes: utf8.encode(text).length,
          transcriptTruncated: truncated,
        );
        if (reserved == null) return;
        try {
          await _storage.update(_slotKey(reserved.$1), (current) {
            final g = current is Map && current['g'] is int
                ? current['g'] as int
                : -1;
            // A newer reservation already owns this slot: keep it.
            if (g > reserved.$2) return current;
            return {'id': entry.id, 'g': reserved.$2, 'text': text};
          });
        } on Object {
          storageFailed = true;
        }
        _notify();
      }),
    );
  }

  void _ensureHeartbeat() {
    if (!_storage.persistent || _heartbeat != null || _disposed) return;
    _heartbeat = Timer.periodic(heartbeatInterval, (_) => _persistIndex());
  }

  void _persistIndex() => unawaited(_serial(() async => _writeIndex()));

  /// Merges this book's pending state into [stored]. Pure; mutates nothing
  /// but the returned index.
  _Index _merge(
    _Index stored, {
    bool touchOwner = true,
    Map<String, SessionLogEntry>? dirty,
    Map<String, int>? deletes,
    int? clearAt,
  }) {
    final now = _now;
    final pendingDirty = dirty ?? _dirty;
    final out = _Index(
      clearedAt: [
        stored.clearedAt,
        _view.clearedAt,
        clearAt ?? _pendingClear,
      ].reduce(max),
      slotGeneration: max(stored.slotGeneration, _view.slotGeneration),
    );
    for (final source in [stored.deleted, _view.deleted, deletes ?? _pendingDeletes]) {
      source.forEach((id, at) {
        if ((out.deleted[id] ?? -1) < at) out.deleted[id] = at;
      });
    }
    if (out.deleted.length > _maxTombstones) {
      final keep = out.deleted.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      out.deleted
        ..clear()
        ..addEntries(keep.take(_maxTombstones));
    }
    for (final source in [stored.owners, _view.owners]) {
      source.forEach((id, at) {
        if ((out.owners[id] ?? -1) < at) out.owners[id] = at;
      });
    }
    if (touchOwner) out.owners[ownerId] = now;
    out.owners.removeWhere(
      (id, at) => id != ownerId && now - at > const Duration(days: 1).inMilliseconds,
    );
    bool removed(SessionLogEntry e) => out.deleted.containsKey(e.id);
    int stamp(SessionLogEntry e) =>
        (e.updatedAt ?? e.startedAt).millisecondsSinceEpoch;
    for (final e in stored.entries.values) {
      if (!removed(e)) out.entries[e.id] = e;
    }
    // Rows this book owns or changed win over the stored copy unless the
    // stored copy is strictly newer (another window closed an abandoned row).
    for (final e in pendingDirty.values) {
      if (removed(e)) {
        // The newest copy is cleared: no older copy may survive it.
        out.entries.remove(e.id);
        continue;
      }
      final other = out.entries[e.id];
      if (other == null || stamp(e) >= stamp(other) || _live.containsKey(e.id)) {
        out.entries[e.id] = e;
      }
    }
    // A pending "clear" tombstones exactly the finished rows present in this
    // CAS-merged index (other windows' included). Rows that start later are
    // unaffected; stale writers cannot resurrect tombstoned ids.
    final clear = clearAt ?? _pendingClear;
    if (clear > 0) {
      for (final e in out.entries.values.toList()) {
        if (e.endedAt != null &&
            e.endedAt!.millisecondsSinceEpoch <= clear &&
            !_live.containsKey(e.id)) {
          out.deleted[e.id] = clear;
          out.entries.remove(e.id);
        }
      }
    }
    // Bound rows: drop the oldest finished rows first.
    if (out.entries.length > maxEntries) {
      final finished = out.entries.values
          .where((e) => e.endedAt != null && !_live.containsKey(e.id))
          .toList()
        ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
      for (final e in finished) {
        if (out.entries.length <= maxEntries) break;
        out.entries.remove(e.id);
      }
    }
    // A slot belongs to at most one row: the latest reservation wins.
    final bySlot = <int, SessionLogEntry>{};
    for (final e in out.entries.values.toList()) {
      final slot = e.transcriptSlot;
      if (slot == null) continue;
      if (slot >= maxTranscripts) {
        out.entries[e.id] = e.copyWith(clearTranscript: true, touch: false);
        continue;
      }
      final holder = bySlot[slot];
      if (holder == null) {
        bySlot[slot] = e;
      } else {
        final loser = holder.transcriptGeneration >= e.transcriptGeneration
            ? e
            : holder;
        if (identical(loser, holder)) bySlot[slot] = e;
        out.entries[loser.id] = loser.copyWith(
          clearTranscript: true,
          touch: false,
        );
      }
    }
    return out;
  }

  Map<String, Object?> _encode(_Index index) {
    final rows = <Map<String, Object?>>[];
    var bytes = 512 + index.deleted.length * 64 + index.owners.length * 64;
    final ordered = index.entries.values.toList()
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    for (final entry in ordered.take(maxEntries)) {
      final row = entry.toJson();
      final size = utf8.encode(jsonEncode(row)).length + 1;
      if (bytes + size > _maxIndexBytes) break;
      rows.add(row);
      bytes += size;
    }
    return {
      'v': 2,
      'entries': rows,
      'd': index.deleted,
      'c': index.clearedAt,
      'o': index.owners,
      'g': index.slotGeneration,
    };
  }

  /// CAS-merges pending state into the shared index. With [reserveFor] it
  /// also assigns a transcript slot (free one, else the oldest) to that row
  /// and returns `(slot, generation)`.
  Future<(int, int)?> _writeIndex({
    String? reserveFor,
    int transcriptBytes = 0,
    bool transcriptTruncated = false,
  }) async {
    (int, int)? reserved;
    final dirty = Map.of(_dirty);
    final deletes = Map.of(_pendingDeletes);
    final clearAt = _pendingClear;
    try {
      final written = await _storage.update(_indexKey, (current) {
        reserved = null;
        final merged = _merge(
          _Index.decode(current),
          dirty: dirty,
          deletes: deletes,
          clearAt: clearAt,
        );
        final target = reserveFor == null ? null : merged.entries[reserveFor];
        if (target != null) {
          final used = <int, SessionLogEntry>{
            for (final e in merged.entries.values)
              if (e.transcriptSlot != null && e.id != target.id)
                e.transcriptSlot!: e,
          };
          var slot = -1;
          for (var i = 0; i < maxTranscripts; i++) {
            if (!used.containsKey(i)) {
              slot = i;
              break;
            }
          }
          if (slot < 0) {
            final oldest = used.entries.reduce(
              (a, b) => a.value.startedAt.isBefore(b.value.startedAt) ? a : b,
            );
            slot = oldest.key;
            merged.entries[oldest.value.id] = oldest.value.copyWith(
              clearTranscript: true,
              touch: false,
            );
          }
          final generation = ++merged.slotGeneration;
          merged.entries[target.id] = target.copyWith(
            transcriptSlot: slot,
            transcriptGeneration: generation,
            transcriptBytes: transcriptBytes,
            transcriptTruncated: transcriptTruncated,
          );
          reserved = (slot, generation);
        }
        return _encode(merged);
      });
      final view = _Index.decode(written);
      // Only what this write carried is confirmed; changes made while it was
      // in flight stay pending (and visible) for the next write.
      dirty.forEach((id, e) {
        if (identical(_dirty[id], e) && !_live.containsKey(id)) {
          _dirty.remove(id);
        }
      });
      for (final id in _live.keys) {
        final stored = view.entries[id];
        if (stored != null && identical(_dirty[id], dirty[id])) {
          _dirty[id] = stored;
        }
      }
      deletes.forEach((id, at) {
        if (_pendingDeletes[id] == at) _pendingDeletes.remove(id);
      });
      if (_pendingClear == clearAt) _pendingClear = 0;
      view.entries.addAll(_dirty);
      for (final id in _pendingDeletes.keys) {
        view.entries.remove(id);
      }
      if (_pendingClear > 0) {
        view.entries.removeWhere(
          (_, e) =>
              e.endedAt != null &&
              e.endedAt!.millisecondsSinceEpoch <= _pendingClear,
        );
      }
      _view = view;
      storageFailed = false;
    } on Object {
      storageFailed = true;
      reserved = null;
    }
    _notify();
    return reserved;
  }

  Future<void> _wipeSlot(int slot, {String? onlyId}) async {
    try {
      await _storage.update(_slotKey(slot), (current) {
        if (current is! Map || current['id'] == null) return current;
        if (onlyId != null && current['id'] != onlyId) return current;
        return {'id': null, 'g': current['g'], 'text': ''};
      });
    } on Object {
      storageFailed = true;
    }
  }

  /// Wipes transcript payloads that no current row references.
  Future<void> _collectOrphanSlots() async {
    for (var slot = 0; slot < maxTranscripts; slot++) {
      final holder = _view.entries.values
          .where((e) => e.transcriptSlot == slot)
          .firstOrNull;
      try {
        await _storage.update(_slotKey(slot), (current) {
          if (current is! Map || current['id'] == null) return current;
          if (holder != null &&
              current['id'] == holder.id &&
              current['g'] == holder.transcriptGeneration) {
            return current;
          }
          // Keep a payload newer than this view (another window may have
          // just reserved it).
          final g = current['g'] is int ? current['g'] as int : -1;
          if (g > _view.slotGeneration) return current;
          return {'id': null, 'g': current['g'], 'text': ''};
        });
      } on Object {
        storageFailed = true;
      }
    }
  }

  Future<void> _serial(Future<void> Function() action) {
    final next = _queue.then((_) => _disposed ? null : action());
    _queue = next.catchError((Object _) {});
    return _queue;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Finishes live rows as closed and waits for pending writes.
  Future<void> close() async {
    for (final recorder in _live.values.toList()) {
      recorder.markClosed(SessionLogEndReason.user);
    }
    await _queue;
  }

  @override
  void dispose() {
    _disposed = true;
    _heartbeat?.cancel();
    for (final recorder in _live.values) {
      recorder._buffer.clear();
    }
    _live.clear();
    _view = _Index();
    _dirty.clear();
    super.dispose();
  }
}

/// Lifecycle handle for one connection attempt. All methods are idempotent
/// after the session finished.
final class SessionLogRecorder {
  SessionLogRecorder._(this._book, this._entry, this.capturing)
    : _buffer = _TranscriptBuffer(_book.maxTranscriptBytes);

  final SessionLogBook _book;
  SessionLogEntry _entry;
  final bool capturing;
  final _TranscriptBuffer _buffer;
  bool _finished = false;

  String get id => _entry.id;
  SessionLogEntry get entry => _entry;
  bool get finished => _finished;

  void markConnected() {
    if (_finished || _entry.status != SessionLogStatus.connecting) return;
    _entry = _entry.copyWith(
      status: SessionLogStatus.connected,
      connectedAt: DateTime.now().toUtc(),
    );
    _book._update(_entry);
  }

  void markFailed(Object error) {
    if (_finished) return;
    _finished = true;
    _entry = _entry.copyWith(
      status: SessionLogStatus.failed,
      failure: classifySessionFailure(error),
      endReason: SessionLogEndReason.error,
      endedAt: DateTime.now().toUtc(),
    );
    _book._finish(this, _entry);
  }

  void markClosed(SessionLogEndReason reason, {Object? error}) {
    if (_finished) return;
    _finished = true;
    if (_entry.status == SessionLogStatus.connecting) {
      _entry = _entry.copyWith(
        status: SessionLogStatus.failed,
        failure: error == null
            ? SessionLogFailure.cancelled
            : classifySessionFailure(error),
        endReason: reason,
        endedAt: DateTime.now().toUtc(),
      );
    } else {
      _entry = _entry.copyWith(
        status: SessionLogStatus.closed,
        failure: error == null ? null : classifySessionFailure(error),
        endReason: error == null ? reason : SessionLogEndReason.error,
        endedAt: DateTime.now().toUtc(),
      );
    }
    _book._finish(this, _entry);
  }

  /// Terminal output as displayed. Ignored unless capture was enabled.
  void output(String text) {
    if (!capturing || _finished) return;
    _buffer.add(text);
  }
}

final _ansi = RegExp(
  r'\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)?' // OSC (titles, shell integration)
  r'|\x1B[P^_][^\x1B]*(?:\x1B\\)?' // DCS / PM / APC
  r'|\x1B\[[0-?]*[ -/]*[@-~]' // CSI
  r'|\x1B[ -/]*[0-~]' // other ESC sequences
  r'|\x9B[0-?]*[ -/]*[@-~]',
);
final _controls = RegExp(r'[\x00-\x08\x0B-\x1F\x7F]');

/// Strips terminal control sequences so a transcript is plain readable text.
String plainTerminalText(String text) => text
    .replaceAll(_ansi, '')
    .replaceAll('\r\n', '\n')
    .replaceAll('\r', '\n')
    .replaceAll(_controls, '');

final class _TranscriptBuffer {
  _TranscriptBuffer(this.maxBytes);
  final int maxBytes;
  final _chunks = <String>[];
  int _bytes = 0;
  bool truncated = false;

  void add(String raw) {
    final text = plainTerminalText(raw);
    if (text.isEmpty) return;
    _chunks.add(text);
    _bytes += utf8.encode(text).length;
    while (_bytes > maxBytes && _chunks.isNotEmpty) {
      truncated = true;
      final first = _chunks.first;
      final firstBytes = utf8.encode(first).length;
      if (_bytes - firstBytes >= maxBytes || _chunks.length > 1) {
        _chunks.removeAt(0);
        _bytes -= firstBytes;
      } else {
        // Keep the newest tail of a single oversized chunk.
        var tail = first.substring(first.length ~/ 2);
        while (utf8.encode(tail).length > maxBytes) {
          tail = tail.substring(tail.length ~/ 2);
        }
        _chunks[0] = tail;
        _bytes = utf8.encode(tail).length;
      }
    }
  }

  String get text => _chunks.join();

  void clear() {
    _chunks.clear();
    _bytes = 0;
  }
}

/// Binds an in-memory [SessionLogBook] to an explicit scope (for the cloud
/// workspace: server, account, device and Vault). When the scope changes or
/// is retired (lock, logout, credential cleanup, dispose) the old book is
/// disposed and a fresh one is created on next access, so rows of a previous
/// account/Vault never leak into the new scope. Recorders keep a reference to
/// the book they started in; late callbacks of old sessions therefore land in
/// the disposed book and are dropped.
final class ScopedSessionLogBook {
  ScopedSessionLogBook(this._scope, {SessionLogBook Function()? create})
    : _create = create ?? SessionLogBook.memory;

  final Object? Function() _scope;
  final SessionLogBook Function() _create;
  SessionLogBook? _book;
  Object? _bookScope;
  bool _disposed = false;

  SessionLogBook get current {
    final scope = _scope();
    final book = _book;
    if (book != null && !_disposed && _bookScope == scope) return book;
    retire();
    final fresh = _create();
    // After dispose callers get an empty, unretained book (never shared).
    if (_disposed) return fresh;
    _book = fresh;
    _bookScope = scope;
    return fresh;
  }

  /// Drops the current book (and every row/transcript it holds).
  void retire() {
    final old = _book;
    _book = null;
    _bookScope = null;
    old?.dispose();
  }

  void dispose() {
    _disposed = true;
    retire();
  }
}
