import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../api/api_client.dart' show VaultPresenceDevice;
import '../app_controller.dart';
import '../console/local_console.dart';
import '../domain/models.dart';
import '../domain/quick_connect.dart';
import '../l10n/l10n.dart';
import '../telnet/telnet_ui.dart';
import 'app_theme.dart';
import 'local_shell_menu.dart';
import 'workspace_controls.dart';

/// Server presence leases expire after this long (`VaultPresenceSnapshot`
/// only accepts `ttl_seconds == 90`). A device is shown online only while its
/// last heartbeat is younger than this.
const homeSharingPresenceTtl = Duration(seconds: 90);

/// Home row directly below the search field: one primary Add menu (Hosts,
/// local Shell, serial Console) on the left and the multi-user sharing status
/// on the right. It only routes to existing flows supplied by the caller; it
/// starts nothing itself and never contacts the server.
class HomeAddSharingRow extends StatelessWidget {
  const HomeAddSharingRow({
    required this.idPrefix,
    required this.onAddHost,
    required this.onLaunchShell,
    required this.onSerialConsole,
    required this.sharing,
    this.onQuickImportTermius,
    this.canAddHosts = true,
    this.enabled = true,
    this.shellSupportedOverride,
    this.serialSupportedOverride,
    super.key,
  });

  /// `cloud` or `local`; prefixes every key in this row.
  final String idPrefix;
  final FutureOr<void> Function(HostProtocol protocol) onAddHost;
  final FutureOr<void> Function(LocalShellLaunch launch) onLaunchShell;

  /// Receives a validated serial request; callers pass it to their existing
  /// quick-connect route (`console COMn -b baud`).
  final FutureOr<void> Function(QuickConnectRequest request) onSerialConsole;
  final FutureOr<void> Function()? onQuickImportTermius;
  final Widget sharing;

  /// False for read-only Vaults: Host entries stay visible but disabled.
  final bool canAddHosts;
  final bool enabled;
  final bool? shellSupportedOverride, serialSupportedOverride;

  bool get _shellSupported => shellSupportedOverride ?? localConsoleSupported;

  /// Serial consoles exist in the Windows (COMn) and macOS (/dev/cu.*) desktop clients.
  bool get _serialSupported =>
      serialSupportedOverride ??
      (!kIsWeb &&
          localConsoleSupported &&
          (defaultTargetPlatform == TargetPlatform.windows ||
              defaultTargetPlatform == TargetPlatform.macOS));

  static String _quickImportLabel(BuildContext context) {
    final lang = Localizations.localeOf(context).languageCode;
    return switch (lang) {
      'zh' => '一键导入 Termius',
      'ja' => 'Termius 一括取込',
      'ru' => 'Импорт Termius в 1 клик',
      _ => 'One-click Termius Import',
    };
  }

