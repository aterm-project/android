import 'dart:async';

import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../l10n/l10n.dart';
import 'credential_visibility/credential_visibility_widgets.dart';
import '../storage/workspace_mode.dart';
import 'app_motion.dart';
import 'settings_scaffold.dart';
import 'sync_settings.dart';
import 'workspace_mode_settings.dart';

/// Settings category id shared by the account and local settings pages.
const accountSettingsSectionId = 'account';

/// Category id of the existing password/MFA/recovery/deletion page.
const accountSecuritySectionId = 'security';

/// Non-secret identity of the signed-in account session shown in Settings.
/// Built from [AppController] by [AccountSettingsPanel]; tests can build it
/// directly. It must never carry passwords, tokens or key material.
@immutable
class AccountSessionSummary {
  const AccountSessionSummary({
    required this.username,
    required this.serverUrl,
    required this.accountId,
    required this.deviceId,
    required this.vaultName,
    required this.instanceAdmin,
  });

  factory AccountSessionSummary.fromController(AppController app) {
    final vault = app.activeVault;
    return AccountSessionSummary(
      username: app.authenticatedUsername,
      serverUrl: app.serverUrl,
      accountId: app.currentAccountId,
      deviceId: app.identity?.deviceId ?? app.session?.deviceId,
      vaultName: vault == null ? null : app.vaultNameFor(vault.id),
      instanceAdmin: app.isInstanceAdmin,
    );
  }

  final String? username;
  final String? serverUrl;
  final String? accountId;
  final String? deviceId;
  final String? vaultName;
  final bool instanceAdmin;
}

/// Account category for a signed-in, unlocked account workspace. Every action
/// goes through the controller's existing lifecycle (lock, logout) or the
/// app-level workspace mode switch; nothing here authenticates on its own.
class AccountSettingsPanel extends StatelessWidget {
  const AccountSettingsPanel({
    required this.app,
    this.cloudAccessControls,
    super.key,
  });

  final AppController app;

  /// Capability-gated cloud controls supplied by the account shell.
  final Widget? cloudAccessControls;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) => AccountSettingsView(
      summary: AccountSessionSummary.fromController(app),
      busy: app.busy,
      onLock: app.lock,
      onSignOut: app.logout,
      describeError: app.friendlyError,
      syncControls: SyncSettingsPanel(app: app),
      cloudAccessControls: cloudAccessControls,
      // credential-visibility: mode, escrow status and admin views.
      credentialVisibilityControls: credentialVisibilityAccountControls(app),
    ),
  );
}

class AccountSettingsView extends StatefulWidget {
  const AccountSettingsView({
    required this.summary,
    required this.onLock,
    required this.onSignOut,
    required this.describeError,
    this.busy = false,
    this.syncControls,
    this.cloudAccessControls,
    this.credentialVisibilityControls,
    super.key,
  });

  final AccountSessionSummary summary;
  final Future<void> Function() onLock;
  final Future<void> Function() onSignOut;
  final String Function(Object error) describeError;
  final bool busy;

  /// SYNC worker: automatic sync switch and Sync now, between the identity
  /// and session cards.
  final Widget? syncControls;

  /// Optional capability card before the existing session actions.
  final Widget? cloudAccessControls;

  /// credential-visibility: capability-gated card after the identity card.
  final Widget? credentialVisibilityControls;

  @override
  State<AccountSettingsView> createState() => _AccountSettingsViewState();
}

class _AccountSettingsViewState extends State<AccountSettingsView> {
  bool _acting = false;

  static String _scopeKey(AccountSessionSummary summary) =>
      '${summary.serverUrl}\u0000${summary.accountId}\u0000${summary.deviceId}';

