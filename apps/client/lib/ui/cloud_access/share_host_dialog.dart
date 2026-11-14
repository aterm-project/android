// Host "Share…" dialog: Members & teams (dedicated sharing Vault, grants,
// owner-confirmed key delivery) and Temporary links (trusted gateway).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_controller.dart';
import '../../cloud/cloud_access_service.dart';
import '../../cloud/host_share_plan.dart';
import '../../domain/models.dart';
import '../../l10n/l10n.dart';
import '../app_theme.dart';
import '../credential_visibility/credential_visibility_widgets.dart';
import 'cloud_access_common.dart';
import 'organizations_page.dart';

Future<void> showCloudShareDialog(
  BuildContext context, {
  required AppController app,
  required HostRecord host,
}) => showDialog<void>(
  context: context,
  builder: (context) => Dialog(
    insetPadding: const EdgeInsets.all(16),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560, maxHeight: 720),
      child: CloudShareHostPanel(app: app, host: host),
    ),
  ),
);

enum _ShareTab { members, links }

class CloudShareHostPanel extends StatefulWidget {
  const CloudShareHostPanel({required this.app, required this.host, super.key});
  final AppController app;
  final HostRecord host;

  @override
  State<CloudShareHostPanel> createState() => _CloudShareHostPanelState();
}

class _CloudShareHostPanelState extends State<CloudShareHostPanel> {
  late final CloudAccessService service = CloudAccessService(widget.app);
  _ShareTab tab = _ShareTab.links;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.ios_share, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.cloudAccessShareTitle(widget.host.name),
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                tooltip: l10n.cloudAccessClose,
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SegmentedButton<_ShareTab>(
            segments: [
              ButtonSegment(
                value: _ShareTab.members,
                icon: const Icon(Icons.group_outlined, size: 16),
                label: Text(l10n.cloudAccessTabMembers),
              ),
              ButtonSegment(
                value: _ShareTab.links,
                icon: const Icon(Icons.link, size: 16),
                label: Text(l10n.cloudAccessTabLinks),
              ),
            ],
            selected: {tab},
            onSelectionChanged: (value) => setState(() => tab = value.first),
          ),
          const SizedBox(height: 4),
          Flexible(
            child: switch (tab) {
              _ShareTab.links => _LinksTab(service: service, host: widget.host),
              _ShareTab.members => _MembersTab(
                service: service,
                host: widget.host,
              ),
            },
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Temporary links
// ---------------------------------------------------------------------------

class _LinksTab extends StatefulWidget {
  const _LinksTab({required this.service, required this.host});
  final CloudAccessService service;
  final HostRecord host;

  @override
  State<_LinksTab> createState() => _LinksTabState();
}

enum _LinksView { list, create, created, activity }

class _LinksTabState extends State<_LinksTab> {
  _LinksView view = _LinksView.list;
  List<Map<String, dynamic>> links = const [];
  bool loading = true;
  String? error;
  CreatedShareLink? created;
  Map<String, dynamic>? activityFor;

  CloudAccessService get service => widget.service;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    if (!service.linksAvailable ||
        widget.service.app.activeVault?.role != 'owner') {
      setState(() => loading = false);
      return;
    }
    setState(() => loading = true);
    try {
      final vaultId = widget.service.app.activeVault!.id;
      final response = await service.api.links(vaultId);
      final all = (response['links'] as List? ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .where(
            (link) => (link['targets'] as List).any(
              (t) => t['host_record_id'] == widget.host.id,
            ),
          )
          .toList();
      if (mounted)
        setState(() {
          links = all;
          error = null;
        });
    } catch (e) {
      if (mounted) setState(() => error = cloudAccessErrorText(context, e));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(cloudAccessErrorText(context, e))),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final blocker = service.shareBlocker(widget.host);
    return switch (view) {
      _LinksView.create => _LinkEditor(
        service: service,
        host: widget.host,
        onCancel: () => setState(() => view = _LinksView.list),
        onCreated: (value) => setState(() {
          created = value;
          view = _LinksView.created;
        }),
      ),
      _LinksView.created => _CreatedLinkView(
        created: created!,
        onDone: () {
          setState(() {
            created = null;
            view = _LinksView.list;
          });
          unawaited(_load());
        },
      ),
      _LinksView.activity => _ActivityView(
        service: service,
        link: activityFor!,
        onBack: () => setState(() => view = _LinksView.list),
      ),
      _LinksView.list => ListView(
        shrinkWrap: true,
        children: [
          const SizedBox(height: 10),
          const CloudAccessTrustNotice(),
          if (blocker != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                cloudAccessErrorText(context, CloudAccessException(blocker)),
                style: TextStyle(color: context.palette.orange),
              ),
            ),
          CloudAccessSection(
            title: l10n.cloudAccessLinksHeading,
            trailing: FilledButton.icon(
              onPressed: blocker == null
                  ? () => setState(() => view = _LinksView.create)
                  : null,
              icon: const Icon(Icons.add_link, size: 18),
              label: Text(l10n.cloudAccessNewLink),
            ),
            children: [
              if (loading)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: LinearProgressIndicator(),
                ),
              if (error != null)
                Text(error!, style: TextStyle(color: context.palette.red)),
              if (!loading && links.isEmpty && error == null)
                Text(
                  l10n.cloudAccessNoLinks,
                  style: TextStyle(color: context.palette.muted),
                ),
              for (final link in links)
                _LinkTile(
                  link: link,
                  onPause: () => _run(
                    () => service.api.updateLink(
                      link['vault_id'] as String,
                      link['link_id'] as String,
                      {
                        'expected_revision': link['revision'],
                        'state': link['status'] == 'paused'
                            ? 'active'
                            : 'paused',
                      },
                    ),
                  ),
                  onRevoke: () async {
                    if (await confirmCloudAction(
                      context,
                      title: l10n.cloudAccessRevokeLinkTitle,
                      message: l10n.cloudAccessRevokeLinkMessage,
                      action: l10n.cloudAccessRevoke,
                    )) {
                      await _run(
                        () => service.api.revokeLink(
                          link['vault_id'] as String,
                          link['link_id'] as String,
                        ),
                      );
                    }
                  },
                  onRotate: () async {
                    if (!await confirmCloudAction(
                      context,
                      title: l10n.cloudAccessRotateTitle,
                      message: l10n.cloudAccessRotateMessage,
                      action: l10n.cloudAccessRotate,
                    )) {
                      return;
                    }
                    try {
                      final labels = {
                        'title': widget.host.name,
                        for (final t in link['targets'] as List)
                          t['target_id'] as String: widget.host.name,
                      };
                      final rotated = await service.rotateLink(link, labels);
                      setState(() {
                        created = rotated;
                        view = _LinksView.created;
                      });
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                          SnackBar(
                            content: Text(cloudAccessErrorText(context, e)),
                          ),
                        );
                      }
                    }
                  },
                  onActivity: () => setState(() {
                    activityFor = link;
                    view = _LinksView.activity;
                  }),
                ),
            ],
          ),
        ],
      ),
    };
  }
}

