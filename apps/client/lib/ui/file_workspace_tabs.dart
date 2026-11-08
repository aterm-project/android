import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../domain/models.dart';
import '../ssh/file_workspace_controller.dart';
import '../ssh/scp_transfer_types.dart';
import '../ssh/ssh_service.dart';
import '../l10n/l10n.dart';

class FileWorkspaceTab {
  FileWorkspaceTab({
    required this.id,
    required this.sourceSessionId,
    required this.host,
    required this.controller,
  });
  final String id;
  final String sourceSessionId;
  final HostRecord host;
  final FileWorkspaceController controller;
  String get title =>
      '${controller.protocol.name.toUpperCase()} · ${host.name}';
}

/// File tabs have independent paths/channels while borrowing a fixed SSH owner.
class FileWorkspaceTabs extends ChangeNotifier {
  final List<FileWorkspaceTab> _entries = [];
  final Map<String, Future<void>> _closing = {};
  bool _disposed = false;
  List<FileWorkspaceTab> get entries => List.unmodifiable(_entries);
  FileWorkspaceTab? find(String id) =>
      _entries.where((entry) => entry.id == id).firstOrNull;

  FileWorkspaceTab open({
    required String sourceSessionId,
    required HostRecord host,
    required SshConnection connection,
    required SshTransferProtocol protocol,
    String initialPath = '/',
    bool reuseExisting = true,
  }) {
    if (_disposed) throw StateError(currentL10n.fileWorkspaceIsClosed);
    final existing = _entries
        .where(
          (entry) =>
              entry.sourceSessionId == sourceSessionId &&
              identical(entry.controller.connection, connection) &&
              entry.controller.protocol == protocol,
        )
        .firstOrNull;
    if (reuseExisting && existing != null) return existing;
    final entry = FileWorkspaceTab(
      id: 'files-${const Uuid().v4()}',
      sourceSessionId: sourceSessionId,
      host: host,
      controller: FileWorkspaceController(
        connection: connection,
        protocol: protocol,
        initialPath: initialPath,
      ),
    );
    _entries.add(entry);
    notifyListeners();
    return entry;
  }

  Future<void> close(String id) {
    final pending = _closing[id];
    if (pending != null) return pending;
    final entry = find(id);
    if (entry == null) return Future.value();
    _entries.remove(entry);
    final completion = _close(entry);
    _closing[id] = completion;
    if (!_disposed) notifyListeners();
    return completion;
  }

  Future<void> _close(FileWorkspaceTab entry) async {
    try {
      await entry.controller.close();
    } finally {
      entry.controller.dispose();
      _closing.remove(entry.id);
    }
  }

  Future<void> closeSource(String id) => Future.wait([
    ..._closing.values,
    ..._entries
        .where((entry) => entry.sourceSessionId == id)
        .map((entry) => entry.id)
        .toList()
        .map(close),
  ]);

  Future<void> closeAll() => Future.wait([
    ..._closing.values,
    ..._entries.map((entry) => entry.id).toList().map(close),
  ]);

  void retainConnections(Map<String, SshConnection> connections) {
    for (final entry in _entries.toList()) {
      if (!identical(
        connections[entry.sourceSessionId],
        entry.controller.connection,
      )) {
        unawaited(close(entry.id).catchError((Object _) {}));
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(closeAll().catchError((Object _) {}));
    super.dispose();
  }
}

/// Retains a mixed terminal/file tab order without changing session ownership.
class WorkspaceTabOrder {
  final List<String> _ids = [];
  List<T> arrange<T>(List<T> items, String Function(T) id) {
    final byId = {for (final item in items) id(item): item};
    _ids.removeWhere((value) => !byId.containsKey(value));
    for (final key in byId.keys) {
      if (!_ids.contains(key)) _ids.add(key);
    }
    return [for (final key in _ids) byId[key]!];
  }

  void move(String id, String? beforeId) {
    if (id == beforeId || !_ids.remove(id)) return;
    final index = beforeId == null ? -1 : _ids.indexOf(beforeId);
    _ids.insert(index < 0 ? _ids.length : index, id);
  }
}
