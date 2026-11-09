// Selected-Host sharing: what has to be copied into a dedicated sharing
// Vault so that exactly the selected Hosts (and the dependencies the owner
// explicitly approves) become visible to recipients — never the rest of the
// source Vault.
import '../domain/known_host.dart';
import '../domain/models.dart';

enum HostShareDependencyKind { jumpHost, credential, knownHost, group }

class HostShareDependency {
  const HostShareDependency({
    required this.kind,
    required this.id,
    required this.label,
    required this.requiredBy,
  });
  final HostShareDependencyKind kind;
  final String id;
  final String label;
  final String requiredBy;
}

enum HostShareBlockerKind { missingJumpHost, missingCredential, jumpLoop }

class HostShareBlocker {
  const HostShareBlocker(this.kind, this.hostName);
  final HostShareBlockerKind kind;
  final String hostName;
}

class HostSharePlan {
  const HostSharePlan({
    required this.selected,
    required this.jumpHosts,
    required this.credentials,
    required this.knownHosts,
    required this.droppedGroups,
    required this.blockers,
    this.sourceVaultId,
  });

  /// The Vault the plan was computed from (null in pure unit use).
  final String? sourceVaultId;
  final List<HostRecord> selected;

  /// Extra Hosts copied only because a selected Host jumps through them.
  final List<HostRecord> jumpHosts;
  final List<CredentialRecord> credentials;
  final List<KnownHostRecord> knownHosts;

  /// Groups are not copied; the copies are ungrouped in the sharing Vault.
  final List<String> droppedGroups;
  final List<HostShareBlocker> blockers;

  bool get canProceed => blockers.isEmpty && selected.isNotEmpty;

  /// Everything the owner must consent to before the copy happens.
  List<HostShareDependency> get dependencies => [
    for (final host in jumpHosts)
      HostShareDependency(
        kind: HostShareDependencyKind.jumpHost,
        id: host.id,
        label: host.name,
        requiredBy: _requiredBy(host.id, (h) => h.jumpHostId),
      ),
    for (final credential in credentials)
      HostShareDependency(
        kind: HostShareDependencyKind.credential,
        id: credential.id,
        label: credential.name,
        requiredBy: _requiredBy(credential.id, (h) => h.credentialId),
      ),
    for (final known in knownHosts)
      HostShareDependency(
        kind: HostShareDependencyKind.knownHost,
        id: known.id,
        label: '${known.host}:${known.port} ${known.algorithm}',
        requiredBy: known.host,
      ),
    for (final group in droppedGroups)
      HostShareDependency(
        kind: HostShareDependencyKind.group,
        id: group,
        label: group,
        requiredBy: '',
      ),
  ];

  String _requiredBy(String id, String? Function(HostRecord) ref) => [
    ...selected,
    ...jumpHosts,
  ].where((h) => ref(h) == id).map((h) => h.name).join(', ');

  /// Hosts in copy order (jump hosts first so references resolve).
  List<HostRecord> get copyOrder => [...jumpHosts.reversed, ...selected];
}

/// Resolves every reference of the selected Hosts inside the source Vault.
/// Unresolvable references block the share instead of leaving dangling
/// cross-Vault references.
HostSharePlan planHostShare({
  required List<HostRecord> selected,
  required List<HostRecord> vaultHosts,
  required List<CredentialRecord> vaultCredentials,
  required List<KnownHostRecord> vaultKnownHosts,
  required List<GroupRecord> vaultGroups,
  String? sourceVaultId,
}) {
  final byId = {for (final host in vaultHosts) host.id: host};
  final selectedIds = selected.map((h) => h.id).toSet();
  final jumpHosts = <HostRecord>[];
  final jumpIds = <String>{};
  final blockers = <HostShareBlocker>[];
  for (final host in selected) {
    var current = host;
    final seen = <String>{host.id};
    while (current.jumpHostId != null) {
      final next = byId[current.jumpHostId];
      if (next == null) {
        blockers.add(
          HostShareBlocker(HostShareBlockerKind.missingJumpHost, current.name),
        );
        break;
      }
      if (!seen.add(next.id)) {
        blockers.add(
          HostShareBlocker(HostShareBlockerKind.jumpLoop, host.name),
        );
        break;
      }
      if (!selectedIds.contains(next.id) && jumpIds.add(next.id)) {
        jumpHosts.add(next);
      }
      current = next;
    }
  }
  final all = [...selected, ...jumpHosts];
  final credentialsById = {for (final c in vaultCredentials) c.id: c};
  final credentials = <CredentialRecord>[];
  for (final host in all) {
    final id = host.credentialId;
    if (id == null) continue;
    final credential = credentialsById[id];
    if (credential == null) {
      blockers.add(
        HostShareBlocker(HostShareBlockerKind.missingCredential, host.name),
      );
    } else if (!credentials.any((c) => c.id == id)) {
      credentials.add(credential);
    }
  }
  final knownHosts = <KnownHostRecord>[
    for (final known in vaultKnownHosts)
      if (known.state == KnownHostState.trusted &&
          all.any(
            (h) =>
                h.protocol == HostProtocol.ssh &&
                h.address == known.host &&
                h.port == known.port,
          ))
        known,
  ];
  final groupsById = {for (final g in vaultGroups) g.id: g.name};
  final droppedGroups = <String>{
    for (final host in all)
      if (host.groupId != null) groupsById[host.groupId] ?? host.groupId!,
  }.toList();
  return HostSharePlan(
    selected: List.unmodifiable(selected),
    jumpHosts: List.unmodifiable(jumpHosts),
    credentials: List.unmodifiable(credentials),
    knownHosts: List.unmodifiable(knownHosts),
    droppedGroups: droppedGroups,
    blockers: List.unmodifiable(blockers),
    sourceVaultId: sourceVaultId,
  );
}

/// Produces re-identified copies with references remapped inside the
/// sharing Vault. Groups are dropped; inline Host logins stay with the Host.
({List<HostRecord> hosts, List<CredentialRecord> credentials})
remapForSharingVault(HostSharePlan plan, String Function() newId) {
  final hostIds = {for (final host in plan.copyOrder) host.id: newId()};
  final credentialIds = {for (final c in plan.credentials) c.id: newId()};
  final credentials = [
    for (final c in plan.credentials)
      CredentialRecord.fromJson({...c.toJson(), 'id': credentialIds[c.id]}),
  ];
  final hosts = [
    for (final host in plan.copyOrder)
      HostRecord.fromJson({
        ...host.toJson(),
        'id': hostIds[host.id],
        'group_id': null,
        'jump_host_id': host.jumpHostId == null
            ? null
            : hostIds[host.jumpHostId],
        'credential_id': host.credentialId == null
            ? null
            : credentialIds[host.credentialId],
        'is_favorite': false,
      }),
  ];
  return (hosts: hosts, credentials: credentials);
}
