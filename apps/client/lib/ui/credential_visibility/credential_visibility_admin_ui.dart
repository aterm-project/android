// Instance-admin UI for Credential visibility v1: default mode, escrow key
// setup / recovery-code unlock / reset, per-account mode controls, the
// invitation mode selector and the read-only credential viewer.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../api/api_client.dart';
import '../../app_controller.dart';
import '../../credential_visibility/credential_escrow_admin.dart';
import '../../credential_visibility/credential_escrow_crypto.dart';
import '../../credential_visibility/credential_visibility_models.dart';
import '../../credential_visibility/credential_visibility_service.dart';
import '../../credential_visibility/sensitive_clipboard.dart';
import '../../crypto/vault_crypto.dart' show DeviceIdentity;
import '../../domain/models.dart';
import '../../l10n/l10n.dart';
import '../app_density.dart';
import '../app_motion.dart';
import '../app_theme.dart';
import '../settings_scaffold.dart';
import 'credential_visibility_widgets.dart';
import 'database_encryption_status.dart';

/// The literal the admin types to confirm an escrow reset (also the wire
/// `confirm` value). Not localized on purpose.
const credentialEscrowResetWord = 'reset';

String credentialEscrowAdminErrorText(AppController app, Object error) {
  final l10n = currentL10n;
  if (error is CredentialEscrowAdminException) {
    return switch (error.code) {
      'wrong_password' => l10n.cvErrorWrongPassword,
      'wrong_recovery_code' => l10n.cvErrorWrongRecoveryCode,
      'no_key' => l10n.cvErrorNoKey,
      'key_exists' => l10n.cvErrorKeyExists,
      'key_invalid' => l10n.cvAdminKeyInvalid,
      'wrap_missing' => l10n.cvAdminKeyNoWrap,
      'wrap_invalid' => l10n.cvErrorWrapInvalid,
      'not_available' => l10n.cvErrorNotAvailable,
      'not_admin' => l10n.cvErrorNotAdmin,
      'signed_out' => l10n.cvErrorSignedOut,
      _ => l10n.cvErrorScopeChanged,
    };
  }
  if (error is ApiException) {
    switch (error.code) {
      case 'CREDENTIAL_ESCROW_KEY_EXISTS':
        return l10n.cvErrorKeyExists;
      case 'CREDENTIAL_ESCROW_NOT_AVAILABLE':
        return l10n.cvErrorNotAvailable;
      case 'CREDENTIAL_ESCROW_KEY_MISMATCH':
        return l10n.cvErrorNoKey;
    }
  }
  return app.friendlyError(error);
}

void _snack(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(context)
      ?.showSnackBar(SnackBar(content: Text(message)));
}

/// Asks for the admin's master password. Returns null when cancelled. The
/// password is only used locally to derive the account key.
Future<String?> promptCredentialEscrowPassword(BuildContext context) async {
  final controller = TextEditingController();
  try {
    return await showAppDialog<String>(
      context: context,
      builder: (dialogContext) {
        final l10n = dialogContext.l10n;
        void submit() {
          if (controller.text.isEmpty) return;
          Navigator.of(dialogContext).pop(controller.text);
        }

        return AlertDialog(
          title: Text(l10n.cvAdminPasswordTitle),
          content: SizedBox(
            width: appDialogWidth(dialogContext, 440),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.cvAdminPasswordBody,
                  style: const TextStyle(height: 1.45),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('credential_escrow_password'),
                  controller: controller,
                  obscureText: true,
                  autofocus: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: l10n.cvMasterPassword,
                    border: const OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => submit(),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              key: const ValueKey('credential_escrow_password_continue'),
              onPressed: submit,
              child: Text(l10n.continueLabel),
            ),
          ],
        );
      },
    );
  } finally {
    controller.dispose();
  }
}

/// Settings card with the instance default, counts and escrow key controls.
class CredentialVisibilityAdminCard extends StatefulWidget {
  const CredentialVisibilityAdminCard({
    required this.app,
    this.adminForTesting,
    super.key,
  });

  final AppController app;
  final CredentialEscrowAdmin? adminForTesting;

  @override
  State<CredentialVisibilityAdminCard> createState() =>
      _CredentialVisibilityAdminCardState();
}

