import 'dart:convert';

import 'package:uuid/uuid.dart';

/// Schema version used by terminal-tab Workspace records.
///
/// Version 1 deliberately stores layout intent only. It does not contain SSH
/// connection state, terminal output, credentials, or runtime tab IDs.
const int workspaceLayoutSchemaVersion = 1;
const int workspaceSplitLayoutSchemaVersion = 2;
const int workspaceNestedSplitLayoutSchemaVersion = 3;
const int maxTmuxSessionNameCharacters = 41;
const int maxWorkspacePanes = 8;
const int maxWorkspaceSplitDepth = 7;
const int maxWorkspaceNameUtf8Bytes = 256;
const int minWorkspaceSplitRatioBasisPoints = 2500;
const int maxWorkspaceSplitRatioBasisPoints = 7500;

final RegExp _workspaceUuidV4 = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);
final RegExp _workspaceNameControlCharacters = RegExp(r'[\x00-\x1f\x7f-\x9f]');
final RegExp _tmuxSessionNamePattern = RegExp(r'^atermius_[0-9a-f]{32}$');
const String workspaceSessionDescriptorsManifestKey =
    'workspace_session_descriptors_v1';
const Object _manifestNotProvided = Object();

/// One terminal pane in a [WorkspaceRecord].
///
/// Pane IDs are layout identities; [hostId] is a reference to a Host record
/// in the same Vault and is resolved at use time.
class WorkspacePane {
  const WorkspacePane._({required this.paneId, required this.hostId});

  final String paneId;
  final String hostId;

  Map<String, Object?> toJson() => {
    'kind': 'terminal',
    'pane_id': paneId,
    'host_id': hostId,
  };
}

/// A per-pane reference to a tmux session on the pane's Host.
///
/// This stores only a bounded tmux session name. It does not contain a command,
/// SSH credential, connection identifier, or terminal runtime state.
class WorkspaceSessionDescriptor {
  WorkspaceSessionDescriptor({
    required this.paneId,
    required this.hostId,
    required this.tmuxSessionName,
  }) {
    _validateUuidV4(paneId, 'pane_id');
    _validateUuidV4(hostId, 'host_id');
    _validateTmuxSessionName(tmuxSessionName);
  }

  /// Creates an application-owned tmux session name for this pane binding.
  factory WorkspaceSessionDescriptor.createForPane({
    required String paneId,
    required String hostId,
  }) => WorkspaceSessionDescriptor(
    paneId: paneId,
    hostId: hostId,
    tmuxSessionName: 'atermius_${const Uuid().v4().replaceAll('-', '')}',
  );

  final String paneId;
  final String hostId;
  final String tmuxSessionName;

  Map<String, Object?> toJson() => {
    'pane_id': paneId,
    'host_id': hostId,
    'tmux_session_name': tmuxSessionName,
  };
}

/// Shape of a saved terminal layout.
enum WorkspaceLayoutKind { terminalTabs, split }

/// Direction of a divider in a split Workspace tree.
enum WorkspaceSplitAxis { horizontal, vertical }

/// Immutable recursive tree used by schema-v3 split Workspaces.
sealed class WorkspaceLayoutNode {
  const WorkspaceLayoutNode();
}

/// A terminal leaf in a Workspace layout tree.
class WorkspaceTerminalNode extends WorkspaceLayoutNode {
  WorkspaceTerminalNode({required this.paneId, required this.hostId}) {
    _validateUuidV4(paneId, 'pane_id');
    _validateUuidV4(hostId, 'host_id');
  }

  final String paneId;
  final String hostId;
}

/// A binary split node. A saved layout is bounded to eight terminal leaves.
class WorkspaceSplitNode extends WorkspaceLayoutNode {
  WorkspaceSplitNode({
    required this.axis,
    required this.splitRatioBasisPoints,
    required this.first,
    required this.second,
  }) {
    _validateSplitRatio(splitRatioBasisPoints);
  }

  final WorkspaceSplitAxis axis;
  final int splitRatioBasisPoints;
  final WorkspaceLayoutNode first;
  final WorkspaceLayoutNode second;
}

/// An end-to-end encrypted named layout for terminal tabs.
///
/// The serialized v1 payload has the exact fields `schema_version`, `id`,
/// `type`, `name`, `layout_tree`, and `host_refs` (plus the optional encrypted
/// `_manifest`). `_record_id` and `_revision_id` are accepted as repository
/// metadata by [fromJson], but are never serialized as payload fields.
class WorkspaceRecord {
  WorkspaceRecord._({
    required this.id,
    required this.name,
    required List<WorkspacePane> panes,
    required this.activePaneId,
    required this.layoutKind,
    required this.schemaVersion,
    required this.splitTree,
    required this.splitAxis,
    required this.splitRatioBasisPoints,
    required this.revisionId,
    required List<WorkspaceSessionDescriptor> sessionDescriptors,
    required Map<String, Object?>? manifest,
  }) : panes = List<WorkspacePane>.unmodifiable(panes),
       sessionDescriptors = List<WorkspaceSessionDescriptor>.unmodifiable(
         sessionDescriptors,
       ),
       hostRefs = List<String>.unmodifiable(
         (panes.map((pane) => pane.hostId).toSet().toList()..sort()),
       ),
       manifest = manifest == null
           ? null
           : Map<String, Object?>.unmodifiable(manifest);

