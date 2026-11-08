import 'dart:convert';

import 'window_placement.dart';
import '../console/local_shell.dart';
import '../l10n/l10n.dart';

/// Encrypted layout intent only: references are resolved in the current scope.
class WindowCombination {
  WindowCombination({
    required this.id,
    required this.name,
    required List<CombinationPane> panes,
    required Map<String, Object?> tree,
    required this.activePane,
    this.mainPlacement,
    List<CombinationWindow> windows = const [],
    List<CombinationGroup> groups = const [],
  }) : panes = List.unmodifiable(panes),
       tree = _freezeTree(tree, 0),
       windows = List.unmodifiable(windows),
       groups = List.unmodifiable(groups) {
    _validate();
  }
  final String id, name;
  final List<CombinationPane> panes;
  final Map<String, Object?> tree;
  final int activePane;
  final SavedWindowPlacement? mainPlacement;
  final List<CombinationWindow> windows;
  final List<CombinationGroup> groups;
  int get schemaVersion => panes.any((p) => p.ownerPane != null)
      ? 4
      : groups.isNotEmpty || windows.any((w) => w.independentFile)
      ? 3
      : mainPlacement == null && windows.isEmpty
      ? 1
      : 2;
  static const maxPanes = 32, maxCombinations = 32;
  void _validate() {
    if (!_identifier(id) ||
        name.trim() != name ||
        name.isEmpty ||
        utf8.encode(name).length > 256 ||
        RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(name) ||
        panes.isEmpty ||
        panes.length > maxPanes ||
        activePane < 0 ||
        activePane >= panes.length) {
      throw FormatException(currentL10n.invalidWindowSetNameOrSession);
    }
    if (windows.length > maxPanes)
      throw const FormatException('Too many saved windows.');
    final windowKeys = <String>{};
    for (final window in windows) {
      if (window.pane < 0 ||
          window.pane >= panes.length ||
          (window.viewport != null &&
              !{'rdp', 'vnc'}.contains(panes[window.pane].kind)) ||
          (window.independentFile &&
              (!{'sftp', 'scp'}.contains(panes[window.pane].kind) ||
                  panes[window.pane].remotePath == null ||
                  window.viewport != null)) ||
          !windowKeys.add(
            '${window.pane}:${window.viewport?['x']},${window.viewport?['y']},${window.viewport?['width']},${window.viewport?['height']}',
          ))
        throw const FormatException('Invalid saved window association.');
    }
    for (final (index, pane) in panes.indexed) {
      final owner = pane.ownerPane;
      if (owner != null &&
          (owner < 0 ||
              owner >= panes.length ||
              owner == index ||
              panes[owner].kind != 'ssh' ||
              panes[owner].hostId != pane.hostId ||
              windows.any((w) => w.pane == index && w.independentFile))) {
        throw FormatException(currentL10n.invalidAttachedFileOwner);
      }
    }
    final seen = <int>{};
    void visit(Map<String, Object?> node, int depth) {
      if (depth > 16) {
        throw FormatException(currentL10n.windowSetIsNestedTooDeeply);
      }
      if (node.keys.toSet().contains('pane')) {
        final pane = node['pane'];
        if (node.length != 1 ||
            pane is! int ||
            pane < 0 ||
            pane >= panes.length ||
            !seen.add(pane)) {
          throw FormatException(currentL10n.invalidWindowSetPaneReference);
        }
      } else {
        final ratio = node['ratio'];
        if (node.length != 4 ||
            !node.keys.toSet().containsAll({
              'axis',
              'ratio',
              'first',
              'second',
            }) ||
            !{'horizontal', 'vertical'}.contains(node['axis']) ||
            ratio is! num ||
            !ratio.isFinite ||
            ratio < .15 ||
            ratio > .85) {
          throw FormatException(currentL10n.invalidWindowSetSplit);
        }
        visit(_map(node['first']), depth + 1);
        visit(_map(node['second']), depth + 1);
      }
    }

    visit(tree, 0);
    // Other panes are independent tabs, intentionally absent from this tree.
    if (!seen.contains(activePane)) {
      throw FormatException(currentL10n.theActivePaneIsntInThe);
    }
    if (groups.length > maxPanes ~/ 2)
      throw const FormatException('Too many retained groups.');
    final mainPanes = Set<int>.from(seen), groupPanes = <int>{};
    for (final group in groups) {
      seen.clear();
      visit(group.tree, 0);
      if (seen.length < 2 ||
          !seen.contains(group.activePane) ||
          seen.any(groupPanes.contains))
        throw const FormatException('Invalid retained group membership.');
      if (seen.any(mainPanes.contains) &&
          (seen.length != mainPanes.length ||
              !seen.containsAll(mainPanes) ||
              _treeKey(group.tree) != _treeKey(tree)))
        throw const FormatException(
          'Active and retained group layouts disagree.',
        );
      if (windows.any((w) => w.independentFile && seen.contains(w.pane)))
        throw const FormatException(
          'Independent file windows cannot join parent groups.',
        );
      groupPanes.addAll(seen);
    }
  }