String _statusLabel(BuildContext context, String status) => switch (status) {
  'active' => context.l10n.cloudAccessStatusActive,
  'not_yet_valid' => context.l10n.cloudAccessStatusScheduled,
  'expired' => context.l10n.cloudAccessStatusExpired,
  'paused' => context.l10n.cloudAccessStatusPaused,
  'suspended' => context.l10n.cloudAccessStatusSuspended,
  'revoked' => context.l10n.cloudAccessStatusRevoked,
  _ => status,
};

class _LinkTile extends StatelessWidget {
  const _LinkTile({
    required this.link,
    required this.onPause,
    required this.onRevoke,
    required this.onRotate,
    required this.onActivity,
  });
  final Map<String, dynamic> link;
  final VoidCallback onPause;
  final VoidCallback onRevoke;
  final VoidCallback onRotate;
  final VoidCallback onActivity;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final palette = context.palette;
    final status = link['status'] as String;
    final live =
        status == 'active' || status == 'not_yet_valid' || status == 'paused';
    final color = switch (status) {
      'active' => palette.accent,
      'not_yet_valid' || 'paused' => palette.orange,
      _ => palette.muted,
    };
    final max = link['max_redemptions'];
    return Card(
      margin: const EdgeInsets.only(top: 6),
      child: ListTile(
        dense: true,
        leading: Icon(Icons.circle, size: 10, color: color),
        title: Text(
          '/s/${link['slug']}',
          style: const TextStyle(fontFamily: 'monospace'),
        ),
        subtitle: Text(
          [
            _statusLabel(context, status),
            l10n.cloudAccessValidUntil(
              cloudAccessShortTime(context, link['expires_at'] as String?),
            ),
            l10n.cloudAccessRedemptionCount(
              '${link['redemptions']}',
              max == null ? '∞' : '$max',
            ),
            l10n.cloudAccessActiveSessions('${link['active_sessions']}'),
          ].join(' · '),
        ),
        trailing: PopupMenuButton<String>(
          tooltip: l10n.cloudAccessMore,
          onSelected: (value) => switch (value) {
            'pause' => onPause(),
            'rotate' => onRotate(),
            'activity' => onActivity(),
            'revoke' => onRevoke(),
            _ => null,
          },
          itemBuilder: (context) => [
            PopupMenuItem(
              value: 'activity',
              child: Text(l10n.cloudAccessActivity),
            ),
            if (live)
              PopupMenuItem(
                value: 'pause',
                child: Text(
                  status == 'paused'
                      ? l10n.cloudAccessResume
                      : l10n.cloudAccessPause,
                ),
              ),
            if (status != 'revoked')
              PopupMenuItem(
                value: 'rotate',
                child: Text(l10n.cloudAccessRotate),
              ),
            if (status != 'revoked')
              PopupMenuItem(
                value: 'revoke',
                child: Text(
                  l10n.cloudAccessRevoke,
                  style: TextStyle(color: palette.red),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

enum _Lifetime { hour, day, week, custom }

class _LinkEditor extends StatefulWidget {
  const _LinkEditor({
    required this.service,
    required this.host,
    required this.onCancel,
    required this.onCreated,
  });
  final CloudAccessService service;
  final HostRecord host;
  final VoidCallback onCancel;
  final ValueChanged<CreatedShareLink> onCreated;

  @override
  State<_LinkEditor> createState() => _LinkEditorState();
}

class _LinkEditorState extends State<_LinkEditor> {
  _Lifetime lifetime = _Lifetime.day;
  bool scheduled = false;
  DateTime? start;
  DateTime? end;
  final redemptions = TextEditingController(text: '1');
  bool unlimitedRedemptions = false;
  final connections = TextEditingController();
  int concurrent = 1;
  bool clipboardIn = false;
  bool clipboardOut = false;
  bool viewOnly = false;
  final slug = TextEditingController();
  final title = TextEditingController();
  bool busy = false;
  String? error;

  @override
  void dispose() {
    redemptions.dispose();
    connections.dispose();
    slug.dispose();
    title.dispose();
    super.dispose();
  }

  Future<DateTime?> _pick(DateTime initial) async {
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime.now().subtract(const Duration(minutes: 1)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return null;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null) return null;
    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }

  ({DateTime? from, DateTime until}) _window() {
    final from = scheduled ? start : null;
    final base = from ?? DateTime.now();
    final until = switch (lifetime) {
      _Lifetime.hour => base.add(const Duration(hours: 1)),
      _Lifetime.day => base.add(const Duration(hours: 24)),
      _Lifetime.week => base.add(const Duration(days: 7)),
      _Lifetime.custom => end ?? base.add(const Duration(hours: 24)),
    };
    return (from: from, until: until);
  }

  Future<void> _create() async {
    final l10n = context.l10n;
    final window = _window();
    if (scheduled && start == null) {
      setState(() => error = l10n.cloudAccessPickStart);
      return;
    }
    if (!window.until.isAfter(window.from ?? DateTime.now())) {
      setState(() => error = l10n.cloudAccessEndBeforeStart);
      return;
    }
    final maxRedemptions = unlimitedRedemptions
        ? null
        : int.tryParse(redemptions.text.trim());
    if (!unlimitedRedemptions &&
        (maxRedemptions == null ||
            maxRedemptions < 1 ||
            maxRedemptions > 1000)) {
      setState(() => error = l10n.cloudAccessRedemptionsRange);
      return;
    }
    final maxConnections = connections.text.trim().isEmpty
        ? null
        : int.tryParse(connections.text.trim());
    if (connections.text.trim().isNotEmpty &&
        (maxConnections == null || maxConnections < 1)) {
      setState(() => error = l10n.cloudAccessConnectionsRange);
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final created = await widget.service.createLink(
        [widget.host],
        ShareLinkOptions(
          validFrom: window.from,
          expiresAt: window.until,
          maxRedemptions: maxRedemptions,
          maxConnections: maxConnections,
          maxConcurrent: concurrent,
          clipboardToRemote: clipboardIn,
          clipboardFromRemote: clipboardOut,
          viewOnly: viewOnly,
          slug: slug.text.trim().isEmpty ? null : slug.text.trim(),
          title: title.text.trim(),
        ),
      );
      widget.onCreated(created);
    } catch (e) {
      if (mounted) setState(() => error = cloudAccessErrorText(context, e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final window = _window();
    return ListView(
      shrinkWrap: true,
      children: [
        const SizedBox(height: 10),
        Text(
          l10n.cloudAccessNewLink,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 10),
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.cloudAccessScheduleStart),
          subtitle: Text(
            scheduled
                ? (start == null
                      ? l10n.cloudAccessPickStart
                      : cloudAccessShortTime(
                          context,
                          start!.toUtc().toIso8601String(),
                        ))
                : l10n.cloudAccessStartsNow,
          ),
          value: scheduled,
          onChanged: (value) async {
            setState(() => scheduled = value);
            if (value) {
              final picked = await _pick(
                DateTime.now().add(const Duration(hours: 1)),
              );
              if (picked != null) setState(() => start = picked);
            }
          },
        ),
        Text(l10n.cloudAccessLifetime),
        const SizedBox(height: 4),
        Wrap(
          spacing: 6,
          children: [
            for (final (value, label) in [
              (_Lifetime.hour, l10n.cloudAccessOneHour),
              (_Lifetime.day, l10n.cloudAccessOneDay),
              (_Lifetime.week, l10n.cloudAccessOneWeek),
              (_Lifetime.custom, l10n.cloudAccessCustom),
            ])
              ChoiceChip(
                label: Text(label),
                selected: lifetime == value,
                onSelected: (_) async {
                  setState(() => lifetime = value);
                  if (value == _Lifetime.custom) {
                    final picked = await _pick(
                      DateTime.now().add(const Duration(days: 2)),
                    );
                    if (picked != null) setState(() => end = picked);
                  }
                },
              ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text(
            l10n.cloudAccessWindowSummary(
              window.from == null
                  ? l10n.cloudAccessStartsNow
                  : cloudAccessShortTime(
                      context,
                      window.from!.toUtc().toIso8601String(),
                    ),
              cloudAccessShortTime(
                context,
                window.until.toUtc().toIso8601String(),
              ),
              window.until
                  .toUtc()
                  .toIso8601String()
                  .substring(0, 16)
                  .replaceFirst('T', ' '),
            ),
            style: TextStyle(color: context.palette.muted, fontSize: 12),
          ),
        ),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: redemptions,
                enabled: !unlimitedRedemptions,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: l10n.cloudAccessMaxRedemptions,
                  helperText: l10n.cloudAccessMaxRedemptionsHelp,
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilterChip(
              label: Text(l10n.cloudAccessUnlimited),
              selected: unlimitedRedemptions,
              onSelected: (value) =>
                  setState(() => unlimitedRedemptions = value),
            ),
          ],
        ),
        TextField(
          controller: connections,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(
            labelText: l10n.cloudAccessMaxConnections,
            helperText: l10n.cloudAccessMaxConnectionsHelp,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(child: Text(l10n.cloudAccessConcurrent)),
            DropdownButton<int>(
              value: concurrent,
              items: [
                for (var i = 1; i <= 10; i++)
                  DropdownMenuItem(value: i, child: Text('$i')),
              ],
              onChanged: (value) => setState(() => concurrent = value ?? 1),
            ),
          ],
        ),
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.cloudAccessViewOnly),
          subtitle: Text(l10n.cloudAccessViewOnlyHelp),
          value: viewOnly,
          onChanged: (value) => setState(() => viewOnly = value),
        ),
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.cloudAccessClipboardToRemote),
          value: clipboardIn && !viewOnly,
          onChanged: viewOnly
              ? null
              : (value) => setState(() => clipboardIn = value),
        ),
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.cloudAccessClipboardFromRemote),
          value: clipboardOut,
          onChanged: (value) => setState(() => clipboardOut = value),
        ),
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          enabled: false,
          leading: const Icon(Icons.lock_outline, size: 18),
          title: Text(l10n.cloudAccessFilesLocked),
        ),
        TextField(
          controller: slug,
          decoration: InputDecoration(
            labelText: l10n.cloudAccessCustomSlug,
            helperText: l10n.cloudAccessCustomSlugHelp,
            prefixText: '/s/',
          ),
        ),
        TextField(
          controller: title,
          decoration: InputDecoration(
            labelText: l10n.cloudAccessGuestTitle,
            helperText: l10n.cloudAccessGuestTitleHelp,
          ),
        ),
        const SizedBox(height: 10),
        const CloudAccessTrustNotice(),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(error!, style: TextStyle(color: context.palette.red)),
          ),
        const SizedBox(height: 10),
        // Stacks the actions when they do not fit side by side.
        OverflowBar(
          alignment: MainAxisAlignment.end,
          overflowAlignment: OverflowBarAlignment.end,
          spacing: 8,
          overflowSpacing: 6,
          children: [
            TextButton(
              onPressed: busy ? null : widget.onCancel,
              child: Text(l10n.cloudAccessCancel),
            ),
            FilledButton(
              onPressed: busy ? null : _create,
              child: busy
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(l10n.cloudAccessCreateLink),
            ),
          ],
        ),
      ],
    );
  }
}