  /// Creates a workspace from its ordered Host references.
  ///
  /// Every Host ID creates a terminal pane, including repeated IDs. Pane IDs
  /// are generated when omitted. [activeIndex] is an index into [hostIds].
  /// The name is trimmed before it is stored.
  factory WorkspaceRecord.fromHostIds({
    required String name,
    required List<String> hostIds,
    int activeIndex = 0,
    String? id,
    List<String>? paneIds,
    String? revisionId,
    List<WorkspaceSessionDescriptor>? sessionDescriptors,
    Map<String, Object?>? manifest,
  }) {
    final resolvedId = id ?? const Uuid().v4();
    _validateUuidV4(resolvedId, 'id');
    if (revisionId != null) _validateUuidV4(revisionId, '_revision_id');
    final normalizedName = name.trim();
    _validateName(normalizedName);
    final panes = _panesFromHostIds(hostIds, paneIds: paneIds);
    if (activeIndex < 0 || activeIndex >= panes.length) {
      throw const FormatException(
        'activeIndex must reference a workspace pane',
      );
    }
    final sessionState = _workspaceSessionState(
      manifest,
      sessionDescriptors,
      panes,
    );
    return WorkspaceRecord._(
      id: resolvedId,
      name: normalizedName,
      panes: panes,
      activePaneId: panes[activeIndex].paneId,
      layoutKind: WorkspaceLayoutKind.terminalTabs,
      schemaVersion: workspaceLayoutSchemaVersion,
      splitTree: null,
      splitAxis: null,
      splitRatioBasisPoints: null,
      revisionId: revisionId,
      sessionDescriptors: sessionState.descriptors,
      manifest: sessionState.manifest,
    );
  }

  /// Creates a schema-v2 two-pane split Workspace from ordered Host IDs.
  ///
  /// The ratio is the fraction allocated to the first pane in basis points.
  factory WorkspaceRecord.fromSplitHostIds({
    required String name,
    required List<String> hostIds,
    required WorkspaceSplitAxis axis,
    int splitRatioBasisPoints = 5000,
    int activeIndex = 0,
    String? id,
    List<String>? paneIds,
    String? revisionId,
    List<WorkspaceSessionDescriptor>? sessionDescriptors,
    Map<String, Object?>? manifest,
  }) {
    final resolvedId = id ?? const Uuid().v4();
    _validateUuidV4(resolvedId, 'id');
    if (revisionId != null) _validateUuidV4(revisionId, '_revision_id');
    final normalizedName = name.trim();
    _validateName(normalizedName);
    final panes = _panesFromHostIds(hostIds, paneIds: paneIds);
    if (panes.length != 2) {
      throw const FormatException(
        'A split Workspace must have exactly two panes',
      );
    }
    if (activeIndex < 0 || activeIndex >= panes.length) {
      throw const FormatException(
        'activeIndex must reference a workspace pane',
      );
    }
    _validateSplitRatio(splitRatioBasisPoints);
    final splitTree = WorkspaceSplitNode(
      axis: axis,
      splitRatioBasisPoints: splitRatioBasisPoints,
      first: WorkspaceTerminalNode(
        paneId: panes[0].paneId,
        hostId: panes[0].hostId,
      ),
      second: WorkspaceTerminalNode(
        paneId: panes[1].paneId,
        hostId: panes[1].hostId,
      ),
    );
    final sessionState = _workspaceSessionState(
      manifest,
      sessionDescriptors,
      panes,
    );
    return WorkspaceRecord._(
      id: resolvedId,
      name: normalizedName,
      panes: panes,
      activePaneId: panes[activeIndex].paneId,
      layoutKind: WorkspaceLayoutKind.split,
      schemaVersion: workspaceSplitLayoutSchemaVersion,
      splitTree: splitTree,
      splitAxis: axis,
      splitRatioBasisPoints: splitRatioBasisPoints,
      revisionId: revisionId,
      sessionDescriptors: sessionState.descriptors,
      manifest: sessionState.manifest,
    );
  }

  /// Creates a strict schema-v3 recursive split Workspace.
  factory WorkspaceRecord.fromSplitTree({
    required String name,
    required WorkspaceLayoutNode layoutTree,
    required String activePaneId,
    String? id,
    String? revisionId,
    List<WorkspaceSessionDescriptor>? sessionDescriptors,
    Map<String, Object?>? manifest,
  }) {
    final resolvedId = id ?? const Uuid().v4();
    _validateUuidV4(resolvedId, 'id');
    if (revisionId != null) _validateUuidV4(revisionId, '_revision_id');
    final normalizedName = name.trim();
    _validateName(normalizedName);
    if (layoutTree is! WorkspaceSplitNode) {
      throw const FormatException('A split Workspace must start with a split');
    }
    final panes = _panesFromTree(layoutTree);
    if (panes.length < 2 || panes.length > maxWorkspacePanes) {
      throw const FormatException(
        'A split Workspace must contain between 2 and 8 terminal panes',
      );
    }
    _validateUuidV4(activePaneId, 'active_pane_id');
    if (!panes.any((pane) => pane.paneId == activePaneId)) {
      throw const FormatException(
        'active_pane_id must reference a pane in layout_tree',
      );
    }
    final sessionState = _workspaceSessionState(
      manifest,
      sessionDescriptors,
      panes,
    );
    return WorkspaceRecord._(
      id: resolvedId,
      name: normalizedName,
      panes: panes,
      activePaneId: activePaneId,
      layoutKind: WorkspaceLayoutKind.split,
      schemaVersion: workspaceNestedSplitLayoutSchemaVersion,
      splitTree: layoutTree,
      splitAxis: layoutTree.axis,
      splitRatioBasisPoints: layoutTree.splitRatioBasisPoints,
      revisionId: revisionId,
      sessionDescriptors: sessionState.descriptors,
      manifest: sessionState.manifest,
    );
  }