class _CredentialVisibilityAdminCardState
    extends State<CredentialVisibilityAdminCard> {
  late final CredentialEscrowAdmin _admin =
      widget.adminForTesting ?? CredentialEscrowAdmin(widget.app);
  AdminCredentialVisibilityOverview? _overview;
  VerifiedEscrowKey? _key;
  bool _keyInvalid = false;

  /// `database_encryption` from the instance overview; null until loaded or
  /// when the server does not report it.
  String? _databaseEncryption;
  bool _busy = false;
  String? _error;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on Object catch (error) {
      if (mounted) {
        setState(
          () => _error = credentialEscrowAdminErrorText(widget.app, error),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _apply(AdminCredentialVisibilityOverview overview) {
    VerifiedEscrowKey? key;
    var invalid = false;
    final descriptor = overview.escrowKey;
    if (descriptor != null) {
      try {
        key = _admin.verifyKey(descriptor);
      } on CredentialEscrowAdminException {
        invalid = true;
      }
    }
    setState(() {
      _overview = overview;
      _key = key;
      _keyInvalid = invalid;
    });
  }

  Future<void> _load() => _run(() async {
    final overview = await _admin.loadOverview();
    if (mounted) _apply(overview);
    await _loadDatabaseEncryption();
  });

  /// Best effort: the escrow controls work without it.
  Future<void> _loadDatabaseEncryption() async {
    try {
      final value = await _admin.loadDatabaseEncryption();
      if (mounted) setState(() => _databaseEncryption = value);
    } on Object {
      // Leave the last known value; nothing is shown when unknown.
    }
  }

  Future<void> _setDefault(CredentialVisibilityMode mode) => _run(() async {
    final overview = await _admin.setDefaultMode(mode);
    if (mounted) _apply(overview);
  });

  Future<void> _createKey() async {
    final password = await promptCredentialEscrowPassword(context);
    if (password == null || !mounted) return;
    PreparedEscrowKey? prepared;
    await _run(() async {
      prepared = await _admin.prepareEscrowKey(password);
    });
    final ready = prepared;
    if (ready == null || !mounted) return;
    final confirmed = await showAppDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => CredentialEscrowRecoveryCodeDialog(prepared: ready),
    );
    ready.discardRecoveryCode();
    if (confirmed != true || !mounted) return;
    await _run(() async {
      await _admin.uploadEscrowKey(ready);
      if (mounted) _snack(context, context.l10n.cvAdminKeyCreated);
      final overview = await _admin.loadOverview();
      if (mounted) _apply(overview);
    });
  }

  Future<void> _unlock() async {
    final recoveryCode = await showAppDialog<String>(
      context: context,
      builder: (_) => const _RecoveryCodeEntryDialog(),
    );
    if (recoveryCode == null || !mounted) return;
    final password = await promptCredentialEscrowPassword(context);
    if (password == null || !mounted) return;
    await _run(() async {
      await _admin.unlockWithRecoveryCode(
        recoveryCode: recoveryCode,
        password: password,
      );
      if (mounted) _snack(context, context.l10n.cvAdminUnlocked);
      final overview = await _admin.loadOverview();
      if (mounted) _apply(overview);
    });
  }

  Future<void> _reset() async {
    final keyId = _overview?.escrowKey?.keyId;
    if (keyId == null) return;
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (_) => const _ResetEscrowDialog(),
    );
    if (confirmed != true || !mounted) return;
    await _run(() async {
      await _admin.resetEscrowKey(keyId);
      if (mounted) _snack(context, context.l10n.cvAdminResetDone);
      final overview = await _admin.loadOverview();
      if (mounted) _apply(overview);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final overview = _overview;
    final muted = TextStyle(
      color: context.palette.muted,
      fontSize: 12,
      height: 1.45,
    );
    return SettingsCard(
      semanticContainer: false,
      child: Column(
        key: const ValueKey('credential_visibility_admin_card'),
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
              IconButton(
                key: const ValueKey('credential_visibility_admin_load'),
                tooltip: l10n.cvAdminLoad,
                onPressed: _busy ? null : _load,
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
          Text(l10n.cvAdminDescription, style: muted),
          if (overview != null) ...[
            const SizedBox(height: 14),
            DropdownButtonFormField<CredentialVisibilityMode>(
              key: const ValueKey('credential_visibility_admin_default'),
              initialValue: overview.defaultMode,
              decoration: InputDecoration(
                labelText: l10n.cvAdminDefaultMode,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              items: [
                for (final mode in CredentialVisibilityMode.values)
                  DropdownMenuItem(
                    value: mode,
                    child: Text(credentialVisibilityModeLabel(l10n, mode)),
                  ),
              ],
              onChanged: _busy
                  ? null
                  : (mode) {
                      if (mode != null && mode != overview.defaultMode) {
                        unawaited(_setDefault(mode));
                      }
                    },
            ),
            const SizedBox(height: 8),
            Text(
              l10n.cvAdminCounts(
                overview.counts.adminVisible,
                overview.counts.private,
                overview.counts.pending,
              ),
              key: const ValueKey('credential_visibility_admin_counts'),
              style: muted,
            ),
            // An escrow key on a plaintext database is the main offline
            // attack target (see docs/CREDENTIAL-VISIBILITY.md).
            DatabaseEncryptionStatus(databaseEncryption: _databaseEncryption),
            const SizedBox(height: 14),
            Text(l10n.cvAdminKeyTitle, style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            if (overview.escrowKey == null)
              Text(l10n.cvAdminKeyMissing, style: muted)
            else if (_keyInvalid)
              Text(
                l10n.cvAdminKeyInvalid,
                key: const ValueKey('credential_visibility_admin_key_invalid'),
                style: TextStyle(color: context.palette.red),
              )
            else if (_key case final key?) ...[
              SelectableText(
                l10n.cvAdminKeyReady(
                  key.keyId,
                  formatCredentialVisibilityTime(
                    DateTime.tryParse(key.createdAt) ?? DateTime.now(),
                  ),
                ),
                style: muted,
              ),
              if (overview.callerWrap == null)
                Text(
                  l10n.cvAdminKeyNoWrap,
                  key: const ValueKey('credential_visibility_admin_no_wrap'),
                  style: TextStyle(color: context.palette.orange),
                ),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                if (overview.escrowKey == null)
                  FilledButton.icon(
                    key: const ValueKey(
                      'credential_visibility_admin_create_key',
                    ),
                    onPressed: _busy ? null : () => unawaited(_createKey()),
                    icon: const Icon(Icons.key_rounded),
                    label: Text(l10n.cvAdminCreateKey),
                  )
                else ...[
                  if (!_keyInvalid)
                    OutlinedButton.icon(
                      key: const ValueKey('credential_visibility_admin_unlock'),
                      onPressed: _busy ? null : () => unawaited(_unlock()),
                      icon: const Icon(Icons.lock_open_rounded),
                      label: Text(l10n.cvAdminUnlockWithRecovery),
                    ),
                  TextButton.icon(
                    key: const ValueKey('credential_visibility_admin_reset'),
                    style: TextButton.styleFrom(
                      foregroundColor: context.palette.red,
                    ),
                    onPressed: _busy ? null : () => unawaited(_reset()),
                    icon: const Icon(Icons.delete_forever_outlined),
                    label: Text(l10n.cvAdminResetKey),
                  ),
                ],
              ],
            ),
          ],
          if (_error case final error?) ...[
            const SizedBox(height: 10),
            Text(error, style: TextStyle(color: context.palette.red)),
          ],
          if (_busy) ...[
            const SizedBox(height: 10),
            const LinearProgressIndicator(),
          ],
        ],
      ),
    );
  }
}

/// Shows the new recovery code once; returns true after "I have stored it".
class CredentialEscrowRecoveryCodeDialog extends StatefulWidget {
  const CredentialEscrowRecoveryCodeDialog({required this.prepared, super.key});

  final PreparedEscrowKey prepared;

  @override
  State<CredentialEscrowRecoveryCodeDialog> createState() =>
      _CredentialEscrowRecoveryCodeDialogState();
}

class _CredentialEscrowRecoveryCodeDialogState
    extends State<CredentialEscrowRecoveryCodeDialog> {
  bool _stored = false;

  /// The code leaves the clipboard after a minute or when the dialog closes.
  final _clipboard = SensitiveClipboard();

  @override
  void dispose() {
    _clipboard.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final code = widget.prepared.recoveryCode ?? '';
    return AlertDialog(
      title: Text(l10n.cvAdminRecoveryTitle),
      content: SizedBox(
        width: appDialogWidth(context, 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.cvAdminRecoveryBody,
              style: const TextStyle(height: 1.45),
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: context.palette.codeBackground,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                code,
                key: const ValueKey('credential_escrow_recovery_code'),
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 15,
                  letterSpacing: 1,
                  color: context.palette.codeText,
                ),
              ),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              key: const ValueKey('credential_escrow_recovery_copy'),
              onPressed: () async {
                await _clipboard.copy(code);
                if (context.mounted) {
                  _snack(
                    context,
                    '${l10n.cvAdminRecoveryCopied}\n${l10n.cvClipboardAutoClear}',
                  );
                }
              },
              icon: const Icon(Icons.copy_rounded),
              label: Text(l10n.copy),
            ),
            CheckboxListTile(
              key: const ValueKey('credential_escrow_recovery_stored'),
              contentPadding: EdgeInsets.zero,
              value: _stored,
              onChanged: (value) => setState(() => _stored = value ?? false),
              title: Text(l10n.cvAdminRecoveryStored),
              controlAffinity: ListTileControlAffinity.leading,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          key: const ValueKey('credential_escrow_recovery_confirm'),
          onPressed: _stored ? () => Navigator.of(context).pop(true) : null,
          child: Text(l10n.cvAdminCreateKey),
        ),
      ],
    );
  }
}

class _RecoveryCodeEntryDialog extends StatefulWidget {
  const _RecoveryCodeEntryDialog();

  @override
  State<_RecoveryCodeEntryDialog> createState() =>
      _RecoveryCodeEntryDialogState();
}

class _RecoveryCodeEntryDialogState extends State<_RecoveryCodeEntryDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.cvAdminUnlockWithRecovery),
      content: SizedBox(
        width: appDialogWidth(context, 440),
        child: TextField(
          key: const ValueKey('credential_escrow_recovery_input'),
          controller: _controller,
          autofocus: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: l10n.cvAdminRecoveryCodeLabel,
            border: const OutlineInputBorder(),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          key: const ValueKey('credential_escrow_recovery_continue'),
          onPressed: () {
            if (_controller.text.trim().isEmpty) return;
            Navigator.of(context).pop(_controller.text);
          },
          child: Text(l10n.continueLabel),
        ),
      ],
    );
  }
}