class _CreatedLinkView extends StatefulWidget {
  const _CreatedLinkView({required this.created, required this.onDone});
  final CreatedShareLink created;
  final VoidCallback onDone;

  @override
  State<_CreatedLinkView> createState() => _CreatedLinkViewState();
}

class _CreatedLinkViewState extends State<_CreatedLinkView> {
  bool copied = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ListView(
      shrinkWrap: true,
      children: [
        const SizedBox(height: 16),
        Icon(
          Icons.check_circle_outline,
          size: 40,
          color: context.palette.accent,
        ),
        const SizedBox(height: 8),
        Text(
          l10n.cloudAccessLinkReady,
          textAlign: TextAlign.center,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          key: const ValueKey('cloud-access-copy-link'),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: widget.created.url));
            if (mounted) setState(() => copied = true);
          },
          icon: Icon(copied ? Icons.check : Icons.copy),
          label: Text(
            copied ? l10n.cloudAccessCopied : l10n.cloudAccessCopyLink,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          l10n.cloudAccessShownOnce,
          textAlign: TextAlign.center,
          style: TextStyle(color: context.palette.muted, fontSize: 12.5),
        ),
        const SizedBox(height: 6),
        Text(
          l10n.cloudAccessSendSafely,
          textAlign: TextAlign.center,
          style: TextStyle(color: context.palette.muted, fontSize: 12.5),
        ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: widget.onDone,
            child: Text(l10n.cloudAccessDone),
          ),
        ),
      ],
    );
  }
}

