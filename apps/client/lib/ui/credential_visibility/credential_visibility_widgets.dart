// User-facing Credential visibility v1 surfaces: the account settings card,
// the workspace indicator, the one-time mode notice, the registration notice,
// Vault badges and the share-recipient warning. Logic lives in
// lib/credential_visibility; these widgets only render it and never derive
// behavior from label text.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../api/api_client.dart';
import '../../app_controller.dart';
import '../../credential_visibility/credential_visibility_api.dart';
import '../../credential_visibility/credential_visibility_models.dart';
import '../../credential_visibility/credential_visibility_service.dart';
import '../../l10n/l10n.dart';
import '../account_settings.dart' show accountSettingsSectionId;
import '../app_motion.dart';
import '../app_theme.dart';
import '../settings_scaffold.dart';

String formatCredentialVisibilityTime(DateTime value) =>
    DateFormat.yMMMd().add_jm().format(value.toLocal());

String credentialVisibilityModeLabel(
  AppLocalizations l10n,
  CredentialVisibilityMode mode,
) => switch (mode) {
  CredentialVisibilityMode.private => l10n.cvModePrivateShort,
  CredentialVisibilityMode.adminVisible => l10n.cvModeAdminVisibleShort,
};

String credentialEscrowStatusLabel(
  AppLocalizations l10n,
  CredentialEscrowStatus status,
) => switch (status) {
  CredentialEscrowStatus.notRequired => l10n.cvEscrowNotRequired,
  CredentialEscrowStatus.noKey => l10n.cvEscrowNoKey,
  CredentialEscrowStatus.pending => l10n.cvEscrowPending,
  CredentialEscrowStatus.complete => l10n.cvEscrowComplete,
};

/// The explanation of [mode]. A private account that belongs to shared
/// Vaults another member made administrator visible gets the qualified text,
/// never an unconditional "administrators can't view them".
String credentialVisibilityModeBody(
  AppLocalizations l10n,
  CredentialVisibilityMode mode, {
  bool sharedAdminVisibleVaults = false,
}) => switch (mode) {
  CredentialVisibilityMode.adminVisible => l10n.cvModeAdminVisibleBody,
  CredentialVisibilityMode.private =>
    sharedAdminVisibleVaults
        ? l10n.cvModePrivateBodySharedException
        : l10n.cvModePrivateBody,
};

Color _modeColor(BuildContext context, CredentialVisibilityMode mode) =>
    switch (mode) {
      CredentialVisibilityMode.private => context.palette.accentText,
      CredentialVisibilityMode.adminVisible => context.palette.orange,
    };

IconData _modeIcon(CredentialVisibilityMode mode) => switch (mode) {
  CredentialVisibilityMode.private => Icons.lock_rounded,
  CredentialVisibilityMode.adminVisible => Icons.warning_amber_rounded,
};

/// Account settings card. Hidden unless the server supports the feature.
class CredentialVisibilitySettingsCard extends StatelessWidget {
  const CredentialVisibilitySettingsCard({
    required this.app,
    this.inDialog = false,
    super.key,
  });

  final AppController app;
  final bool inDialog;

  @override
  Widget build(BuildContext context) {
    final service = credentialVisibilityFor(app);
    return ListenableBuilder(
      // The Vault list too: its admin-visible flags qualify private mode.
      listenable: Listenable.merge([service, app]),
      builder: (context, _) {
        final mode = service.mode;
        if (!service.available || mode == null) return const SizedBox.shrink();
        final content = CredentialVisibilityStatusView(
          mode: mode,
          changedAt: service.changedAt,
          status: service.status,
          sharedAdminVisibleVaults: service.privateWithAdminVisibleVaults,
          escrowKeyRejected: service.escrowKeyRejected,
          refreshFailed: service.lastError != null,
          refreshing: service.refreshing,
          vaultName: (vaultId) => app.vaults.any((vault) => vault.id == vaultId)
              ? app.vaultNameFor(vaultId)
              : null,
          onRefresh: () => unawaited(service.refresh()),
        );
        if (inDialog) return content;
        return SettingsCard(child: content);
      },
    );
  }
}