  List<WorkspaceAction> _actions(BuildContext context) {
    final l10n = context.l10n;
    final quickTermius = onQuickImportTermius;
    return [
      if (quickTermius != null)
        WorkspaceAction(
          '${idPrefix}_home_add_termius_one_click',
          _quickImportLabel(context),
          Icons.bolt_rounded,
          quickTermius,
          enabled: enabled && canAddHosts,
        ),
      for (final protocol in const [
        HostProtocol.ssh,
        HostProtocol.telnet,
        HostProtocol.rdp,
        HostProtocol.vnc,
      ])
        WorkspaceAction(
          '${idPrefix}_home_add_${protocol.name}',
          l10n.newTouppercaseHost(protocol.label),
          hostProtocolIcon(protocol),
          () => onAddHost(protocol),
          enabled: enabled && canAddHosts,
        ),
      if (_shellSupported) ...[
        WorkspaceAction(
          '${idPrefix}_home_add_shell',
          l10n.homeAddShell,
          Icons.code,
          () => onLaunchShell(LocalShellLaunch.systemDefault),
          enabled: enabled,
        ),
        WorkspaceAction(
          '${idPrefix}_home_add_shell_options',
          l10n.shellLocalOptions,
          Icons.tune,
          () async {
            final kinds = availableLocalShellKinds();
            final launch = await showLocalShellOptionsDialog(
              context,
              kinds: kinds.isEmpty ? const [LocalShellKind.system] : kinds,
            );
            if (launch != null) await onLaunchShell(launch);
          },
          enabled: enabled,
        ),
      ] else
        WorkspaceAction(
          '${idPrefix}_home_add_shell_unavailable',
          l10n.shellLocalUnavailable,
          Icons.code_off,
          () => showLocalShellUnavailable(context),
        ),
      WorkspaceAction(
        '${idPrefix}_home_add_console',
        _serialSupported
            ? l10n.homeAddSerialConsole
            : l10n.homeAddSerialConsoleUnavailable,
        Icons.cable_outlined,
        () async {
          if (!_serialSupported) {
            await showHomeSerialConsoleUnavailable(context);
            return;
          }
          final request = await showHomeSerialConsoleDialog(context);
          if (request != null) await onSerialConsole(request);
        },
        enabled: enabled || !_serialSupported,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    final add = WorkspaceOverflowMenu(
      key: ValueKey('${idPrefix}_home_add'),
      tooltip: l10n.homeAddTooltip,
      actions: _actions(context),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 40, minWidth: 88),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.add, size: 18, color: scheme.onPrimaryContainer),
                const SizedBox(width: 6),
                Text(
                  l10n.homeAddButton,
                  style: TextStyle(
                    color: scheme.onPrimaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 2),
                Icon(
                  Icons.arrow_drop_down,
                  size: 18,
                  color: scheme.onPrimaryContainer,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final quickTermius = onQuickImportTermius;
    final quickButton = quickTermius == null
        ? null
        : SizedBox(
            height: 40,
            child: OutlinedButton.icon(
              key: ValueKey('${idPrefix}_home_one_click_termius'),
              onPressed: enabled && canAddHosts ? () => quickTermius() : null,
              icon: const Icon(Icons.bolt_rounded, size: 18),
              label: Text(
                _quickImportLabel(context),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          );
    final leftCluster = quickButton == null
        ? add
        : Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [add, quickButton],
          );
    // spaceBetween keeps Add on the left and sharing on the right while both
    // fit; on narrow screens the sharing cluster wraps to its own line.
    return SizedBox(
      key: ValueKey('${idPrefix}_home_add_row'),
      width: double.infinity,
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 12,
        runSpacing: 8,
        children: [leftCluster, sharing],
      ),
    );
  }
}

Future<void> showHomeSerialConsoleUnavailable(BuildContext context) =>
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('home_serial_console_unavailable_dialog'),
        title: Text(context.l10n.homeAddSerialConsoleUnavailable),
        content: Text(context.l10n.theComSerialConsoleRequiresThe),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(MaterialLocalizations.of(context).okButtonLabel),
          ),
        ],
      ),
    );

/// Asks for a COM port and baud rate. Validation is the quick-connect grammar
/// (`console COMn -b baud`), so the result follows the same route and limits
/// as typing that command in search.
Future<QuickConnectRequest?> showHomeSerialConsoleDialog(
  BuildContext context,
) => showDialog<QuickConnectRequest>(
  context: context,
  builder: (_) => const _HomeSerialConsoleDialog(),
);

class _HomeSerialConsoleDialog extends StatefulWidget {
  const _HomeSerialConsoleDialog();

  @override
  State<_HomeSerialConsoleDialog> createState() =>
      _HomeSerialConsoleDialogState();
}

class _HomeSerialConsoleDialogState extends State<_HomeSerialConsoleDialog> {
  final _port = TextEditingController();
  final _baud = TextEditingController(text: '115200');
  String? _error;

  @override
  void dispose() {
    _port.dispose();
    _baud.dispose();
    super.dispose();
  }