class _ResetEscrowDialog extends StatefulWidget {
  const _ResetEscrowDialog();

  @override
  State<_ResetEscrowDialog> createState() => _ResetEscrowDialogState();
}

class _ResetEscrowDialogState extends State<_ResetEscrowDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final matches = _controller.text.trim() == credentialEscrowResetWord;
    return AlertDialog(
      title: Text(l10n.cvAdminResetTitle),
      content: SizedBox(
        width: appDialogWidth(context, 460),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l10n.cvAdminResetBody(credentialEscrowResetWord),
              style: const TextStyle(height: 1.45),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('credential_escrow_reset_confirm_input'),
              controller: _controller,
              autocorrect: false,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(border: OutlineInputBorder()),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          key: const ValueKey('credential_escrow_reset_confirm'),
          style: FilledButton.styleFrom(backgroundColor: context.palette.red),
          onPressed: matches ? () => Navigator.of(context).pop(true) : null,
          child: Text(l10n.cvAdminResetKey),
        ),
      ],
    );
  }
}

/// Mode + escrow status of one account in the admin account list, with the
/// mode selector and the "View credentials" action. Hidden on servers
/// without the capability (the account row then has no mode).
class CredentialVisibilityAdminAccountRow extends StatefulWidget {
  const CredentialVisibilityAdminAccountRow({
    required this.app,
    required this.account,
    this.adminForTesting,
    super.key,
  });