  /// Decodes strict schema-v1, schema-v2, or schema-v3 payloads, optionally
  /// with repository fields.
  factory WorkspaceRecord.fromJson(Map<String, dynamic> json) {
    const requiredFields = {
      'schema_version',
      'id',
      'type',
      'name',
      'layout_tree',
      'host_refs',
    };
    const repositoryFields = {'_record_id', '_revision_id', '_manifest'};
    final keys = json.keys.toSet();
    if (!keys.containsAll(requiredFields) ||
        keys.any(
          (field) =>
              !requiredFields.contains(field) &&
              !repositoryFields.contains(field),
        )) {
      throw const FormatException(
        'Workspace record fields are incomplete or unknown',
      );
    }
    if (json['type'] != 'workspace') {
      throw const FormatException('Record type must be workspace');
    }
    final schemaVersion = json['schema_version'];
    if (schemaVersion is! int ||
        (schemaVersion != workspaceLayoutSchemaVersion &&
            schemaVersion != workspaceSplitLayoutSchemaVersion &&
            schemaVersion != workspaceNestedSplitLayoutSchemaVersion)) {
      throw const FormatException('Workspace schema version is unsupported');
    }

    final id = _requiredString(json['id'], 'id');
    _validateUuidV4(id, 'id');
    if (json.containsKey('_record_id')) {
      final recordId = _requiredString(json['_record_id'], '_record_id');
      _validateUuidV4(recordId, '_record_id');
      if (recordId != id) {
        throw const FormatException(
          'Workspace payload ID does not match record ID',
        );
      }
    }

    final name = _requiredString(json['name'], 'name');
    _validateName(name);
    if (name != name.trim()) {
      throw const FormatException('Workspace name must be trimmed');
    }

    final layoutTree = _requiredStringMap(json['layout_tree'], 'layout_tree');
    final layoutKind = switch ((schemaVersion, layoutTree['kind'])) {
      (workspaceLayoutSchemaVersion, 'terminal_tabs') =>
        WorkspaceLayoutKind.terminalTabs,
      (workspaceSplitLayoutSchemaVersion, 'split') => WorkspaceLayoutKind.split,
      (workspaceNestedSplitLayoutSchemaVersion, 'split') =>
        WorkspaceLayoutKind.split,
      _ => throw const FormatException('Workspace layout kind is unsupported'),
    };
    final String activePaneId;
    final WorkspaceSplitNode? splitTree;
    final WorkspaceSplitAxis? splitAxis;
    final int? splitRatioBasisPoints;
    final List<WorkspacePane> panes;
    if (layoutKind == WorkspaceLayoutKind.terminalTabs) {
      _requireExactKeys(layoutTree, const {
        'kind',
        'active_pane_id',
        'panes',
      }, 'layout_tree');
      activePaneId = _requiredString(
        layoutTree['active_pane_id'],
        'active_pane_id',
      );
      _validateUuidV4(activePaneId, 'active_pane_id');
      splitAxis = null;
      splitRatioBasisPoints = null;
      splitTree = null;
      panes = _decodeTerminalPanes(layoutTree['panes']);
    } else {
      _requireExactKeys(layoutTree, const {
        'kind',
        'axis',
        'split_ratio_basis_points',
        'active_pane_id',
        'panes',
      }, 'layout_tree');
      activePaneId = _requiredString(
        layoutTree['active_pane_id'],
        'active_pane_id',
      );
      _validateUuidV4(activePaneId, 'active_pane_id');
      if (schemaVersion == workspaceSplitLayoutSchemaVersion) {
        final axis = _decodeSplitAxis(layoutTree['axis']);
        final ratio = _decodeSplitRatio(layoutTree['split_ratio_basis_points']);
        final rawPanes = layoutTree['panes'];
        if (rawPanes is! List || rawPanes.length != 2) {
          throw const FormatException(
            'Workspace pane count is invalid for its layout kind',
          );
        }
        panes = _decodeTerminalPanes(rawPanes);
        splitTree = WorkspaceSplitNode(
          axis: axis,
          splitRatioBasisPoints: ratio,
          first: WorkspaceTerminalNode(
            paneId: panes[0].paneId,
            hostId: panes[0].hostId,
          ),
          second: WorkspaceTerminalNode(
            paneId: panes[1].paneId,
            hostId: panes[1].hostId,
          ),
        );
      } else {
        final nodes = <String>{};
        splitTree = _decodeSplitNode(
          layoutTree,
          isRoot: true,
          splitDepth: 1,
          paneIds: nodes,
        );
        panes = _panesFromTree(splitTree);
        if (panes.length < 2 || panes.length > maxWorkspacePanes) {
          throw const FormatException(
            'Workspace pane count is invalid for its layout kind',
          );
        }
        if (!nodes.contains(activePaneId)) {
          throw const FormatException(
            'active_pane_id must reference a pane in layout_tree',
          );
        }
      }
      splitAxis = splitTree.axis;
      splitRatioBasisPoints = splitTree.splitRatioBasisPoints;
    }
    if (layoutKind == WorkspaceLayoutKind.terminalTabs &&
        !panes.any((pane) => pane.paneId == activePaneId)) {
      throw const FormatException(
        'active_pane_id must reference a pane in layout_tree',
      );
    }

    final rawHostRefs = json['host_refs'];
    if (rawHostRefs is! List) {
      throw const FormatException('host_refs must be a list');
    }
    final hostRefs = <String>[];
    String? previous;
    for (final value in rawHostRefs) {
      final hostId = _requiredString(value, 'host_refs');
      _validateUuidV4(hostId, 'host_refs');
      if (previous != null && previous.compareTo(hostId) >= 0) {
        throw const FormatException(
          'host_refs must be sorted and contain no duplicates',
        );
      }
      hostRefs.add(hostId);
      previous = hostId;
    }
    final derivedHostRefs = (panes.map((pane) => pane.hostId).toSet().toList()
      ..sort());
    if (!_sameStrings(hostRefs, derivedHostRefs)) {
      throw const FormatException(
        'host_refs must exactly match the Host IDs in layout_tree',
      );
    }

    final rawRevisionId = json['_revision_id'];
    final String? revisionId;
    if (!json.containsKey('_revision_id') || rawRevisionId == null) {
      revisionId = null;
    } else {
      revisionId = _requiredString(rawRevisionId, '_revision_id');
      _validateUuidV4(revisionId, '_revision_id');
    }
    final sessionState = _workspaceSessionState(
      json.containsKey('_manifest') ? json['_manifest'] : null,
      null,
      panes,
    );

    return WorkspaceRecord._(
      id: id,
      name: name,
      panes: panes,
      activePaneId: activePaneId,
      layoutKind: layoutKind,
      schemaVersion: schemaVersion,
      splitTree: splitTree,
      splitAxis: splitAxis,
      splitRatioBasisPoints: splitRatioBasisPoints,
      revisionId: revisionId,
      sessionDescriptors: sessionState.descriptors,
      manifest: sessionState.manifest,
    );
  }

