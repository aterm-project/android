import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../domain/models.dart';
import 'session_workspace.dart';
import '../l10n/l10n.dart';

const _manifestKey = 'group_session_layout_v1';
const _maxPanes = 32;
final _idPattern = RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_.:-]{0,255}$');

bool matchesGroupHostConnection(HostRecord connected, HostRecord current) =>
    connected.id == current.id &&
    connected.protocol == HostProtocol.ssh &&
    current.protocol == HostProtocol.ssh &&
    connected.address == current.address &&
    connected.port == current.port &&
    connected.username == current.username &&
    connected.jumpHostId == current.jumpHostId;

class GroupSessionPane {
  const GroupSessionPane({required this.paneId, required this.hostId});
  final String paneId;
  final String hostId;
}

/// Group-bound layout intent only. Hosts are resolved again in the active
/// encrypted scope; no credentials, output or live session IDs are serialized.
class GroupSessionLayout {
  GroupSessionLayout._(this._root, this.panes, this._activePaneId);
  final SessionWorkspaceNode
  _root; // Leaf IDs are saved pane IDs, never sessions.
  final List<GroupSessionPane> panes;
  final String _activePaneId;
  List<String> get hostIds =>
      panes.map((pane) => pane.hostId).toList(growable: false);

  static GroupSessionLayout? read(GroupRecord group) {
    final raw = group.manifest?[_manifestKey];
    if (raw == null) return null;
    return _decode(raw);
  }

  static GroupSessionLayout _decode(Object? raw) {
    final invalid = FormatException(currentL10n.theSavedGroupLayoutIsInvalid);
    if (raw is! Map ||
        jsonEncode(raw).length > 65536 ||
        raw.length != 3 ||
        raw['version'] != 1 ||
        raw['active'] is! String) {
      throw invalid;
    }
    final panes = <GroupSessionPane>[];
    final seen = <String>{};
    SessionWorkspaceNode node(Object? value, int depth) {
      if (depth > 31 || value is! Map) throw invalid;
      if (value['kind'] == 'pane') {
        final id = value['id'], host = value['host'];
        if (value.length != 3 ||
            !_validId(id) ||
            !_validId(host) ||
            !seen.add(id as String) ||
            seen.length > _maxPanes) {
          throw invalid;
        }
        panes.add(GroupSessionPane(paneId: id, hostId: host as String));
        return SessionWorkspacePane(id);
      }
      final ratio = value['ratio'];
      if (value.length != 5 ||
          value['kind'] != 'split' ||
          !{'horizontal', 'vertical'}.contains(value['axis']) ||
          ratio is! int ||
          ratio < 1500 ||
          ratio > 8500) {
        throw invalid;
      }
      return SessionWorkspaceSplit(
        axis: value['axis'] == 'horizontal' ? Axis.horizontal : Axis.vertical,
        ratio: ratio / 10000,
        first: node(value['first'], depth + 1),
        second: node(value['second'], depth + 1),
      );
    }

    final root = node(raw['root'], 0);
    if (!seen.contains(raw['active'])) throw invalid;
    return GroupSessionLayout._(
      root,
      List.unmodifiable(panes),
      raw['active'] as String,
    );
  }

  factory GroupSessionLayout.capture({
    required SessionWorkspaceNode root,
    required Map<String, String> hostIdsBySession,
    String? selectedSessionId,
  }) {
    final panes = <GroupSessionPane>[];
    String? active;
    final seen = <String>{};
    SessionWorkspaceNode? capture(SessionWorkspaceNode value, int depth) {
      if (depth > 31) throw FormatException(currentL10n.upTo32PanesCanBe);
      if (value is SessionWorkspacePane) {
        final host = hostIdsBySession[value.sessionId];
        if (host == null) return null;
        if (!_validId(host) ||
            !seen.add(value.sessionId) ||
            seen.length > _maxPanes) {
          throw FormatException(currentL10n.invalidLayoutHostsOrMoreThan);
        }
        final id = const Uuid().v4();
        panes.add(GroupSessionPane(paneId: id, hostId: host));
        if (value.sessionId == selectedSessionId) active = id;
        return SessionWorkspacePane(id);
      }
      final split = value as SessionWorkspaceSplit;
      final a = capture(split.first, depth + 1),
          b = capture(split.second, depth + 1);
      if (a == null) return b;
      if (b == null) return a;
      if (!split.ratio.isFinite) {
        throw FormatException(currentL10n.invalidLayoutRatio);
      }
      return SessionWorkspaceSplit(
        axis: split.axis,
        first: a,
        second: b,
        ratio: split.ratio.clamp(.15, .85),
      );
    }

    final savedRoot = capture(root, 0);
    if (savedRoot == null) {
      throw FormatException(currentL10n.thisWindowHasNoSshSessions);
    }
    return GroupSessionLayout._(
      savedRoot,
      List.unmodifiable(panes),
      active ?? panes.first.paneId,
    );
  }

