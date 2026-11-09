import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../api/api_client.dart';
import 'app_motion.dart';
import 'app_theme.dart';
import '../l10n/l10n.dart';
import 'app_density.dart';

const _totpCodePattern = r'^[0-9]{6}$';

bool _isValidTotpCode(String value) => RegExp(_totpCodePattern).hasMatch(value);

/// Account-level TOTP enrollment and recovery-code management.
///
/// Provisioning data, passwords, TOTP values and recovery codes live only for
/// the duration of the interactive operation. The panel keeps only the
/// server-provided enabled/count status in [AppController].
class AccountMfaPanel extends StatefulWidget {
  const AccountMfaPanel({required this.app, super.key});

  final AppController app;

  @override
  State<AccountMfaPanel> createState() => _AccountMfaPanelState();
}

class _AccountMfaPanelState extends State<AccountMfaPanel> {
  // Keep dialog controllers alive until the panel is disposed. A dialog route
  // remains mounted during its closing transition, so disposing its
  // controller immediately after showDialog completes can race that teardown.
  final _passwordController = TextEditingController();
  final _totpController = TextEditingController();
  bool _busy = false;
  bool _unconfirmedCodes = false;
  String? _error;
  String? _notice;

  AppController get app => widget.app;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refreshStatus();
    });
  }

  @override
  void dispose() {
    _passwordController.clear();
    _totpController.clear();
    _passwordController.dispose();
    _totpController.dispose();
    super.dispose();
  }

  Future<void> _refreshStatus() async {
    if (_busy) return;
    try {
      await app.refreshAccountMfaStatus();
      if (mounted) {
        setState(() {
          _error = null;
          _notice = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = app.friendlyError(error));
    }
  }

  Future<String?> _askPassword({
    required String title,
    required String actionLabel,
  }) async {
    _passwordController.clear();
    try {
      return await showAppDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(title),
          content: TextField(
            key: const ValueKey('mfa_current_password'),
            controller: _passwordController,
            autofocus: true,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: context.l10n.currentMasterPassword,
            ),
            onSubmitted: (value) => Navigator.pop(dialogContext, value),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(context.l10n.cancel2),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, _passwordController.text),
              child: Text(actionLabel),
            ),
          ],
        ),
      );
    } finally {
      _passwordController.clear();
    }
  }

  Future<({String password, String totpCode})?> _askPasswordAndTotp({
    required String title,
    required String actionLabel,
  }) async {
    _passwordController.clear();
    _totpController.clear();
    try {
      return await showAppDialog<({String password, String totpCode})>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const ValueKey('mfa_current_password'),
                controller: _passwordController,
                autofocus: true,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: context.l10n.currentMasterPassword,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('mfa_totp_code'),
                controller: _totpController,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(6),
                ],
                maxLength: 6,
                enableSuggestions: false,
                autocorrect: false,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  labelText: context.l10n.authenticatorCode,
                  helperText: context.l10n.enterExactlySixDigits,
                  counterText: '',
                ),
                onSubmitted: (_) {
                  if (_isValidTotpCode(_totpController.text)) {
                    Navigator.pop(dialogContext, (
                      password: _passwordController.text,
                      totpCode: _totpController.text,
                    ));
                  }
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(context.l10n.cancel2),
            ),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _totpController,
              builder: (context, value, _) => FilledButton(
                onPressed: _isValidTotpCode(value.text)
                    ? () => Navigator.pop(dialogContext, (
                        password: _passwordController.text,
                        totpCode: value.text,
                      ))
                    : null,
                child: Text(actionLabel),
              ),
            ),
          ],
        ),
      );
    } finally {
      _passwordController.clear();
      _totpController.clear();
    }
  }

  Future<String?> _showTotpSetup(MfaTotpSetup setup) async {
    _totpController.clear();
    final secret = setup.secret;
    final provisioningUri = setup.provisioningUri;
    if (secret == null || provisioningUri == null) return null;
    try {
      return await showAppDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: Text(context.l10n.setUpAuthenticatorApp),
          content: SizedBox(
            width: appDialogWidth(context, 480),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.l10n.addThisAccountInYourAuthenticator,
                  ),
                  const SizedBox(height: 14),
                  Text(
                    context.l10n.setupSecret,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 5),
                  Semantics(
                    key: const ValueKey('mfa_totp_setup_secret_semantics'),
                    label: context.l10n.totpSetupSecretSecret(secret),
                    excludeSemantics: true,
                    child: SelectableText(
                      secret,
                      key: const ValueKey('mfa_totp_setup_secret'),
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 16,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    context.l10n.provisioningUri,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 5),
                  Semantics(
                    key: const ValueKey('mfa_totp_setup_uri_semantics'),
                    label: context.l10n.totpProvisioningUriProvisioninguri(provisioningUri),
                    excludeSemantics: true,
                    child: SelectableText(
                      provisioningUri,
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const ValueKey('mfa_totp_code'),
                    controller: _totpController,
                    autofocus: true,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(6),
                    ],
                    maxLength: 6,
                    enableSuggestions: false,
                    autocorrect: false,
                    textInputAction: TextInputAction.done,
                    decoration: InputDecoration(
                      labelText: context.l10n.authenticatorCode,
                      helperText: context.l10n.enterExactlySixDigits,
                      counterText: '',
                    ),
                    onSubmitted: (_) {
                      if (_isValidTotpCode(_totpController.text)) {
                        Navigator.pop(dialogContext, _totpController.text);
                      }
                    },
                  ),
                  const SizedBox(height: 5),
                  Text(
                    context.l10n.setupExpiresTolocal(setup.expiresAt.toLocal()),
                    style: TextStyle(
                      color: context.palette.muted,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(context.l10n.cancel2),
            ),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _totpController,
              builder: (context, value, _) => FilledButton(
                onPressed: _isValidTotpCode(value.text)
                    ? () => Navigator.pop(dialogContext, value.text)
                    : null,
                child: Text(context.l10n.verifyAndEnable),
              ),
            ),
          ],
        ),
      );
    } finally {
      _totpController.clear();
    }
  }

  Future<bool> _showRecoveryCodes(MfaRecoveryCodes material) async {
    var confirmed = false;
    final formattedCodes = material.codes.join('\n');
    final result = await showAppDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(context.l10n.saveYourMfaRecoveryCodes),
          content: SizedBox(
            width: appDialogWidth(context, 480),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.l10n.eachCodeCanBeUsedOnce,
                  ),
                  const SizedBox(height: 14),
                  Semantics(
                    key: const ValueKey('mfa_recovery_codes_once_semantics'),
                    label: context.l10n.mfaRecoveryCodesFormattedcodes(formattedCodes),
                    excludeSemantics: true,
                    child: SelectableText(
                      formattedCodes,
                      key: const ValueKey('mfa_recovery_codes_once'),
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 14,
                        height: 1.65,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: confirmed,
                    onChanged: (value) =>
                        setDialogState(() => confirmed = value == true),
                    title: Text(context.l10n.iSavedTheseCodesSecurely),
                    controlAffinity: ListTileControlAffinity.leading,
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(context.l10n.close),
            ),
            FilledButton(
              onPressed: confirmed
                  ? () => Navigator.pop(dialogContext, true)
                  : null,
              child: Text(context.l10n.finish),
            ),
          ],
        ),
      ),
    );
    return result == true;
  }

  Future<void> _runMfaAction(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = app.friendlyMfaSettingsError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _enable() async {
    if (_busy) return;
    var password = await _askPassword(
      title: context.l10n.setUpAuthenticatorApp,
      actionLabel: context.l10n.continueLabel,
    );
    if (password == null || password.isEmpty || !mounted) return;
    String? transientPassword = password;
    password = '';
    await _runMfaAction(() async {
      MfaTotpSetup? setup;
      try {
        setup = await app.beginMfaTotpSetup(
          currentPassword: transientPassword!,
        );
        final code = await _showTotpSetup(setup);
        if (code == null || !mounted) return;
        final material = await app.confirmMfaTotp(
          currentPassword: transientPassword!,
          totpCode: code,
        );
        try {
          final saved = await _showRecoveryCodes(material);
          if (mounted) {
            setState(() {
              _unconfirmedCodes = !saved;
              _notice = saved
                  ? 'Two-factor sign-in is enabled.'
                  : 'Two-factor sign-in is enabled, but the recovery codes were not confirmed as saved. Rotate the codes to display a replacement set.';
            });
          }
        } finally {
          material.clear();
        }
      } finally {
        setup?.clear();
        transientPassword = null;
      }
    });
  }

  Future<void> _rotateRecoveryCodes() async {
    if (_busy) return;
    var credentials = await _askPasswordAndTotp(
      title: context.l10n.rotateMfaRecoveryCodes,
      actionLabel: context.l10n.rotateCodes,
    );
    if (credentials == null || !mounted) return;
    if (credentials.password.isEmpty || credentials.totpCode.isEmpty) {
      credentials = null;
      setState(
        () => _error = context.l10n.enterYourCurrentPasswordAndAuthenticator,
      );
      return;
    }
    var transientPassword = credentials.password;
    var transientCode = credentials.totpCode;
    credentials = null;
    await _runMfaAction(() async {
      final material = await app.rotateMfaRecoveryCodes(
        currentPassword: transientPassword,
        totpCode: transientCode,
      );
      try {
        final saved = await _showRecoveryCodes(material);
        if (mounted) {
          setState(() {
            _unconfirmedCodes = !saved;
            _notice = saved
                ? context.l10n.mfaRecoveryCodesWereRotated
                : context.l10n.newRecoveryCodesWereGeneratedBut;
          });
        }
      } finally {
        material.clear();
      }
    });
    transientPassword = '';
    transientCode = '';
  }

  Future<void> _disable() async {
    if (_busy) return;
    final consent = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.l10n.disableTwoFactorSignIn),
        content: Text(
          context.l10n.youWillBeAbleToSign,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(context.l10n.cancel2),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(context.l10n.continueLabel),
          ),
        ],
      ),
    );
    if (consent != true || !mounted) return;
    var credentials = await _askPasswordAndTotp(
      title: context.l10n.disableTwoFactorSignIn,
      actionLabel: context.l10n.disableMfa,
    );
    if (credentials == null || !mounted) return;
    if (credentials.password.isEmpty || credentials.totpCode.isEmpty) {
      credentials = null;
      setState(
        () => _error = context.l10n.enterYourCurrentPasswordAndAuthenticator,
      );
      return;
    }
    var transientPassword = credentials.password;
    var transientCode = credentials.totpCode;
    credentials = null;
    await _runMfaAction(() async {
      await app.disableMfaTotp(
        currentPassword: transientPassword,
        totpCode: transientCode,
      );
      if (mounted) {
        setState(() {
          _unconfirmedCodes = false;
          _notice = 'Two-factor sign-in was disabled.';
        });
      }
    });
    transientPassword = '';
    transientCode = '';
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: app,
    builder: (context, _) {
      final enabled = app.accountMfaEnabled;
      final busy = _busy || app.accountMfaBusy;
      final remaining = app.accountMfaRecoveryCodesRemaining;
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(17),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.verified_user_outlined,
                    color: context.palette.lime,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      context.l10n.twoFactorSignIn,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  Chip(
                    label: Text(
                      enabled == null
                          ? 'Loading…'
                          : enabled
                          ? context.l10n.enabled
                          : context.l10n.disabled,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 7),
              Text(
                context.l10n.useAnAuthenticatorAppOrA,
                style: TextStyle(
                  color: context.palette.muted,
                  height: 1.45,
                  fontSize: 12,
                ),
              ),
              if (enabled == true) ...[
                const SizedBox(height: 8),
                Text(
                  context.l10n.valuevalueRecoveryCodesRemaining(remaining ?? 0),
                  style: TextStyle(color: context.palette.muted, fontSize: 12),
                ),
              ],
              if (_unconfirmedCodes) ...[
                const SizedBox(height: 8),
                Text(
                  context.l10n.theLastRecoveryCodesWereNot,
                  style: TextStyle(color: context.palette.orange, fontSize: 12),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: TextStyle(color: context.palette.red)),
              ],
              if (_notice != null) ...[
                const SizedBox(height: 8),
                Text(_notice!, style: TextStyle(color: context.palette.teal)),
              ],
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (enabled != true)
                    FilledButton.tonalIcon(
                      key: const ValueKey('mfa_enable'),
                      onPressed: busy ? null : _enable,
                      icon: const Icon(Icons.phonelink_lock_outlined),
                      label: Text(context.l10n.setUpAuthenticator),
                    ),
                  if (enabled == true) ...[
                    FilledButton.tonalIcon(
                      key: const ValueKey('mfa_rotate_recovery_codes'),
                      onPressed: busy ? null : _rotateRecoveryCodes,
                      icon: const Icon(Icons.refresh_rounded),
                      label: Text(context.l10n.rotateRecoveryCodes),
                    ),
                    OutlinedButton.icon(
                      key: const ValueKey('mfa_disable'),
                      onPressed: busy ? null : _disable,
                      icon: const Icon(Icons.lock_open_outlined),
                      label: Text(context.l10n.disableMfa),
                    ),
                  ],
                  OutlinedButton.icon(
                    key: const ValueKey('mfa_refresh'),
                    onPressed: busy ? null : _refreshStatus,
                    icon: const Icon(Icons.refresh_rounded),
                    label: Text(context.l10n.refreshMfaStatus),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}