  final String id;
  final String name;
  final List<WorkspacePane> panes;
  final String activePaneId;
  final WorkspaceLayoutKind layoutKind;
  final int schemaVersion;
  final WorkspaceSplitNode? splitTree;
  final WorkspaceSplitAxis? splitAxis;
  final int? splitRatioBasisPoints;
  final String? revisionId;
  final List<WorkspaceSessionDescriptor> sessionDescriptors;
  final Map<String, Object?>? manifest;

  /// Recursive split tree for v2/v3 records; v1 terminal tabs return null.
  WorkspaceSplitNode? get layoutTree => splitTree;

  /// Sorted, unique Host IDs derived from the pane list.
  final List<String> hostRefs;

  bool get isSplit => layoutKind == WorkspaceLayoutKind.split;

  List<String> get hostIds =>
      List<String>.unmodifiable(panes.map((pane) => pane.hostId));

  int get activeIndex =>
      panes.indexWhere((pane) => pane.paneId == activePaneId);

  /// Makes a validated copy while keeping workspace and surviving pane IDs.
  ///
  /// If [hostIds] changes length, existing pane IDs are kept by position and
  /// new pane IDs are generated for added panes. A resulting active index that
  /// is outside the new pane list is rejected.
  WorkspaceRecord copyWith({
    String? name,
    List<String>? hostIds,
    int? activeIndex,
    String? revisionId,
    bool clearRevisionId = false,
    Object? manifest = _manifestNotProvided,
    bool clearManifest = false,
    List<WorkspaceSessionDescriptor>? sessionDescriptors,
  }) {
    final nextName = name == null ? this.name : name.trim();
    _validateName(nextName);
    final nextHostIds = hostIds ?? this.hostIds;
    final paneIds = hostIds == null
        ? panes.map((pane) => pane.paneId).toList(growable: false)
        : List<String>.generate(
            nextHostIds.length,
            (index) =>
                index < panes.length ? panes[index].paneId : const Uuid().v4(),
          );
    final nextPanes = _panesFromHostIds(nextHostIds, paneIds: paneIds);
    final nextActiveIndex = activeIndex ?? this.activeIndex;
    if (nextActiveIndex < 0 || nextActiveIndex >= nextPanes.length) {
      throw const FormatException(
        'activeIndex must reference a workspace pane',
      );
    }
    if (revisionId != null) _validateUuidV4(revisionId, '_revision_id');
    final preserveSplit =
        layoutKind == WorkspaceLayoutKind.split &&
        nextPanes.length == panes.length;
    final WorkspaceSplitNode? nextSplitTree;
    if (!preserveSplit) {
      nextSplitTree = null;
    } else if (schemaVersion == workspaceNestedSplitLayoutSchemaVersion) {
      nextSplitTree = _treeWithHosts(splitTree!, nextPanes);
    } else {
      nextSplitTree = WorkspaceSplitNode(
        axis: splitAxis!,
        splitRatioBasisPoints: splitRatioBasisPoints!,
        first: WorkspaceTerminalNode(
          paneId: nextPanes[0].paneId,
          hostId: nextPanes[0].hostId,
        ),
        second: WorkspaceTerminalNode(
          paneId: nextPanes[1].paneId,
          hostId: nextPanes[1].hostId,
        ),
      );
    }
    final suppliedManifest = clearManifest
        ? null
        : identical(manifest, _manifestNotProvided)
        ? this.manifest
        : _validatedManifest(manifest);
    final retainedSessionDescriptors =
        sessionDescriptors ??
        (clearManifest
            ? const <WorkspaceSessionDescriptor>[]
            : this.sessionDescriptors
                  .where(
                    (descriptor) => nextPanes.any(
                      (pane) =>
                          pane.paneId == descriptor.paneId &&
                          pane.hostId == descriptor.hostId,
                    ),
                  )
                  .toList(growable: false));
    final sessionState = _workspaceSessionState(
      suppliedManifest,
      retainedSessionDescriptors,
      nextPanes,
    );
    return WorkspaceRecord._(
      id: id,
      name: nextName,
      panes: nextPanes,
      activePaneId: nextPanes[nextActiveIndex].paneId,
      layoutKind: preserveSplit
          ? WorkspaceLayoutKind.split
          : WorkspaceLayoutKind.terminalTabs,
      schemaVersion: preserveSplit
          ? schemaVersion
          : workspaceLayoutSchemaVersion,
      splitTree: nextSplitTree,
      splitAxis: preserveSplit ? splitAxis : null,
      splitRatioBasisPoints: preserveSplit ? splitRatioBasisPoints : null,
      revisionId: clearRevisionId ? null : revisionId ?? this.revisionId,
      sessionDescriptors: sessionState.descriptors,
      manifest: sessionState.manifest,
    );
  }

  /// Returns a validated copy with a tmux session attached to one exact pane
  /// and Host pair.
  WorkspaceRecord withSessionDescriptor(WorkspaceSessionDescriptor descriptor) {
    final pane = panes
        .where((item) => item.paneId == descriptor.paneId)
        .firstOrNull;
    if (pane == null || pane.hostId != descriptor.hostId) {
      throw const FormatException(
        'A session descriptor must match an existing pane and Host',
      );
    }
    return copyWith(
      sessionDescriptors: [
        ...sessionDescriptors.where((item) => item.paneId != descriptor.paneId),
        descriptor,
      ],
    );
  }

  /// Returns a copy without the selected pane's tmux session reference.
  WorkspaceRecord withoutSessionDescriptor(String paneId) {
    if (!panes.any((pane) => pane.paneId == paneId)) {
      throw const FormatException('Workspace pane does not exist');
    }
    return copyWith(
      sessionDescriptors: sessionDescriptors
          .where((descriptor) => descriptor.paneId != paneId)
          .toList(growable: false),
    );
  }