  final AppController app;
  final AdminAccountMetadata account;
  final CredentialEscrowAdmin? adminForTesting;

  @override
  State<CredentialVisibilityAdminAccountRow> createState() =>
      _CredentialVisibilityAdminAccountRowState();
}

class _CredentialVisibilityAdminAccountRowState
    extends State<CredentialVisibilityAdminAccountRow> {
  late final CredentialEscrowAdmin _admin =
      widget.adminForTesting ?? CredentialEscrowAdmin(widget.app);
  bool _busy = false;

  Future<void> _setMode(CredentialVisibilityMode mode) async {
    final l10n = context.l10n;
    final username = widget.account.username;
    final adminVisible = mode == CredentialVisibilityMode.adminVisible;
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          adminVisible
              ? l10n.cvAdminConfirmAdminVisibleTitle(username)
              : l10n.cvAdminConfirmPrivateTitle(username),
        ),
        content: SizedBox(
          width: appDialogWidth(dialogContext, 440),
          child: Text(
            adminVisible
                ? l10n.cvAdminConfirmAdminVisibleBody
                : l10n.cvAdminConfirmPrivateBody,
            style: const TextStyle(height: 1.45),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            key: const ValueKey('credential_visibility_admin_mode_confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(credentialVisibilityModeLabel(l10n, mode)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final receipt = await _admin.setAccountMode(
        userId: widget.account.userId,
        mode: mode,
      );
      if (mounted) {
        _snack(
          context,
          l10n.cvAdminModeChanged(
            username,
            credentialVisibilityModeLabel(l10n, receipt.mode),
          ),
        );
      }
      final app = widget.app;
      await app.loadAdminAccounts(offset: app.adminAccountsPage?.offset ?? 0);
      // The admin's own mode is part of /me; refresh the user status too.
      if (app.isCurrentAdminAccount(widget.account.userId)) {
        unawaited(credentialVisibilityFor(app).refresh());
      }
    } on Object catch (error) {
      if (mounted) {
        _snack(context, credentialEscrowAdminErrorText(widget.app, error));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mode = CredentialVisibilityMode.tryParse(
      widget.account.credentialVisibility,
    );
    if (mode == null || !_admin.available) return const SizedBox.shrink();
    final escrow = CredentialEscrowStatus.tryParse(widget.account.escrowStatus);
    final l10n = context.l10n;
    final color = mode == CredentialVisibilityMode.adminVisible
        ? context.palette.orange
        : context.palette.accentText;
    final enabled = !_busy && widget.account.status != 'deleting';
    return Padding(
      key: ValueKey('credential_visibility_admin_row_${widget.account.userId}'),
      padding: const EdgeInsets.only(top: 6, bottom: 2),
      child: Wrap(
        spacing: 10,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            l10n.cvSectionTitle,
            style: TextStyle(color: context.palette.muted, fontSize: 12),
          ),
          PopupMenuButton<CredentialVisibilityMode>(
            key: ValueKey(
              'credential_visibility_admin_mode_${widget.account.userId}',
            ),
            enabled: enabled,
            initialValue: mode,
            tooltip: l10n.cvSectionTitle,
            onSelected: (value) {
              if (value != mode) unawaited(_setMode(value));
            },
            itemBuilder: (_) => [
              for (final value in CredentialVisibilityMode.values)
                PopupMenuItem(
                  value: value,
                  child: Text(credentialVisibilityModeLabel(l10n, value)),
                ),
            ],
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  mode == CredentialVisibilityMode.adminVisible
                      ? Icons.visibility_outlined
                      : Icons.lock_outline,
                  size: 15,
                  color: color,
                ),
                const SizedBox(width: 4),
                Text(
                  credentialVisibilityModeLabel(l10n, mode),
                  style: TextStyle(color: color, fontWeight: FontWeight.w600),
                ),
                const Icon(Icons.arrow_drop_down, size: 18),
              ],
            ),
          ),
          if (escrow != null)
            Text(
              '${l10n.cvEscrowStatusLabel}: ${credentialEscrowStatusLabel(l10n, escrow)}',
              key: ValueKey(
                'credential_visibility_admin_escrow_${widget.account.userId}',
              ),
              style: TextStyle(color: context.palette.muted, fontSize: 12),
            ),
          if (mode == CredentialVisibilityMode.adminVisible)
            TextButton.icon(
              key: ValueKey(
                'credential_visibility_admin_view_${widget.account.userId}',
              ),
              onPressed: enabled
                  ? () => unawaited(
                      showCredentialEscrowViewer(
                        context,
                        widget.app,
                        userId: widget.account.userId,
                        username: widget.account.username,
                        admin: _admin,
                      ),
                    )
                  : null,
              icon: const Icon(Icons.manage_search_rounded, size: 18),
              label: Text(l10n.cvAdminViewCredentials),
            ),
          if (_busy)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
        ],
      ),
    );
  }
}