class _ActivityView extends StatefulWidget {
  const _ActivityView({
    required this.service,
    required this.link,
    required this.onBack,
  });
  final CloudAccessService service;
  final Map<String, dynamic> link;
  final VoidCallback onBack;

  @override
  State<_ActivityView> createState() => _ActivityViewState();
}

class _ActivityViewState extends State<_ActivityView> {
  Map<String, dynamic>? activity;
  Timer? refresh;

  String get vaultId => widget.link['vault_id'] as String;
  String get linkId => widget.link['link_id'] as String;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    refresh = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_load()),
    );
  }

  @override
  void dispose() {
    refresh?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final value = await widget.service.api.activity(vaultId, linkId);
      if (mounted) setState(() => activity = value);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final sessions = (activity?['sessions'] as List? ?? const []).cast<Map>();
    final events = (activity?['events'] as List? ?? const []).cast<Map>();
    return ListView(
      shrinkWrap: true,
      children: [
        Row(
          children: [
            IconButton(
              onPressed: widget.onBack,
              icon: const Icon(Icons.arrow_back),
              tooltip: l10n.cloudAccessBack,
            ),
            Text(
              l10n.cloudAccessActivityFor('/s/${widget.link['slug']}'),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ],
        ),
        CloudAccessSection(
          title: l10n.cloudAccessGuestSessions,
          children: [
            if (sessions.isEmpty)
              Text(
                l10n.cloudAccessNoSessions,
                style: TextStyle(color: context.palette.muted),
              ),
            for (final session in sessions)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  (session['live_connections'] as int? ?? 0) > 0
                      ? Icons.desktop_windows
                      : Icons.person_outline,
                  size: 18,
                ),
                title: Text(
                  '${session['ip_prefix'] ?? '—'} · ${session['ua_family'] ?? '—'}',
                ),
                subtitle: Text(
                  session['active'] == true
                      ? l10n.cloudAccessSessionSince(
                          cloudAccessShortTime(
                            context,
                            session['created_at'] as String?,
                          ),
                        )
                      : l10n.cloudAccessSessionEnded(
                          '${session['end_reason'] ?? ''}',
                        ),
                ),
                trailing: session['active'] == true
                    ? TextButton(
                        onPressed: () async {
                          await widget.service.api.terminate(
                            vaultId,
                            linkId,
                            session['guest_session_id'] as String,
                          );
                          await _load();
                        },
                        child: Text(l10n.cloudAccessTerminate),
                      )
                    : null,
              ),
          ],
        ),
        CloudAccessSection(
          title: l10n.cloudAccessAuditEvents,
          children: [
            for (final event in events.take(50))
              Text(
                '${cloudAccessShortTime(context, event['occurred_at'] as String?)}  ${event['action']}  ${event['result']}',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5),
              ),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Members & teams
// ---------------------------------------------------------------------------

class _MembersTab extends StatefulWidget {
  const _MembersTab({required this.service, required this.host});
  final CloudAccessService service;
  final HostRecord host;

  @override
  State<_MembersTab> createState() => _MembersTabState();
}

class _MembersTabState extends State<_MembersTab> {
  late HostSharePlan plan = widget.service.planShare([widget.host]);
  late final vaultName = TextEditingController(
    text: context.l10n.cloudAccessSharingVaultDefaultName(widget.host.name),
  );
  bool consent = false;
  bool busy = false;
  String? error;
  String? createdVaultId;

  @override
  void dispose() {
    vaultName.dispose();
    super.dispose();
  }

  Future<void> _createVault() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final id = await widget.service.createSharingVault(
        plan,
        vaultName.text.trim(),
      );
      if (mounted) setState(() => createdVaultId = id);
    } catch (e) {
      if (mounted) setState(() => error = cloudAccessErrorText(context, e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  String _dependencyLabel(
    BuildContext context,
    HostShareDependency dependency,
  ) => switch (dependency.kind) {
    HostShareDependencyKind.jumpHost =>
      context.l10n.cloudAccessDependencyJumpHost(dependency.label),
    HostShareDependencyKind.credential =>
      context.l10n.cloudAccessDependencyCredential(dependency.label),
    HostShareDependencyKind.knownHost =>
      context.l10n.cloudAccessDependencyKnownHost(dependency.label),
    HostShareDependencyKind.group => context.l10n.cloudAccessDependencyGroup(
      dependency.label,
    ),
  };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final service = widget.service;
    if (!service.organizationsAvailable) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Text(l10n.cloudAccessErrorOrganizationsUnavailable),
      );
    }
    final vaultId = createdVaultId;
    return ListView(
      shrinkWrap: true,
      children: [
        const SizedBox(height: 10),
        Text(
          l10n.cloudAccessMembersExplainer,
          style: TextStyle(color: context.palette.muted, fontSize: 12.5),
        ),
        // credential-visibility: shared-Vault admin notice.
        CredentialVisibilitySharedVaultNotice(
          app: service.app,
          vaultId: vaultId,
        ),
        if (vaultId != null)
          VaultGrantsPanel(service: service, vaultId: vaultId)
        else ...[
          CloudAccessSection(
            title: l10n.cloudAccessDedicatedVault,
            children: [
              Text(
                l10n.cloudAccessDedicatedVaultHelp,
                style: const TextStyle(fontSize: 12.5),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: vaultName,
                decoration: InputDecoration(
                  labelText: l10n.cloudAccessSharingVaultName,
                ),
              ),
              const SizedBox(height: 8),
              for (final blocker in plan.blockers)
                Text(switch (blocker.kind) {
                  HostShareBlockerKind.missingJumpHost =>
                    l10n.cloudAccessBlockerMissingJump(blocker.hostName),
                  HostShareBlockerKind.missingCredential =>
                    l10n.cloudAccessBlockerMissingCredential(blocker.hostName),
                  HostShareBlockerKind.jumpLoop =>
                    l10n.cloudAccessBlockerJumpLoop(blocker.hostName),
                }, style: TextStyle(color: context.palette.red)),
              Text(
                l10n.cloudAccessWillCopy,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              Text('• ${widget.host.name}'),
              for (final dependency in plan.dependencies)
                Text('• ${_dependencyLabel(context, dependency)}'),
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: consent,
                onChanged: (value) => setState(() => consent = value ?? false),
                title: Text(l10n.cloudAccessConsentCopy),
              ),
              if (error != null)
                Text(error!, style: TextStyle(color: context.palette.red)),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed:
                      busy ||
                          !consent ||
                          !plan.canProceed ||
                          vaultName.text.trim().isEmpty
                      ? null
                      : _createVault,
                  child: Text(l10n.cloudAccessCreateSharingVault),
                ),
              ),
            ],
          ),
          if (service.app.activeVault?.role == 'owner')
            CloudAccessSection(
              title: l10n.cloudAccessWholeVaultHeading,
              children: [
                Text(
                  l10n.cloudAccessWholeVaultHelp,
                  style: const TextStyle(fontSize: 12.5),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: OutlinedButton(
                    onPressed: () => setState(
                      () => createdVaultId = service.app.activeVault!.id,
                    ),
                    child: Text(l10n.cloudAccessManageWholeVault),
                  ),
                ),
              ],
            ),
        ],
      ],
    );
  }
}

