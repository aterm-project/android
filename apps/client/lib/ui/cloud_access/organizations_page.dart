// Organization management and joining. Organization data is visible to the
// server; joining never grants Vault keys by itself.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../cloud/cloud_access_crypto.dart';
import '../../cloud/cloud_access_service.dart';
import '../../cloud/pending_cloud_link.dart';
import '../../l10n/l10n.dart';
import '../app_theme.dart';
import 'cloud_access_common.dart';

/// Extracts a join token from a pasted `…/join#o1.<token>` link or raw token.
String? parseOrgJoinToken(String input) {
  final text = input.trim();
  final hash = text.indexOf('#$orgJoinFragmentPrefix');
  final token = hash >= 0
      ? text.substring(hash + 1 + orgJoinFragmentPrefix.length)
      : text.startsWith(orgJoinFragmentPrefix)
      ? text.substring(orgJoinFragmentPrefix.length)
      : text;
  return RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(token) ? token : null;
}

class OrganizationsPage extends StatefulWidget {
  const OrganizationsPage({
    required this.service,
    this.initialJoinToken,
    super.key,
  });
  final CloudAccessService service;
  final String? initialJoinToken;

  @override
  State<OrganizationsPage> createState() => _OrganizationsPageState();
}

class _OrganizationsPageState extends State<OrganizationsPage> {
  List<Map<String, dynamic>> orgs = const [];
  bool canCreate = false;
  String? error;
  String? notice;
  final join = TextEditingController();
  Map<String, dynamic>? inspected;

  CloudAccessService get service => widget.service;

  @override
  void initState() {
    super.initState();
    final pending = widget.initialJoinToken ?? PendingCloudLink.takeJoinToken();
    if (pending != null) {
      join.text = '$orgJoinFragmentPrefix$pending';
      unawaited(_inspect());
    }
    unawaited(_load());
  }

  @override
  void dispose() {
    join.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final response = await service.api.orgs();
      if (mounted) {
        setState(() {
          orgs = (response['organizations'] as List)
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
          canCreate = response['can_create'] == true;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = cloudAccessErrorText(context, e));
    }
  }

  Future<void> _inspect() async {
    final token = parseOrgJoinToken(join.text);
    if (token == null) {
      setState(() => error = context.l10n.cloudAccessJoinInvalid);
      return;
    }
    try {
      final value = await service.api.inspectInvitation(token);
      if (mounted)
        setState(() {
          inspected = value;
          error = null;
        });
    } catch (e) {
      if (mounted) setState(() => error = cloudAccessErrorText(context, e));
    }
  }

  Future<void> _accept() async {
    final token = parseOrgJoinToken(join.text);
    if (token == null) return;
    try {
      await service.api.acceptInvitation(token);
      // Make this device addressable for owner-confirmed key delivery.
      await service.publishDeviceCard();
      join.clear();
      if (mounted)
        setState(() {
          inspected = null;
          notice = context.l10n.cloudAccessJoined;
        });
      await _load();
    } catch (e) {
      if (mounted) setState(() => error = cloudAccessErrorText(context, e));
    }
  }

  Future<void> _create() async {
    final name = await _askText(
      context,
      context.l10n.cloudAccessNewOrganization,
      context.l10n.cloudAccessOrganizationName,
    );
    if (name == null || name.isEmpty) return;
    try {
      await service.api.createOrg(name);
      await _load();
    } catch (e) {
      if (mounted) setState(() => error = cloudAccessErrorText(context, e));
    }
  }

  Future<void> _checkDeliveries() async {
    try {
      await service.publishDeviceCard();
      final count = await service.acceptDeliveries();
      if (mounted)
        setState(
          () => notice = context.l10n.cloudAccessDeliveriesAccepted(count),
        );
    } catch (e) {
      if (mounted) setState(() => error = cloudAccessErrorText(context, e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.cloudAccessOrganizations)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            l10n.cloudAccessOrganizationsExplainer,
            style: TextStyle(color: context.palette.muted, fontSize: 12.5),
          ),
          if (notice != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                notice!,
                style: TextStyle(color: context.palette.accent),
              ),
            ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(error!, style: TextStyle(color: context.palette.red)),
            ),
          CloudAccessSection(
            title: l10n.cloudAccessJoinOrganization,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: join,
                      decoration: InputDecoration(
                        labelText: l10n.cloudAccessJoinLinkField,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: _inspect,
                    child: Text(l10n.cloudAccessReview),
                  ),
                ],
              ),
              if (inspected != null)
                Card(
                  margin: const EdgeInsets.only(top: 8),
                  child: ListTile(
                    title: Text('${inspected!['name']}'),
                    subtitle: Text(
                      l10n.cloudAccessJoinSummary(
                        '${inspected!['invited_by']}',
                        _orgRole(context, '${inspected!['role']}'),
                      ),
                    ),
                    trailing: FilledButton(
                      onPressed: _accept,
                      child: Text(l10n.cloudAccessJoin),
                    ),
                  ),
                ),
            ],
          ),
          CloudAccessSection(
            title: l10n.cloudAccessSharedVaultKeys,
            children: [
              Text(
                l10n.cloudAccessSharedVaultKeysHelp,
                style: const TextStyle(fontSize: 12.5),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: _checkDeliveries,
                  icon: const Icon(Icons.key_outlined, size: 18),
                  label: Text(l10n.cloudAccessCheckDeliveries),
                ),
              ),
            ],
          ),
          CloudAccessSection(
            title: l10n.cloudAccessYourOrganizations,
            trailing: canCreate
                ? FilledButton.icon(
                    onPressed: _create,
                    icon: const Icon(Icons.add, size: 18),
                    label: Text(l10n.cloudAccessNewOrganization),
                  )
                : null,
            children: [
              if (orgs.isEmpty)
                Text(
                  l10n.cloudAccessNoOrganizations,
                  style: TextStyle(color: context.palette.muted),
                ),
              for (final org in orgs)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.apartment_outlined),
                    title: Text('${org['name']}'),
                    subtitle: Text(
                      '${_orgRole(context, '${org['role']}')} · ${l10n.cloudAccessMemberCount('${org['member_count']}')}',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => OrganizationDetailPage(
                            service: service,
                            orgId: org['org_id'] as String,
                          ),
                        ),
                      );
                      await _load();
                    },
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