/// Optional mode selector for the account invitation dialog. `null` means
/// the instance default.
class CredentialVisibilityInvitationField extends StatelessWidget {
  const CredentialVisibilityInvitationField({
    required this.app,
    required this.value,
    required this.onChanged,
    super.key,
  });

  final AppController app;
  final CredentialVisibilityMode? value;
  final ValueChanged<CredentialVisibilityMode?>? onChanged;

  @override
  Widget build(BuildContext context) {
    if (!credentialVisibilitySupported(app)) return const SizedBox.shrink();
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: DropdownButtonFormField<CredentialVisibilityMode?>(
        key: const ValueKey('admin_account_invitation_credential_visibility'),
        initialValue: value,
        decoration: InputDecoration(
          labelText: l10n.cvSectionTitle,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        items: [
          DropdownMenuItem<CredentialVisibilityMode?>(
            value: null,
            child: Text(l10n.cvInstanceDefaultOption),
          ),
          for (final mode in CredentialVisibilityMode.values)
            DropdownMenuItem<CredentialVisibilityMode?>(
              value: mode,
              child: Text(credentialVisibilityModeLabel(l10n, mode)),
            ),
        ],
        onChanged: onChanged,
      ),
    );
  }
}

/// Re-asks the master password, opens the escrow key and shows the target
/// account's Vaults. Every key is released when the dialog closes.
Future<void> showCredentialEscrowViewer(
  BuildContext context,
  AppController app, {
  required String userId,
  required String username,
  CredentialEscrowAdmin? admin,
}) async {
  final password = await promptCredentialEscrowPassword(context);
  if (password == null || !context.mounted) return;
  final escrowAdmin = admin ?? CredentialEscrowAdmin(app);
  CredentialEscrowViewerSession session;
  try {
    session = await escrowAdmin.openViewer(
      password: password,
      targetUserId: userId,
    );
  } on Object catch (error) {
    if (context.mounted) {
      _snack(context, credentialEscrowAdminErrorText(app, error));
    }
    return;
  }
  if (!context.mounted) {
    session.dispose();
    return;
  }
  try {
    await showAppDialog<void>(
      context: context,
      builder: (_) => CredentialEscrowViewerDialog(
        app: app,
        session: session,
        username: username,
      ),
    );
  } finally {
    session.dispose();
  }
}