  /// Makes a separately named copy with a new Workspace and pane identity.
  ///
  /// Split geometry, ordered Host references, active-pane position, and other
  /// encrypted manifest values are retained. Pane IDs are unique to the copy,
  /// so tmux session references are deliberately dropped.
  WorkspaceRecord duplicateWithNewIdentity({required String name}) {
    final nextId = const Uuid().v4();
    if (schemaVersion == workspaceNestedSplitLayoutSchemaVersion) {
      final duplicatedTree = _treeWithFreshPaneIds(splitTree!, activePaneId);
      return WorkspaceRecord.fromSplitTree(
        id: nextId,
        name: name,
        layoutTree: duplicatedTree.layoutTree,
        activePaneId: duplicatedTree.activePaneId,
        sessionDescriptors: const [],
        manifest: _manifestWithoutSessionDescriptors(manifest),
      );
    }
    if (schemaVersion == workspaceSplitLayoutSchemaVersion) {
      return WorkspaceRecord.fromSplitHostIds(
        id: nextId,
        name: name,
        hostIds: hostIds,
        paneIds: List<String>.generate(panes.length, (_) => const Uuid().v4()),
        axis: splitAxis!,
        splitRatioBasisPoints: splitRatioBasisPoints!,
        activeIndex: activeIndex,
        sessionDescriptors: const [],
        manifest: _manifestWithoutSessionDescriptors(manifest),
      );
    }
    return WorkspaceRecord.fromHostIds(
      id: nextId,
      name: name,
      hostIds: hostIds,
      paneIds: List<String>.generate(panes.length, (_) => const Uuid().v4()),
      activeIndex: activeIndex,
      sessionDescriptors: const [],
      manifest: _manifestWithoutSessionDescriptors(manifest),
    );
  }

  /// Removes a terminal pane while preserving surviving pane IDs.
  ///
  /// Schema-v3 split nodes with one remaining child are collapsed. If that
  /// leaves only one terminal, the record becomes a schema-v1 tab layout.
  WorkspaceRecord withoutPane(String paneId) {
    final removedIndex = panes.indexWhere((pane) => pane.paneId == paneId);
    if (removedIndex < 0) {
      throw const FormatException('Workspace pane does not exist');
    }
    if (panes.length == 1) {
      throw const FormatException(
        'A Workspace must retain at least one terminal pane',
      );
    }
    final nextPanes = panes.where((pane) => pane.paneId != paneId).toList();
    final nextActiveIndex = activeIndex > removedIndex
        ? activeIndex - 1
        : activeIndex == removedIndex
        ? removedIndex.clamp(0, nextPanes.length - 1)
        : activeIndex;
    final nextActivePaneId = nextPanes[nextActiveIndex].paneId;

    if (schemaVersion == workspaceNestedSplitLayoutSchemaVersion) {
      final nextTree = _removePaneFromTree(splitTree!, paneId)!;
      if (nextTree is WorkspaceSplitNode) {
        return WorkspaceRecord.fromSplitTree(
          id: id,
          name: name,
          layoutTree: nextTree,
          activePaneId: nextActivePaneId,
          revisionId: revisionId,
          manifest: manifest,
        );
      }
      final terminal = nextTree as WorkspaceTerminalNode;
      return WorkspaceRecord.fromHostIds(
        id: id,
        name: name,
        hostIds: [terminal.hostId],
        paneIds: [terminal.paneId],
        revisionId: revisionId,
        manifest: manifest,
      );
    }
    return copyWith(
      hostIds: nextPanes.map((pane) => pane.hostId).toList(),
      activeIndex: nextActiveIndex,
    );
  }

  /// Serializes with stable key and pane order, retaining v1 for tab layouts.
  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'id': id,
    'type': 'workspace',
    'name': name,
    'layout_tree': switch (schemaVersion) {
      workspaceNestedSplitLayoutSchemaVersion => _splitTreeToJson(
        splitTree!,
        root: true,
        activePaneId: activePaneId,
      ),
      workspaceSplitLayoutSchemaVersion => {
        'kind': 'split',
        'axis': _splitAxisWireValue(splitAxis!),
        'split_ratio_basis_points': splitRatioBasisPoints,
        'active_pane_id': activePaneId,
        'panes': panes.map((pane) => pane.toJson()).toList(growable: false),
      },
      _ => {
        'kind': 'terminal_tabs',
        'active_pane_id': activePaneId,
        'panes': panes.map((pane) => pane.toJson()).toList(growable: false),
      },
    },
    'host_refs': hostRefs,
    if (manifest != null) '_manifest': manifest,
  };
}

({WorkspaceSplitNode layoutTree, String activePaneId}) _treeWithFreshPaneIds(
  WorkspaceSplitNode source,
  String sourceActivePaneId,
) {
  String? nextActivePaneId;
  WorkspaceLayoutNode clone(WorkspaceLayoutNode node) => switch (node) {
    WorkspaceTerminalNode(:final paneId, :final hostId) => () {
      final nextPaneId = const Uuid().v4();
      if (paneId == sourceActivePaneId) nextActivePaneId = nextPaneId;
      return WorkspaceTerminalNode(paneId: nextPaneId, hostId: hostId);
    }(),
    WorkspaceSplitNode(
      :final axis,
      :final splitRatioBasisPoints,
      :final first,
      :final second,
    ) =>
      WorkspaceSplitNode(
        axis: axis,
        splitRatioBasisPoints: splitRatioBasisPoints,
        first: clone(first),
        second: clone(second),
      ),
  };
  final layoutTree = clone(source) as WorkspaceSplitNode;
  final activePaneId = nextActivePaneId;
  if (activePaneId == null) {
    throw StateError('The active Workspace pane is absent from its layout.');
  }
  return (layoutTree: layoutTree, activePaneId: activePaneId);
}