  Map<String, Object?> toJson() => {
    'version': schemaVersion,
    'id': id,
    'name': name,
    'panes': panes.map((p) => p.toJson()).toList(),
    'tree': tree,
    'active': activePane,
    if (schemaVersion >= 2) ...{
      'placement': mainPlacement?.toJson(),
      'windows': windows
          .map((w) => w.toJson(independentField: schemaVersion >= 3))
          .toList(),
      if (schemaVersion >= 3) 'groups': groups.map((g) => g.toJson()).toList(),
    },
  };
  factory WindowCombination.fromJson(Map<String, Object?> json) {
    final version = json['version'];
    if (version is! int ||
        (version == 1
            ? json.length != 6
            : version == 2
            ? json.length != 8
            : version == 3 || version == 4
            ? json.length != 9
            : true) ||
        !json.keys.toSet().containsAll({
          'version',
          'id',
          'name',
          'panes',
          'tree',
          'active',
        }) ||
        (version >= 2 &&
            (!json.containsKey('placement') ||
                !json.containsKey('windows') ||
                json['windows'] is! List ||
                (json['windows'] is List &&
                    (json['windows'] as List).length > maxPanes) ||
                (json['placement'] != null && json['placement'] is! Map))) ||
        (version >= 3 &&
            (json['groups'] is! List ||
                (json['groups'] as List).length > maxPanes ~/ 2)) ||
        json['id'] is! String ||
        json['name'] is! String ||
        json['active'] is! int ||
        json['panes'] is! List) {
      throw FormatException(currentL10n.invalidWindowSetFormat);
    }
    final raw = json['panes'] as List;
    if (raw.length > maxPanes) {
      throw FormatException(currentL10n.theWindowSetHasTooMany);
    }
    return WindowCombination(
      id: json['id'] as String,
      name: json['name'] as String,
      panes: raw.map((p) {
        final value = _map(p);
        if (version < 4 && value.containsKey('owner'))
          throw FormatException(
            currentL10n.unexpectedWindowCombinationOwnerField,
          );
        return CombinationPane.fromJson(value);
      }).toList(),
      tree: _map(json['tree']),
      activePane: json['active'] as int,
      mainPlacement: version >= 2 && json['placement'] != null
          ? SavedWindowPlacement.fromJson(_map(json['placement']))
          : null,
      windows: version >= 2
          ? (json['windows'] as List)
                .map(
                  (w) => CombinationWindow.fromJson(
                    _map(w),
                    independentField: version >= 3,
                  ),
                )
                .toList()
          : const [],
      groups: version >= 3
          ? (json['groups'] as List)
                .map((g) => CombinationGroup.fromJson(_map(g)))
                .toList()
          : const [],
    );
  }
  static String encode(List<WindowCombination> values) {
    if (values.length > maxCombinations ||
        values.map((v) => v.id).toSet().length != values.length) {
      throw FormatException(currentL10n.invalidWindowSetCountOrIdentifier);
    }
    final encoded = jsonEncode(values.map((v) => v.toJson()).toList());
    if (utf8.encode(encoded).length > 30000) {
      throw FormatException(currentL10n.windowSetDataIsTooLarge);
    }
    return encoded;
  }