class CredentialEscrowViewerDialog extends StatefulWidget {
  const CredentialEscrowViewerDialog({
    required this.app,
    required this.session,
    required this.username,
    super.key,
  });

  final AppController app;
  final CredentialEscrowViewerSession session;
  final String username;

  @override
  State<CredentialEscrowViewerDialog> createState() =>
      _CredentialEscrowViewerDialogState();
}

class _CredentialEscrowViewerDialogState
    extends State<CredentialEscrowViewerDialog> {
  List<EscrowViewerVault>? _vaults;
  EscrowViewerVault? _selected;
  EscrowViewerItems? _items;
  bool _busy = false;
  String? _error;

  // The admin session the viewer was opened in. The dialog sits on the root
  // navigator, above the shell that sign-out, revocation or a lock replaces.
  late final ApiClient? _client = widget.app.api;
  late final String? _accountId = widget.app.account?.accountId;
  late final DeviceIdentity? _identity = widget.app.identity;
  bool _closed = false;

  /// Copied secrets leave the clipboard after a minute or when the viewer
  /// closes.
  final _clipboard = SensitiveClipboard();

  @override
  void initState() {
    super.initState();
    widget.app.addListener(_onAppChanged);
    unawaited(_loadVaults());
  }

  @override
  void dispose() {
    widget.app.removeListener(_onAppChanged);
    _clipboard.dispose();
    super.dispose();
  }

  bool get _sessionLost {
    final app = widget.app;
    return widget.session.disposed ||
        app.session == null ||
        app.workspaceLocked ||
        !app.isInstanceAdmin ||
        !identical(app.api, _client) ||
        app.account?.accountId != _accountId ||
        !identical(app.identity, _identity);
  }

  /// Sign-out, session revocation or expiry, a workspace lock or a lost
  /// admin role: release the escrow key and every opened Vault key at once,
  /// drop the decrypted items and close the viewer without an animation.
  void _onAppChanged() {
    if (_closed || !_sessionLost) return;
    _closed = true;
    widget.session.dispose();
    unawaited(_clipboard.clear());
    _vaults = null;
    _selected = null;
    _items = null;
    // Hide the decrypted content on the next frame. A notification that
    // arrives during a build is deferred to after it.
    final scheduler = SchedulerBinding.instance;
    if (scheduler.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      scheduler.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    } else {
      setState(() {});
    }
    // Not from inside the controller's notification, which may run during
    // another navigator operation.
    scheduleMicrotask(() {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route != null && route.isActive) {
        Navigator.of(context).removeRoute(route);
      }
    });
  }

  Future<void> _guard(Future<void> Function() action) async {
    if (_closed) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on Object catch (error) {
      if (mounted) {
        setState(
          () => _error = credentialEscrowAdminErrorText(widget.app, error),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadVaults() => _guard(() async {
    final vaults = await widget.session.loadVaults();
    if (mounted && !_closed) setState(() => _vaults = vaults);
  });

  Future<void> _open(EscrowViewerVault vault) => _guard(() async {
    setState(() {
      _selected = vault;
      _items = null;
    });
    final items = await widget.session.loadItems(vault.vaultId);
    if (mounted && !_closed && identical(_selected, vault)) {
      setState(() => _items = items);
    }
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    if (_closed) return const SizedBox.shrink();
    final selected = _selected;
    final items = _items;
    return AlertDialog(
      key: const ValueKey('credential_escrow_viewer'),
      title: Text(
        l10n.cvViewerTitle(widget.session.username ?? widget.username),
      ),
      content: SizedBox(
        width: appDialogWidth(context, 640),
        height: 520,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              key: const ValueKey('credential_escrow_viewer_banner'),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: context.palette.warningContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.visibility_outlined,
                    color: context.palette.orange,
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(l10n.cvViewerBanner)),
                  Text(
                    l10n.cvViewerReadOnly,
                    style: TextStyle(
                      color: context.palette.muted,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            if (_busy) const LinearProgressIndicator(),
            if (_error case final error?)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  error,
                  style: TextStyle(color: context.palette.red),
                ),
              ),
            const SizedBox(height: 8),
            Expanded(
              child: selected == null
                  ? _vaultList(context)
                  : _itemList(context, selected, items),
            ),
          ],
        ),
      ),
      actions: [
        if (selected != null)
          TextButton.icon(
            onPressed: _busy
                ? null
                : () => setState(() {
                    _selected = null;
                    _items = null;
                    _error = null;
                  }),
            icon: const Icon(Icons.arrow_back_rounded),
            label: Text(l10n.cvViewerVaults),
          ),
        FilledButton(
          key: const ValueKey('credential_escrow_viewer_close'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.close),
        ),
      ],
    );
  }

  Widget _vaultList(BuildContext context) {
    final l10n = context.l10n;
    final vaults = _vaults;
    if (vaults == null) return const SizedBox.shrink();
    if (vaults.isEmpty) return Text(l10n.cvViewerNoVaults);
    return ListView(
      children: [
        for (final vault in vaults)
          ListTile(
            key: ValueKey('credential_escrow_viewer_vault_${vault.vaultId}'),
            leading: Icon(
              vault.readable
                  ? Icons.folder_open_outlined
                  : Icons.folder_off_outlined,
            ),
            title: Text(vault.name ?? l10n.cvViewerVaultUnnamed(vault.vaultId)),
            subtitle: vault.readable
                ? null
                : Text(l10n.cvViewerVaultNotEscrowed),
            trailing: vault.readable
                ? TextButton(
                    onPressed: _busy ? null : () => unawaited(_open(vault)),
                    child: Text(l10n.cvViewerOpenVault),
                  )
                : null,
          ),
      ],
    );
  }

  Widget _itemList(
    BuildContext context,
    EscrowViewerVault vault,
    EscrowViewerItems? items,
  ) {
    final l10n = context.l10n;
    if (items == null) return const SizedBox.shrink();
    final credentialsById = {
      for (final credential in items.credentials) credential.id: credential,
    };
    return ListView(
      children: [
        Text(
          vault.name ?? l10n.cvViewerVaultUnnamed(vault.vaultId),
          style: Theme.of(context).textTheme.titleSmall,
        ),
        if (items.undecryptable > 0)
          Text(
            l10n.cvViewerUndecryptable(items.undecryptable),
            style: TextStyle(color: context.palette.orange, fontSize: 12),
          ),
        if (items.hosts.isEmpty && items.credentials.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(l10n.cvViewerNoItems),
          ),
        if (items.hosts.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(
            l10n.cvViewerHosts,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          for (final host in items.hosts)
            _EscrowHostTile(
              host: host,
              keychainName: credentialsById[host.credentialId]?.name,
              clipboard: _clipboard,
            ),
        ],
        if (items.credentials.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(
            l10n.cvViewerKeychain,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          for (final credential in items.credentials)
            _EscrowCredentialTile(
              credential: credential,
              clipboard: _clipboard,
            ),
        ],
      ],
    );
  }
}

class _EscrowHostTile extends StatelessWidget {
  const _EscrowHostTile({
    required this.host,
    required this.clipboard,
    this.keychainName,
  });

  final HostRecord host;
  final SensitiveClipboard clipboard;
  final String? keychainName;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final login = host.login;
    return Card(
      key: ValueKey('credential_escrow_viewer_host_${host.id}'),
      margin: const EdgeInsets.only(top: 6),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              host.name,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            _EscrowField(
              label: l10n.cvViewerAddress,
              value:
                  '${host.address}:${host.port} · ${host.protocol.name.toUpperCase()}',
            ),
            if (host.username.isNotEmpty)
              _EscrowField(label: l10n.cvViewerUsername, value: host.username),
            if (login?.password case final password?)
              _EscrowField(
                label: l10n.cvViewerPassword,
                value: password,
                secret: true,
                clipboard: clipboard,
              ),
            if (login?.privateKey case final privateKey?)
              _EscrowField(
                label: l10n.cvViewerPrivateKey,
                value: privateKey,
                secret: true,
                clipboard: clipboard,
              ),
            if (login?.passphrase case final passphrase?)
              _EscrowField(
                label: l10n.cvViewerPassphrase,
                value: passphrase,
                secret: true,
                clipboard: clipboard,
              ),
            if (host.credentialId != null)
              Text(
                l10n.cvViewerUsesKeychain(keychainName ?? host.credentialId!),
                style: TextStyle(color: context.palette.muted, fontSize: 12),
              ),
          ],
        ),
      ),
    );
  }
}