List<WorkspacePane> _panesFromHostIds(
  List<String> hostIds, {
  List<String>? paneIds,
}) {
  if (hostIds.isEmpty || hostIds.length > maxWorkspacePanes) {
    throw const FormatException(
      'Workspace must contain between 1 and 8 terminal panes',
    );
  }
  if (paneIds != null && paneIds.length != hostIds.length) {
    throw const FormatException('paneIds must match the number of Host IDs');
  }
  final usedPaneIds = <String>{};
  return List<WorkspacePane>.generate(hostIds.length, (index) {
    final hostId = hostIds[index];
    _validateUuidV4(hostId, 'host_id');
    final paneId = paneIds == null ? const Uuid().v4() : paneIds[index];
    _validateUuidV4(paneId, 'pane_id');
    if (!usedPaneIds.add(paneId)) {
      throw const FormatException('Workspace pane IDs must be unique');
    }
    return WorkspacePane._(paneId: paneId, hostId: hostId);
  }, growable: false);
}

List<WorkspacePane> _decodeTerminalPanes(Object? rawPanes) {
  if (rawPanes is! List ||
      rawPanes.isEmpty ||
      rawPanes.length > maxWorkspacePanes) {
    throw const FormatException(
      'Workspace must contain between 1 and 8 terminal panes',
    );
  }
  final panes = <WorkspacePane>[];
  final paneIds = <String>{};
  for (final (index, rawPane) in rawPanes.indexed) {
    final pane = _requiredStringMap(rawPane, 'panes[$index]');
    _requireExactKeys(pane, const {'kind', 'pane_id', 'host_id'}, 'pane');
    if (pane['kind'] != 'terminal') {
      throw FormatException('panes[$index].kind must be terminal');
    }
    final paneId = _requiredString(pane['pane_id'], 'pane_id');
    _validateUuidV4(paneId, 'pane_id');
    if (!paneIds.add(paneId)) {
      throw const FormatException('Workspace pane IDs must be unique');
    }
    final hostId = _requiredString(pane['host_id'], 'host_id');
    _validateUuidV4(hostId, 'host_id');
    panes.add(WorkspacePane._(paneId: paneId, hostId: hostId));
  }
  return panes;
}

WorkspaceSplitNode _decodeSplitNode(
  Map<String, dynamic> value, {
  required bool isRoot,
  required int splitDepth,
  required Set<String> paneIds,
}) {
  if (splitDepth > maxWorkspaceSplitDepth) {
    throw const FormatException('Workspace split tree is too deep');
  }
  _requireExactKeys(
    value,
    isRoot
        ? const {
            'kind',
            'axis',
            'split_ratio_basis_points',
            'active_pane_id',
            'panes',
          }
        : const {'kind', 'axis', 'split_ratio_basis_points', 'panes'},
    isRoot ? 'layout_tree' : 'split node',
  );
  if (value['kind'] != 'split') {
    throw const FormatException('Workspace split node kind is unsupported');
  }
  final rawPanes = value['panes'];
  if (rawPanes is! List || rawPanes.length != 2) {
    throw const FormatException(
      'A Workspace split node must have two children',
    );
  }
  final children = <WorkspaceLayoutNode>[];
  for (final (index, rawChild) in rawPanes.indexed) {
    final child = _requiredStringMap(rawChild, 'panes[$index]');
    switch (child['kind']) {
      case 'terminal':
        _requireExactKeys(child, const {
          'kind',
          'pane_id',
          'host_id',
        }, 'terminal pane');
        final paneId = _requiredString(child['pane_id'], 'pane_id');
        final hostId = _requiredString(child['host_id'], 'host_id');
        _validateUuidV4(paneId, 'pane_id');
        _validateUuidV4(hostId, 'host_id');
        if (!paneIds.add(paneId)) {
          throw const FormatException('Workspace pane IDs must be unique');
        }
        if (paneIds.length > maxWorkspacePanes) {
          throw const FormatException(
            'Workspace split tree has more than eight terminal panes',
          );
        }
        children.add(WorkspaceTerminalNode(paneId: paneId, hostId: hostId));
      case 'split':
        children.add(
          _decodeSplitNode(
            child,
            isRoot: false,
            splitDepth: splitDepth + 1,
            paneIds: paneIds,
          ),
        );
      default:
        throw const FormatException(
          'Workspace layout node kind is unsupported',
        );
    }
  }
  return WorkspaceSplitNode(
    axis: _decodeSplitAxis(value['axis']),
    splitRatioBasisPoints: _decodeSplitRatio(value['split_ratio_basis_points']),
    first: children[0],
    second: children[1],
  );
}

WorkspaceSplitAxis _decodeSplitAxis(Object? value) => switch (value) {
  'horizontal' => WorkspaceSplitAxis.horizontal,
  'vertical' => WorkspaceSplitAxis.vertical,
  _ => throw const FormatException('Workspace split axis is unsupported'),
};

int _decodeSplitRatio(Object? value) {
  if (value is! int) {
    throw const FormatException('split_ratio_basis_points must be an integer');
  }
  _validateSplitRatio(value);
  return value;
}

List<WorkspacePane> _panesFromTree(WorkspaceLayoutNode root) {
  final panes = <WorkspacePane>[];
  final paneIds = <String>{};
  void visit(WorkspaceLayoutNode node, int splitDepth) {
    switch (node) {
      case WorkspaceTerminalNode(:final paneId, :final hostId):
        _validateUuidV4(paneId, 'pane_id');
        _validateUuidV4(hostId, 'host_id');
        if (!paneIds.add(paneId)) {
          throw const FormatException('Workspace pane IDs must be unique');
        }
        if (paneIds.length > maxWorkspacePanes) {
          throw const FormatException(
            'Workspace split tree has more than eight terminal panes',
          );
        }
        panes.add(WorkspacePane._(paneId: paneId, hostId: hostId));
      case WorkspaceSplitNode(
        :final axis,
        :final splitRatioBasisPoints,
        :final first,
        :final second,
      ):
        if (splitDepth > maxWorkspaceSplitDepth) {
          throw const FormatException('Workspace split tree is too deep');
        }
        _validateSplitRatio(splitRatioBasisPoints);
        // Reading axis here also makes it explicit that only the two enum
        // values can enter through the public model.
        _splitAxisWireValue(axis);
        visit(first, splitDepth + 1);
        visit(second, splitDepth + 1);
    }
  }

  visit(root, 1);
  return panes;
}