  static List<WindowCombination> decode(String value) {
    if (utf8.encode(value).length > 30000) {
      throw FormatException(currentL10n.windowSetDataIsTooLarge);
    }
    final raw = jsonDecode(value);
    if (raw is! List || raw.length > maxCombinations) {
      throw FormatException(currentL10n.invalidWindowSetList);
    }
    final result = raw.map((v) => WindowCombination.fromJson(_map(v))).toList();
    encode(result);
    return result;
  }
}

String _treeKey(Map<String, Object?> node) => node.containsKey('pane')
    ? 'p${node['pane']}'
    : '${node['axis']}:${node['ratio']}:${_treeKey(_map(node['first']))}:${_treeKey(_map(node['second']))}';

class CombinationGroup {
  CombinationGroup({
    required Map<String, Object?> tree,
    required this.activePane,
  }) : tree = _freezeTree(tree, 0);
  final Map<String, Object?> tree;
  final int activePane;
  Map<String, Object?> toJson() => {'tree': tree, 'active': activePane};
  factory CombinationGroup.fromJson(Map<String, Object?> value) {
    if (value.length != 2 ||
        !value.keys.toSet().containsAll({'tree', 'active'}) ||
        value['active'] is! int)
      throw const FormatException('Invalid retained group.');
    return CombinationGroup(
      tree: _map(value['tree']),
      activePane: value['active'] as int,
    );
  }
}

class CombinationWindow {
  CombinationWindow({
    required this.pane,
    this.placement,
    this.independentFile = false,
    Map<String, int>? viewport,
  }) : viewport = viewport == null ? null : Map.unmodifiable(viewport) {
    if (pane < 0 || pane >= WindowCombination.maxPanes)
      throw const FormatException('Invalid window pane.');
    if (viewport != null &&
        (viewport.length != 4 ||
            !viewport.keys.toSet().containsAll({'x', 'y', 'width', 'height'}) ||
            viewport.values.any((v) => v < 0 || v > 32766) ||
            viewport['width'] == 0 ||
            viewport['height'] == 0))
      throw const FormatException('Invalid remote monitor viewport.');
  }
  final int pane;
  final bool independentFile;
  final SavedWindowPlacement? placement;
  final Map<String, int>? viewport;
  Map<String, Object?> toJson({bool independentField = false}) => {
    'pane': pane,
    'placement': placement?.toJson(),
    'viewport': viewport,
    if (independentField || independentFile)
      'independent_file': independentFile,
  };
  factory CombinationWindow.fromJson(
    Map<String, Object?> value, {
    bool independentField = false,
  }) {
    if (value.length != (independentField ? 4 : 3) ||
        (independentField && value['independent_file'] is! bool) ||
        !value.keys.toSet().containsAll({'pane', 'placement', 'viewport'}) ||
        value['pane'] is! int ||
        (value['placement'] != null && value['placement'] is! Map) ||
        (value['viewport'] != null &&
            (value['viewport'] is! Map ||
                (value['viewport'] as Map).keys.any((key) => key is! String) ||
                (value['viewport'] as Map).values.any((v) => v is! int))))
      throw const FormatException('Invalid saved window.');
    return CombinationWindow(
      pane: value['pane'] as int,
      independentFile: independentField && value['independent_file'] == true,
      placement: value['placement'] == null
          ? null
          : SavedWindowPlacement.fromJson(_map(value['placement'])),
      viewport: value['viewport'] == null
          ? null
          : Map<String, int>.from(value['viewport'] as Map),
    );
  }
}