class _EscrowCredentialTile extends StatelessWidget {
  const _EscrowCredentialTile({
    required this.credential,
    required this.clipboard,
  });

  final CredentialRecord credential;
  final SensitiveClipboard clipboard;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Card(
      key: ValueKey('credential_escrow_viewer_credential_${credential.id}'),
      margin: const EdgeInsets.only(top: 6),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              credential.name,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            if (credential.username.isNotEmpty)
              _EscrowField(
                label: l10n.cvViewerUsername,
                value: credential.username,
              ),
            if (credential.secret case final secret?)
              _EscrowField(
                label: l10n.cvViewerPassword,
                value: secret,
                secret: true,
                clipboard: clipboard,
              ),
            if (credential.privateKey case final privateKey?)
              _EscrowField(
                label: l10n.cvViewerPrivateKey,
                value: privateKey,
                secret: true,
                clipboard: clipboard,
              ),
            if (credential.passphrase case final passphrase?)
              _EscrowField(
                label: l10n.cvViewerPassphrase,
                value: passphrase,
                secret: true,
                clipboard: clipboard,
              ),
          ],
        ),
      ),
    );
  }
}

/// One labelled value; secrets are masked until revealed and can be copied.
class _EscrowField extends StatefulWidget {
  const _EscrowField({
    required this.label,
    required this.value,
    this.secret = false,
    this.clipboard,
  }) : assert(!secret || clipboard != null);