/// Pure rendering of the user's credential visibility state (testable without
/// a controller).
class CredentialVisibilityStatusView extends StatelessWidget {
  const CredentialVisibilityStatusView({
    required this.mode,
    required this.changedAt,
    required this.status,
    this.sharedAdminVisibleVaults = false,
    this.escrowKeyRejected = false,
    this.refreshFailed = false,
    this.refreshing = false,
    this.vaultName,
    this.onRefresh,
    super.key,
  });

  final CredentialVisibilityMode mode;
  final String? changedAt;
  final CredentialVisibilityStatus? status;

  /// Private mode, but some shared Vaults are administrator visible through
  /// another member: the private text names that exception.
  final bool sharedAdminVisibleVaults;
  final bool escrowKeyRejected;
  final bool refreshFailed;
  final bool refreshing;
  final String? Function(String vaultId)? vaultName;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final color = _modeColor(context, mode);
    final changed = changedAt == null ? null : DateTime.tryParse(changedAt!);
    final escrow = status?.escrowStatus;
    final views = status?.adminViews ?? const <CredentialAdminView>[];
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: context.palette.muted,
      height: 1.45,
    );
    return Column(
      key: const ValueKey('credential_visibility_section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.cvSectionTitle,
                style: theme.textTheme.titleSmall,
              ),
            ),
            if (onRefresh != null)
              IconButton(
                key: const ValueKey('credential_visibility_refresh'),
                tooltip: l10n.refresh,
                onPressed: refreshing ? null : onRefresh,
                icon: refreshing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh_rounded),
              ),
          ],
        ),
        const SizedBox(height: 8),
        DecoratedBox(
          key: ValueKey('credential_visibility_mode_${mode.wire}'),
          decoration: BoxDecoration(
            color: mode == CredentialVisibilityMode.adminVisible
                ? context.palette.warningContainer
                : context.palette.accentContainer.withValues(alpha: .35),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: color.withValues(alpha: .45)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(_modeIcon(mode), color: color, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        credentialVisibilityModeLabel(l10n, mode),
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: color,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        credentialVisibilityModeBody(
                          l10n,
                          mode,
                          sharedAdminVisibleVaults: sharedAdminVisibleVaults,
                        ),
                        key: ValueKey(
                          mode == CredentialVisibilityMode.private &&
                                  sharedAdminVisibleVaults
                              ? 'credential_visibility_private_shared_exception'
                              : 'credential_visibility_mode_body',
                        ),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          height: 1.45,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(l10n.cvModeSetByAdmin, style: muted),
        if (changed != null)
          Text(
            l10n.cvChangedAt(formatCredentialVisibilityTime(changed)),
            style: muted,
          ),
        if (mode == CredentialVisibilityMode.adminVisible &&
            escrow != null) ...[
          const SizedBox(height: 10),
          Text(
            '${l10n.cvEscrowStatusLabel}: ${credentialEscrowStatusLabel(l10n, escrow)}',
            key: ValueKey('credential_visibility_escrow_${escrow.wire}'),
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(switch (escrow) {
            CredentialEscrowStatus.noKey => l10n.cvEscrowNoKeyDetail,
            CredentialEscrowStatus.pending => l10n.cvEscrowPendingDetail,
            _ => l10n.cvEscrowCompleteDetail,
          }, style: muted),
        ],
        if (escrowKeyRejected) ...[
          const SizedBox(height: 8),
          Text(
            l10n.cvEscrowKeyRejected,
            key: const ValueKey('credential_visibility_key_rejected'),
            style: TextStyle(color: context.palette.red),
          ),
        ],
        if (refreshFailed) ...[
          const SizedBox(height: 8),
          Text(
            l10n.cvRefreshFailed,
            style: TextStyle(color: context.palette.red),
          ),
        ],
        const SizedBox(height: 14),
        Text(l10n.cvAdminViewsTitle, style: theme.textTheme.titleSmall),
        const SizedBox(height: 6),
        if (views.isEmpty)
          Text(
            l10n.cvAdminViewsEmpty,
            key: const ValueKey('credential_visibility_no_views'),
            style: muted,
          )
        else
          for (final view in views)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.visibility_outlined,
                    size: 16,
                    color: context.palette.orange,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.cvAdminViewEntry(
                            view.adminUsername ?? l10n.cvAdminViewDeletedAdmin,
                            formatCredentialVisibilityTime(view.viewedAt),
                          ),
                          style: theme.textTheme.bodyMedium,
                        ),
                        if (view.vaultId case final vaultId?)
                          Text(
                            l10n.cvAdminViewVault(
                              vaultName?.call(vaultId) ?? vaultId,
                            ),
                            style: muted,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
      ],
    );
  }
}