class CombinationPane {
  CombinationPane({
    required this.kind,
    this.hostId,
    this.remotePath,
    this.serialPort,
    this.baudRate,
    this.ownerPane,
    this.shell,
  }) {
    if ((shell != null && (kind != 'console' || serialPort != null)) ||
        (ownerPane != null &&
            (!{'sftp', 'scp'}.contains(kind) ||
                ownerPane! < 0 ||
                ownerPane! >= WindowCombination.maxPanes)) ||
        !{'ssh', 'sftp', 'scp', 'rdp', 'vnc', 'console', 'telnet'}.contains(kind) ||
        (kind == 'console'
            ? hostId != null
            : hostId == null || !_identifier(hostId!)) ||
        (remotePath != null &&
            (!{'sftp', 'scp'}.contains(kind) ||
                !_safeText(remotePath!, 2048) ||
                !remotePath!.startsWith('/'))) ||
        (serialPort != null &&
            (kind != 'console' ||
                !_safeText(serialPort!, 256) ||
                baudRate == null)) ||
        (baudRate != null &&
            (serialPort == null || baudRate! < 300 || baudRate! > 4000000))) {
      throw FormatException(currentL10n.invalidWindowSetHostPathOr);
    }
  }
  final String kind;
  final String? hostId, remotePath, serialPort;
  final int? baudRate, ownerPane;

  /// Local shell launch metadata (kind + optional working directory) for a
  /// non-serial Console pane. Omitted for the system default so older
  /// recipes and clients stay byte-compatible.
  final LocalShellLaunch? shell;
  Map<String, Object?> toJson() => {
    'kind': kind,
    'host': hostId,
    'remote_path': remotePath,
    'serial_port': serialPort,
    'baud_rate': baudRate,
    if (ownerPane != null) 'owner': ownerPane,
    if (shell != null && !shell!.isDefault) 'shell': shell!.toJson(),
  };
  factory CombinationPane.fromJson(Map<String, Object?> json) {
    if (json.length !=
            5 +
                (json.containsKey('owner') ? 1 : 0) +
                (json.containsKey('shell') ? 1 : 0) ||
        (json.containsKey('owner') && json['owner'] is! int) ||
        !json.keys.toSet().containsAll({
          'kind',
          'host',
          'remote_path',
          'serial_port',
          'baud_rate',
        }) ||
        json['kind'] is! String ||
        (json['host'] != null && json['host'] is! String) ||
        (json['remote_path'] != null && json['remote_path'] is! String) ||
        (json['serial_port'] != null && json['serial_port'] is! String) ||
        (json['baud_rate'] != null && json['baud_rate'] is! int)) {
      throw FormatException(currentL10n.invalidWindowSetPane);
    }
    return CombinationPane(
      kind: json['kind'] as String,
      hostId: json['host'] as String?,
      remotePath: json['remote_path'] as String?,
      serialPort: json['serial_port'] as String?,
      baudRate: json['baud_rate'] as int?,
      ownerPane: json['owner'] as int?,
      shell: json.containsKey('shell')
          ? _localShell(json['shell'])
          : null,
    );
  }
}

LocalShellLaunch _localShell(Object? value) {
  try {
    return LocalShellLaunch.fromJson(value);
  } on FormatException {
    throw FormatException(currentL10n.invalidWindowSetPane);
  }
}

bool _safeText(String value, int max) =>
    value.isNotEmpty &&
    utf8.encode(value).length <= max &&
    !RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(value);
Map<String, Object?> _freezeTree(Map<String, Object?> value, int depth) {
  if (depth > 16) throw FormatException(currentL10n.windowSetIsNestedTooDeeply);
  return Map.unmodifiable(
    value.map(
      (key, item) => MapEntry(
        key,
        item is Map ? _freezeTree(_map(item), depth + 1) : item,
      ),
    ),
  );
}