  Future<void> _run(
    Future<void> Function() action, {
    String? confirmTitle,
    String? confirmBody,
    String? confirmLabel,
  }) async {
    if (_acting || widget.busy) return;
    if (confirmTitle != null) {
      final scope = _scopeKey(widget.summary);
      final confirmed = await _confirmAccountAction(
        context,
        title: confirmTitle,
        body: confirmBody!,
        confirmLabel: confirmLabel!,
      );
      // The dialog is an await: never apply a confirmation given for one
      // account/server session to whichever session is current afterwards.
      if (!confirmed || !mounted || _scopeKey(widget.summary) != scope) {
        return;
      }
    }
    setState(() => _acting = true);
    try {
      await action();
    } on Object catch (error) {
      if (mounted) {
        _showAccountMessage(context, widget.describeError(error));
      }
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  Future<void> _switchToLocal(WorkspaceModeScope scope) => _run(
    scope.onSwitch,
    confirmTitle: context.l10n.accountSettingsSwitchToLocalTitle,
    confirmBody: context.l10n.accountSettingsSwitchToLocalBody,
    confirmLabel: context.l10n.switchToLocalMode,
  );

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final summary = widget.summary;
    final scope = WorkspaceModeScope.of(context);
    final disabled = _acting || widget.busy;
    final canSwitchMode =
        scope != null && scope.mode == WorkspaceMode.server && !scope.busy;
    return SettingsCards(
      children: [
        SettingsCard(
          child: Column(
            key: const ValueKey('account_settings_signed_in'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CircleAvatar(
                    backgroundColor: scheme.primaryContainer,
                    foregroundColor: scheme.onPrimaryContainer,
                    child: const Icon(Icons.person_outline),
                  ),
                  const SizedBox(width: 14),
                  // Identity, session state and the admin badge share the
                  // remaining width and wrap, so long names and translated
                  // labels never push the card past a narrow window.
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          summary.username ?? summary.accountId ?? '—',
                          key: const ValueKey('account_settings_identity'),
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          l10n.accountSettingsSessionUnlocked,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        if (summary.instanceAdmin) ...[
                          const SizedBox(height: 8),
                          _AccountBadge(
                            key: const ValueKey('account_settings_admin_badge'),
                            icon: Icons.admin_panel_settings_outlined,
                            label: l10n.accountSettingsInstanceAdmin,
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _AccountDetailRow(
                label: l10n.accountSettingsCurrentMode,
                value: l10n.accountSettingsModeAccount,
              ),
              _AccountDetailRow(
                label: l10n.accountSettingsServer,
                value: summary.serverUrl ?? '—',
                valueKey: const ValueKey('account_settings_server'),
              ),
              _AccountDetailRow(
                label: l10n.accountSettingsSignedInAs,
                value: summary.username ?? '—',
              ),
              _AccountDetailRow(
                label: l10n.accountId,
                value: summary.accountId ?? '—',
              ),
              _AccountDetailRow(
                label: l10n.deviceId,
                value: summary.deviceId ?? '—',
              ),
              _AccountDetailRow(
                label: l10n.accountSettingsActiveVault,
                value: summary.vaultName ?? l10n.accountSettingsNoVault,
              ),
            ],
          ),
        ),
        ?widget.credentialVisibilityControls,
        ?widget.syncControls,
        ?widget.cloudAccessControls,
        SettingsCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.accountSettingsSessionActions,
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  FilledButton.tonalIcon(
                    key: const ValueKey('account_settings_open_security'),
                    onPressed: () => SettingsScaffold.selectSection(
                      context,
                      accountSecuritySectionId,
                    ),
                    icon: const Icon(Icons.shield_outlined),
                    label: Text(l10n.accountSettingsSecurityAction),
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('account_settings_lock'),
                    onPressed: disabled ? null : () => _run(widget.onLock),
                    icon: const Icon(Icons.lock_outline),
                    label: Text(l10n.lockWorkspace),
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('account_settings_sign_out'),
                    onPressed: disabled
                        ? null
                        : () => _run(
                            widget.onSignOut,
                            confirmTitle: l10n.accountSettingsSignOutTitle,
                            confirmBody: l10n.accountSettingsSignOutBody,
                            confirmLabel: l10n.signOut,
                          ),
                    icon: const Icon(Icons.logout),
                    label: Text(l10n.signOut),
                  ),
                  if (scope != null && scope.mode == WorkspaceMode.server)
                    TextButton.icon(
                      key: const ValueKey('account_settings_switch_local'),
                      onPressed: disabled || !canSwitchMode
                          ? null
                          : () => _switchToLocal(scope),
                      icon: const Icon(Icons.swap_horiz),
                      label: Text(l10n.switchToLocalMode),
                    ),
                ],
              ),
              if (disabled) ...[
                const SizedBox(height: 12),
                const LinearProgressIndicator(),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Account category while a local-only profile workspace is active. It never
/// pretends to sync; the only action routes through the app's existing
/// workspace switch, which locks the local profile and opens the account
/// server/sign-in flow (or restores this device's stored account session).
class LocalAccountSettingsPanel extends StatefulWidget {
  const LocalAccountSettingsPanel({required this.onSignIn, super.key});

  /// The local workspace's exit/switch path (LocalProfileFlow._exit). It owns
  /// closing local sessions and locking the profile before the mode changes.
  final FutureOr<void> Function() onSignIn;

  @override
  State<LocalAccountSettingsPanel> createState() =>
      _LocalAccountSettingsPanelState();
}

class _LocalAccountSettingsPanelState extends State<LocalAccountSettingsPanel> {
  bool _switching = false;

  Future<void> _signIn() async {
    if (_switching) return;
    final l10n = context.l10n;
    final confirmed = await _confirmAccountAction(
      context,
      title: l10n.accountSettingsSignInTitle,
      body: l10n.accountSettingsSignInBody,
      confirmLabel: l10n.continueLabel,
    );
    if (!confirmed || !mounted) return;
    setState(() => _switching = true);
    try {
      await widget.onSignIn();
    } on Object {
      if (mounted) {
        _showAccountMessage(context, context.l10n.couldntSwitchTheWorkspaceModeCheck);
      }
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final scope = WorkspaceModeScope.of(context);
    final busy = _switching || (scope?.busy ?? false);
    return SettingsCard(
      child: Column(
        key: const ValueKey('account_settings_local'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                backgroundColor: scheme.surfaceContainerHighest,
                foregroundColor: scheme.onSurfaceVariant,
                child: const Icon(Icons.person_off_outlined),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  l10n.accountSettingsLocalNotSignedIn,
                  style: theme.textTheme.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _AccountDetailRow(
            label: l10n.accountSettingsCurrentMode,
            value: l10n.accountSettingsModeLocal,
          ),
          const SizedBox(height: 8),
          Text(
            l10n.accountSettingsLocalSyncRequiresAccount,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const ValueKey('account_settings_local_sign_in'),
            onPressed: busy ? null : _signIn,
            icon: const Icon(Icons.login),
            label: Text(l10n.accountSettingsSignIn),
          ),
          if (busy) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
          ],
        ],
      ),
    );
  }
}

class _AccountDetailRow extends StatelessWidget {
  const _AccountDetailRow({
    required this.label,
    required this.value,
    this.valueKey,
  });

  final String label;
  final String value;
  final Key? valueKey;

  /// Below this width the label sits above its value instead of beside it.
  static const _stackBelow = 360.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final labelText = Text(
      label,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
    final valueText = SelectableText(
      value,
      key: valueKey,
      style: theme.textTheme.bodyMedium,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < _stackBelow) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [labelText, const SizedBox(height: 2), valueText],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 140, child: labelText),
              const SizedBox(width: 8),
              Expanded(child: valueText),
            ],
          );
        },
      ),
    );
  }
}

/// Compact status badge whose label wraps instead of forcing its intrinsic
/// width (a Material [Chip] cannot shrink below its label).
class _AccountBadge extends StatelessWidget {
  const _AccountBadge({required this.icon, required this.label, super.key});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: scheme.onSecondaryContainer),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.onSecondaryContainer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<bool> _confirmAccountAction(
  BuildContext context, {
  required String title,
  required String body,
  required String confirmLabel,
}) async {
  final result = await showAppDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Text(body),
      ),
      actions: [
        TextButton(
          key: const ValueKey('account_settings_confirm_cancel'),
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(dialogContext.l10n.cancel),
        ),
        FilledButton(
          key: const ValueKey('account_settings_confirm'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}

void _showAccountMessage(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(content: Text(message)),
  );
}