String _orgRole(BuildContext context, String role) => switch (role) {
  'owner' => context.l10n.cloudAccessOrgRoleOwner,
  'admin' => context.l10n.cloudAccessOrgRoleAdmin,
  _ => context.l10n.cloudAccessOrgRoleMember,
};

Future<String?> _askText(BuildContext context, String title, String label) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: InputDecoration(labelText: label),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.l10n.cloudAccessCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text.trim()),
          child: Text(context.l10n.cloudAccessSave),
        ),
      ],
    ),
  ).whenComplete(controller.dispose);
}

class OrganizationDetailPage extends StatefulWidget {
  const OrganizationDetailPage({
    required this.service,
    required this.orgId,
    super.key,
  });
  final CloudAccessService service;
  final String orgId;

  @override
  State<OrganizationDetailPage> createState() => _OrganizationDetailPageState();
}

class _OrganizationDetailPageState extends State<OrganizationDetailPage> {
  Map<String, dynamic>? org;
  List<Map<String, dynamic>> invitations = const [];
  String? error;
  String? joinLink;

  CloudAccessService get service => widget.service;
  bool get manager => org?['role'] == 'owner' || org?['role'] == 'admin';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final detail = await service.api.org(widget.orgId);
      var invites = const <Map<String, dynamic>>[];
      if (detail['role'] == 'owner' || detail['role'] == 'admin') {
        invites =
            ((await service.api.invitations(widget.orgId))['invitations']
                    as List)
                .map((e) => Map<String, dynamic>.from(e as Map))
                .toList();
      }
      if (mounted)
        setState(() {
          org = detail;
          invitations = invites;
          error = null;
        });
    } catch (e) {
      if (mounted) setState(() => error = cloudAccessErrorText(context, e));
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
      await _load();
    } catch (e) {
      if (mounted) setState(() => error = cloudAccessErrorText(context, e));
    }
  }

  Future<void> _invite() async {
    final l10n = context.l10n;
    final username = TextEditingController();
    var role = 'member';
    String? teamId;
    final teams = (org?['teams'] as List? ?? const []).cast<Map>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: Text(l10n.cloudAccessInviteMember),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: username,
                decoration: InputDecoration(
                  labelText: l10n.cloudAccessInviteUsername,
                  helperText: l10n.cloudAccessInviteUsernameHelp,
                ),
              ),
              DropdownButtonFormField<String>(
                initialValue: role,
                decoration: InputDecoration(labelText: l10n.cloudAccessRole),
                items: [
                  DropdownMenuItem(
                    value: 'member',
                    child: Text(l10n.cloudAccessOrgRoleMember),
                  ),
                  DropdownMenuItem(
                    value: 'admin',
                    child: Text(l10n.cloudAccessOrgRoleAdmin),
                  ),
                ],
                onChanged: (value) => setDialog(() => role = value ?? 'member'),
              ),
              if (teams.isNotEmpty)
                DropdownButtonFormField<String?>(
                  initialValue: teamId,
                  decoration: InputDecoration(
                    labelText: l10n.cloudAccessInitialTeam,
                  ),
                  items: [
                    DropdownMenuItem<String?>(
                      value: null,
                      child: Text(l10n.cloudAccessNoTeam),
                    ),
                    for (final team in teams)
                      DropdownMenuItem<String?>(
                        value: team['team_id'] as String,
                        child: Text('${team['name']}'),
                      ),
                  ],
                  onChanged: (value) => setDialog(() => teamId = value),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.cloudAccessCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.cloudAccessCreateInvitation),
            ),
          ],
        ),
      ),
    );
    final name = username.text.trim();
    username.dispose();
    if (ok != true) return;
    await _run(() async {
      final created = await service.api.createInvitation(
        widget.orgId,
        role: role,
        username: name.isEmpty ? null : name,
        teamId: teamId,
      );
      final origin = Uri.parse(service.app.api!.baseUrl);
      final base = Uri(
        scheme: origin.scheme,
        host: origin.host,
        port: origin.hasPort ? origin.port : null,
      ).toString();
      setState(
        () => joinLink = '$base/join#$orgJoinFragmentPrefix${created['token']}',
      );
    });
  }

  Future<void> _editTeam(Map team) async {
    final members = (org?['members'] as List).cast<Map>();
    final selected = Set<String>.from(
      (team['member_user_ids'] as List).cast<String>(),
    );
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: Text(context.l10n.cloudAccessTeamMembers('${team['name']}')),
          content: SizedBox(
            width: 360,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final member in members)
                  CheckboxListTile(
                    dense: true,
                    value: selected.contains(member['user_id']),
                    title: Text('${member['username']}'),
                    onChanged: (value) => setDialog(
                      () => value == true
                          ? selected.add(member['user_id'] as String)
                          : selected.remove(member['user_id']),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(context.l10n.cloudAccessCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(context.l10n.cloudAccessSave),
            ),
          ],
        ),
      ),
    );
    if (ok == true) {
      await _run(
        () => service.api.setTeamMembers(
          widget.orgId,
          team['team_id'] as String,
          selected.toList(),
          team['revision'] as int,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final o = org;
    final myId = service.app.account?.accountId;
    return Scaffold(
      appBar: AppBar(
        title: Text(o == null ? l10n.cloudAccessOrganizations : '${o['name']}'),
      ),
      body: o == null
          ? Center(
              child: error == null
                  ? const CircularProgressIndicator()
                  : Text(error!),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (error != null)
                  Text(error!, style: TextStyle(color: context.palette.red)),
                if (joinLink != null)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            l10n.cloudAccessInvitationReady,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 6),
                          FilledButton.icon(
                            onPressed: () => Clipboard.setData(
                              ClipboardData(text: joinLink!),
                            ),
                            icon: const Icon(Icons.copy),
                            label: Text(l10n.cloudAccessCopyInvitation),
                          ),
                          Text(
                            l10n.cloudAccessShownOnce,
                            style: TextStyle(
                              color: context.palette.muted,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                CloudAccessSection(
                  title: l10n.cloudAccessMembers,
                  trailing: manager
                      ? FilledButton.icon(
                          onPressed: _invite,
                          icon: const Icon(Icons.person_add_alt, size: 18),
                          label: Text(l10n.cloudAccessInviteMember),
                        )
                      : null,
                  children: [
                    for (final member in (o['members'] as List).cast<Map>())
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text('${member['username']}'),
                        subtitle: Text(_orgRole(context, '${member['role']}')),
                        trailing: Wrap(
                          spacing: 4,
                          children: [
                            if (manager && member['user_id'] != myId)
                              PopupMenuButton<String>(
                                tooltip: l10n.cloudAccessRole,
                                onSelected: (role) => _run(
                                  () => service.api.setMemberRole(
                                    widget.orgId,
                                    member['user_id'] as String,
                                    role,
                                  ),
                                ),
                                itemBuilder: (context) => [
                                  for (final role in [
                                    'member',
                                    'admin',
                                    if (o['role'] == 'owner') 'owner',
                                  ])
                                    PopupMenuItem(
                                      value: role,
                                      child: Text(_orgRole(context, role)),
                                    ),
                                ],
                              ),
                            if (manager || member['user_id'] == myId)
                              IconButton(
                                tooltip: member['user_id'] == myId
                                    ? l10n.cloudAccessLeave
                                    : l10n.cloudAccessRemove,
                                icon: Icon(
                                  Icons.person_remove_outlined,
                                  size: 18,
                                  color: context.palette.red,
                                ),
                                onPressed: () async {
                                  if (await confirmCloudAction(
                                    context,
                                    title: l10n.cloudAccessRemoveMemberTitle,
                                    message:
                                        l10n.cloudAccessRemoveMemberMessage,
                                    action: l10n.cloudAccessRemove,
                                  )) {
                                    await _run(
                                      () => service.api.removeMember(
                                        widget.orgId,
                                        member['user_id'] as String,
                                      ),
                                    );
                                  }
                                },
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
                CloudAccessSection(
                  title: l10n.cloudAccessTeams,
                  trailing: manager
                      ? TextButton.icon(
                          onPressed: () async {
                            final name = await _askText(
                              context,
                              l10n.cloudAccessNewTeam,
                              l10n.cloudAccessTeamName,
                            );
                            if (name != null && name.isNotEmpty)
                              await _run(
                                () =>
                                    service.api.createTeam(widget.orgId, name),
                              );
                          },
                          icon: const Icon(Icons.add, size: 18),
                          label: Text(l10n.cloudAccessNewTeam),
                        )
                      : null,
                  children: [
                    for (final team in (o['teams'] as List).cast<Map>())
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.groups_outlined, size: 18),
                        title: Text('${team['name']}'),
                        subtitle: Text(
                          l10n.cloudAccessMemberCount(
                            '${(team['member_user_ids'] as List).length}',
                          ),
                        ),
                        onTap: manager ? () => _editTeam(team) : null,
                        trailing: manager
                            ? IconButton(
                                tooltip: l10n.cloudAccessRemove,
                                icon: const Icon(
                                  Icons.delete_outline,
                                  size: 18,
                                ),
                                onPressed: () => _run(
                                  () => service.api.deleteTeam(
                                    widget.orgId,
                                    team['team_id'] as String,
                                  ),
                                ),
                              )
                            : null,
                      ),
                  ],
                ),
                if (manager)
                  CloudAccessSection(
                    title: l10n.cloudAccessInvitations,
                    children: [
                      for (final invite in invitations)
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            '${invite['intended_username'] ?? l10n.cloudAccessAnyAccount} · ${_orgRole(context, '${invite['role']}')}',
                          ),
                          subtitle: Text(
                            '${invite['status']} · ${l10n.cloudAccessValidUntil(cloudAccessShortTime(context, invite['expires_at'] as String?))}',
                          ),
                          trailing: invite['status'] == 'pending'
                              ? TextButton(
                                  onPressed: () => _run(
                                    () => service.api.revokeInvitation(
                                      widget.orgId,
                                      invite['invitation_id'] as String,
                                    ),
                                  ),
                                  child: Text(l10n.cloudAccessRevoke),
                                )
                              : null,
                        ),
                    ],
                  ),
              ],
            ),
    );
  }
}

/// Account-page entry point (narrow hook).
class CloudAccessAccountCard extends StatelessWidget {
  const CloudAccessAccountCard({required this.service, super.key});
  final CloudAccessService service;

  @override
  Widget build(BuildContext context) {
    if (!service.organizationsAvailable && !service.linksAvailable)
      return const SizedBox.shrink();
    final l10n = context.l10n;
    final pendingJoin = PendingCloudLink.hasJoinToken;
    return Card(
      child: ListTile(
        leading: Icon(
          Icons.apartment_outlined,
          color: pendingJoin ? context.palette.accent : null,
        ),
        title: Text(l10n.cloudAccessOrganizations),
        subtitle: Text(
          pendingJoin
              ? l10n.cloudAccessPendingJoin
              : l10n.cloudAccessOrganizationsSubtitle,
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: service.organizationsAvailable
            ? () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => OrganizationsPage(service: service),
                ),
              )
            : null,
      ),
    );
  }
}