  factory GroupSessionLayout.forHosts(List<String> hostIds) {
    if (hostIds.isEmpty ||
        hostIds.length > _maxPanes ||
        hostIds.any((id) => !_validId(id))) {
      throw FormatException(currentL10n.aGroupLayoutNeeds1To);
    }
    final panes = [
      for (final id in hostIds)
        GroupSessionPane(paneId: const Uuid().v4(), hostId: id),
    ];
    SessionWorkspaceNode build(List<GroupSessionPane> items, Axis axis) {
      if (items.length == 1) return SessionWorkspacePane(items.single.paneId);
      final middle = (items.length / 2).ceil();
      return SessionWorkspaceSplit(
        axis: axis,
        first: build(
          items.sublist(0, middle),
          axis == Axis.horizontal ? Axis.vertical : Axis.horizontal,
        ),
        second: build(
          items.sublist(middle),
          axis == Axis.horizontal ? Axis.vertical : Axis.horizontal,
        ),
      );
    }

    return GroupSessionLayout._(
      build(panes, Axis.horizontal),
      List.unmodifiable(panes),
      panes.first.paneId,
    );
  }

  /// Failed/missing connections are omitted; a failed attempt never borrows an
  /// unrelated active session. Mapping duplicate live sessions is rejected.
  bool apply(
    SessionWorkspaceController controller, {
    required Map<String, String> sessionIdsByPane,
  }) {
    final accepted = <String>{};
    SessionWorkspaceNode? restore(SessionWorkspaceNode value) {
      if (value is SessionWorkspacePane) {
        final id = sessionIdsByPane[value.sessionId];
        if (id == null) return null;
        if (id.isEmpty || !accepted.add(id)) {
          throw FormatException(currentL10n.invalidGroupSessionMapping);
        }
        return SessionWorkspacePane(id);
      }
      final split = value as SessionWorkspaceSplit;
      final a = restore(split.first), b = restore(split.second);
      if (a == null) return b;
      if (b == null) return a;
      return SessionWorkspaceSplit(
        axis: split.axis,
        ratio: split.ratio,
        first: a,
        second: b,
      );
    }

    final root = restore(_root);
    if (root == null) return false;
    controller.restore(root, selectedId: sessionIdsByPane[_activePaneId]);
    return true;
  }

  Map<String, Object?> _toJson() {
    final byId = {for (final pane in panes) pane.paneId: pane.hostId};
    Map<String, Object?> node(SessionWorkspaceNode value) {
      if (value is SessionWorkspacePane) {
        return {
          'kind': 'pane',
          'id': value.sessionId,
          'host': byId[value.sessionId],
        };
      }
      final split = value as SessionWorkspaceSplit;
      return {
        'kind': 'split',
        'axis': split.axis.name,
        'ratio': (split.ratio * 10000).round(),
        'first': node(split.first),
        'second': node(split.second),
      };
    }

    return {'version': 1, 'active': _activePaneId, 'root': node(_root)};
  }

  GroupRecord writeTo(GroupRecord group) =>
      _copy(group, {...?group.manifest, _manifestKey: _toJson()});
  static GroupRecord clear(GroupRecord group) =>
      _copy(group, {...?group.manifest}..remove(_manifestKey));
  static GroupRecord _copy(GroupRecord group, Map<String, Object?> manifest) =>
      GroupRecord(
        id: group.id,
        name: group.name,
        color: group.color,
        parentId: group.parentId,
        defaultCredentialId: group.defaultCredentialId,
        manifest: manifest.isEmpty ? null : manifest,
      );

  static List<HostRecord> groupHosts(
    GroupRecord group,
    List<GroupRecord> groups,
    List<HostRecord> hosts,
  ) {
    final ids = {group.id};
    for (var changed = true; changed;) {
      changed = false;
      for (final item in groups) {
        if (ids.contains(item.parentId) && ids.add(item.id)) changed = true;
      }
    }
    return hosts
        .where(
          (host) =>
              host.protocol == HostProtocol.ssh && ids.contains(host.groupId),
        )
        .toList();
  }
}

bool _validId(Object? value) =>
    value is String && _idPattern.firstMatch(value)?.end == value.length;