  void _submit() {
    final port = _port.text.trim();
    final baud = _baud.text.trim();
    // Each field is a single token, so the grammar cannot be extended here.
    if (port.isEmpty || port.contains(RegExp(r'\s'))) {
      setState(() => _error = context.l10n.enterAValidSerialPortFor);
      return;
    }
    if (!RegExp(r'^[0-9]{1,7}$').hasMatch(baud)) {
      setState(() => _error = context.l10n.baudRateMustBe504000000);
      return;
    }
    try {
      final request = QuickConnectRequest.parse('console $port -b $baud');
      if (request == null || request.kind != QuickConnectKind.serial) {
        throw FormatException(context.l10n.enterAValidSerialPortFor);
      }
      Navigator.of(context).pop(request);
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      key: const ValueKey('home_serial_console_dialog'),
      title: Text(l10n.homeAddSerialConsoleTitle),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.homeAddSerialConsoleDetail,
              style: TextStyle(color: context.palette.muted, height: 1.4),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('home_serial_console_port'),
              controller: _port,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              maxLength: defaultTargetPlatform == TargetPlatform.macOS ? 128 : 8,
              decoration: InputDecoration(
                labelText: l10n.homeAddSerialConsolePort,
                hintText: defaultTargetPlatform == TargetPlatform.macOS
                    ? '/dev/cu.usbserial-0001'
                    : 'COM3',
                counterText: '',
              ),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('home_serial_console_baud'),
              controller: _baud,
              keyboardType: TextInputType.number,
              maxLength: 7,
              decoration: InputDecoration(
                labelText: l10n.homeAddSerialConsoleBaud,
                errorText: _error,
                counterText: '',
              ),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          key: const ValueKey('home_serial_console_open'),
          onPressed: _submit,
          child: Text(l10n.homeAddSerialConsoleOpen),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Sharing status projection
// ---------------------------------------------------------------------------

enum HomeSharingMode {
  /// Local Profile: never shared, no other users exist.
  local,

  /// Account Vault whose member list has not been loaded (yet).
  notLoaded,

  /// Account Vault with only the signed-in member.
  individual,

  /// Account Vault with more than one active member.
  shared,
}

enum HomeSharingPresence { online, offline, unknown }

@immutable
class HomeSharingPerson {
  const HomeSharingPerson({
    required this.userId,
    required this.label,
    required this.role,
    required this.isSelf,
    required this.invited,
    required this.presence,
  });

  final String userId, label, role;
  final bool isSelf, invited;
  final HomeSharingPresence presence;

  /// One or two visible initials from the trusted user name; never a fetched
  /// avatar image.
  String get initials {
    final name = label.split('@').first.trim();
    final parts = name
        .split(RegExp(r'[\s._\-]+'))
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '?';
    final first = parts.first.characters.first;
    final second = parts.length > 1 ? parts[1].characters.first : '';
    return (first + second).toUpperCase();
  }
}

@immutable
class HomeSharingSnapshot {
  const HomeSharingSnapshot._({
    required this.mode,
    required this.people,
    required this.presenceKnown,
    this.loading = false,
  });

  const HomeSharingSnapshot.local()
    : this._(
        mode: HomeSharingMode.local,
        people: const [],
        presenceKnown: false,
      );

  final HomeSharingMode mode;

  /// Active and invited members, the signed-in member first. Revoked members
  /// are excluded.
  final List<HomeSharingPerson> people;
  final bool presenceKnown, loading;

  int get activeCount => people.where((p) => !p.invited).length;
  int get onlineOthers => people
      .where((p) => !p.isSelf && p.presence == HomeSharingPresence.online)
      .length;

  /// Pure projection over the controller's real Vault member list and
  /// presence snapshot. [presenceFetchedAt] is when the presence list last
  /// loaded successfully for this Vault (null = never/unknown). Nobody is
  /// shown online without a lease younger than [ttl]; a missing lease means
  /// offline only while the snapshot itself is younger than [ttl].
  factory HomeSharingSnapshot.fromVault({
    required List<Map<String, dynamic>> members,
    required List<VaultPresenceDevice> devices,
    required String? selfUserId,
    required String? selfUsername,
    required DateTime? presenceFetchedAt,
    required bool presenceFailed,
    required DateTime now,
    bool loading = false,
    Duration ttl = homeSharingPresenceTtl,
  }) {
    final snapshotFresh =
        !presenceFailed &&
        presenceFetchedAt != null &&
        now.difference(presenceFetchedAt) < ttl;
    HomeSharingPresence presenceOf(String userId) {
      if (presenceFailed || presenceFetchedAt == null) {
        return HomeSharingPresence.unknown;
      }
      final live = devices.any(
        (device) =>
            device.userId == userId && now.difference(device.lastSeenAt) < ttl,
      );
      if (live) return HomeSharingPresence.online;
      return snapshotFresh
          ? HomeSharingPresence.offline
          : HomeSharingPresence.unknown;
    }

    final people = <HomeSharingPerson>[];
    for (final member in members) {
      final userId = member['user_id'];
      final state = member['state'];
      if (userId is! String || (state != 'active' && state != 'invited')) {
        continue;
      }
      final username = member['username'];
      final label = username is String && username.trim().isNotEmpty
          ? username.trim()
          : (userId.length > 13 ? '${userId.substring(0, 8)}…' : userId);
      final isSelf = selfUserId != null && userId == selfUserId;
      final invited = state == 'invited';
      people.add(
        HomeSharingPerson(
          userId: userId,
          label: label,
          role: member['role'] is String ? member['role'] as String : '',
          isSelf: isSelf,
          invited: invited,
          // This device is the signed-in member's live session.
          presence: invited
              ? HomeSharingPresence.unknown
              : isSelf
              ? HomeSharingPresence.online
              : presenceOf(userId),
        ),
      );
    }
    if (people.isEmpty) {
      // Members are not loaded: show only the signed-in user, never others.
      return HomeSharingSnapshot._(
        mode: HomeSharingMode.notLoaded,
        loading: loading,
        presenceKnown: false,
        people: [
          if (selfUserId != null)
            HomeSharingPerson(
              userId: selfUserId,
              label: selfUsername?.trim().isNotEmpty == true
                  ? selfUsername!.trim()
                  : '?',
              role: '',
              isSelf: true,
              invited: false,
              presence: HomeSharingPresence.online,
            ),
        ],
      );
    }
    people.sort((a, b) {
      if (a.isSelf != b.isSelf) return a.isSelf ? -1 : 1;
      if (a.invited != b.invited) return a.invited ? 1 : -1;
      final rank = (a.presence.index).compareTo(b.presence.index);
      if (rank != 0) return rank;
      return a.label.toLowerCase().compareTo(b.label.toLowerCase());
    });
    final active = people.where((p) => !p.invited).length;
    return HomeSharingSnapshot._(
      mode: active > 1 ? HomeSharingMode.shared : HomeSharingMode.individual,
      people: List.unmodifiable(people),
      presenceKnown: !presenceFailed && presenceFetchedAt != null,
      loading: loading,
    );
  }
}

/// Account-mode loader: fetches the active Vault's member list once per
/// Vault/membership version through the existing authenticated controller
/// API, refreshes only the presence list while visible (no lease renewal) and
/// re-evaluates lease freshness locally.
class CloudHomeSharingStatus extends StatefulWidget {
  const CloudHomeSharingStatus({
    required this.app,
    required this.onOpenDetails,
    this.now,
    this.presenceRefreshInterval = const Duration(seconds: 30),
    super.key,
  });

  final AppController app;
  final VoidCallback onOpenDetails;

  /// Presence-list (GET only) refresh cadence while Home is visible; matches
  /// the Members dialog and stays below [homeSharingPresenceTtl].
  final Duration presenceRefreshInterval;

  /// Clock for tests.
  final DateTime Function()? now;

  @override
  State<CloudHomeSharingStatus> createState() => _CloudHomeSharingStatusState();
}

class _CloudHomeSharingStatusState extends State<CloudHomeSharingStatus> {
  String? _loadedScope;
  String? _presenceVaultId;
  DateTime? _presenceFetchedAt;
  bool _loading = false;
  Timer? _refreshTimer;

  AppController get app => widget.app;
  DateTime _now() => (widget.now ?? DateTime.now)().toUtc();

  String? get _scope {
    final vault = app.activeVault;
    if (vault == null || !app.authenticated) return null;
    return '${app.currentAccountId}:${vault.id}:${vault.membershipVersion}';
  }

  @override
  void initState() {
    super.initState();
    app.addListener(_onAppChanged);
    _schedule();
  }

  @override
  void didUpdateWidget(CloudHomeSharingStatus oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.app, app)) {
      oldWidget.app.removeListener(_onAppChanged);
      app.addListener(_onAppChanged);
      _loadedScope = null;
      _schedule();
    }
  }

  @override
  void dispose() {
    app.removeListener(_onAppChanged);
    _refreshTimer?.cancel();
    super.dispose();
  }

  void _onAppChanged() {
    if (!mounted) return;
    if (_scope != _loadedScope) _schedule();
    setState(() {});
  }

  void _schedule() {
    final scope = _scope;
    if (scope == _loadedScope) return;
    _loadedScope = scope;
    _presenceFetchedAt = null;
    _presenceVaultId = null;
    _refreshTimer?.cancel();
    _refreshTimer = null;
    if (scope == null) return;
    // Defer so a listener notification is never raised during build.
    scheduleMicrotask(() => _loadMembers(scope));
    _refreshTimer = Timer.periodic(
      widget.presenceRefreshInterval,
      (_) => _refreshPresence(),
    );
  }

  Future<void> _loadMembers(String scope) async {
    if (!mounted || _scope != scope || _loading) return;
    final vaultId = app.activeVault?.id;
    setState(() => _loading = true);
    try {
      await app.refreshVaultMembers(vaultId: vaultId);
      _notePresenceResult(scope, vaultId);
    } catch (_) {
      // Unknown state is shown; details remain available via the dialog.
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _refreshPresence() async {
    final scope = _scope;
    if (!mounted || scope == null || scope != _loadedScope) return;
    if (app.vaultPresenceLoading || app.vaultMembershipBusy || _loading) {
      setState(() {}); // still re-evaluate lease freshness
      return;
    }
    final vaultId = app.activeVault?.id;
    try {
      await app.refreshVaultPresenceList(vaultId: vaultId);
      _notePresenceResult(scope, vaultId);
    } catch (_) {
      if (mounted && _scope == scope) setState(() => _presenceFetchedAt = null);
    }
  }

  void _notePresenceResult(String scope, String? vaultId) {
    if (!mounted || _scope != scope || app.activeVault?.id != vaultId) return;
    setState(() {
      if (app.vaultPresenceError == null) {
        _presenceFetchedAt = _now();
        _presenceVaultId = vaultId;
      } else {
        _presenceFetchedAt = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final vaultId = app.activeVault?.id;
    final trusted = _scope != null && _scope == _loadedScope;
    final snapshot = HomeSharingSnapshot.fromVault(
      members: trusted ? app.vaultMembers : const [],
      devices: trusted ? app.vaultPresenceDevices : const [],
      selfUserId: app.currentAccountId,
      selfUsername: app.authenticatedUsername,
      presenceFetchedAt: _presenceVaultId == vaultId
          ? _presenceFetchedAt
          : null,
      presenceFailed: app.vaultPresenceError != null,
      now: _now(),
      loading: _loading,
    );
    return HomeSharingCluster(
      idPrefix: 'cloud',
      snapshot: snapshot,
      onOpenDetails: widget.onOpenDetails,
    );
  }
}

/// Avatars + status label. Tapping opens [onOpenDetails].
class HomeSharingCluster extends StatelessWidget {
  const HomeSharingCluster({
    required this.idPrefix,
    required this.snapshot,
    required this.onOpenDetails,
    super.key,
  });

  final String idPrefix;
  final HomeSharingSnapshot snapshot;
  final VoidCallback onOpenDetails;

  String _status(BuildContext context) {
    final l10n = context.l10n;
    return switch (snapshot.mode) {
      HomeSharingMode.local => l10n.homeSharingLocalOnly,
      HomeSharingMode.notLoaded =>
        snapshot.loading
            ? l10n.homeSharingLoading
            : l10n.homeSharingMembersUnavailable,
      HomeSharingMode.individual => l10n.homeSharingIndividual,
      HomeSharingMode.shared =>
        snapshot.presenceKnown
            ? l10n.homeSharingSharedOnline(
                snapshot.activeCount,
                snapshot.onlineOthers,
              )
            : l10n.homeSharingSharedPresenceUnknown(snapshot.activeCount),
    };
  }

  String _presenceLabel(BuildContext context, HomeSharingPerson person) {
    final l10n = context.l10n;
    if (person.invited) return l10n.invitationPending;
    if (person.isSelf) return l10n.homeSharingThisDevice;
    return switch (person.presence) {
      HomeSharingPresence.online => l10n.homeSharingOnline,
      HomeSharingPresence.offline => l10n.homeSharingOffline,
      HomeSharingPresence.unknown => l10n.homeSharingPresenceUnknown,
    };
  }

  String _personTooltip(BuildContext context, HomeSharingPerson person) {
    final name = person.isSelf
        ? context.l10n.homeSharingYou(person.label)
        : person.label;
    return [
      name,
      if (person.role.isNotEmpty) person.role.toUpperCase(),
      _presenceLabel(context, person),
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    // The space actually given to the row (sidebars included), not the window.
    builder: (context, constraints) =>
        _build(context, maxVisible: constraints.maxWidth < 440 ? 3 : 5),
  );

  Widget _build(BuildContext context, {required int maxVisible}) {
    final people = snapshot.people;
    final visible = people.length > maxVisible
        ? people.take(maxVisible - 1).toList()
        : people;
    final hidden = people.skip(visible.length).toList();
    final status = _status(context);
    final scheme = Theme.of(context).colorScheme;
    final local = snapshot.mode == HomeSharingMode.local;
    return Semantics(
      container: true,
      button: true,
      label: status,
      child: Tooltip(
        message: local
            ? context.l10n.homeSharingLocalTooltip
            : context.l10n.homeSharingDetailsTooltip,
        excludeFromSemantics: true,
        child: InkWell(
          key: ValueKey('${idPrefix}_home_sharing'),
          borderRadius: BorderRadius.circular(20),
          onTap: onOpenDetails,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 40),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (local)
                    _Avatar(
                      key: ValueKey('${idPrefix}_home_sharing_local_avatar'),
                      tooltip: context.l10n.homeSharingLocalTooltip,
                      background: scheme.surfaceContainerHighest,
                      foreground: scheme.onSurfaceVariant,
                      icon: Icons.person_outline,
                    )
                  else
                    for (final (index, person) in visible.indexed)
                      Padding(
                        padding: EdgeInsets.only(left: index == 0 ? 0 : 2),
                        child: _Avatar(
                          key: ValueKey(
                            '${idPrefix}_home_sharing_avatar_${person.userId}',
                          ),
                          tooltip: _personTooltip(context, person),
                          text: person.initials,
                          background: person.isSelf
                              ? scheme.primaryContainer
                              : scheme.secondaryContainer,
                          foreground: person.isSelf
                              ? scheme.onPrimaryContainer
                              : scheme.onSecondaryContainer,
                          dashed: person.invited,
                          presence: person.presence,
                        ),
                      ),
                  if (hidden.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: 2),
                      child: _Avatar(
                        key: ValueKey('${idPrefix}_home_sharing_overflow'),
                        tooltip: context.l10n.homeSharingMore(
                          hidden.length,
                          hidden
                              .map((person) => _personTooltip(context, person))
                              .join('\n'),
                        ),
                        text: '+${hidden.length}',
                        background: scheme.surfaceContainerHighest,
                        foreground: scheme.onSurfaceVariant,
                      ),
                    ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      status,
                      key: ValueKey('${idPrefix}_home_sharing_status'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: context.palette.muted,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (snapshot.loading) ...[
                    const SizedBox(width: 6),
                    const SizedBox.square(
                      dimension: 12,
                      child: CircularProgressIndicator(strokeWidth: 1.6),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({
    required this.tooltip,
    required this.background,
    required this.foreground,
    this.text,
    this.icon,
    this.dashed = false,
    this.presence,
    super.key,
  });

  final String tooltip;
  final String? text;
  final IconData? icon;
  final Color background, foreground;
  final bool dashed;
  final HomeSharingPresence? presence;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dot = switch (presence) {
      HomeSharingPresence.online => context.palette.accent,
      HomeSharingPresence.offline => scheme.outline,
      _ => null,
    };
    return Tooltip(
      message: tooltip,
      child: Semantics(
        label: tooltip,
        excludeSemantics: true,
        child: SizedBox.square(
          dimension: 30,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: 30,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: dashed ? Colors.transparent : background,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: dashed ? scheme.outline : scheme.surface,
                    width: dashed ? 1 : 1.5,
                  ),
                ),
                child: icon != null
                    ? Icon(icon, size: 17, color: foreground)
                    : Text(
                        text ?? '?',
                        maxLines: 1,
                        style: TextStyle(
                          color: dashed ? scheme.onSurfaceVariant : foreground,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
              ),
              if (dot != null)
                Positioned(
                  right: -1,
                  bottom: -1,
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: dot,
                      shape: BoxShape.circle,
                      border: Border.all(color: scheme.surface, width: 1.5),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Truthful read-only detail for a local Profile: nothing is shared.
Future<void> showHomeLocalSharingDetails(BuildContext context) =>
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('home_local_sharing_dialog'),
        icon: const Icon(Icons.person_outline),
        title: Text(context.l10n.homeSharingLocalOnly),
        content: Text(context.l10n.homeSharingLocalDetail),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(MaterialLocalizations.of(context).okButtonLabel),
          ),
        ],
      ),
    );