/// Desired grants for one Vault plus the owner's key-distribution queue.
class VaultGrantsPanel extends StatefulWidget {
  const VaultGrantsPanel({
    required this.service,
    required this.vaultId,
    super.key,
  });
  final CloudAccessService service;
  final String vaultId;

  @override
  State<VaultGrantsPanel> createState() => _VaultGrantsPanelState();
}

class _VaultGrantsPanelState extends State<VaultGrantsPanel> {
  Map<String, dynamic>? grants;
  Map<String, dynamic>? distribution;
  Map<String, dynamic>? org;
  List<Map<String, dynamic>> orgs = const [];
  String? error;
  bool busy = false;

  CloudAccessService get service => widget.service;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final g = await service.api.grants(widget.vaultId);
      final list = await service.api.orgs();
      Map<String, dynamic>? detail;
      final attached = g['organization'];
      if (attached is Map)
        detail = await service.api.org(attached['org_id'] as String);
      Map<String, dynamic>? dist;
      try {
        dist = await service.api.keyDistribution(widget.vaultId);
      } catch (_) {}
      if (mounted) {
        setState(() {
          grants = g;
          org = detail;
          distribution = dist;
          orgs = (list['organizations'] as List)
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = cloudAccessErrorText(context, e));
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => busy = true);
    try {
      await action();
      await _load();
    } catch (e) {
      if (mounted) setState(() => error = cloudAccessErrorText(context, e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final g = grants;
    if (g == null) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: error == null ? const LinearProgressIndicator() : Text(error!),
      );
    }
    final attached = g['organization'] as Map?;
    if (attached == null) {
      final managed = orgs
          .where((o) => o['role'] == 'owner' || o['role'] == 'admin')
          .toList();
      return CloudAccessSection(
        title: l10n.cloudAccessAttachOrg,
        children: [
          Text(
            l10n.cloudAccessAttachOrgHelp,
            style: const TextStyle(fontSize: 12.5),
          ),
          for (final o in managed)
            ListTile(
              dense: true,
              title: Text(o['name'] as String),
              trailing: TextButton(
                onPressed: busy
                    ? null
                    : () => _run(
                        () => service.api.attachVault(
                          widget.vaultId,
                          o['org_id'] as String,
                        ),
                      ),
                child: Text(l10n.cloudAccessAttach),
              ),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => OrganizationsPage(service: service),
                ),
              ),
              child: Text(l10n.cloudAccessManageOrganizations),
            ),
          ),
          if (error != null)
            Text(error!, style: TextStyle(color: context.palette.red)),
        ],
      );
    }
    final revision = g['grants_revision'] as int;
    final members = (org?['members'] as List? ?? const []).cast<Map>();
    final teams = (org?['teams'] as List? ?? const []).cast<Map>();
    final dist = distribution;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CloudAccessSection(
          title: l10n.cloudAccessGrantsIn('${attached['name']}'),
          trailing: PopupMenuButton<(String, String)>(
            tooltip: l10n.cloudAccessAddGrant,
            icon: const Icon(Icons.person_add_alt),
            onSelected: (choice) => _run(
              () => service.api.setGrant(
                widget.vaultId,
                choice.$1,
                choice.$2,
                'viewer',
                revision,
              ),
            ),
            itemBuilder: (context) => [
              for (final team in teams)
                PopupMenuItem(
                  value: ('team', team['team_id'] as String),
                  child: Text(l10n.cloudAccessTeamLabel('${team['name']}')),
                ),
              for (final member in members)
                PopupMenuItem(
                  value: ('user', member['user_id'] as String),
                  child: Text('${member['username']}'),
                ),
            ],
          ),
          children: [
            for (final grant in (g['grants'] as List).cast<Map>())
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  grant['principal_type'] == 'team'
                      ? Icons.groups_outlined
                      : Icons.person_outline,
                  size: 18,
                ),
                title: Text('${grant['name'] ?? grant['principal_id']}'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButton<String>(
                      value: grant['role'] as String,
                      items: [
                        DropdownMenuItem(
                          value: 'viewer',
                          child: Text(l10n.cloudAccessRoleViewer),
                        ),
                        DropdownMenuItem(
                          value: 'editor',
                          child: Text(l10n.cloudAccessRoleEditor),
                        ),
                      ],
                      onChanged: busy
                          ? null
                          : (role) => _run(
                              () => service.api.setGrant(
                                widget.vaultId,
                                grant['principal_type'] as String,
                                grant['principal_id'] as String,
                                role!,
                                revision,
                              ),
                            ),
                    ),
                    IconButton(
                      tooltip: l10n.cloudAccessRemove,
                      onPressed: busy
                          ? null
                          : () => _run(
                              () => service.api.removeGrant(
                                widget.vaultId,
                                grant['principal_type'] as String,
                                grant['principal_id'] as String,
                                revision,
                              ),
                            ),
                      icon: const Icon(Icons.close, size: 18),
                    ),
                  ],
                ),
              ),
          ],
        ),
        if (dist != null)
          CloudAccessSection(
            title: l10n.cloudAccessKeyDistribution,
            children: [
              Text(
                l10n.cloudAccessKeyDistributionHelp,
                style: const TextStyle(fontSize: 12.5),
              ),
              for (final pending
                  in (dist['pending_additions'] as List).cast<Map>())
                _PendingAddition(
                  pending: Map<String, dynamic>.from(pending),
                  service: service,
                  busy: busy,
                  onDeliver: (card) => _run(
                    () => service.deliverKey(
                      vaultId: widget.vaultId,
                      card: card,
                      role: pending['desired_role'] as String,
                    ),
                  ),
                  onApplyRole: () => _run(
                    () => service.changeMemberRole(
                      vaultId: widget.vaultId,
                      userId: pending['user_id'] as String,
                      role: pending['desired_role'] as String,
                    ),
                  ),
                ),
              for (final removal
                  in (dist['pending_removals'] as List).cast<Map>())
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    Icons.block,
                    size: 18,
                    color: context.palette.red,
                  ),
                  title: Text('${removal['username'] ?? removal['user_id']}'),
                  subtitle: Text(l10n.cloudAccessRemovalPending),
                  trailing: Wrap(
                    spacing: 4,
                    children: [
                      TextButton(
                        onPressed: busy
                            ? null
                            : () => _run(
                                () => service.api.makeDirect(
                                  widget.vaultId,
                                  removal['user_id'] as String,
                                ),
                              ),
                        child: Text(l10n.cloudAccessKeepDirect),
                      ),
                      FilledButton(
                        onPressed: busy
                            ? null
                            : () async {
                                if (await confirmCloudAction(
                                  context,
                                  title: l10n.cloudAccessRotateToRemove,
                                  message: l10n.cloudAccessRemovalPending,
                                  action: l10n.cloudAccessRotateToRemove,
                                )) {
                                  await _run(
                                    () => service.removeMember(
                                      vaultId: widget.vaultId,
                                      userId: removal['user_id'] as String,
                                    ),
                                  );
                                }
                              },
                        child: Text(l10n.cloudAccessRotateToRemove),
                      ),
                    ],
                  ),
                ),
              for (final restricted
                  in (dist['restricted_to_viewer'] as List? ?? const [])
                      .cast<Map>())
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.visibility_outlined, size: 18),
                  title: Text(
                    '${restricted['username'] ?? restricted['user_id']}',
                  ),
                  subtitle: Text(l10n.cloudAccessRestrictedToViewer),
                ),
            ],
          ),
        if (error != null)
          Text(error!, style: TextStyle(color: context.palette.red)),
      ],
    );
  }
}

