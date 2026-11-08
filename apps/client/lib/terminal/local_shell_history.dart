import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../storage/local_host_repository.dart';
import 'shell_integration_protocol.dart';
import 'shell_integration_session.dart';
import 'terminal_tools.dart';
import '../l10n/l10n.dart';

/// Local Profile history uses the existing authenticated, encrypted Preference
/// store. No raw input stream (including password prompts) is recorded.
class LocalShellHistory extends ChangeNotifier {
  LocalShellHistory({
    required this.repository,
    required this.hostId,
    required this.terminalId,
  }) {
    _live.add(this);
  }
  static final _live = <LocalShellHistory>{};
  Iterable<LocalShellHistory> get _peers => _live.where(
    (h) => identical(h.repository, repository) && h.hostId == hostId,
  );
  final LocalHostRepository repository;
  final String hostId, terminalId;
  final _rows = <Map<String, Object?>>[];
  Future<void> _queue = Future.value();
  bool _disposed = false;
  int _generation = 0;
  bool storageFailed = false;
  ShellIntegrationSession? _capture;
  bool get enabled => _capture?.isActive == true;
  String get _key => 'host-$hostId';
  List<TerminalCommandItem> get items => [
    for (final row in _rows.reversed)
      TerminalCommandItem(
        id: row['id'] as String,
        title: currentL10n.itemExitItem2('${row['at']}', '${row['exit']}'),
        command: row['command'] as String,
      ),
  ];

  static List<Map<String, Object?>> _decode(Object? value) {
    if (value is! List) return [];
    return [
      for (final row in value.take(500))
        if (row is Map &&
            row['id'] is String &&
            row['at'] is String &&
            row['exit'] is int &&
            row['command'] is String &&
            (row['command'] as String).length <=
                shellIntegrationMaxCommandBytes)
          {
            'id': row['id'],
            'at': row['at'],
            'exit': row['exit'],
            'command': row['command'],
          },
    ];
  }

  static List<Map<String, Object?>> _bounded(
    Iterable<Map<String, Object?>> rows,
  ) {
    final byId = {for (final row in rows) row['id'] as String: row};
    final sorted = byId.values.toList()
      ..sort((a, b) => (a['at'] as String).compareTo(b['at'] as String));
    final kept = <Map<String, Object?>>[];
    var bytes = 2;
    for (final row in sorted.reversed) {
      final size = utf8.encode(jsonEncode(row)).length + 1;
      if (kept.length == 500 || bytes + size > 48 * 1024) break;
      kept.add(row);
      bytes += size;
    }
    return kept.reversed.toList();
  }

  Future<void> load() async {
    final generation = _generation;
    try {
      final saved = await repository.getPreference(
        scope: 'terminal-history',
        key: _key,
        platformFamily: 'all',
      );
      if (_disposed || generation != _generation) return;
      final merged = _bounded([..._decode(saved?.value), ..._rows]);
      _rows
        ..clear()
        ..addAll(merged);
    } catch (_) {
      if (!_disposed) storageFailed = true;
    }
    if (!_disposed) notifyListeners();
  }

  String enable() {
    disable();
    _capture = ShellIntegrationSession(terminalId: terminalId);
    notifyListeners();
    return _capture!.bootstrapCommand;
  }

  void disable() {
    _capture?.close();
    _capture = null;
    if (!_disposed) notifyListeners();
  }

  void accept(String code, List<String> args) {
    final completed =
        _capture?.accept(code, args) ??
        const <ShellIntegrationCompletedCommand>[];
    if (completed.isEmpty || _disposed) return;
    final added = [
      for (final command in completed)
        <String, Object?>{
          'id': const Uuid().v4(),
          'command': command.command,
          'exit': command.exitStatus,
          'at': command.completedAt.toUtc().toIso8601String(),
        },
    ];
    for (final peer in _peers) {
      final merged = _bounded([...peer._rows, ...added]);
      peer._rows
        ..clear()
        ..addAll(merged);
      peer.notifyListeners();
    }
    _enqueue(added);
  }

  Future<void> flush() => _queue;

  Future<void> clear() {
    for (final peer in _peers) {
      ++peer._generation;
      peer._rows.clear();
      peer.notifyListeners();
    }
    return _enqueue(const [], replace: true);
  }

  List<Map<String, Object?>> _pending = [];
  bool _replacePending = false, _draining = false;
  int _pendingGeneration = 0;
  Future<void> _enqueue(List<Map<String, Object?>> added, {bool replace = false}) {
    if (replace || _pendingGeneration != _generation) {
      _pending.clear();
      _replacePending = false;
    }
    _pendingGeneration = _generation;
    _replacePending = _replacePending || replace;
    _pending = _bounded([..._pending, ...added]);
    if (!_draining) _queue = _drain();
    return _queue;
  }

  Future<void> _drain() async {
    _draining = true;
    try {
      while (_pending.isNotEmpty || _replacePending) {
        final added = _pending;
        final replace = _replacePending;
        final generation = _pendingGeneration;
        _pending = [];
        _replacePending = false;
        if (generation == _generation) await _persist(added, replace, generation);
      }
    } finally { _draining = false; }
  }

  Future<void> _persist(List<Map<String, Object?>> added, bool replace, int generation) async {
      try {
        // Re-read and compare revisions so multiple tabs do not lose commands.
        for (var attempt = 0; attempt < 2; attempt++) {
          final old = await repository.getPreference(
            scope: 'terminal-history',
            key: _key,
            platformFamily: 'all',
          );
          if (generation != _generation) return;
          final value = _bounded([
            if (!replace) ..._decode(old?.value),
            ...added,
          ]);
          try {
            if (old == null) {
              await repository.createPreference(
                scope: 'terminal-history',
                key: _key,
                value: value,
                platformFamily: 'all',
              );
            } else {
              await repository.updatePreference(
                preference: LocalPreferenceRecord(
                  id: old.id,
                  scope: old.scope,
                  key: old.key,
                  value: value,
                  platformFamily: old.platformFamily,
                  revisionId: old.revisionId,
                ),
                baseRevisionId: old.revisionId,
              );
            }
            if (!_disposed) storageFailed = false;
            break;
          } on LocalPreferenceConflictException {
            if (attempt == 1) rethrow;
          } on LocalPreferenceDuplicateException {
            if (attempt == 1) rethrow;
          }
        }
      } catch (_) {
        if (!_disposed) storageFailed = true;
      }
      if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _live.remove(this);
    _disposed = true;
    _capture?.close();
    _rows.clear();
    super.dispose();
  }
}