/// Takes a signed-in user to the credential visibility section (Settings ›
/// Account). Outside the workspace it shows the same details in a dialog.
void openCredentialVisibilitySettings(BuildContext context, AppController app) {
  if (app.authenticated) {
    SettingsScaffold.requestSection(accountSettingsSectionId);
    app.showWorkspacePage(WorkspacePage.settings);
    return;
  }
  unawaited(showCredentialVisibilityDetails(context, app));
}

/// Opens the credential visibility details over the current page.
Future<void> showCredentialVisibilityDetails(
  BuildContext context,
  AppController app,
) => showAppDialog<void>(
  context: context,
  builder: (dialogContext) => AlertDialog(
    content: SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: CredentialVisibilitySettingsCard(app: app, inDialog: true),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(dialogContext).pop(),
        child: Text(dialogContext.l10n.close),
      ),
    ],
  ),
);

/// Persistent compact "admin-visible" chip for the workspace chrome; renders
/// nothing in private mode or without server support.
class CredentialVisibilityIndicator extends StatelessWidget {
  const CredentialVisibilityIndicator({
    required this.app,
    this.compact = false,
    this.padding = EdgeInsets.zero,
    super.key,
  });

  final AppController app;

  /// Icon only (narrow rails and tight headers).
  final bool compact;

  /// Applied only while the indicator is visible, so private mode leaves
  /// the surrounding layout untouched.
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final service = credentialVisibilityFor(app);
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        if (!service.adminVisible) return const SizedBox.shrink();
        final l10n = context.l10n;
        final color = context.palette.orange;
        final indicator = Tooltip(
          message: l10n.cvIndicatorTooltip,
          child: Semantics(
            button: true,
            label: l10n.cvModeAdminVisibleShort,
            child: InkWell(
              key: const ValueKey('credential_visibility_indicator'),
              borderRadius: BorderRadius.circular(9),
              onTap: () => openCredentialVisibilitySettings(context, app),
              // Falls back to the icon alone when the slot is too narrow for
              // the label (phone status bars), so it never overflows.
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final iconOnly = compact || constraints.maxWidth < 96;
                  final icon = Icon(
                    Icons.visibility_outlined,
                    size: 15,
                    color: color,
                  );
                  return Container(
                    // Bounded so the label can shrink even inside rows that
                    // give their children unbounded width.
                    constraints: const BoxConstraints(maxWidth: 172),
                    padding: EdgeInsets.symmetric(
                      horizontal: iconOnly ? 4 : 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: context.palette.warningContainer,
                      borderRadius: BorderRadius.circular(9),
                      border: Border.all(color: color.withValues(alpha: .5)),
                    ),
                    child: iconOnly
                        ? icon
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              icon,
                              const SizedBox(width: 5),
                              Flexible(
                                child: Text(
                                  l10n.cvModeAdminVisibleShort,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: color,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                  );
                },
              ),
            ),
          ),
        );
        return Padding(padding: padding, child: indicator);
      },
    );
  }
}

/// Replaces [fallback] (chrome that otherwise claims "private") with the
/// admin-visible indicator while the account is admin-visible, or with the
/// Vault badge while the current Vault is shared with an admin-visible
/// member. Only a private account in a private Vault shows [fallback].
class CredentialVisibilityPrivacyBadge extends StatelessWidget {
  const CredentialVisibilityPrivacyBadge({
    required this.app,
    required this.fallback,
    super.key,
  });

  final AppController app;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    if (!credentialVisibilitySupported(app)) return fallback;
    final service = credentialVisibilityFor(app);
    return ListenableBuilder(
      listenable: Listenable.merge([service, app]),
      builder: (context, _) {
        if (service.adminVisible) {
          return CredentialVisibilityIndicator(app: app, compact: true);
        }
        if (app.activeVault?.adminVisible ?? false) {
          return const CredentialVisibilityVaultBadge(compact: true);
        }
        return fallback;
      },
    );
  }
}

/// True when the signed-in account is admin-visible (for chrome that must
/// not claim "private").
bool credentialVisibilityShowsAdminVisible(AppController app) =>
    credentialVisibilitySupported(app) &&
    credentialVisibilityFor(app).adminVisible;