WorkspaceSplitNode _treeWithHosts(
  WorkspaceSplitNode root,
  List<WorkspacePane> panes,
) {
  var index = 0;
  WorkspaceLayoutNode replace(WorkspaceLayoutNode node) => switch (node) {
    WorkspaceTerminalNode(:final paneId) => () {
      final pane = panes[index++];
      return WorkspaceTerminalNode(paneId: paneId, hostId: pane.hostId);
    }(),
    WorkspaceSplitNode(
      :final axis,
      :final splitRatioBasisPoints,
      :final first,
      :final second,
    ) =>
      WorkspaceSplitNode(
        axis: axis,
        splitRatioBasisPoints: splitRatioBasisPoints,
        first: replace(first),
        second: replace(second),
      ),
  };
  return replace(root) as WorkspaceSplitNode;
}

WorkspaceLayoutNode? _removePaneFromTree(
  WorkspaceLayoutNode node,
  String paneId,
) => switch (node) {
  WorkspaceTerminalNode(paneId: final leafId) => leafId == paneId ? null : node,
  WorkspaceSplitNode(
    :final axis,
    :final splitRatioBasisPoints,
    :final first,
    :final second,
  ) =>
    () {
      final nextFirst = _removePaneFromTree(first, paneId);
      final nextSecond = _removePaneFromTree(second, paneId);
      if (nextFirst == null) return nextSecond;
      if (nextSecond == null) return nextFirst;
      if (identical(nextFirst, first) && identical(nextSecond, second)) {
        return node;
      }
      return WorkspaceSplitNode(
        axis: axis,
        splitRatioBasisPoints: splitRatioBasisPoints,
        first: nextFirst,
        second: nextSecond,
      );
    }(),
};

Map<String, Object?> _splitTreeToJson(
  WorkspaceLayoutNode node, {
  required bool root,
  String? activePaneId,
}) => switch (node) {
  WorkspaceTerminalNode(:final paneId, :final hostId) => {
    'kind': 'terminal',
    'pane_id': paneId,
    'host_id': hostId,
  },
  WorkspaceSplitNode(
    :final axis,
    :final splitRatioBasisPoints,
    :final first,
    :final second,
  ) =>
    {
      'kind': 'split',
      'axis': _splitAxisWireValue(axis),
      'split_ratio_basis_points': splitRatioBasisPoints,
      if (root) 'active_pane_id': activePaneId,
      'panes': [
        _splitTreeToJson(first, root: false),
        _splitTreeToJson(second, root: false),
      ],
    },
};

void _validateSplitRatio(int ratio) {
  if (ratio < minWorkspaceSplitRatioBasisPoints ||
      ratio > maxWorkspaceSplitRatioBasisPoints) {
    throw const FormatException(
      'split_ratio_basis_points must be between 2500 and 7500',
    );
  }
}

String _splitAxisWireValue(WorkspaceSplitAxis axis) => switch (axis) {
  WorkspaceSplitAxis.horizontal => 'horizontal',
  WorkspaceSplitAxis.vertical => 'vertical',
};

String _requiredString(Object? value, String field) {
  if (value is! String || value.isEmpty) {
    throw FormatException('$field must be a non-empty string');
  }
  return value;
}

Map<String, dynamic> _requiredStringMap(Object? value, String field) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw FormatException('$field must be an object with string keys');
  }
  return Map<String, dynamic>.from(value);
}

void _requireExactKeys(
  Map<String, dynamic> value,
  Set<String> keys,
  String field,
) {
  if (value.keys.toSet().length != keys.length ||
      !value.keys.toSet().containsAll(keys)) {
    throw FormatException('$field has missing or unknown fields');
  }
}

void _validateUuidV4(String value, String field) {
  if (!_workspaceUuidV4.hasMatch(value)) {
    throw FormatException('$field must be a lowercase UUIDv4');
  }
}

void _validateName(String value) {
  if (value.isEmpty ||
      utf8.encode(value).length > maxWorkspaceNameUtf8Bytes ||
      _workspaceNameControlCharacters.hasMatch(value)) {
    throw const FormatException(
      'Workspace name must be 1–256 UTF-8 bytes without control characters',
    );
  }
}

Map<String, Object?>? _validatedManifest(Object? raw) {
  if (raw == null) return null;
  if (raw is! Map || raw.keys.any((key) => key is! String)) {
    throw const FormatException(
      'Record _manifest must be an object with string keys',
    );
  }
  final copied = _copyJsonValue(raw, depth: 0, field: '_manifest');
  if (copied is! Map<String, Object?>) {
    throw const FormatException('Record _manifest must be a JSON object');
  }
  return copied;
}

typedef _WorkspaceSessionState = ({
  Map<String, Object?>? manifest,
  List<WorkspaceSessionDescriptor> descriptors,
});

_WorkspaceSessionState _workspaceSessionState(
  Object? rawManifest,
  List<WorkspaceSessionDescriptor>? requestedDescriptors,
  List<WorkspacePane> panes,
) {
  final baseManifest = _validatedManifest(rawManifest);
  final descriptors = requestedDescriptors == null
      ? _decodeWorkspaceSessionDescriptors(baseManifest, panes)
      : _validateRequestedSessionDescriptors(requestedDescriptors, panes);
  final manifest = baseManifest == null
      ? <String, Object?>{}
      : Map<String, Object?>.from(baseManifest);
  final hadDescriptorNamespace = manifest.containsKey(
    workspaceSessionDescriptorsManifestKey,
  );
  if (descriptors.isEmpty) {
    manifest.remove(workspaceSessionDescriptorsManifestKey);
  } else {
    manifest[workspaceSessionDescriptorsManifestKey] = descriptors
        .map((descriptor) => descriptor.toJson())
        .toList(growable: false);
  }
  if (manifest.isEmpty && (baseManifest == null || hadDescriptorNamespace)) {
    return (manifest: null, descriptors: List.unmodifiable(descriptors));
  }
  return (
    manifest: _validatedManifest(manifest),
    descriptors: List.unmodifiable(descriptors),
  );
}