  final String label;
  final String value;
  final bool secret;

  /// Owned by the viewer; required for secrets.
  final SensitiveClipboard? clipboard;

  @override
  State<_EscrowField> createState() => _EscrowFieldState();
}

class _EscrowFieldState extends State<_EscrowField> {
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final shown = !widget.secret || _revealed;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              widget.label,
              style: TextStyle(color: context.palette.muted, fontSize: 12),
            ),
          ),
          Expanded(
            child: shown
                ? SelectableText(
                    widget.value,
                    maxLines: widget.value.contains('\n') ? 6 : 1,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12.5,
                    ),
                  )
                : const Text('••••••••'),
          ),
          if (widget.secret) ...[
            IconButton(
              tooltip: _revealed ? l10n.cvViewerHide : l10n.cvViewerReveal,
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              onPressed: () => setState(() => _revealed = !_revealed),
              icon: Icon(
                _revealed
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
              ),
            ),
            IconButton(
              tooltip: l10n.copy,
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              onPressed: () async {
                await widget.clipboard!.copy(widget.value);
                if (context.mounted) {
                  _snack(
                    context,
                    '${l10n.cvViewerCopied}\n${l10n.cvClipboardAutoClear}',
                  );
                }
              },
              icon: const Icon(Icons.copy_rounded),
            ),
          ],
        ],
      ),
    );
  }
}