bool _identifier(String value) =>
    value.isNotEmpty &&
    value.length <= 128 &&
    RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(value);
Map<String, Object?> _map(Object? value) {
  if (value is! Map || value.keys.any((k) => k is! String)) {
    throw FormatException(currentL10n.invalidWindowSetNode);
  }
  return Map<String, Object?>.from(value);
}

/// One explicit restore run. Validation completes before any connection opens;
/// the caller's scope lease is checked around every asynchronous boundary.
class CombinationRestoreResult {
  const CombinationRestoreResult(
    this.sessions,
    this.failures,
    this.stale, {
    this.independentOpened = 0,
  });
  final Map<int, String> sessions;
  final int failures;
  final int independentOpened;
  final bool stale;
}

class CombinationRestoreCoordinator {
  bool _busy = false;
  bool get busy => _busy;
  Future<CombinationRestoreResult?> restore({
    required WindowCombination recipe,
    required bool Function() isCurrent,
    required bool Function(CombinationPane) canResolve,
    required Future<String?> Function(CombinationPane) open,
    Future<String?> Function(CombinationPane, String ownerId)? openAttachedFile,
    bool Function(int)? independentPane,
    Future<bool> Function(int, CombinationPane)? openIndependent,
  }) async {
    if (_busy || !isCurrent()) return null;
    _busy = true;
    final sessions = <int, String>{};
    var failures = 0, independentOpened = 0;
    try {
      for (final pane in recipe.panes) {
        if (!canResolve(pane)) {
          throw StateError(currentL10n.aHostInThisWindowSet);
        }
      }
      // Owners first, without changing persisted pane indices or group topology.
      final ordered = [
        ...recipe.panes.indexed.where(
          (e) => !{'sftp', 'scp'}.contains(e.$2.kind),
        ),
        ...recipe.panes.indexed.where(
          (e) => {'sftp', 'scp'}.contains(e.$2.kind),
        ),
      ];
      for (final (index, pane) in ordered) {
        if (!isCurrent())
          return CombinationRestoreResult(
            sessions,
            failures,
            true,
            independentOpened: independentOpened,
          );
        try {
          if (!canResolve(pane)) {
            failures++;
            continue;
          }
          if (independentPane?.call(index) == true) {
            final opened = await openIndependent?.call(index, pane) ?? false;
            if (!isCurrent())
              return CombinationRestoreResult(
                sessions,
                failures,
                true,
                independentOpened: independentOpened,
              );
            if (opened)
              independentOpened++;
            else
              failures++;
            continue;
          }
          String? id;
          if ({'sftp', 'scp'}.contains(pane.kind)) {
            final ownerIndex =
                pane.ownerPane ??
                recipe.panes.indexed
                    .where(
                      (e) =>
                          e.$2.kind == 'ssh' &&
                          e.$2.hostId == pane.hostId &&
                          sessions.containsKey(e.$1),
                    )
                    .map((e) => e.$1)
                    .firstOrNull;
            final owner = ownerIndex == null ? null : sessions[ownerIndex];
            // Never connect an implicit replacement or borrow a preexisting session.
            id = owner == null
                ? null
                : await openAttachedFile?.call(pane, owner);
          } else {
            id = await open(pane);
          }
          if (!isCurrent())
            return CombinationRestoreResult(
              sessions,
              failures,
              true,
              independentOpened: independentOpened,
            );
          if (id == null || sessions.values.contains(id)) {
            failures++;
          } else {
            sessions[index] = id;
          }
        } catch (_) {
          if (!isCurrent())
            return CombinationRestoreResult(
              sessions,
              failures,
              true,
              independentOpened: independentOpened,
            );
          failures++;
        }
      }
      return CombinationRestoreResult(
        Map.unmodifiable(sessions),
        failures,
        false,
        independentOpened: independentOpened,
      );
    } finally {
      _busy = false;
    }
  }
}