class _PendingAddition extends StatelessWidget {
  const _PendingAddition({
    required this.pending,
    required this.service,
    required this.busy,
    required this.onDeliver,
    required this.onApplyRole,
  });
  final Map<String, dynamic> pending;
  final CloudAccessService service;
  final bool busy;
  final ValueChanged<Map<String, dynamic>> onDeliver;

  /// Owner-confirmed signed role update for an already accepted member.
  final VoidCallback onApplyRole;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final status = pending['status'] as String;
    final cards = (pending['device_cards'] as List).cast<Map>();
    // credential-visibility: the server marks admin-visible grantees.
    final adminVisible = pending['admin_visible'] == true;
    return Card(
      margin: const EdgeInsets.only(top: 6),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${pending['username']} · ${pending['desired_role'] == 'editor' ? l10n.cloudAccessRoleEditor : l10n.cloudAccessRoleViewer}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            Text(switch (status) {
              'waiting_for_device' => l10n.cloudAccessWaitingForDevice,
              'waiting_for_recipient' => l10n.cloudAccessWaitingForRecipient,
              'role_differs' => l10n.cloudAccessRoleDiffers,
              _ => l10n.cloudAccessWaitingForOwner,
            }, style: TextStyle(color: context.palette.orange, fontSize: 12.5)),
            if (adminVisible)
              CredentialVisibilityGranteeWarning(
                key: ValueKey(
                  'cloud-access-admin-visible-${pending['user_id']}',
                ),
                recipientName: '${pending['username']}',
              ),
            if (status == 'role_differs')
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: FilledButton.tonal(
                  key: ValueKey(
                    'cloud-access-apply-role-${pending['user_id']}',
                  ),
                  onPressed: busy
                      ? null
                      : () async {
                          final role = pending['desired_role'] == 'editor'
                              ? l10n.cloudAccessRoleEditor
                              : l10n.cloudAccessRoleViewer;
                          final ok = await confirmCloudAction(
                            context,
                            title: l10n.cloudAccessApplyRoleTitle,
                            message: l10n.cloudAccessApplyRoleMessage(
                              '${pending['username']}',
                              role,
                            ),
                            action: l10n.cloudAccessApplyRole(role),
                            destructive: false,
                          );
                          if (ok) onApplyRole();
                        },
                  child: Text(
                    l10n.cloudAccessApplyRole(
                      pending['desired_role'] == 'editor'
                          ? l10n.cloudAccessRoleEditor
                          : l10n.cloudAccessRoleViewer,
                    ),
                  ),
                ),
              ),
            if (status == 'waiting_for_owner')
              for (final card in cards)
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.cloudAccessDeviceFingerprint(
                          service.cardFingerprint(
                            Map<String, dynamic>.from(card['card'] as Map),
                          ),
                        ),
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: busy
                          ? null
                          : () async {
                              // credential-visibility: explicit consent first.
                              if (adminVisible &&
                                  !await confirmCredentialVisibilityRecipient(
                                    context,
                                    recipientName: '${pending['username']}',
                                  )) {
                                return;
                              }
                              if (!context.mounted) return;
                              final ok = await confirmCloudAction(
                                context,
                                title: l10n.cloudAccessConfirmFingerprintTitle,
                                message: l10n
                                    .cloudAccessConfirmFingerprintMessage(
                                      '${pending['username']}',
                                      service.cardFingerprint(
                                        Map<String, dynamic>.from(
                                          card['card'] as Map,
                                        ),
                                      ),
                                    ),
                                action: l10n.cloudAccessDeliverKey,
                                destructive: false,
                              );
                              if (ok)
                                onDeliver(
                                  Map<String, dynamic>.from(
                                    card['card'] as Map,
                                  ),
                                );
                            },
                      child: Text(l10n.cloudAccessDeliverKey),
                    ),
                  ],
                ),
          ],
        ),
      ),
    );
  }
}