/// Zero-size listener that shows the one-time mode notice when the current
/// mode/changed_at was not acknowledged on this device yet.
class CredentialVisibilityNoticeHost extends StatefulWidget {
  const CredentialVisibilityNoticeHost({required this.app, super.key});

  final AppController app;

  @override
  State<CredentialVisibilityNoticeHost> createState() =>
      _CredentialVisibilityNoticeHostState();
}

class _CredentialVisibilityNoticeHostState
    extends State<CredentialVisibilityNoticeHost> {
  CredentialVisibilityService? _service;
  bool _showing = false;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  @override
  void didUpdateWidget(covariant CredentialVisibilityNoticeHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.app, widget.app)) {
      _service?.removeListener(_changed);
      _attach();
    }
  }

  void _attach() {
    _service = credentialVisibilityFor(widget.app)..addListener(_changed);
    _changed();
  }

  void _changed() {
    if (_showing || _service?.pendingNotice == null) return;
    WidgetsBinding.instance
      ..addPostFrameCallback((_) => unawaited(_show()))
      ..ensureVisualUpdate();
  }

  Future<void> _show() async {
    final service = _service;
    if (!mounted || _showing || service == null) return;
    final notice = service.pendingNotice;
    final mode = service.mode;
    final changedAt = service.changedAt;
    if (notice == null || mode == null) return;
    _showing = true;
    try {
      final openDetails = await showAppDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => CredentialVisibilityNoticeDialog(
          notice: notice,
          sharedAdminVisibleVaults: service.privateWithAdminVisibleVaults,
        ),
      );
      // Only the dialog's own buttons acknowledge (true/false). A route
      // removed any other way (null) leaves the notice pending, so it is
      // shown again. Acknowledge exactly what was shown, unless it changed
      // meanwhile.
      if (openDetails != null &&
          service.mode == mode &&
          service.changedAt == changedAt) {
        await service.acknowledge();
      }
      if (openDetails == true && mounted) {
        await showCredentialVisibilityDetails(context, widget.app);
      }
    } finally {
      _showing = false;
    }
    if (mounted) _changed();
  }

  @override
  void dispose() {
    _service?.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class CredentialVisibilityNoticeDialog extends StatelessWidget {
  const CredentialVisibilityNoticeDialog({
    required this.notice,
    this.sharedAdminVisibleVaults = false,
    super.key,
  });

  final CredentialVisibilityNotice notice;

  /// See [CredentialVisibilityStatusView.sharedAdminVisibleVaults].
  final bool sharedAdminVisibleVaults;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final adminVisible =
        notice == CredentialVisibilityNotice.adminVisible ||
        notice == CredentialVisibilityNotice.switchedToAdminVisible;
    final color = adminVisible
        ? context.palette.orange
        : context.palette.accentText;
    final title = switch (notice) {
      CredentialVisibilityNotice.adminVisible => l10n.cvNoticeAdminVisibleTitle,
      CredentialVisibilityNotice.switchedToAdminVisible =>
        l10n.cvNoticeSwitchedAdminVisibleTitle,
      CredentialVisibilityNotice.private => l10n.cvNoticePrivateTitle,
      CredentialVisibilityNotice.switchedToPrivate =>
        l10n.cvNoticeSwitchedPrivateTitle,
    };
    final paragraphs = switch (notice) {
      CredentialVisibilityNotice.adminVisible ||
      CredentialVisibilityNotice.switchedToAdminVisible => [
        l10n.cvModeAdminVisibleBody,
        l10n.cvNoticeAdminVisibleDeposit,
      ],
      CredentialVisibilityNotice.private => [
        credentialVisibilityModeBody(
          l10n,
          CredentialVisibilityMode.private,
          sharedAdminVisibleVaults: sharedAdminVisibleVaults,
        ),
      ],
      CredentialVisibilityNotice.switchedToPrivate => [
        credentialVisibilityModeBody(
          l10n,
          CredentialVisibilityMode.private,
          sharedAdminVisibleVaults: sharedAdminVisibleVaults,
        ),
        l10n.cvNoticeSwitchedPrivateBody,
      ],
    };
    // The system back gesture/button must not dismiss the notice: it is
    // acknowledged only through one of the two buttons.
    return PopScope(
      canPop: false,
      child: AlertDialog(
        key: ValueKey('credential_visibility_notice_${notice.name}'),
        icon: Icon(
          adminVisible ? Icons.warning_amber_rounded : Icons.lock_rounded,
          color: color,
        ),
        title: Text(title),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final paragraph in paragraphs)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text(
                      paragraph,
                      style: const TextStyle(height: 1.45),
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('credential_visibility_notice_details'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.cvNoticeOpenSettings),
          ),
          FilledButton(
            key: const ValueKey('credential_visibility_notice_ack'),
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.cvNoticeAcknowledge),
          ),
        ],
      ),
    );
  }
}