List<WorkspaceSessionDescriptor> _decodeWorkspaceSessionDescriptors(
  Map<String, Object?>? manifest,
  List<WorkspacePane> panes,
) {
  if (manifest == null ||
      !manifest.containsKey(workspaceSessionDescriptorsManifestKey)) {
    return const [];
  }
  final rawDescriptors = manifest[workspaceSessionDescriptorsManifestKey];
  if (rawDescriptors is! List || rawDescriptors.length > maxWorkspacePanes) {
    throw const FormatException(
      'Workspace session descriptors must be a bounded list',
    );
  }
  final paneById = {for (final pane in panes) pane.paneId: pane};
  final seenPaneIds = <String>{};
  final seenHostSessions = <String>{};
  final valid = <String, WorkspaceSessionDescriptor>{};
  for (final (index, rawDescriptor) in rawDescriptors.indexed) {
    final value = _requiredStringMap(
      rawDescriptor,
      'session_descriptors[$index]',
    );
    _requireExactKeys(value, const {
      'pane_id',
      'host_id',
      'tmux_session_name',
    }, 'session descriptor');
    final descriptor = WorkspaceSessionDescriptor(
      paneId: _requiredString(value['pane_id'], 'pane_id'),
      hostId: _requiredString(value['host_id'], 'host_id'),
      tmuxSessionName: _requiredString(
        value['tmux_session_name'],
        'tmux_session_name',
      ),
    );
    if (!seenPaneIds.add(descriptor.paneId)) {
      throw const FormatException(
        'Workspace session descriptors must have unique pane IDs',
      );
    }
    final hostSessionKey =
        '${descriptor.hostId}\u0000${descriptor.tmuxSessionName}';
    if (!seenHostSessions.add(hostSessionKey)) {
      throw const FormatException(
        'A tmux session can be referenced by only one pane per Workspace',
      );
    }
    final pane = paneById[descriptor.paneId];
    if (pane != null && pane.hostId == descriptor.hostId) {
      valid[descriptor.paneId] = descriptor;
    }
    // Old clients can change a pane's Host or remove it while preserving the
    // encrypted manifest. Such references are stale intent and are dropped.
  }
  return List<WorkspaceSessionDescriptor>.unmodifiable([
    for (final pane in panes)
      if (valid[pane.paneId] case final descriptor?) descriptor,
  ]);
}

List<WorkspaceSessionDescriptor> _validateRequestedSessionDescriptors(
  List<WorkspaceSessionDescriptor> descriptors,
  List<WorkspacePane> panes,
) {
  if (descriptors.length > maxWorkspacePanes) {
    throw const FormatException('Too many Workspace session descriptors');
  }
  final paneById = {for (final pane in panes) pane.paneId: pane};
  final byPaneId = <String, WorkspaceSessionDescriptor>{};
  final seenHostSessions = <String>{};
  for (final descriptor in descriptors) {
    final pane = paneById[descriptor.paneId];
    if (pane == null || pane.hostId != descriptor.hostId) {
      throw const FormatException(
        'A session descriptor must match an existing pane and Host',
      );
    }
    if (byPaneId.containsKey(descriptor.paneId)) {
      throw const FormatException(
        'Workspace session descriptors must have unique pane IDs',
      );
    }
    final hostSessionKey =
        '${descriptor.hostId}\u0000${descriptor.tmuxSessionName}';
    if (!seenHostSessions.add(hostSessionKey)) {
      throw const FormatException(
        'A tmux session can be referenced by only one pane per Workspace',
      );
    }
    byPaneId[descriptor.paneId] = descriptor;
  }
  return List<WorkspaceSessionDescriptor>.unmodifiable([
    for (final pane in panes)
      if (byPaneId[pane.paneId] case final descriptor?) descriptor,
  ]);
}

Map<String, Object?>? _manifestWithoutSessionDescriptors(
  Map<String, Object?>? rawManifest,
) {
  final manifest = _validatedManifest(rawManifest);
  if (manifest == null ||
      !manifest.containsKey(workspaceSessionDescriptorsManifestKey)) {
    return manifest;
  }
  final copy = Map<String, Object?>.from(manifest)
    ..remove(workspaceSessionDescriptorsManifestKey);
  return copy.isEmpty ? null : Map<String, Object?>.unmodifiable(copy);
}

void _validateTmuxSessionName(String value) {
  if (value.length > maxTmuxSessionNameCharacters ||
      !_tmuxSessionNamePattern.hasMatch(value)) {
    throw const FormatException(
      'tmux session names must use the application-owned UUID format',
    );
  }
}

Object? _copyJsonValue(
  Object? value, {
  required int depth,
  required String field,
}) {
  if (depth > 32) {
    throw FormatException('$field exceeds the maximum nesting depth');
  }
  if (value == null || value is String || value is bool || value is int) {
    return value;
  }
  if (value is double) {
    if (!value.isFinite)
      throw FormatException('$field contains a non-finite number');
    return value;
  }
  if (value is List) {
    return List<Object?>.unmodifiable(
      value.map((item) => _copyJsonValue(item, depth: depth + 1, field: field)),
    );
  }
  if (value is Map) {
    if (value.keys.any((key) => key is! String)) {
      throw FormatException('$field object keys must be strings');
    }
    return Map<String, Object?>.unmodifiable({
      for (final entry in value.entries)
        entry.key as String: _copyJsonValue(
          entry.value,
          depth: depth + 1,
          field: field,
        ),
    });
  }
  throw FormatException('$field must contain only JSON values');
}

bool _sameStrings(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