/// Shown on the registration form before an account is created when the
/// instance default for new accounts is admin-visible.
class CredentialVisibilityRegistrationNotice extends StatelessWidget {
  const CredentialVisibilityRegistrationNotice({
    required this.instance,
    super.key,
  });

  final InstanceInfo? instance;

  @override
  Widget build(BuildContext context) {
    final info = instance;
    if (info == null ||
        !info.capabilities.contains(credentialVisibilityCapability) ||
        info.credentialVisibilityDefault !=
            CredentialVisibilityMode.adminVisible.wire) {
      return const SizedBox.shrink();
    }
    final l10n = context.l10n;
    final color = context.palette.orange;
    return Container(
      key: const ValueKey('credential_visibility_registration_notice'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.palette.warningContainer,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: .45)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.cvRegistrationNoticeTitle,
                  style: TextStyle(color: color, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.cvRegistrationNoticeBody,
                  style: const TextStyle(fontSize: 12.5, height: 1.45),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Small amber "admin-visible" badge for Vault rows.
class CredentialVisibilityVaultBadge extends StatelessWidget {
  const CredentialVisibilityVaultBadge({this.compact = false, super.key});

  /// Icon only (tight headers); the tooltip carries the explanation.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final color = context.palette.orange;
    final l10n = context.l10n;
    return Tooltip(
      message: l10n.cvVaultBadgeTooltip,
      child: Semantics(
        label: compact ? l10n.cvModeAdminVisibleShort : null,
        child: Container(
          key: const ValueKey('credential_visibility_vault_badge'),
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 4 : 6,
            vertical: 2,
          ),
          decoration: BoxDecoration(
            color: context.palette.warningContainer,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: color.withValues(alpha: .5)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.visibility_outlined,
                size: compact ? 15 : 12,
                color: color,
              ),
              if (!compact) ...[
                const SizedBox(width: 3),
                Text(
                  l10n.cvModeAdminVisibleShort,
                  style: TextStyle(
                    color: color,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// [label] for a Vault in menus that cannot show a badge widget (the
/// workspace Vault switcher), marked when the Vault is admin-visible.
String credentialVisibilityVaultMenuLabel(
  AppLocalizations l10n,
  VaultDescriptor vault,
  String label,
) => vault.adminVisible ? '$label · ${l10n.cvModeAdminVisibleShort}' : label;

/// Notice for share flows: shown when the server marks the Vault
/// `admin_visible`.
///
/// The controller's Vault list is only reloaded at sign-in, unlock and
/// lifecycle actions, while another member's mode (or the escrow key) can
/// change at any time. So the notice asks the server (`GET /vaults`) each
/// time a share flow shows it and uses that answer; the cached descriptor
/// is shown meanwhile and kept if the request fails.
class CredentialVisibilitySharedVaultNotice extends StatefulWidget {
  const CredentialVisibilitySharedVaultNotice({
    required this.app,
    required this.vaultId,
    super.key,
  });

  final AppController app;
  final String? vaultId;

  @override
  State<CredentialVisibilitySharedVaultNotice> createState() =>
      _CredentialVisibilitySharedVaultNoticeState();
}

class _CredentialVisibilitySharedVaultNoticeState
    extends State<CredentialVisibilitySharedVaultNotice> {
  /// The server's current flag for [CredentialVisibilitySharedVaultNotice.
  /// vaultId], once fetched.
  bool? _serverFlag;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_fetch());
  }

  @override
  void didUpdateWidget(CredentialVisibilitySharedVaultNotice oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.vaultId != widget.vaultId ||
        !identical(oldWidget.app, widget.app)) {
      _serverFlag = null;
      unawaited(_fetch());
    }
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  Future<void> _fetch() async {
    final generation = ++_generation;
    final app = widget.app;
    final vaultId = widget.vaultId;
    final client = app.api;
    if (vaultId == null ||
        client == null ||
        !credentialVisibilitySupported(app)) {
      return;
    }
    try {
      final vaults = await client.vaults();
      if (!mounted ||
          generation != _generation ||
          !identical(app.api, client)) {
        return;
      }
      final match = vaults.where((vault) => vault.id == vaultId).firstOrNull;
      if (match != null) setState(() => _serverFlag = match.adminVisible);
    } on Object {
      // Best effort: the cached descriptor stays authoritative.
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final vaultId = widget.vaultId;
    final active = app.activeVault;
    final vault =
        app.vaults.where((item) => item.id == vaultId).firstOrNull ??
        (active?.id == vaultId ? active : null);
    final adminVisible = _serverFlag ?? vault?.adminVisible ?? false;
    if (vaultId == null || !adminVisible) return const SizedBox.shrink();
    final color = context.palette.orange;
    return Container(
      key: const ValueKey('credential_visibility_shared_vault_notice'),
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: context.palette.warningContainer,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: .45)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.visibility_outlined, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              context.l10n.cvSharedVaultNotice,
              style: const TextStyle(fontSize: 12.5, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}

/// Whether a share flow must ask the server about the recipient before the
/// owner may sign (only servers with the capability can answer).
bool credentialVisibilityShareCheckRequired(AppController app) =>
    credentialVisibilitySupported(app);

enum _RecipientCheck { checking, clear, adminVisible, failed }

/// Before the owner shares [vaultId] with the account behind
/// [recipientDeviceId] (a Vault invitation): asks the server whether that
/// account is admin-visible. Sharing with it makes the whole Vault, the
/// owner's own entries included, readable by administrators, so the warning
/// must be confirmed explicitly. A failed check is treated the same way.
///
/// [onChanged] reports, only after the check finished or the owner ticked or
/// cleared the confirmation, whether sharing may proceed. Callers start from
/// `!credentialVisibilityShareCheckRequired(app)`.
class CredentialVisibilityShareRecipientGate extends StatefulWidget {
  const CredentialVisibilityShareRecipientGate({
    required this.app,
    required this.vaultId,
    required this.recipientDeviceId,
    required this.recipientName,
    required this.onChanged,
    super.key,
  });

  final AppController app;
  final String? vaultId;
  final String recipientDeviceId;
  final String recipientName;
  final ValueChanged<bool> onChanged;

  @override
  State<CredentialVisibilityShareRecipientGate> createState() =>
      _CredentialVisibilityShareRecipientGateState();
}

class _CredentialVisibilityShareRecipientGateState
    extends State<CredentialVisibilityShareRecipientGate> {
  _RecipientCheck _check = _RecipientCheck.checking;
  bool _confirmed = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_fetch());
  }

  @override
  void didUpdateWidget(CredentialVisibilityShareRecipientGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.vaultId != widget.vaultId ||
        oldWidget.recipientDeviceId != widget.recipientDeviceId ||
        !identical(oldWidget.app, widget.app)) {
      _check = _RecipientCheck.checking;
      _confirmed = false;
      unawaited(_fetch());
    }
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  Future<void> _fetch() async {
    final generation = ++_generation;
    final app = widget.app;
    final client = app.api;
    final vaultId = widget.vaultId;
    // Never report synchronously: this also runs while the parent builds.
    await Future<void>.value();
    if (!credentialVisibilityShareCheckRequired(app)) {
      _settle(generation, _RecipientCheck.clear);
      return;
    }
    if (client == null || vaultId == null) {
      _settle(generation, _RecipientCheck.failed);
      return;
    }
    try {
      final answer = await CredentialVisibilityApi(client)
          .shareRecipient(vaultId: vaultId, deviceId: widget.recipientDeviceId);
      if (!identical(app.api, client)) return;
      _settle(
        generation,
        answer.recipientAdminVisible
            ? _RecipientCheck.adminVisible
            : _RecipientCheck.clear,
      );
    } on Object {
      _settle(generation, _RecipientCheck.failed);
    }
  }

  void _settle(int generation, _RecipientCheck check) {
    if (!mounted || generation != _generation) return;
    setState(() {
      _check = check;
      _confirmed = false;
    });
    widget.onChanged(check == _RecipientCheck.clear);
  }

  void _confirm(bool value) {
    setState(() => _confirmed = value);
    widget.onChanged(value);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    switch (_check) {
      case _RecipientCheck.clear:
        return const SizedBox.shrink();
      case _RecipientCheck.checking:
        return Padding(
          key: const ValueKey('credential_visibility_share_checking'),
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.cvShareRecipientChecking,
                  style: TextStyle(color: context.palette.muted, fontSize: 12),
                ),
              ),
            ],
          ),
        );
      case _RecipientCheck.adminVisible:
      case _RecipientCheck.failed:
        final adminVisible = _check == _RecipientCheck.adminVisible;
        final color = context.palette.orange;
        return Container(
          key: ValueKey(
            adminVisible
                ? 'credential_visibility_share_recipient_admin_visible'
                : 'credential_visibility_share_check_failed',
          ),
          margin: const EdgeInsets.symmetric(vertical: 8),
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
          decoration: BoxDecoration(
            color: context.palette.warningContainer,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: color.withValues(alpha: .45)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.warning_amber_rounded, size: 18, color: color),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (adminVisible)
                          Text(
                            l10n.cvShareRecipientAdminVisibleTitle,
                            style: TextStyle(
                              color: color,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        Text(
                          adminVisible
                              ? l10n.cvShareRecipientAdminVisibleBody(
                                  widget.recipientName,
                                )
                              : l10n.cvShareRecipientCheckFailed,
                          style: const TextStyle(fontSize: 12.5, height: 1.45),
                        ),
                      ],
                    ),
                  ),
                  if (!adminVisible)
                    IconButton(
                      key: const ValueKey(
                        'credential_visibility_share_check_retry',
                      ),
                      tooltip: l10n.refresh,
                      onPressed: () {
                        setState(() => _check = _RecipientCheck.checking);
                        widget.onChanged(false);
                        unawaited(_fetch());
                      },
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                    ),
                ],
              ),
              // Its own Material: the tinted box would hide the tile's ink.
              Material(
                type: MaterialType.transparency,
                child: CheckboxListTile(
                  key: const ValueKey('credential_visibility_share_confirm'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _confirmed,
                  onChanged: (value) => _confirm(value ?? false),
                  title: Text(
                    l10n.cvShareRecipientConfirm,
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ),
              ),
            ],
          ),
        );
    }
  }
}

/// Inline warning for an organization grantee the server reports as
/// admin-visible (key-distribution `admin_visible`).
class CredentialVisibilityGranteeWarning extends StatelessWidget {
  const CredentialVisibilityGranteeWarning({
    required this.recipientName,
    super.key,
  });

  final String recipientName;

  @override
  Widget build(BuildContext context) {
    final color = context.palette.orange;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.visibility_outlined, size: 16, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              context.l10n.cvShareRecipientAdminVisibleBody(recipientName),
              style: TextStyle(color: color, fontSize: 12.5, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

/// Explicit confirmation before delivering a Vault key to an admin-visible
/// account. Returns true only when the owner chose to share anyway.
Future<bool> confirmCredentialVisibilityRecipient(
  BuildContext context, {
  required String recipientName,
}) async {
  final confirmed = await showAppDialog<bool>(
    context: context,
    builder: (dialogContext) {
      final l10n = dialogContext.l10n;
      final color = dialogContext.palette.orange;
      return AlertDialog(
        key: const ValueKey('credential_visibility_share_confirm_dialog'),
        icon: Icon(Icons.warning_amber_rounded, color: color),
        title: Text(l10n.cvShareRecipientAdminVisibleTitle),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Text(
            l10n.cvShareRecipientAdminVisibleBody(recipientName),
            style: const TextStyle(height: 1.45),
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('credential_visibility_share_cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            key: const ValueKey('credential_visibility_share_anyway'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.cvShareAnyway),
          ),
        ],
      );
    },
  );
  return confirmed ?? false;
}

/// The account settings card, or null when the server lacks the capability.
Widget? credentialVisibilityAccountControls(AppController app) =>
    credentialVisibilitySupported(app)
    ? CredentialVisibilitySettingsCard(app: app)
    : null;
